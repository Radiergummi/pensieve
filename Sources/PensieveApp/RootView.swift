// Sources/PensieveApp/RootView.swift
import SwiftUI
import PensieveKit

struct RootView: View {
  @ObservedObject var model: AppModel
  @Environment(\.openWindow) private var openWindow

  var body: some View {
    NavigationSplitView {
      SidebarView(model: model)
        .navigationSplitViewColumnWidth(min: 200, ideal: 240)
    } content: {
      ContentListView(model: model)
        .navigationSplitViewColumnWidth(min: 240, ideal: 300)
    } detail: {
      if let id = model.selectedNodeID, let node = model.node(id) {
        DetailView(model: model, node: node, allowsInspector: true)
      } else if model.sidebarSelection == .briefing {
        BriefingView(model: model)
      } else {
        ContentUnavailableView("Select a project", systemImage: "sidebar.left")
      }
    }
    .navigationTitle("Pensieve")
    // ⌘K now lives in the "Go" menu (see PensieveApp.commands); the palette state lives on AppModel.
    .sheet(isPresented: $model.showPalette) {
      PaletteView(model: model, isPresented: $model.showPalette)
    }
    .inspector(isPresented: $model.showInspector) {
      // Only query when the inspector is actually shown — this closure is part of RootView.body
      // and re-evaluates on every liveness refresh, so an unconditional detail() runs two DB
      // queries in the background even while the panel is closed.
      let ends = model.showInspector
        ? (model.selectedNodeID.flatMap(model.node).map { model.detail(for: $0).looseEnds } ?? [])
        : []
      InspectorView(model: model, looseEnds: ends)
        .inspectorColumnWidth(min: 260, ideal: 340, max: 500)
    }
    .onChange(of: model.openNodeRequest) { _, id in
      guard let id else { return }
      openWindow(id: "recall", value: id)
      model.openNodeRequest = nil
    }
  }
}
