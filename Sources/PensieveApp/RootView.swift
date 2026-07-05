// Sources/PensieveApp/RootView.swift
import SwiftUI
import PensieveKit

struct RootView: View {
  @ObservedObject var model: AppModel

  var body: some View {
    NavigationSplitView {
      SidebarView(model: model)
        .navigationSplitViewColumnWidth(min: 200, ideal: 240)
    } content: {
      ContentListView(model: model)
        .navigationSplitViewColumnWidth(min: 240, ideal: 300)
    } detail: {
      if let id = model.selectedNodeID, let node = model.node(id) {
        DetailView(model: model, node: node)
      } else {
        ContentUnavailableView("Select a project", systemImage: "sidebar.left")
      }
    }
    .navigationTitle("Pensieve")
  }
}

// TEMP STUBS — replaced in Task 4 (SidebarView) and Task 5 (DetailView/ContentListView)
struct ContentListView: View {
  @ObservedObject var model: AppModel
  var body: some View { Text("list").frame(minWidth: 240) }
}
struct DetailView: View {
  @ObservedObject var model: AppModel
  let node: Node
  var body: some View { Text(node.name) }
}
