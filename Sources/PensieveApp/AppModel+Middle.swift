// Sources/PensieveApp/AppModel+Middle.swift
import Foundation
import PensieveKit

/// What the middle column shows, how a tap there moves the selection, and the node-tree accessors
/// those answers are computed from. Split out of `AppModel.swift` when the two loose-end feeds pushed
/// that file past SwiftLint's 400-line cap — the same reason the organizing writes already live in
/// `AppModel+Organizing.swift`. The accessors joined it later, for the same reason and because
/// `middleKind()` and `detailShowsLooseEnds` are `visibleChildren(of:)`'s only callers.
extension AppModel {
  // MARK: - Node-tree accessors
  // In-memory reads over `allNodes`, which `refresh()` keeps current. No DB access.

  /// O(1) through the index `setAllNodes` maintains — this is called once per row by the middle
  /// column's three list builders and by every search result, over a 306-node set.
  func node(_ id: UUID) -> Node? { nodesByID[id] }

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

  /// The Focus-visible node set. Extracted because five surfaces now need it (both refreshes, search
  /// and the two cross-node loose-end feeds) and an inlined copy that drifted would scope one list
  /// differently from the rest.
  func visibleNodeIDs() -> Set<UUID> {
    NodeContextResolver.visibleNodeIDs(for: activeFocusContext, in: allNodes)
  }

  // MARK: - What the middle column shows

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
    case .triage:
      return .triage
    case .completed:
      return .completed
    case .smartList(let kind):
      return .nodes(lists[keyPath: kind.itemsKeyPath].map(\.project))
    case .node(let id):
      let kids = visibleChildren(of: id)
      return kids.isEmpty ? .looseEndsOf(id) : .nodes(kids)
    case nil:
      return .nodes([])
    }
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
}
