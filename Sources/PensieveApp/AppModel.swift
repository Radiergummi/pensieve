// Sources/PensieveApp/AppModel.swift
import Foundation
import SwiftUI
import Observation
import SQLiteData
import GRDB
import os
import PensieveKit

@MainActor
@Observable
final class AppModel {
  var lists = SmartLists(whatsNext: [], dormant: [], recentlyActive: [])
  var forest: [NodeForestNode] = []
  var archivedForest: [NodeForestNode] = []
  var sidebarSelection: SidebarSelection? = .briefing
  var selectedNodeID: UUID?
  /// Drives the New/Edit node modal. nil = closed. Mounted in RootView.
  var editingNode: NodeEditRequest?
  /// Non-nil while a Move/Merge picker sheet is up for that node. Mounted in RootView.
  var movePickerNodeID: UUID?
  var mergePickerNodeID: UUID?
  /// Non-nil while the delete confirmation is presented for that node. Mounted in RootView.
  var pendingDeleteNodeID: UUID?
  /// The one surfaced organizing-write failure. Mounted as a single `.alert` in RootView.
  var presentedError: AppError?
  var snapshot = MonitorSnapshot(status: .notSetUp, lastCaptureAt: nil,
                                            spoolPending: 0, eventCount: 0, looseEndCount: 0)
  var briefingCards: [BriefingCard] = []
  /// Count of open, unlabeled, machine-suggested loose ends — the "Review Suggestions" badge.
  var reviewCount = 0
  /// Set by the AppDelegate when an external `pensieve://` URL is opened; observed by the
  /// always-mounted menu-bar label, which applies it and clears it back to nil.
  var pendingDeepLink: DeepLink?
  /// Set by File ▸ Open in New Window (⌘⌥N); observed by RootView, which opens a recall window
  /// via its own openWindow environment and clears it. (RootView is a View, so it reliably has
  /// openWindow; a Commands struct's environment access is less reliable — hence this bridge.)
  var openNodeRequest: UUID?
  /// "Since when" the Briefing measures movement: the previous launch's timestamp (or 7 days ago on
  /// first run). Fixed for the session so cards don't shift under you while the window is open.
  let briefingSince: Date

  @ObservationIgnored var database: (any DatabaseWriter)?
  /// Persistent spool connection, reused for BOTH drains and the heartbeat. Opening a fresh
  /// connection per refresh/drain touches the store dir's `-shm`/`-wal` sidecars, which re-fires
  /// the FSEvents watch below into a busy-loop; a long-lived connection reads without that churn.
  @ObservationIgnored private var spool: CaptureSpool?
  // Tracked (NOT @ObservationIgnored): read by view bodies via node(_:) — e.g. RecallWindowView,
  // whose body reads only node(nodeID). Silencing it would leave that body with no observation
  // dependency, so a cold-restored recall window could never recover from its transient nil.
  // NOT private: AppModel+Search.swift and AppModel+Organizing.swift also read it.
  var allNodes: [Node] = []
  /// The active Focus context ("" = no Focus / unfiltered), mirrored from UserDefaults by the
  /// SetFocusFilterIntent. Drives the visible-node filter applied in refresh()/refreshGlance().
  /// NOT private: AppModel+Search.swift's runSearch() also reads it.
  @ObservationIgnored var activeFocusContext = ""
  /// Last context the forest was built for — so a context change rebuilds it even when the node set
  /// is unchanged (the `fetched != allNodes` guard alone would skip it).
  @ObservationIgnored private var lastForestContext: String?
  @ObservationIgnored private var observationTask: Task<Void, Never>?
  @ObservationIgnored private var spoolWatcher: DirectoryWatcher?
  @ObservationIgnored private var canonicalWatcher: DirectoryWatcher?
  @ObservationIgnored private lazy var refreshDebouncer = Debouncer(interval: 0.15) { [weak self] in
    await self?.refreshFromWatch()
  }
  @ObservationIgnored private lazy var drainDebouncer = Debouncer(interval: 0.15) { [weak self] in
    await self?.drainThenRefreshFromWatch()
  }
  /// Coalesces rapid typing in the .searchable field into one DB read (runSearch), instead of a
  /// full node+loose-end scan per keystroke.
  /// NOT private: AppModel+Search.swift's searchTextChanged() schedules it.
  @ObservationIgnored lazy var searchDebouncer = Debouncer(interval: 0.2) { [weak self] in
    await self?.runSearch()
  }
  @ObservationIgnored private var started = false
  // NOT lazy: rebuilt when the provider preference/config changes (SettingsView), so an in-session
  // switch takes effect on the next narration instead of requiring a relaunch. Bootstrapped cheaply
  // here; `init()` calls rebuildSummaryBuilder() to fold in any configured cloud provider.
  // NOT private: rebuildSummaryBuilder()/narration()/describeNode() live in AppModel+Narration.swift
  // and need to read/write it. Still module-internal — no external exposure change.
  @ObservationIgnored var summaryBuilder = SummaryBuilder(provider: ClaudeCLIProvider())
  /// The raw narration provider, retained so the manual "describe this node" action can call
  /// `NodeDescriber.describe` directly (SummaryBuilder's provider is private). Rebuilt alongside
  /// `summaryBuilder` on a provider/config change.
  @ObservationIgnored var descriptionProvider: any LLMProvider = ClaudeCLIProvider()
  /// The provider kind the current `summaryBuilder` uses — folded into the narration cache key so a
  /// provider/model switch invalidates prose cached under the old provider.
  @ObservationIgnored var providerKind = "claudeCLI"

  /// Persisted narration: prose + the invalidation key it was generated for. Keyed per DB path
  /// (NEW pattern — lastOpenedAt is a single global key today) so throwaway smoke/test stores
  /// don't pollute the real cache. Device-local: narration is a derived, provider-specific
  /// output cache and must not sync.
  struct CachedNarration: Codable { let prose: String; let key: String }
  @ObservationIgnored var narrationCache: [UUID: CachedNarration] = [:]

  /// Bumped on launch + ⌘R (drainThenRefresh). Views key their reload `.task` on it so the OPEN
  /// detail re-narrates after a refresh. The watch-driven refreshDebouncer calls `refresh()` (not
  /// drainThenRefresh), so this never bumps on background liveness updates.
  private(set) var refreshToken = 0

  // MARK: - In-app find
  var searchText: String = ""
  /// ⌘F search scope. `.all` opts archived nodes into EXACT results (semantic "Related" stays
  /// active-only — the semantic index holds no archived content). Observable → drives the scope bar.
  enum SearchScope: Hashable { case active, all }
  var searchScope: SearchScope = .active
  /// NOT private(set): AppModel+Search.swift's runSearch()/clearSearch() write it.
  var searchResults: SearchResults = SearchResults()
  /// Semantic ("Related") hits, populated after the exact search when the Settings toggle is on.
  /// NOT private(set): AppModel+Search.swift's runSearch()/clearSearch() write it.
  var semanticHits: [SemanticHit] = []
  /// The loose-end row a search hit should auto-expand + scroll to. Consumed by LooseEndRow/DetailView.
  var expandedLooseEndID: UUID?
  /// Set by the Find command; RootView observes it to move focus into the .searchable field.
  var focusSearchRequested = false
  // NOT private: AppModel+Search.swift's runSearch()/clearSearch() also read/write these.
  @ObservationIgnored var searchTask: Task<Void, Never>?
  @ObservationIgnored var searchToken = 0
  // Built once; NLContextualEmbedder resolves dimension from the loaded asset at init.
  @ObservationIgnored lazy var embedder: NLContextualEmbedder = NLContextualEmbedder()
  @ObservationIgnored lazy var semanticStore = SemanticIndexStore(
    url: PensievePaths.semanticIndexURL(), dimension: embedder.dimension, embedderVersion: embedder.version)

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
    database = try? openCanonicalDatabase(at: Stores.canonicalURL)
    loadNarrationCache()
    spool = try? CaptureSpool(at: Stores.spoolURL)   // persistent — see the property note above
    activeFocusContext = UserDefaults.standard.string(forKey: FocusFilterDefaults.activeContextKey) ?? ""
    Task { await drainThenRefresh() }

    // Liveness (retires the 3 s Timer). Watches are app-lifetime (this AppModel never deinits),
    // so the menu-bar glyph stays live even when the main window is closed.
    if let database {
      observationTask = Task { [weak self] in
        let observation = ValueObservation.tracking { database in try Event.fetchCount(database) }
        do {
          for try await _ in observation.values(in: database) {
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
    if let database, let spool {
      _ = try? await Ingester(spool: spool, database: database).drain()   // no LLM: spool → events only
    }
    refresh()
    // launch/⌘R: do NOT blanket-clear — cachedNarration/narration are key-aware, so unchanged
    // nodes reuse persisted prose and only changed nodes regenerate. ⌘R force-refresh of the
    // selected node happens in DetailView (force: on same-node token bump).
    refreshToken += 1
    await SpotlightIndexer.reindex(activeContext: activeFocusContext)   // launch + ⌘R
    // Best-effort semantic index catch-up (launch + ⌘R cadence, mirroring SpotlightIndexer above).
    // The sync daemon also runs this periodically; this just keeps ⌘F "Related" fresh sooner after
    // in-app activity. Detached + toggle-gated so it never blocks the UI refresh.
    if AppDefaults.semanticSearchEnabled, let database {
      let store = semanticStore, embedder = self.embedder
      Task.detached { await SemanticIndexer(store: store, embedder: embedder).sync(database) }
    }
  }

  /// Watch-triggered drain: ingest new spool rows on our own connection. The resulting canonical
  /// change trips ValueObservation + the canonical watch → refreshDebouncer. Does NOT clear the
  /// narration cache or bump refreshToken (those are launch/⌘R semantics).
  private func drainThenRefreshFromWatch() async {
    AppLog.app.debug("Spool watcher fired -> drain")
    if let database, let spool {
      _ = try? await Ingester(spool: spool, database: database).drain()
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
  private func filtered(_ smartLists: SmartLists, _ visible: Set<UUID>) -> SmartLists {
    SmartLists(
      whatsNext: smartLists.whatsNext.filter { visible.contains($0.project.id) },
      dormant: smartLists.dormant.filter { visible.contains($0.project.id) },
      recentlyActive: smartLists.recentlyActive.filter { visible.contains($0.project.id) })
  }

  /// Narrow refresh for the menu-bar glance: only what the popover shows (heartbeat + What's Next),
  /// skipping the briefing cards / forest that only the main window needs.
  func refreshGlance() {
    snapshot = MonitorSnapshot.gather(canonical: database, spool: spool)
    guard let database else { return }
    guard let raw = try? SmartLists.compute(database, now: Date()) else { return }
    let visible = NodeContextResolver.visibleNodeIDs(for: activeFocusContext, in: allNodes)
    lists = activeFocusContext.isEmpty ? raw : filtered(raw, visible)
  }

  func refresh() {
    // Heartbeat from the persistent connections (opening fresh ones here would re-fire the store-dir
    // watch into a busy-loop). Works before the database guard: nil connections degrade to a zero snapshot.
    snapshot = MonitorSnapshot.gather(canonical: database, spool: spool)
    guard let database else { return }
    let now = Date()
    let fetched = (try? ProjectQueries.all(database)) ?? allNodes
    let nodesChanged = fetched != allNodes
    if nodesChanged {
      allNodes = fetched
      pruneNarrationCache()
    }
    let visible = NodeContextResolver.visibleNodeIDs(for: activeFocusContext, in: allNodes)

    if let raw = try? SmartLists.compute(database, now: now) {
      lists = activeFocusContext.isEmpty ? raw : filtered(raw, visible)
    }
    if let raw = try? BriefingQueries.cards(database, since: briefingSince, now: now) {
      briefingCards = activeFocusContext.isEmpty ? raw : raw.filter { visible.contains($0.node.id) }
    }
    if nodesChanged || activeFocusContext != lastForestContext {
      let source = activeFocusContext.isEmpty ? allNodes : allNodes.filter { visible.contains($0.id) }
      forest = NodeForest.build(source.filter { $0.state == .active })
      archivedForest = NodeForest.build(source.filter { $0.state == .archived })
      lastForestContext = activeFocusContext
    }
    reviewCount = (try? SalienceReviewQueries.pendingCount(database)) ?? 0
    if isSearching { runSearch() }
  }

  func node(_ id: UUID) -> Node? { allNodes.first { $0.id == id } }

  /// Count of top-level project nodes, for the content-column header.
  var projectCount: Int {
    allNodes.filter { $0.parentID == nil && $0.kind == .project && $0.state == .active }.count
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
    let showArchived = node(id)?.state == .archived
    return children(of: id).filter { ($0.state == .archived) == showArchived }
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
    if case .node(let id) = sidebarSelection, let resultNode = node(id) { return resultNode.name }
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

  // MARK: - Organizing writes (metadata only; each calls the op then refreshes explicitly, because
  // Node-only writes don't change the Event count the liveness ValueObservation tracks). The
  // shared refuse/fail/displayName/defaultKind/presentNewNode/presentEditNode helpers live in
  // AppModel+Organizing.swift alongside the rest of the organizing writes; commitNewNode/updateNode
  // stay here.

  /// Commit the New Node modal: insert fully-formed, select it.
  func commitNewNode(parent parentID: UUID?, fields: NodeFields) {
    guard let database else { return }
    let trimmed = fields.name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    do {
      // nil ⇒ the parent id didn't resolve (deleted under the menu). Name the PARENT: the new node
      // doesn't exist yet, so its own name would be meaningless in the copy.
      guard let new = try NodeCommands.add(database, name: trimmed, kind: fields.kind,
                                           parent: parentID?.uuidString, description: "",
                                           icon: fields.icon, colorTag: fields.colorTag, context: fields.context) else {
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
  func updateNode(_ nodeID: UUID, fields: NodeFields) {
    guard let database else { return }
    let trimmed = fields.name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    let label = displayName(nodeID)
    do {
      var trimmedFields = fields
      trimmedFields.name = trimmed
      let succeeded = try NodeCommands.update(database, nodeID: nodeID, fields: trimmedFields)
      if succeeded { refresh() } else { refuse(String(localized: "rename"), label) }
    } catch {
      fail(String(localized: "rename"), label, error)
    }
  }

}
