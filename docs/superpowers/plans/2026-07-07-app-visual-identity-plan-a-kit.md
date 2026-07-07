# Visual Identity — Plan A (PensieveKit foundation) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship the SwiftUI-free PensieveKit foundation for the app's visual-identity & UX work: per-node `icon`/`colorTag` columns (migration v8), the kind/source style tables + appearance resolver, atomic node creation with appearance, and a manual-only cascade delete.

**Architecture:** Additive migration + two new `String` columns on `Node`. A new `VisualIdentity.swift` holds pure string tables (`NodeKindStyle`, `EventSourceStyle`), an `AppearanceIcon` enum + parser, and a `Node.appearance` resolver — **no SwiftUI** (the CLI links Kit; the app resolves strings → `Color`/`Image`/localized `Text`). `NodeCommands` gains `add(…, icon:, colorTag:)` and `delete`/`subtreeHasSources`.

**Tech Stack:** Swift 6, SQLiteData (GRDB-backed), Swift Testing (`import Testing`, `@Test`, `#expect`).

## Global Constraints

- **SQLiteData predicates use `.eq(x)`, NOT `== x`.** IN-style filters: use a per-id loop (matches `ProjectResolver.group`), not an unverified array predicate.
- Tables are **STRICT**; PKs are `UUID`; column/property names must match `@Table` names exactly.
- Kind strings live in `NodeKind`; capture kinds in `CaptureKind`; source kinds in `SourceKind` — reuse the constants.
- **PensieveKit must not `import SwiftUI`** (the CLI links it). Colors/icons are stored/returned as strings.
- Migrations are **additive**; the trust gate and capture path stay untouched. Next version is **v8** (`v7-incremental-extraction` already exists).
- Run tests with `./scripts/test.sh` (thin `swift test` passthrough); `--filter <name>` to scope.
- Commit messages: use `git commit -F` (backticks in `-m` get shell-executed). Keep the `Co-Authored-By:` + `Claude-Session:` trailers.

---

### Task A1: `Node` appearance columns + migration v8

**Files:**
- Modify: `Sources/PensieveKit/Model/Node.swift`
- Modify: `Sources/PensieveKit/Store/CanonicalStore.swift` (after the `v7-incremental-extraction` block, ~line 129-135)
- Test: `Tests/PensieveKitTests/SchemaV8Tests.swift` (create)

**Interfaces:**
- Produces: `Node.icon: String`, `Node.colorTag: String` (both default `""`); `Node.init(…, icon: String = "", colorTag: String = "")`; migration `"v8-node-appearance"`.

- [ ] **Step 1: Write the failing test**

Create `Tests/PensieveKitTests/SchemaV8Tests.swift`:

```swift
import Foundation
import Testing
import SQLiteData
@testable import PensieveKit

@Test func v8AddsAppearanceColumnsWithDefaults() throws {
  let db = try openCanonicalDatabase(at: tempURL("v8"))
  let node = Node(name: "Colibri")
  try db.write { db in try Node.insert { node }.execute(db) }

  // New rows default to empty appearance strings ("" == "use the kind default").
  let stored = try db.read { db in try Node.where { $0.id.eq(node.id) }.fetchOne(db) }
  #expect(stored?.icon == "")
  #expect(stored?.colorTag == "")

  // Non-empty values round-trip through the STRICT columns.
  try db.write { db in
    try Node.where { $0.id.eq(node.id) }.update {
      $0.icon = "emoji:🚀"
      $0.colorTag = "teal"
    }.execute(db)
  }
  let updated = try db.read { db in try Node.where { $0.id.eq(node.id) }.fetchOne(db) }
  #expect(updated?.icon == "emoji:🚀")
  #expect(updated?.colorTag == "teal")
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `./scripts/test.sh --filter v8AddsAppearanceColumnsWithDefaults`
Expected: FAIL — `Node` has no `icon`/`colorTag` member (compile error).

- [ ] **Step 3: Add the two properties to `Node`**

In `Sources/PensieveKit/Model/Node.swift`, add two stored properties after `branchKey` and two init params (defaults keep every existing `Node(...)` call site compiling):

```swift
  public var branchKey: String?     // set only on kind == NodeKind.strand
  public var icon: String           // "" = use kind default; else "sf:<symbol>" or "emoji:<grapheme>"
  public var colorTag: String       // "" = use kind default; else a palette color name

  public init(id: UUID = UUID(), name: String, state: String = "active", createdAt: Date = Date(),
              parentID: UUID? = nil, kind: String = NodeKind.project, description: String = "",
              metadataJSON: String = "{}", branchKey: String? = nil,
              icon: String = "", colorTag: String = "") {
    self.id = id; self.name = name; self.state = state; self.createdAt = createdAt
    self.parentID = parentID; self.kind = kind; self.description = description
    self.metadataJSON = metadataJSON; self.branchKey = branchKey
    self.icon = icon; self.colorTag = colorTag
  }
```

- [ ] **Step 4: Add migration v8**

In `Sources/PensieveKit/Store/CanonicalStore.swift`, immediately after the `migrator.registerMigration("v7-incremental-extraction") { … }` block and before `try migrator.migrate(db)`:

```swift
  migrator.registerMigration("v8-node-appearance") { db in
    try #sql(#"ALTER TABLE "nodes" ADD COLUMN "icon" TEXT NOT NULL DEFAULT ''"#).execute(db)
    try #sql(#"ALTER TABLE "nodes" ADD COLUMN "colorTag" TEXT NOT NULL DEFAULT ''"#).execute(db)
  }
```

- [ ] **Step 5: Run test to verify it passes**

Run: `./scripts/test.sh --filter v8AddsAppearanceColumnsWithDefaults`
Expected: PASS.

- [ ] **Step 6: Run the full suite (confirm no regressions from the model change)**

Run: `./scripts/test.sh`
Expected: PASS (all existing tests; new column is additive with defaults).

- [ ] **Step 7: Commit**

```bash
git add Sources/PensieveKit/Model/Node.swift Sources/PensieveKit/Store/CanonicalStore.swift Tests/PensieveKitTests/SchemaV8Tests.swift
git commit -F - <<'EOF'
feat(kit): Node icon/colorTag columns + migration v8

Additive appearance columns (empty = use kind default). Trust gate and
capture path untouched.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01GsAu7rTTdD77k3xZHZrhm4
EOF
```

---

### Task A2: Visual-identity tables + appearance resolver

**Files:**
- Create: `Sources/PensieveKit/Model/VisualIdentity.swift`
- Test: `Tests/PensieveKitTests/VisualIdentityTests.swift` (create)

**Interfaces:**
- Consumes: `NodeKind`, `CaptureKind`, `Node` (Task A1's `icon`/`colorTag`).
- Produces:
  - `enum AppearanceIcon: Equatable, Sendable { case sfSymbol(String); case emoji(String) }` with `static func parse(_:) -> AppearanceIcon?` and `var storedString: String`.
  - `struct KindStyle { let icon: String; let colorTag: String }` + `enum NodeKindStyle { static func style(for kind: String) -> KindStyle }`.
  - `struct SourceStyle { let icon: String; let colorTag: String }` + `enum EventSourceStyle { static func style(for eventKind: String) -> SourceStyle }`.
  - `struct NodeAppearance: Equatable, Sendable { let icon: AppearanceIcon; let colorTag: String }` + `extension Node { var appearance: NodeAppearance }`.

- [ ] **Step 1: Write the failing tests**

Create `Tests/PensieveKitTests/VisualIdentityTests.swift`:

```swift
import Foundation
import Testing
@testable import PensieveKit

@Test func appearanceIconParsesBothSchemes() {
  #expect(AppearanceIcon.parse("sf:flag") == .sfSymbol("flag"))
  #expect(AppearanceIcon.parse("emoji:🚀") == .emoji("🚀"))
  #expect(AppearanceIcon.parse("") == nil)          // empty → caller falls back
  #expect(AppearanceIcon.parse("garbage") == nil)   // malformed → nil
  #expect(AppearanceIcon.parse("sf:") == nil)       // empty payload → nil
  #expect(AppearanceIcon.sfSymbol("flag").storedString == "sf:flag")
  #expect(AppearanceIcon.emoji("🚀").storedString == "emoji:🚀")
}

@Test func everyNodeKindHasADefaultStyle() {
  for kind in NodeKind.all {
    let s = NodeKindStyle.style(for: kind)
    #expect(!s.icon.isEmpty)
    #expect(!s.colorTag.isEmpty)
    #expect(AppearanceIcon.parse(s.icon) != nil)   // the default is a parseable icon string
  }
  // Unknown kind degrades to a valid style, not a crash.
  #expect(!NodeKindStyle.style(for: "nonsense").icon.isEmpty)
}

@Test func everyCaptureKindHasASourceStyle() {
  for kind in [CaptureKind.gitCommit, CaptureKind.gitCheckout, CaptureKind.ccSession, CaptureKind.ccSessionStart] {
    let s = EventSourceStyle.style(for: kind)
    #expect(!s.icon.isEmpty)
    #expect(!s.colorTag.isEmpty)
  }
  #expect(!EventSourceStyle.style(for: "unknown.kind").icon.isEmpty)   // fallback
}

@Test func nodeAppearanceOwnValueWinsElseKindDefault() {
  // Empty appearance → falls back to the kind default.
  let plain = Node(name: "P", kind: NodeKind.strand)
  #expect(plain.appearance.colorTag == NodeKindStyle.style(for: NodeKind.strand).colorTag)
  #expect(plain.appearance.icon == AppearanceIcon.parse(NodeKindStyle.style(for: NodeKind.strand).icon))

  // Own values win.
  let custom = Node(name: "C", kind: NodeKind.strand, icon: "emoji:🎯", colorTag: "pink")
  #expect(custom.appearance.icon == .emoji("🎯"))
  #expect(custom.appearance.colorTag == "pink")

  // Malformed own icon → kind default icon; own color still applies.
  let partial = Node(name: "M", kind: NodeKind.task, icon: "garbage", colorTag: "red")
  #expect(partial.appearance.icon == AppearanceIcon.parse(NodeKindStyle.style(for: NodeKind.task).icon))
  #expect(partial.appearance.colorTag == "red")
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `./scripts/test.sh --filter VisualIdentity`
Expected: FAIL — `AppearanceIcon`/`NodeKindStyle`/`EventSourceStyle`/`appearance` undefined (compile error).

*(If the filter matches nothing because the file doesn't compile, run the four `@Test` names is unnecessary — the whole target fails to build, which is the expected failing state.)*

- [ ] **Step 3: Create the implementation**

Create `Sources/PensieveKit/Model/VisualIdentity.swift`:

```swift
import Foundation

/// A node's or source's icon, stored as a string with a scheme (`"sf:<symbol>"` / `"emoji:<x>"`).
/// Kit stays SwiftUI-free — the app renders `.sfSymbol` as an `Image(systemName:)` and `.emoji`
/// as `Text`.
public enum AppearanceIcon: Equatable, Sendable {
  case sfSymbol(String)
  case emoji(String)

  /// Parse a stored icon string. Returns nil for empty or malformed input (the caller then falls
  /// back to the kind default).
  public static func parse(_ raw: String) -> AppearanceIcon? {
    if raw.hasPrefix("sf:") {
      let s = String(raw.dropFirst(3)); return s.isEmpty ? nil : .sfSymbol(s)
    }
    if raw.hasPrefix("emoji:") {
      let e = String(raw.dropFirst(6)); return e.isEmpty ? nil : .emoji(e)
    }
    return nil
  }

  /// The canonical stored form, for writing back to `Node.icon`.
  public var storedString: String {
    switch self {
    case .sfSymbol(let s): return "sf:\(s)"
    case .emoji(let e): return "emoji:\(e)"
    }
  }
}

/// Default icon + palette color for a node kind. Icon is a stored string; colorTag is a palette
/// name the app maps to a `Color`.
public struct KindStyle: Equatable, Sendable {
  public let icon: String
  public let colorTag: String
  public init(icon: String, colorTag: String) { self.icon = icon; self.colorTag = colorTag }
}

public enum NodeKindStyle {
  public static func style(for kind: String) -> KindStyle {
    switch kind {
    case NodeKind.domain:     return KindStyle(icon: "sf:folder", colorTag: "gray")
    case NodeKind.project:    return KindStyle(icon: "sf:shippingbox", colorTag: "blue")
    case NodeKind.strand:     return KindStyle(icon: "sf:arrow.triangle.branch", colorTag: "teal")
    case NodeKind.concept:    return KindStyle(icon: "sf:lightbulb", colorTag: "yellow")
    case NodeKind.initiative: return KindStyle(icon: "sf:flag", colorTag: "orange")
    case NodeKind.task:       return KindStyle(icon: "sf:checklist", colorTag: "green")
    case NodeKind.topic:      return KindStyle(icon: "sf:tag", colorTag: "purple")
    default:                  return KindStyle(icon: "sf:shippingbox", colorTag: "blue")
    }
  }
}

/// Icon + palette color for an event's source (its `CaptureKind`). The localized *label* lives in
/// the app (localization is an app concern); Kit owns only the visual identity.
public struct SourceStyle: Equatable, Sendable {
  public let icon: String
  public let colorTag: String
  public init(icon: String, colorTag: String) { self.icon = icon; self.colorTag = colorTag }
}

public enum EventSourceStyle {
  public static func style(for eventKind: String) -> SourceStyle {
    switch eventKind {
    case CaptureKind.gitCommit:      return SourceStyle(icon: "sf:arrow.triangle.branch", colorTag: "indigo")
    case CaptureKind.gitCheckout:    return SourceStyle(icon: "sf:arrow.triangle.branch", colorTag: "indigo")
    case CaptureKind.ccSession:      return SourceStyle(icon: "sf:sparkles", colorTag: "orange")
    case CaptureKind.ccSessionStart: return SourceStyle(icon: "sf:sparkles", colorTag: "orange")
    default:                         return SourceStyle(icon: "sf:questionmark.circle", colorTag: "gray")
    }
  }
}

/// A node's *effective* appearance: its own icon/color if set, else the kind default.
public struct NodeAppearance: Equatable, Sendable {
  public let icon: AppearanceIcon
  public let colorTag: String
  public init(icon: AppearanceIcon, colorTag: String) { self.icon = icon; self.colorTag = colorTag }
}

public extension Node {
  var appearance: NodeAppearance {
    let kindStyle = NodeKindStyle.style(for: kind)
    let resolvedIcon = AppearanceIcon.parse(icon)
      ?? AppearanceIcon.parse(kindStyle.icon)
      ?? .sfSymbol("shippingbox")
    let resolvedColor = colorTag.isEmpty ? kindStyle.colorTag : colorTag
    return NodeAppearance(icon: resolvedIcon, colorTag: resolvedColor)
  }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `./scripts/test.sh --filter VisualIdentity`
Expected: PASS (all four tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/PensieveKit/Model/VisualIdentity.swift Tests/PensieveKitTests/VisualIdentityTests.swift
git commit -F - <<'EOF'
feat(kit): visual-identity tables + Node.appearance resolver

AppearanceIcon (sf:/emoji: scheme + parser), NodeKindStyle,
EventSourceStyle, and Node.appearance (own value else kind default).
SwiftUI-free — the app resolves strings to Color/Image.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01GsAu7rTTdD77k3xZHZrhm4
EOF
```

---

### Task A3: `NodeCommands.add` accepts icon + colorTag

**Files:**
- Modify: `Sources/PensieveKit/Query/NodeCommands.swift:16-28` (the `add` function)
- Test: `Tests/PensieveKitTests/NodeCommandsTests.swift` (append a test)

**Interfaces:**
- Consumes: Task A1 (`Node.icon`/`colorTag`).
- Produces: `NodeCommands.add(_ db:, name:, kind:, parent:, description:, icon: String = "", colorTag: String = "") -> Node?` — appearance written in the same insert (no create-then-update).

- [ ] **Step 1: Write the failing test**

Append to `Tests/PensieveKitTests/NodeCommandsTests.swift`:

```swift
@Test func addWritesAppearanceAtomically() throws {
  let db = try openCanonicalDatabase(at: tempURL("add-appearance"))
  let n = try #require(try NodeCommands.add(db, name: "Recipes", kind: "project",
                                            parent: nil, description: "",
                                            icon: "emoji:🍲", colorTag: "orange"))
  let stored = try db.read { db in try Node.where { $0.id.eq(n.id) }.fetchOne(db) }
  #expect(stored?.icon == "emoji:🍲")
  #expect(stored?.colorTag == "orange")

  // Defaults keep the appearance empty (existing call sites unaffected).
  let plain = try #require(try NodeCommands.add(db, name: "Plain", kind: "project",
                                                parent: nil, description: ""))
  #expect(plain.icon == "")
  #expect(plain.colorTag == "")
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `./scripts/test.sh --filter addWritesAppearanceAtomically`
Expected: FAIL — `add` has no `icon:`/`colorTag:` params (compile error).

- [ ] **Step 3: Extend `add`**

Replace `NodeCommands.add` (`Sources/PensieveKit/Query/NodeCommands.swift:15-28`) with:

```swift
  @discardableResult
  public static func add(_ db: any DatabaseWriter, name: String, kind: String,
                         parent: String?, description: String,
                         icon: String = "", colorTag: String = "") throws -> Node? {
    try db.write { db in
      var parentID: UUID? = nil
      if let parent {
        guard let p = try find(db, nameOrID: parent) else { return nil }
        parentID = p.id
      }
      let node = Node(name: name, parentID: parentID, kind: kind, description: description,
                      icon: icon, colorTag: colorTag)
      try Node.insert { node }.execute(db)
      return node
    }
  }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `./scripts/test.sh --filter addWritesAppearanceAtomically`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/PensieveKit/Query/NodeCommands.swift Tests/PensieveKitTests/NodeCommandsTests.swift
git commit -F - <<'EOF'
feat(kit): NodeCommands.add accepts icon/colorTag

New nodes are written fully-formed in one transaction (no create-then-
update flash for the liveness observer). Defaults keep existing callers
unchanged.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01GsAu7rTTdD77k3xZHZrhm4
EOF
```

---

### Task A4: Manual-only cascade delete + `subtreeHasSources`

**Files:**
- Modify: `Sources/PensieveKit/Query/NodeCommands.swift` (add `DeleteResult`, `delete`, `subtreeHasSources`)
- Test: `Tests/PensieveKitTests/NodeCommandsTests.swift` (append tests)

**Interfaces:**
- Consumes: `NodeForest.descendantIDs(of:in:)`; `Node`, `Source`, `Event`, `LooseEnd` tables.
- Produces:
  - `enum DeleteResult: Equatable, Sendable { case deleted(nodes: Int, events: Int, looseEnds: Int); case blocked; case notFound }`
  - `NodeCommands.delete(_ db: any DatabaseWriter, nodeID: UUID) throws -> DeleteResult`
  - `NodeCommands.subtreeHasSources(_ db: any DatabaseReader, nodeID: UUID) throws -> Bool`

**Background (verified against the code):** runtime FKs are ON (GRDB default; `openCanonicalDatabase` sets no override) and `sources`/`events`/`looseEnds`/`checkpoints` carry `ON DELETE CASCADE` on `nodeID` (v2 + v4). Only `nodes.parentID` is `ON DELETE SET NULL`, so we must delete every subtree node explicitly — deleting each node row then cascades its child-table rows automatically. Deleting is refused when any subtree node still has a `Source` (it would be re-created by `ProjectResolver.resolve` on the next drain).

- [ ] **Step 1: Write the failing tests**

Append to `Tests/PensieveKitTests/NodeCommandsTests.swift`:

```swift
@Test func deleteSourceFreeSubtreeCascades() throws {
  let db = try openCanonicalDatabase(at: tempURL("delete-cascade"))
  let root = try #require(try NodeCommands.add(db, name: "Root", kind: "domain", parent: nil, description: ""))
  let child = try #require(try NodeCommands.add(db, name: "Child", kind: "project", parent: "Root", description: ""))
  let sibling = try #require(try NodeCommands.add(db, name: "Sibling", kind: "project", parent: nil, description: ""))

  // A source-free child event + loose end (source-free: no Source row references these nodes).
  let ev = Event(nodeID: child.id, sourceID: UUID(), occurredAt: Date(),
                 kind: CaptureKind.ccSession, summary: "s", detailJSON: "{}")
  let le = LooseEnd(nodeID: child.id, sourceEventID: ev.id, text: "todo", quote: "q")
  try db.write { db in
    try Event.insert { ev }.execute(db)
    try LooseEnd.insert { le }.execute(db)
  }

  let result = try NodeCommands.delete(db, nodeID: root.id)
  #expect(result == .deleted(nodes: 2, events: 1, looseEnds: 1))   // root + child

  // Root + child gone; their event + loose end gone; sibling untouched.
  #expect(try db.read { db in try Node.where { $0.id.eq(root.id) }.fetchOne(db) } == nil)
  #expect(try db.read { db in try Node.where { $0.id.eq(child.id) }.fetchOne(db) } == nil)
  #expect(try db.read { db in try Node.where { $0.id.eq(sibling.id) }.fetchOne(db) } != nil)
  #expect(try db.read { db in try Event.fetchCount(db) } == 0)
  #expect(try db.read { db in try LooseEnd.fetchCount(db) } == 0)
}

@Test func deleteBlockedWhenSubtreeHasSource() throws {
  let db = try openCanonicalDatabase(at: tempURL("delete-blocked"))
  let root = try #require(try NodeCommands.add(db, name: "Root", kind: "domain", parent: nil, description: ""))
  let child = try #require(try NodeCommands.add(db, name: "Child", kind: "project", parent: "Root", description: ""))
  // A live source on the *descendant* must block deleting the ancestor.
  try db.write { db in
    try Source.insert { Source(nodeID: child.id, kind: SourceKind.gitRepo, key: "/p/child") }.execute(db)
  }

  #expect(try NodeCommands.subtreeHasSources(db, nodeID: root.id) == true)
  #expect(try NodeCommands.delete(db, nodeID: root.id) == .blocked)
  // Nothing was deleted.
  #expect(try db.read { db in try Node.where { $0.id.eq(root.id) }.fetchOne(db) } != nil)
  #expect(try db.read { db in try Node.where { $0.id.eq(child.id) }.fetchOne(db) } != nil)
}

@Test func deleteLeafAndUnknown() throws {
  let db = try openCanonicalDatabase(at: tempURL("delete-leaf"))
  let leaf = try #require(try NodeCommands.add(db, name: "Leaf", kind: "project", parent: nil, description: ""))
  #expect(try NodeCommands.subtreeHasSources(db, nodeID: leaf.id) == false)
  #expect(try NodeCommands.delete(db, nodeID: leaf.id) == .deleted(nodes: 1, events: 0, looseEnds: 0))
  #expect(try NodeCommands.delete(db, nodeID: UUID()) == .notFound)
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `./scripts/test.sh --filter delete`
Expected: FAIL — `DeleteResult`/`delete`/`subtreeHasSources` undefined (compile error).

- [ ] **Step 3: Implement delete + guard**

In `Sources/PensieveKit/Query/NodeCommands.swift`, add inside `public enum NodeCommands` (after `retype`):

```swift
  /// The outcome of a delete attempt. `.blocked` = the subtree still has a live source, which
  /// `ProjectResolver` would re-create on the next drain — so delete is refused.
  public enum DeleteResult: Equatable, Sendable {
    case deleted(nodes: Int, events: Int, looseEnds: Int)
    case blocked
    case notFound
  }

  /// Delete `nodeID` and all its descendants (manual-only). Refused (`.blocked`, nothing written)
  /// if any node in the subtree has a `Source`. Child rows cascade via FK on node-row delete;
  /// `nodes.parentID` is SET NULL, so the subtree is deleted explicitly.
  @discardableResult
  public static func delete(_ db: any DatabaseWriter, nodeID: UUID) throws -> DeleteResult {
    try db.write { db in
      guard try Node.where({ $0.id.eq(nodeID) }).fetchOne(db) != nil else { return .notFound }
      let all = try Node.all.fetchAll(db)
      let ids = NodeForest.descendantIDs(of: nodeID, in: all).union([nodeID])

      // Manual-only guard: any source in the subtree → refuse (would resurrect on next drain).
      for id in ids where try Source.where({ $0.nodeID.eq(id) }).fetchCount(db) > 0 {
        return .blocked
      }

      var events = 0, looseEnds = 0
      for id in ids {
        events += try Event.where { $0.nodeID.eq(id) }.fetchCount(db)
        looseEnds += try LooseEnd.where { $0.nodeID.eq(id) }.fetchCount(db)
      }
      for id in ids {
        try Node.where { $0.id.eq(id) }.delete().execute(db)   // cascades its child-table rows
      }
      return .deleted(nodes: ids.count, events: events, looseEnds: looseEnds)
    }
  }

  /// True if `nodeID` or any descendant has a `Source` — the app gates the Delete menu item on this.
  public static func subtreeHasSources(_ db: any DatabaseReader, nodeID: UUID) throws -> Bool {
    try db.read { db in
      let all = try Node.all.fetchAll(db)
      let ids = NodeForest.descendantIDs(of: nodeID, in: all).union([nodeID])
      for id in ids where try Source.where({ $0.nodeID.eq(id) }).fetchCount(db) > 0 { return true }
      return false
    }
  }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `./scripts/test.sh --filter delete`
Expected: PASS (all three tests).

- [ ] **Step 5: Run the full suite**

Run: `./scripts/test.sh`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Sources/PensieveKit/Query/NodeCommands.swift Tests/PensieveKitTests/NodeCommandsTests.swift
git commit -F - <<'EOF'
feat(kit): manual-only cascade delete + subtreeHasSources

delete() removes a node + descendants (child tables cascade via FK) but
refuses when the subtree has a live source (ProjectResolver would re-create
it on the next drain). subtreeHasSources gates the app's Delete affordance.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01GsAu7rTTdD77k3xZHZrhm4
EOF
```

---

### Task A5: `NodeCommands.update` (atomic edit of name/kind/icon/colorTag)

**Files:**
- Modify: `Sources/PensieveKit/Query/NodeCommands.swift` (add `update`)
- Test: `Tests/PensieveKitTests/NodeCommandsTests.swift` (append a test)

**Interfaces:**
- Consumes: Task A1 (`Node.icon`/`colorTag`).
- Produces: `NodeCommands.update(_ db: any DatabaseWriter, nodeID: UUID, name: String, kind: String, icon: String, colorTag: String) throws -> Bool` — the app's Edit-modal commit (one transaction, so no per-field flash).

- [ ] **Step 1: Write the failing test**

Append to `Tests/PensieveKitTests/NodeCommandsTests.swift`:

```swift
@Test func updateEditsAllFieldsAtomically() throws {
  let db = try openCanonicalDatabase(at: tempURL("node-update"))
  let n = try #require(try NodeCommands.add(db, name: "Old", kind: "project", parent: nil, description: "keep"))
  #expect(try NodeCommands.update(db, nodeID: n.id, name: "New", kind: "strand",
                                  icon: "sf:flag", colorTag: "pink"))
  let stored = try db.read { db in try Node.where { $0.id.eq(n.id) }.fetchOne(db) }
  #expect(stored?.name == "New")
  #expect(stored?.kind == "strand")
  #expect(stored?.icon == "sf:flag")
  #expect(stored?.colorTag == "pink")
  #expect(stored?.description == "keep")   // untouched fields preserved
  // Unknown id → false, nothing written.
  #expect(try NodeCommands.update(db, nodeID: UUID(), name: "x", kind: "task", icon: "", colorTag: "") == false)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `./scripts/test.sh --filter updateEditsAllFieldsAtomically`
Expected: FAIL — `NodeCommands.update` undefined (compile error).

- [ ] **Step 3: Implement `update`**

In `Sources/PensieveKit/Query/NodeCommands.swift`, add inside `public enum NodeCommands` (after `retype`):

```swift
  /// Atomic edit of a node's user-facing fields (the app's Edit modal). Leaves description,
  /// parentID, state, branchKey untouched. Returns false — writing nothing — for an unknown id.
  @discardableResult
  public static func update(_ db: any DatabaseWriter, nodeID: UUID,
                            name: String, kind: String, icon: String, colorTag: String) throws -> Bool {
    try db.write { db in
      guard try Node.where({ $0.id.eq(nodeID) }).fetchOne(db) != nil else { return false }
      try Node.where { $0.id.eq(nodeID) }.update {
        $0.name = name; $0.kind = kind; $0.icon = icon; $0.colorTag = colorTag
      }.execute(db)
      return true
    }
  }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `./scripts/test.sh --filter updateEditsAllFieldsAtomically`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/PensieveKit/Query/NodeCommands.swift Tests/PensieveKitTests/NodeCommandsTests.swift
git commit -F - <<'EOF'
feat(kit): NodeCommands.update — atomic edit of name/kind/icon/colorTag

Backs the app's Edit modal in one transaction. Description/parent/state
untouched.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01GsAu7rTTdD77k3xZHZrhm4
EOF
```

---

## Self-review (Plan A)

- **Spec coverage:** migration v8 + columns (A1); `NodeKindStyle`/`EventSourceStyle`/`AppearanceIcon`/`NodeAppearance` (A2); `add` icon/colorTag (A3); `delete` manual-only guard + `subtreeHasSources` (A4); `update` for the Edit modal (A5). All Kit items from the spec's "Plan A" bullet are covered.
- **Types consistent:** `AppearanceIcon`, `KindStyle`/`SourceStyle`, `NodeAppearance`, `DeleteResult` names match between definitions and tests. `add`'s new params match A3's test call; `update`'s signature matches A5's test and Plan B's `AppModel.updateNode`. `delete` return shape matches A4's `#expect`.
- **No placeholders:** every step has real code + exact commands.
- **Deviation from spec (noted):** `SourceStyle` carries `icon`+`colorTag` only; the localized source *label* lives in the app (Plan B), not a Kit `labelKey` — keeps localization an app concern and avoids an unused Kit key.
