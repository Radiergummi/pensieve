// Sources/PensieveApp/AppModel.swift
import Foundation
import SwiftUI
import SQLiteData
import GRDB
import os
import PensieveKit

enum SmartListKind: String, CaseIterable, Hashable {
  case whatsNext, dormant, recentlyActive
  var title: String {
    switch self {
    case .whatsNext: return String(localized: "What's Next")
    case .dormant: return String(localized: "Dormant")
    case .recentlyActive: return String(localized: "Recently Active")
    }
  }
  var symbol: String {
    switch self {
    case .whatsNext: return "star"
    case .dormant: return "pause.circle"
    case .recentlyActive: return "dot.radiowaves.left.and.right"
    }
  }
  var color: Color {
    switch self {
    case .whatsNext: return .accentColor
    case .dormant: return .secondary
    case .recentlyActive: return .green
    }
  }
  /// Which bucket of `SmartLists` this kind selects.
  var itemsKeyPath: KeyPath<SmartLists, [NextItem]> {
    switch self {
    case .whatsNext: return \.whatsNext
    case .dormant: return \.dormant
    case .recentlyActive: return \.recentlyActive
    }
  }
}

enum SidebarSelection: Hashable {
  case briefing
  case reviewSuggestions
  case smartList(SmartListKind)
  case node(UUID)
}

/// What the middle column shows for the current sidebar selection. `.looseEndsOf` carries the node id
/// so the view loads its loose ends off-`body` (via `.task`), never in a `body` DB query.
enum MiddleKind: Equatable {
  case nodes([Node])
  case looseEndsOf(UUID)
  case reviewSuggestions
}

/// A New/Edit modal request. Identifiable so it drives `.sheet(item:)`.
struct NodeEditRequest: Identifiable {
  enum Mode { case new(parent: UUID?); case edit(Node) }
  let mode: Mode
  var id: String {
    switch mode {
    case .new(let p): return "new-\(p?.uuidString ?? "root")"
    case .edit(let n): return "edit-\(n.id.uuidString)"
    }
  }
}

/// A ⌘K jump target. Navigation only — sets the same selection state the sidebar does.
enum PaletteDestination: Hashable {
  case node(UUID)
  case smartList(SmartListKind)
  case briefing

  @MainActor func apply(to model: AppModel) {
    switch self {
    case .node(let id):
      model.sidebarSelection = .node(id); model.selectedNodeID = id
    case .smartList(let kind):
      model.sidebarSelection = .smartList(kind); model.selectedNodeID = nil
    case .briefing:
      model.sidebarSelection = .briefing; model.selectedNodeID = nil
    }
  }
}

/// A user-facing failure from an organizing write. Two flavors, both surfaced the same way:
/// a REFUSAL (the command returned a non-success value — stale/guarded state) and a THROW (a real
/// DB error). Refusals get honest, non-alarming copy; throws append the underlying description.
struct AppError: Identifiable {
  let id = UUID()
  let title: String
  let message: String

  /// The node changed under the menu (deleted or re-parented between open and click).
  static func refusal(_ verb: String, _ name: String) -> AppError {
    AppError(title: String(localized: "Couldn’t \(verb) “\(name)”"),
             message: String(localized: "It may have changed since this menu opened. The view has been refreshed — try again."))
  }

  static func failure(_ verb: String, _ name: String, _ error: Error) -> AppError {
    AppError(title: String(localized: "Couldn’t \(verb) “\(name)”"),
             message: error.localizedDescription)
  }

  /// The new node's parent vanished under the menu. This case does NOT compose a verb into the shared
  /// refusal title: German needs a past participle in that passive frame, and "add a node under" is an
  /// infinitive with a trailing preposition — composing it produces an ungrammatical sentence. Its own
  /// complete key lets each language phrase the whole thing naturally.
  static func cannotAddUnder(_ parent: String) -> AppError {
    AppError(title: String(localized: "Couldn’t add a node under “\(parent)”"),
             message: String(localized: "It may have changed since this menu opened. The view has been refreshed — try again."))
  }
}

@MainActor
final class AppModel: ObservableObject {
  @Published var lists = SmartLists(whatsNext: [], dormant: [], recentlyActive: [])
  @Published var forest: [NodeForestNode] = []
  @Published var archivedForest: [NodeForestNode] = []
  @Published var sidebarSelection: SidebarSelection? = .briefing
  @Published var selectedNodeID: UUID?
  /// Drives the New/Edit node modal. nil = closed. Mounted in RootView.
  @Published var editingNode: NodeEditRequest?
  /// Non-nil while a Move/Merge picker sheet is up for that node. Mounted in RootView.
  @Published var movePickerNodeID: UUID?
  @Published var mergePickerNodeID: UUID?
  /// Non-nil while the delete confirmation is presented for that node. Mounted in RootView.
  @Published var pendingDeleteNodeID: UUID?
  /// The one surfaced organizing-write failure. Mounted as a single `.alert` in RootView.
  @Published var presentedError: AppError?
  @Published var snapshot = MonitorSnapshot(status: .notSetUp, lastCaptureAt: nil,
                                            spoolPending: 0, eventCount: 0, looseEndCount: 0)
  @Published var briefingCards: [BriefingCard] = []
  /// Count of open, unlabeled, machine-suggested loose ends — the "Review Suggestions" badge.
  @Published var reviewCount = 0
  /// Set by the AppDelegate when an external `pensieve://` URL is opened; observed by the
  /// always-mounted menu-bar label, which applies it and clears it back to nil.
  @Published var pendingDeepLink: DeepLink?
  /// Set by File ▸ Open in New Window (⌘⌥N); observed by RootView, which opens a recall window
  /// via its own openWindow environment and clears it. (RootView is a View, so it reliably has
  /// openWindow; a Commands struct's environment access is less reliable — hence this bridge.)
  @Published var openNodeRequest: UUID?
  /// "Since when" the Briefing measures movement: the previous launch's timestamp (or 7 days ago on
  /// first run). Fixed for the session so cards don't shift under you while the window is open.
  let briefingSince: Date

  var db: (any DatabaseWriter)?
  /// Persistent spool connection, reused for BOTH drains and the heartbeat. Opening a fresh
  /// connection per refresh/drain touches the store dir's `-shm`/`-wal` sidecars, which re-fires
  /// the FSEvents watch below into a busy-loop; a long-lived connection reads without that churn.
  private var spool: CaptureSpool?
  private var allNodes: [Node] = []
  /// The active Focus context ("" = no Focus / unfiltered), mirrored from UserDefaults by the
  /// SetFocusFilterIntent. Drives the visible-node filter applied in refresh()/refreshGlance().
  private var activeFocusContext = ""
  /// Last context the forest was built for — so a context change rebuilds it even when the node set
  /// is unchanged (the `fetched != allNodes` guard alone would skip it).
  private var lastForestContext: String?
  private var observationTask: Task<Void, Never>?
  private var spoolWatcher: DirectoryWatcher?
  private var canonicalWatcher: DirectoryWatcher?
  private lazy var refreshDebouncer = Debouncer(interval: 0.15) { [weak self] in
    await self?.refreshFromWatch()
  }
  private lazy var drainDebouncer = Debouncer(interval: 0.15) { [weak self] in
    await self?.drainThenRefreshFromWatch()
  }
  /// Coalesces rapid typing in the .searchable field into one DB read (runSearch), instead of a
  /// full node+loose-end scan per keystroke.
  private lazy var searchDebouncer = Debouncer(interval: 0.2) { [weak self] in
    await self?.runSearch()
  }
  private var started = false
  // NOT lazy: rebuilt when the provider preference/config changes (SettingsView), so an in-session
  // switch takes effect on the next narration instead of requiring a relaunch. Bootstrapped cheaply
  // here; `init()` calls rebuildSummaryBuilder() to fold in any configured cloud provider.
  private var summaryBuilder = SummaryBuilder(provider: ClaudeCLIProvider())
  /// The raw narration provider, retained so the manual "describe this node" action can call
  /// `NodeDescriber.describe` directly (SummaryBuilder's provider is private). Rebuilt alongside
  /// `summaryBuilder` on a provider/config change.
  private var descriptionProvider: any LLMProvider = ClaudeCLIProvider()
  /// The provider kind the current `summaryBuilder` uses — folded into the narration cache key so a
  /// provider/model switch invalidates prose cached under the old provider.
  private var providerKind = "claudeCLI"

  /// Reads the app-side cloud inputs: config from UserDefaults, key from the Keychain. Returns
  /// (nil, nil) when no flavor is set.
  private func cloudInputs() -> (CloudConfig?, String?) {
    let d = UserDefaults.standard
    guard let raw = d.string(forKey: PensieveDefaults.cloudFlavorKey),
          let flavor = CloudFlavor(rawValue: raw) else { return (nil, nil) }
    let stored = d.string(forKey: PensieveDefaults.cloudBaseURLKey) ?? ""
    let baseURL = stored.isEmpty ? flavor.defaultBaseURL : stored   // empty ⇒ default, matching the UI
    let model = d.string(forKey: PensieveDefaults.cloudModelKey) ?? ""
    let config = CloudConfig(flavor: flavor, baseURL: baseURL, model: model)
    let key = KeychainSecretStore().read(account: CloudPresets.keychainAccount(flavor: flavor, baseURL: baseURL))
    return (config, key)
  }

  /// Rebuild the narration provider + its cache kind from the current UserDefaults selection + cloud
  /// inputs. The kind folds flavor+model in ONLY when the resolved kind is actually "cloud", so a
  /// not-configured cloud selection keys as the real local kind that runs.
  func rebuildSummaryBuilder() {
    let (config, key) = cloudInputs()
    let provider = makeDefaultLLMProvider(cloudConfig: config, apiKey: key)
    summaryBuilder = SummaryBuilder(provider: provider)
    descriptionProvider = provider
    let kind = resolvedProviderKind(cloudConfig: config, apiKey: key)
    if kind == "cloud", let config {
      let account = CloudPresets.keychainAccount(flavor: config.flavor, baseURL: config.baseURL)
      providerKind = "cloud:\(account):\(config.model)"
    } else {
      providerKind = kind
    }
    AppLog.app.info("Provider rebuilt: \(self.providerKind, privacy: .public)")
  }
  /// Persisted narration: prose + the invalidation key it was generated for. Keyed per DB path
  /// (NEW pattern — lastOpenedAt is a single global key today) so throwaway smoke/test stores
  /// don't pollute the real cache. Device-local: narration is a derived, provider-specific
  /// output cache and must not sync.
  private struct CachedNarration: Codable { let prose: String; let key: String }
  private var narrationCache: [UUID: CachedNarration] = [:]

  private static func narrationCacheDefaultsKey() -> String {
    "pensieve.narrationCache." + Stores.canonicalURL.path
  }
  private func loadNarrationCache() {
    guard let data = UserDefaults.standard.data(forKey: Self.narrationCacheDefaultsKey()),
          let decoded = try? JSONDecoder().decode([UUID: CachedNarration].self, from: data)
    else { return }
    narrationCache = decoded
  }
  private func saveNarrationCache() {
    guard let data = try? JSONEncoder().encode(narrationCache) else { return }
    UserDefaults.standard.set(data, forKey: Self.narrationCacheDefaultsKey())
  }
  /// Bumped on launch + ⌘R (drainThenRefresh). Views key their reload `.task` on it so the OPEN
  /// detail re-narrates after a refresh. The watch-driven refreshDebouncer calls `refresh()` (not
  /// drainThenRefresh), so this never bumps on background liveness updates.
  @Published private(set) var refreshToken = 0

  // MARK: - In-app find
  @Published var searchText: String = ""
  @Published private(set) var searchResults: SearchResults = SearchResults()
  /// The loose-end row a search hit should auto-expand + scroll to. Consumed by LooseEndRow/DetailView.
  @Published var expandedLooseEndID: UUID?
  /// Set by the Find command; RootView observes it to move focus into the .searchable field.
  @Published var focusSearchRequested = false
  private var searchTask: Task<Void, Never>?
  private var searchToken = 0

  /// The single source of truth for "search mode is active" — a non-empty trimmed field. Every
  /// site that branches on search (the middle content, the refresh re-run, the detail one-home
  /// override, clear-on-navigation) reads this, so the trimming rule can't drift.
  var isSearching: Bool { !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

  private static let lastOpenedKey = "pensieve.lastOpenedAt"

  init() {
    let prev = UserDefaults.standard.object(forKey: Self.lastOpenedKey) as? Date
    briefingSince = prev ?? Calendar.current.date(byAdding: .day, value: -7, to: Date())!
    UserDefaults.standard.set(Date(), forKey: Self.lastOpenedKey)
    rebuildSummaryBuilder()
  }

  func start() {
    guard !started else { return }
    started = true
    AppLog.app.info("App started, canonical=\(Stores.canonicalURL.path, privacy: .public) spool=\(Stores.spoolURL.path, privacy: .public)")
    // Open the canonical store read/write (needed for the launch drain). Missing store degrades to empty.
    db = try? openCanonicalDatabase(at: Stores.canonicalURL)
    loadNarrationCache()
    spool = try? CaptureSpool(at: Stores.spoolURL)   // persistent — see the property note above
    activeFocusContext = UserDefaults.standard.string(forKey: FocusFilterDefaults.activeContextKey) ?? ""
    Task { await drainThenRefresh() }

    // Liveness (retires the 3 s Timer). Watches are app-lifetime (this @StateObject never deinits),
    // so the menu-bar glyph stays live even when the main window is closed.
    if let db {
      observationTask = Task { [weak self] in
        let observation = ValueObservation.tracking { db in try Event.fetchCount(db) }
        do {
          for try await _ in observation.values(in: db) {
            await self?.refreshDebouncer.schedule()   // in-process writes (own drains, future edits)
          }
        } catch { /* observation ended; watches still cover changes */ }
      }
    }
    let canonicalDir = Stores.canonicalURL.deletingLastPathComponent().path
    let spoolDir = Stores.spoolURL.deletingLastPathComponent().path
    canonicalWatcher = DirectoryWatcher(paths: [canonicalDir]) { [weak self] in
      Task { await self?.refreshDebouncer.schedule() }   // catches the EXTERNAL daemon's writes
    }
    spoolWatcher = DirectoryWatcher(paths: [spoolDir]) { [weak self] in
      Task { await self?.drainDebouncer.schedule() }      // new git/session activity → self-drain
    }

    AppLog.app.info("Liveness watchers registered")

    // The SetFocusFilterIntent runs in-process and writes UserDefaults → observe on the main queue.
    NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification,
                                           object: nil, queue: .main) { [weak self] _ in
      Task { @MainActor in self?.focusContextDidChange() }
    }
  }

  /// On-demand equivalent of the launch drain+refresh, for the ⌘R Refresh menu command.
  func refreshNow() async { await drainThenRefresh() }

  private func drainThenRefresh() async {
    AppLog.app.info("Drain+refresh triggered")
    if let db, let spool {
      _ = try? await Ingester(spool: spool, db: db).drain()   // no LLM: spool → events only
    }
    refresh()
    // launch/⌘R: do NOT blanket-clear — cachedNarration/narration are key-aware, so unchanged
    // nodes reuse persisted prose and only changed nodes regenerate. ⌘R force-refresh of the
    // selected node happens in DetailView (force: on same-node token bump).
    refreshToken += 1
    await SpotlightIndexer.reindex(activeContext: activeFocusContext)   // launch + ⌘R
  }

  /// Watch-triggered drain: ingest new spool rows on our own connection. The resulting canonical
  /// change trips ValueObservation + the canonical watch → refreshDebouncer. Does NOT clear the
  /// narration cache or bump refreshToken (those are launch/⌘R semantics).
  private func drainThenRefreshFromWatch() async {
    AppLog.app.debug("Spool watcher fired -> drain")
    if let db, let spool {
      _ = try? await Ingester(spool: spool, db: db).drain()
    }
  }

  /// Watch-triggered refresh: recompute state on the main actor, then reindex Spotlight. Kept as one
  /// @MainActor method so the debouncer's `await self?.refreshFromWatch()` needs no `MainActor.run`
  /// wrapper nor a nested `Task` — the nested Task captured the weak-`self` var in concurrently
  /// executing code, which is an error under the Swift 6 language mode.
  private func refreshFromWatch() async {
    AppLog.app.debug("Canonical watcher fired -> refresh")
    refresh()
    await reindexSpotlight()
  }

  private func reindexSpotlight() async { await SpotlightIndexer.reindex(activeContext: activeFocusContext) }

  /// UserDefaults changed — if the active Focus context flipped, re-filter the window + reindex.
  private func focusContextDidChange() {
    let new = UserDefaults.standard.string(forKey: FocusFilterDefaults.activeContextKey) ?? ""
    guard new != activeFocusContext else { return }
    AppLog.app.info("Focus context changed: '\(self.activeFocusContext, privacy: .public)' -> '\(new, privacy: .public)'")
    activeFocusContext = new
    refresh()
    Task { await SpotlightIndexer.reindex(activeContext: new) }
  }

  /// Filter a freshly-computed SmartLists to the ids visible under the active context.
  private func filtered(_ l: SmartLists, _ visible: Set<UUID>) -> SmartLists {
    SmartLists(
      whatsNext: l.whatsNext.filter { visible.contains($0.project.id) },
      dormant: l.dormant.filter { visible.contains($0.project.id) },
      recentlyActive: l.recentlyActive.filter { visible.contains($0.project.id) })
  }

  /// Narrow refresh for the menu-bar glance: only what the popover shows (heartbeat + What's Next),
  /// skipping the briefing cards / forest that only the main window needs.
  func refreshGlance() {
    snapshot = MonitorSnapshot.gather(canonical: db, spool: spool)
    guard let db else { return }
    guard let raw = try? SmartLists.compute(db, now: Date()) else { return }
    let visible = NodeContextResolver.visibleNodeIDs(for: activeFocusContext, in: allNodes)
    lists = activeFocusContext.isEmpty ? raw : filtered(raw, visible)
  }

  func refresh() {
    // Heartbeat from the persistent connections (opening fresh ones here would re-fire the store-dir
    // watch into a busy-loop). Works before the db guard: nil connections degrade to a zero snapshot.
    snapshot = MonitorSnapshot.gather(canonical: db, spool: spool)
    guard let db else { return }
    let now = Date()
    let fetched = (try? ProjectQueries.all(db)) ?? allNodes
    let nodesChanged = fetched != allNodes
    if nodesChanged { allNodes = fetched }
    let visible = NodeContextResolver.visibleNodeIDs(for: activeFocusContext, in: allNodes)

    if let raw = try? SmartLists.compute(db, now: now) {
      lists = activeFocusContext.isEmpty ? raw : filtered(raw, visible)
    }
    if let raw = try? BriefingQueries.cards(db, since: briefingSince, now: now) {
      briefingCards = activeFocusContext.isEmpty ? raw : raw.filter { visible.contains($0.node.id) }
    }
    if nodesChanged || activeFocusContext != lastForestContext {
      let source = activeFocusContext.isEmpty ? allNodes : allNodes.filter { visible.contains($0.id) }
      forest = NodeForest.build(source.filter { $0.state == "active" })
      archivedForest = NodeForest.build(source.filter { $0.state == "archived" })
      lastForestContext = activeFocusContext
    }
    reviewCount = (try? SalienceReviewQueries.pendingCount(db)) ?? 0
    if isSearching { runSearch() }
  }

  func node(_ id: UUID) -> Node? { allNodes.first { $0.id == id } }

  /// Count of top-level project nodes, for the content-column header.
  var projectCount: Int {
    allNodes.filter { $0.parentID == nil && $0.kind == NodeKind.project && $0.state == "active" }.count
  }

  /// The middle column's content for the current `sidebarSelection`. Pure/in-memory (children reads
  /// `allNodes`); the leaf case defers its loose-ends DB read to the view's `.task`.
  func middleKind() -> MiddleKind {
    switch sidebarSelection {
    case .briefing:
      return .nodes(briefingCards.map(\.node))
    case .reviewSuggestions:
      return .reviewSuggestions
    case .smartList(let kind):
      return .nodes(lists[keyPath: kind.itemsKeyPath].map(\.project))
    case .node(let id):
      let kids = visibleChildren(of: id)
      return kids.isEmpty ? .looseEndsOf(id) : .nodes(kids)
    case nil:
      return .nodes([])
    }
  }

  /// Direct children of `id`, name-sorted (thin wrapper over the pure Kit helper).
  func children(of id: UUID) -> [Node] { NodeForest.children(of: id, in: allNodes) }

  /// Children of `id` restricted to the same "world" as `id` itself — archived children under an
  /// archived node, active children under an active one — so the two "worlds" don't bleed into
  /// each other. The ONE state-scoped children filter: `middleKind()` and `detailShowsLooseEnds`
  /// both call this so they can never disagree about whether `id` has visible children.
  func visibleChildren(of id: UUID) -> [Node] {
    let showArchived = node(id)?.state == "archived"
    return children(of: id).filter { ($0.state == "archived") == showArchived }
  }

  /// A middle-column node tap. In tree mode this DRILLS — the tapped node becomes the focused node, so
  /// the middle re-populates with its contents; from a smart list / briefing it only sets the detail
  /// node, leaving the triage list in place.
  func selectMiddleNode(_ id: UUID) {
    expandedLooseEndID = nil
    if case .node = sidebarSelection {
      sidebarSelection = .node(id)
    }
    selectedNodeID = id
  }

  /// The middle column's title: the focused node's name in tree mode, else the app name. The app name
  /// is a proper noun — NOT localized.
  var middleTitle: String {
    if case .node(let id) = sidebarSelection, let n = node(id) { return n.name }
    return "Pensieve"
  }

  /// The detail recall shows its Loose Ends section EXCEPT when the middle is already showing this same
  /// node's loose ends (the focused leaf) — the one-home rule (no duplication). While searching, the
  /// middle shows results (never a leaf's loose ends), so the one-home premise is void and the detail
  /// always shows its loose ends — including the row a search hit auto-expands into.
  var detailShowsLooseEnds: Bool {
    if isSearching { return true }
    if case .node(let fid) = sidebarSelection, selectedNodeID == fid, visibleChildren(of: fid).isEmpty {
      return false
    }
    return true
  }

  /// The keystroke entry point (from the .searchable field). Coalesces rapid typing into one
  /// debounced DB read; an empty/whitespace field clears immediately so exiting search stays crisp.
  func searchTextChanged() {
    guard isSearching else { runSearch(); return }   // empty → synchronous clear via runSearch's guard
    Task { await searchDebouncer.schedule() }
  }

  /// The one entry point for the actual search read (the debounced keystroke path AND the liveness
  /// refresh). Cancels the prior task; runs the read off-main; assigns results under a monotonic token
  /// so a stale keystroke can't overwrite a newer result. Below the min length → clears results.
  func runSearch() {
    searchTask?.cancel()
    let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard query.count >= SearchQueries.minQueryLength, let db else {
      searchResults = SearchResults()
      expandedLooseEndID = nil   // emptying the field (any way) exits search coherently, incl. the leaf one-home override
      return
    }
    let visible = NodeContextResolver.visibleNodeIDs(for: activeFocusContext, in: allNodes)
    searchToken += 1
    let token = searchToken
    searchTask = Task { [weak self] in
      let results = try? await Task.detached {
        try SearchQueries.search(query: query, visibleNodeIDs: visible, db)
      }.value
      guard let self, self.searchToken == token, !Task.isCancelled else { return }
      self.searchResults = results ?? SearchResults()
    }
  }

  /// A node search hit: drive the detail only (the briefing-card pattern), leaving sidebarSelection
  /// so clearing the field restores a coherent middle list. Clears any pending loose-end expand.
  func selectSearchNode(_ id: UUID) {
    expandedLooseEndID = nil
    selectedNodeID = id
  }

  /// A loose-end search hit: select its node and mark the row to auto-expand + scroll to.
  func selectSearchLooseEnd(_ hit: LooseEndHit) {
    selectedNodeID = hit.nodeID
    expandedLooseEndID = hit.id
  }

  /// Exit search mode (e.g. on sidebar navigation): clear the field, results, and pending expand.
  func clearSearch() {
    searchText = ""
    searchResults = SearchResults()
    expandedLooseEndID = nil
    searchTask?.cancel()
  }

  func detail(for node: Node) -> (status: ProjectStatus, looseEnds: [LooseEndView]) {
    let fallback = ProjectStatus(project: node, recentEvents: [])
    guard let db else { return (fallback, []) }
    let now = Date()
    let status = (try? ProjectQueries.status(db, node: node, limit: 15)) ?? fallback
    let ends = (try? LooseEndQueries.open(db, nodeID: node.id, now: now)) ?? []
    return (status, ends)
  }

  /// The node's recall rendered as shareable English Markdown. Reuses `detail(for:)` for the gather
  /// and includes the narration only if it's already cached (a share never blocks on an LLM call).
  func recallMarkdown(for node: Node) -> String {
    let d = detail(for: node)
    // Respect the narration display toggle: a disabled recap must not leak into a share/export.
    let narration = AppDefaults.narrationEnabled ? cachedNarration(for: node, events: d.status.recentEvents) : nil
    return RecallMarkdown.render(node: node, narration: narration,
                                 looseEnds: d.looseEnds, events: d.status.recentEvents, now: Date())
  }

  /// Open loose ends for a node — the inspector's slice of `detail(for:)` (no status query).
  /// Loaded once per selection via the inspector's `.task`, never in a view `body`.
  func looseEnds(forNode nodeID: UUID) -> [LooseEndView] {
    guard let db else { return [] }
    return (try? LooseEndQueries.open(db, nodeID: nodeID, now: Date())) ?? []
  }

  /// The cross-node audit queue for the Review Suggestions surface. Loaded off-`body` via `.task`.
  func reviewItems() -> [LooseEndView] {
    guard let db else { return [] }
    return (try? SalienceReviewQueries.pending(db, now: Date())) ?? []
  }

  /// Confirm a user salience label for a loose end (👍 salient / 👎 noise / "" clears).
  func setLooseEndLabel(_ looseEndID: UUID, _ label: String) {
    guard let db else { return }
    do {
      let ok = try LooseEndCommands.setLabel(db, id: looseEndID, label: label)
      if !ok { refuse(String(localized: "update"), String(localized: "this loose end")) }
    } catch {
      fail(String(localized: "update"), String(localized: "this loose end"), error)
    }
  }

  // MARK: - Organizing writes (metadata only; each calls the op then refreshes explicitly, because
  // Node-only writes don't change the Event count the liveness ValueObservation tracks).

  /// A refusal: the view was stale, so REFRESH (that's the remedy — the phantom node disappears and
  /// the "try again" copy becomes true), then surface the alert. Post-write state changes are skipped.
  private func refuse(_ verb: String, _ name: String) {
    refresh()
    presentedError = .refusal(verb, name)
  }

  /// A throw: a real DB error. Do NOT refresh — an error tells us nothing about staleness.
  private func fail(_ verb: String, _ name: String, _ error: Error) {
    presentedError = .failure(verb, name, error)
  }

  /// The display name for a node id, falling back to a neutral word when it's already gone.
  private func displayName(_ id: UUID) -> String {
    node(id)?.name ?? String(localized: "this item")
  }

  /// Default kind for a new node: a child of a project/domain is a strand; everything else a project.
  func defaultKind(under parentID: UUID?) -> String {
    guard let parentID, let parent = node(parentID) else { return NodeKind.project }
    return (parent.kind == NodeKind.project || parent.kind == NodeKind.domain) ? NodeKind.strand : NodeKind.project
  }

  /// Open the New Node modal (replaces the old immediate-insert + inline-rename flow → fixes #3).
  func presentNewNode(under parentID: UUID?) { editingNode = NodeEditRequest(mode: .new(parent: parentID)) }
  /// Open the Edit modal for an existing node.
  func presentEditNode(_ node: Node) { editingNode = NodeEditRequest(mode: .edit(node)) }

  /// Commit the New Node modal: insert fully-formed, select it.
  func commitNewNode(parent parentID: UUID?, name: String, kind: String,
                     icon: String, colorTag: String, context: String) {
    guard let db else { return }
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    do {
      // nil ⇒ the parent id didn't resolve (deleted under the menu). Name the PARENT: the new node
      // doesn't exist yet, so its own name would be meaningless in the copy.
      guard let new = try NodeCommands.add(db, name: trimmed, kind: kind,
                                           parent: parentID?.uuidString, description: "",
                                           icon: icon, colorTag: colorTag, context: context) else {
        let parentName = parentID.map { displayName($0) } ?? String(localized: "the top level")
        refresh()
        presentedError = .cannotAddUnder(parentName)
        return
      }
      refresh()
      sidebarSelection = .node(new.id); selectedNodeID = new.id
    } catch {
      fail(String(localized: "create"), trimmed, error)
    }
  }

  /// Commit the Edit modal: atomic name/kind/icon/colorTag update.
  func updateNode(_ nodeID: UUID, name: String, kind: String,
                  icon: String, colorTag: String, context: String) {
    guard let db else { return }
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    let label = displayName(nodeID)
    do {
      let ok = try NodeCommands.update(db, nodeID: nodeID, name: trimmed, kind: kind,
                                       icon: icon, colorTag: colorTag, context: context)
      if ok { refresh() } else { refuse(String(localized: "rename"), label) }
    } catch {
      fail(String(localized: "rename"), label, error)
    }
  }

  /// Whether `nodeID` may be deleted (no live source or auto-birthed strand in its subtree → won't resurrect on sync).
  func canDelete(_ nodeID: UUID) -> Bool {
    guard let db else { return false }
    return (try? NodeCommands.subtreeIsActivityBorn(db, nodeID: nodeID)) == false
  }

  func move(_ nodeID: UUID, under newParentID: UUID?) {
    guard let db else { return }
    let label = displayName(nodeID)
    do {
      // false ⇒ cycle guard, unknown node, or unknown parent — all stale-state rejections.
      let ok = try NodeCommands.reparent(db, nodeID: nodeID, newParentID: newParentID)
      if ok { refresh() } else { refuse(String(localized: "move"), label) }
    } catch {
      fail(String(localized: "move"), label, error)
    }
  }

  func archive(_ nodeID: UUID) {
    guard let db else { return }
    // Selection moves off the whole archived subtree so we don't strand the detail pane on a
    // node that just left the active tree.
    let subtree = NodeForest.descendantIDs(of: nodeID, in: allNodes).union([nodeID])
    _ = try? NodeCommands.archive(db, nodeID: nodeID)
    if let sel = selectedNodeID, subtree.contains(sel) { selectedNodeID = nil }
    if case .node(let id) = sidebarSelection, subtree.contains(id) { sidebarSelection = .briefing }
    refresh()
  }

  func unarchive(_ nodeID: UUID) {
    guard let db else { return }
    _ = try? NodeCommands.unarchive(db, nodeID: nodeID)
    refresh()
  }

  /// Merge `sourceID` into `targetID`. `ProjectResolver.group` returns Void and never validates that
  /// the TARGET still exists: a concurrently-deleted target aborts the whole transaction on an FK
  /// violation (no data loss — but "FOREIGN KEY constraint failed" is not copy we show a human). So
  /// pre-check both nodes and emit the normal refusal instead. `group` itself stays untouched.
  func merge(_ sourceID: UUID, into targetID: UUID) {
    guard let db, sourceID != targetID else { return }
    let label = displayName(sourceID)

    let bothExist = (try? db.read { db in
      try Node.where { $0.id.eq(sourceID) }.fetchOne(db) != nil
        && Node.where { $0.id.eq(targetID) }.fetchOne(db) != nil
    }) ?? false
    guard bothExist else { refuse(String(localized: "merge"), label); return }

    do {
      try ProjectResolver(db: db).group(targetID, into: [sourceID])
      // The source node is gone: move any state that referenced it onto the survivor.
      if selectedNodeID == sourceID { selectedNodeID = targetID }
      if sidebarSelection == .node(sourceID) { sidebarSelection = .node(targetID) }
      refresh()
    } catch {
      fail(String(localized: "merge"), label, error)
    }
  }

  /// Legal Move/Merge targets for `nodeID`: every node except itself, its descendants, and any
  /// archived node (an active node moved/merged under an archived parent would immediately become
  /// a phantom top-level root — see Finding 3 of the archive-nodes whole-branch review).
  func moveTargets(for nodeID: UUID) -> [Node] {
    let banned = NodeForest.descendantIDs(of: nodeID, in: allNodes).union([nodeID])
    return allNodes.filter { !banned.contains($0.id) && $0.state != "archived" }.sorted { $0.name < $1.name }
  }

  /// Delete a (source-free) node and its subtree via the Kit cascade. Moves selection off it.
  func deleteNode(_ nodeID: UUID) {
    guard let db else { return }
    let label = displayName(nodeID)
    do {
      switch try NodeCommands.delete(db, nodeID: nodeID) {
      case .deleted:
        if selectedNodeID == nodeID { selectedNodeID = nil }
        if sidebarSelection == .node(nodeID) { sidebarSelection = .briefing }
        refresh()
      case .blocked:
        // The subtree is activity-born — it would resurrect on the next sync. `canDelete` already
        // gates the menu, so this only fires on a stale menu; the copy names the real reason.
        refresh()
        presentedError = AppError(
          title: String(localized: "Can’t delete “\(label)”"),
          message: String(localized: "It still has captured sources or activity that would return on the next sync."))
      case .notFound:
        refuse(String(localized: "delete"), label)
      }
    } catch {
      fail(String(localized: "delete"), label, error)
    }
  }

  /// Destructive-confirmation copy for the currently-pending delete. Names the node; warns about
  /// nested items when the subtree isn't a leaf. (Exact event counts would need a Kit read; the
  /// subtree shape from the in-memory forest is enough for an honest warning.)
  func deleteConfirmationText() -> String {
    guard let id = pendingDeleteNodeID, let n = node(id) else { return "" }
    let hasChildren = allNodes.contains { $0.parentID == id }
    if hasChildren {
      return String(localized: "Delete “\(n.name)” and everything nested under it? Captured activity and loose ends are removed. This can’t be undone.")
    }
    return String(localized: "Delete “\(n.name)”? Its captured activity and loose ends are removed. This can’t be undone.")
  }

  /// Surrounding-transcript provenance for a loose end, resolved off the main actor (file I/O).
  /// nil only when the source event is missing; a present-but-unavailable transcript returns a
  /// ProvenanceContext with `transcriptAvailable == false`.
  func provenance(for looseEnd: LooseEnd) async -> ProvenanceContext? {
    guard let db else { return nil }
    return try? await Task.detached { try ProvenanceQueries.context(db, looseEnd: looseEnd) }.value
  }

  /// Cached narration for `node` IFF the stored key still matches the current events. Synchronous —
  /// lets the view render a valid cached recap instantly (including across launches).
  func cachedNarration(for node: Node, events: [Event]) -> String? {
    guard let entry = narrationCache[node.id],
          entry.key == NarrationCacheKey.make(events: events, provider: providerKind) else { return nil }
    return entry.prose
  }

  /// The "Last Work Done" narration for `node`. Returns the cached result when its key matches and
  /// `force` is false; otherwise regenerates off-main, stores prose+key, and returns it. `force`
  /// (⌘R on the selected node) bypasses the cache so the user can always refresh a bad recap.
  func narration(for node: Node, events: [Event], force: Bool = false) async -> String? {
    let key = NarrationCacheKey.make(events: events, provider: providerKind)
    if !force, let entry = narrationCache[node.id], entry.key == key { return entry.prose }
    let text = await summaryBuilder.narrate(project: node, events: events)
    if let text {
      narrationCache[node.id] = CachedNarration(prose: text, key: key)
      saveNarrationCache()
    }
    return text
  }

  /// True when `node` is a project with exactly one git source — i.e. `NodeDescriber` can act on
  /// it. Gates the DetailView's describe/refresh button so it never appears where it would no-op.
  func isDescribable(_ node: Node) -> Bool {
    guard node.kind == NodeKind.project, let db else { return false }
    let key = try? db.read { db in try NodeDescriber.soleGitRepoKey(db, nodeID: node.id) }
    return (key ?? nil) != nil
  }

  /// Manual "describe this node" action: force-derive `node`'s description off-main via the retained
  /// provider, then refresh so the new text renders. Best-effort — a failure/empty leaves the
  /// existing description untouched. Returns the outcome so the view can show an inline note.
  func describeNode(_ node: Node) async -> NodeDescriber.Outcome {
    guard let db else { return .ineligible }
    let outcome = await NodeDescriber.describe(db, nodeID: node.id, provider: descriptionProvider, force: true)
    refresh()
    return outcome
  }
}
