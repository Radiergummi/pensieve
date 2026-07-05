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
    guard let db else { return }
    let now = Date()
    lists = (try? SmartLists.compute(db, now: now)) ?? lists
    allNodes = (try? ProjectQueries.all(db)) ?? allNodes
    forest = NodeForest.build(allNodes)
  }

  func node(_ id: UUID) -> Node? { allNodes.first { $0.id == id } }

  /// The middle-column list for the current sidebar selection.
  func nodesForSelection() -> [Node] {
    switch sidebarSelection {
    case .smartList(let kind):
      let items: [NextItem]
      switch kind {
      case .whatsNext: items = lists.whatsNext
      case .dormant: items = lists.dormant
      case .recentlyActive: items = lists.recentlyActive
      }
      return items.map(\.project)
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
    guard let db else {
      return (ProjectStatus(project: node, recentEvents: []), [])
    }
    let now = Date()
    let status = (try? ProjectQueries.status(db, node: node, limit: 15))
      ?? ProjectStatus(project: node, recentEvents: [])
    let ends = (try? LooseEndQueries.open(db, nodeID: node.id, now: now)) ?? []
    return (status, ends)
  }
}
