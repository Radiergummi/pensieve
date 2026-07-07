# Visual Identity — Plan B (PensieveApp surfaces) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. **Plan A (Kit foundation) must be merged first** — Plan B consumes `Node.appearance`, `AppearanceIcon`, `NodeKindStyle`, `EventSourceStyle`, `NodeCommands.add(…, icon:, colorTag:)`, `NodeCommands.update`, `NodeCommands.delete`, `NodeCommands.subtreeHasSources`.

**Goal:** Apply the visual-identity foundation across the three-pane app: a New/Edit modal (replacing inline-rename + Change Type), a footer-clash fix, collapsible sidebar sections, node icon/color badges everywhere, a kind-label + state-orb header, manual delete, a GitHub-style activity timeline, and German localization.

**Architecture:** A thin app-side `AppearanceStyle` resolver maps Kit strings → SwiftUI `Color`/`Image`/localized `Text`, plus a shared `NodeBadge` view. All writes go through the Kit `NodeCommands` from Plan A, wrapped by thin `AppModel` methods that call `refresh()`. Views stay thin; the app has no unit tests, so each task verifies by `xcodebuild` build + a non-blocking smoke-launch of the inner binary.

**Tech Stack:** SwiftUI (macOS 15 target), XcodeGen + Xcode 26.6, PensieveKit (local SwiftPM package).

## Global Constraints

- **The app has no unit tests.** Verify every task with the **build + smoke recipe** below.
- Keep derivation in tested PensieveKit; keep views thin. App reads are read-only; the only canonical writer is `Ingester.drain()` **plus** the Kit `NodeCommands` organizing writes.
- **Prefer platform primitives** (`.commands`, `Section(isExpanded:)`, `.sheet(item:)`, `.confirmationDialog`) over hand-built equivalents.
- **Localization is chrome-only.** Node names, loose-end quotes, event summaries, descriptions, transcript text are **never** localized. `xcodebuild` does NOT auto-populate `Localizable.xcstrings` — author/reconcile keys by hand.
- Deployment target is macOS 15 (`project.yml`); `Package.swift` stays `.macOS(.v14)` (all app code is app-target-only).
- Commit messages: use `git commit -F` (backticks in `-m` get shell-executed). Keep the `Co-Authored-By:` + `Claude-Session:` trailers.

### Build + smoke recipe (used by every task's verify step)

```bash
# Build the app bundle.
xcodegen generate
xcodebuild -project Pensieve.xcodeproj -scheme Pensieve -configuration Debug \
  -derivedDataPath ./.build-xcode build 2>&1 | tail -8
# Expect: "** BUILD SUCCEEDED **"

# Non-blocking smoke-launch of the INNER binary with throwaway stores, then kill.
BIN="./.build-xcode/Build/Products/Debug/Pensieve.app/Contents/MacOS/Pensieve"
PENSIEVE_DB="/tmp/vi-smoke.sqlite" PENSIEVE_CAPTURE_DB="/tmp/vi-smoke-cap.sqlite" \
  "$BIN" >/tmp/vi-smoke.log 2>&1 &
SMOKE_PID=$!; sleep 3; kill "$SMOKE_PID" 2>/dev/null
echo "--- smoke log ---"; cat /tmp/vi-smoke.log
# Expect: no crash/backtrace in the log (a clean launch prints little or nothing).
```

*(If the harness blocks a foreground `sleep`, launch with the Bash `run_in_background` option instead, wait briefly, then kill the PID.)*

---

### Task B1: `AppearanceStyle` resolver + `NodeBadge`

**Files:**
- Create: `Sources/PensieveApp/AppearanceStyle.swift`

**Interfaces:**
- Consumes (Plan A): `NodeKind`, `CaptureKind`, `AppearanceIcon`, `Node.appearance`.
- Produces:
  - `enum AppearanceStyle` with: `static let palette: [(tag: String, color: Color)]`; `static func color(_ tag: String) -> Color`; `static func kindLabel(_ kind: String) -> LocalizedStringResource`; `static func sourceLabel(_ eventKind: String) -> LocalizedStringResource`; `static func stateLabel(_ state: String) -> LocalizedStringResource`; `static func stateColor(_ state: String) -> Color`.
  - `struct NodeBadge: View { let node: Node; var size: CGFloat = 22 }`.

- [ ] **Step 1: Create the resolver + badge**

Create `Sources/PensieveApp/AppearanceStyle.swift`:

```swift
// Sources/PensieveApp/AppearanceStyle.swift
import SwiftUI
import PensieveKit

/// App-side bridge from Kit's SwiftUI-free identity strings to SwiftUI values, plus the localized
/// chrome labels for kinds/sources/states. One place, reused by sidebar, list, header, timeline.
enum AppearanceStyle {
  /// The fixed Reminders-style palette. A `colorTag` (stored on Node or returned by the Kit style
  /// tables) maps to a Color here; an unknown tag falls back to the accent color.
  static let palette: [(tag: String, color: Color)] = [
    ("red", .red), ("orange", .orange), ("yellow", .yellow), ("green", .green),
    ("mint", .mint), ("teal", .teal), ("blue", .blue), ("indigo", .indigo),
    ("purple", .purple), ("pink", .pink), ("brown", .brown), ("gray", .gray),
  ]

  static func color(_ tag: String) -> Color {
    palette.first { $0.tag == tag }?.color ?? .accentColor
  }

  /// Localized kind label (chrome). English literals double as the String Catalog keys.
  static func kindLabel(_ kind: String) -> LocalizedStringResource {
    switch kind {
    case NodeKind.domain:     return "Domain"
    case NodeKind.project:    return "Project"
    case NodeKind.strand:     return "Strand"
    case NodeKind.concept:    return "Concept"
    case NodeKind.initiative: return "Initiative"
    case NodeKind.task:       return "Task"
    case NodeKind.topic:      return "Topic"
    default:                  return "Project"
    }
  }

  /// Localized source label (chrome) for an event's `CaptureKind`.
  static func sourceLabel(_ eventKind: String) -> LocalizedStringResource {
    switch eventKind {
    case CaptureKind.gitCommit:                        return "Git Commit"
    case CaptureKind.gitCheckout:                      return "Git Checkout"
    case CaptureKind.ccSession, CaptureKind.ccSessionStart: return "Claude Code Session"
    default:                                           return "Activity"
    }
  }

  static func stateLabel(_ state: String) -> LocalizedStringResource {
    switch state {
    case "muted":    return "Muted"
    case "archived": return "Archived"
    default:         return "Active"
    }
  }

  static func stateColor(_ state: String) -> Color {
    switch state {
    case "muted":    return .orange
    case "archived": return .gray
    default:         return .green
    }
  }
}

/// A node's effective icon in a colored rounded-rect badge. Reused in the sidebar tree, the middle
/// list, and the detail header.
struct NodeBadge: View {
  let node: Node
  var size: CGFloat = 22

  var body: some View {
    let a = node.appearance
    RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
      .fill(AppearanceStyle.color(a.colorTag))
      .frame(width: size, height: size)
      .overlay {
        Group {
          switch a.icon {
          case .sfSymbol(let name): Image(systemName: name).foregroundStyle(.white)
          case .emoji(let e):       Text(e)
          }
        }
        .font(.system(size: size * 0.55))
      }
  }
}
```

- [ ] **Step 2: Build (smoke not needed — no runtime surface yet)**

Run the **build** portion of the recipe.
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Commit**

```bash
git add Sources/PensieveApp/AppearanceStyle.swift
git commit -F - <<'EOF'
feat(app): AppearanceStyle resolver + NodeBadge

Bridges Kit's SwiftUI-free identity strings to Color/Image and localized
kind/source/state labels; shared NodeBadge view.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01GsAu7rTTdD77k3xZHZrhm4
EOF
```

---

### Task B2: Sidebar footer material (#1) + collapsible sections (#2)

**Files:**
- Modify: `Sources/PensieveApp/SidebarView.swift`

**Interfaces:**
- No new public API. Adds two `@AppStorage` flags local to `SidebarView`; gives `StatusFooter` an opaque background.

- [ ] **Step 1: Make the two sections collapsible**

In `Sources/PensieveApp/SidebarView.swift`, add two `@AppStorage` properties to `SidebarView` (right after `@ObservedObject var model`):

```swift
  @AppStorage("sidebar.smartLists.expanded") private var smartExpanded = true
  @AppStorage("sidebar.projects.expanded") private var projectsExpanded = true
```

Then change the two `Section` headers to the collapsible (`isExpanded:`) form:

```swift
      Section("Smart Lists", isExpanded: $smartExpanded) {
        smartRow(.whatsNext, count: model.lists.whatsNext.count)
        smartRow(.dormant, count: model.lists.dormant.count)
        smartRow(.recentlyActive, count: model.lists.recentlyActive.count)
      }
      Section("Projects", isExpanded: $projectsExpanded) {
        OutlineGroup(model.forest, children: \.childrenIfAny) { item in
          nodeRow(item)
        }
      }
```

- [ ] **Step 2: Fix the footer clash (#1) with an opaque background**

In the same file, change `StatusFooter.body`'s modifier chain so the material paints behind the full-width footer (so list rows scroll *under* it instead of showing through):

```swift
    .padding(.horizontal, 12).padding(.vertical, 8)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(.bar)
```

- [ ] **Step 3: Build + smoke**

Run the full **build + smoke recipe**.
Expected: `** BUILD SUCCEEDED **`; smoke log clean.

- [ ] **Step 4: Commit**

```bash
git add Sources/PensieveApp/SidebarView.swift
git commit -F - <<'EOF'
feat(app): collapsible sidebar sections + footer material fix

Smart Lists / Projects are Section(isExpanded:) persisted in AppStorage;
StatusFooter gets a .bar background so list rows no longer clash with it.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01GsAu7rTTdD77k3xZHZrhm4
EOF
```

> **Human-verify carry:** collapse/expand persists across relaunch; footer no longer overlaps the last project row.

---

### Task B3: New/Edit modal (`NodeEditor`) + AppModel wiring; remove inline-rename & Change Type

**Files:**
- Modify: `Sources/PensieveApp/AppModel.swift`
- Rewrite: `Sources/PensieveApp/NodeOrganizing.swift` (remove `NodeNameField`; add `NodeEditor`; rework `NodeContextMenu`)
- Modify: `Sources/PensieveApp/RootView.swift` (mount the modal; toolbar "+" → modal)
- Modify: `Sources/PensieveApp/ContentListView.swift` (drop the rename branch; badge added in B5)
- Modify: `Sources/PensieveApp/SidebarView.swift` (drop the rename branch)
- Modify: `Sources/PensieveApp/PensieveApp.swift` (⌘N → modal)

**Interfaces:**
- Consumes (Plan A): `NodeCommands.add(…, icon:, colorTag:)`, `NodeCommands.update`, `NodeKind`, `NodeKindStyle`, `AppearanceIcon`, `Node.appearance`.
- Produces on `AppModel`: `struct NodeEditRequest: Identifiable` (nested); `@Published var editingNode: NodeEditRequest?`; `func presentNewNode(under:)`, `func presentEditNode(_:)`, `func commitNewNode(parent:name:kind:icon:colorTag:)`, `func updateNode(_:name:kind:icon:colorTag:)`; `func defaultKind(under:)` becomes non-private. **Removes** `createNode`, `rename`, `retype`, `renamingNodeID`.
- Produces: `struct NodeEditor: View`.

- [ ] **Step 1: AppModel — add the edit-request model and commit methods; remove the old ones**

In `Sources/PensieveApp/AppModel.swift`:

(a) Add a top-level type near `SidebarSelection` (before `@MainActor final class AppModel`):

```swift
/// A New/Edit modal request. Identifiable so it drives `.sheet(item:)`.
struct NodeEditRequest: Identifiable {
  enum Mode { case new(parent: UUID?); case edit(Node) }
  let mode: Mode
  var id: String {
    switch mode {
    case .new(let p): return "new-\(p?.uuidString ?? "root")"
    case .edit(let n): return "edit-\(n.id.uuidString)"
    }
  }
}
```

(b) Add a published property (near `renamingNodeID`, which you will delete):

```swift
  /// Drives the New/Edit node modal. nil = closed. Mounted in RootView.
  @Published var editingNode: NodeEditRequest?
```

(c) **Delete** `@Published var renamingNodeID: UUID?` and its doc comment.

(d) In `merge(_:into:)`, **delete** the line `if renamingNodeID == sourceID { renamingNodeID = nil }`.

(e) Make the existing `defaultKind` visible to the modal: in `private func defaultKind(under parentID: UUID?) -> String`, **remove the `private` keyword** (leave the body unchanged). Do NOT re-declare it below.

(f) **Replace** the `createNode(under:)`, `rename(_:to:)`, and `retype(_:to:)` methods (the block from `func createNode` through the end of `retype`) with:

```swift
  /// Open the New Node modal (replaces the old immediate-insert + inline-rename flow → fixes #3).
  func presentNewNode(under parentID: UUID?) { editingNode = NodeEditRequest(mode: .new(parent: parentID)) }
  /// Open the Edit modal for an existing node.
  func presentEditNode(_ node: Node) { editingNode = NodeEditRequest(mode: .edit(node)) }

  /// Commit the New Node modal: insert fully-formed, select it.
  func commitNewNode(parent parentID: UUID?, name: String, kind: String, icon: String, colorTag: String) {
    guard let db else { return }
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty,
          let new = try? NodeCommands.add(db, name: trimmed, kind: kind,
                                          parent: parentID?.uuidString, description: "",
                                          icon: icon, colorTag: colorTag) else { return }
    refresh()
    sidebarSelection = .node(new.id); selectedNodeID = new.id
  }

  /// Commit the Edit modal: atomic name/kind/icon/colorTag update.
  func updateNode(_ nodeID: UUID, name: String, kind: String, icon: String, colorTag: String) {
    guard let db else { return }
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    _ = try? NodeCommands.update(db, nodeID: nodeID, name: trimmed, kind: kind, icon: icon, colorTag: colorTag)
    refresh()
  }
```

- [ ] **Step 2: Rewrite `NodeOrganizing.swift` — drop `NodeNameField`, add `NodeEditor`, rework the menu**

Replace the whole `Sources/PensieveApp/NodeOrganizing.swift` with:

```swift
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
```

*(The `pendingDeleteNodeID`/`canDelete` references compile only after Task B4 adds them to AppModel; do B4 immediately after this task, or add the two AppModel members now. To keep this task independently buildable, add the two members in Step 3 below.)*

- [ ] **Step 3: Add the delete stubs AppModel needs so this task builds**

In `Sources/PensieveApp/AppModel.swift`, add (full behavior lands in B4):

```swift
  /// Non-nil while the delete confirmation is presented for that node. Mounted in RootView.
  @Published var pendingDeleteNodeID: UUID?

  /// Whether `nodeID` may be deleted (no live source in its subtree → won't resurrect on sync).
  func canDelete(_ nodeID: UUID) -> Bool {
    guard let db else { return false }
    return (try? NodeCommands.subtreeHasSources(db, nodeID: nodeID)) == false
  }
```

- [ ] **Step 4: Mount the modal + repoint the toolbar/⌘N; drop the rename branches**

(a) In `Sources/PensieveApp/RootView.swift`, add the modal sheet (after the merge-picker sheet):

```swift
    .sheet(item: $model.editingNode) { req in
      NodeEditor(model: model, request: req)
    }
```

and change the toolbar "+" action:

```swift
      ToolbarItem {
        Button { model.presentNewNode(under: nil) } label: { Image(systemName: "plus") }
          .help("New Node")
      }
```

(b) In `Sources/PensieveApp/PensieveApp.swift`, change the New Node command:

```swift
        Button("New Node") { model.presentNewNode(under: nil) }
          .keyboardShortcut("n", modifiers: .command)
```

(c) In `Sources/PensieveApp/ContentListView.swift`, replace the `if model.renamingNodeID … else …` block with just the name text (badge comes in B5):

```swift
      VStack(alignment: .leading, spacing: 2) {
        Text(node.name)
        Text(node.kind).font(.caption).foregroundStyle(.secondary)
      }
      .tag(node.id)
      .contextMenu { NodeContextMenu(model: model, node: node) }
```

(d) In `Sources/PensieveApp/SidebarView.swift`, replace the `nodeRow` `Group { if renaming … }` with the plain label (badge comes in B5):

```swift
  @ViewBuilder private func nodeRow(_ item: NodeForestNode) -> some View {
    Label(item.node.name, systemImage: symbol(for: item.node.kind))
      .tag(SidebarSelection.node(item.node.id))
      .contextMenu { NodeContextMenu(model: model, node: item.node) }
  }
```

- [ ] **Step 5: Build + smoke**

Run the full **build + smoke recipe**.
Expected: `** BUILD SUCCEEDED **`; smoke log clean. *(If the build reports `NodeNameField` still referenced, ensure every reference was removed in Steps 2 & 4.)*

- [ ] **Step 6: Commit**

```bash
git add Sources/PensieveApp/AppModel.swift Sources/PensieveApp/NodeOrganizing.swift Sources/PensieveApp/RootView.swift Sources/PensieveApp/ContentListView.swift Sources/PensieveApp/SidebarView.swift Sources/PensieveApp/PensieveApp.swift
git commit -F - <<'EOF'
feat(app): New/Edit node modal (name/type/color/icon)

Reminders-style NodeEditor replaces immediate-insert + inline-rename and
the Change Type submenu. Toolbar + / ⌘N / context "New Child…" / "Edit…"
open it; writes go through Kit NodeCommands.add/update. Adds delete stubs
(canDelete/pendingDeleteNodeID) wired fully in the next task.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01GsAu7rTTdD77k3xZHZrhm4
EOF
```

> **Human-verify carry:** toolbar "+"/⌘N opens a New Node modal; picking a color+icon and Save creates a fully-formed node (no empty placeholder); Edit… on a node pre-fills its values and Save updates them; Cancel writes nothing.

---

### Task B4: Manual delete — confirmation + AppModel wiring

**Files:**
- Modify: `Sources/PensieveApp/AppModel.swift` (add `deleteNode`; `canDelete`/`pendingDeleteNodeID` exist from B3)
- Modify: `Sources/PensieveApp/RootView.swift` (mount the confirmation dialog)

**Interfaces:**
- Consumes (Plan A): `NodeCommands.delete`. Consumes (B3): `pendingDeleteNodeID`, `canDelete`, the context-menu Delete button.
- Produces on `AppModel`: `func deleteNode(_ nodeID: UUID)`, `func deleteConfirmationText() -> String`.

- [ ] **Step 1: AppModel — perform the delete + build the confirmation text**

In `Sources/PensieveApp/AppModel.swift`, add (near `merge`):

```swift
  /// Delete a (source-free) node and its subtree via the Kit cascade. Moves selection off it.
  func deleteNode(_ nodeID: UUID) {
    guard let db else { return }
    _ = try? NodeCommands.delete(db, nodeID: nodeID)
    if selectedNodeID == nodeID { selectedNodeID = nil }
    if sidebarSelection == .node(nodeID) { sidebarSelection = .briefing }
    refresh()
  }

  /// Destructive-confirmation copy for the currently-pending delete. Names the node; warns about
  /// nested items when the subtree isn't a leaf. (Exact event counts would need a Kit read; the
  /// subtree shape from the in-memory forest is enough for an honest warning.)
  func deleteConfirmationText() -> String {
    guard let id = pendingDeleteNodeID, let n = node(id) else { return "" }
    let hasChildren = allNodes.contains { $0.parentID == id }
    if hasChildren {
      return String(localized: "Delete “\(n.name)” and everything nested under it? Captured activity and loose ends are removed. This can’t be undone.")
    }
    return String(localized: "Delete “\(n.name)”? Its captured activity and loose ends are removed. This can’t be undone.")
  }
```

- [ ] **Step 2: RootView — mount the confirmation dialog**

In `Sources/PensieveApp/RootView.swift`, add (after the `NodeEditor` sheet):

```swift
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
```

- [ ] **Step 3: Build + smoke**

Run the full **build + smoke recipe**.
Expected: `** BUILD SUCCEEDED **`; smoke log clean.

- [ ] **Step 4: Commit**

```bash
git add Sources/PensieveApp/AppModel.swift Sources/PensieveApp/RootView.swift
git commit -F - <<'EOF'
feat(app): manual node delete with confirmation

Context-menu Delete… (disabled for source-backed nodes that would
resurrect) → destructive confirmation → Kit cascade delete; selection
moves off the deleted node.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01GsAu7rTTdD77k3xZHZrhm4
EOF
```

> **Human-verify carry:** Delete… is disabled on an activity-born node (has sources), enabled on a manual node; confirming removes the node + its subtree; `pensieve list` matches after.

---

### Task B5: Node identity in list, sidebar, and detail header (#3, #6)

**Files:**
- Modify: `Sources/PensieveApp/ContentListView.swift` (badge + localized kind subtitle)
- Modify: `Sources/PensieveApp/SidebarView.swift` (badge as the row icon; remove `symbol(for:)`)
- Modify: `Sources/PensieveApp/DetailView.swift` (header: badge + kind label + state orb)

**Interfaces:**
- Consumes (B1): `NodeBadge`, `AppearanceStyle.kindLabel/stateLabel/stateColor`.

- [ ] **Step 1: Middle list — badge + localized kind subtitle (#3)**

In `Sources/PensieveApp/ContentListView.swift`, replace the row body with:

```swift
    List(items, selection: $model.selectedNodeID) { node in
      HStack(spacing: 10) {
        NodeBadge(node: node, size: 26)
        VStack(alignment: .leading, spacing: 2) {
          Text(node.name)
          Text(AppearanceStyle.kindLabel(node.kind)).font(.caption).foregroundStyle(.secondary)
        }
      }
      .tag(node.id)
      .contextMenu { NodeContextMenu(model: model, node: node) }
    }
```

- [ ] **Step 2: Sidebar tree — badge as the row icon; drop `symbol(for:)`**

In `Sources/PensieveApp/SidebarView.swift`, change `nodeRow` to use the badge as the Label icon:

```swift
  @ViewBuilder private func nodeRow(_ item: NodeForestNode) -> some View {
    Label { Text(item.node.name) } icon: { NodeBadge(node: item.node, size: 18) }
      .tag(SidebarSelection.node(item.node.id))
      .contextMenu { NodeContextMenu(model: model, node: item.node) }
  }
```

Then **delete** the now-unused `private func symbol(for kind: String) -> String { … }` method.

- [ ] **Step 3: Detail header — badge + kind label + state orb (#6)**

In `Sources/PensieveApp/DetailView.swift`, replace the "WHAT IT IS" `VStack` with:

```swift
        // WHAT IT IS
        HStack(alignment: .top, spacing: 12) {
          NodeBadge(node: node, size: 44)
          VStack(alignment: .leading, spacing: 4) {
            Text(node.name).font(.largeTitle).bold()
            HStack(spacing: 6) {
              Text(AppearanceStyle.kindLabel(node.kind)).foregroundStyle(.secondary)
              Text("·").foregroundStyle(.secondary)
              Circle().fill(AppearanceStyle.stateColor(node.state)).frame(width: 8, height: 8)
              Text(AppearanceStyle.stateLabel(node.state)).foregroundStyle(.secondary)
            }
            if !node.description.isEmpty {
              Text(node.description).font(.body).padding(.top, 2)
            }
          }
        }
```

- [ ] **Step 4: Build + smoke**

Run the full **build + smoke recipe**.
Expected: `** BUILD SUCCEEDED **`; smoke log clean.

- [ ] **Step 5: Commit**

```bash
git add Sources/PensieveApp/ContentListView.swift Sources/PensieveApp/SidebarView.swift Sources/PensieveApp/DetailView.swift
git commit -F - <<'EOF'
feat(app): node icon/color badges + kind label + state orb

Middle list and sidebar tree show the NodeBadge; the detail header shows
the badge, the localized kind label, and a colored state orb.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01GsAu7rTTdD77k3xZHZrhm4
EOF
```

> **Human-verify carry:** badges render (color+icon) in list/sidebar/header; a node with a custom emoji shows the emoji; state orb is green/orange/gray for active/muted/archived.

---

### Task B6: GitHub-style activity timeline (#7)

**Files:**
- Modify: `Sources/PensieveApp/DetailView.swift` (replace the flat Recent Activity rows with a rail timeline)

**Interfaces:**
- Consumes (B1): `AppearanceStyle.color/sourceLabel`. Consumes (Plan A): `EventSourceStyle`, `AppearanceIcon`. Uses the already-loaded `recentEvents: [Event]`.

- [ ] **Step 1: Replace the Recent Activity section body**

In `Sources/PensieveApp/DetailView.swift`, change the "RECENT ACTIVITY" section to render the timeline:

```swift
        // RECENT ACTIVITY (GitHub-style rail timeline)
        section("Recent Activity") {
          if recentEvents.isEmpty {
            Text("No captured activity.").foregroundStyle(.secondary)
          } else {
            ActivityTimeline(events: recentEvents)
          }
        }
```

- [ ] **Step 2: Add the timeline views at the bottom of `DetailView.swift`**

After the `private struct DetailLoadKey` line at the end of the file, add:

```swift
/// A GitHub-style vertical-rail timeline: events grouped by day, a colored dot per event on a rail,
/// the source icon+color, the localized source label, and the summary. No avatars (single-user).
private struct ActivityTimeline: View {
  let events: [Event]

  var body: some View {
    let groups = Dictionary(grouping: events) { Calendar.current.startOfDay(for: $0.occurredAt) }
    let days = groups.keys.sorted(by: >)
    VStack(alignment: .leading, spacing: 16) {
      ForEach(days, id: \.self) { day in
        VStack(alignment: .leading, spacing: 8) {
          Text(day, format: .dateTime.weekday(.wide).month().day())
            .font(.caption).bold().foregroundStyle(.secondary)
          ForEach((groups[day] ?? []).sorted { $0.occurredAt > $1.occurredAt }) { event in
            TimelineRow(event: event)
          }
        }
      }
    }
  }
}

private struct TimelineRow: View {
  let event: Event

  var body: some View {
    let style = EventSourceStyle.style(for: event.kind)
    let color = AppearanceStyle.color(style.colorTag)
    HStack(alignment: .top, spacing: 10) {
      VStack(spacing: 0) {
        Circle().fill(color).frame(width: 10, height: 10).padding(.top, 3)
        Rectangle().fill(.quaternary).frame(width: 2).frame(maxHeight: .infinity)
      }
      .frame(width: 10)

      VStack(alignment: .leading, spacing: 2) {
        HStack(spacing: 6) {
          sourceIcon(style).font(.caption).foregroundStyle(color)
          Text(AppearanceStyle.sourceLabel(event.kind)).font(.caption).foregroundStyle(.secondary)
          Text(event.occurredAt, format: .dateTime.hour().minute())
            .font(.caption2).monospacedDigit().foregroundStyle(.tertiary)
        }
        Text(event.summary).font(.callout)
      }
      Spacer()
    }
  }

  @ViewBuilder private func sourceIcon(_ s: SourceStyle) -> some View {
    switch AppearanceIcon.parse(s.icon) {
    case .sfSymbol(let n): Image(systemName: n)
    case .emoji(let e):    Text(e)
    case nil:              Image(systemName: "circle.fill")
    }
  }
}
```

- [ ] **Step 3: Build + smoke**

Run the full **build + smoke recipe**.
Expected: `** BUILD SUCCEEDED **`; smoke log clean.

- [ ] **Step 4: Commit**

```bash
git add Sources/PensieveApp/DetailView.swift
git commit -F - <<'EOF'
feat(app): GitHub-style activity timeline

Recent Activity now renders a day-grouped vertical rail with per-event
dots, source icon+color, and localized source labels.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01GsAu7rTTdD77k3xZHZrhm4
EOF
```

> **Human-verify carry:** timeline renders with a rail + day headers; a git commit shows "Git Commit" (indigo), a session shows "Claude Code Session" (orange).

---

### Task B7: Localization (German) + localized `NodeEntity` subtitle

**Files:**
- Modify: `Sources/PensieveApp/Localizable.xcstrings` (add en base + de for all new chrome)
- Modify: `Sources/PensieveApp/AppIntents/NodeEntity.swift` (localize the kind portion of the subtitle)

**Interfaces:**
- Consumes (B1): `AppearanceStyle.kindLabel`.

- [ ] **Step 1: Add the new keys to the String Catalog**

`Localizable.xcstrings` is a JSON catalog keyed by the English source string. For **each** English key below, add an entry following the existing structure (an object with `"localizations"` containing `"de"` → `{"stringUnit": {"state": "translated", "value": "<German>"}}`; leave English to source-fallback, i.e. no `"en"` unit needed, matching the existing entries). Author these by hand — `xcodebuild` will NOT extract them.

Keys + German values (impersonal/infinitive chrome; proper names stay English):

| English key | German (`de`) |
|---|---|
| `Domain` | `Bereich` |
| `Project` | `Projekt` |
| `Strand` | `Strang` |
| `Concept` | `Konzept` |
| `Initiative` | `Initiative` |
| `Task` | `Aufgabe` |
| `Topic` | `Thema` |
| `Git Commit` | `Git-Commit` |
| `Git Checkout` | `Git-Checkout` |
| `Claude Code Session` | `Claude-Code-Sitzung` |
| `Activity` | `Aktivität` |
| `Active` | `Aktiv` |
| `Muted` | `Stummgeschaltet` |
| `Archived` | `Archiviert` |
| `Name` | `Name` |
| `Type` | `Typ` |
| `Color` | `Farbe` |
| `Symbol` | `Symbol` |
| `Emoji` | `Emoji` |
| `Save` | `Sichern` |
| `New Node` | `Neuer Knoten` |
| `Edit Node` | `Knoten bearbeiten` |
| `New Child…` | `Neues Unterelement …` |
| `Edit…` | `Bearbeiten …` |
| `Delete…` | `Löschen …` |
| `Delete` | `Löschen` |
| `Delete “%@”? Its captured activity and loose ends are removed. This can’t be undone.` | `„%@“ löschen? Die erfasste Aktivität und offenen Enden werden entfernt. Dies kann nicht rückgängig gemacht werden.` |
| `Delete “%@” and everything nested under it? Captured activity and loose ends are removed. This can’t be undone.` | `„%@“ und alles darin Verschachtelte löschen? Erfasste Aktivität und offene Enden werden entfernt. Dies kann nicht rückgängig gemacht werden.` |

Example entry shape (match the existing file's formatting exactly):

```json
    "Domain" : {
      "localizations" : {
        "de" : {
          "stringUnit" : {
            "state" : "translated",
            "value" : "Bereich"
          }
        }
      }
    },
```

For the two delete strings, the key in the catalog is the **format string with `%@`** (Swift's `String(localized: "… \(name) …")` lowers the `\(name)` interpolation to `%@`). Ensure the `%@` position matches in the German value.

*(Obsolete keys `Rename`, `Change Type`, `New Child` from the removed menu may remain in the file — leave them; unused keys are harmless.)*

- [ ] **Step 2: Localize the `NodeEntity` subtitle**

In `Sources/PensieveApp/AppIntents/NodeEntity.swift`, change the `init(facts:)` subtitle line so the kind is localized (Spotlight/Siri match the app):

```swift
  init(facts: NodeFacts) {
    self.id = facts.node.id
    self.name = facts.node.name
    self.searchBody = facts.node.description
    let n = facts.openLooseEnds
    let kind = String(localized: AppearanceStyle.kindLabel(facts.node.kind))
    self.subtitle = "\(kind) · \(n) open loose end\(n == 1 ? "" : "s") · dormant \(facts.daysDormant)d"
  }
```

- [ ] **Step 3: Build + smoke, then verify German loads**

Run the **build** portion, then verify the `de` catalog compiled into the bundle and forces correctly:

```bash
# German strings compiled into the bundle?
plutil -p "./.build-xcode/Build/Products/Debug/Pensieve.app/Contents/Resources/de.lproj/Localizable.strings" | grep -E "Bereich|Aufgabe|Git-Commit" | head
# Force-launch in German (non-blocking), then kill.
BIN="./.build-xcode/Build/Products/Debug/Pensieve.app/Contents/MacOS/Pensieve"
PENSIEVE_DB="/tmp/vi-smoke.sqlite" PENSIEVE_CAPTURE_DB="/tmp/vi-smoke-cap.sqlite" \
  "$BIN" -AppleLanguages '(de)' >/tmp/vi-de.log 2>&1 &
P=$!; sleep 3; kill "$P" 2>/dev/null; cat /tmp/vi-de.log
```

Expected: `plutil` prints the German values (proves the keys compiled); launch is clean.

- [ ] **Step 4: Commit**

```bash
git add Sources/PensieveApp/Localizable.xcstrings Sources/PensieveApp/AppIntents/NodeEntity.swift
git commit -F - <<'EOF'
feat(app): German localization for identity chrome + localized Spotlight subtitle

Kind/source/state labels, modal + menu + delete chrome localized (en base,
de) and the NodeEntity Spotlight/Siri subtitle now uses the localized kind
label so it matches the app.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01GsAu7rTTdD77k3xZHZrhm4
EOF
```

> **Human-verify carry:** launch with `-AppleLanguages '(de)'` → kind labels, modal, menus, and delete dialog render in German; node names/quotes/summaries stay English (content). Native-speaker tone pass on the new German copy.

---

## Self-review (Plan B)

- **Spec coverage:** #1 footer material (B2); #2 collapsible sections (B2); #3 modal + list badge (B3, B5); #4 delete (B4); #5 localized kind labels (B1 + B7); #6 header kind label + state orb (B5); #7 timeline (B6); localization + Spotlight subtitle (B7). `AppearanceStyle`/`NodeBadge` (B1). All Plan-B spec bullets covered.
- **Types consistent:** `NodeEditRequest` (nested, `Mode.new/edit`) matches `presentNewNode`/`presentEditNode`/`NodeEditor.load/commit`. `commitNewNode`/`updateNode`/`deleteNode`/`canDelete`/`deleteConfirmationText`/`pendingDeleteNodeID`/`editingNode` names match across AppModel, RootView, and NodeOrganizing. `AppearanceStyle.kindLabel/sourceLabel/stateLabel/stateColor/color/palette` and `NodeBadge(node:size:)` names match every call site (B5, B6, B7). Kit symbols consumed match Plan A's produced signatures.
- **No placeholders:** every step has real code + exact commands; the build/smoke recipe is concrete.
- **Ordering:** Plan A merged first. Within Plan B: B1 → B2 → B3 → B4 → B5 → B6 → B7. B3 adds `canDelete`/`pendingDeleteNodeID` stubs so it builds before B4 completes delete. B5 depends on B1's `NodeBadge`; B6 on B1's label/color; B7 on B1's `kindLabel`.
- **Deliberate simplifications (noted):** the delete confirmation warns about nested items rather than printing exact event/loose-end counts (exact counts would need a new Kit read; the in-memory forest gives an honest warning); the New modal seeds explicit icon/color from the kind default (so a swatch is pre-selected) rather than leaving them empty. Both are within spec intent.
