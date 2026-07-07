# App Chrome Polish Batch Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make four pieces of Pensieve.app chrome feel Apple-native — prose typography, the window toolbar, the sidebar tracking indicator, and the New/Edit node modal — without touching PensieveKit.

**Architecture:** Pure SwiftUI view styling/wiring in the `PensieveApp` target. All writes reuse existing `AppModel` methods (which already route through Kit `NodeCommands`). One tiny new app-only helper file (`ProseStyle.swift`); everything else edits existing views. No Kit changes, no new query logic.

**Tech Stack:** SwiftUI (macOS 15+ deployment target), XcodeGen + Xcode 26.6, Xcode String Catalog (`Localizable.xcstrings`) for en+de chrome strings.

## Global Constraints

- **No PensieveKit changes.** App-target files only (`Sources/PensieveApp/**`).
- **App target has NO unit tests.** Verify every task by: `xcodegen generate && xcodebuild -project Pensieve.xcodeproj -scheme Pensieve -configuration Debug -derivedDataPath ./.build-xcode build` → `** BUILD SUCCEEDED **`, then a non-blocking smoke-launch of the inner binary `./.build-xcode/Build/Products/Debug/Pensieve.app/Contents/MacOS/Pensieve` with throwaway `PENSIEVE_DB`/`PENSIEVE_CAPTURE_DB` (`/tmp` paths), confirm it stays up ~2s, then `kill`.
- **All writes go through existing `AppModel` methods** — never call Kit directly from a view. Do not add new `AppModel` methods unless a task says so (none do).
- **Localization is chrome-only.** Any NEW user-facing UI string gets `en` + `de` keys in `Sources/PensieveApp/Localizable.xcstrings` **by hand** (xcodebuild does not auto-populate the catalog). Node names, quotes, summaries, descriptions stay un-localized. German is impersonal/infinitive.
- **Match existing style.** English literals double as String Catalog keys (see `AppearanceStyle.kindLabel`). Predicates use `.eq(x)` — but no Kit/DB work happens here.
- **Execution order (smallest-first):** Task 1 → Task 2 → Task 3 → Task 4. (Task numbering here = execution order, not backlog numbering.)
- Worktree: `../pensieve-chrome-polish` on branch `feat/app-chrome-polish`.

---

### Task 1: Prose typography

**Files:**
- Create: `Sources/PensieveApp/ProseStyle.swift`
- Modify: `Sources/PensieveApp/DetailView.swift` (prose runs + measure cap + `TimelineRow`)
- Modify: `Sources/PensieveApp/BriefingView.swift` (teaser run + measure cap)

**Interfaces:**
- Produces: `enum Prose { static let measure: CGFloat }` and `extension View { func prose() -> some View }`. Consumed only within this task.

- [ ] **Step 1: Create the prose helper**

Create `Sources/PensieveApp/ProseStyle.swift`:

```swift
// Sources/PensieveApp/ProseStyle.swift
import SwiftUI

/// Shared reading-prose treatment for the app's content text (LLM narration, node descriptions,
/// loose-end text/quotes, activity summaries, briefing teasers). App-only styling; no Kit involvement.
enum Prose {
  /// Max reading-column width. Caps line length on wide windows so prose stays readable.
  static let measure: CGFloat = 680
}

extension View {
  /// Body prose: a slightly larger size with generous leading. Apply to text runs, not headers.
  func prose() -> some View {
    self.font(.system(size: 14)).lineSpacing(4)
  }
}
```

- [ ] **Step 2: Apply `.prose()` to DetailView prose runs**

In `Sources/PensieveApp/DetailView.swift`:

Node description (was `.font(.body)`):
```swift
            if !node.description.isEmpty {
              Text(node.description).prose().padding(.top, 2)
            }
```

"Last Work Done" narration (was `.font(.body)`):
```swift
          section("Last Work Done") {
            Text(lastWorkDone).prose()
          }
```

Loose-end text (in `looseEndRow`, the `Text(view.looseEnd.text)` — add `.prose()`; keep it inside the existing HStack):
```swift
          Text(view.looseEnd.text).prose()
```

Verbatim quote (in `looseEndRow`, was `.italic()`):
```swift
          Text(view.looseEnd.quote)
            .prose()
            .italic()
            .padding(.leading, 10)
            .overlay(alignment: .leading) {
              Rectangle().fill(.orange).frame(width: 3)
            }
```

Timeline summary (in `TimelineRow.body`, was `.font(.callout)`):
```swift
        Text(event.summary).prose()
```

- [ ] **Step 3: Add the measure cap to DetailView**

In `DetailView.body`, the outer `ScrollView`'s `VStack` currently ends with `.padding(24)` then `.frame(maxWidth: .infinity, alignment: .leading)`. Insert the measure cap on the `VStack` BEFORE the infinity frame, so the text column is bounded but the scroll view still fills the pane:

```swift
      .padding(24)
      .frame(maxWidth: Prose.measure, alignment: .leading)
      .frame(maxWidth: .infinity, alignment: .leading)
```

- [ ] **Step 4: Apply `.prose()` + measure cap to BriefingView**

In `Sources/PensieveApp/BriefingView.swift`, the card teaser (was `.font(.callout)`, keep `.lineLimit(1)`):
```swift
        if !c.latestSummary.isEmpty {
          Text(c.latestSummary).prose().foregroundStyle(.secondary).lineLimit(1)
        }
```

And the measure cap on the body `VStack` (same pattern — before the infinity frame):
```swift
      .padding(24)
      .frame(maxWidth: Prose.measure, alignment: .leading)
      .frame(maxWidth: .infinity, alignment: .leading)
```

- [ ] **Step 5: Build**

Run from the worktree root:
```bash
xcodegen generate && xcodebuild -project Pensieve.xcodeproj -scheme Pensieve -configuration Debug -derivedDataPath ./.build-xcode build
```
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 6: Smoke-launch**

```bash
PENSIEVE_DB=/tmp/pv-smoke.sqlite PENSIEVE_CAPTURE_DB=/tmp/pv-smoke-cap.sqlite \
  ./.build-xcode/Build/Products/Debug/Pensieve.app/Contents/MacOS/Pensieve &
PID=$!; sleep 2; kill $PID 2>/dev/null; echo "smoke ok"
```
Expected: process stays up for ~2s (no crash), prints `smoke ok`.

- [ ] **Step 7: Commit**

```bash
git add Sources/PensieveApp/ProseStyle.swift Sources/PensieveApp/DetailView.swift Sources/PensieveApp/BriefingView.swift
git commit -m "feat(app): reading-prose typography (size, leading, measure cap)"
```

---

### Task 2: Window toolbar actions

**Files:**
- Modify: `Sources/PensieveApp/RootView.swift` (`.toolbar` + a `selectedNode` helper)
- Modify: `Sources/PensieveApp/Localizable.xcstrings` (new `.help` tooltip strings, en+de)

**Interfaces:**
- Consumes (existing `AppModel`, all present): `selectedNodeID: UUID?`, `node(_:) -> Node?`, `presentNewNode(under:)`, `presentEditNode(_:)`, `movePickerNodeID`, `mergePickerNodeID`, `pendingDeleteNodeID`, `canDelete(_:) -> Bool`, `showInspector`, `refreshNow() async`.
- Produces: nothing consumed elsewhere.

- [ ] **Step 1: Replace the toolbar in RootView**

In `Sources/PensieveApp/RootView.swift`, replace the current single-item `.toolbar { ToolbarItem { Button { model.presentNewNode(under: nil) } ... } }` block with the following. Keep every other modifier (`.sheet`, `.confirmationDialog`, `.inspector`, `.onChange`) exactly as-is.

```swift
    .toolbar {
      ToolbarItemGroup {
        Button { model.presentNewNode(under: nil) } label: { Image(systemName: "plus") }
          .help("New Node")

        Button { if let n = selectedNode { model.presentEditNode(n) } } label: {
          Image(systemName: "pencil")
        }
        .help("Edit")
        .disabled(model.selectedNodeID == nil)

        Button { model.movePickerNodeID = model.selectedNodeID } label: {
          Image(systemName: "arrow.up.and.down.text.horizontal")
        }
        .help("Move to…")
        .disabled(model.selectedNodeID == nil)

        Button { model.mergePickerNodeID = model.selectedNodeID } label: {
          Image(systemName: "arrow.triangle.merge")
        }
        .help("Merge into…")
        .disabled(model.selectedNodeID == nil)

        Button(role: .destructive) { model.pendingDeleteNodeID = model.selectedNodeID } label: {
          Image(systemName: "trash")
        }
        .help("Delete")
        .disabled(!canDeleteSelection)
      }
      ToolbarItemGroup(placement: .primaryAction) {
        Button { model.showInspector.toggle() } label: { Image(systemName: "sidebar.trailing") }
          .help("Inspector")
        Button { Task { await model.refreshNow() } } label: { Image(systemName: "arrow.clockwise") }
          .help("Refresh")
      }
    }
```

- [ ] **Step 2: Add the selection helpers**

In `Sources/PensieveApp/RootView.swift`, add these computed properties to `struct RootView` (above `var body`):

```swift
  private var selectedNode: Node? {
    guard let id = model.selectedNodeID else { return nil }
    return model.node(id)
  }
  /// Delete is enabled only for a selected node that is not activity-born (mirrors NodeContextMenu).
  private var canDeleteSelection: Bool {
    guard let id = model.selectedNodeID else { return false }
    return model.canDelete(id)
  }
```

- [ ] **Step 3: Add the new tooltip strings to the String Catalog**

`"New Node"`, `"Edit"`, `"Move to…"`, `"Merge into…"`, `"Delete"`, `"Inspector"`, `"Refresh"` are the `.help` keys. Some already exist as keys used by menus/context menu (`"New Node"`, `"Move to…"`, `"Merge into…"`, `"Inspector"`, `"Refresh"`). The ones likely NEW as standalone keys are `"Edit"` and `"Delete"` (the context menu uses `"Edit…"` and `"Delete…"`). Open `Sources/PensieveApp/Localizable.xcstrings` and ensure each of the seven keys exists with an `en` value equal to the key and a `de` value. Add (or leave if present):

For `"Edit"`:
```json
    "Edit" : {
      "localizations" : {
        "de" : { "stringUnit" : { "state" : "translated", "value" : "Bearbeiten" } }
      }
    },
```
For `"Delete"`:
```json
    "Delete" : {
      "localizations" : {
        "de" : { "stringUnit" : { "state" : "translated", "value" : "Löschen" } }
      }
    },
```
Verify German already exists for the reused keys `"Move to…"`, `"Merge into…"`, `"Inspector"`, `"Refresh"`, `"New Node"` (they should — search the file). If any is missing a `de` unit, add one: `"Move to…"`→`"Verschieben nach…"`, `"Merge into…"`→`"Zusammenführen mit…"`, `"Inspector"`→`"Inspektor"`, `"Refresh"`→`"Aktualisieren"`, `"New Node"`→`"Neuer Knoten"`.

> Note: the `.xcstrings` file is JSON with keys in sorted order. Insert new keys in the correct alphabetical position, matching the existing indentation (2-space). A malformed JSON will fail the build's catalog compile — validate with `plutil -lint Sources/PensieveApp/Localizable.xcstrings` before building.

- [ ] **Step 4: Validate the catalog JSON**

```bash
plutil -lint Sources/PensieveApp/Localizable.xcstrings
```
Expected: `... OK`

- [ ] **Step 5: Build**

```bash
xcodegen generate && xcodebuild -project Pensieve.xcodeproj -scheme Pensieve -configuration Debug -derivedDataPath ./.build-xcode build
```
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 6: Smoke-launch**

```bash
PENSIEVE_DB=/tmp/pv-smoke.sqlite PENSIEVE_CAPTURE_DB=/tmp/pv-smoke-cap.sqlite \
  ./.build-xcode/Build/Products/Debug/Pensieve.app/Contents/MacOS/Pensieve &
PID=$!; sleep 2; kill $PID 2>/dev/null; echo "smoke ok"
```
Expected: `smoke ok`, no crash.

- [ ] **Step 7: Commit**

```bash
git add Sources/PensieveApp/RootView.swift Sources/PensieveApp/Localizable.xcstrings
git commit -m "feat(app): window toolbar actions (edit/move/merge/delete/refresh/inspector)"
```

---

### Task 3: Native sidebar tracking indicator

**Files:**
- Modify: `Sources/PensieveApp/SidebarView.swift` (`StatusFooter.body`)

**Interfaces:**
- Consumes: nothing new. `StatusFooter` already takes `snapshot: MonitorSnapshot`.
- Produces: nothing consumed elsewhere.

- [ ] **Step 1: Rework StatusFooter.body**

In `Sources/PensieveApp/SidebarView.swift`, replace the `StatusFooter.body` with a top-hairline + translucent-bar treatment (the Finder/Mail bottom status bar idiom). Leave the `color` and `label` computed properties unchanged.

```swift
  var body: some View {
    VStack(spacing: 0) {
      Divider()
      HStack(spacing: 6) {
        Circle().fill(color).frame(width: 7, height: 7)
        Text(label).font(.caption).foregroundStyle(.secondary)
        Spacer()
      }
      .padding(.horizontal, 12).padding(.vertical, 6)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .background(.bar)
  }
```

- [ ] **Step 2: Build**

```bash
xcodegen generate && xcodebuild -project Pensieve.xcodeproj -scheme Pensieve -configuration Debug -derivedDataPath ./.build-xcode build
```
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Smoke-launch**

```bash
PENSIEVE_DB=/tmp/pv-smoke.sqlite PENSIEVE_CAPTURE_DB=/tmp/pv-smoke-cap.sqlite \
  ./.build-xcode/Build/Products/Debug/Pensieve.app/Contents/MacOS/Pensieve &
PID=$!; sleep 2; kill $PID 2>/dev/null; echo "smoke ok"
```
Expected: `smoke ok`, no crash.

- [ ] **Step 4: Commit**

```bash
git add Sources/PensieveApp/SidebarView.swift
git commit -m "feat(app): native sidebar status bar (hairline + translucent bar)"
```

---

### Task 4: New/Edit modal — Reminders-parity layout + popover pickers

**Files:**
- Modify: `Sources/PensieveApp/NodeOrganizing.swift` (`NodeEditor` only — the `NodeContextMenu`/`MovePicker`/`MergePicker` structs below it stay untouched)
- Modify: `Sources/PensieveApp/Localizable.xcstrings` (new strings: `"Symbol"`, `"Emoji"`, `"Search symbols"`)

**Interfaces:**
- Consumes (existing): `AppearanceStyle.color(_:) -> Color`, `AppearanceStyle.palette`, `AppearanceStyle.kindLabel(_:)`, `AppearanceIcon.parse(_:)`, `NodeKind.all`, `model.commitNewNode(parent:name:kind:icon:colorTag:)`, `model.updateNode(_:name:kind:icon:colorTag:)`, `model.defaultKind(under:)`, `NodeKindStyle.style(for:)`, `node.appearance`.
- Produces: nothing consumed elsewhere. Stored icon form is unchanged (`sf:<name>` / `emoji:<grapheme>`).

- [ ] **Step 1: Rewrite the NodeEditor struct**

In `Sources/PensieveApp/NodeOrganizing.swift`, replace the entire `struct NodeEditor: View { ... }` (lines from `struct NodeEditor` through its closing brace, before `/// The organizing context menu...`) with the two-zone version below. **Do not touch** `NodeContextMenu`, `MovePicker`, or `MergePicker`.

```swift
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
```

- [ ] **Step 2: Add the new strings to the String Catalog**

Open `Sources/PensieveApp/Localizable.xcstrings` and add three keys in alphabetical position (2-space indent). `"Symbol"` is identical in German; `"Emoji"` identical; `"Search symbols"` → `"Symbole suchen"`. `"Name"`, `"Type"`, `"Color"`, `"Cancel"`, `"Save"`, `"New Node"`, `"Edit Node"` already exist from the prior modal — do not duplicate.

```json
    "Emoji" : {
      "localizations" : {
        "de" : { "stringUnit" : { "state" : "translated", "value" : "Emoji" } }
      }
    },
```
```json
    "Search symbols" : {
      "localizations" : {
        "de" : { "stringUnit" : { "state" : "translated", "value" : "Symbole suchen" } }
      }
    },
```
```json
    "Symbol" : {
      "localizations" : {
        "de" : { "stringUnit" : { "state" : "translated", "value" : "Symbol" } }
      }
    },
```

- [ ] **Step 3: Validate the catalog JSON**

```bash
plutil -lint Sources/PensieveApp/Localizable.xcstrings
```
Expected: `... OK`

- [ ] **Step 4: Build**

```bash
xcodegen generate && xcodebuild -project Pensieve.xcodeproj -scheme Pensieve -configuration Debug -derivedDataPath ./.build-xcode build
```
Expected: `** BUILD SUCCEEDED **`

If a first `xcodebuild` on this machine fails with a macro/plugin fingerprint error, trust the plugins (`defaults write com.apple.dt.Xcode IDESkipPackagePluginFingerprintValidation -bool YES` + `...IDESkipMacroFingerprintValidation...`) and retry. If a SwiftSyntax linker error, `rm -rf .build .build-xcode` and retry.

- [ ] **Step 5: Smoke-launch**

```bash
PENSIEVE_DB=/tmp/pv-smoke.sqlite PENSIEVE_CAPTURE_DB=/tmp/pv-smoke-cap.sqlite \
  ./.build-xcode/Build/Products/Debug/Pensieve.app/Contents/MacOS/Pensieve &
PID=$!; sleep 2; kill $PID 2>/dev/null; echo "smoke ok"
```
Expected: `smoke ok`, no crash. (The modal itself is human-verify: opens balanced, Symbol popover searches, Emoji button opens the Character Viewer.)

- [ ] **Step 6: Commit**

```bash
git add Sources/PensieveApp/NodeOrganizing.swift Sources/PensieveApp/Localizable.xcstrings
git commit -m "feat(app): Reminders-parity New/Edit modal with popover icon pickers"
```

**Fallback (only if Character-Viewer capture proves flaky in the smoke run):** replace the hidden-capture field + `pickEmoji()` + `firstEmoji(in:)` with an Emoji popover mirroring `symbolPopover` over the curated `emojis` set (`"🚀","🎯","💡",…` from the previous editor), setting `icon = "emoji:\(e)"`. Same stored form, same look. Note it as a carry in the whole-branch review.

---

## Whole-branch close-out (after all four tasks)

- [ ] **Opus whole-branch review** of `main..feat/app-chrome-polish` (use `scripts/review-package`). Focus: no Kit changes leaked in; String Catalog JSON well-formed with de units; toolbar gating matches `NodeContextMenu`; no stale references to the removed `IconTab`/`iconGrid`/`cell`/`tab` members in `NodeEditor`.
- [ ] Fix any Critical/Important findings; re-verify build + smoke.
- [ ] `superpowers:finishing-a-development-branch` → user chooses "merge to main locally"; then remove the worktree + delete the branch. Update `CONTINUE.md` with the human-verify carries.

## Human-verify carries (record at merge — cannot be asserted headlessly)

1. **Typography:** Detail + Briefing prose reads larger/airier; the reading column is bounded (~680pt) on a wide window instead of running edge-to-edge.
2. **Toolbar:** each action opens the same sheet/dialog as the context menu; Edit/Move/Merge/Delete disable with no selection; Delete stays disabled on an activity-born node.
3. **Indicator:** the sidebar bottom bar reads native — a hairline over a translucent bar — no longer a bolted-on band.
4. **Modal:** balanced two-zone layout; live preview circle updates with color/icon; Symbol popover searches and picks an SF Symbol; the Emoji button opens the system Character Viewer and the picked emoji lands in the preview + saved badge; German renders in situ (`-AppleLanguages '(de)'`); `pensieve list` matches after a create/edit.

## Self-review notes

- **Spec coverage:** Task 1 = spec Task 1; Task 2 = spec Task 2 (toolbar); Task 3 = spec Task 3 (indicator); Task 4 = spec Task 4 (modal). All four spec sections mapped. Out-of-scope items (backlog 5, Sharing) intentionally absent.
- **No placeholders:** every code step shows full code; the emoji fallback is a concrete alternative, not a TODO.
- **Type consistency:** `AppearanceIcon.parse` returns `.sfSymbol(String)` / `.emoji(String)` / `nil` (matches `TimelineRow.sourceIcon` and `NodeBadge` usage). `model.commitNewNode`/`updateNode` signatures copied verbatim from `AppModel`. Stored icon form `sf:`/`emoji:` matches `NodeEditor.load()`'s existing `storedString`.
