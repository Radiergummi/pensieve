// Sources/PensieveApp/RootView.swift
import SwiftUI
import PensieveKit

/// What makes the Briefing's cards stale: arriving on it, ⌘R, a resolve, or a Focus switch.
private struct BriefingLoadKey: Hashable {
  let isBriefing: Bool
  let token: Int
  let looseEndRevision: Int
  let context: String
}

struct RootView: View {
  @Bindable var model: AppModel
  @Environment(\.openWindow) private var openWindow
  @Environment(\.undoManager) private var undoManager
  // Bound column visibility so the native NavigationSplitView sidebar toggle (in the sidebar, like
  // Mail) works. The sidebar is fully independent of the provenance panel now.
  @State private var columns = NavigationSplitViewVisibility.all
  @FocusState private var isSearchFocused: Bool

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
        .searchable(text: $model.searchText, placement: .sidebar, prompt: Text("Search"))
        // NOTE: `.searchScopes` is deliberately NOT used — under `.sidebar` placement SwiftUI
        // rendered the scope bar twice (sidebar + content column), overlaying content, and left it
        // mounted after the field cleared. The plan's pre-committed fallback (a segmented Picker in
        // the results header, scoped to the search UI) is used instead — see ContentListView.
        .searchFocused($isSearchFocused)
    } detail: {
      // Provenance is now shown inline inside each loose-end row (expand to see the surrounding
      // transcript), so the detail is a single flexible column again — no side panel, no `.inspector`.
      detailColumn
        .navigationSplitViewColumnWidth(min: 360, ideal: 800)   // floor only; no max → stays flexible
        .toolbar {
          ToolbarItem(placement: .navigation) {
            Button { model.presentNewNodeAtSelection() } label: { Image(systemName: "plus") }
              .help("New Node")
          }
          // Refresh lives on ⌘R and Go ▸ Refresh — kept off the toolbar so the native sidebar toggle
          // isn't pushed into an overflow menu.
        }
    }
    // Briefing's cards are a whole-store pass (one query per active node) for a pane that is usually
    // off screen, so `refresh()` computes them only while Briefing IS the selection — this is what
    // loads them on arrival. It lives here rather than in `BriefingView` because the middle column
    // renders the same cards, and `BriefingView` is not mounted when a node is also selected.
    .task(id: BriefingLoadKey(isBriefing: model.sidebarSelection == .briefing,
                              token: model.refreshToken,
                              looseEndRevision: model.looseEndRevision,
                              context: model.activeFocusContext)) {
      if model.sidebarSelection == .briefing { model.loadBriefingCards() }
    }
    .onChange(of: model.openNodeRequest) { _, id in
      guard let id else { return }
      openWindow(id: "recall", value: id)
      model.openNodeRequest = nil
    }
    .onChange(of: model.searchText) { _, _ in model.searchTextChanged() }
    .onChange(of: model.searchScope) { _, _ in
      if model.isSearching { model.runSearch() }
    }
    .onChange(of: model.sidebarSelection) { _, _ in
      if model.isSearching { model.clearSearch() }
    }
    .onChange(of: model.focusSearchRequested) { _, requested in
      if requested { isSearchFocused = true; model.focusSearchRequested = false }
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
    .confirmationDialog(
      model.bulkCloseConfirmationText(),
      isPresented: Binding(get: { model.pendingBulkCloseNodeID != nil },
                           set: { if !$0 { model.pendingBulkCloseNodeID = nil } }),
      titleVisibility: .visible,
      presenting: model.pendingBulkCloseNodeID
    ) { id in
      Button("Mark as Done", role: .destructive) {
        model.closeAllLooseEnds(onNode: id, undoManager: undoManager)
      }
      Button("Cancel", role: .cancel) {}
    } message: { _ in
      Text("They can be reopened individually or with ⌘Z.")
    }
    .alert(
      model.presentedError?.title ?? "",
      isPresented: Binding(get: { model.presentedError != nil },
                           set: { if !$0 { model.presentedError = nil } }),
      presenting: model.presentedError
    ) { _ in
      Button("OK", role: .cancel) {}
    } message: { err in
      Text(err.message)
    }
  }
}
