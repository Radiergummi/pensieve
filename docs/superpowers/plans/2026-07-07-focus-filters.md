# Focus Filters (Work / Personal context) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** When a macOS Focus is active, Pensieve restricts the main window + menu-bar + Spotlight to the projects/strands matching that Focus's context (Work / Personal), via a `SetFocusFilterIntent` over a new inheritable `context` node attribute.

**Architecture:** All derivation lives in tested PensieveKit — a `context` column (migration v9), a pure `NodeContextResolver` (subtree inheritance + a mute-opposite/show-unset visibility predicate), and `NodeCommands` write support. The app target stays thin: a `SetFocusFilterIntent` persists the active context to `UserDefaults`; `AppModel` observes it and applies the one tested predicate at its existing read boundaries; `SpotlightIndexer` filters its index by the same predicate.

**Tech Stack:** Swift 6, SwiftUI (macOS 15 app target), SQLiteData (GRDB), App Intents (`SetFocusFilterIntent`, `AppEnum`), Swift Testing, XcodeGen + Xcode 26.6, Xcode String Catalog (`Localizable.xcstrings`).

## Global Constraints

- **PensieveKit is the only place derivation/queries live; keep the app target thin.** Tasks 1–3 are Kit (real Swift Testing tests). Tasks 4–7 are app-target-only (no unit tests) — verify each by `xcodegen generate && xcodebuild -project Pensieve.xcodeproj -scheme Pensieve -configuration Debug -derivedDataPath ./.build-xcode build` → `** BUILD SUCCEEDED **`, then a non-blocking smoke-launch of the inner binary `./.build-xcode/Build/Products/Debug/Pensieve.app/Contents/MacOS/Pensieve` with throwaway `PENSIEVE_DB`/`PENSIEVE_CAPTURE_DB` (`/tmp` paths), confirm it stays up ~2s, then `kill`.
- **`Package.swift` stays `.macOS(.v14)`.** All App-Intents / `SetFocusFilterIntent` code is app-target-only. Do NOT bump the package platform floor.
- **SQLiteData predicates use `.eq(x)`, never `== x`.** Tables are STRICT; column names must match `@Table` property names exactly; PKs are UUID.
- **Migrations are additive** and registered in `Sources/PensieveKit/Store/CanonicalStore.swift` after v8, mirroring the v8 `#sql(#"ALTER TABLE …"#)` style.
- **`context` stored values are constants, not localized** — `NodeContext.work = "work"`, `NodeContext.personal = "personal"`, unset = `""`. Only chrome labels are localized.
- **Localization is chrome-only, by hand** in `Sources/PensieveApp/Localizable.xcstrings` (en base = key; add a `de` unit). German is impersonal/infinitive. `xcodebuild` does NOT auto-populate the catalog; validate JSON with `plutil -lint` before building.
- **All node writes go through `AppModel` → `NodeCommands`**; views never call Kit directly. `allNodes` in `AppModel` stays the FULL node set; only the derived/surfaced collections (`lists`, `briefingCards`, `forest`, Spotlight) are filtered.
- **Filter semantic:** a node is visible under active context `C` iff its resolved context `== C` OR is unset; active context `""` ⇒ everything visible.
- Run the Kit test suite with `./scripts/test.sh` (thin `swift test` passthrough).

---

### Task 1: Migration v9 + `Node.context` field

**Files:**
- Modify: `Sources/PensieveKit/Model/Node.swift` (add `context` property + init param)
- Modify: `Sources/PensieveKit/Store/CanonicalStore.swift` (register migration v9)
- Test: `Tests/PensieveKitTests/SchemaV9Tests.swift` (create)

**Interfaces:**
- Produces: `Node.context: String` (default `""`); `Node.init(..., colorTag: String = "", context: String = "")`; migration `"v9-node-context"`.

- [ ] **Step 1: Write the failing test**

Create `Tests/PensieveKitTests/SchemaV9Tests.swift`:
```swift
import Foundation
import Testing
import SQLiteData
@testable import PensieveKit

@Test func v9AddsContextColumnWithDefault() throws {
  let db = try openCanonicalDatabase(at: tempURL("v9"))
  let node = Node(name: "Colibri")
  try db.write { db in try Node.insert { node }.execute(db) }

  // New rows default to "" (== unset / inherit).
  let stored = try db.read { db in try Node.where { $0.id.eq(node.id) }.fetchOne(db) }
  #expect(stored?.context == "")

  // A non-empty value round-trips through the STRICT column.
  try db.write { db in
    try Node.where { $0.id.eq(node.id) }.update { $0.context = "work" }.execute(db)
  }
  let updated = try db.read { db in try Node.where { $0.id.eq(node.id) }.fetchOne(db) }
  #expect(updated?.context == "work")
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `./scripts/test.sh --filter v9AddsContextColumnWithDefault`
Expected: FAIL — `Node` has no member `context` (compile error).

- [ ] **Step 3: Add the property + init param to Node**

In `Sources/PensieveKit/Model/Node.swift`, add the property after `colorTag` and the init param after `colorTag`:
```swift
  public var icon: String           // "" = use kind default; else "sf:<symbol>" or "emoji:<grapheme>"
  public var colorTag: String       // "" = use kind default; else a palette color name
  public var context: String        // "" = unset (inherit from ancestor); else "work" | "personal"

  public init(id: UUID = UUID(), name: String, state: String = "active", createdAt: Date = Date(),
              parentID: UUID? = nil, kind: String = NodeKind.project, description: String = "",
              metadataJSON: String = "{}", branchKey: String? = nil,
              icon: String = "", colorTag: String = "", context: String = "") {
    self.id = id; self.name = name; self.state = state; self.createdAt = createdAt
    self.parentID = parentID; self.kind = kind; self.description = description
    self.metadataJSON = metadataJSON; self.branchKey = branchKey
    self.icon = icon; self.colorTag = colorTag; self.context = context
  }
```

- [ ] **Step 4: Register migration v9**

In `Sources/PensieveKit/Store/CanonicalStore.swift`, add immediately after the `"v8-node-appearance"` migration block and before `try migrator.migrate(db)`:
```swift
  migrator.registerMigration("v9-node-context") { db in
    try #sql(#"ALTER TABLE "nodes" ADD COLUMN "context" TEXT NOT NULL DEFAULT ''"#).execute(db)
  }
```

- [ ] **Step 5: Run test to verify it passes**

Run: `./scripts/test.sh --filter v9AddsContextColumnWithDefault`
Expected: PASS.

- [ ] **Step 6: Run the full suite (nothing regressed)**

Run: `./scripts/test.sh`
Expected: all tests pass (196 + 1 new = 197).

- [ ] **Step 7: Commit**

```bash
git add Sources/PensieveKit/Model/Node.swift Sources/PensieveKit/Store/CanonicalStore.swift Tests/PensieveKitTests/SchemaV9Tests.swift
git commit -m "feat(kit): add inheritable node context field (migration v9)"
```

---

### Task 2: `NodeContext` constants + resolver + visibility predicate

**Files:**
- Create: `Sources/PensieveKit/Query/NodeContext.swift`
- Test: `Tests/PensieveKitTests/NodeContextTests.swift`

**Interfaces:**
- Consumes: `Node.context`, `Node.parentID`, `Node.id` (from Task 1).
- Produces:
  - `enum NodeContext { static let work = "work"; static let personal = "personal"; static let unset = ""; static let all: [String] }`
  - `enum NodeContextResolver { static func resolve(_ nodeID: UUID, in nodes: [Node]) -> String; static func visibleNodeIDs(for active: String, in nodes: [Node]) -> Set<UUID> }`

- [ ] **Step 1: Write the failing tests**

Create `Tests/PensieveKitTests/NodeContextTests.swift`:
```swift
import Foundation
import Testing
@testable import PensieveKit

// Tree: work(domain, "work") > proj(project, "") > strand(strand, "")
//       personalProj(project, "personal")
//       loose(project, "")   ← never set anywhere
private func fixture() -> (work: Node, proj: Node, strand: Node, personal: Node, loose: Node, all: [Node]) {
  let work = Node(name: "Work", kind: NodeKind.domain, context: NodeContext.work)
  let proj = Node(name: "Colibri", parentID: work.id, kind: NodeKind.project)
  let strand = Node(name: "auth", parentID: proj.id, kind: NodeKind.strand)
  let personal = Node(name: "Garden", kind: NodeKind.project, context: NodeContext.personal)
  let loose = Node(name: "Scratch", kind: NodeKind.project)
  return (work, proj, strand, personal, loose, [work, proj, strand, personal, loose])
}

@Test func resolveInheritsNearestAncestor() {
  let f = fixture()
  #expect(NodeContextResolver.resolve(f.strand.id, in: f.all) == "work")   // inherited 2 levels up
  #expect(NodeContextResolver.resolve(f.proj.id, in: f.all) == "work")     // inherited 1 level up
  #expect(NodeContextResolver.resolve(f.work.id, in: f.all) == "work")     // own
  #expect(NodeContextResolver.resolve(f.personal.id, in: f.all) == "personal")
  #expect(NodeContextResolver.resolve(f.loose.id, in: f.all) == "")        // unset everywhere
}

@Test func resolveChildOverridesAncestor() {
  let work = Node(name: "Work", kind: NodeKind.domain, context: NodeContext.work)
  let odd = Node(name: "side", parentID: work.id, kind: NodeKind.strand, context: NodeContext.personal)
  #expect(NodeContextResolver.resolve(odd.id, in: [work, odd]) == "personal")   // own wins over ancestor
}

@Test func visiblePersonalFocusMutesWorkKeepsUnset() {
  let f = fixture()
  let vis = NodeContextResolver.visibleNodeIDs(for: NodeContext.personal, in: f.all)
  #expect(vis.contains(f.personal.id))   // personal shown
  #expect(vis.contains(f.loose.id))      // unset shown
  #expect(!vis.contains(f.work.id))      // work muted
  #expect(!vis.contains(f.proj.id))      // inherits work → muted
  #expect(!vis.contains(f.strand.id))    // inherits work → muted (subtree gone with its parent)
}

@Test func visibleWorkFocusMutesPersonal() {
  let f = fixture()
  let vis = NodeContextResolver.visibleNodeIDs(for: NodeContext.work, in: f.all)
  #expect(vis.contains(f.work.id) && vis.contains(f.proj.id) && vis.contains(f.strand.id))
  #expect(vis.contains(f.loose.id))       // unset shown
  #expect(!vis.contains(f.personal.id))   // personal muted
}

@Test func visibleNoFocusShowsEverything() {
  let f = fixture()
  let vis = NodeContextResolver.visibleNodeIDs(for: "", in: f.all)
  #expect(vis == Set(f.all.map(\.id)))
}

@Test func resolveIsCycleSafe() {
  // Corrupt parent cycle a→b→a must not loop; returns "" (no context found).
  var a = Node(name: "A", kind: NodeKind.project)
  var b = Node(name: "B", kind: NodeKind.project)
  a.parentID = b.id
  b.parentID = a.id
  #expect(NodeContextResolver.resolve(a.id, in: [a, b]) == "")
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `./scripts/test.sh --filter NodeContext`
Expected: FAIL — `NodeContext` / `NodeContextResolver` undefined (compile error).

- [ ] **Step 3: Implement the resolver**

Create `Sources/PensieveKit/Query/NodeContext.swift`:
```swift
import Foundation

/// The `Node.context` string values. Centralized like `NodeKind` so a typo can't misfile a node.
/// The column stays an open `String`; `""` means unset (inherit from the nearest ancestor).
public enum NodeContext {
  public static let work = "work"
  public static let personal = "personal"
  public static let unset = ""

  /// The user-selectable explicit contexts (for the app's Context picker + Focus filter).
  public static let all = [work, personal]
}

/// Pure context resolution + the Focus-filter visibility predicate. Operates on an in-memory `[Node]`
/// (the app already holds the full node set) — no DB round-trip. Tested; the app applies it thinly.
public enum NodeContextResolver {
  /// The effective context of `nodeID`: its own if set, else the nearest ancestor's; `""` if none.
  public static func resolve(_ nodeID: UUID, in nodes: [Node]) -> String {
    resolve(nodeID, byID: Dictionary(nodes.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a }))
  }

  static func resolve(_ nodeID: UUID, byID: [UUID: Node]) -> String {
    var seen: Set<UUID> = []
    var cursor: UUID? = nodeID
    // `seen.insert(...).inserted` bounds a corrupt (pre-existing) parent cycle.
    while let id = cursor, seen.insert(id).inserted, let node = byID[id] {
      if !node.context.isEmpty { return node.context }
      cursor = node.parentID
    }
    return ""
  }

  /// The ids visible under `active`: resolved context equal to `active` OR unset. `active == ""`
  /// (no Focus) ⇒ every id. Generalizes to more contexts: show active + unset, hide every other.
  public static func visibleNodeIDs(for active: String, in nodes: [Node]) -> Set<UUID> {
    let byID = Dictionary(nodes.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    let allIDs = Set(byID.keys)
    guard !active.isEmpty else { return allIDs }
    return allIDs.filter { id in
      let ctx = resolve(id, byID: byID)
      return ctx == active || ctx.isEmpty
    }
  }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `./scripts/test.sh --filter NodeContext`
Expected: PASS (6 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/PensieveKit/Query/NodeContext.swift Tests/PensieveKitTests/NodeContextTests.swift
git commit -m "feat(kit): NodeContext constants + inheritance resolver + visibility predicate"
```

---

### Task 3: `NodeCommands.add` / `.update` accept a context

**Files:**
- Modify: `Sources/PensieveKit/Query/NodeCommands.swift` (`add`, `update`)
- Test: `Tests/PensieveKitTests/NodeCommandsTests.swift` (append one test)

**Interfaces:**
- Consumes: `Node.init(..., context:)` (Task 1).
- Produces: `NodeCommands.add(_:name:kind:parent:description:icon:colorTag:context:)` (context defaulted last); `NodeCommands.update(_:nodeID:name:kind:icon:colorTag:context:)` (context defaulted last).

- [ ] **Step 1: Write the failing test**

Append to `Tests/PensieveKitTests/NodeCommandsTests.swift`:
```swift
@Test func addAndUpdateRoundTripContext() throws {
  let db = try openCanonicalDatabase(at: tempURL("nodecmd-context"))
  let proj = try #require(try NodeCommands.add(db, name: "Garden", kind: "project",
                                               parent: nil, description: "", context: "personal"))
  #expect(proj.context == "personal")

  #expect(try NodeCommands.update(db, nodeID: proj.id, name: "Garden", kind: "project",
                                  icon: "", colorTag: "", context: "work"))
  let reloaded = try db.read { db in try Node.where { $0.id.eq(proj.id) }.fetchOne(db) }
  #expect(reloaded?.context == "work")
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `./scripts/test.sh --filter addAndUpdateRoundTripContext`
Expected: FAIL — `add`/`update` have no `context:` argument (compile error).

- [ ] **Step 3: Thread `context` through `add`**

In `Sources/PensieveKit/Query/NodeCommands.swift`, update `add`'s signature and the `Node(...)` construction:
```swift
  @discardableResult
  public static func add(_ db: any DatabaseWriter, name: String, kind: String,
                         parent: String?, description: String,
                         icon: String = "", colorTag: String = "", context: String = "") throws -> Node? {
    try db.write { db in
      var parentID: UUID? = nil
      if let parent {
        guard let p = try find(db, nameOrID: parent) else { return nil }
        parentID = p.id
      }
      let node = Node(name: name, parentID: parentID, kind: kind, description: description,
                      icon: icon, colorTag: colorTag, context: context)
      try Node.insert { node }.execute(db)
      return node
    }
  }
```

- [ ] **Step 4: Thread `context` through `update`**

In the same file, update `update`'s signature and the update block:
```swift
  @discardableResult
  public static func update(_ db: any DatabaseWriter, nodeID: UUID,
                            name: String, kind: String, icon: String, colorTag: String,
                            context: String = "") throws -> Bool {
    try db.write { db in
      guard try Node.where({ $0.id.eq(nodeID) }).fetchOne(db) != nil else { return false }
      try Node.where { $0.id.eq(nodeID) }.update {
        $0.name = name; $0.kind = kind; $0.icon = icon; $0.colorTag = colorTag; $0.context = context
      }.execute(db)
      return true
    }
  }
```

- [ ] **Step 5: Run test to verify it passes**

Run: `./scripts/test.sh --filter addAndUpdateRoundTripContext`
Expected: PASS.

- [ ] **Step 6: Run the full suite**

Run: `./scripts/test.sh`
Expected: all pass (the existing `addNestRenameRetype` etc. still compile — `context` is defaulted).

- [ ] **Step 7: Commit**

```bash
git add Sources/PensieveKit/Query/NodeCommands.swift Tests/PensieveKitTests/NodeCommandsTests.swift
git commit -m "feat(kit): NodeCommands.add/update accept a context"
```

---

### Task 4: `FocusContextOption` + `PensieveFocusFilter` intent

**Files:**
- Create: `Sources/PensieveApp/AppIntents/PensieveFocusFilter.swift`
- Modify: `Sources/PensieveApp/Localizable.xcstrings` (new chrome strings)

**Interfaces:**
- Consumes: `NodeContext.work` / `.personal` (Task 2).
- Produces: `enum FocusFilterDefaults { static let activeContextKey: String }` (consumed by Task 6); `FocusContextOption: AppEnum`; `PensieveFocusFilter: SetFocusFilterIntent`.

- [ ] **Step 1: Create the intent file**

Create `Sources/PensieveApp/AppIntents/PensieveFocusFilter.swift`:
```swift
import AppIntents
import Foundation
import PensieveKit

/// Where the active Focus context is persisted (single process — no App Group). "" = no filter.
enum FocusFilterDefaults {
  static let activeContextKey = "pensieve.activeFocusContext"
}

/// The two explicit contexts, as a Focus-filter parameter. Raw values match `NodeContext` constants;
/// the exhaustive `nodeContext` switch fails to compile if a case is added (no drift).
enum FocusContextOption: String, AppEnum {
  case work, personal

  static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Pensieve Context")
  static let caseDisplayRepresentations: [FocusContextOption: DisplayRepresentation] = [
    .work: "Work", .personal: "Personal",
  ]

  var nodeContext: String {
    switch self {
    case .work: return NodeContext.work
    case .personal: return NodeContext.personal
    }
  }
}

/// Attach in System Settings → Focus → (a Focus) → Add Filter → Pensieve, then pick a context. On
/// activation the system sets `context`; on deactivation it re-runs perform() with `context == nil`
/// (why the parameter is OPTIONAL — a non-optional one is only delivered on activation). perform()
/// persists the active context; AppModel observes the change and re-filters + reindexes.
struct PensieveFocusFilter: SetFocusFilterIntent {
  static let title: LocalizedStringResource = "Filter Pensieve by Context"

  @Parameter(title: "Context") var context: FocusContextOption?

  var displayRepresentation: DisplayRepresentation {
    switch context {
    case .work: return DisplayRepresentation(title: "Show Work")
    case .personal: return DisplayRepresentation(title: "Show Personal")
    case nil: return DisplayRepresentation(title: "Show All")
    }
  }

  @MainActor func perform() async throws -> some IntentResult {
    UserDefaults.standard.set(context?.nodeContext ?? "", forKey: FocusFilterDefaults.activeContextKey)
    return .result()
  }
}
```

- [ ] **Step 2: Add the new chrome strings to the String Catalog**

Open `Sources/PensieveApp/Localizable.xcstrings` and add these keys in alphabetical position (2-space indent, matching existing entries). `"Work"` and `"Personal"` are reused by the Task 7 picker — add them once here. Each new key needs a `de` unit:

- `"Filter Pensieve by Context"` → de `"Pensieve nach Kontext filtern"`
- `"Pensieve Context"` → de `"Pensieve-Kontext"`
- `"Work"` → de `"Arbeit"`
- `"Personal"` → de `"Persönlich"`
- `"Show Work"` → de `"Arbeit anzeigen"`
- `"Show Personal"` → de `"Persönliches anzeigen"`
- `"Show All"` → de `"Alle anzeigen"`

Entry shape (repeat per key, alphabetical):
```json
    "Show All" : {
      "localizations" : {
        "de" : { "stringUnit" : { "state" : "translated", "value" : "Alle anzeigen" } }
      }
    },
```

- [ ] **Step 3: Validate the catalog JSON**

Run: `plutil -lint Sources/PensieveApp/Localizable.xcstrings`
Expected: `... OK`

- [ ] **Step 4: Build**

Run: `xcodegen generate && xcodebuild -project Pensieve.xcodeproj -scheme Pensieve -configuration Debug -derivedDataPath ./.build-xcode build`
Expected: `** BUILD SUCCEEDED **`.

If `perform()`'s `some IntentResult` or the `SetFocusFilterIntent` conformance triggers a "missing requirement" error, add the missing member the compiler names (do not add speculative members). If a first `xcodebuild` fails with a macro/plugin fingerprint error, trust the plugins (`defaults write com.apple.dt.Xcode IDESkipPackagePluginFingerprintValidation -bool YES` + `…IDESkipMacroFingerprintValidation…`) and retry.

- [ ] **Step 5: Smoke-launch**

```bash
PENSIEVE_DB=/tmp/pv-smoke.sqlite PENSIEVE_CAPTURE_DB=/tmp/pv-smoke-cap.sqlite \
  ./.build-xcode/Build/Products/Debug/Pensieve.app/Contents/MacOS/Pensieve &
PID=$!; sleep 2; kill $PID 2>/dev/null; echo "smoke ok"
```
Expected: `smoke ok`, no crash.

- [ ] **Step 6: Commit**

```bash
git add Sources/PensieveApp/AppIntents/PensieveFocusFilter.swift Sources/PensieveApp/Localizable.xcstrings
git commit -m "feat(app): PensieveFocusFilter SetFocusFilterIntent + context option"
```

---

### Task 5: Filter-aware `SpotlightIndexer`

**Files:**
- Modify: `Sources/PensieveApp/AppIntents/SpotlightIndexer.swift`

**Interfaces:**
- Consumes: `NodeContextResolver.visibleNodeIDs` (Task 2), `ProjectQueries.all`, `NodeFactsQueries.all`, `NodeFacts.node`.
- Produces: `SpotlightIndexer.reindex(activeContext: String = "")` (default keeps existing no-arg callers compiling until Task 6 updates them).

- [ ] **Step 1: Make `reindex` filter by active context**

Replace the body of `Sources/PensieveApp/AppIntents/SpotlightIndexer.swift` with:
```swift
import Foundation
import CoreSpotlight
import PensieveKit

/// Clear-then-index the active node set into Spotlight, restricted to the active Focus context's
/// visible nodes. Full re-index (nodes are few) keeps the index in exact sync. Read-only;
/// best-effort; never fatal.
enum SpotlightIndexer {
  static func reindex(activeContext: String = "") async {
    guard let db = try? openCanonicalDatabaseReadOnly(at: Stores.canonicalURL) else { return }
    let facts = (try? NodeFactsQueries.all(db, now: Date())) ?? []
    let allNodes = (try? ProjectQueries.all(db)) ?? []
    let visible = NodeContextResolver.visibleNodeIDs(for: activeContext, in: allNodes)
    let entities = facts.filter { visible.contains($0.node.id) }.map(NodeEntity.init(facts:))
    let index = CSSearchableIndex.default()
    do {
      try await index.deleteAllSearchableItems()   // Pensieve indexes only nodes → this is exactly our set
      try await index.indexAppEntities(entities)
    } catch {
      // A glance surface must never break the app; a failed index is silently dropped.
    }
  }
}
```

- [ ] **Step 2: Build**

Run: `xcodegen generate && xcodebuild -project Pensieve.xcodeproj -scheme Pensieve -configuration Debug -derivedDataPath ./.build-xcode build`
Expected: `** BUILD SUCCEEDED **` (existing `SpotlightIndexer.reindex()` callers still compile via the default).

- [ ] **Step 3: Smoke-launch**

```bash
PENSIEVE_DB=/tmp/pv-smoke.sqlite PENSIEVE_CAPTURE_DB=/tmp/pv-smoke-cap.sqlite \
  ./.build-xcode/Build/Products/Debug/Pensieve.app/Contents/MacOS/Pensieve &
PID=$!; sleep 2; kill $PID 2>/dev/null; echo "smoke ok"
```
Expected: `smoke ok`.

- [ ] **Step 4: Commit**

```bash
git add Sources/PensieveApp/AppIntents/SpotlightIndexer.swift
git commit -m "feat(app): filter Spotlight index by active Focus context"
```

---

### Task 6: `AppModel` — active-context state, observation, and filtering

**Files:**
- Modify: `Sources/PensieveApp/AppModel.swift`

**Interfaces:**
- Consumes: `NodeContextResolver.visibleNodeIDs` (Task 2), `FocusFilterDefaults.activeContextKey` (Task 4), `SpotlightIndexer.reindex(activeContext:)` (Task 5), `SmartLists`, `BriefingCard.node`, `NextItem.project`, `NodeForest.build`.
- Produces: filtered `lists` / `briefingCards` / `forest`; a private `activeFocusContext`. Nothing consumed by later tasks.

- [ ] **Step 1: Add the active-context state + a filter helper**

In `Sources/PensieveApp/AppModel.swift`, add stored properties near the other private vars (e.g. after `private var allNodes: [Node] = []`):
```swift
  /// The active Focus context ("" = no Focus / unfiltered), mirrored from UserDefaults by the
  /// SetFocusFilterIntent. Drives the visible-node filter applied in refresh()/refreshGlance().
  private var activeFocusContext = ""
  /// Last context the forest was built for — so a context change rebuilds it even when the node set
  /// is unchanged (the `fetched != allNodes` guard alone would skip it).
  private var lastForestContext: String?
```

Add a private helper method (place it just above `func refresh()`):
```swift
  /// Filter a freshly-computed SmartLists to the ids visible under the active context.
  private func filtered(_ l: SmartLists, _ visible: Set<UUID>) -> SmartLists {
    SmartLists(
      whatsNext: l.whatsNext.filter { visible.contains($0.project.id) },
      dormant: l.dormant.filter { visible.contains($0.project.id) },
      recentlyActive: l.recentlyActive.filter { visible.contains($0.project.id) })
  }
```

- [ ] **Step 2: Apply the filter in `refresh()`**

Replace the body of `func refresh()` with (keeps the heartbeat + fetch, adds filtering; rebuilds the forest on node OR context change):
```swift
  func refresh() {
    // Heartbeat from the persistent connections (opening fresh ones here would re-fire the store-dir
    // watch into a busy-loop). Works before the db guard: nil connections degrade to a zero snapshot.
    snapshot = MonitorSnapshot.gather(canonical: db, spool: spool)
    guard let db else { return }
    let now = Date()
    let fetched = (try? ProjectQueries.all(db)) ?? allNodes
    let nodesChanged = fetched != allNodes
    if nodesChanged { allNodes = fetched }
    let visible = NodeContextResolver.visibleNodeIDs(for: activeFocusContext, in: allNodes)

    if let raw = try? SmartLists.compute(db, now: now) {
      lists = activeFocusContext.isEmpty ? raw : filtered(raw, visible)
    }
    if let raw = try? BriefingQueries.cards(db, since: briefingSince, now: now) {
      briefingCards = activeFocusContext.isEmpty ? raw : raw.filter { visible.contains($0.node.id) }
    }
    if nodesChanged || activeFocusContext != lastForestContext {
      let source = activeFocusContext.isEmpty ? allNodes : allNodes.filter { visible.contains($0.id) }
      forest = NodeForest.build(source)
      lastForestContext = activeFocusContext
    }
  }
```

- [ ] **Step 3: Apply the filter in `refreshGlance()`**

Replace the body of `func refreshGlance()` with:
```swift
  func refreshGlance() {
    snapshot = MonitorSnapshot.gather(canonical: db, spool: spool)
    guard let db else { return }
    guard let raw = try? SmartLists.compute(db, now: Date()) else { return }
    let visible = NodeContextResolver.visibleNodeIDs(for: activeFocusContext, in: allNodes)
    lists = activeFocusContext.isEmpty ? raw : filtered(raw, visible)
  }
```

- [ ] **Step 4: Read the context on launch + observe changes in `start()`**

In `func start()`, after `spool = try? CaptureSpool(...)` and before `Task { await drainThenRefresh() }`, seed the context:
```swift
    activeFocusContext = UserDefaults.standard.string(forKey: FocusFilterDefaults.activeContextKey) ?? ""
```
Then, at the end of `start()` (after the `spoolWatcher` assignment), register the observer:
```swift
    // The SetFocusFilterIntent runs in-process and writes UserDefaults → observe on the main queue.
    NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification,
                                           object: nil, queue: .main) { [weak self] _ in
      Task { @MainActor in self?.focusContextDidChange() }
    }
```
Add the handler method (near `refresh()`):
```swift
  /// UserDefaults changed — if the active Focus context flipped, re-filter the window + reindex.
  private func focusContextDidChange() {
    let new = UserDefaults.standard.string(forKey: FocusFilterDefaults.activeContextKey) ?? ""
    guard new != activeFocusContext else { return }
    activeFocusContext = new
    refresh()
    Task { await SpotlightIndexer.reindex(activeContext: new) }
  }
```

- [ ] **Step 5: Pass the active context to the existing Spotlight reindex calls**

In `drainThenRefresh()` change:
```swift
    await SpotlightIndexer.reindex(activeContext: activeFocusContext)   // launch + ⌘R
```
In `reindexSpotlight()` change:
```swift
  private func reindexSpotlight() async { await SpotlightIndexer.reindex(activeContext: activeFocusContext) }
```

- [ ] **Step 6: Build**

Run: `xcodegen generate && xcodebuild -project Pensieve.xcodeproj -scheme Pensieve -configuration Debug -derivedDataPath ./.build-xcode build`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 7: Smoke-launch**

```bash
PENSIEVE_DB=/tmp/pv-smoke.sqlite PENSIEVE_CAPTURE_DB=/tmp/pv-smoke-cap.sqlite \
  ./.build-xcode/Build/Products/Debug/Pensieve.app/Contents/MacOS/Pensieve &
PID=$!; sleep 2; kill $PID 2>/dev/null; echo "smoke ok"
```
Expected: `smoke ok`, no crash (default context "" ⇒ everything visible, unchanged behavior).

- [ ] **Step 8: Commit**

```bash
git add Sources/PensieveApp/AppModel.swift
git commit -m "feat(app): AppModel observes active Focus context and filters window + spotlight"
```

---

### Task 7: Context picker in the New/Edit modal

**Files:**
- Modify: `Sources/PensieveApp/NodeOrganizing.swift` (`NodeEditor`)
- Modify: `Sources/PensieveApp/AppModel.swift` (`commitNewNode`, `updateNode`)
- Modify: `Sources/PensieveApp/Localizable.xcstrings` (add `"Context"`, `"Unset"`)

**Interfaces:**
- Consumes: `NodeContext.work` / `.personal` (Task 2), `NodeCommands.add/update` `context:` (Task 3), `Node.context` (Task 1).
- Produces: nothing consumed elsewhere.

- [ ] **Step 1: Extend the AppModel write wrappers with `context`**

In `Sources/PensieveApp/AppModel.swift`, update `commitNewNode` and `updateNode`:
```swift
  func commitNewNode(parent parentID: UUID?, name: String, kind: String,
                     icon: String, colorTag: String, context: String) {
    guard let db else { return }
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty,
          let new = try? NodeCommands.add(db, name: trimmed, kind: kind,
                                          parent: parentID?.uuidString, description: "",
                                          icon: icon, colorTag: colorTag, context: context) else { return }
    refresh()
    sidebarSelection = .node(new.id); selectedNodeID = new.id
  }
  func updateNode(_ nodeID: UUID, name: String, kind: String,
                  icon: String, colorTag: String, context: String) {
    guard let db else { return }
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    _ = try? NodeCommands.update(db, nodeID: nodeID, name: trimmed, kind: kind,
                                 icon: icon, colorTag: colorTag, context: context)
    refresh()
  }
```

- [ ] **Step 2: Add context state + picker + load/commit wiring to `NodeEditor`**

In `Sources/PensieveApp/NodeOrganizing.swift`:

Add the state var after `icon`:
```swift
  @State private var icon = ""              // stored form "sf:x" / "emoji:x"
  @State private var context = ""           // "" = unset (inherit); else NodeContext.work/.personal
```

Add the Context picker inside the left-zone `Form`, after the Type `Picker`:
```swift
            Picker("Type", selection: $kind) {
              ForEach(NodeKind.all, id: \.self) { k in Text(AppearanceStyle.kindLabel(k)).tag(k) }
            }
            Picker("Context", selection: $context) {
              Text("Unset").tag("")
              Text("Work").tag(NodeContext.work)
              Text("Personal").tag(NodeContext.personal)
            }
```

In `load()`, set `context` in both branches:
```swift
    case .new(let parent):
      let k = model.defaultKind(under: parent)
      kind = k
      let style = NodeKindStyle.style(for: k)
      colorTag = style.colorTag
      icon = style.icon
      name = ""
      context = ""
    case .edit(let node):
      name = node.name
      kind = node.kind
      let a = node.appearance
      colorTag = a.colorTag
      icon = a.icon.storedString
      context = node.context
```

In `commit()`, pass `context`:
```swift
    case .new(let parent):
      model.commitNewNode(parent: parent, name: name, kind: kind, icon: icon, colorTag: colorTag, context: context)
    case .edit(let node):
      model.updateNode(node.id, name: name, kind: kind, icon: icon, colorTag: colorTag, context: context)
```

- [ ] **Step 3: Add the two new strings to the String Catalog**

Open `Sources/PensieveApp/Localizable.xcstrings` and add (alphabetical, 2-space indent). `"Work"` / `"Personal"` already exist from Task 4 — do NOT duplicate.
- `"Context"` → de `"Kontext"`
- `"Unset"` → de `"Nicht festgelegt"`
```json
    "Context" : {
      "localizations" : {
        "de" : { "stringUnit" : { "state" : "translated", "value" : "Kontext" } }
      }
    },
```
```json
    "Unset" : {
      "localizations" : {
        "de" : { "stringUnit" : { "state" : "translated", "value" : "Nicht festgelegt" } }
      }
    },
```

- [ ] **Step 4: Validate the catalog JSON**

Run: `plutil -lint Sources/PensieveApp/Localizable.xcstrings`
Expected: `... OK`

- [ ] **Step 5: Build**

Run: `xcodegen generate && xcodebuild -project Pensieve.xcodeproj -scheme Pensieve -configuration Debug -derivedDataPath ./.build-xcode build`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 6: Smoke-launch**

```bash
PENSIEVE_DB=/tmp/pv-smoke.sqlite PENSIEVE_CAPTURE_DB=/tmp/pv-smoke-cap.sqlite \
  ./.build-xcode/Build/Products/Debug/Pensieve.app/Contents/MacOS/Pensieve &
PID=$!; sleep 2; kill $PID 2>/dev/null; echo "smoke ok"
```
Expected: `smoke ok`.

- [ ] **Step 7: Commit**

```bash
git add Sources/PensieveApp/NodeOrganizing.swift Sources/PensieveApp/AppModel.swift Sources/PensieveApp/Localizable.xcstrings
git commit -m "feat(app): Context picker in New/Edit modal (Work/Personal/Unset)"
```

---

## Whole-branch close-out (after all seven tasks)

- [ ] **Opus whole-branch review** of `main..HEAD` (use this skill's `scripts/review-package`). Focus: no Kit derivation leaked into the app; `Package.swift` platform floor untouched; String Catalog JSON well-formed with `de` units on every new key; the filter predicate applied consistently at all four surfaces (lists, briefing, forest, Spotlight); the forest-rebuild-on-context-change guard is correct; the optional `@Parameter` on `SetFocusFilterIntent` (deactivation path); no `== x` predicates.
- [ ] Fix any Critical/Important findings; re-verify build + smoke (+ `./scripts/test.sh` for Kit tasks).
- [ ] `superpowers:finishing-a-development-branch` → user chooses "merge to main locally"; then update `CONTINUE.md` + the backlog Focus-filters entry with the human-verify carries.

## Human-verify carries (record at merge — cannot be asserted headlessly)

1. In System Settings → Focus → "Personal" → Add Filter → Pensieve, set it to Personal; enable the Focus → main window smart lists / Briefing / tree + the menu-bar popover show only personal + unset nodes; Work nodes hidden. Disable → everything returns.
2. A "Work" Focus set to Work mutes personal nodes; unset nodes stay visible under both Focuses.
3. Spotlight (while a Focus is active) surfaces only the visible subset; switching Focus re-indexes.
4. The New/Edit modal Context picker sets a node's context; a child with unset context is filtered by its parent's context (inheritance); setting a project to Work hides its whole subtree while in Personal.
5. `pensieve list` is unaffected (CLI doesn't surface context in v1).
6. German renders in situ (`-AppleLanguages '(de)'`) for the picker + the Settings filter row.

## Self-review notes

- **Spec coverage:** model+migration (§1)=Task 1; resolver+predicate (§2)=Task 2; write support (§5)=Task 3; intent+plumbing (§4)=Tasks 4+6; surface filtering (§2 apply)=Tasks 5 (Spotlight) + 6 (window/menu-bar); UI picker (§5)=Task 7; localization (§6) folded into Tasks 4 & 7. Menu-bar-filtered amendment reflected (Task 6 filters shared `lists`).
- **Type consistency:** `NodeContextResolver.visibleNodeIDs(for:in:)` / `resolve(_:in:)`, `NodeContext.work/.personal/.unset/.all`, `FocusFilterDefaults.activeContextKey`, `SpotlightIndexer.reindex(activeContext:)`, `NodeCommands.add(...context:)` / `update(...context:)`, `Node.init(...context:)`, `commitNewNode(...context:)` / `updateNode(...context:)` used consistently across tasks. `NextItem.project.id`, `BriefingCard.node.id` match the Kit shapes.
- **No placeholders:** every step has full code or an exact command + expected output.
