// Sources/PensieveApp/NodeOrganizing.swift
import SwiftUI
import PensieveKit

/// The New/Edit node modal (Reminders-style): name, type, color grid, and an emoji / SF-symbol
/// picker. Writes go through AppModel → Kit NodeCommands. Replaces the old inline-rename field and
/// the Change Type submenu.
struct NodeEditor: View {
  @ObservedObject var model: AppModel
  let request: NodeEditRequest
  @Environment(\.dismiss) private var dismiss

  @State private var name = ""
  @State private var kind = NodeKind.project
  @State private var colorTag = ""          // palette name
  @State private var icon = ""              // stored form "sf:x" / "emoji:x"
  @State private var tab: IconTab = .symbol
  enum IconTab: Hashable { case symbol, emoji }

  private static let symbols = [
    "folder", "shippingbox", "arrow.triangle.branch", "lightbulb", "flag", "checklist",
    "tag", "star", "bolt", "book", "hammer", "paintbrush", "cart", "gearshape", "doc.text",
    "calendar", "person", "house", "globe", "leaf", "cup.and.saucer", "gamecontroller",
    "music.note", "camera",
  ]
  private static let emojis = [
    "🚀", "🎯", "💡", "🔧", "📝", "📦", "🌱", "🔥", "⭐️", "🧠", "🎨", "🍲",
    "📚", "🏠", "🌍", "🎮", "🎵", "📷", "💰", "🧪", "⚙️", "🗂", "✅", "🐛",
  ]

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text(isEdit ? "Edit Node" : "New Node").font(.headline)

      Form {
        TextField("Name", text: $name)
        Picker("Type", selection: $kind) {
          ForEach(NodeKind.all, id: \.self) { k in Text(AppearanceStyle.kindLabel(k)).tag(k) }
        }
      }

      VStack(alignment: .leading, spacing: 6) {
        Text("Color").font(.caption).foregroundStyle(.secondary)
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(30)), count: 6), spacing: 10) {
          ForEach(AppearanceStyle.palette, id: \.tag) { entry in
            Circle().fill(entry.color).frame(width: 24, height: 24)
              .overlay { if entry.tag == colorTag { Circle().stroke(Color.primary, lineWidth: 2).padding(-3) } }
              .contentShape(Circle())
              .onTapGesture { colorTag = entry.tag }
          }
        }
      }

      VStack(alignment: .leading, spacing: 6) {
        Picker("", selection: $tab) {
          Text("Symbol").tag(IconTab.symbol)
          Text("Emoji").tag(IconTab.emoji)
        }.pickerStyle(.segmented).labelsHidden()
        iconGrid
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
    .frame(width: 440)
    .onAppear(perform: load)
  }

  private var isEdit: Bool { if case .edit = request.mode { return true }; return false }

  @ViewBuilder private var iconGrid: some View {
    let items = tab == .symbol ? Self.symbols.map { "sf:\($0)" } : Self.emojis.map { "emoji:\($0)" }
    LazyVGrid(columns: Array(repeating: GridItem(.fixed(38)), count: 6), spacing: 10) {
      ForEach(items, id: \.self) { stored in
        cell(stored)
          .frame(width: 34, height: 34)
          .background { if icon == stored { RoundedRectangle(cornerRadius: 7).fill(Color.accentColor.opacity(0.25)) } }
          .contentShape(Rectangle())
          .onTapGesture { icon = stored }
      }
    }
  }

  @ViewBuilder private func cell(_ stored: String) -> some View {
    switch AppearanceIcon.parse(stored) {
    case .sfSymbol(let n): Image(systemName: n).font(.system(size: 18))
    case .emoji(let e):    Text(e).font(.system(size: 20))
    case nil:              EmptyView()
    }
  }

  private func load() {
    switch request.mode {
    case .new(let parent):
      let k = model.defaultKind(under: parent)
      kind = k
      let style = NodeKindStyle.style(for: k)
      colorTag = style.colorTag
      icon = style.icon
      name = ""
    case .edit(let node):
      name = node.name
      kind = node.kind
      let a = node.appearance
      colorTag = a.colorTag
      icon = a.icon.storedString
    }
  }

  private func commit() {
    switch request.mode {
    case .new(let parent):
      model.commitNewNode(parent: parent, name: name, kind: kind, icon: icon, colorTag: colorTag)
    case .edit(let node):
      model.updateNode(node.id, name: name, kind: kind, icon: icon, colorTag: colorTag)
    }
    dismiss()
  }
}

/// The organizing context menu shared by sidebar-tree and content-list rows.
struct NodeContextMenu: View {
  @ObservedObject var model: AppModel
  let node: Node

  var body: some View {
    Button("New Child…") { model.presentNewNode(under: node.id) }
    Button("Edit…") { model.presentEditNode(node) }
    Divider()
    Button("Move to…") { model.movePickerNodeID = node.id }
    Button("Merge into…") { model.mergePickerNodeID = node.id }
    Divider()
    Button("Delete…", role: .destructive) { model.pendingDeleteNodeID = node.id }
      .disabled(!model.canDelete(node.id))
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
    return String(localized: "Merge “\(source)” into “\(target)”? Its sources, activity, and loose ends move to the target, and the original is deleted. This can’t be undone.")
  }
}
