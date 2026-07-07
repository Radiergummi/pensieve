// Sources/PensieveApp/NodeOrganizing.swift
import SwiftUI
import AppKit
import PensieveKit

/// The New/Edit node modal (Reminders-style two zones): Name + Type + a compact color row on the
/// left; a large live preview circle + Symbol / Emoji popover buttons on the right. Writes go
/// through AppModel → Kit NodeCommands. The chosen icon keeps the stored "sf:<name>" / "emoji:<g>"
/// form.
struct NodeEditor: View {
  @ObservedObject var model: AppModel
  let request: NodeEditRequest
  @Environment(\.dismiss) private var dismiss

  @State private var name = ""
  @State private var kind = NodeKind.project
  @State private var colorTag = ""          // palette name
  @State private var icon = ""              // stored form "sf:x" / "emoji:x"

  @State private var showSymbolPopover = false
  @State private var symbolQuery = ""
  // Hidden capture field: the system Character Viewer inserts the picked emoji here; onChange
  // extracts the emoji grapheme into `icon` and clears the field.
  @State private var emojiCapture = ""
  @FocusState private var emojiFieldFocused: Bool

  // An expanded SF-symbol set the Symbol popover searches over.
  private static let symbols = [
    "folder", "folder.badge.gearshape", "shippingbox", "arrow.triangle.branch", "lightbulb",
    "flag", "flag.checkered", "checklist", "list.bullet", "tag", "star", "sparkles", "bolt",
    "book", "books.vertical", "hammer", "wrench.and.screwdriver", "paintbrush", "paintpalette",
    "cart", "gearshape", "gearshape.2", "doc.text", "doc.richtext", "calendar", "clock", "person",
    "person.2", "house", "building.2", "globe", "network", "leaf", "cup.and.saucer",
    "gamecontroller", "music.note", "camera", "photo", "terminal", "cpu", "server.rack",
    "chart.bar", "chart.line.uptrend.xyaxis", "envelope", "message", "bubble.left", "map",
    "location", "heart", "flame", "drop", "wand.and.stars", "puzzlepiece", "cube", "shield",
    "lock", "key", "brain", "graduationcap", "briefcase", "creditcard", "banknote",
  ]

  private var filteredSymbols: [String] {
    let q = symbolQuery.trimmingCharacters(in: .whitespaces).lowercased()
    guard !q.isEmpty else { return Self.symbols }
    return Self.symbols.filter { $0.contains(q) }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text(isEdit ? "Edit Node" : "New Node").font(.headline)

      HStack(alignment: .top, spacing: 24) {
        // LEFT: form
        VStack(alignment: .leading, spacing: 14) {
          Form {
            TextField("Name", text: $name)
            Picker("Type", selection: $kind) {
              ForEach(NodeKind.all, id: \.self) { k in Text(AppearanceStyle.kindLabel(k)).tag(k) }
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

        // RIGHT: preview + icon pickers
        VStack(spacing: 12) {
          preview
          HStack(spacing: 8) {
            Button { showSymbolPopover = true } label: { Label("Symbol", systemImage: "square.grid.2x2") }
              .popover(isPresented: $showSymbolPopover, arrowEdge: .bottom) { symbolPopover }
            Button { pickEmoji() } label: { Label("Emoji", systemImage: "face.smiling") }
          }
          .controlSize(.small)
          // Zero-size hidden capture field for the Character Viewer.
          TextField("", text: $emojiCapture)
            .focused($emojiFieldFocused)
            .frame(width: 0, height: 0).opacity(0)
            .onChange(of: emojiCapture) { _, newValue in
              if let g = Self.firstEmoji(in: newValue) { icon = "emoji:\(g)" }
              emojiCapture = ""
            }
        }
        .frame(width: 150)
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
          case .sfSymbol(let n): Image(systemName: n).foregroundStyle(.white)
          case .emoji(let e):    Text(e)
          case nil:              Image(systemName: "questionmark").foregroundStyle(.white)
          }
        }.font(.system(size: 34))
      }
  }

  private var symbolPopover: some View {
    VStack(spacing: 8) {
      TextField("Search symbols", text: $symbolQuery)
        .textFieldStyle(.roundedBorder)
      ScrollView {
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(34)), count: 6), spacing: 8) {
          ForEach(filteredSymbols, id: \.self) { name in
            Image(systemName: name).font(.system(size: 18))
              .frame(width: 30, height: 30)
              .background { if icon == "sf:\(name)" { RoundedRectangle(cornerRadius: 7).fill(Color.accentColor.opacity(0.25)) } }
              .contentShape(Rectangle())
              .onTapGesture { icon = "sf:\(name)"; showSymbolPopover = false }
          }
        }
      }
      .frame(height: 200)
    }
    .padding(12)
    .frame(width: 260)
  }

  /// Focus the hidden capture field, then open the system Character Viewer (emoji-and-symbol palette).
  private func pickEmoji() {
    emojiFieldFocused = true
    DispatchQueue.main.async { NSApp.orderFrontCharacterPalette(nil) }
  }

  /// The first emoji grapheme in `s`, or nil. Ignores ordinary text the Character Viewer might insert.
  private static func firstEmoji(in s: String) -> Character? {
    s.first { ch in
      ch.unicodeScalars.contains { $0.properties.isEmoji && ($0.value > 0x238C || $0.properties.isEmojiPresentation) }
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
