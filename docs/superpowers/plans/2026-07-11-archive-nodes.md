# Archive Nodes Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let the user archive a node (whole subtree) to move stale work into a collapsed, out-of-sight "Archived" sidebar section, with new captured activity automatically resurfacing it.

**Architecture:** Archive reuses the existing `Node.state == "archived"` (no migration). Two tested PensieveKit write ops (`archive`/`unarchive`) plus a tested ingest-path resurrection step do the load-bearing work; the app adds thin filtering (active vs archived forests), a collapsed sidebar section, and Archive/Unarchive context-menu actions.

**Tech Stack:** Swift 6, SwiftUI (app target, untested), SQLiteData/GRDB (PensieveKit, tested with Swift Testing), XcodeGen + Xcode 26.6 for the app bundle.

## Global Constraints

- **No migration** — `Node.state` (`"active" | "archived" | "muted"`) already exists (`Node.swift:23`).
- **SQLiteData predicates use `.eq(x)`, never `== x`** — e.g. `.where { $0.id.eq(id) }`.
- **Trust gate untouched** — this feature touches no cited/loose-end code.
- **Capture path stays sacred** — resurrection lives in the **ingest** path only, never in capture.
- **PensieveKit is tested; the app is not.** Keep derivation logic in Kit; keep views thin. Verify app changes with an `xcodebuild` build + a non-blocking smoke-launch of the inner binary with throwaway `PENSIEVE_DB`/`PENSIEVE_CAPTURE_DB`.
- **Kit test command:** `./scripts/test.sh --filter <TestName>` (or plain `./scripts/test.sh`).
- **App build:** `xcodegen generate && xcodebuild -project Pensieve.xcodeproj -scheme Pensieve -configuration Debug -derivedDataPath ./.build-xcode build`. Inner binary: `./.build-xcode/Build/Products/Debug/Pensieve.app/Contents/MacOS/Pensieve`.
- **Localization:** app UI strings go in `Sources/PensieveApp/Localizable.xcstrings` with hand-authored German (impersonal/infinitive); `xcodebuild` does NOT auto-populate keys.
- **Muted is deferred** — this plan builds Archive only. `muted` stays a latent state with no write path or UI, but the resurrection logic must leave `muted` nodes untouched.

---

### Task 1: `NodeCommands.archive` / `unarchive` (PensieveKit, tested)

Two whole-subtree state writes. Mirror `retype` (state-only update) and `delete` (subtree via `NodeForest.descendantIDs`). No source/branchKey guard — archive is always allowed.

**Files:**
- Modify: `Sources/PensieveKit/Query/NodeCommands.swift` (add ops after `update`, ~line 102)
- Test: `Tests/PensieveKitTests/NodeCommandsTests.swift` (append)

**Interfaces:**
- Consumes: `NodeForest.descendantIDs(of:in:) -> Set<UUID>`, `NodeCommands.add`, `NodeCommands.reparent`.
- Produces:
  - `NodeCommands.archive(_ db: any DatabaseWriter, nodeID: UUID) throws -> Bool`
  - `NodeCommands.unarchive(_ db: any DatabaseWriter, nodeID: UUID) throws -> Bool`
  - Both set the whole subtree (`nodeID` ∪ descendants) to `"archived"` / `"active"`; return `false` (writing nothing) for an unknown `nodeID`.

- [ ] **Step 1: Write the failing test**

Append to `Tests/PensieveKitTests/NodeCommandsTests.swift`:

```swift
@Test func archiveAndUnarchiveWholeSubtree() throws {
  let db = try openCanonicalDatabase(at: tempURL("archive"))
  let proj = try #require(try NodeCommands.add(db, name: "Colibri", kind: "project", parent: nil, description: ""))
  let strandA = try #require(try NodeCommands.add(db, name: "auth", kind: "strand", parent: "Colibri", description: ""))
  let strandB = try #require(try NodeCommands.add(db, name: "ui", kind: "strand", parent: "Colibri", description: ""))

  // Archive the project → whole subtree archived.
  #expect(try NodeCommands.archive(db, nodeID: proj.id))
  func state(_ id: UUID) throws -> String? {
    try db.read { db in try Node.where { $0.id.eq(id) }.fetchOne(db)?.state }
  }
  #expect(try state(proj.id) == "archived")
  #expect(try state(strandA.id) == "archived")
  #expect(try state(strandB.id) == "archived")

  // Unarchive → whole subtree active again.
  #expect(try NodeCommands.unarchive(db, nodeID: proj.id))
  #expect(try state(proj.id) == "active")
  #expect(try state(strandA.id) == "active")
  #expect(try state(strandB.id) == "active")

  // Unknown id → false, writes nothing.
  #expect(try NodeCommands.archive(db, nodeID: UUID()) == false)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `./scripts/test.sh --filter archiveAndUnarchiveWholeSubtree`
Expected: FAIL — `archive`/`unarchive` are not members of `NodeCommands`.

- [ ] **Step 3: Write minimal implementation**

In `Sources/PensieveKit/Query/NodeCommands.swift`, add after the `update` function (~line 102):

```swift
  /// Archive `nodeID` and all its descendants (whole-subtree, state = "archived"). Unlike
  /// `delete`, archive is always allowed — it's the escape hatch for source-bearing nodes that
  /// `delete` refuses. Returns false — writing nothing — for an unknown id.
  @discardableResult
  public static func archive(_ db: any DatabaseWriter, nodeID: UUID) throws -> Bool {
    try setSubtreeState(db, nodeID: nodeID, to: "archived")
  }

  /// Restore `nodeID` and all its descendants to state = "active".
  @discardableResult
  public static func unarchive(_ db: any DatabaseWriter, nodeID: UUID) throws -> Bool {
    try setSubtreeState(db, nodeID: nodeID, to: "active")
  }

  private static func setSubtreeState(_ db: any DatabaseWriter, nodeID: UUID, to state: String) throws -> Bool {
    try db.write { db in
      guard try Node.where({ $0.id.eq(nodeID) }).fetchOne(db) != nil else { return false }
      let all = try Node.all.fetchAll(db)
      let ids = NodeForest.descendantIDs(of: nodeID, in: all).union([nodeID])
      for id in ids {
        try Node.where { $0.id.eq(id) }.update { $0.state = state }.execute(db)
      }
      return true
    }
  }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `./scripts/test.sh --filter archiveAndUnarchiveWholeSubtree`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/PensieveKit/Query/NodeCommands.swift Tests/PensieveKitTests/NodeCommandsTests.swift
git commit -F - <<'EOF'
feat(kit): NodeCommands.archive/unarchive (whole-subtree state write)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
```

---

### Task 2: Resurrection on activity (PensieveKit ingest, tested)

When a new git commit or Claude session is attributed to an archived node, flip that node **and its ancestor chain** back to `"active"`. Leave `muted` nodes untouched. Sibling descendants stay archived.

**Files:**
- Modify: `Sources/PensieveKit/Ingest/Ingester.swift` (add helper + 2 call sites in the git.commit and cc.session `writeSync` blocks)
- Test: `Tests/PensieveKitTests/IngesterTests.swift` (append)

**Interfaces:**
- Consumes: `NodeCommands.ancestorIDs(_ db: Database, of: UUID) throws -> [UUID]` (returns `[parent, …, root]`, excludes the node), `Node.state`.
- Produces: private `Ingester.resurfaceIfArchived(_ db: Database, nodeID: UUID) throws` — for `nodeID` and each ancestor, sets `state` to `"active"` when it is currently `"archived"` (skips `"muted"` and `"active"`).

- [ ] **Step 1: Write the failing test**

Append to `Tests/PensieveKitTests/IngesterTests.swift`:

```swift
@Test func newActivityResurfacesArchivedNodeAndAncestors() async throws {
  let (repo, _) = try makeCommittedRepo()
  let spool = try CaptureSpool(at: tempURL("spool"))
  let db = try openCanonicalDatabase(at: tempURL("canon"))

  // First commit → drain → creates the project node P (active, root).
  let hash1 = Git.run(["rev-parse", "HEAD"], in: repo.path)!
  try spool.append(kind: CaptureKind.gitCommit,
                   payload: try encodeJSON(GitCommitPayload(repoPath: repo.path, hash: hash1, branch: "main")))
  _ = try await Ingester(spool: spool, db: db).drain()
  let proj = try #require(try await db.read { db in try Node.all.fetchAll(db).first })

  // Give P a parent domain D and an extra child strand S.
  let domain = try #require(try NodeCommands.add(db, name: "Work", kind: "domain", parent: nil, description: ""))
  _ = try NodeCommands.reparent(db, nodeID: proj.id, newParentID: domain.id)
  let strand = try #require(try NodeCommands.add(db, name: "sibling", kind: "strand", parent: proj.name, description: ""))

  // Archive the whole subtree (D + P + S archived), then make D muted (sticky).
  #expect(try NodeCommands.archive(db, nodeID: domain.id))
  try await db.write { db in try Node.where { $0.id.eq(domain.id) }.update { $0.state = "muted" }.execute(db) }

  // Second commit → drain → attributes to P.
  try "more".write(to: repo.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)
  _ = Git.run(["add", "-A"], in: repo.path)
  _ = Git.run(["commit", "-m", "second commit"], in: repo.path)
  let hash2 = Git.run(["rev-parse", "HEAD"], in: repo.path)!
  try spool.append(kind: CaptureKind.gitCommit,
                   payload: try encodeJSON(GitCommitPayload(repoPath: repo.path, hash: hash2, branch: "main")))
  _ = try await Ingester(spool: spool, db: db).drain()

  func state(_ id: UUID) async throws -> String? {
    try await db.read { db in try Node.where { $0.id.eq(id) }.fetchOne(db)?.state }
  }
  #expect(try await state(proj.id) == "active")     // resurfaced
  #expect(try await state(domain.id) == "muted")    // ancestor stays sticky
  #expect(try await state(strand.id) == "archived") // sibling descendant untouched
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `./scripts/test.sh --filter newActivityResurfacesArchivedNodeAndAncestors`
Expected: FAIL — `state(proj.id)` is `"archived"` (no resurrection yet).

- [ ] **Step 3: Write minimal implementation**

In `Sources/PensieveKit/Ingest/Ingester.swift`, add the helper near `attributeToNode` (after it, ~line 166):

```swift
  /// After attributing an event, bring an archived node (and its ancestor chain) back to
  /// "active" so it reappears in place. Muted nodes are sticky and left untouched. Runs inside
  /// the write transaction that inserted the event.
  private func resurfaceIfArchived(_ db: Database, nodeID: UUID) throws {
    let chain = try [nodeID] + NodeCommands.ancestorIDs(db, of: nodeID)
    for id in chain {
      guard let n = try Node.where({ $0.id.eq(id) }).fetchOne(db), n.state == "archived" else { continue }
      try Node.where { $0.id.eq(id) }.update { $0.state = "active" }.execute(db)
    }
  }
```

Then call it in the git.commit `writeSync` block, immediately after the `Event.insert { … }.execute(db)` (~line 68, before `return (true, attr.bornStrand)`):

```swift
        try resurfaceIfArchived(db, nodeID: attr.nodeID)
```

And identically in the cc.session `writeSync` block, after its `Event.insert { … }.execute(db)` (~line 121, before `return (true, attr.bornStrand, branchKey)`):

```swift
        try resurfaceIfArchived(db, nodeID: attr.nodeID)
```

(Do NOT add it to the git.checkout path — a checkout is not "work done"; the spec resurfaces on commits and sessions only.)

- [ ] **Step 4: Run test to verify it passes**

Run: `./scripts/test.sh --filter newActivityResurfacesArchivedNodeAndAncestors`
Expected: PASS.

- [ ] **Step 5: Run the full Kit suite to confirm no regression**

Run: `./scripts/test.sh`
Expected: PASS (all existing tests + the two new ones).

- [ ] **Step 6: Commit**

```bash
git add Sources/PensieveKit/Ingest/Ingester.swift Tests/PensieveKitTests/IngesterTests.swift
git commit -F - <<'EOF'
feat(kit): resurface an archived node + ancestors on new activity

New git commit / cc.session attributed to an archived node flips it and its
ancestor chain back to active (muted stays sticky). Ingest path only.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
```

---

### Task 3: Archived filtering, forests & collapsed sidebar section (app)

Split the app's single `forest` into an active forest (`state == "active"`) and a new `archivedForest` (`state == "archived"`); render the archived forest in a new collapsed sidebar section; scope middle-list children and `projectCount` to match. Includes one Kit characterization test proving `NodeForest.build` re-roots an archived-only subset.

**Files:**
- Modify: `Sources/PensieveApp/AppModel.swift` (`forest` region ~line 90; `refresh()` ~lines 359-363; `middleKind()` ~line 383-385; `projectCount` ~line 371)
- Modify: `Sources/PensieveApp/SidebarView.swift` (add the Archived section + `@AppStorage`)
- Test: `Tests/PensieveKitTests/NodeForestTests.swift` (append the re-root characterization test)

**Interfaces:**
- Consumes: `NodeForest.build(_:) -> [NodeForestNode]`, `NodeContextResolver.visibleNodeIDs(for:in:)`, `Node.state`.
- Produces: `AppModel.archivedForest: [NodeForestNode]` (published), scoped to `state == "archived"` and the active Focus context.

- [ ] **Step 1: Write the Kit characterization test (re-root)**

Append to `Tests/PensieveKitTests/NodeForestTests.swift`:

```swift
@Test func archivedOnlySubsetReRootsUnderAbsentParent() {
  // Active parent P, archived child C: an archived-only forest promotes C to a root.
  let p = Node(name: "P", kind: "project", description: "")   // active
  let c = Node(name: "C", state: "archived", parentID: p.id, kind: "strand", description: "")
  let archived = [p, c].filter { $0.state == "archived" }
  let forest = NodeForest.build(archived)
  #expect(forest.count == 1)
  #expect(forest.first?.node.id == c.id)   // C is a root, not dropped
}
```

- [ ] **Step 2: Run it (already passes — characterizes existing behavior)**

Run: `./scripts/test.sh --filter archivedOnlySubsetReRootsUnderAbsentParent`
Expected: PASS (re-root is existing `NodeForest.build` behavior — this locks it in for the archived section).

- [ ] **Step 3: Add `archivedForest` state to `AppModel`**

In `Sources/PensieveApp/AppModel.swift`, next to `@Published var forest` (~line 90), add:

```swift
  @Published var archivedForest: [NodeForestNode] = []
```

- [ ] **Step 4: Filter the active forest and build the archived forest in `refresh()`**

In `AppModel.swift`, replace the forest-building block in `refresh()` (currently ~lines 359-363):

```swift
    if nodesChanged || activeFocusContext != lastForestContext {
      let source = activeFocusContext.isEmpty ? allNodes : allNodes.filter { visible.contains($0.id) }
      forest = NodeForest.build(source)
      lastForestContext = activeFocusContext
    }
```

with:

```swift
    if nodesChanged || activeFocusContext != lastForestContext {
      let source = activeFocusContext.isEmpty ? allNodes : allNodes.filter { visible.contains($0.id) }
      forest = NodeForest.build(source.filter { $0.state == "active" })
      archivedForest = NodeForest.build(source.filter { $0.state == "archived" })
      lastForestContext = activeFocusContext
    }
```

- [ ] **Step 5: Scope middle-list children to the selected node's state class**

In `AppModel.swift`, replace the `.node` case of `middleKind()` (~lines 383-385):

```swift
    case .node(let id):
      let kids = children(of: id)
      return kids.isEmpty ? .looseEndsOf(id) : .nodes(kids)
```

with:

```swift
    case .node(let id):
      // Show archived children under an archived node, active children under an active one, so
      // the two "worlds" don't bleed into each other.
      let showArchived = node(id)?.state == "archived"
      let kids = children(of: id).filter { ($0.state == "archived") == showArchived }
      return kids.isEmpty ? .looseEndsOf(id) : .nodes(kids)
```

- [ ] **Step 6: Scope `projectCount` to active roots**

In `AppModel.swift`, replace `projectCount` (~line 371):

```swift
  var projectCount: Int { allNodes.filter { $0.parentID == nil && $0.kind == NodeKind.project }.count }
```

with:

```swift
  var projectCount: Int {
    allNodes.filter { $0.parentID == nil && $0.kind == NodeKind.project && $0.state == "active" }.count
  }
```

- [ ] **Step 7: Add the collapsed "Archived" sidebar section**

In `Sources/PensieveApp/SidebarView.swift`, add the `@AppStorage` (after line 8):

```swift
  @AppStorage("sidebar.archived.expanded") private var archivedExpanded = false
```

Then, after the "Projects" `Section` (after line 43, inside the `List`), add:

```swift
      if !model.archivedForest.isEmpty {
        Section("Archived", isExpanded: $archivedExpanded) {
          OutlineGroup(model.archivedForest, children: \.childrenIfAny) { item in
            nodeRow(item)
          }
        }
      }
```

- [ ] **Step 8: Build the app**

Run: `xcodegen generate && xcodebuild -project Pensieve.xcodeproj -scheme Pensieve -configuration Debug -derivedDataPath ./.build-xcode build`
Expected: `BUILD SUCCEEDED`.

- [ ] **Step 9: Smoke-launch the inner binary (non-blocking)**

Run:

```bash
PENSIEVE_DB=$(mktemp -u).sqlite PENSIEVE_CAPTURE_DB=$(mktemp -u).sqlite \
  ./.build-xcode/Build/Products/Debug/Pensieve.app/Contents/MacOS/Pensieve &
PID=$!; sleep 3; kill $PID 2>/dev/null; echo "launched pid $PID ok"
```

Expected: launches without crashing (no dialog), prints `launched pid … ok`.

- [ ] **Step 10: Commit**

```bash
git add Sources/PensieveApp/AppModel.swift Sources/PensieveApp/SidebarView.swift Tests/PensieveKitTests/NodeForestTests.swift
git commit -F - <<'EOF'
feat(app): split active/archived forests + collapsed Archived sidebar section

Archived nodes leave the active tree/middle list and render in a new
collapsed-by-default "Archived" section. projectCount counts active roots.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
```

---

### Task 4: Archive/Unarchive actions, selection relocation & German l10n (app)

Wire the write ops into the app: context-menu Archive/Unarchive on both sidebar and middle-list rows, `AppModel` methods that relocate selection off an archived subtree, and localized strings.

**Files:**
- Modify: `Sources/PensieveApp/AppModel.swift` (add `archive`/`unarchive` in the organizing-writes section, ~after `move`, line 563)
- Modify: `Sources/PensieveApp/NodeOrganizing.swift` (`NodeContextMenu`, ~lines 124-135)
- Modify: `Sources/PensieveApp/Localizable.xcstrings` (add 3 keys with German)

**Interfaces:**
- Consumes: `NodeCommands.archive`/`unarchive` (Task 1), `NodeForest.descendantIDs(of:in:)`, `AppModel.refresh()`.
- Produces:
  - `AppModel.archive(_ nodeID: UUID)` — archives the subtree; if the current `selectedNodeID`/`sidebarSelection` is inside it, relocate to `.briefing`.
  - `AppModel.unarchive(_ nodeID: UUID)` — unarchives the subtree.

- [ ] **Step 1: Add `archive`/`unarchive` to `AppModel`**

In `Sources/PensieveApp/AppModel.swift`, after `move(_:under:)` (~line 563), add:

```swift
  func archive(_ nodeID: UUID) {
    guard let db else { return }
    // Selection moves off the whole archived subtree so we don't strand the detail pane on a
    // node that just left the active tree.
    let subtree = NodeForest.descendantIDs(of: nodeID, in: allNodes).union([nodeID])
    _ = try? NodeCommands.archive(db, nodeID: nodeID)
    if let sel = selectedNodeID, subtree.contains(sel) { selectedNodeID = nil }
    if case .node(let id) = sidebarSelection, subtree.contains(id) { sidebarSelection = .briefing }
    refresh()
  }

  func unarchive(_ nodeID: UUID) {
    guard let db else { return }
    _ = try? NodeCommands.unarchive(db, nodeID: nodeID)
    refresh()
  }
```

- [ ] **Step 2: Add the context-menu buttons**

In `Sources/PensieveApp/NodeOrganizing.swift`, inside `NodeContextMenu.body`, add an Archive/Unarchive control. Replace the block from `Button("Move to…")` down through the `Delete` button (lines 130-134) with:

```swift
    Button("Move to…") { model.movePickerNodeID = node.id }
    Button("Merge into…") { model.mergePickerNodeID = node.id }
    Divider()
    if node.state == "archived" {
      Button("Unarchive") { model.unarchive(node.id) }
    } else {
      Button("Archive") { model.archive(node.id) }
    }
    Button("Delete…", role: .destructive) { model.pendingDeleteNodeID = node.id }
      .disabled(!model.canDelete(node.id))
```

- [ ] **Step 3: Add the German localization keys**

In `Sources/PensieveApp/Localizable.xcstrings`, add three entries to the top-level `"strings"` object (matching the existing per-key shape — `extractionState: "manual"`, a `de` `stringUnit` with `state: "translated"`):

```json
    "Archive" : {
      "extractionState" : "manual",
      "localizations" : {
        "de" : { "stringUnit" : { "state" : "translated", "value" : "Archivieren" } }
      }
    },
    "Archived" : {
      "extractionState" : "manual",
      "localizations" : {
        "de" : { "stringUnit" : { "state" : "translated", "value" : "Archiviert" } }
      }
    },
    "Unarchive" : {
      "extractionState" : "manual",
      "localizations" : {
        "de" : { "stringUnit" : { "state" : "translated", "value" : "Wiederherstellen" } }
      }
    },
```

Verify the file still parses:

Run: `python3 -c "import json; json.load(open('Sources/PensieveApp/Localizable.xcstrings')); print('ok')"`
Expected: `ok`.

- [ ] **Step 4: Build the app**

Run: `xcodegen generate && xcodebuild -project Pensieve.xcodeproj -scheme Pensieve -configuration Debug -derivedDataPath ./.build-xcode build`
Expected: `BUILD SUCCEEDED`.

- [ ] **Step 5: Smoke-launch the inner binary (non-blocking)**

Run:

```bash
PENSIEVE_DB=$(mktemp -u).sqlite PENSIEVE_CAPTURE_DB=$(mktemp -u).sqlite \
  ./.build-xcode/Build/Products/Debug/Pensieve.app/Contents/MacOS/Pensieve &
PID=$!; sleep 3; kill $PID 2>/dev/null; echo "launched pid $PID ok"
```

Expected: launches without crashing, prints `launched pid … ok`.

- [ ] **Step 6: Commit**

```bash
git add Sources/PensieveApp/AppModel.swift Sources/PensieveApp/NodeOrganizing.swift Sources/PensieveApp/Localizable.xcstrings
git commit -F - <<'EOF'
feat(app): Archive/Unarchive context-menu actions + German l10n

Archive/Unarchive on sidebar + middle-list rows; archiving relocates selection
off the archived subtree. Strings localized (Archivieren/Archiviert/Wiederherstellen).

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
```

---

## Human-verify carries (need the built app + a real store, plain `open`)

- Right-click a node in the sidebar tree and in the middle list → **Archive** → it disappears from the active tree and appears under a collapsed **Archived** section (expand to see it, with its subtree intact).
- Archiving the currently-selected node moves the detail pane off it (lands on Briefing).
- Right-click an archived node → **Unarchive** → its subtree returns to the active tree.
- Make a fresh git commit in an archived project's repo, let the sync daemon drain (`tail -f ~/Library/Logs/Pensieve/sync.log`) → the node resurfaces in the active tree in place; a muted ancestor (if any) stays put.
- Smart Lists / Briefing / Spotlight no longer surface an archived node; it returns after resurrection.
- German: launch with `-AppleLanguages '(de)'` → menu shows *Archivieren* / *Wiederherstellen*, section header *Archiviert*.

## Self-review notes

- **Spec coverage:** write path (Task 1), resurrection incl. muted-untouched + ancestor chain (Task 2), active/archived forest filtering + re-root + middle-list + projectCount (Task 3), collapsed section (Task 3), context-menu actions + selection relocation + l10n (Task 4), out-of-scope items (CLI/muted UI/MCP) intentionally omitted. ✓
- **Type consistency:** `archive`/`unarchive`/`setSubtreeState`/`resurfaceIfArchived`/`archivedForest` names are used identically across tasks. `NodeCommands.ancestorIDs` and `NodeForest.descendantIDs` signatures match their definitions. ✓
- **No placeholders:** every code and command step is concrete. ✓
