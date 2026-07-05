// Sources/PensieveApp/ContentListView.swift
import SwiftUI
import PensieveKit

struct ContentListView: View {
  @ObservedObject var model: AppModel

  var body: some View {
    List(model.nodesForSelection(), selection: $model.selectedNodeID) { node in
      VStack(alignment: .leading, spacing: 2) {
        Text(node.name)
        Text(node.kind).font(.caption).foregroundStyle(.secondary)
      }
      .tag(node.id)
    }
    .overlay {
      if model.nodesForSelection().isEmpty {
        ContentUnavailableView("Nothing here", systemImage: "tray")
      }
    }
  }
}
