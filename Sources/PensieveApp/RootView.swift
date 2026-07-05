// Sources/PensieveApp/RootView.swift
import SwiftUI
import PensieveKit

struct RootView: View {
  @ObservedObject var model: AppModel
  @State private var showPalette = false

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
      } else if model.sidebarSelection == .briefing {
        BriefingView(model: model)
      } else {
        ContentUnavailableView("Select a project", systemImage: "sidebar.left")
      }
    }
    .navigationTitle("Pensieve")
    // A hidden, zero-size button carries the ⌘K shortcut for the key window.
    .background {
      Button("") { showPalette = true }
        .keyboardShortcut("k", modifiers: .command)
        .opacity(0)
        .accessibilityHidden(true)
    }
    .sheet(isPresented: $showPalette) {
      PaletteView(model: model, isPresented: $showPalette)
    }
  }
}
