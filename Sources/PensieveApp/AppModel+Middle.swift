// Sources/PensieveApp/AppModel+Middle.swift
import Foundation
import PensieveKit

/// What the middle column shows, and how a tap there moves the selection. Split out of
/// `AppModel.swift` when the two loose-end feeds pushed that file past SwiftLint's 400-line cap —
/// the same reason the organizing writes already live in `AppModel+Organizing.swift`.
extension AppModel {
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
