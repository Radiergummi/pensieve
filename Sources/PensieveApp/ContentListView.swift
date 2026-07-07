// Sources/PensieveApp/ContentListView.swift
import SwiftUI
import PensieveKit

struct ContentListView: View {
  @ObservedObject var model: AppModel

  var body: some View {
    let items = model.nodesForSelection()
    List(items, selection: $model.selectedNodeID) { node in
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
      if items.isEmpty {
        ContentUnavailableView("Nothing here", systemImage: "tray")
      }
    }
  }
}
