# Pensieve.app Slice 1 — Read-only Three-Pane Core — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the v0.1 heartbeat window with a live read-only three-pane `NavigationSplitView` app: an action-first sidebar (What's Next / Dormant / Recently Active smart lists + the typed node tree), a middle list of the selected scope's nodes, and a detail recall view (What It Is, Recent Activity, Loose Ends with inline verbatim provenance). Drains the capture spool on launch.

**Architecture:** All *derivation* logic (smart-list bucketing, tree building) lands in `PensieveKit` where the `PensieveKitTests` suite can TDD it; the `PensieveApp` target stays a thin SwiftUI shell (`AppModel` + views) that calls those helpers and the existing query layer (`NextQueries`, `ProjectQueries`, `LooseEndQueries`). The app opens the canonical store with a read/write `DatabaseWriter` (needed for the launch drain) but only ever reads it for display. Liveness in this slice is a 3 s `Timer` refresh, mirroring the existing `HeartbeatModel` (upgrading to GRDB `ValueObservation` is a later slice).

**Tech Stack:** Swift 6, SwiftUI + AppKit host (unbundled `NSApplication`, no Xcode.app), SQLiteData (GRDB-backed), Swift Testing.

## Global Constraints

- **Spec:** `docs/superpowers/specs/2026-07-05-pensieve-app-three-pane-design.md` (slice 1 of its build sequence).
- **Run tests with `./scripts/test.sh`** (optionally `--filter <name>`) — **never** plain `swift test` (this machine is Command Line Tools–only). `swift build` / `swift run` work normally.
- **SQLiteData predicates use `.eq(x)`, NOT `== x`** (e.g. `.where { $0.name.eq(name) }`). `==` is `unavailable`.
- **Reads only touch the canonical store; the app never writes canonical rows in this slice** except via the existing `Ingester.drain()` (spool → events), which is the sanctioned writer.
- **Grounded-only:** every surfaced item derives from captured rows. Do **not** add a "Blocked" or "Roads Not Taken" smart list here (no grounded signal / no fork backend yet) — those are later slices.
- **No LLM calls in this slice.** Detail fields are deterministic (node metadata + captured events + stored loose-end quotes). `SummaryBuilder` narration is a later slice.
- Store URLs resolve via the existing `Stores` enum in `Sources/PensieveApp/main.swift` (honors `PENSIEVE_DB` / `PENSIEVE_CAPTURE_DB`).
- **No Python, ever. Swift only.**

## File Structure

**Create:**
- `Sources/PensieveKit/Query/NodeForest.swift` — pure forest builder: `[Node] → [NodeForestNode]` (parent/child nesting, orphan-promotion, cycle-safe). Tested.
- `Sources/PensieveKit/Query/SmartLists.swift` — derives What's Next / Dormant / Recently Active from `NextQueries.ranked`. Tested.
- `Sources/PensieveApp/AppModel.swift` — `ObservableObject` owning the `DatabaseWriter`; launch drain; 3 s refresh; `@Published` sidebar/detail state; thin glue to the query layer.
- `Sources/PensieveApp/SidebarView.swift` — smart lists + node-tree outline, one selection binding.
- `Sources/PensieveApp/ContentListView.swift` — middle column: the node list for the current sidebar selection.
- `Sources/PensieveApp/DetailView.swift` — recall view with inline-expand provenance.
- `Sources/PensieveApp/RootView.swift` — the `NavigationSplitView` assembling the three columns.
- `Tests/PensieveKitTests/NodeForestTests.swift`
- `Tests/PensieveKitTests/SmartListsTests.swift`

**Modify:**
- `Sources/PensieveApp/main.swift` — swap the heartbeat window for `RootView`; widen the window; start `AppModel`.

---

### Task 1: `NodeForest` — pure forest builder

**Files:**
- Create: `Sources/PensieveKit/Query/NodeForest.swift`
- Test: `Tests/PensieveKitTests/NodeForestTests.swift`

**Interfaces:**
- Consumes: `Node` (from `PensieveKit/Model/Node.swift`: `id: UUID`, `name: String`, `parentID: UUID?`).
- Produces:
  - `struct NodeForestNode: Identifiable, Equatable, Sendable { let node: Node; let children: [NodeForestNode]; var id: UUID { node.id } }`
  - `enum NodeForest { static func build(_ nodes: [Node]) -> [NodeForestNode] }`
  - **Naming note:** do NOT name this `NodeTree` — `Sources/PensieveKit/Query/NodeCommands.swift:53` already declares `public enum NodeTree` (the CLI's indented-tree *renderer*, `render(_:) -> [String]`). This new type is a distinct structured builder for SwiftUI; leave the existing `NodeTree` untouched.
  - Contract: roots = nodes with `parentID == nil` OR whose parent isn't in the input set (orphans promoted to roots, never dropped). Children and roots are sorted by `name`. Nodes reachable only through a parent-cycle are omitted (islanded) — the recursion carries a `visited` set so it can never loop.

- [ ] **Step 1: Write the failing test**

```swift
// Tests/PensieveKitTests/NodeForestTests.swift
import Foundation
import Testing
@testable import PensieveKit

@Test func buildsNestedForestSortedByName() {
  let root = Node(name: "alpha", kind: "project")
  let childB = Node(name: "b-strand", parentID: root.id, kind: "strand")
  let childA = Node(name: "a-strand", parentID: root.id, kind: "strand")
  let grandchild = Node(name: "deep", parentID: childA.id, kind: "strand")
  let other = Node(name: "zeta", kind: "project")

  let forest = NodeForest.build([grandchild, childB, root, other, childA])

  #expect(forest.map(\.node.name) == ["alpha", "zeta"])           // roots sorted
  #expect(forest[0].children.map(\.node.name) == ["a-strand", "b-strand"])  // children sorted
  #expect(forest[0].children[0].children.map(\.node.name) == ["deep"])
  #expect(forest[1].children.isEmpty)
}

@Test func promotesOrphanWithMissingParentToRoot() {
  let ghostParent = UUID()
  let orphan = Node(name: "orphan", parentID: ghostParent, kind: "strand")
  let realRoot = Node(name: "real", kind: "project")

  let forest = NodeForest.build([orphan, realRoot])

  // parent isn't in the set → orphan is promoted, never dropped
  #expect(Set(forest.map(\.node.name)) == ["orphan", "real"])
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `./scripts/test.sh --filter NodeForest`
Expected: FAIL — `cannot find 'NodeForest' in scope`.

- [ ] **Step 3: Write minimal implementation**

```swift
// Sources/PensieveKit/Query/NodeForest.swift
import Foundation

/// A node plus its child nodes, ready for SwiftUI `OutlineGroup`. Pure value type.
public struct NodeForestNode: Identifiable, Equatable, Sendable {
  public let node: Node
  public let children: [NodeForestNode]
  public var id: UUID { node.id }
  public init(node: Node, children: [NodeForestNode]) {
    self.node = node; self.children = children
  }
}

/// Turns a flat `[Node]` into a rooted forest by `parentID`. Read-only, deterministic.
public enum NodeForest {
  public static func build(_ nodes: [Node]) -> [NodeForestNode] {
    let byID = Dictionary(nodes.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    var childrenByParent: [UUID: [Node]] = [:]
    var roots: [Node] = []
    for n in nodes {
      if let pid = n.parentID, byID[pid] != nil {
        childrenByParent[pid, default: []].append(n)
      } else {
        roots.append(n)   // nil parent, or parent absent from the set → promote to root
      }
    }
    func make(_ n: Node, _ visited: Set<UUID>) -> NodeForestNode {
      var visited = visited
      visited.insert(n.id)
      let kids = (childrenByParent[n.id] ?? [])
        .filter { !visited.contains($0.id) }        // cycle guard: can never recurse forever
        .sorted { $0.name < $1.name }
        .map { make($0, visited) }
      return NodeForestNode(node: n, children: kids)
    }
    return roots.sorted { $0.name < $1.name }.map { make($0, []) }
  }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `./scripts/test.sh --filter NodeForest`
Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/PensieveKit/Query/NodeForest.swift Tests/PensieveKitTests/NodeForestTests.swift
git commit -m "feat: NodeForest — pure [Node] → forest builder for the app sidebar"
```

---

### Task 2: `SmartLists` — derive What's Next / Dormant / Recently Active

**Files:**
- Create: `Sources/PensieveKit/Query/SmartLists.swift`
- Test: `Tests/PensieveKitTests/SmartListsTests.swift`

**Interfaces:**
- Consumes: `NextQueries.ranked(_ db: any DatabaseWriter, now: Date) throws -> [NextItem]` where `NextItem { project: Node; openLooseEnds: Int; daysDormant: Int; score: Double }`.
- Produces:
  - `struct SmartLists: Sendable { let whatsNext: [NextItem]; let dormant: [NextItem]; let recentlyActive: [NextItem] }`
  - `static func compute(_ db: any DatabaseWriter, now: Date, dormantAfterDays: Int = 14, activeWithinDays: Int = 3) throws -> SmartLists`
  - Contract: `whatsNext` = the full ranked list (score desc, as-is). `dormant` = items with `daysDormant >= dormantAfterDays`, most-dormant first. `recentlyActive` = items with `daysDormant <= activeWithinDays`, most-recent (smallest dormancy) first. Overlap between lists is expected and fine.

- [ ] **Step 1: Write the failing test**

```swift
// Tests/PensieveKitTests/SmartListsTests.swift
import Foundation
import Testing
import SQLiteData
@testable import PensieveKit

@Test func bucketsRankedItemsIntoSmartLists() throws {
  let db = try openCanonicalDatabase(at: tempURL("smartlists"))
  let resolver = ProjectResolver(db: db)
  let (recentNode, rs) = try resolver.resolve(path: "/p/recent", kind: SourceKind.claudeCode)
  let (oldNode, os) = try resolver.resolve(path: "/p/old", kind: SourceKind.claudeCode)
  let now = Date()
  let old = Calendar.current.date(byAdding: .day, value: -30, to: now)!
  try db.write { db in
    try Event.insert {
      Event(nodeID: recentNode.id, sourceID: rs.id, occurredAt: now, kind: CaptureKind.ccSession,
            summary: "s", detailJSON: "{}", fingerprint: "r1")
    }.execute(db)
    try Event.insert {
      Event(nodeID: oldNode.id, sourceID: os.id, occurredAt: old, kind: CaptureKind.ccSession,
            summary: "s", detailJSON: "{}", fingerprint: "o1")
    }.execute(db)
  }

  let lists = try SmartLists.compute(db, now: now, dormantAfterDays: 14, activeWithinDays: 3)

  #expect(lists.whatsNext.count == 2)                                   // all active nodes
  #expect(lists.dormant.map(\.project.id) == [oldNode.id])             // only the 30-day-old one
  #expect(lists.recentlyActive.map(\.project.id) == [recentNode.id])   // only the fresh one
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `./scripts/test.sh --filter SmartLists`
Expected: FAIL — `cannot find 'SmartLists' in scope`.

- [ ] **Step 3: Write minimal implementation**

```swift
// Sources/PensieveKit/Query/SmartLists.swift
import Foundation
import SQLiteData

/// The action-first sidebar's grounded buckets, derived from the deterministic `NextQueries` ranking.
/// No model, no invented signal. "Blocked" and "Roads Not Taken" are intentionally absent until their
/// grounded signal / fork backend exist.
public struct SmartLists: Sendable {
  public let whatsNext: [NextItem]
  public let dormant: [NextItem]
  public let recentlyActive: [NextItem]

  public static func compute(_ db: any DatabaseWriter, now: Date,
                             dormantAfterDays: Int = 14,
                             activeWithinDays: Int = 3) throws -> SmartLists {
    let ranked = try NextQueries.ranked(db, now: now)
    let dormant = ranked
      .filter { $0.daysDormant >= dormantAfterDays }
      .sorted { $0.daysDormant > $1.daysDormant }
    let recentlyActive = ranked
      .filter { $0.daysDormant <= activeWithinDays }
      .sorted { $0.daysDormant < $1.daysDormant }
    return SmartLists(whatsNext: ranked, dormant: dormant, recentlyActive: recentlyActive)
  }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `./scripts/test.sh --filter SmartLists`
Expected: PASS (1 test).

- [ ] **Step 5: Commit**

```bash
git add Sources/PensieveKit/Query/SmartLists.swift Tests/PensieveKitTests/SmartListsTests.swift
git commit -m "feat: SmartLists — grounded What's Next / Dormant / Recently Active buckets"
```

---

### Task 3: `AppModel` + shell skeleton + launch drain

**Files:**
- Create: `Sources/PensieveApp/AppModel.swift`
- Create: `Sources/PensieveApp/RootView.swift`
- Modify: `Sources/PensieveApp/main.swift`

**Interfaces:**
- Consumes: `Stores` (existing in `main.swift`), `openCanonicalDatabase(at:) throws -> any DatabaseWriter`, `CaptureSpool(at:) throws`, `Ingester(spool:db:llm:).drain() async throws -> Int`, `SmartLists.compute`, `ProjectQueries.all`, `NodeForest.build`.
- Produces (used by Tasks 4–5):
  - `enum SidebarSelection: Hashable { case smartList(SmartListKind); case node(UUID) }`
  - `enum SmartListKind: String, CaseIterable, Hashable { case whatsNext, dormant, recentlyActive }` with `var title: String` and `var symbol: String`.
  - `@MainActor final class AppModel: ObservableObject` exposing `@Published var lists: SmartLists`, `@Published var forest: [NodeForestNode]`, `@Published var sidebarSelection: SidebarSelection?`, `@Published var selectedNodeID: UUID?`; methods `start()`, `refresh()`, `nodesForSelection() -> [Node]`, `node(_ id: UUID) -> Node?`, and `detail(for node: Node) -> (status: ProjectStatus, looseEnds: [LooseEndView])`.

- [ ] **Step 1: Write `AppModel`**

```swift
// Sources/PensieveApp/AppModel.swift
import Foundation
import SwiftUI
import PensieveKit

enum SmartListKind: String, CaseIterable, Hashable {
  case whatsNext, dormant, recentlyActive
  var title: String {
    switch self {
    case .whatsNext: return "What's Next"
    case .dormant: return "Dormant"
    case .recentlyActive: return "Recently Active"
    }
  }
  var symbol: String {
    switch self {
    case .whatsNext: return "star"
    case .dormant: return "pause.circle"
    case .recentlyActive: return "dot.radiowaves.left.and.right"
    }
  }
}

enum SidebarSelection: Hashable {
  case smartList(SmartListKind)
  case node(UUID)
}

@MainActor
final class AppModel: ObservableObject {
  @Published var lists = SmartLists(whatsNext: [], dormant: [], recentlyActive: [])
  @Published var forest: [NodeForestNode] = []
  @Published var sidebarSelection: SidebarSelection? = .smartList(.whatsNext)
  @Published var selectedNodeID: UUID?

  private var db: (any DatabaseWriter)?
  private var allNodes: [Node] = []
  private var timer: Timer?

  func start() {
    // Open the canonical store read/write (needed for the launch drain). Missing store degrades to empty.
    db = try? openCanonicalDatabase(at: Stores.canonicalURL)
    Task { await drainThenRefresh() }
    timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
      Task { @MainActor in self?.refresh() }
    }
  }

  private func drainThenRefresh() async {
    if let db, let spool = try? CaptureSpool(at: Stores.spoolURL) {
      _ = try? await Ingester(spool: spool, db: db).drain()   // no LLM: spool → events only
    }
    refresh()
  }

  func refresh() {
    guard let db else { return }
    let now = Date()
    lists = (try? SmartLists.compute(db, now: now)) ?? lists
    allNodes = (try? ProjectQueries.all(db)) ?? allNodes
    forest = NodeForest.build(allNodes)
  }

  func node(_ id: UUID) -> Node? { allNodes.first { $0.id == id } }

  /// The middle-column list for the current sidebar selection.
  func nodesForSelection() -> [Node] {
    switch sidebarSelection {
    case .smartList(let kind):
      let items: [NextItem]
      switch kind {
      case .whatsNext: items = lists.whatsNext
      case .dormant: items = lists.dormant
      case .recentlyActive: items = lists.recentlyActive
      }
      return items.map(\.project)
    case .node(let id):
      // A tree pick: show that node plus its direct child strands.
      guard let selected = node(id) else { return [] }
      let children = allNodes.filter { $0.parentID == id }.sorted { $0.name < $1.name }
      return [selected] + children
    case nil:
      return []
    }
  }

  func detail(for node: Node) -> (status: ProjectStatus, looseEnds: [LooseEndView]) {
    guard let db else {
      return (ProjectStatus(project: node, recentEvents: []), [])
    }
    let now = Date()
    let status = (try? ProjectQueries.status(db, node: node, limit: 15))
      ?? ProjectStatus(project: node, recentEvents: [])
    let ends = (try? LooseEndQueries.open(db, nodeID: node.id, now: now)) ?? []
    return (status, ends)
  }
}
```

- [ ] **Step 2: Write the `RootView` shell (placeholders for columns filled in Tasks 4–5)**

```swift
// Sources/PensieveApp/RootView.swift
import SwiftUI
import PensieveKit

struct RootView: View {
  @ObservedObject var model: AppModel

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
      } else {
        ContentUnavailableView("Select a project", systemImage: "sidebar.left")
      }
    }
    .navigationTitle("Pensieve")
  }
}
```

- [ ] **Step 3: Add temporary stubs so the project compiles before Tasks 4–5**

Add these minimal stubs to the bottom of `RootView.swift` (they will be MOVED to their own files and fleshed out in Tasks 4 and 5 — do not leave them here):

```swift
// TEMP STUBS — replaced in Task 4 (SidebarView) and Task 5 (DetailView/ContentListView)
struct SidebarView: View {
  @ObservedObject var model: AppModel
  var body: some View { Text("sidebar").frame(minWidth: 200) }
}
struct ContentListView: View {
  @ObservedObject var model: AppModel
  var body: some View { Text("list").frame(minWidth: 240) }
}
struct DetailView: View {
  @ObservedObject var model: AppModel
  let node: Node
  var body: some View { Text(node.name) }
}
```

- [ ] **Step 4: Rewrite `main.swift` to host `RootView`**

Replace the entire contents of `Sources/PensieveApp/main.swift` with (keep the `Stores` enum exactly as-is at the top):

```swift
import AppKit
import Foundation
import SwiftUI
import PensieveKit

/// Resolves store locations the same way the CLI does (honors PENSIEVE_DB / PENSIEVE_CAPTURE_DB).
enum Stores {
  static var canonicalURL: URL {
    if let o = ProcessInfo.processInfo.environment["PENSIEVE_DB"] { return URL(fileURLWithPath: o) }
    return PensievePaths.canonicalURL()
  }
  static var spoolURL: URL {
    if let o = ProcessInfo.processInfo.environment["PENSIEVE_CAPTURE_DB"] { return URL(fileURLWithPath: o) }
    return PensievePaths.captureURL()
  }
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let model = AppModel()
model.start()
let window = NSWindow(
  contentRect: NSRect(x: 0, y: 0, width: 900, height: 560),
  styleMask: [.titled, .closable, .miniaturizable, .resizable],
  backing: .buffered, defer: false)
window.title = "Pensieve"
window.center()
window.contentView = NSHostingView(rootView: RootView(model: model))
window.makeKeyAndOrderFront(nil)
app.activate(ignoringOtherApps: true)
app.run()
```

- [ ] **Step 5: Build and run to verify the shell**

Run: `swift build`
Expected: builds cleanly.

Run: `swift run PensieveApp`
Expected: a resizable 900×560 window titled "Pensieve" opens showing three columns (stub "sidebar" / "list" / "Select a project" placeholder). The launch drain runs silently against the real store. Close the window to exit.

- [ ] **Step 6: Commit**

```bash
git add Sources/PensieveApp/AppModel.swift Sources/PensieveApp/RootView.swift Sources/PensieveApp/main.swift
git commit -m "feat: three-pane app shell (AppModel + NavigationSplitView) with launch spool drain"
```

---

### Task 4: Sidebar — smart lists + node tree

**Files:**
- Create: `Sources/PensieveApp/SidebarView.swift`
- Modify: `Sources/PensieveApp/RootView.swift` (remove the `SidebarView` stub)

**Interfaces:**
- Consumes: `AppModel.lists`, `AppModel.forest`, `AppModel.sidebarSelection`, `SmartListKind`, `SidebarSelection`, `NodeForestNode`, `MonitorSnapshot.gather` (for the footer status dot).

- [ ] **Step 1: Remove the `SidebarView` stub from `RootView.swift`**

Delete the `struct SidebarView { … }` stub block added in Task 3, Step 3. Leave the `ContentListView` and `DetailView` stubs for now.

- [ ] **Step 2: Write the real `SidebarView`**

```swift
// Sources/PensieveApp/SidebarView.swift
import SwiftUI
import PensieveKit

struct SidebarView: View {
  @ObservedObject var model: AppModel

  var body: some View {
    List(selection: Binding(
      get: { model.sidebarSelection },
      set: { newValue in
        model.sidebarSelection = newValue
        // Selecting a smart list clears the detail until a middle-column row is picked;
        // selecting a tree node jumps detail straight to it.
        if case .node(let id) = newValue { model.selectedNodeID = id }
        else { model.selectedNodeID = nil }
      })) {
      Section("Smart Lists") {
        smartRow(.whatsNext, count: model.lists.whatsNext.count)
        smartRow(.dormant, count: model.lists.dormant.count)
        smartRow(.recentlyActive, count: model.lists.recentlyActive.count)
      }
      Section("Projects") {
        OutlineGroup(model.forest, children: \.children) { item in
          Label(item.node.name, systemImage: symbol(for: item.node.kind))
            .tag(SidebarSelection.node(item.node.id))
        }
      }
    }
    .listStyle(.sidebar)
    .safeAreaInset(edge: .bottom) { StatusFooter() }
  }

  private func smartRow(_ kind: SmartListKind, count: Int) -> some View {
    Label {
      HStack {
        Text(kind.title)
        Spacer()
        Text("\(count)").foregroundStyle(.secondary).monospacedDigit()
      }
    } icon: {
      Image(systemName: kind.symbol)
    }
    .tag(SidebarSelection.smartList(kind))
  }

  private func symbol(for kind: String) -> String {
    switch kind {
    case "domain": return "folder"
    case "strand": return "arrow.triangle.branch"
    default: return "shippingbox"
    }
  }
}

/// Reuses the read-only heartbeat kernel for a tiny liveness dot at the sidebar's foot.
private struct StatusFooter: View {
  @State private var snapshot = MonitorSnapshot(status: .notSetUp, lastCaptureAt: nil,
                                                spoolPending: 0, eventCount: 0, looseEndCount: 0)
  private let tick = Timer.publish(every: 3, on: .main, in: .common).autoconnect()

  var body: some View {
    HStack(spacing: 6) {
      Circle().fill(color).frame(width: 8, height: 8)
      Text(label).font(.caption).foregroundStyle(.secondary)
      Spacer()
    }
    .padding(.horizontal, 12).padding(.vertical, 8)
    .onAppear(perform: refresh)
    .onReceive(tick) { _ in refresh() }
  }
  private func refresh() {
    snapshot = MonitorSnapshot.gather(canonicalURL: Stores.canonicalURL, spoolURL: Stores.spoolURL)
  }
  private var color: Color {
    switch snapshot.status { case .active: return .green; case .idle: return .secondary; case .notSetUp: return .orange }
  }
  private var label: String {
    switch snapshot.status { case .active: return "capturing"; case .idle: return "idle"; case .notSetUp: return "not set up" }
  }
}
```

- [ ] **Step 3: Build and run to verify the sidebar**

Run: `swift build`
Expected: builds cleanly.

Run: `swift run PensieveApp`
Expected: the sidebar shows a **Smart Lists** section (What's Next / Dormant / Recently Active with live counts) and a **Projects** section with the real node tree (expandable to strands). A green/orange status dot sits at the bottom. Clicking a smart list highlights it; clicking a project row selects it (detail still stubbed). Counts match `swift run pensieve next` roughly (What's Next count = active nodes).

- [ ] **Step 4: Commit**

```bash
git add Sources/PensieveApp/SidebarView.swift Sources/PensieveApp/RootView.swift
git commit -m "feat: action-first sidebar — smart lists + node tree + heartbeat footer"
```

---

### Task 5: Middle list + detail recall view with inline provenance

**Files:**
- Create: `Sources/PensieveApp/ContentListView.swift`
- Create: `Sources/PensieveApp/DetailView.swift`
- Modify: `Sources/PensieveApp/RootView.swift` (remove the `ContentListView` and `DetailView` stubs)

**Interfaces:**
- Consumes: `AppModel.nodesForSelection()`, `AppModel.selectedNodeID`, `AppModel.detail(for:)`, `Node`, `Event`, `LooseEndView` (`{ looseEnd: LooseEnd, occurredAt: Date, ageDays: Int }`), `LooseEnd` (`{ text, quote, role, sourceMessageIndex }`).

- [ ] **Step 1: Remove the `ContentListView` and `DetailView` stubs from `RootView.swift`**

Delete both stub structs added in Task 3, Step 3. `RootView.swift` should now contain only `RootView`.

- [ ] **Step 2: Write `ContentListView` (middle column)**

```swift
// Sources/PensieveApp/ContentListView.swift
import SwiftUI
import PensieveKit

struct ContentListView: View {
  @ObservedObject var model: AppModel

  var body: some View {
    List(model.nodesForSelection(), selection: $model.selectedNodeID) { node in
      VStack(alignment: .leading, spacing: 2) {
        Text(node.name)
        Text(node.kind).font(.caption).foregroundStyle(.secondary)
      }
      .tag(node.id)
    }
    .overlay {
      if model.nodesForSelection().isEmpty {
        ContentUnavailableView("Nothing here", systemImage: "tray")
      }
    }
  }
}
```

- [ ] **Step 3: Write `DetailView` (the recall view + inline provenance)**

```swift
// Sources/PensieveApp/DetailView.swift
import SwiftUI
import PensieveKit

struct DetailView: View {
  @ObservedObject var model: AppModel
  let node: Node
  @State private var expanded: Set<UUID> = []

  private var data: (status: ProjectStatus, looseEnds: [LooseEndView]) { model.detail(for: node) }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        // WHAT IT IS
        VStack(alignment: .leading, spacing: 4) {
          Text(node.name).font(.largeTitle).bold()
          Text("\(node.kind) · \(node.state)").foregroundStyle(.secondary)
          if !node.description.isEmpty {
            Text(node.description).font(.body).padding(.top, 2)
          }
        }

        // LOOSE ENDS (with inline verbatim provenance)
        section("Loose Ends") {
          let ends = data.looseEnds
          if ends.isEmpty {
            Text("None open.").foregroundStyle(.secondary)
          } else {
            ForEach(ends, id: \.looseEnd.id) { view in
              looseEndRow(view)
            }
          }
        }

        // RECENT ACTIVITY (deterministic; LLM narration is a later slice)
        section("Recent Activity") {
          let events = data.status.recentEvents
          if events.isEmpty {
            Text("No captured activity.").foregroundStyle(.secondary)
          } else {
            ForEach(events) { event in
              HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(event.occurredAt, format: .dateTime.month().day())
                  .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                  .frame(width: 52, alignment: .leading)
                Text(event.summary).font(.callout)
                Spacer()
                Text(event.kind).font(.caption2).foregroundStyle(.tertiary)
              }
            }
          }
        }
      }
      .padding(24)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  @ViewBuilder private func looseEndRow(_ view: LooseEndView) -> some View {
    let id = view.looseEnd.id
    let isOpen = expanded.contains(id)
    VStack(alignment: .leading, spacing: 6) {
      Button {
        if isOpen { expanded.remove(id) } else { expanded.insert(id) }
      } label: {
        HStack(spacing: 6) {
          Image(systemName: isOpen ? "chevron.down" : "chevron.right")
            .font(.caption2).foregroundStyle(.secondary)
          Text(view.looseEnd.text)
          Spacer()
        }
      }
      .buttonStyle(.plain)

      if isOpen {
        // The provenance: verbatim quote + where it came from. North-star made visible.
        VStack(alignment: .leading, spacing: 4) {
          Text(view.looseEnd.quote)
            .italic()
            .padding(.leading, 10)
            .overlay(alignment: .leading) {
              Rectangle().fill(.orange).frame(width: 3)
            }
          Text("\(view.looseEnd.role.isEmpty ? "captured" : view.looseEnd.role) · \(view.occurredAt, format: .dateTime.year().month().day()) · \(view.ageDays)d ago")
            .font(.caption).foregroundStyle(.secondary)
        }
        .padding(.leading, 18)
      }
    }
    .padding(.vertical, 2)
  }

  @ViewBuilder private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(title.uppercased()).font(.caption).bold().foregroundStyle(.secondary)
      content()
    }
  }
}
```

- [ ] **Step 4: Build and run — full slice verification**

Run: `swift build`
Expected: builds cleanly.

Run: `swift run PensieveApp`
Expected, against the live dogfooding store:
1. Sidebar smart lists + tree populate (from Task 4).
2. Clicking **What's Next** → middle column lists ranked projects; clicking one → detail shows its name, kind·state, description, **Loose Ends**, and **Recent Activity** (real commit/session summaries).
3. Clicking a loose end **expands inline** to reveal the orange-barred **verbatim quote** + a provenance line (role · date · age). Clicking again collapses it.
4. Clicking a **project in the sidebar tree** → detail jumps straight to it; its child strands appear in the middle list.
5. Leaving the app open ~5 s and making a commit in a tracked repo → within a refresh cycle the counts/activity update (launch drain + 3 s timer).

- [ ] **Step 5: Run the full test suite**

Run: `./scripts/test.sh`
Expected: all tests pass (existing 96+ plus the 3 new from Tasks 1–2). No regressions.

- [ ] **Step 6: Commit**

```bash
git add Sources/PensieveApp/ContentListView.swift Sources/PensieveApp/DetailView.swift Sources/PensieveApp/RootView.swift
git commit -m "feat: middle list + detail recall view with inline verbatim provenance"
```

---

## Self-Review

**Spec coverage (slice 1 bullets):**
- three-column `NavigationSplitView` → Task 3 (`RootView`). ✓
- action-first sidebar: What's Next / Dormant / Recently Active + tree → Tasks 2 + 4. ✓ (Blocked / Roads Not Taken intentionally deferred — no grounded signal / no fork backend; stated in Global Constraints.)
- detail recall view: What It Is / Loose Ends / recent activity(timeline) → Task 5. ✓ (Last Work Done *LLM narration* deferred; deterministic Recent Activity shown instead — stated in Architecture + Global Constraints.)
- inline-expand provenance → Task 5, `looseEndRow`. ✓ (⌘⌥I inspector + jump-to-timeline are later slices per the spec's slice 3.)
- live updates → Task 3 `Timer` refresh. ✓ (`ValueObservation` upgrade deferred, stated in Architecture.)
- app-launch spool drain → Task 3 `drainThenRefresh`. ✓

**Placeholder scan:** the only stubs are the explicitly-temporary column stubs in Task 3 Step 3, each removed in Tasks 4–5 (Task 4 Step 1, Task 5 Step 1). No `TODO`/`TBD` in shipped code.

**Type consistency:** `NextItem.project: Node`, `LooseEndView.looseEnd/occurredAt/ageDays`, `LooseEnd.text/quote/role`, `ProjectStatus.recentEvents: [Event]`, `SidebarSelection`/`SmartListKind` are used identically across tasks. `AppModel` method names (`nodesForSelection`, `detail(for:)`, `node(_:)`) match their call sites in `ContentListView`/`DetailView`/`RootView`.

**Deferred to later slices (not gaps):** Briefing home + ⌘K (slice 2); inspector + window tabbing + light/dark polish + LLM narration + ValueObservation (slice 3); in-app writes (slice 4); talk-to-system (slice 5); forks surface (slice 6, gated on backend).

## Execution Handoff

**Plan complete and saved to `docs/superpowers/plans/2026-07-05-pensieve-app-slice1-three-pane-core.md`. Two execution options:**

**1. Subagent-Driven (recommended)** — I dispatch a fresh subagent per task, review between tasks, fast iteration.

**2. Inline Execution** — Execute tasks in this session using executing-plans, batch execution with checkpoints.

**Which approach?**
