// Sources/PensieveApp/AppModel.swift
import Foundation
import SwiftUI
import SQLiteData
import PensieveKit

enum SmartListKind: String, CaseIterable, Hashable {
  case whatsNext, dormant, recentlyActive
  var title: String {
    switch self {
    case .whatsNext: return "What's Next"
    case .dormant: return "Dormant"
    case .recentlyActive: return "Recently Active"
    }
  }
  var symbol: String {
    switch self {
    case .whatsNext: return "star"
    case .dormant: return "pause.circle"
    case .recentlyActive: return "dot.radiowaves.left.and.right"
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
  /// "Since when" the Briefing measures movement: the previous launch's timestamp (or 7 days ago on
  /// first run). Fixed for the session so cards don't shift under you while the window is open.
  let briefingSince: Date

  private var db: (any DatabaseWriter)?
  private var allNodes: [Node] = []
  private var timer: Timer?
  private var started = false
  private lazy var summaryBuilder = SummaryBuilder(provider: makeDefaultLLMProvider())
  private var narrationCache: [UUID: String] = [:]
  /// Bumped on launch + ⌘R (drainThenRefresh). Views key their reload `.task` on it so the OPEN
  /// detail re-narrates after a refresh. The 3 s Timer calls `refresh()` (not drainThenRefresh), so
  /// this never bumps per tick.
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
    Task { await drainThenRefresh() }
    timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
      Task { @MainActor in self?.refresh() }
    }
  }

  /// On-demand equivalent of the launch drain+refresh, for the ⌘R Refresh menu command.
  func refreshNow() async { await drainThenRefresh() }

  private func drainThenRefresh() async {
    if let db, let spool = try? CaptureSpool(at: Stores.spoolURL) {
      _ = try? await Ingester(spool: spool, db: db).drain()   // no LLM: spool → events only
    }
    refresh()
    narrationCache.removeAll()   // launch/⌘R: recaps may be stale — regenerate on next open
    refreshToken += 1
    await SpotlightIndexer.reindex()   // launch + ⌘R only (not the 3 s timer, which calls refresh() directly)
  }

  /// Narrow refresh for the menu-bar glance: only what the popover shows (heartbeat + What's Next),
  /// skipping the briefing cards / forest that only the main window needs.
  func refreshGlance() {
    snapshot = MonitorSnapshot.gather(canonicalURL: Stores.canonicalURL, spoolURL: Stores.spoolURL)
    guard let db else { return }
    lists = (try? SmartLists.compute(db, now: Date())) ?? lists
  }

  func refresh() {
    // The heartbeat kernel reads the stores standalone (works even with no canonical store), so
    // gather it here — one poller for the whole window — before the db guard.
    snapshot = MonitorSnapshot.gather(canonicalURL: Stores.canonicalURL, spoolURL: Stores.spoolURL)
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
