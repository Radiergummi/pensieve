// Sources/PensieveApp/NodeOrganizing.swift
import SwiftUI
import PensieveKit

/// The New/Edit node modal (Reminders-style two zones): Name + Type + a compact color row on the
/// left; a large live preview circle + Symbol / Emoji popover buttons on the right. Writes go
/// through AppModel → Kit NodeCommands. The chosen icon keeps the stored "sf:<name>" / "emoji:<g>"
/// form.
struct NodeEditor: View {
  var model: AppModel
  let request: NodeEditRequest
  @Environment(\.dismiss) private var dismiss

  @State private var name = ""
  @State private var kind = NodeKind.project
  @State private var colorTag = ""          // palette name
  @State private var icon = ""              // stored form "sf:x" / "emoji:x"
  @State private var context = ""           // "" = unset (inherit); else NodeContext.work/.personal

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text(isEdit ? "Edit Node" : "New Node").font(.headline)

      HStack(alignment: .top, spacing: 24) {
        // LEFT: form
        VStack(alignment: .leading, spacing: 14) {
          Form {
            TextField("Name", text: $name)
            Picker("Type", selection: $kind) {
              ForEach(NodeKind.all, id: \.self) { nodeKind in Text(AppearanceStyle.kindLabel(nodeKind)).tag(nodeKind) }
            }
            Picker("Context", selection: $context) {
              Text("Unset").tag("")
              Text("Work").tag(NodeContext.work)
              Text("Personal").tag(NodeContext.personal)
            }
          }
          VStack(alignment: .leading, spacing: 6) {
            Text("Color").font(.caption).foregroundStyle(.secondary)
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(28)), count: 6), spacing: 8) {
              ForEach(AppearanceStyle.palette, id: \.tag) { entry in
                Circle().fill(entry.color).frame(width: 22, height: 22)
                  .overlay { if entry.tag == colorTag { Circle().stroke(Color.primary, lineWidth: 2).padding(-3) } }
                  .contentShape(Circle())
                  .onTapGesture { colorTag = entry.tag }
              }
            }
          }
        }

        // RIGHT: preview + icon toggles
        VStack(spacing: 12) {
          preview
          Text("Symbol").metaText()
          IconToggleRow(icon: $icon, tint: AppearanceStyle.color(colorTag))
        }
        .frame(width: 160)
      }

      HStack {
        Spacer()
        Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
        Button("Save") { commit() }
          .keyboardShortcut(.defaultAction)
          .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
      }
    }
    .padding(20)
    .frame(width: 480)
    .onAppear(perform: load)
  }

  private var isEdit: Bool { if case .edit = request.mode { return true }; return false }

  private var preview: some View {
    Circle().fill(AppearanceStyle.color(colorTag)).frame(width: 72, height: 72)
      .overlay {
        Group {
          switch AppearanceIcon.parse(icon) {
          case .sfSymbol(let symbolName): Image(systemName: symbolName).foregroundStyle(.white)
          case .emoji(let emoji):    Text(emoji)
          case nil:              Image(systemName: "questionmark").foregroundStyle(.white)
          }
        }.font(.system(size: 34))
      }
  }

  private func load() {
    switch request.mode {
    case .new(let parent):
      let defaultKind = model.defaultKind(under: parent)
      kind = defaultKind
      let style = NodeKindStyle.style(for: defaultKind)
      colorTag = style.colorTag
      icon = style.icon
      name = ""
      context = ""
    case .edit(let node):
      name = node.name
      kind = node.kind
      let appearance = node.appearance
      colorTag = appearance.colorTag
      icon = appearance.icon.storedString
      context = node.context
    }
  }

  private func commit() {
    let fields = NodeFields(name: name, kind: kind, icon: icon, colorTag: colorTag, context: context)
    switch request.mode {
    case .new(let parent):
      model.commitNewNode(parent: parent, fields: fields)
    case .edit(let node):
      model.updateNode(node.id, fields: fields)
    }
    dismiss()
  }
}

/// The organizing context menu shared by sidebar-tree and content-list rows.
struct NodeContextMenu: View {
  var model: AppModel
  let node: Node

  var body: some View {
    // Not offered on an archived row: a new child is created "active" (the Node default), which
    // would immediately become a phantom top-level root under a still-archived parent.
    if node.state != .archived {
      Button("New Child…") { model.presentNewNode(under: node.id) }
    }
    Button("Edit…") { model.presentEditNode(node) }
    Divider()
    ShareLink("Share Recall…", item: model.recallMarkdown(for: node))
    Divider()
    Button("Move to…") { model.movePickerNodeID = node.id }
    Button("Merge into…") { model.mergePickerNodeID = node.id }
    Divider()
    if node.state == .archived {
      Button("Unarchive") { model.unarchive(node.id) }
    } else {
      Button("Archive") { model.archive(node.id) }
    }
    Button("Delete…", role: .destructive) { model.pendingDeleteNodeID = node.id }
      .disabled(!model.canDelete(node.id))
  }
}

/// Reparent `nodeID` under a chosen node (or to top level). Targets exclude self + descendants.
struct MovePicker: View {
  var model: AppModel
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
  var model: AppModel
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
        if let targetNode = pendingTarget { model.merge(nodeID, into: targetNode.id) }
        dismiss()
      }
      Button("Cancel", role: .cancel) { pendingTarget = nil }
    }
  }

  private var confirmMessage: String {
    let source = model.node(nodeID)?.name ?? ""
    let target = pendingTarget?.name ?? ""
    return String(localized: """
      Merge “\(source)” into “\(target)”? Its sources, activity, and loose ends move to the target, and \
      the original is deleted. This can’t be undone.
      """)
  }
}
