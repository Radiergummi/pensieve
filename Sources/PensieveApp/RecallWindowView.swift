// Sources/PensieveApp/RecallWindowView.swift
import SwiftUI
import PensieveKit

/// A focused, single-node recall window (⌘⌥N). Reuses DetailView WITHOUT an inspector
/// (allowsInspector: false) so a loose-end tap here never touches the main window's inspector.
/// Reads the shared AppModel; a cold-restored window may briefly resolve nil before the store
/// loads — it re-renders when @Published forest/allNodes refresh, so the first nil is transient.
struct RecallWindowView: View {
  @ObservedObject var model: AppModel
  let nodeID: UUID

  var body: some View {
    let node = model.node(nodeID)
    Group {
      if let node {
        DetailView(model: model, node: node, allowsInspector: false)
      } else {
        ContentUnavailableView("Project unavailable", systemImage: "questionmark.folder")
      }
    }
    .frame(minWidth: 480, minHeight: 360)
    .navigationTitle(node?.name ?? "Pensieve")
    .task { model.start() }   // idempotent; ensures the store is open on cold restore
  }
}
