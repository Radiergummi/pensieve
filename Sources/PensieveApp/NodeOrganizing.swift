// Sources/PensieveApp/NodeOrganizing.swift
import SwiftUI
import PensieveKit

/// In-place rename field. Shown by a row when `model.renamingNodeID == node.id`. Commits on
/// Enter/blur, cancels on Esc. Editing the node's NAME only — content, never localized.
struct NodeNameField: View {
  @ObservedObject var model: AppModel
  let node: Node
  @State private var draft: String = ""
  @FocusState private var focused: Bool

  var body: some View {
    TextField("", text: $draft)
      .textFieldStyle(.plain)
      .focused($focused)
      .onAppear { draft = node.name; focused = true }
      .onSubmit { model.rename(node.id, to: draft) }          // Enter commits
      .onExitCommand { model.renamingNodeID = nil }            // Esc cancels (no write)
      .onChange(of: focused) { _, isFocused in                 // blur commits (if still renaming)
        if !isFocused && model.renamingNodeID == node.id { model.rename(node.id, to: draft) }
      }
  }
}

/// The organizing context menu shared by sidebar-tree and content-list rows.
struct NodeContextMenu: View {
  @ObservedObject var model: AppModel
  let node: Node

  var body: some View {
    Button("New Child") { model.createNode(under: node.id) }
    Button("Rename") { model.renamingNodeID = node.id }
    Menu("Change Type") {
      ForEach(NodeKindOption.all, id: \.self) { kind in
        Button {
          model.retype(node.id, to: kind)
        } label: {
          // Kind labels are roles → not localized (English, capitalized), per the l10n ledger.
          if node.kind == kind { Label(kind.capitalized, systemImage: "checkmark") }
          else { Text(kind.capitalized) }
        }
      }
    }
  }
}
