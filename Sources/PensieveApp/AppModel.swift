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
  case smartList(SmartListKind)
  case node(UUID)
}

@MainActor
final class AppModel: ObservableObject {
  @Published var lists = SmartLists(whatsNext: [], dormant: [], recentlyActive: [])
  @Published var forest: [NodeForestNode] = []
  @Published var sidebarSelection: SidebarSelection? = .smartList(.whatsNext)
  @Published var selectedNodeID: UUID?
  @Published var snapshot = MonitorSnapshot(status: .notSetUp, lastCaptureAt: nil,
                                            spoolPending: 0, eventCount: 0, looseEndCount: 0)

  private var db: (any DatabaseWriter)?
  private var allNodes: [Node] = []
  private var timer: Timer?

  func start() {
    // Open the canonical store read/write (needed for the launch drain). Missing store degrades to empty.
    db = try? openCanonicalDatabase(at: Stores.canonicalURL)
    Task { await drainThenRefresh() }
    timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
      Task { @MainActor in self?.refresh() }
    }
  }

  private func drainThenRefresh() async {
    if let db, let spool = try? CaptureSpool(at: Stores.spoolURL) {
      _ = try? await Ingester(spool: spool, db: db).drain()   // no LLM: spool → events only
    }
    refresh()
  }

  func refresh() {
    // The heartbeat kernel reads the stores standalone (works even with no canonical store), so
    // gather it here — one poller for the whole window — before the db guard.
    snapshot = MonitorSnapshot.gather(canonicalURL: Stores.canonicalURL, spoolURL: Stores.spoolURL)
    guard let db else { return }
    let now = Date()
    lists = (try? SmartLists.compute(db, now: now)) ?? lists
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

  func detail(for node: Node) -> (status: ProjectStatus, looseEnds: [LooseEndView]) {
    let fallback = ProjectStatus(project: node, recentEvents: [])
    guard let db else { return (fallback, []) }
    let now = Date()
    let status = (try? ProjectQueries.status(db, node: node, limit: 15)) ?? fallback
    let ends = (try? LooseEndQueries.open(db, nodeID: node.id, now: now)) ?? []
    return (status, ends)
  }
}
