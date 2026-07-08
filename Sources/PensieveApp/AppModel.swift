// Sources/PensieveApp/AppModel.swift
import Foundation
import SwiftUI
import SQLiteData
import GRDB
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
  case smartList(SmartListKind)
  case node(UUID)
}

/// What the middle column shows for the current sidebar selection. `.looseEndsOf` carries the node id
/// so the view loads its loose ends off-`body` (via `.task`), never in a `body` DB query.
enum MiddleKind: Equatable {
  case nodes([Node])
  case looseEndsOf(UUID)
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

@MainActor
final class AppModel: ObservableObject {
  @Published var lists = SmartLists(whatsNext: [], dormant: [], recentlyActive: [])
  @Published var forest: [NodeForestNode] = []
  @Published var sidebarSelection: SidebarSelection? = .briefing
  @Published var selectedNodeID: UUID?
  /// Drives the New/Edit node modal. nil = closed. Mounted in RootView.
  @Published var editingNode: NodeEditRequest?
  /// Non-nil while a Move/Merge picker sheet is up for that node. Mounted in RootView.
  @Published var movePickerNodeID: UUID?
  @Published var mergePickerNodeID: UUID?
  /// Non-nil while the delete confirmation is presented for that node. Mounted in RootView.
  @Published var pendingDeleteNodeID: UUID?
  @Published var snapshot = MonitorSnapshot(status: .notSetUp, lastCaptureAt: nil,
                                            spoolPending: 0, eventCount: 0, looseEndCount: 0)
  @Published var briefingCards: [BriefingCard] = []
  /// Drives the ⌘K Quick Jump palette. Hoisted here (from RootView @State) so the "Go" menu command
  /// can open it.
  @Published var showPalette = false
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

  private var db: (any DatabaseWriter)?
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
  private var started = false
  // NOT lazy: rebuilt when the provider preference changes (SettingsView), so an in-session
  // provider switch takes effect on the next narration instead of requiring a relaunch.
  private var summaryBuilder = SummaryBuilder(provider: makeDefaultLLMProvider())

  /// Rebuild the narration provider from the current persisted preference. Called by
  /// SettingsView after it writes a new ProviderPreference.
  func rebuildSummaryBuilder() {
    summaryBuilder = SummaryBuilder(provider: makeDefaultLLMProvider())
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

  private static let lastOpenedKey = "pensieve.lastOpenedAt"

  init() {
    let prev = UserDefaults.standard.object(forKey: Self.lastOpenedKey) as? Date
    briefingSince = prev ?? Calendar.current.date(byAdding: .day, value: -7, to: Date())!
    UserDefaults.standard.set(Date(), forKey: Self.lastOpenedKey)
  }

  func start() {
    guard !started else { return }
    started = true
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

    // The SetFocusFilterIntent runs in-process and writes UserDefaults → observe on the main queue.
    NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification,
                                           object: nil, queue: .main) { [weak self] _ in
      Task { @MainActor in self?.focusContextDidChange() }
    }
  }

  /// On-demand equivalent of the launch drain+refresh, for the ⌘R Refresh menu command.
  func refreshNow() async { await drainThenRefresh() }

  private func drainThenRefresh() async {
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
    if let db, let spool {
      _ = try? await Ingester(spool: spool, db: db).drain()
    }
  }

  /// Watch-triggered refresh: recompute state on the main actor, then reindex Spotlight. Kept as one
  /// @MainActor method so the debouncer's `await self?.refreshFromWatch()` needs no `MainActor.run`
  /// wrapper nor a nested `Task` — the nested Task captured the weak-`self` var in concurrently
  /// executing code, which is an error under the Swift 6 language mode.
  private func refreshFromWatch() async {
    refresh()
    await reindexSpotlight()
  }

  private func reindexSpotlight() async { await SpotlightIndexer.reindex(activeContext: activeFocusContext) }

  /// UserDefaults changed — if the active Focus context flipped, re-filter the window + reindex.
  private func focusContextDidChange() {
    let new = UserDefaults.standard.string(forKey: FocusFilterDefaults.activeContextKey) ?? ""
    guard new != activeFocusContext else { return }
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
      forest = NodeForest.build(source)
      lastForestContext = activeFocusContext
    }
  }

  func node(_ id: UUID) -> Node? { allNodes.first { $0.id == id } }

  /// Count of top-level project nodes, for the content-column header.
  var projectCount: Int { allNodes.filter { $0.parentID == nil && $0.kind == NodeKind.project }.count }

  /// The middle column's content for the current `sidebarSelection`. Pure/in-memory (children reads
  /// `allNodes`); the leaf case defers its loose-ends DB read to the view's `.task`.
  func middleKind() -> MiddleKind {
    switch sidebarSelection {
    case .briefing:
      return .nodes(briefingCards.map(\.node))
    case .smartList(let kind):
      return .nodes(lists[keyPath: kind.itemsKeyPath].map(\.project))
    case .node(let id):
      let kids = children(of: id)
      return kids.isEmpty ? .looseEndsOf(id) : .nodes(kids)
    case nil:
      return .nodes([])
    }
  }

  /// Direct children of `id`, name-sorted (thin wrapper over the pure Kit helper).
  func children(of id: UUID) -> [Node] { NodeForest.children(of: id, in: allNodes) }

  /// A middle-column node tap. In tree mode this DRILLS — the tapped node becomes the focused node, so
  /// the middle re-populates with its contents; from a smart list / briefing it only sets the detail
  /// node, leaving the triage list in place.
  func selectMiddleNode(_ id: UUID) {
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
  /// node's loose ends (the focused leaf) — the one-home rule (no duplication).
  var detailShowsLooseEnds: Bool {
    if case .node(let fid) = sidebarSelection, selectedNodeID == fid, children(of: fid).isEmpty {
      return false
    }
    return true
  }

  /// Nodes whose name contains `query` (case-insensitive); empty query returns all. For ⌘K.
  func matchingNodes(_ query: String) -> [Node] {
    let q = query.trimmingCharacters(in: .whitespaces)
    guard !q.isEmpty else { return allNodes }
    return allNodes.filter { $0.name.range(of: q, options: .caseInsensitive) != nil }
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
    return RecallMarkdown.render(node: node, narration: cachedNarration(for: node, events: d.status.recentEvents),
                                 looseEnds: d.looseEnds, events: d.status.recentEvents, now: Date())
  }

  /// Open loose ends for a node — the inspector's slice of `detail(for:)` (no status query).
  /// Loaded once per selection via the inspector's `.task`, never in a view `body`.
  func looseEnds(forNode nodeID: UUID) -> [LooseEndView] {
    guard let db else { return [] }
    return (try? LooseEndQueries.open(db, nodeID: nodeID, now: Date())) ?? []
  }

  // MARK: - Organizing writes (metadata only; each calls the op then refreshes explicitly, because
  // Node-only writes don't change the Event count the liveness ValueObservation tracks).

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
    guard !trimmed.isEmpty,
          let new = try? NodeCommands.add(db, name: trimmed, kind: kind,
                                          parent: parentID?.uuidString, description: "",
                                          icon: icon, colorTag: colorTag, context: context) else { return }
    refresh()
    sidebarSelection = .node(new.id); selectedNodeID = new.id
  }

  /// Commit the Edit modal: atomic name/kind/icon/colorTag update.
  func updateNode(_ nodeID: UUID, name: String, kind: String,
                  icon: String, colorTag: String, context: String) {
    guard let db else { return }
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    _ = try? NodeCommands.update(db, nodeID: nodeID, name: trimmed, kind: kind,
                                 icon: icon, colorTag: colorTag, context: context)
    refresh()
  }

  /// Whether `nodeID` may be deleted (no live source or auto-birthed strand in its subtree → won't resurrect on sync).
  func canDelete(_ nodeID: UUID) -> Bool {
    guard let db else { return false }
    return (try? NodeCommands.subtreeIsActivityBorn(db, nodeID: nodeID)) == false
  }

  func move(_ nodeID: UUID, under newParentID: UUID?) {
    guard let db else { return }
    _ = try? NodeCommands.reparent(db, nodeID: nodeID, newParentID: newParentID)
    refresh()
  }

  func merge(_ sourceID: UUID, into targetID: UUID) {
    guard let db, sourceID != targetID else { return }
    try? ProjectResolver(db: db).group(targetID, into: [sourceID])
    // The source node is gone: move any state that referenced it onto the survivor / clear it.
    if selectedNodeID == sourceID { selectedNodeID = targetID }
    if sidebarSelection == .node(sourceID) { sidebarSelection = .node(targetID) }
    refresh()
  }

  /// Legal Move/Merge targets for `nodeID`: every node except itself and its descendants.
  func moveTargets(for nodeID: UUID) -> [Node] {
    let banned = NodeForest.descendantIDs(of: nodeID, in: allNodes).union([nodeID])
    return allNodes.filter { !banned.contains($0.id) }.sorted { $0.name < $1.name }
  }

  /// Delete a (source-free) node and its subtree via the Kit cascade. Moves selection off it.
  func deleteNode(_ nodeID: UUID) {
    guard let db else { return }
    _ = try? NodeCommands.delete(db, nodeID: nodeID)
    if selectedNodeID == nodeID { selectedNodeID = nil }
    if sidebarSelection == .node(nodeID) { sidebarSelection = .briefing }
    refresh()
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
          entry.key == NarrationCacheKey.make(events: events) else { return nil }
    return entry.prose
  }

  /// The "Last Work Done" narration for `node`. Returns the cached result when its key matches and
  /// `force` is false; otherwise regenerates off-main, stores prose+key, and returns it. `force`
  /// (⌘R on the selected node) bypasses the cache so the user can always refresh a bad recap.
  func narration(for node: Node, events: [Event], force: Bool = false) async -> String? {
    let key = NarrationCacheKey.make(events: events)
    if !force, let entry = narrationCache[node.id], entry.key == key { return entry.prose }
    let text = await summaryBuilder.narrate(project: node, events: events)
    if let text {
      narrationCache[node.id] = CachedNarration(prose: text, key: key)
      saveNarrationCache()
    }
    return text
  }
}
