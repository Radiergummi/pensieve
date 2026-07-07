# Pensieve.app slice 4 — in-app organizing writes — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let me create, rename, change-type, move, and merge nodes from inside Pensieve.app via native context menus + in-place rename, over the existing PensieveKit organizing ops — with a real cycle guard so no UI action can corrupt the tree.

**Architecture:** Three tested PensieveKit changes (a unified guarded `reparent` that fixes the missing cycle guard on `nest`; a fix for the latent `ProjectResolver.group` self-cycle; a pure `descendantIDs` helper for the picker guard), then thin app wiring: `AppModel` write methods (each calls the op then `refresh()` explicitly), context menus + an in-place-rename `TextField`, Move/Merge pickers with a destructive-merge confirmation, and a toolbar "+" / File ▸ New Node. Writes are metadata-only and don't touch the single-writer event-ingestion path.

**Tech Stack:** Swift 6, SQLiteData (GRDB-backed), Swift Testing, SwiftUI (macOS 15+), XcodeGen + Xcode 26.6 for the app bundle.

## Global Constraints

- **Predicates use `.eq(x)`, never `== x`** (e.g. `.where { $0.id.eq(uuid) }`). `==` is `unavailable`.
- **All writes go through PensieveKit ops, never raw SQL.** Organizing edits are a legitimate app write path; the single-writer principle governs *event ingestion* only.
- **No cycle may ever be created.** The write-side guard in `reparent`/`group` is authoritative; the UI picker filter is defense-in-depth.
- **Deletion only via Merge.** No standalone delete, no archive/mute, no Undo this slice. `Node.state` stays CLI-only.
- **Localize chrome only.** New UI strings use `String(localized:)` / `LocalizedStringKey` and are added to `Sources/PensieveApp/Localizable.xcstrings` (en base + `de`). **Never** localize node names, descriptions, kinds/roles, quotes, or event text. **`xcodebuild build` does NOT auto-populate the `.xcstrings`** — keys are reconciled by hand.
- **The app target has no unit tests.** App tasks are verified by `xcodebuild` build + a non-blocking smoke-launch of the inner binary with throwaway `PENSIEVE_DB`/`PENSIEVE_CAPTURE_DB` (NEVER the live store).
- **Kinds offered in the UI (all seven):** `domain`, `project`, `strand`, `concept`, `initiative`, `task`, `topic`.
- Tests run with `./scripts/test.sh` (thin `swift test` passthrough). App builds with `xcodegen generate` → `xcodebuild -project Pensieve.xcodeproj -scheme Pensieve -configuration Debug -derivedDataPath ./.build-xcode build`.

## File Structure

- `Sources/PensieveKit/Query/NodeCommands.swift` — add `reparent` (public wrapper + in-transaction core); rewrite `nest` as a wrapper over the core. **[Task 1]**
- `Sources/PensieveKit/Ingest/ProjectResolver.swift` — fix `group` self-cycle. **[Task 2]**
- `Sources/PensieveKit/Query/NodeForest.swift` — add `descendantIDs(of:in:)`. **[Task 3]**
- `Tests/PensieveKitTests/NodeCommandsTests.swift` — reparent/nest guard tests. **[Task 1]**
- `Tests/PensieveKitTests/ProjectResolverTests.swift` — merge-parent-into-child tests. **[Task 2]**
- `Tests/PensieveKitTests/NodeForestTests.swift` — descendantIDs tests. **[Task 3]**
- `Sources/PensieveApp/AppModel.swift` — write methods, `renamingNodeID`, `defaultKind`, `moveTargets`, `NodeKindOption`. **[Task 4]**
- `Sources/PensieveApp/NodeOrganizing.swift` (**new**) — `NodeNameField` (in-place rename) + `NodeContextMenu`. **[Task 5]**, extended **[Task 6]**
- `Sources/PensieveApp/SidebarView.swift` — inline-rename swap + context menu on tree rows; extend `symbol(for:)` to 7 kinds. **[Task 5]**
- `Sources/PensieveApp/ContentListView.swift` — inline-rename swap + context menu on list rows. **[Task 5]**
- `Sources/PensieveApp/NodeOrganizing.swift` — `MovePicker` + `MergePicker`. **[Task 6]**
- `Sources/PensieveApp/RootView.swift` — mount picker sheets + toolbar "+". **[Task 6]**
- `Sources/PensieveApp/PensieveApp.swift` — File ▸ New Node (⌘N) command. **[Task 6]**
- `Sources/PensieveApp/Localizable.xcstrings` — new chrome keys (en + de). **[Task 7]**

---

### Task 1: Guarded `reparent` in `NodeCommands` + `nest` becomes a wrapper

**Files:**
- Modify: `Sources/PensieveKit/Query/NodeCommands.swift:28-34` (the current `nest`)
- Test: `Tests/PensieveKitTests/NodeCommandsTests.swift`

**Interfaces:**
- Produces:
  - `NodeCommands.reparent(_ db: any DatabaseWriter, nodeID: UUID, newParentID: UUID?) throws -> Bool` (public, `@discardableResult`) — reparents `nodeID` under `newParentID` (nil = root). Returns `false`, writing nothing, if either id is unknown or the move would form a cycle.
  - `NodeCommands.reparent(_ db: Database, nodeID: UUID, newParentID: UUID?) throws -> Bool` (internal, in-transaction core).
  - `NodeCommands.nest(_ db: any DatabaseWriter, child: String, under parent: String) throws -> Bool` — unchanged signature; now cycle-guarded.

- [ ] **Step 1: Write the failing tests**

Append to `Tests/PensieveKitTests/NodeCommandsTests.swift`:

```swift
@Test func reparentRejectsCycle() throws {
  let db = try openCanonicalDatabase(at: tempURL("reparent-cycle"))
  let a = try #require(try NodeCommands.add(db, name: "A", kind: "domain", parent: nil, description: ""))
  let b = try #require(try NodeCommands.add(db, name: "B", kind: "project", parent: "A", description: ""))
  let c = try #require(try NodeCommands.add(db, name: "C", kind: "strand", parent: "B", description: ""))

  // Move A under its own grandchild C → cycle → refused.
  #expect(try NodeCommands.reparent(db, nodeID: a.id, newParentID: c.id) == false)
  // Move B under itself → refused.
  #expect(try NodeCommands.reparent(db, nodeID: b.id, newParentID: b.id) == false)

  let reloadedA = try db.read { db in try Node.where { $0.id.eq(a.id) }.fetchOne(db) }
  #expect(reloadedA?.parentID == nil)   // A still a root; nothing was written
}

@Test func reparentLegalAndToRoot() throws {
  let db = try openCanonicalDatabase(at: tempURL("reparent-legal"))
  let a = try #require(try NodeCommands.add(db, name: "A", kind: "domain", parent: nil, description: ""))
  let b = try #require(try NodeCommands.add(db, name: "B", kind: "project", parent: nil, description: ""))

  #expect(try NodeCommands.reparent(db, nodeID: b.id, newParentID: a.id))
  #expect(try db.read { db in try Node.where { $0.id.eq(b.id) }.fetchOne(db) }?.parentID == a.id)

  #expect(try NodeCommands.reparent(db, nodeID: b.id, newParentID: nil))   // move back to root
  #expect(try db.read { db in try Node.where { $0.id.eq(b.id) }.fetchOne(db) }?.parentID == nil)
}

@Test func reparentUnknownIDReturnsFalse() throws {
  let db = try openCanonicalDatabase(at: tempURL("reparent-unknown"))
  #expect(try NodeCommands.reparent(db, nodeID: UUID(), newParentID: nil) == false)
}

@Test func nestRejectsCycleViaWrapper() throws {
  let db = try openCanonicalDatabase(at: tempURL("nest-cycle"))
  _ = try NodeCommands.add(db, name: "A", kind: "domain", parent: nil, description: "")
  _ = try NodeCommands.add(db, name: "B", kind: "project", parent: "A", description: "")
  // Nest A under its own child B → refused, tree unchanged.
  #expect(try NodeCommands.nest(db, child: "A", under: "B") == false)
  let a = try db.read { db in try Node.where { $0.name.eq("A") }.fetchOne(db) }
  #expect(a?.parentID == nil)
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `./scripts/test.sh --filter reparent`
Expected: FAIL — `reparent` does not exist (compile error / unresolved identifier).

- [ ] **Step 3: Add `reparent` and rewrite `nest`**

In `Sources/PensieveKit/Query/NodeCommands.swift`, replace the current `nest` (lines 28-34) with:

```swift
  /// Reparent `nodeID` under `newParentID` (nil = move to root). Returns false — writing nothing — if
  /// either id is unknown or the move would create a cycle (`newParentID == nodeID`, or `nodeID` is an
  /// ancestor of `newParentID`). The read side (`NodeForest.build`) guards display; this guards data.
  @discardableResult
  public static func reparent(_ db: any DatabaseWriter, nodeID: UUID, newParentID: UUID?) throws -> Bool {
    try db.write { db in try reparent(db, nodeID: nodeID, newParentID: newParentID) }
  }

  /// In-transaction core, so `nest` can reuse the guard inside its own `db.write`.
  static func reparent(_ db: Database, nodeID: UUID, newParentID: UUID?) throws -> Bool {
    guard try Node.where({ $0.id.eq(nodeID) }).fetchOne(db) != nil else { return false }
    if let newParentID {
      guard try Node.where({ $0.id.eq(newParentID) }).fetchOne(db) != nil else { return false }
      // Walk up from the intended parent; hitting nodeID means this move would form a cycle.
      var cursor: UUID? = newParentID
      while let current = cursor {
        if current == nodeID { return false }
        cursor = try Node.where { $0.id.eq(current) }.fetchOne(db)?.parentID
      }
    }
    try Node.where { $0.id.eq(nodeID) }.update { $0.parentID = #bind(newParentID) }.execute(db)
    return true
  }

  public static func nest(_ db: any DatabaseWriter, child: String, under parent: String) throws -> Bool {
    try db.write { db in
      guard let c = try find(db, nameOrID: child), let p = try find(db, nameOrID: parent) else { return false }
      return try reparent(db, nodeID: c.id, newParentID: p.id)
    }
  }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `./scripts/test.sh --filter reparent && ./scripts/test.sh --filter nest`
Expected: PASS (all `reparent*` and `nest*` tests).

- [ ] **Step 5: Run the full suite to confirm no regressions**

Run: `./scripts/test.sh`
Expected: PASS (existing 173 + the 4 new tests). The existing `addNestRenameRetype` test still passes (legal `nest` unchanged).

- [ ] **Step 6: Commit**

```bash
git add Sources/PensieveKit/Query/NodeCommands.swift Tests/PensieveKitTests/NodeCommandsTests.swift
git commit -F - <<'EOF'
feat(kit): guarded NodeCommands.reparent; nest routes through it

Adds a walk-to-root cycle guard so no reparent (nest under a descendant,
or under self) can corrupt the tree. nest becomes a thin wrapper over the
in-transaction core; CLI behavior unchanged except a cyclic nest now
returns false instead of corrupting data. nil parent = move to root.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01GsAu7rTTdD77k3xZHZrhm4
EOF
```

---

### Task 2: Fix `ProjectResolver.group` self-cycle (merge parent into own child)

**Files:**
- Modify: `Sources/PensieveKit/Ingest/ProjectResolver.swift:52-68` (the current `group`)
- Test: `Tests/PensieveKitTests/ProjectResolverTests.swift`

**Interfaces:**
- Consumes: `NodeCommands.add` (Task 1 file, pre-existing).
- Produces: `ProjectResolver.group(_ primaryID: UUID, into merged: [UUID]) throws` — unchanged signature; now safe when a merged node is the primary's parent.

- [ ] **Step 1: Write the failing tests**

Append to `Tests/PensieveKitTests/ProjectResolverTests.swift`:

```swift
@Test func groupMergingParentIntoChildRerootsAtGrandparent() throws {
  let db = try openCanonicalDatabase(at: tempURL("group-selfcycle"))
  let grand = try #require(try NodeCommands.add(db, name: "Grand", kind: "domain", parent: nil, description: ""))
  let parent = try #require(try NodeCommands.add(db, name: "Parent", kind: "project", parent: "Grand", description: ""))
  let child = try #require(try NodeCommands.add(db, name: "Child", kind: "strand", parent: "Parent", description: ""))

  try ProjectResolver(db: db).group(child.id, into: [parent.id])   // merge parent INTO its own child

  let reloaded = try db.read { db in try Node.where { $0.id.eq(child.id) }.fetchOne(db) }
  #expect(reloaded != nil)
  #expect(reloaded?.parentID == grand.id)     // promoted to grandparent…
  #expect(reloaded?.parentID != child.id)     // …never itself
  #expect(try db.read { db in try Node.where { $0.id.eq(parent.id) }.fetchOne(db) } == nil)  // parent gone
}

@Test func groupMergingRootParentIntoChildMakesChildRoot() throws {
  let db = try openCanonicalDatabase(at: tempURL("group-selfcycle-root"))
  let parent = try #require(try NodeCommands.add(db, name: "Parent", kind: "project", parent: nil, description: ""))
  let child = try #require(try NodeCommands.add(db, name: "Child", kind: "strand", parent: "Parent", description: ""))

  try ProjectResolver(db: db).group(child.id, into: [parent.id])

  let reloaded = try db.read { db in try Node.where { $0.id.eq(child.id) }.fetchOne(db) }
  #expect(reloaded?.parentID == nil)   // parent was a root → child becomes a root
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `./scripts/test.sh --filter groupMerging`
Expected: FAIL — the child's `parentID` comes back equal to `child.id` (self-cycle), not the grandparent/nil.

- [ ] **Step 3: Fix `group`**

In `Sources/PensieveKit/Ingest/ProjectResolver.swift`, replace the `group` body (lines 52-68) with:

```swift
  public func group(_ primaryID: UUID, into merged: [UUID]) throws {
    try db.write { db in
      for other in merged where other != primaryID {
        // If the primary is itself a child of the node being absorbed, promote it to `other`'s parent
        // first — otherwise the "reparent other's children → primary" step below would set the primary's
        // own parent to itself (a self-cycle).
        if let primary = try Node.where({ $0.id.eq(primaryID) }).fetchOne(db), primary.parentID == other {
          let grandparentID = try Node.where { $0.id.eq(other) }.fetchOne(db)?.parentID
          try Node.where { $0.id.eq(primaryID) }
            .update { $0.parentID = #bind(grandparentID) }.execute(db)
        }
        try Source.where { $0.nodeID.eq(other) }
          .update { $0.nodeID = primaryID }.execute(db)
        try Event.where { $0.nodeID.eq(other) }
          .update { $0.nodeID = primaryID }.execute(db)
        try LooseEnd.where { $0.nodeID.eq(other) }
          .update { $0.nodeID = primaryID }.execute(db)
        try Checkpoint.where { $0.nodeID.eq(other) }
          .update { $0.nodeID = primaryID }.execute(db)
        try Node.where { $0.parentID.eq(other) }
          .update { $0.parentID = #bind(primaryID) }.execute(db)
        try Node.where { $0.id.eq(other) }.delete().execute(db)
      }
    }
  }
```

Note: because the primary is promoted off `other` *before* the children-reparent step, it is no longer matched by `$0.parentID.eq(other)`, so it is never repointed to itself. All other merged children still move to the primary correctly.

- [ ] **Step 4: Run tests to verify they pass**

Run: `./scripts/test.sh --filter groupMerging`
Expected: PASS.

- [ ] **Step 5: Run the full suite (existing group tests must still pass)**

Run: `./scripts/test.sh`
Expected: PASS. `groupMergesProjects`, `groupPreservesLooseEndsAndCheckpoints`, and any other existing `group*` tests are unaffected (they merge unrelated roots, where `primary.parentID != other`).

- [ ] **Step 6: Commit**

```bash
git add Sources/PensieveKit/Ingest/ProjectResolver.swift Tests/PensieveKitTests/ProjectResolverTests.swift
git commit -F - <<'EOF'
fix(kit): ProjectResolver.group self-cycle when merging a parent into its child

Merging a node into its own descendant left the survivor pointing at
itself. Promote the primary to the absorbed node's parent (grandparent,
or root) before reparenting the absorbed node's children, so the primary
is never repointed to itself.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01GsAu7rTTdD77k3xZHZrhm4
EOF
```

---

### Task 3: `NodeForest.descendantIDs(of:in:)` helper

**Files:**
- Modify: `Sources/PensieveKit/Query/NodeForest.swift` (add to the `NodeForest` enum)
- Test: `Tests/PensieveKitTests/NodeForestTests.swift`

**Interfaces:**
- Produces: `NodeForest.descendantIDs(of id: UUID, in nodes: [Node]) -> Set<UUID>` — all transitive descendants of `id` (excludes `id`); empty for a leaf or an unknown id. Cycle-safe.

- [ ] **Step 1: Write the failing test**

Append to `Tests/PensieveKitTests/NodeForestTests.swift`:

```swift
@Test func descendantIDsTransitiveExcludesSelf() {
  let a = Node(name: "A", kind: "domain")
  let b = Node(name: "B", parentID: a.id, kind: "project")
  let c = Node(name: "C", parentID: b.id, kind: "strand")
  let d = Node(name: "D", kind: "project")   // unrelated root
  let nodes = [a, b, c, d]

  #expect(NodeForest.descendantIDs(of: a.id, in: nodes) == [b.id, c.id])
  #expect(!NodeForest.descendantIDs(of: a.id, in: nodes).contains(a.id))
  #expect(NodeForest.descendantIDs(of: c.id, in: nodes).isEmpty)   // leaf
  #expect(NodeForest.descendantIDs(of: d.id, in: nodes).isEmpty)   // childless root
  #expect(NodeForest.descendantIDs(of: UUID(), in: nodes).isEmpty) // unknown id
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `./scripts/test.sh --filter descendantIDs`
Expected: FAIL — `descendantIDs` does not exist.

- [ ] **Step 3: Implement `descendantIDs`**

In `Sources/PensieveKit/Query/NodeForest.swift`, add inside the `public enum NodeForest { … }` (after `build`):

```swift
  /// All transitive descendants of `id` within `nodes` (excludes `id` itself). Read-only,
  /// deterministic, and cycle-safe (a visited set guards against any pre-existing bad edge).
  public static func descendantIDs(of id: UUID, in nodes: [Node]) -> Set<UUID> {
    var childrenByParent: [UUID: [UUID]] = [:]
    for n in nodes { if let p = n.parentID { childrenByParent[p, default: []].append(n.id) } }
    var result: Set<UUID> = []
    var stack = childrenByParent[id] ?? []
    while let next = stack.popLast() {
      guard result.insert(next).inserted else { continue }
      stack.append(contentsOf: childrenByParent[next] ?? [])
    }
    return result
  }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `./scripts/test.sh --filter descendantIDs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/PensieveKit/Query/NodeForest.swift Tests/PensieveKitTests/NodeForestTests.swift
git commit -F - <<'EOF'
feat(kit): NodeForest.descendantIDs for the move/merge picker guard

Pure transitive-descendant set (excludes self), cycle-safe. Lets the app
filter self + descendants out of Move/Merge target lists.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01GsAu7rTTdD77k3xZHZrhm4
EOF
```

---

### Task 4: `AppModel` write methods + rename/kind state

**Files:**
- Modify: `Sources/PensieveApp/AppModel.swift`

**Interfaces:**
- Consumes: `NodeCommands.add/rename/retype/reparent` (Tasks 1), `ProjectResolver.group` (Task 2), `NodeForest.descendantIDs` (Task 3). Existing `AppModel.refresh()`, `node(_:)`, private `db`, private `allNodes`.
- Produces (on `AppModel`):
  - `@Published var renamingNodeID: UUID?`
  - `enum NodeKindOption { static let all: [String] }` (top-level in the file)
  - `func createNode(under parentID: UUID?)`
  - `func rename(_ nodeID: UUID, to newName: String)`
  - `func retype(_ nodeID: UUID, to kind: String)`
  - `func move(_ nodeID: UUID, under newParentID: UUID?)`
  - `func merge(_ sourceID: UUID, into targetID: UUID)`
  - `func moveTargets(for nodeID: UUID) -> [Node]`

- [ ] **Step 1: Add the kind-options enum**

At the top of `Sources/PensieveApp/AppModel.swift` (after the imports, near `SmartListKind`), add:

```swift
/// The node kinds the app surfaces in Change Type / new-node creation (all seven declared kinds).
enum NodeKindOption {
  static let all = ["domain", "project", "strand", "concept", "initiative", "task", "topic"]
}
```

- [ ] **Step 2: Add the rename-state property**

In `AppModel`, next to the other `@Published` properties (e.g. after `selectedNodeID`), add:

```swift
  /// The node currently being renamed in place (drives the row's TextField). nil = not renaming.
  @Published var renamingNodeID: UUID?
```

- [ ] **Step 3: Add the write methods**

In `AppModel`, add (e.g. after `detail(for:)`):

```swift
  // MARK: - Organizing writes (metadata only; each calls the op then refreshes explicitly, because
  // Node-only writes don't change the Event count the liveness ValueObservation tracks).

  /// Default kind for a new node: a child of a project/domain is a strand; everything else a project.
  private func defaultKind(under parentID: UUID?) -> String {
    guard let parentID, let parent = node(parentID) else { return "project" }
    return (parent.kind == "project" || parent.kind == "domain") ? "strand" : "project"
  }

  /// Create a node (nil parent = top level), select it into the middle list, and enter inline rename.
  /// Renaming happens in the flat content list (OutlineGroup can't be force-expanded), so for a child
  /// we select the *parent* — the list shows parent + children, including the new one.
  func createNode(under parentID: UUID?) {
    guard let db else { return }
    guard let new = try? NodeCommands.add(db, name: String(localized: "New Node"),
                                          kind: defaultKind(under: parentID),
                                          parent: parentID?.uuidString, description: "") else { return }
    refresh()
    if let parentID {
      sidebarSelection = .node(parentID); selectedNodeID = parentID
    } else {
      sidebarSelection = .node(new.id); selectedNodeID = new.id
    }
    renamingNodeID = new.id
  }

  func rename(_ nodeID: UUID, to newName: String) {
    renamingNodeID = nil
    let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let db, !trimmed.isEmpty else { return }
    _ = try? NodeCommands.rename(db, node: nodeID.uuidString, to: trimmed)
    refresh()
  }

  func retype(_ nodeID: UUID, to kind: String) {
    guard let db else { return }
    _ = try? NodeCommands.retype(db, node: nodeID.uuidString, to: kind)
    refresh()
  }

  func move(_ nodeID: UUID, under newParentID: UUID?) {
    guard let db else { return }
    _ = try? NodeCommands.reparent(db, nodeID: nodeID, newParentID: newParentID)
    refresh()
  }

  func merge(_ sourceID: UUID, into targetID: UUID) {
    guard let db, sourceID != targetID else { return }
    try? ProjectResolver(db: db).group(targetID, into: [sourceID])
    if selectedNodeID == sourceID { selectedNodeID = targetID; sidebarSelection = .node(targetID) }
    refresh()
  }

  /// Legal Move/Merge targets for `nodeID`: every node except itself and its descendants.
  func moveTargets(for nodeID: UUID) -> [Node] {
    let banned = NodeForest.descendantIDs(of: nodeID, in: allNodes).union([nodeID])
    return allNodes.filter { !banned.contains($0.id) }.sorted { $0.name < $1.name }
  }
```

- [ ] **Step 4: Build**

Run: `xcodegen generate && xcodebuild -project Pensieve.xcodeproj -scheme Pensieve -configuration Debug -derivedDataPath ./.build-xcode build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`. (The new methods aren't called yet — this task just adds them; wiring is Tasks 5–6.)

- [ ] **Step 5: Non-blocking smoke-launch (still boots)**

Run:
```bash
PENSIEVE_DB=/tmp/s4-t4.sqlite PENSIEVE_CAPTURE_DB=/tmp/s4-t4-cap.sqlite \
  ./.build-xcode/Build/Products/Debug/Pensieve.app/Contents/MacOS/Pensieve &
PID=$!; sleep 3; kill $PID 2>/dev/null; echo "launched pid $PID"
```
Expected: launches without crashing; `kill` succeeds.

- [ ] **Step 6: Commit**

```bash
git add Sources/PensieveApp/AppModel.swift
git commit -F - <<'EOF'
feat(app): AppModel organizing write methods + rename state

createNode/rename/retype/move/merge over the PensieveKit ops, each
refreshing explicitly (Node-only writes don't trip the Event-count
observation). renamingNodeID drives in-place rename; moveTargets filters
self + descendants via NodeForest.descendantIDs. Not wired to UI yet.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01GsAu7rTTdD77k3xZHZrhm4
EOF
```

---

### Task 5: In-place rename + New Child / Rename / Change Type context menu

**Files:**
- Create: `Sources/PensieveApp/NodeOrganizing.swift`
- Modify: `Sources/PensieveApp/SidebarView.swift:26-30` (OutlineGroup row) and `:50-56` (`symbol(for:)`)
- Modify: `Sources/PensieveApp/ContentListView.swift:10-16` (list row)

**Interfaces:**
- Consumes: `AppModel.renamingNodeID`, `createNode`, `rename`, `retype`, `NodeKindOption.all` (Task 4).
- Produces: `NodeNameField` (in-place TextField), `NodeContextMenu` (3 items this task; extended in Task 6).

- [ ] **Step 1: Create `NodeOrganizing.swift` with the rename field + context menu**

```swift
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
```

- [ ] **Step 2: Wire the sidebar tree row (rename swap + context menu, extended `symbol`)**

In `Sources/PensieveApp/SidebarView.swift`, replace the `OutlineGroup` closure (lines 26-30) with:

```swift
        OutlineGroup(model.forest, children: \.childrenIfAny) { item in
          Group {
            if model.renamingNodeID == item.node.id {
              NodeNameField(model: model, node: item.node)
            } else {
              Label(item.node.name, systemImage: symbol(for: item.node.kind))
            }
          }
          .tag(SidebarSelection.node(item.node.id))
          .contextMenu { NodeContextMenu(model: model, node: item.node) }
        }
```

And replace `symbol(for:)` (lines 50-56) with a 7-kind mapping:

```swift
  private func symbol(for kind: String) -> String {
    switch kind {
    case "domain": return "folder"
    case "strand": return "arrow.triangle.branch"
    case "concept": return "lightbulb"
    case "initiative": return "flag"
    case "task": return "checklist"
    case "topic": return "tag"
    default: return "shippingbox"   // project + any unknown kind
    }
  }
```

- [ ] **Step 3: Wire the content-list row (rename swap + context menu)**

In `Sources/PensieveApp/ContentListView.swift`, replace the row closure (lines 10-16) with:

```swift
    List(items, selection: $model.selectedNodeID) { node in
      VStack(alignment: .leading, spacing: 2) {
        if model.renamingNodeID == node.id {
          NodeNameField(model: model, node: node)
        } else {
          Text(node.name)
        }
        Text(node.kind).font(.caption).foregroundStyle(.secondary)
      }
      .tag(node.id)
      .contextMenu { NodeContextMenu(model: model, node: node) }
    }
```

- [ ] **Step 4: Build**

Run: `xcodegen generate && xcodebuild -project Pensieve.xcodeproj -scheme Pensieve -configuration Debug -derivedDataPath ./.build-xcode build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Non-blocking smoke-launch**

Run:
```bash
PENSIEVE_DB=/tmp/s4-t5.sqlite PENSIEVE_CAPTURE_DB=/tmp/s4-t5-cap.sqlite \
  ./.build-xcode/Build/Products/Debug/Pensieve.app/Contents/MacOS/Pensieve &
PID=$!; sleep 3; kill $PID 2>/dev/null; echo "launched pid $PID"
```
Expected: launches without crashing.

- [ ] **Step 6: Commit**

```bash
git add Sources/PensieveApp/NodeOrganizing.swift Sources/PensieveApp/SidebarView.swift Sources/PensieveApp/ContentListView.swift
git commit -F - <<'EOF'
feat(app): in-place rename + New Child/Rename/Change Type context menu

Shared NodeContextMenu + NodeNameField on both tree and content-list
rows; Enter/blur commit, Esc cancels. symbol(for:) now covers all seven
kinds. Move/Merge menu items land in the next task.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01GsAu7rTTdD77k3xZHZrhm4
EOF
```

**Human-verify (needs the built app, `open` the bundle):** right-click a tree row and a content-list row → New Child creates a child that appears in the middle list in rename mode; typing + Enter renames it, Esc cancels; Change Type ▸ shows all seven kinds with a checkmark on the current one and switching updates the tree icon.

---

### Task 6: Move to… / Merge into… pickers + merge confirmation + toolbar "+" / File ▸ New Node

**Files:**
- Modify: `Sources/PensieveApp/NodeOrganizing.swift` (extend `NodeContextMenu`; add `MovePicker`, `MergePicker`)
- Modify: `Sources/PensieveApp/AppModel.swift` (picker-presentation state)
- Modify: `Sources/PensieveApp/RootView.swift` (mount sheets + toolbar "+")
- Modify: `Sources/PensieveApp/PensieveApp.swift:36-40` (File ▸ New Node ⌘N)

**Interfaces:**
- Consumes: `AppModel.moveTargets`, `move`, `merge`, `createNode`, `node(_:)` (Task 4).
- Produces (on `AppModel`): `@Published var movePickerNodeID: UUID?`, `@Published var mergePickerNodeID: UUID?`. Views: `MovePicker`, `MergePicker`.

- [ ] **Step 1: Add picker-presentation state to `AppModel`**

In `AppModel`, next to `renamingNodeID`, add:

```swift
  /// Non-nil while a Move/Merge picker sheet is up for that node. Mounted in RootView.
  @Published var movePickerNodeID: UUID?
  @Published var mergePickerNodeID: UUID?
```

- [ ] **Step 2: Extend `NodeContextMenu` with Move/Merge**

In `Sources/PensieveApp/NodeOrganizing.swift`, add to `NodeContextMenu.body` after the `Menu("Change Type")` block:

```swift
    Divider()
    Button("Move to…") { model.movePickerNodeID = node.id }
    Button("Merge into…") { model.mergePickerNodeID = node.id }
```

- [ ] **Step 3: Add `MovePicker` and `MergePicker` to `NodeOrganizing.swift`**

```swift
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
```

- [ ] **Step 4: Mount the picker sheets + toolbar "+" in `RootView`**

In `Sources/PensieveApp/RootView.swift`, add these modifiers to the `NavigationSplitView` (alongside the existing `.sheet`/`.inspector`/`.onChange`):

```swift
    .toolbar {
      ToolbarItem {
        Button { model.createNode(under: nil) } label: { Image(systemName: "plus") }
          .help("New Node")
      }
    }
    .sheet(isPresented: Binding(get: { model.movePickerNodeID != nil },
                                set: { if !$0 { model.movePickerNodeID = nil } })) {
      if let id = model.movePickerNodeID { MovePicker(model: model, nodeID: id) }
    }
    .sheet(isPresented: Binding(get: { model.mergePickerNodeID != nil },
                                set: { if !$0 { model.mergePickerNodeID = nil } })) {
      if let id = model.mergePickerNodeID { MergePicker(model: model, nodeID: id) }
    }
```

- [ ] **Step 5: Add File ▸ New Node (⌘N)**

In `Sources/PensieveApp/PensieveApp.swift`, inside the existing `CommandGroup(after: .newItem)` (lines 36-40), add the New Node button *before* "Open in New Window":

```swift
      CommandGroup(after: .newItem) {
        Button("New Node") { model.createNode(under: nil) }
          .keyboardShortcut("n", modifiers: .command)
        Button("Open in New Window") { model.openNodeRequest = model.selectedNodeID }
          .keyboardShortcut("n", modifiers: [.command, .option])
          .disabled(model.selectedNodeID == nil)
      }
```

- [ ] **Step 6: Build**

Run: `xcodegen generate && xcodebuild -project Pensieve.xcodeproj -scheme Pensieve -configuration Debug -derivedDataPath ./.build-xcode build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 7: Non-blocking smoke-launch**

Run:
```bash
PENSIEVE_DB=/tmp/s4-t6.sqlite PENSIEVE_CAPTURE_DB=/tmp/s4-t6-cap.sqlite \
  ./.build-xcode/Build/Products/Debug/Pensieve.app/Contents/MacOS/Pensieve &
PID=$!; sleep 3; kill $PID 2>/dev/null; echo "launched pid $PID"
```
Expected: launches without crashing.

- [ ] **Step 8: Commit**

```bash
git add Sources/PensieveApp/NodeOrganizing.swift Sources/PensieveApp/AppModel.swift Sources/PensieveApp/RootView.swift Sources/PensieveApp/PensieveApp.swift
git commit -F - <<'EOF'
feat(app): Move/Merge pickers, destructive-merge confirmation, New Node

Move to… (incl. Top level) and Merge into… pickers filter self +
descendants; Merge requires a destructive confirmation. Toolbar "+" and
File ▸ New Node (⌘N) create a top-level node.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01GsAu7rTTdD77k3xZHZrhm4
EOF
```

**Human-verify:** Move to… lists neither the node nor any of its descendants, plus a "Top level" row; moving updates the tree. Merge into… → pick a target → confirmation names both nodes → confirm merges (the merged node's activity now shows under the target). `pensieve list` reflects the same tree after each op.

---

### Task 7: Localize the new chrome strings (English base + German)

**Files:**
- Modify: `Sources/PensieveApp/Localizable.xcstrings`

**Interfaces:** none (data only). Note: `xcodebuild build` does NOT extract keys — add them by hand.

New English keys introduced across Tasks 4–6 (verbatim, must match the Swift literals exactly):

| English key | German (`de`) |
|---|---|
| `New Node` | `Neuer Knoten` |
| `New Child` | `Neues Unterelement` |
| `Rename` | `Umbenennen` |
| `Change Type` | `Typ ändern` |
| `Move to…` | `Verschieben nach…` |
| `Merge into…` | `Zusammenführen mit…` |
| `Top level` | `Oberste Ebene` |
| `Cancel` | `Abbrechen` |
| `Merge` | `Zusammenführen` |
| `Merge “%@” into “%@”? Its sources, activity, and loose ends move to the target, and the original is deleted. This can’t be undone.` | `„%1$@“ mit „%2$@“ zusammenführen? Quellen, Aktivität und offene Enden werden zum Ziel verschoben und das Original gelöscht. Dies kann nicht rückgängig gemacht werden.` |

Notes:
- Kind labels (`Domain`/`Project`/… ) are **roles → not localized** (English, capitalized) — do **not** add keys for them.
- The confirmation's two names are content interpolated as `%@` args; the German value uses positional `%1$@`/`%2$@`. `Cancel` may already exist in the catalog — if so, reuse it (don't duplicate).

- [ ] **Step 1: Confirm which keys are already present**

Run:
```bash
python3 -c "import json;d=json.load(open('Sources/PensieveApp/Localizable.xcstrings'));print([k for k in ['New Node','New Child','Rename','Change Type','Move to…','Merge into…','Top level','Cancel','Merge'] if k in d['strings']])"
```
Expected: prints the subset already present (likely `[]` or just `['Cancel']`). Add only the missing ones.

- [ ] **Step 2: Add each missing key to the catalog**

For each missing English key, add an entry under `"strings"` following the file's existing shape. Example for a plain key:

```json
    "New Node" : {
      "localizations" : {
        "de" : { "stringUnit" : { "state" : "translated", "value" : "Neuer Knoten" } }
      }
    },
```

For the confirmation format string, the `value` uses `%1$@`/`%2$@`:

```json
    "Merge “%@” into “%@”? Its sources, activity, and loose ends move to the target, and the original is deleted. This can’t be undone." : {
      "localizations" : {
        "de" : { "stringUnit" : { "state" : "translated", "value" : "„%1$@“ mit „%2$@“ zusammenführen? Quellen, Aktivität und offene Enden werden zum Ziel verschoben und das Original gelöscht. Dies kann nicht rückgängig gemacht werden." } }
      }
    },
```

Match the source key's smart quotes (`“ ” … ’`) and `%@` order **exactly** — a mismatched key silently falls back to English.

- [ ] **Step 3: Validate the JSON**

Run: `python3 -c "import json;json.load(open('Sources/PensieveApp/Localizable.xcstrings'));print('valid json')"`
Expected: `valid json`.

- [ ] **Step 4: Build + verify the German bundle strings**

Run:
```bash
xcodegen generate && xcodebuild -project Pensieve.xcodeproj -scheme Pensieve -configuration Debug -derivedDataPath ./.build-xcode build 2>&1 | tail -3
plutil -p ./.build-xcode/Build/Products/Debug/Pensieve.app/Contents/Resources/de.lproj/Localizable.strings | grep -iE "Knoten|Umbenennen|Zusammenführen" | head
```
Expected: `** BUILD SUCCEEDED **` and the German values appear in the compiled `de.lproj/Localizable.strings`.

- [ ] **Step 5: Forced-locale smoke-launch (German)**

Run:
```bash
PENSIEVE_DB=/tmp/s4-t7.sqlite PENSIEVE_CAPTURE_DB=/tmp/s4-t7-cap.sqlite \
  ./.build-xcode/Build/Products/Debug/Pensieve.app/Contents/MacOS/Pensieve -AppleLanguages '(de)' &
PID=$!; sleep 3; kill $PID 2>/dev/null; echo "launched de pid $PID"
```
Expected: launches without crashing (visual German check is a human carry).

- [ ] **Step 6: Commit**

```bash
git add Sources/PensieveApp/Localizable.xcstrings
git commit -F - <<'EOF'
feat(l10n): German for slice-4 organizing chrome

Adds the organizing menu/picker/confirmation strings (en base + de) to
the String Catalog, hand-reconciled against the Swift literals. Kind
labels stay English (roles are never localized).

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01GsAu7rTTdD77k3xZHZrhm4
EOF
```

---

## Self-Review

**Spec coverage:**
- Five ops — New Child (T4 `createNode` + T5 menu), Rename (T4 `rename` + T5 field/menu), Change Type (T4 `retype` + T5 menu, all 7 kinds), Move to… (T4 `move` + T6 `MovePicker`, incl. Top level), Merge into… (T2 fix + T4 `merge` + T6 `MergePicker` + confirmation). ✓
- Toolbar "+" + File ▸ New Node — T6. ✓
- Cycle guard on reparent — T1; group self-cycle — T2; descendant picker filter — T3 + T4 `moveTargets`. ✓
- Rename-in-middle-list wrinkle — T4 `createNode` routing + T5. ✓
- Deletion only via merge / no undo / no archive — enforced by omission (Global Constraints). ✓
- Localize chrome only — T7; kind labels excluded. ✓
- Tests on the three Kit changes — T1/T2/T3. ✓

**Placeholder scan:** No TBD/TODO; every code step shows full code; every test step shows the assertions. ✓

**Type consistency:** `reparent(_:nodeID:newParentID:)`, `group(_:into:)`, `descendantIDs(of:in:)`, `createNode(under:)`, `rename(_:to:)`, `retype(_:to:)`, `move(_:under:)`, `merge(_:into:)`, `moveTargets(for:)`, `renamingNodeID`, `movePickerNodeID`, `mergePickerNodeID`, `NodeKindOption.all` — names are used identically across tasks. ✓

## Verification (whole slice)

- `./scripts/test.sh` — 173 existing + ~10 new Kit tests pass.
- `xcodegen generate && xcodebuild … build` succeeds; inner-binary smoke-launch boots (throwaway DBs).
- Human carries (built app, real store via plain `open`): create/rename/retype/move/merge round-trips; Move/Merge never list self or descendants; merge confirmation copy is right; `pensieve list` matches the app's tree; German locale renders the new chrome.
