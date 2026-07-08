// Sources/PensieveApp/RootView.swift
import SwiftUI
import PensieveKit

struct RootView: View {
  @ObservedObject var model: AppModel
  @Environment(\.openWindow) private var openWindow

  @ViewBuilder private var detailColumn: some View {
    if let id = model.selectedNodeID, let node = model.node(id) {
      DetailView(model: model, node: node, allowsInspector: true, showsLooseEnds: model.detailShowsLooseEnds)
    } else if model.sidebarSelection == .briefing {
      BriefingView(model: model)
    } else {
      ContentUnavailableView("Select a project", systemImage: "sidebar.left")
    }
  }

  var body: some View {
    NavigationSplitView {
      SidebarView(model: model)
        .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 340)
    } content: {
      ContentListView(model: model)
        .navigationSplitViewColumnWidth(min: 280, ideal: 320, max: 460)
    } detail: {
      detailColumn
        .toolbar {
          ToolbarItem(placement: .navigation) {
            Button { model.presentNewNode(under: nil) } label: { Image(systemName: "plus") }
              .help("New Node")
          }
          ToolbarItemGroup(placement: .primaryAction) {
            Button { Task { await model.refreshNow() } } label: { Image(systemName: "arrow.clockwise") }
              .help("Refresh")
            Button { model.showInspector.toggle() } label: { Image(systemName: "sidebar.right") }
              .help("Inspector")
          }
        }
        .navigationSplitViewColumnWidth(min: 380, ideal: 380)
    }
    // ⌘K now lives in the "Go" menu (see PensieveApp.commands); the palette state lives on AppModel.
    .sheet(isPresented: $model.showPalette) {
      PaletteView(model: model, isPresented: $model.showPalette)
    }
    .inspector(isPresented: $model.showInspector) {
      // InspectorView loads its own loose ends via `.task(id: selectedNodeID)` — no DB query in
      // this body closure, which re-evaluates on every liveness refresh.
      InspectorView(model: model)
        .inspectorColumnWidth(min: 260, ideal: 340, max: 500)
    }
    .onChange(of: model.openNodeRequest) { _, id in
      guard let id else { return }
      openWindow(id: "recall", value: id)
      model.openNodeRequest = nil
    }
    .sheet(isPresented: Binding(get: { model.movePickerNodeID != nil },
                                set: { if !$0 { model.movePickerNodeID = nil } })) {
      if let id = model.movePickerNodeID { MovePicker(model: model, nodeID: id) }
    }
    .sheet(isPresented: Binding(get: { model.mergePickerNodeID != nil },
                                set: { if !$0 { model.mergePickerNodeID = nil } })) {
      if let id = model.mergePickerNodeID { MergePicker(model: model, nodeID: id) }
    }
    .sheet(item: $model.editingNode) { req in
      NodeEditor(model: model, request: req)
    }
    .confirmationDialog(
      model.deleteConfirmationText(),
      isPresented: Binding(get: { model.pendingDeleteNodeID != nil },
                           set: { if !$0 { model.pendingDeleteNodeID = nil } }),
      titleVisibility: .visible,
      presenting: model.pendingDeleteNodeID
    ) { id in
      Button("Delete", role: .destructive) { model.deleteNode(id) }
      Button("Cancel", role: .cancel) {}
    }
  }
}
