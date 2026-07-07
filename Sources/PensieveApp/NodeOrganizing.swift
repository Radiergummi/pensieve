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
    Divider()
    Button("Move to…") { model.movePickerNodeID = node.id }
    Button("Merge into…") { model.mergePickerNodeID = node.id }
  }
}

/// Reparent `nodeID` under a chosen node (or to top level). Targets exclude self + descendants.
struct MovePicker: View {
  @ObservedObject var model: AppModel
  let nodeID: UUID
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack {
      List {
        Button("Top level") { model.move(nodeID, under: nil); dismiss() }
        ForEach(model.moveTargets(for: nodeID)) { target in
          Button(target.name) { model.move(nodeID, under: target.id); dismiss() }
        }
      }
      .navigationTitle("Move to…")
      .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
    }
    .frame(minWidth: 320, minHeight: 400)
  }
}

/// Merge `nodeID` into a chosen target (destructive; confirmation required). Targets exclude
/// self + descendants.
struct MergePicker: View {
  @ObservedObject var model: AppModel
  let nodeID: UUID
  @Environment(\.dismiss) private var dismiss
  @State private var pendingTarget: Node?

  var body: some View {
    NavigationStack {
      List(model.moveTargets(for: nodeID)) { target in
        Button(target.name) { pendingTarget = target }
      }
      .navigationTitle("Merge into…")
      .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
    }
    .frame(minWidth: 320, minHeight: 400)
    .confirmationDialog(
      confirmMessage,
      isPresented: Binding(get: { pendingTarget != nil },
                           set: { if !$0 { pendingTarget = nil } }),
      titleVisibility: .visible
    ) {
      Button("Merge", role: .destructive) {
        if let t = pendingTarget { model.merge(nodeID, into: t.id) }
        dismiss()
      }
      Button("Cancel", role: .cancel) { pendingTarget = nil }
    }
  }

  private var confirmMessage: String {
    let source = model.node(nodeID)?.name ?? ""
    let target = pendingTarget?.name ?? ""
    // Chrome format string; the two names are %@ args (content). Each named once → 2 args.
    return String(localized: "Merge “\(source)” into “\(target)”? Its sources, activity, and loose ends move to the target, and the original is deleted. This can’t be undone.")
  }
}
