// Sources/PensieveApp/ContentListView.swift
import SwiftUI
import PensieveKit

struct ContentListView: View {
  @ObservedObject var model: AppModel
  // A focused leaf's loose ends, loaded off-`body` via `.task` (never a DB query in `body`).
  @State private var looseEnds: [LooseEndView] = []
  @State private var reviewItems: [LooseEndView] = []

  var body: some View {
    let kind = model.middleKind()
    Group {
      switch kind {
      case .nodes(let items):
        nodeList(items)
      case .looseEndsOf:
        looseEndList()
      case .reviewSuggestions:
        reviewList()
      }
    }
    .navigationTitle(model.middleTitle)
    .navigationSubtitle(subtitle(for: kind))
    // Load the focused leaf's loose ends. Re-runs on selection change AND ⌘R (refreshToken),
    // mirroring DetailView's off-body load. Non-leaf kinds clear the list.
    .task(id: MiddleLoadKey(kind: kind, token: model.refreshToken)) {
      switch kind {
      case .looseEndsOf(let id): looseEnds = model.looseEnds(forNode: id)
      case .reviewSuggestions: reviewItems = model.reviewItems()
      case .nodes: looseEnds = []; reviewItems = []
      }
    }
  }

  @ViewBuilder private func nodeList(_ items: [Node]) -> some View {
    List(items, selection: Binding(
      get: { model.selectedNodeID },
      set: { if let id = $0 { model.selectMiddleNode(id) } })) { node in
      HStack(spacing: 10) {
        NodeBadge(node: node, size: 26)
        VStack(alignment: .leading, spacing: 2) {
          Text(node.name)
          Text(AppearanceStyle.kindLabel(node.kind)).font(.caption).foregroundStyle(.secondary)
        }
      }
      .tag(node.id)
      .contextMenu { NodeContextMenu(model: model, node: node) }
    }
    .overlay {
      if items.isEmpty { ContentUnavailableView("Nothing here", systemImage: "tray") }
    }
  }

  @ViewBuilder private func looseEndList() -> some View {
    List {
      ForEach(looseEnds, id: \.looseEnd.id) { view in
        LooseEndRow(view: view, loadProvenance: model.provenance, onLabel: model.setLooseEndLabel)
      }
    }
    .overlay {
      if looseEnds.isEmpty { ContentUnavailableView("None open", systemImage: "checkmark.circle") }
    }
  }

  @ViewBuilder private func reviewList() -> some View {
    List {
      ForEach(reviewItems, id: \.looseEnd.id) { view in
        VStack(alignment: .leading, spacing: 2) {
          if let name = model.node(view.looseEnd.nodeID)?.name {
            Text(name).font(.caption).foregroundStyle(.secondary)
          }
          LooseEndRow(view: view, loadProvenance: model.provenance, onLabel: model.setLooseEndLabel)
        }
      }
    }
    .overlay {
      if reviewItems.isEmpty {
        ContentUnavailableView("No suggestions to review", systemImage: "checklist")
      }
    }
  }

  private func subtitle(for kind: MiddleKind) -> String {
    switch kind {
    case .nodes(let items):
      if case .node = model.sidebarSelection { return String(localized: "\(items.count) strands") }
      return String(localized: "\(model.projectCount) Projects")
    case .looseEndsOf:
      return String(localized: "\(looseEnds.count) loose ends")
    case .reviewSuggestions:
      return String(localized: "\(reviewItems.count) to review")
    }
  }
}

/// A Hashable `.task` id for the middle. Derived from `MiddleKind` WITHOUT hashing the node array —
/// only the leaf id + refresh token matter for reloading loose ends.
private struct MiddleLoadKey: Hashable {
  enum Tag: Hashable { case nodes, looseEnds(UUID), review }
  let tag: Tag
  let token: Int
  init(kind: MiddleKind, token: Int) {
    switch kind {
    case .looseEndsOf(let id): tag = .looseEnds(id)
    case .reviewSuggestions: tag = .review
    case .nodes: tag = .nodes
    }
    self.token = token
  }
}
