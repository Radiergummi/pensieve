# App Intents Foundation (+ Spotlight via IndexedEntity) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give Pensieve.app an App Intents foundation — a `NodeEntity` (searchable in Spotlight via `IndexedEntity`) plus an Open-Node and a parameterized Show-Pensieve-List intent — so one entity/intent model lights up Spotlight content, Siri, and Shortcuts, all routing through the live `pensieve://` deep-link path.

**Architecture:** Derivation stays in tested PensieveKit (a new `NodeFacts` grounded helper); the App Intents / Spotlight code is thin and lives in the app target. Intents run **in the app process**, so `perform()` reuses the existing `AppDelegate` → `pendingDeepLink` bridge (the same path external `pensieve://` opens already take). Spotlight indexing is a clear-then-index of the active node set, triggered on launch + ⌘R.

**Tech Stack:** Swift 6, SwiftUI `App` lifecycle, App Intents (`AppEntity`/`IndexedEntity`/`AppIntent`/`OpenIntent`/`AppShortcutsProvider`), Core Spotlight (`CSSearchableIndex`), SQLiteData (GRDB), XcodeGen + Xcode 26.6.

## Global Constraints

- **Deployment target:** app target = **macOS 15.0** (set in Task 0); `IndexedEntity` requires it. `Package.swift` (PensieveKit) **stays `.macOS(.v14)`** — do not bump it; no App-Intents/Spotlight code goes in PensieveKit.
- **Predicates:** SQLiteData uses `.eq(x)`, never `== x`. Reuse `CaptureKind` / `SourceKind` constants; never hardcode kind strings.
- **No `@available`/`#available` guards** in the app target — the whole target is macOS 15+.
- **App target has no unit tests.** App-target tasks verify with `xcodegen generate` + `xcodebuild … build` (expect `BUILD SUCCEEDED`) + a **non-blocking** smoke-launch of the inner binary with throwaway `PENSIEVE_DB`/`PENSIEVE_CAPTURE_DB`. Only PensieveKit gets XCTest/Swift-Testing coverage.
- **Store access from intents/queries/indexer is read-only:** `openCanonicalDatabaseReadOnly(at: Stores.canonicalURL)` (returns `DatabaseReader`; no migrator; can't create the file) — degrade to empty on any failure. Never use `openCanonicalDatabase` (read-write, migrates) from these paths.
- **Never set `PENSIEVE_DB`/`PENSIEVE_CAPTURE_DB` against the live store.** Smoke tests point them at `/tmp` throwaway paths.
- **Commits:** no backticks inside `git commit -m "…"` (they shell-execute). Keep the repo's `Co-Authored-By:` + `Claude-Session:` trailers (the executing skill adds them).
- **Build command (app):** `xcodegen generate && xcodebuild -project Pensieve.xcodeproj -scheme Pensieve -configuration Debug -derivedDataPath ./.build-xcode build`. Inner binary: `./.build-xcode/Build/Products/Debug/Pensieve.app/Contents/MacOS/Pensieve`.

---

## File Structure

**PensieveKit (tested):**
- Create `Sources/PensieveKit/Query/NodeFacts.swift` — `NodeFacts` value + `NodeFactsQueries.all` / `.facts(for:)`.
- Create `Tests/PensieveKitTests/NodeFactsTests.swift`.

**App target (thin, `Sources/PensieveApp/AppIntents/`):**
- Create `NodeEntity.swift` — `NodeEntity: AppEntity, IndexedEntity` + `init(facts:)`.
- Create `NodeEntityQuery.swift` — `EntityQuery` + `EntityStringQuery`; read-only store access.
- Create `PensieveIntents.swift` — `PensieveListOption` (`AppEnum`), `OpenNodeIntent`, `ShowPensieveListIntent`, `PensieveIntentBridge`.
- Create `PensieveShortcuts.swift` — `AppShortcutsProvider`.
- Create `SpotlightIndexer.swift` — clear-then-index driver.
- Modify `Sources/PensieveApp/AppDelegate.swift` — extract shared `receive(_:)`.
- Modify `Sources/PensieveApp/AppModel.swift` — call the indexer in `drainThenRefresh()`.
- Modify `project.yml` — deployment target 14 → 15.

**Dependency order:** Task 0 → 1 → 2 → 3 → 4 → 5 → 6. (1 and 2 are independent of each other; 3 needs 0+1; 4 needs 2+3; 5 needs 1+3.)

---

## Task 0: Bump deployment target to macOS 15

**Files:**
- Modify: `project.yml` (the `deploymentTarget.macOS` value)

**Interfaces:**
- Consumes: nothing.
- Produces: an app target whose floor is macOS 15 (enables `IndexedEntity` in Tasks 3–5). `LSMinimumSystemVersion` already interpolates `$(MACOSX_DEPLOYMENT_TARGET)`, so it updates automatically.

- [ ] **Step 1: Edit the deployment target**

In `project.yml`, under the target's `deploymentTarget:`, change:
```yaml
  deploymentTarget:
    macOS: "14.0"
```
to:
```yaml
  deploymentTarget:
    macOS: "15.0"
```

- [ ] **Step 2: Regenerate and build to prove the bump is clean**

Run: `xcodegen generate && xcodebuild -project Pensieve.xcodeproj -scheme Pensieve -configuration Debug -derivedDataPath ./.build-xcode build`
Expected: `** BUILD SUCCEEDED **` (nothing uses macOS 15 APIs yet; this only proves the floor bump breaks nothing).

- [ ] **Step 3: Confirm the generated Info.plist floor**

Run: `/usr/bin/plutil -p ./.build-xcode/Build/Products/Debug/Pensieve.app/Contents/Info.plist | grep LSMinimumSystemVersion`
Expected: `"LSMinimumSystemVersion" => "15.0"`

- [ ] **Step 4: Commit**

```bash
git add project.yml
git commit -m "build: raise app deployment target to macOS 15 for IndexedEntity"
```

---

## Task 1: `NodeFacts` grounded helper (PensieveKit, TDD)

**Files:**
- Create: `Sources/PensieveKit/Query/NodeFacts.swift`
- Test: `Tests/PensieveKitTests/NodeFactsTests.swift`

**Interfaces:**
- Consumes: `Node`, `Event`, `LooseEnd` models; `CaptureKind`, `SourceKind`; `ProjectResolver`; the `tempURL(_:)` + `openCanonicalDatabase(at:)` test idiom (see `NextQueriesTests.swift`).
- Produces:
  - `struct NodeFacts: Sendable { let node: Node; let openLooseEnds: Int; let daysDormant: Int }`
  - `NodeFactsQueries.all(_ db: any DatabaseReader, now: Date) throws -> [NodeFacts]` — active nodes only.
  - `NodeFactsQueries.facts(for ids: [UUID], _ db: any DatabaseReader, now: Date) throws -> [NodeFacts]` — by id, any state.

- [ ] **Step 1: Write the failing tests**

Create `Tests/PensieveKitTests/NodeFactsTests.swift`:
```swift
import Foundation
import Testing
import SQLiteData
@testable import PensieveKit

@Test func nodeFactsComputesGroundedFactsForActiveNodes() throws {
  let db = try openCanonicalDatabase(at: tempURL("nodefacts"))
  let resolver = ProjectResolver(db: db)
  let (a, sa) = try resolver.resolve(path: "/p/a", kind: SourceKind.claudeCode)
  let tenDaysAgo = Calendar.current.date(byAdding: .day, value: -10, to: Date())!
  try db.write { db in
    let ea = Event(nodeID: a.id, sourceID: sa.id, occurredAt: tenDaysAgo, kind: CaptureKind.ccSession,
                   summary: "s", detailJSON: "{}", fingerprint: "a1")
    try Event.insert { ea }.execute(db)
    try LooseEnd.insert {
      LooseEnd(nodeID: a.id, sourceEventID: ea.id, text: "t", quote: "q", role: "user")
    }.execute(db)
    try LooseEnd.insert {   // a resolved loose end must NOT be counted
      LooseEnd(nodeID: a.id, sourceEventID: ea.id, text: "t2", quote: "q2", status: "resolved")
    }.execute(db)
  }
  let facts = try NodeFactsQueries.all(db, now: Date())
  let fa = try #require(facts.first { $0.node.id == a.id })
  #expect(fa.openLooseEnds == 1)   // resolved excluded
  #expect(fa.daysDormant == 10)
}

@Test func nodeFactsExcludesArchivedFromAllButFetchesByID() throws {
  let db = try openCanonicalDatabase(at: tempURL("nodefacts-archived"))
  let archivedID = UUID()
  try db.write { db in
    try Node.insert { Node(id: archivedID, name: "Archived", state: "archived") }.execute(db)
  }
  let all = try NodeFactsQueries.all(db, now: Date())
  #expect(!all.contains { $0.node.id == archivedID })   // active-only population
  let byID = try NodeFactsQueries.facts(for: [archivedID], db, now: Date())
  #expect(byID.first?.node.id == archivedID)             // a tap still resolves it
  #expect(byID.first?.daysDormant == 0)                  // no events → 0
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `./scripts/test.sh --filter NodeFacts`
Expected: FAIL to compile / "cannot find 'NodeFactsQueries' in scope".

- [ ] **Step 3: Write the implementation**

Create `Sources/PensieveKit/Query/NodeFacts.swift`:
```swift
import Foundation
import SQLiteData

/// Grounded per-node facts for glance surfaces (Spotlight subtitle, rankings). Mirrors the dormancy +
/// open-loose-end logic in `NextQueries.ranked`; kept as a shared helper. Read-only (`DatabaseReader`).
public struct NodeFacts: Sendable {
  public let node: Node
  public let openLooseEnds: Int
  public let daysDormant: Int   // days since latest Event; 0 if the node has no events

  public init(node: Node, openLooseEnds: Int, daysDormant: Int) {
    self.node = node; self.openLooseEnds = openLooseEnds; self.daysDormant = daysDormant
  }
}

public enum NodeFactsQueries {
  /// Active nodes with their grounded facts (the same live set `NextQueries` surfaces).
  public static func all(_ db: any DatabaseReader, now: Date) throws -> [NodeFacts] {
    try db.read { db in
      try Node.where { $0.state.eq("active") }.fetchAll(db).map { try facts(for: $0, db, now: now) }
    }
  }

  /// Facts for specific node ids, **any state** (so a Spotlight tap on a since-archived node resolves).
  public static func facts(for ids: [UUID], _ db: any DatabaseReader, now: Date) throws -> [NodeFacts] {
    try db.read { db in
      try ids.compactMap { id in
        guard let node = try Node.where { $0.id.eq(id) }.fetchOne(db) else { return nil }
        return try facts(for: node, db, now: now)
      }
    }
  }

  private static func facts(for node: Node, _ db: Database, now: Date) throws -> NodeFacts {
    let latest = try Event.where { $0.nodeID.eq(node.id) }
      .order { $0.occurredAt.desc() }.limit(1).fetchOne(db)
    let dormant = latest.map {
      Calendar.current.dateComponents([.day], from: $0.occurredAt, to: now).day ?? 0
    } ?? 0
    let open = try LooseEnd.where { $0.nodeID.eq(node.id) && $0.status.eq("open") }.fetchAll(db).count
    return NodeFacts(node: node, openLooseEnds: open, daysDormant: dormant)
  }
}
```
(If `Database` isn't found at compile time, add `import GRDB` — SQLiteData usually re-exports it.)

- [ ] **Step 4: Run tests to verify they pass**

Run: `./scripts/test.sh --filter NodeFacts`
Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/PensieveKit/Query/NodeFacts.swift Tests/PensieveKitTests/NodeFactsTests.swift
git commit -m "feat: NodeFacts grounded per-node helper (active-only + by-id)"
```

---

## Task 2: Extract `AppDelegate.receive(_:)` shared bridge

**Files:**
- Modify: `Sources/PensieveApp/AppDelegate.swift`

**Interfaces:**
- Consumes: `DeepLink`, `AppModel.pendingDeepLink` (existing).
- Produces: `@MainActor func receive(_ link: DeepLink)` on `AppDelegate` — sets `model.pendingDeepLink` or buffers if the model isn't wired yet. Called by `application(_:open:)` (now) and the intent bridge (Task 4).

- [ ] **Step 1: Refactor to a shared `receive`**

In `Sources/PensieveApp/AppDelegate.swift`, replace the `application(_:open:)` method with:
```swift
  func application(_ application: NSApplication, open urls: [URL]) {
    for url in urls {
      guard let link = DeepLink(url: url) else { continue }
      receive(link)
    }
  }

  /// Single entry point for a resolved deep link — from an external `pensieve://` open OR an App
  /// Intent's `perform()`. Forwards to the wired model, else buffers until the model is set.
  func receive(_ link: DeepLink) {
    if let model {
      model.pendingDeepLink = link
    } else {
      buffered = link
    }
  }
```
(Leave the `model` property, `buffered`, and `flush()` unchanged.)

- [ ] **Step 2: Build**

Run: `xcodegen generate && xcodebuild -project Pensieve.xcodeproj -scheme Pensieve -configuration Debug -derivedDataPath ./.build-xcode build`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Smoke-launch + verify external deep link still routes**

Run (non-blocking):
```bash
PENSIEVE_DB=/tmp/pz-t.sqlite PENSIEVE_CAPTURE_DB=/tmp/pz-c.sqlite \
  ./.build-xcode/Build/Products/Debug/Pensieve.app/Contents/MacOS/Pensieve & PID=$!
sleep 3; open "pensieve://smartlist/dormant"; sleep 1
kill $PID 2>/dev/null; echo "ok"
```
Expected: launches and exits cleanly, `ok` printed (the URL routing path is unchanged behavior; this confirms the refactor didn't break launch).

- [ ] **Step 4: Commit**

```bash
git add Sources/PensieveApp/AppDelegate.swift
git commit -m "refactor: extract AppDelegate.receive shared deep-link entry point"
```

---

## Task 3: `NodeEntity` + `NodeEntityQuery`

**Files:**
- Create: `Sources/PensieveApp/AppIntents/NodeEntity.swift`
- Create: `Sources/PensieveApp/AppIntents/NodeEntityQuery.swift`

**Interfaces:**
- Consumes: `NodeFacts`, `NodeFactsQueries` (Task 1); `Stores.canonicalURL`, `openCanonicalDatabaseReadOnly` (existing).
- Produces:
  - `struct NodeEntity: AppEntity, IndexedEntity` with `id: UUID`, `name`, `subtitle`, `searchBody: String`, `init(facts: NodeFacts)`, `static var defaultQuery = NodeEntityQuery()`.
  - `struct NodeEntityQuery: EntityQuery, EntityStringQuery`.

- [ ] **Step 1: Create `NodeEntity`**

Create `Sources/PensieveApp/AppIntents/NodeEntity.swift`:
```swift
import AppIntents
import CoreSpotlight
import UniformTypeIdentifiers
import PensieveKit

/// A Pensieve node as an App Intents entity — searchable in Spotlight (IndexedEntity) and openable.
/// Thin: all derivation comes from the tested `NodeFacts` kernel.
struct NodeEntity: AppEntity, IndexedEntity {
  let id: UUID
  let name: String
  let subtitle: String     // grounded facts line
  let searchBody: String   // Node.description — the searchable body

  static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Node")
  static let defaultQuery = NodeEntityQuery()

  var displayRepresentation: DisplayRepresentation {
    DisplayRepresentation(title: "\(name)", subtitle: "\(subtitle)")
  }

  /// IndexedEntity override: only name + description are matched (spec decision #4).
  var attributeSet: CSSearchableItemAttributeSet {
    let attrs = CSSearchableItemAttributeSet(contentType: .content)
    attrs.title = name
    attrs.displayName = name
    attrs.contentDescription = searchBody.isEmpty ? subtitle : searchBody
    return attrs
  }

  init(facts: NodeFacts) {
    self.id = facts.node.id
    self.name = facts.node.name
    self.searchBody = facts.node.description
    let n = facts.openLooseEnds
    self.subtitle = "\(facts.node.kind) · \(n) open loose end\(n == 1 ? "" : "s") · dormant \(facts.daysDormant)d"
  }
}
```
(If `CSSearchableItemAttributeSet(contentType: .content)` doesn't resolve, use `.text`; both are `UTType`s from `UniformTypeIdentifiers`.)

- [ ] **Step 2: Create `NodeEntityQuery`**

Create `Sources/PensieveApp/AppIntents/NodeEntityQuery.swift`:
```swift
import AppIntents
import SQLiteData
import PensieveKit

/// Resolves NodeEntities for Spotlight/Shortcuts/Siri. Opens the canonical store READ-ONLY and
/// degrades to empty if it's missing — an intent surface must never create/migrate the store.
struct NodeEntityQuery: EntityQuery, EntityStringQuery {
  /// A tap / by-id resolution — any state, so a since-archived node still opens. Unknown id → dropped.
  func entities(for identifiers: [UUID]) async throws -> [NodeEntity] {
    read { try NodeFactsQueries.facts(for: identifiers, $0, now: Date()) }.map(NodeEntity.init(facts:))
  }

  /// The Shortcuts parameter picker — active nodes.
  func suggestedEntities() async throws -> [NodeEntity] {
    read { try NodeFactsQueries.all($0, now: Date()) }.map(NodeEntity.init(facts:))
  }

  /// Name search (case-insensitive). Nodes are few, so filter in Swift — no fragile LIKE predicate.
  func entities(matching string: String) async throws -> [NodeEntity] {
    read { try NodeFactsQueries.all($0, now: Date()) }
      .filter { $0.node.name.localizedCaseInsensitiveContains(string) }
      .map(NodeEntity.init(facts:))
  }

  private func read(_ body: (any DatabaseReader) throws -> [NodeFacts]) -> [NodeFacts] {
    guard let db = try? openCanonicalDatabaseReadOnly(at: Stores.canonicalURL) else { return [] }
    return (try? body(db)) ?? []
  }
}
```

- [ ] **Step 3: Build**

Run: `xcodegen generate && xcodebuild -project Pensieve.xcodeproj -scheme Pensieve -configuration Debug -derivedDataPath ./.build-xcode build`
Expected: `** BUILD SUCCEEDED **`. (This is the real gate — `IndexedEntity` conformance compiling proves Task 0's macOS 15 floor is in effect.)

- [ ] **Step 4: Commit**

```bash
git add Sources/PensieveApp/AppIntents/NodeEntity.swift Sources/PensieveApp/AppIntents/NodeEntityQuery.swift
git commit -m "feat: NodeEntity (AppEntity + IndexedEntity) and its query"
```

---

## Task 4: Intents + Shortcuts provider

**Files:**
- Create: `Sources/PensieveApp/AppIntents/PensieveIntents.swift`
- Create: `Sources/PensieveApp/AppIntents/PensieveShortcuts.swift`

**Interfaces:**
- Consumes: `NodeEntity` (Task 3); `AppDelegate.receive` (Task 2); `DeepLink`, `DeepLink.SmartList` (PensieveKit).
- Produces: `PensieveListOption: AppEnum`; `OpenNodeIntent: OpenIntent`; `ShowPensieveListIntent: AppIntent`; `PensieveIntentBridge.route(_:)`; `PensieveShortcuts: AppShortcutsProvider`.

- [ ] **Step 1: Create the intents + bridge**

Create `Sources/PensieveApp/AppIntents/PensieveIntents.swift`:
```swift
import AppIntents
import AppKit
import PensieveKit

/// The three smart lists as an intent parameter. Raw values match `DeepLink.SmartList` so the mapping
/// below is a pure re-label; the exhaustive switch fails to compile if a case is ever added (no drift).
enum PensieveListOption: String, AppEnum {
  case whatsNext, dormant, recentlyActive

  static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Pensieve List")
  static let caseDisplayRepresentations: [PensieveListOption: DisplayRepresentation] = [
    .whatsNext: "What's Next",
    .dormant: "Dormant",
    .recentlyActive: "Recently Active",
  ]

  var deepLinkKind: DeepLink.SmartList {
    switch self {
    case .whatsNext: return .whatsNext
    case .dormant: return .dormant
    case .recentlyActive: return .recentlyActive
    }
  }
}

/// Hands a resolved deep link to the shared AppDelegate bridge — the same path external `pensieve://`
/// opens use. Must run on the main actor (touches NSApp). Fire-and-forget w.r.t. navigation.
enum PensieveIntentBridge {
  @MainActor static func route(_ link: DeepLink) {
    (NSApp.delegate as? AppDelegate)?.receive(link)
  }
}

/// Open a specific node's recall view. `OpenIntent` implies opening the app. The system resolves
/// `target` via NodeEntityQuery BEFORE perform() runs; a deleted id → perform() never runs (silent).
struct OpenNodeIntent: OpenIntent {
  static let title: LocalizedStringResource = "Open Node"
  @Parameter(title: "Node") var target: NodeEntity

  @MainActor func perform() async throws -> some IntentResult {
    PensieveIntentBridge.route(.node(target.id))
    return .result()
  }
}

/// Open one of the three smart lists (What's Next / Dormant / Recently Active).
struct ShowPensieveListIntent: AppIntent {
  static let title: LocalizedStringResource = "Show Pensieve List"
  static let openAppWhenRun = true
  @Parameter(title: "List") var list: PensieveListOption

  @MainActor func perform() async throws -> some IntentResult {
    PensieveIntentBridge.route(.smartList(list.deepLinkKind))
    return .result()
  }
}
```

- [ ] **Step 2: Create the Shortcuts provider**

Create `Sources/PensieveApp/AppIntents/PensieveShortcuts.swift`:
```swift
import AppIntents

/// One declaration surfaces each action in Siri, the Shortcuts app, and as a Spotlight action.
/// Keeping OpenNodeIntent here is load-bearing: an IndexedEntity is only surfaced in Spotlight when
/// it is also referenced as an App Shortcut parameter. Do not drop it.
struct PensieveShortcuts: AppShortcutsProvider {
  static var appShortcuts: [AppShortcut] {
    AppShortcut(
      intent: ShowPensieveListIntent(),
      phrases: [
        "Show my \(.applicationName) list",
        "What's next in \(.applicationName)",
        "Show my dormant projects in \(.applicationName)",
      ],
      shortTitle: "Show List",
      systemImageName: "list.bullet")
    AppShortcut(
      intent: OpenNodeIntent(),
      phrases: ["Open a node in \(.applicationName)"],
      shortTitle: "Open Node",
      systemImageName: "doc.text")
  }
}
```

- [ ] **Step 3: Build**

Run: `xcodegen generate && xcodebuild -project Pensieve.xcodeproj -scheme Pensieve -configuration Debug -derivedDataPath ./.build-xcode build`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Smoke-launch (intents register without crashing launch)**

Run (non-blocking):
```bash
PENSIEVE_DB=/tmp/pz-t.sqlite PENSIEVE_CAPTURE_DB=/tmp/pz-c.sqlite \
  ./.build-xcode/Build/Products/Debug/Pensieve.app/Contents/MacOS/Pensieve & PID=$!
sleep 3; kill $PID 2>/dev/null; echo "ok"
```
Expected: launches, `ok` printed (App Intents metadata is compiled in; a malformed intent would fail the build, not launch — this just confirms no launch regression).

- [ ] **Step 5: Commit**

```bash
git add Sources/PensieveApp/AppIntents/PensieveIntents.swift Sources/PensieveApp/AppIntents/PensieveShortcuts.swift
git commit -m "feat: Open-Node + Show-Pensieve-List intents and App Shortcuts"
```

---

## Task 5: `SpotlightIndexer` + AppModel wiring

**Files:**
- Create: `Sources/PensieveApp/AppIntents/SpotlightIndexer.swift`
- Modify: `Sources/PensieveApp/AppModel.swift` (`drainThenRefresh()`)

**Interfaces:**
- Consumes: `NodeFactsQueries.all` (Task 1); `NodeEntity.init(facts:)` (Task 3); `Stores.canonicalURL`, `openCanonicalDatabaseReadOnly` (existing).
- Produces: `enum SpotlightIndexer { static func reindex() async }`.

- [ ] **Step 1: Create the indexer**

Create `Sources/PensieveApp/AppIntents/SpotlightIndexer.swift`:
```swift
import Foundation
import CoreSpotlight
import PensieveKit

/// Clear-then-index the active node set into Spotlight. Full re-index (nodes are few) keeps the index
/// in exact sync — archived/deleted nodes drop out each run. Read-only; best-effort; never fatal.
enum SpotlightIndexer {
  static func reindex() async {
    guard let db = try? openCanonicalDatabaseReadOnly(at: Stores.canonicalURL) else { return }
    let facts = (try? NodeFactsQueries.all(db, now: Date())) ?? []
    let entities = facts.map(NodeEntity.init(facts:))
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

- [ ] **Step 2: Wire it into the launch + refresh path**

In `Sources/PensieveApp/AppModel.swift`, in `drainThenRefresh()`, add the reindex after `refresh()`:
```swift
  private func drainThenRefresh() async {
    if let db, let spool = try? CaptureSpool(at: Stores.spoolURL) {
      _ = try? await Ingester(spool: spool, db: db).drain()   // no LLM: spool → events only
    }
    refresh()
    await SpotlightIndexer.reindex()   // launch + ⌘R only (not the 3 s timer, which calls refresh() directly)
  }
```

- [ ] **Step 3: Build**

Run: `xcodegen generate && xcodebuild -project Pensieve.xcodeproj -scheme Pensieve -configuration Debug -derivedDataPath ./.build-xcode build`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Commit**

```bash
git add Sources/PensieveApp/AppIntents/SpotlightIndexer.swift Sources/PensieveApp/AppModel.swift
git commit -m "feat: Spotlight clear-then-index of active nodes on launch and refresh"
```

---

## Task 6: Full verification + human-check checklist

**Files:** none (verification only).

**Interfaces:** Consumes the whole feature.

- [ ] **Step 1: Full test suite**

Run: `./scripts/test.sh`
Expected: all tests pass (144 prior + 2 new NodeFacts = 146). Note the exact count.

- [ ] **Step 2: Clean build**

Run: `xcodegen generate && xcodebuild -project Pensieve.xcodeproj -scheme Pensieve -configuration Debug -derivedDataPath ./.build-xcode build`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Smoke-launch against a throwaway store, then reindex path runs**

Run (non-blocking):
```bash
PENSIEVE_DB=/tmp/pz-t.sqlite PENSIEVE_CAPTURE_DB=/tmp/pz-c.sqlite \
  ./.build-xcode/Build/Products/Debug/Pensieve.app/Contents/MacOS/Pensieve & PID=$!
sleep 4; kill $PID 2>/dev/null; echo "ok"
```
Expected: launches and exits cleanly (`ok`). The launch drain → `SpotlightIndexer.reindex()` runs without crashing on an empty store.

- [ ] **Step 4: Record the human-verification checklist for the branch review**

These cannot be asserted headlessly — list them in the PR/branch summary for the user to run against the **real** store (a normal `open` of the built app, not the throwaway-env smoke):
  1. Spotlight-search a real node's **name** → it appears → tap → app opens its recall view. *(Also try a word only in its description — records whether content-body matching works on macOS; known-risk, not a gate.)*
  2. **Cold launch:** quit the app fully → invoke "Show Pensieve List" from the Shortcuts app → app foregrounds on the correct list.
  3. **Shortcuts app** lists "Open Node" and "Show Pensieve List" (list picker resolves the three options).
  4. **Siri:** "Show my dormant projects in Pensieve" opens the Dormant list.
  5. Delete a node → ⌘R / relaunch → its stale Spotlight entry is gone.

- [ ] **Step 5: Commit (if any doc/notes added; otherwise skip)**

```bash
git add -A
git commit -m "chore: record App Intents human-verification checklist"
```

---

## Self-Review (completed by plan author)

- **Spec coverage:** target bump (T0) · `NodeFacts` active-only + by-id + read-only signature (T1) · `receive` bridge (T2) · `NodeEntity`/`IndexedEntity` + read-only query + name search (T3) · `OpenNodeIntent`/`ShowPensieveListIntent`/`PensieveListOption` exhaustive mapping + `AppShortcutsProvider` with the load-bearing OpenNode coupling (T4) · clear-then-index on launch+⌘R, not the timer (T5) · full verify + the 5 human items incl. cold-launch and stale-entry (T6). Roadmap/backlog + CLAUDE/CONTINUE updates happen at merge, per spec.
- **Placeholder scan:** none — every code step has complete code; every run step has an expected result.
- **Type consistency:** `NodeFactsQueries.all(_:now:)` / `.facts(for:_:now:)` signatures match across T1/T3/T5; `NodeEntity.init(facts:)` used in T3+T5; `PensieveIntentBridge.route` / `AppDelegate.receive` match T2/T4; `deepLinkKind` maps to `DeepLink.SmartList` consistently.
- **Known build-time adjustments flagged inline:** `Database` import fallback (T1); `CSSearchableItemAttributeSet` UTType `.content`→`.text` fallback (T3).
