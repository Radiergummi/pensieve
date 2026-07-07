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

/// The node kinds the app surfaces in Change Type / new-node creation (all seven declared kinds).
enum NodeKindOption {
  static let all = ["domain", "project", "strand", "concept", "initiative", "task", "topic"]
}

enum SidebarSelection: Hashable {
  case briefing
  case smartList(SmartListKind)
  case node(UUID)
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
  @Published var selectedNodeID: UUID? {
    didSet { if selectedNodeID != oldValue { inspectedLooseEndID = nil } }
  }
  /// The node currently being renamed in place (drives the row's TextField). nil = not renaming.
  @Published var renamingNodeID: UUID?
  /// Non-nil while a Move/Merge picker sheet is up for that node. Mounted in RootView.
  @Published var movePickerNodeID: UUID?
  @Published var mergePickerNodeID: UUID?
  /// Drives the ⌘⌥I provenance inspector (main window only). Toggled by the Go ▸ Inspector command.
  @Published var showInspector = false
  /// The loose end whose surrounding transcript the inspector shows. Written ONLY by the main
  /// window's DetailView (allowsInspector == true); cleared when the main selection changes.
  @Published var inspectedLooseEndID: UUID? {
    didSet { /* no-op; clearing is driven by selectedNodeID below */ }
  }
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
  private var observationTask: Task<Void, Never>?
  private var spoolWatcher: DirectoryWatcher?
  private var canonicalWatcher: DirectoryWatcher?
  private lazy var refreshDebouncer = Debouncer(interval: 0.15) { [weak self] in
    await MainActor.run { self?.refresh(); Task { await self?.reindexSpotlight() } }
  }
  private lazy var drainDebouncer = Debouncer(interval: 0.15) { [weak self] in
    await self?.drainThenRefreshFromWatch()
  }
  private var started = false
  private lazy var summaryBuilder = SummaryBuilder(provider: makeDefaultLLMProvider())
  private var narrationCache: [UUID: String] = [:]
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
    spool = try? CaptureSpool(at: Stores.spoolURL)   // persistent — see the property note above
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
  }

  /// On-demand equivalent of the launch drain+refresh, for the ⌘R Refresh menu command.
  func refreshNow() async { await drainThenRefresh() }

  private func drainThenRefresh() async {
    if let db, let spool {
      _ = try? await Ingester(spool: spool, db: db).drain()   // no LLM: spool → events only
    }
    refresh()
    narrationCache.removeAll()   // launch/⌘R: recaps may be stale — regenerate on next open
    refreshToken += 1
    await SpotlightIndexer.reindex()   // launch + ⌘R only (the watch-driven refreshDebouncer handles the rest)
  }

  /// Watch-triggered drain: ingest new spool rows on our own connection. The resulting canonical
  /// change trips ValueObservation + the canonical watch → refreshDebouncer. Does NOT clear the
  /// narration cache or bump refreshToken (those are launch/⌘R semantics).
  private func drainThenRefreshFromWatch() async {
    if let db, let spool {
      _ = try? await Ingester(spool: spool, db: db).drain()
    }
  }

  private func reindexSpotlight() async { await SpotlightIndexer.reindex() }

  /// Narrow refresh for the menu-bar glance: only what the popover shows (heartbeat + What's Next),
  /// skipping the briefing cards / forest that only the main window needs.
  func refreshGlance() {
    snapshot = MonitorSnapshot.gather(canonical: db, spool: spool)
    guard let db else { return }
    lists = (try? SmartLists.compute(db, now: Date())) ?? lists
  }

  func refresh() {
    // Heartbeat from the persistent connections (opening fresh ones here would re-fire the store-dir
    // watch into a busy-loop). Works before the db guard: nil connections degrade to a zero snapshot.
    snapshot = MonitorSnapshot.gather(canonical: db, spool: spool)
    guard let db else { return }
    let now = Date()
    lists = (try? SmartLists.compute(db, now: now)) ?? lists
    briefingCards = (try? BriefingQueries.cards(db, since: briefingSince, now: now)) ?? briefingCards
    let fetched = (try? ProjectQueries.all(db)) ?? allNodes
    if fetched != allNodes {   // rebuild the forest only when the node set actually changed
      allNodes = fetched
      forest = NodeForest.build(allNodes)
    }
  }

  func node(_ id: UUID) -> Node? { allNodes.first { $0.id == id } }

  /// The middle-column list for the current sidebar selection.
  func nodesForSelection() -> [Node] {
    switch sidebarSelection {
    case .briefing:
      return briefingCards.map(\.node)
    case .smartList(let kind):
      return lists[keyPath: kind.itemsKeyPath].map(\.project)
    case .node(let id):
      // A tree pick: show that node plus its direct child strands.
      guard let selected = node(id) else { return [] }
      let children = allNodes.filter { $0.parentID == id }.sorted { $0.name < $1.name }
      return [selected] + children
    case nil:
      return []
    }
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

  // MARK: - Organizing writes (metadata only; each calls the op then refreshes explicitly, because
  // Node-only writes don't change the Event count the liveness ValueObservation tracks).

  /// Default kind for a new node: a child of a project/domain is a strand; everything else a project.
  private func defaultKind(under parentID: UUID?) -> String {
    guard let parentID, let parent = node(parentID) else { return "project" }
    return (parent.kind == "project" || parent.kind == "domain") ? "strand" : "project"
  }

  /// Create a node (nil parent = top level), select it into the middle list, and enter inline rename.
  /// Renaming happens in the flat content list (OutlineGroup can't be force-expanded), so for a child
  /// we select the *parent* — the list shows parent + children, including the new one.
  func createNode(under parentID: UUID?) {
    guard let db else { return }
    guard let new = try? NodeCommands.add(db, name: "New Node",
                                          kind: defaultKind(under: parentID),
                                          parent: parentID?.uuidString, description: "") else { return }
    refresh()
    if let parentID {
      sidebarSelection = .node(parentID); selectedNodeID = parentID
    } else {
      sidebarSelection = .node(new.id); selectedNodeID = new.id
    }
    renamingNodeID = new.id
  }

  func rename(_ nodeID: UUID, to newName: String) {
    renamingNodeID = nil
    let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let db, !trimmed.isEmpty else { return }
    _ = try? NodeCommands.rename(db, node: nodeID.uuidString, to: trimmed)
    refresh()
  }

  func retype(_ nodeID: UUID, to kind: String) {
    guard let db else { return }
    _ = try? NodeCommands.retype(db, node: nodeID.uuidString, to: kind)
    refresh()
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
    if renamingNodeID == sourceID { renamingNodeID = nil }
    refresh()
  }

  /// Legal Move/Merge targets for `nodeID`: every node except itself and its descendants.
  func moveTargets(for nodeID: UUID) -> [Node] {
    let banned = NodeForest.descendantIDs(of: nodeID, in: allNodes).union([nodeID])
    return allNodes.filter { !banned.contains($0.id) }.sorted { $0.name < $1.name }
  }

  /// Surrounding-transcript provenance for a loose end, resolved off the main actor (file I/O).
  /// nil only when the source event is missing; a present-but-unavailable transcript returns a
  /// ProvenanceContext with `transcriptAvailable == false`.
  func provenance(for looseEnd: LooseEnd) async -> ProvenanceContext? {
    guard let db else { return nil }
    return try? await Task.detached { try ProvenanceQueries.context(db, looseEnd: looseEnd) }.value
  }

  /// Cached narration for `node`, if generated this session. Synchronous — lets the view render a
  /// cached recap instantly, with no spinner.
  func cachedNarration(for node: Node) -> String? { narrationCache[node.id] }

  /// The "Last Work Done" narration for `node`. Returns a session-cached result instantly; otherwise
  /// generates it off the main actor via the Sendable SummaryBuilder, caches a non-nil result, and
  /// returns it. nil when there's nothing to narrate or no provider is reachable (failures are not
  /// cached, so a later ⌘R/open can still produce one).
  func narration(for node: Node, events: [Event]) async -> String? {
    if let cached = narrationCache[node.id] { return cached }
    let text = await summaryBuilder.narrate(project: node, events: events)
    if let text { narrationCache[node.id] = text }
    return text
  }
}
