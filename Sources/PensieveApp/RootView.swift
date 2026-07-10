// Sources/PensieveApp/RootView.swift
import SwiftUI
import PensieveKit

struct RootView: View {
  @ObservedObject var model: AppModel
  @Environment(\.openWindow) private var openWindow
  // Bound column visibility so the native NavigationSplitView sidebar toggle (in the sidebar, like
  // Mail) works. The sidebar is fully independent of the provenance panel now.
  @State private var columns = NavigationSplitViewVisibility.all

  @ViewBuilder private var detailColumn: some View {
    if let id = model.selectedNodeID, let node = model.node(id) {
      DetailView(model: model, node: node, showsLooseEnds: model.detailShowsLooseEnds)
    } else if model.sidebarSelection == .briefing {
      BriefingView(model: model)
    } else {
      ContentUnavailableView("Select a project", systemImage: "sidebar.left")
    }
  }

  var body: some View {
    // Mail-like column rules: every column has a min so a divider drag can't corrupt the layout, and
    // sidebar/content have maxes so they can't swallow the detail. The detail carries a MIN ONLY — it
    // stays the flexible column (grows with the window) but has a floor so dragging can't collapse it
    // into a broken state. The native toggle (driven by `columns`) lives in the sidebar, like Mail.
    NavigationSplitView(columnVisibility: $columns) {
      SidebarView(model: model)
        .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 320)
    } content: {
      ContentListView(model: model)
        .navigationSplitViewColumnWidth(min: 240, ideal: 300, max: 420)
    } detail: {
      // Provenance is now shown inline inside each loose-end row (expand to see the surrounding
      // transcript), so the detail is a single flexible column again — no side panel, no `.inspector`.
      detailColumn
        .navigationSplitViewColumnWidth(min: 360, ideal: 800)   // floor only; no max → stays flexible
        .toolbar {
          ToolbarItem(placement: .navigation) {
            Button { model.presentNewNode(under: nil) } label: { Image(systemName: "plus") }
              .help("New Node")
          }
          // Refresh lives on ⌘R and Go ▸ Refresh — kept off the toolbar so the native sidebar toggle
          // isn't pushed into an overflow menu.
        }
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
