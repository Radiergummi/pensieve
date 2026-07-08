# Three-pane IA Rework Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The middle pane lists a focused node's children (or its loose ends when the node is a leaf) instead of the node-plus-its-children; the detail always shows the focused node's recall; loose-end provenance stays in the single ⌘⌥I inspector. This kills the sidebar→middle→detail self-duplication.

**Architecture:** Sidebar selection drives the middle column; `selectedNodeID` drives the detail. A new in-memory `AppModel.middleKind()` returns either child nodes or a leaf's id (whose loose ends the view loads off-body via `.task`, never in `body`). A shared `LooseEndRow` view makes loose ends look and behave identically in the middle worklist and the detail recall; a `showsLooseEnds` flag enforces the one-home rule. One tiny tested PensieveKit helper (`NodeForest.children`) backs the child lookup.

**Tech Stack:** Swift 6, SwiftUI (macOS app target built via XcodeGen + Xcode), PensieveKit (SwiftPM), Swift Testing, SQLiteData/GRDB. Spec: `docs/superpowers/specs/2026-07-08-three-pane-ia-rework-design.md`.

## Global Constraints

- **PensieveKit is the only unit-tested layer.** The app target (`Sources/PensieveApp/`) has **no unit tests** — verify app tasks with a build + non-blocking smoke-launch (recipe below) + the human-eyeball carries listed at the end. Keep derivation logic in tested PensieveKit; keep views thin. (`CLAUDE.md`)
- **App build + smoke recipe** (run from repo root):
  ```bash
  xcodegen generate && \
  xcodebuild -project Pensieve.xcodeproj -scheme Pensieve -configuration Debug \
    -derivedDataPath ./.build-xcode build 2>&1 | tail -8
  ```
  Then smoke-launch the **inner binary** in the background with throwaway stores, wait ~3s, confirm it did not crash, and kill it (never touch the live store):
  ```bash
  env PENSIEVE_DB=/tmp/pv-ia.sqlite PENSIEVE_CAPTURE_DB=/tmp/pv-ia-cap.sqlite \
    ./.build-xcode/Build/Products/Debug/Pensieve.app/Contents/MacOS/Pensieve
  ```
  (Use the Bash tool's `run_in_background: true`; the shell is `fish`, so prefix env vars with `env`, not `VAR=…`.)
- **Kit tests:** `./scripts/test.sh --filter <name>` (thin `swift test` passthrough).
- **SQLiteData predicates use `.eq(x)`, never `== x`.** Reuse `SourceKind`/`CaptureKind`/`NodeKind` constants. No shared mutable `static ISO8601DateFormatter`. (`CLAUDE.md`)
- **Localization — chrome only.** New UI strings go through `String(localized:)`/`LocalizedStringResource` and are hand-added to `Sources/PensieveApp/Localizable.xcstrings` (en base + `de`); `xcodebuild` does **not** auto-populate keys. **Never** localize node names, loose-end text, quotes, transcript content, or the proper name "Pensieve".
- **Commit trailers** on every commit (backticks in `-m` get shell-executed — use a heredoc `-F -`):
  ```
  Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_01Ya7ToQ9MrGVDLzHkDB1mg3
  ```

---

## File Structure

- **Modify** `Sources/PensieveKit/Query/NodeForest.swift` — add the pure `children(of:in:)` helper.
- **Modify** `Tests/PensieveKitTests/NodeForestTests.swift` — tests for the helper.
- **Create** `Sources/PensieveApp/LooseEndRow.swift` — the shared loose-end row (internal disclosure + `onSelect`).
- **Modify** `Sources/PensieveApp/DetailView.swift` — use `LooseEndRow`; add `showsLooseEnds` flag; drop the local `expanded` set + `looseEndRow(_:)`.
- **Modify** `Sources/PensieveApp/AppModel.swift` — add `MiddleKind`, `middleKind()`, `children(of:)`, `selectMiddleNode(_:)`, `selectMiddleLooseEnd(_:)`, `middleTitle`, `detailShowsLooseEnds`; remove `nodesForSelection()` (Task 4).
- **Modify** `Sources/PensieveApp/ContentListView.swift` — render nodes-or-loose-ends from `middleKind()`; route taps; middle title/subtitle.
- **Modify** `Sources/PensieveApp/RootView.swift` — pass `showsLooseEnds: model.detailShowsLooseEnds` to the main-window `DetailView`.
- **Modify** `Sources/PensieveApp/Localizable.xcstrings` — add `%lld strands`, `%lld loose ends`, `None open` (en + de).

`RecallWindowView.swift` needs **no** change: `DetailView.showsLooseEnds` defaults to `true`.

---

## Task 1: `NodeForest.children(of:in:)` Kit helper

**Files:**
- Modify: `Sources/PensieveKit/Query/NodeForest.swift`
- Test: `Tests/PensieveKitTests/NodeForestTests.swift`

**Interfaces:**
- Consumes: `Node` (has `id: UUID`, `parentID: UUID?`, `name: String`).
- Produces: `public static func children(of id: UUID, in nodes: [Node]) -> [Node]` — direct children only, name-sorted.

- [ ] **Step 1: Write the failing test**

Append to `Tests/PensieveKitTests/NodeForestTests.swift`:

```swift
@Test func childrenReturnsDirectChildrenNameSorted() {
  let root = Node(name: "root", kind: "project")
  let b = Node(name: "b", parentID: root.id, kind: "strand")
  let a = Node(name: "a", parentID: root.id, kind: "strand")
  let grand = Node(name: "grand", parentID: a.id, kind: "strand")   // grandchild, NOT a direct child of root
  let other = Node(name: "other", kind: "project")
  let nodes = [grand, b, root, other, a]

  #expect(NodeForest.children(of: root.id, in: nodes).map(\.name) == ["a", "b"])   // direct + name-sorted
  #expect(NodeForest.children(of: a.id, in: nodes).map(\.name) == ["grand"])       // one level only
  #expect(NodeForest.children(of: b.id, in: nodes).isEmpty)                        // leaf
  #expect(NodeForest.children(of: other.id, in: nodes).isEmpty)                    // childless root
  #expect(NodeForest.children(of: UUID(), in: nodes).isEmpty)                      // unknown id
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `./scripts/test.sh --filter NodeForest`
Expected: FAIL — compile error, `type 'NodeForest' has no member 'children'`.

- [ ] **Step 3: Write minimal implementation**

In `Sources/PensieveKit/Query/NodeForest.swift`, inside `enum NodeForest`, after `descendantIDs`:

```swift
  /// Direct children of `id` within `nodes`, name-sorted. Pure and deterministic; mirrors
  /// `descendantIDs` but one level only.
  public static func children(of id: UUID, in nodes: [Node]) -> [Node] {
    nodes.filter { $0.parentID == id }.sorted { $0.name < $1.name }
  }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `./scripts/test.sh --filter NodeForest`
Expected: PASS (all NodeForest tests, including the new one).

- [ ] **Step 5: Commit**

```bash
git add Sources/PensieveKit/Query/NodeForest.swift Tests/PensieveKitTests/NodeForestTests.swift
git commit -F - <<'EOF'
feat(kit): NodeForest.children(of:in:) direct-children helper

Pure, name-sorted, one-level-only. Backs the app's new middle-column
"children of the focused node" lookup. Mirrors descendantIDs.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01Ya7ToQ9MrGVDLzHkDB1mg3
EOF
```

---

## Task 2: Shared `LooseEndRow` + `DetailView.showsLooseEnds`

Extract the detail recall's loose-end row into a reusable view (so the middle worklist can use the same one), and add the `showsLooseEnds` flag. Default `true` keeps `DetailView`/`RecallWindowView` behavior identical, so this task is a pure refactor + additive flag.

**Files:**
- Create: `Sources/PensieveApp/LooseEndRow.swift`
- Modify: `Sources/PensieveApp/DetailView.swift`

**Interfaces:**
- Consumes: `LooseEndView` (has `.looseEnd.id: UUID`, `.looseEnd.text: String`, `.looseEnd.quote: String`, `.looseEnd.role: String`, `.occurredAt: Date`, `.ageDays: Int`); `AppModel`; the `.prose()` / `.metaText()` / `.sectionHeader()` view modifiers (`ProseStyle.swift`).
- Produces: `struct LooseEndRow: View { init(view: LooseEndView, onSelect: @escaping () -> Void) }`; `DetailView` gains `var showsLooseEnds: Bool = true`.

- [ ] **Step 1: Create `LooseEndRow.swift`**

```swift
// Sources/PensieveApp/LooseEndRow.swift
import SwiftUI
import PensieveKit

/// One loose-end row: a tappable summary that discloses its verbatim quote + provenance meta inline,
/// and reports selection so the caller can point the ⌘⌥I inspector at it. Shared by the detail recall's
/// Loose Ends section and the middle worklist so both look and behave identically. Each row owns its own
/// expand state (rows are independent; no external set needed).
struct LooseEndRow: View {
  let view: LooseEndView
  /// Called on tap so the owner can set the inspected loose end (or no-op in a recall window).
  let onSelect: () -> Void
  @State private var expanded = false

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Button {
        expanded.toggle()
        onSelect()
      } label: {
        HStack(spacing: 6) {
          Image(systemName: expanded ? "chevron.down" : "chevron.right")
            .font(.caption2).foregroundStyle(.secondary)
          Text(view.looseEnd.text).prose()
          Spacer()
        }
      }
      .buttonStyle(.plain)

      if expanded {
        // The provenance: verbatim quote + where it came from. North-star made visible.
        VStack(alignment: .leading, spacing: 4) {
          Text(view.looseEnd.quote)
            .prose()
            .italic()
            .padding(.leading, 10)
            .overlay(alignment: .leading) { Rectangle().fill(.orange).frame(width: 3) }
          Text("\(view.looseEnd.role.isEmpty ? String(localized: "captured") : view.looseEnd.role) · \(view.occurredAt, format: .dateTime.year().month().day()) · \(view.ageDays)d ago")
            .metaText()
        }
        .padding(.leading, 18)
      }
    }
    .padding(.vertical, 2)
  }
}
```

- [ ] **Step 2: Rewire `DetailView` to use `LooseEndRow` + add the flag**

In `Sources/PensieveApp/DetailView.swift`:

Add the flag next to `allowsInspector` (after line 9):

```swift
  /// When false, the detail omits its Loose Ends section (the middle column is showing this same
  /// node's loose ends — the one-home rule). Recall windows / smart-list details pass true.
  var showsLooseEnds: Bool = true
```

Delete the local expansion state (line 10):

```swift
  @State private var expanded: Set<UUID> = []
```

Replace the whole `// LOOSE ENDS …` `section("Loose Ends") { … }` block (lines 51–60) with:

```swift
        // LOOSE ENDS (with inline verbatim provenance) — omitted when the middle already shows them.
        if showsLooseEnds {
          section("Loose Ends") {
            if looseEnds.isEmpty {
              Text("None open.").foregroundStyle(.secondary)
            } else {
              ForEach(looseEnds, id: \.looseEnd.id) { view in
                LooseEndRow(view: view) {
                  if allowsInspector { model.inspectedLooseEndID = view.looseEnd.id }
                }
              }
            }
          }
        }
```

Delete the now-unused `looseEndRow(_:)` method (the `@ViewBuilder private func looseEndRow(_ view: LooseEndView) -> some View { … }`, lines 96–130).

- [ ] **Step 3: Build**

Run the Global Constraints build recipe. Expected: clean build (no reference to the removed `expanded` / `looseEndRow`).

- [ ] **Step 4: Smoke-launch**

Run the Global Constraints smoke recipe (background, ~3s, kill). Expected: app launches and stays up; no crash in output.

- [ ] **Step 5: Commit**

```bash
git add Sources/PensieveApp/LooseEndRow.swift Sources/PensieveApp/DetailView.swift
git commit -F - <<'EOF'
refactor(app): extract shared LooseEndRow + DetailView.showsLooseEnds

Pulls the detail recall's loose-end row into a reusable view (internal
expand state + onSelect) so the middle worklist can reuse it verbatim.
Adds showsLooseEnds (default true → behavior unchanged) for the one-home
rule. No behavior change this task.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01Ya7ToQ9MrGVDLzHkDB1mg3
EOF
```

---

## Task 3: `AppModel` middle/detail routing API

Add the new state-derivation methods. `nodesForSelection()` stays for now (Task 4 removes it), so the app still builds and behaves as before.

**Files:**
- Modify: `Sources/PensieveApp/AppModel.swift`

**Interfaces:**
- Consumes: `NodeForest.children(of:in:)` (Task 1); existing `allNodes`, `briefingCards`, `lists`, `sidebarSelection`, `selectedNodeID`, `inspectedLooseEndID`, `node(_:)`, `looseEnds(forNode:)`, `SmartListKind.itemsKeyPath`.
- Produces:
  - `enum MiddleKind: Equatable { case nodes([Node]); case looseEndsOf(UUID) }`
  - `func middleKind() -> MiddleKind`
  - `func children(of id: UUID) -> [Node]`
  - `func selectMiddleNode(_ id: UUID)`
  - `func selectMiddleLooseEnd(_ id: UUID)`
  - `var middleTitle: String`
  - `var detailShowsLooseEnds: Bool`

- [ ] **Step 1: Add the `MiddleKind` enum**

In `Sources/PensieveApp/AppModel.swift`, at file scope (near `SidebarSelection`, after its declaration around line 45):

```swift
/// What the middle column shows for the current sidebar selection. `.looseEndsOf` carries the node id
/// so the view loads its loose ends off-`body` (via `.task`), never in a `body` DB query.
enum MiddleKind: Equatable {
  case nodes([Node])
  case looseEndsOf(UUID)
}
```

- [ ] **Step 2: Add the derivation methods**

Replace the existing `nodesForSelection()` method (lines 278–293) — keep it, and add the new methods **immediately after** it:

```swift
  /// The middle column's content for the current `sidebarSelection`. Pure/in-memory (children reads
  /// `allNodes`); the leaf case defers its loose-ends DB read to the view's `.task`.
  func middleKind() -> MiddleKind {
    switch sidebarSelection {
    case .briefing:
      return .nodes(briefingCards.map(\.node))
    case .smartList(let kind):
      return .nodes(lists[keyPath: kind.itemsKeyPath].map(\.project))
    case .node(let id):
      let kids = children(of: id)
      return kids.isEmpty ? .looseEndsOf(id) : .nodes(kids)
    case nil:
      return .nodes([])
    }
  }

  /// Direct children of `id`, name-sorted (thin wrapper over the pure Kit helper).
  func children(of id: UUID) -> [Node] { NodeForest.children(of: id, in: allNodes) }

  /// A middle-column node tap. In tree mode this DRILLS — the tapped node becomes the focused node, so
  /// the middle re-populates with its contents; from a smart list / briefing it only sets the detail
  /// node, leaving the triage list in place.
  func selectMiddleNode(_ id: UUID) {
    if case .node = sidebarSelection {
      sidebarSelection = .node(id)
    }
    selectedNodeID = id
  }

  /// A middle-column loose-end tap: point the ⌘⌥I inspector at it. Visibility stays user-controlled
  /// (⌘⌥I), matching the detail recall's rows.
  func selectMiddleLooseEnd(_ id: UUID) { inspectedLooseEndID = id }

  /// The middle column's title: the focused node's name in tree mode, else the app name. The app name
  /// is a proper noun — NOT localized.
  var middleTitle: String {
    if case .node(let id) = sidebarSelection, let n = node(id) { return n.name }
    return "Pensieve"
  }

  /// The detail recall shows its Loose Ends section EXCEPT when the middle is already showing this same
  /// node's loose ends (the focused leaf) — the one-home rule (no duplication).
  var detailShowsLooseEnds: Bool {
    if case .node(let fid) = sidebarSelection, selectedNodeID == fid, children(of: fid).isEmpty {
      return false
    }
    return true
  }
```

- [ ] **Step 3: Build**

Run the Global Constraints build recipe. Expected: clean build (new methods compile; `nodesForSelection` still present + used by the current `ContentListView` — may emit no warnings since both exist).

- [ ] **Step 4: Smoke-launch**

Run the Global Constraints smoke recipe. Expected: app launches, no crash (behavior unchanged this task).

- [ ] **Step 5: Commit**

```bash
git add Sources/PensieveApp/AppModel.swift
git commit -F - <<'EOF'
feat(app): AppModel middle/detail routing API for the IA rework

Adds MiddleKind + middleKind() (children, else a leaf's id whose loose
ends the view loads off-body), children(of:), selectMiddleNode (drills in
tree mode / detail-only from lists), selectMiddleLooseEnd, middleTitle,
and detailShowsLooseEnds (the one-home rule). nodesForSelection() kept
until the view switches over. No behavior change yet.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01Ya7ToQ9MrGVDLzHkDB1mg3
EOF
```

---

## Task 4: Flip the middle + detail (the IA change)

Rewrite `ContentListView` to render children-or-loose-ends from `middleKind()`, route taps through the new handlers, and title on the focused node. Pass `showsLooseEnds` to the main-window `DetailView`. Remove the now-unused `nodesForSelection()`. This is the task that changes visible behavior and removes the duplication.

**Files:**
- Modify: `Sources/PensieveApp/ContentListView.swift`
- Modify: `Sources/PensieveApp/RootView.swift`
- Modify: `Sources/PensieveApp/AppModel.swift` (remove `nodesForSelection()`)

**Interfaces:**
- Consumes: `AppModel.middleKind()`, `.middleTitle`, `.selectedNodeID`, `.selectMiddleNode(_:)`, `.selectMiddleLooseEnd(_:)`, `.looseEnds(forNode:)`, `.projectCount`, `.refreshToken`, `.detailShowsLooseEnds`, `.sidebarSelection`; `MiddleKind`; `LooseEndRow` (Task 2); `NodeBadge`, `NodeContextMenu`, `AppearanceStyle.kindLabel` (existing).
- Produces: the finished three-pane IA behavior; no new public symbols.

- [ ] **Step 1: Rewrite `ContentListView.swift`**

Replace the entire file with:

```swift
// Sources/PensieveApp/ContentListView.swift
import SwiftUI
import PensieveKit

struct ContentListView: View {
  @ObservedObject var model: AppModel
  // A focused leaf's loose ends, loaded off-`body` via `.task` (never a DB query in `body`).
  @State private var looseEnds: [LooseEndView] = []

  var body: some View {
    let kind = model.middleKind()
    Group {
      switch kind {
      case .nodes(let items):
        nodeList(items)
      case .looseEndsOf:
        looseEndList()
      }
    }
    .navigationTitle(model.middleTitle)
    .navigationSubtitle(subtitle(for: kind))
    // Load the focused leaf's loose ends. Re-runs on selection change AND ⌘R (refreshToken),
    // mirroring DetailView/InspectorView. Non-leaf kinds clear the list.
    .task(id: MiddleLoadKey(kind: kind, token: model.refreshToken)) {
      if case .looseEndsOf(let id) = kind {
        looseEnds = model.looseEnds(forNode: id)
      } else {
        looseEnds = []
      }
    }
  }

  @ViewBuilder private func nodeList(_ items: [Node]) -> some View {
    List(items, selection: Binding(
      get: { model.selectedNodeID },
      set: { if let id = $0 { model.selectMiddleNode(id) } })) { node in
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
    .overlay {
      if items.isEmpty { ContentUnavailableView("Nothing here", systemImage: "tray") }
    }
  }

  @ViewBuilder private func looseEndList() -> some View {
    List {
      ForEach(looseEnds, id: \.looseEnd.id) { view in
        LooseEndRow(view: view) { model.selectMiddleLooseEnd(view.looseEnd.id) }
      }
    }
    .overlay {
      if looseEnds.isEmpty { ContentUnavailableView("None open", systemImage: "checkmark.circle") }
    }
  }

  private func subtitle(for kind: MiddleKind) -> String {
    switch kind {
    case .nodes(let items):
      if case .node = model.sidebarSelection { return String(localized: "\(items.count) strands") }
      return String(localized: "\(model.projectCount) Projects")
    case .looseEndsOf:
      return String(localized: "\(looseEnds.count) loose ends")
    }
  }
}

/// A Hashable `.task` id for the middle. Derived from `MiddleKind` WITHOUT hashing the node array —
/// only the leaf id + refresh token matter for reloading loose ends.
private struct MiddleLoadKey: Hashable {
  let nodeID: UUID?
  let token: Int
  init(kind: MiddleKind, token: Int) {
    switch kind {
    case .looseEndsOf(let id): nodeID = id
    case .nodes: nodeID = nil
    }
    self.token = token
  }
}
```

- [ ] **Step 2: Pass `showsLooseEnds` from `RootView`**

In `Sources/PensieveApp/RootView.swift`, in `detailColumn` (line 11), change:

```swift
      DetailView(model: model, node: node, allowsInspector: true)
```

to:

```swift
      DetailView(model: model, node: node, allowsInspector: true, showsLooseEnds: model.detailShowsLooseEnds)
```

- [ ] **Step 3: Remove the unused `nodesForSelection()`**

In `Sources/PensieveApp/AppModel.swift`, delete the entire `nodesForSelection()` method (the `/// The middle-column list for the current sidebar selection.` doc comment through its closing brace — the former lines 278–293). Its callers are gone (`ContentListView` now uses `middleKind()`).

- [ ] **Step 4: Build**

Run the Global Constraints build recipe. Expected: clean build; no reference to `nodesForSelection`.

- [ ] **Step 5: Smoke-launch**

Run the Global Constraints smoke recipe. Expected: app launches, no crash.

- [ ] **Step 6: Commit**

```bash
git add Sources/PensieveApp/ContentListView.swift Sources/PensieveApp/RootView.swift Sources/PensieveApp/AppModel.swift
git commit -F - <<'EOF'
feat(app): three-pane IA — middle lists children/loose ends, no self-dup

Middle column now shows a focused node's children (or its loose ends when
a leaf) instead of the node-plus-children; tapping a child drills, tapping
a loose end points the ⌘⌥I inspector at it. Detail keeps its Loose Ends
section except for the focused leaf (one-home rule). Smart-list/briefing
lists stay on click. Removes nodesForSelection(). Loose ends load off-body
via .task (no DB query in body).

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01Ya7ToQ9MrGVDLzHkDB1mg3
EOF
```

---

## Task 5: Localize the new chrome strings (German)

Add the three new keys introduced in Task 4 to the String Catalog by hand (en base + `de`). `%lld strands` and `%lld loose ends` are `%lld`-formatted; `None open` is the middle empty-state title. (`Nothing here`, `%lld Projects`, and `captured` already exist and are reused.)

**Files:**
- Modify: `Sources/PensieveApp/Localizable.xcstrings`

**Interfaces:**
- Consumes: the literals emitted by `ContentListView.subtitle(for:)` (`"\(count) strands"` → key `"%lld strands"`; `"\(count) loose ends"` → key `"%lld loose ends"`) and `looseEndList()`'s `ContentUnavailableView("None open", …)` → key `"None open"`.
- Produces: complete en/de translations for those keys.

- [ ] **Step 1: Confirm which keys are missing**

Run:
```bash
python3 - <<'PY'
import json
s=json.load(open("Sources/PensieveApp/Localizable.xcstrings"))["strings"]
for k in ["%lld strands","%lld loose ends","None open"]:
    print(k, "PRESENT" if k in s else "MISSING")
PY
```
Expected: all three `MISSING`.

- [ ] **Step 2: Add the three keys with German translations**

Run this script (adds only missing keys; German matches the catalog's existing terms — `Strang`/`Stränge`, `Lose Enden`/`lose Enden`, `Keine offen`):

```bash
python3 - <<'PY'
import json, collections
p="Sources/PensieveApp/Localizable.xcstrings"
d=json.load(open(p))
s=d["strings"]
def add(key, en, de):
    s.setdefault(key, {})
    s[key].setdefault("localizations", {})
    for lang, val in (("en", en), ("de", de)):
        s[key]["localizations"][lang] = {"stringUnit": {"state": "translated", "value": val}}
add("%lld strands", "%lld strands", "%lld Stränge")
add("%lld loose ends", "%lld loose ends", "%lld lose Enden")
add("None open", "None open", "Keine offen")
d["strings"]=collections.OrderedDict(sorted(s.items()))
json.dump(d, open(p,"w"), ensure_ascii=False, indent=2)
open(p,"a").write("\n")
print("done")
PY
```

(Xcode will re-normalize the JSON whitespace on next open; that churn is expected and harmless.)

- [ ] **Step 3: Build and verify the German compiles into the bundle**

Run the Global Constraints build recipe, then:
```bash
plutil -p ./.build-xcode/Build/Products/Debug/Pensieve.app/Contents/Resources/de.lproj/Localizable.strings \
  | grep -iE "Stränge|lose Enden|Keine offen"
```
Expected: build succeeds and all three German values appear.

- [ ] **Step 4: Smoke-launch (German locale)**

Run the smoke binary in the background with the German locale, ~3s, kill:
```bash
env PENSIEVE_DB=/tmp/pv-ia.sqlite PENSIEVE_CAPTURE_DB=/tmp/pv-ia-cap.sqlite \
  ./.build-xcode/Build/Products/Debug/Pensieve.app/Contents/MacOS/Pensieve -AppleLanguages '(de)'
```
Expected: launches, no crash.

- [ ] **Step 5: Commit**

```bash
git add Sources/PensieveApp/Localizable.xcstrings
git commit -F - <<'EOF'
chore(l10n): German for the new middle chrome (strands/loose ends/None open)

Adds %lld strands (Stränge), %lld loose ends (lose Enden), None open
(Keine offen) — consistent with the catalog's existing Strang / Lose
Enden terms. Chrome only.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01Ya7ToQ9MrGVDLzHkDB1mg3
EOF
```

---

## Human-verify carries (need the built app + real store + plain `open` — can't be asserted headlessly)

Build: `xcodegen generate && xcodebuild -project Pensieve.xcodeproj -scheme Pensieve -configuration Debug -derivedDataPath ./.build-xcode build`, then `open ./.build-xcode/Build/Products/Debug/Pensieve.app`.

1. A **strand-less project** selected in the sidebar does **not** appear as a middle row; the middle shows its **loose ends**; the detail shows its recall **without** a duplicated Loose Ends section.
2. A **project with strands**: the middle lists the **strands** (not the project); the detail shows the **project** recall; clicking a strand **drills** (middle → the strand's loose ends, detail → the strand's recall). Clicking the parent in the sidebar returns to the siblings.
3. **What's Next / Dormant / Recently Active** and **Briefing cards**: clicking a project shows its recall in the detail and the **list stays** (triage preserved).
4. Clicking a loose end in the **middle worklist** and clicking one in a **smart-list detail recall** both drive the **same** ⌘⌥I inspector transcript (open the inspector to confirm).
5. **⌘⌥N** recall window still shows a node's loose ends (no middle pane).
6. The middle **title** reads the focused node's name with a **"N strands" / "N loose ends"** subtitle; smart-list/briefing keep **"Pensieve" / "N Projects"**.
7. `pensieve list` still matches the app tree after any organizing write (create/rename/move/merge via the context menus).
8. German renders in situ (`open` with the system set to German, or the `-AppleLanguages '(de)'` launch) for the new title/subtitle and empty state.

## Self-Review (completed while writing)

- **Spec coverage:** middle=children→Task 4; leaf→loose-ends→Tasks 3+4; detail=focused recall→existing + Task 4; drill→`selectMiddleNode` (Task 3/4); smart-list stays→`selectMiddleNode` else-branch (Task 3/4); loose-end→inspector everywhere→shared `LooseEndRow` (Task 2) + `selectMiddleLooseEnd` (Task 3/4); one-home rule→`showsLooseEnds`/`detailShowsLooseEnds` (Tasks 2–4); inspector kept→no removal; Kit helper→Task 1; recall windows unaffected→default flag; l10n→Task 5. No gaps.
- **Type consistency:** `MiddleKind` (`.nodes`/`.looseEndsOf`) used identically across Tasks 3–4; `LooseEndRow(view:onSelect:)` and `showsLooseEnds` names match between Tasks 2 and 4; `LooseEndView` field access (`.looseEnd.id/.text/.quote/.role`, `.occurredAt`, `.ageDays`) matches the original `DetailView`.
- **Placeholder scan:** none.
