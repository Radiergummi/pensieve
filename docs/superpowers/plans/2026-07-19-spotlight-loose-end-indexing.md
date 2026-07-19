# Spotlight loose-end indexing (Track C 1b) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Index open loose ends into macOS Spotlight so a phrase from a loose end's text or its cited quote returns that specific loose end, and tapping it opens Pensieve at the loose end's node with the cited row expanded.

**Architecture:** Mirror the proven `NodeEntity` Spotlight path exactly. Two tested SwiftUI-free Kit pieces (a new `DeepLink.looseEnd` case + a `LooseEndFacts`/`LooseEndFactsQueries` read-only kernel) plus three thin app pieces (a `LooseEndEntity`+`LooseEndEntityQuery`, an `OpenLooseEndIntent` registered as an App Shortcut, and `SpotlightIndexer` gaining a second entity set). Navigation reuses the existing `pensieve://` → `AppDelegate.receive` → `pendingDeepLink` → `applyDeepLink` bridge, routing `.looseEnd` through a new `AppModel.openLooseEnd`.

**Tech Stack:** Swift, App Intents (`AppEntity`/`IndexedEntity`/`EntityQuery`/`OpenIntent`/`AppShortcutsProvider`), Core Spotlight (`CSSearchableIndex`/`CSSearchableItemAttributeSet`), SQLiteData (GRDB), SwiftUI. Kit tested with Swift Testing (`./scripts/test.sh`); app verified by `xcodebuild` + smoke-launch.

## Global Constraints

- **No new capture, schema, migration, or deployment-target change.** Read-only indexing + navigation only. Target is already macOS 15 (for `IndexedEntity`). `Package.swift` stays `.macOS(.v14)` — all App-Intents code is app-target-only.
- **Corpus discipline (identical to every other surface):** open loose ends only (`LooseEnd.isOpen` — `status == "open" && label != "noise"`), in **active** nodes (`Node.state == "active"`), Focus-scoped to the visible set via `NodeContextResolver.visibleNodeIDs`.
- **Grounded-with-provenance north star:** only a loose end's stored `text` and verbatim `quote` are indexed. No LLM, no fabrication.
- **Best-effort + read-only everywhere:** an intent surface / indexer never creates or migrates the store; any failure is silently dropped and can never break the app or the capture/ingest path. Degrade honestly (stale/deleted → open the node, else briefing; never crash).
- **SQLiteData 1.6.6 predicates use `.eq(x)`, NOT `== x`.** Reuse `LooseEnd.isOpen($0)`; don't re-spell the predicate.
- **App-Intents user-facing strings are plain English literals, NOT localized** — matching how `NodeEntity.typeDisplayRepresentation` and `OpenNodeIntent`'s phrase/shortTitle are handled today (App-Intents/Siri/Shortcuts localization is a deferred item). **No `Localizable.xcstrings` changes in this plan.**
- **The `DeepLink` → navigation exhaustive-switch no-drift guard MUST be preserved:** adding the enum case forces a compile error anywhere a switch over `DeepLink` isn't updated.
- **The app has no unit tests** — verify app-target tasks with an `xcodebuild` build + a non-blocking smoke-launch of the inner binary (`./.build-xcode/Build/Products/Debug/Pensieve.app/Contents/MacOS/Pensieve`, background + `kill`, forwarding throwaway `PENSIEVE_DB`/`PENSIEVE_CAPTURE_DB`).

---

## File Structure

- **Modify** `Sources/PensieveKit/Support/DeepLink.swift` — add the `.looseEnd(UUID)` case (parse + serialize).
- **Modify** `Tests/PensieveKitTests/DeepLinkTests.swift` — round-trip + malformed coverage for the new case.
- **Create** `Sources/PensieveKit/Query/LooseEndFacts.swift` — `LooseEndFacts` struct + `LooseEndFactsQueries` (`all` / `facts(for:)`).
- **Create** `Tests/PensieveKitTests/LooseEndFactsTests.swift` — corpus discipline + by-id resolution tests.
- **Create** `Sources/PensieveApp/AppIntents/LooseEndEntity.swift` — `LooseEndEntity: AppEntity, IndexedEntity`.
- **Create** `Sources/PensieveApp/AppIntents/LooseEndEntityQuery.swift` — `LooseEndEntityQuery: EntityQuery, EntityStringQuery`.
- **Modify** `Sources/PensieveApp/AppIntents/PensieveIntents.swift` — add `OpenLooseEndIntent`.
- **Modify** `Sources/PensieveApp/AppIntents/PensieveShortcuts.swift` — register `OpenLooseEndIntent`.
- **Modify** `Sources/PensieveApp/AppIntents/SpotlightIndexer.swift` — index loose ends alongside nodes.
- **Modify** `Sources/PensieveApp/DeepLinkNavigation.swift` — route `.looseEnd` via `AppModel.openLooseEnd` (failable `PaletteDestination(_:)`).
- **Modify** `Sources/PensieveApp/AppModel.swift` — add `openLooseEnd(_ id: UUID)`.

---

### Task 1: Kit — `DeepLink.looseEnd(UUID)` case

**Files:**
- Modify: `Sources/PensieveKit/Support/DeepLink.swift`
- Test: `Tests/PensieveKitTests/DeepLinkTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `DeepLink.looseEnd(UUID)`; grammar `pensieve://looseend/<uuid>`; invariant `DeepLink(url: link.url) == link`.

- [ ] **Step 1: Write the failing tests**

Add to `Tests/PensieveKitTests/DeepLinkTests.swift`:

```swift
@Test func deepLinkRoundTripsLooseEnd() {
  let link = DeepLink.looseEnd(UUID())
  #expect(DeepLink(url: link.url) == link)
}

@Test func deepLinkParsesLooseEndForm() {
  let id = UUID()
  #expect(DeepLink(url: URL(string: "pensieve://looseend/\(id.uuidString)")!) == .looseEnd(id))
}

@Test func deepLinkRejectsMalformedLooseEnd() {
  #expect(DeepLink(url: URL(string: "pensieve://looseend")!) == nil)             // missing uuid
  #expect(DeepLink(url: URL(string: "pensieve://looseend/not-a-uuid")!) == nil)  // bad uuid
  let id = UUID()
  #expect(DeepLink(url: URL(string: "pensieve://looseend/\(id.uuidString)/extra")!) == nil) // trailing
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `./scripts/test.sh --filter DeepLink`
Expected: FAIL — `looseEnd` is not a member of `DeepLink`.

- [ ] **Step 3: Add the enum case + parse + serialize**

In `Sources/PensieveKit/Support/DeepLink.swift`, add the case after `smartList`:

```swift
  case briefing
  case node(UUID)
  case smartList(SmartList)
  case looseEnd(UUID)
```

Update the doc comment grammar block to add the new line:

```swift
///   pensieve://smartlist/<whatsNext|dormant|recentlyActive>
///   pensieve://looseend/<uuid>
```

In `init?(url:)`, add a `case` to the host switch (before `default`):

```swift
    case "looseend":
      guard segments.count == 1, let id = UUID(uuidString: segments[0]) else { return nil }
      self = .looseEnd(id)
```

In `var url`, add a `case` to the switch:

```swift
    case .looseEnd(let id):
      comps.host = "looseend"
      comps.path = "/\(id.uuidString)"
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `./scripts/test.sh --filter DeepLink`
Expected: PASS (all DeepLink tests, including the three new ones).

- [ ] **Step 5: Commit**

```bash
git add Sources/PensieveKit/Support/DeepLink.swift Tests/PensieveKitTests/DeepLinkTests.swift
git commit -F- <<'EOF'
feat(deeplink): add pensieve://looseend/<uuid> case (Track C 1b)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01ByuhXmgmAcdshVcYc8Bf1V
EOF
```

---

### Task 2: Kit — `LooseEndFacts` + `LooseEndFactsQueries`

**Files:**
- Create: `Sources/PensieveKit/Query/LooseEndFacts.swift`
- Test: `Tests/PensieveKitTests/LooseEndFactsTests.swift`

**Interfaces:**
- Consumes: `LooseEnd.isOpen(_:)`, `Node`, `LooseEnd` tables (SQLiteData).
- Produces:
  - `struct LooseEndFacts: Sendable { let looseEndID: UUID; let nodeID: UUID; let nodeName: String; let text: String; let quote: String }`
  - `enum LooseEndFactsQueries` with:
    - `static func all(_ db: any DatabaseReader) throws -> [LooseEndFacts]`
    - `static func facts(for ids: [UUID], _ db: any DatabaseReader) throws -> [LooseEndFacts]`

- [ ] **Step 1: Write the failing tests**

Create `Tests/PensieveKitTests/LooseEndFactsTests.swift`:

```swift
import Foundation
import Testing
import SQLiteData
@testable import PensieveKit

@Test func looseEndFactsAllReturnsOpenEndsInActiveNodesWithNodeName() throws {
  let db = try openCanonicalDatabase(at: tempURL("lef-all"))
  let resolver = ProjectResolver(db: db)
  let (a, sa) = try resolver.resolve(path: "/p/lef", kind: SourceKind.claudeCode)
  let ea = Event(nodeID: a.id, sourceID: sa.id, occurredAt: Date(), kind: CaptureKind.ccSession,
                 summary: "s", detailJSON: "{}", fingerprint: "lef1")
  try db.write { db in
    try Event.insert { ea }.execute(db)
    try LooseEnd.insert {
      LooseEnd(nodeID: a.id, sourceEventID: ea.id, text: "wire up the retry", quote: "we should retry")
    }.execute(db)
    try LooseEnd.insert {   // resolved → excluded
      LooseEnd(nodeID: a.id, sourceEventID: ea.id, text: "done item", quote: "q", status: "resolved")
    }.execute(db)
    try LooseEnd.insert {   // confirmed noise → excluded
      LooseEnd(nodeID: a.id, sourceEventID: ea.id, text: "noise item", quote: "q2",
               label: LooseEndLabel.noise)
    }.execute(db)
  }
  let facts = try LooseEndFactsQueries.all(db)
  #expect(facts.count == 1)
  let f = try #require(facts.first)
  #expect(f.text == "wire up the retry")
  #expect(f.quote == "we should retry")
  #expect(f.nodeID == a.id)
  #expect(f.nodeName == a.name)
}

@Test func looseEndFactsAllExcludesEndsWhoseNodeIsArchived() throws {
  let db = try openCanonicalDatabase(at: tempURL("lef-archived"))
  let nodeID = UUID(), eventID = UUID()
  try db.write { db in
    try Node.insert { Node(id: nodeID, name: "Archived", state: "archived") }.execute(db)
    try LooseEnd.insert {
      LooseEnd(id: UUID(), nodeID: nodeID, sourceEventID: eventID, text: "orphan", quote: "q")
    }.execute(db)
  }
  #expect(try LooseEndFactsQueries.all(db).isEmpty)   // node not active → excluded
}

@Test func looseEndFactsForResolvesKnownIDsAndDropsUnknown() throws {
  let db = try openCanonicalDatabase(at: tempURL("lef-byid"))
  let resolver = ProjectResolver(db: db)
  let (a, sa) = try resolver.resolve(path: "/p/byid", kind: SourceKind.claudeCode)
  let ea = Event(nodeID: a.id, sourceID: sa.id, occurredAt: Date(), kind: CaptureKind.ccSession,
                 summary: "s", detailJSON: "{}", fingerprint: "byid1")
  let openID = UUID(), closedID = UUID()
  try db.write { db in
    try Event.insert { ea }.execute(db)
    try LooseEnd.insert {
      LooseEnd(id: openID, nodeID: a.id, sourceEventID: ea.id, text: "open", quote: "q")
    }.execute(db)
    try LooseEnd.insert {   // a since-closed end STILL resolves by id (degrade: tap opens its node)
      LooseEnd(id: closedID, nodeID: a.id, sourceEventID: ea.id, text: "closed", quote: "q2",
               status: "resolved")
    }.execute(db)
  }
  let facts = try LooseEndFactsQueries.facts(for: [openID, closedID, UUID()], db)
  #expect(facts.count == 2)                                   // unknown dropped; closed still resolves
  #expect(facts.contains { $0.looseEndID == openID && $0.nodeID == a.id && $0.nodeName == a.name })
  #expect(facts.contains { $0.looseEndID == closedID })
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `./scripts/test.sh --filter LooseEndFacts`
Expected: FAIL — `LooseEndFacts` / `LooseEndFactsQueries` are not defined.

- [ ] **Step 3: Write the implementation**

Create `Sources/PensieveKit/Query/LooseEndFacts.swift`:

```swift
import Foundation
import SQLiteData

/// Grounded facts for one open loose end — the searchable payload for the Spotlight `LooseEndEntity`
/// and its by-id tap resolution. Mirrors `NodeFacts`/`NodeFactsQueries`. Read-only (`DatabaseReader`).
public struct LooseEndFacts: Sendable {
  public let looseEndID: UUID
  public let nodeID: UUID
  public let nodeName: String
  public let text: String
  public let quote: String

  public init(looseEndID: UUID, nodeID: UUID, nodeName: String, text: String, quote: String) {
    self.looseEndID = looseEndID; self.nodeID = nodeID; self.nodeName = nodeName
    self.text = text; self.quote = quote
  }
}

public enum LooseEndFactsQueries {
  /// Every open loose end (`LooseEnd.isOpen`) whose node is `active`, joined to its node name.
  /// Focus scoping is applied by the app-side indexer against this set (Kit stays Focus-agnostic).
  public static func all(_ db: any DatabaseReader) throws -> [LooseEndFacts] {
    try db.read { db in
      let activeNodes = try Node.where { $0.state.eq("active") }.fetchAll(db)
      let nameByID = Dictionary(activeNodes.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
      let ends = try LooseEnd.where { LooseEnd.isOpen($0) }.fetchAll(db)
      return ends.compactMap { le in
        guard let name = nameByID[le.nodeID] else { return nil }   // node not active → excluded
        return LooseEndFacts(looseEndID: le.id, nodeID: le.nodeID, nodeName: name,
                             text: le.text, quote: le.quote)
      }
    }
  }

  /// By-id resolution for a Spotlight tap — **any status/label/node-state**, so a since-closed or
  /// archived-node loose end still resolves (a tap opens its node). Unknown id → dropped.
  public static func facts(for ids: [UUID], _ db: any DatabaseReader) throws -> [LooseEndFacts] {
    try db.read { db in
      try ids.compactMap { id in
        guard let le = try LooseEnd.where({ $0.id.eq(id) }).fetchOne(db) else { return nil }
        let name = try Node.where({ $0.id.eq(le.nodeID) }).fetchOne(db)?.name ?? ""
        return LooseEndFacts(looseEndID: le.id, nodeID: le.nodeID, nodeName: name,
                             text: le.text, quote: le.quote)
      }
    }
  }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `./scripts/test.sh --filter LooseEndFacts`
Expected: PASS (all three tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/PensieveKit/Query/LooseEndFacts.swift Tests/PensieveKitTests/LooseEndFactsTests.swift
git commit -F- <<'EOF'
feat(query): LooseEndFacts + LooseEndFactsQueries kernel (Track C 1b)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01ByuhXmgmAcdshVcYc8Bf1V
EOF
```

---

### Task 3: App — `LooseEndEntity` + `LooseEndEntityQuery`

**Files:**
- Create: `Sources/PensieveApp/AppIntents/LooseEndEntity.swift`
- Create: `Sources/PensieveApp/AppIntents/LooseEndEntityQuery.swift`

**Interfaces:**
- Consumes: `LooseEndFacts`, `LooseEndFactsQueries.all` / `.facts(for:)` (Task 2); `openCanonicalDatabaseReadOnly(at:)`, `Stores.canonicalURL` (PensieveKit).
- Produces:
  - `struct LooseEndEntity: AppEntity, IndexedEntity` with `id: UUID`, `text`, `nodeName`, `quote`; `init(facts: LooseEndFacts)`; `static let defaultQuery = LooseEndEntityQuery()`.
  - `struct LooseEndEntityQuery: EntityQuery, EntityStringQuery`.

- [ ] **Step 1: Create `LooseEndEntity`**

Create `Sources/PensieveApp/AppIntents/LooseEndEntity.swift`:

```swift
import AppIntents
import CoreSpotlight
import UniformTypeIdentifiers
import PensieveKit

/// One open loose end as an App Intents entity — searchable in Spotlight (IndexedEntity) and
/// openable. Thin: all content comes from the tested `LooseEndFacts` kernel. The cited `quote` is
/// folded into the searchable body so a quote phrase is findable (the whole point of 1b).
struct LooseEndEntity: AppEntity, IndexedEntity {
  let id: UUID           // the loose-end UUID
  let text: String
  let nodeName: String
  let quote: String

  static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Loose End")
  static let defaultQuery = LooseEndEntityQuery()

  var displayRepresentation: DisplayRepresentation {
    DisplayRepresentation(title: "\(text)", subtitle: "\(nodeName)")
  }

  /// IndexedEntity body: title = the loose-end text; searchable content = text + the cited quote.
  var attributeSet: CSSearchableItemAttributeSet {
    let attrs = CSSearchableItemAttributeSet(contentType: .content)
    attrs.title = text
    attrs.displayName = text
    attrs.contentDescription = quote.isEmpty ? text : "\(text)\n\(quote)"
    return attrs
  }

  init(facts: LooseEndFacts) {
    self.id = facts.looseEndID
    self.text = facts.text
    self.nodeName = facts.nodeName
    self.quote = facts.quote
  }
}
```

- [ ] **Step 2: Create `LooseEndEntityQuery`**

Create `Sources/PensieveApp/AppIntents/LooseEndEntityQuery.swift`:

```swift
import AppIntents
import SQLiteData
import PensieveKit

/// Resolves LooseEndEntities for Spotlight/Shortcuts/Siri. Opens the canonical store READ-ONLY and
/// degrades to empty if it's missing — an intent surface must never create/migrate the store.
struct LooseEndEntityQuery: EntityQuery, EntityStringQuery {
  /// A tap / by-id resolution — any status/state, so a since-closed end still opens its node.
  func entities(for identifiers: [UUID]) async throws -> [LooseEndEntity] {
    read { try LooseEndFactsQueries.facts(for: identifiers, $0) }.map(LooseEndEntity.init(facts:))
  }

  /// The Shortcuts parameter picker — open loose ends in active nodes.
  func suggestedEntities() async throws -> [LooseEndEntity] {
    read { try LooseEndFactsQueries.all($0) }.map(LooseEndEntity.init(facts:))
  }

  /// Text/quote search (case-insensitive). Loose ends are few/single-user, so filter in Swift.
  func entities(matching string: String) async throws -> [LooseEndEntity] {
    read { try LooseEndFactsQueries.all($0) }
      .filter {
        $0.text.localizedCaseInsensitiveContains(string)
          || $0.quote.localizedCaseInsensitiveContains(string)
      }
      .map(LooseEndEntity.init(facts:))
  }

  private func read(_ body: (any DatabaseReader) throws -> [LooseEndFacts]) -> [LooseEndFacts] {
    guard let db = try? openCanonicalDatabaseReadOnly(at: Stores.canonicalURL) else { return [] }
    return (try? body(db)) ?? []
  }
}
```

- [ ] **Step 3: Build the app to verify it compiles**

Run:
```bash
xcodegen generate && xcodebuild -project Pensieve.xcodeproj -scheme Pensieve -configuration Debug -derivedDataPath ./.build-xcode build
```
Expected: BUILD SUCCEEDED. (`OpenLooseEndIntent` is not referenced yet; `LooseEndEntity`/`LooseEndEntityQuery` compile standalone.)

- [ ] **Step 4: Commit**

```bash
git add Sources/PensieveApp/AppIntents/LooseEndEntity.swift Sources/PensieveApp/AppIntents/LooseEndEntityQuery.swift
git commit -F- <<'EOF'
feat(app): LooseEndEntity + LooseEndEntityQuery for Spotlight (Track C 1b)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01ByuhXmgmAcdshVcYc8Bf1V
EOF
```

---

### Task 4: App — `OpenLooseEndIntent` + register as an App Shortcut

**Files:**
- Modify: `Sources/PensieveApp/AppIntents/PensieveIntents.swift`
- Modify: `Sources/PensieveApp/AppIntents/PensieveShortcuts.swift`

**Interfaces:**
- Consumes: `LooseEndEntity` (Task 3); `PensieveIntentBridge.route(_:)`; `DeepLink.looseEnd` (Task 1).
- Produces: `struct OpenLooseEndIntent: OpenIntent` (`@Parameter target: LooseEndEntity`) registered in `PensieveShortcuts`. Registration is load-bearing: an `IndexedEntity` is only Spotlight-surfaced when referenced as an App Shortcut.

- [ ] **Step 1: Add `OpenLooseEndIntent`**

In `Sources/PensieveApp/AppIntents/PensieveIntents.swift`, add after `OpenNodeIntent`:

```swift
/// Open a specific loose end — its node's recall view with the cited row expanded. `OpenIntent`
/// implies opening the app. The system resolves `target` via LooseEndEntityQuery BEFORE perform().
struct OpenLooseEndIntent: OpenIntent {
  static let title: LocalizedStringResource = "Open Loose End"
  @Parameter(title: "Loose End") var target: LooseEndEntity

  @MainActor func perform() async throws -> some IntentResult {
    PensieveIntentBridge.route(.looseEnd(target.id))
    return .result()
  }
}
```

- [ ] **Step 2: Register it in `PensieveShortcuts`**

In `Sources/PensieveApp/AppIntents/PensieveShortcuts.swift`, add a third `AppShortcut` after the `OpenNodeIntent` one:

```swift
    AppShortcut(
      intent: OpenLooseEndIntent(),
      phrases: ["Open a loose end in \(.applicationName)"],
      shortTitle: "Open Loose End",
      systemImageName: "text.badge.checkmark")
```

- [ ] **Step 3: Build the app to verify it compiles**

Run:
```bash
xcodebuild -project Pensieve.xcodeproj -scheme Pensieve -configuration Debug -derivedDataPath ./.build-xcode build
```
Expected: BUILD SUCCEEDED.

- [ ] **Step 4: Commit**

```bash
git add Sources/PensieveApp/AppIntents/PensieveIntents.swift Sources/PensieveApp/AppIntents/PensieveShortcuts.swift
git commit -F- <<'EOF'
feat(app): OpenLooseEndIntent App Shortcut (surfaces loose ends in Spotlight)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01ByuhXmgmAcdshVcYc8Bf1V
EOF
```

---

### Task 5: App — `SpotlightIndexer` indexes loose ends alongside nodes

**Files:**
- Modify: `Sources/PensieveApp/AppIntents/SpotlightIndexer.swift`

**Interfaces:**
- Consumes: `LooseEndFactsQueries.all` (Task 2), `LooseEndEntity.init(facts:)` (Task 3), the `visible` set already computed for nodes, `NodeContextResolver.visibleNodeIDs`.
- Produces: a single clear-then-index pass that now indexes both node entities and loose-end entities.

- [ ] **Step 1: Add the loose-end entity set to `reindex`**

Replace the body of `SpotlightIndexer.reindex` in `Sources/PensieveApp/AppIntents/SpotlightIndexer.swift` with:

```swift
  static func reindex(activeContext: String = "") async {
    guard let db = try? openCanonicalDatabaseReadOnly(at: Stores.canonicalURL) else { return }
    let facts = (try? NodeFactsQueries.all(db, now: Date())) ?? []
    let allNodes = (try? ProjectQueries.all(db)) ?? []
    let visible = NodeContextResolver.visibleNodeIDs(for: activeContext, in: allNodes)
    let nodeEntities = facts.filter { visible.contains($0.node.id) }.map(NodeEntity.init(facts:))
    let looseEndEntities = ((try? LooseEndFactsQueries.all(db)) ?? [])
      .filter { visible.contains($0.nodeID) }
      .map(LooseEndEntity.init(facts:))
    let index = CSSearchableIndex.default()
    do {
      // Pensieve indexes only nodes + open loose ends → this clears exactly our set.
      try await index.deleteAllSearchableItems()
      try await index.indexAppEntities(nodeEntities)
      try await index.indexAppEntities(looseEndEntities)
    } catch {
      // A glance surface must never break the app; a failed index is silently dropped.
    }
  }
```

- [ ] **Step 2: Build the app to verify it compiles**

Run:
```bash
xcodebuild -project Pensieve.xcodeproj -scheme Pensieve -configuration Debug -derivedDataPath ./.build-xcode build
```
Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Commit**

```bash
git add Sources/PensieveApp/AppIntents/SpotlightIndexer.swift
git commit -F- <<'EOF'
feat(app): index open loose ends into Spotlight (Track C 1b)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01ByuhXmgmAcdshVcYc8Bf1V
EOF
```

---

### Task 6: App — navigation: `AppModel.openLooseEnd` + `applyDeepLink` routing

**Files:**
- Modify: `Sources/PensieveApp/AppModel.swift`
- Modify: `Sources/PensieveApp/DeepLinkNavigation.swift`

**Interfaces:**
- Consumes: `DeepLink.looseEnd` (Task 1); `LooseEndFactsQueries.facts(for:)` (Task 2); `openCanonicalDatabaseReadOnly(at:)`, `Stores.canonicalURL`; existing `sidebarSelection`/`selectedNodeID`/`expandedLooseEndID` state.
- Produces: `AppModel.openLooseEnd(_ id: UUID)`; `applyDeepLink` routes `.looseEnd` through it; `PaletteDestination(_:)` becomes failable (returns nil for `.looseEnd`) while staying exhaustive over `DeepLink`.

- [ ] **Step 1: Add `openLooseEnd` to `AppModel`**

In `Sources/PensieveApp/AppModel.swift`, add near `selectSearchLooseEnd` (around line 527):

```swift
  /// A Spotlight/App-Intent loose-end open: resolve the loose end → its node (read-only lookup),
  /// select the node, and mark the row to auto-expand. Degrades honestly: a deleted loose end (no
  /// resolution) falls back to the briefing. A since-closed end still resolves → opens its node
  /// (the closed row simply won't render). Window fronting is done by `applyDeepLink`.
  func openLooseEnd(_ id: UUID) {
    guard let db = try? openCanonicalDatabaseReadOnly(at: Stores.canonicalURL),
          let facts = try? LooseEndFactsQueries.facts(for: [id], db),
          let f = facts.first else {
      sidebarSelection = .briefing
      selectedNodeID = nil
      expandedLooseEndID = nil
      return
    }
    sidebarSelection = .node(f.nodeID)
    selectedNodeID = f.nodeID
    expandedLooseEndID = f.looseEndID
  }
```

- [ ] **Step 2: Make `PaletteDestination(_:)` failable and route `.looseEnd` in `applyDeepLink`**

In `Sources/PensieveApp/DeepLinkNavigation.swift`, change the `PaletteDestination` init to a failable init that returns nil for `.looseEnd` (keeping the switch exhaustive over `DeepLink` — the no-drift guard):

```swift
extension PaletteDestination {
  /// Maps a cross-surface DeepLink to the app's nav-only destination. Exhaustive over DeepLink so a
  /// future case fails to compile here (no silent drift). `.looseEnd` has no nav-only destination —
  /// it is routed via `AppModel.openLooseEnd` in `applyDeepLink`, so this returns nil for it.
  init?(_ link: DeepLink) {
    switch link {
    case .briefing:
      self = .briefing
    case .node(let id):
      self = .node(id)
    case .smartList(let s):
      switch s {
      case .whatsNext: self = .smartList(.whatsNext)
      case .dormant: self = .smartList(.dormant)
      case .recentlyActive: self = .smartList(.recentlyActive)
      }
    case .looseEnd:
      return nil
    }
  }
}
```

Then update `applyDeepLink` in the same file to front the window first and branch on `.looseEnd`:

```swift
@MainActor
func applyDeepLink(_ link: DeepLink, model: AppModel, openWindow: OpenWindowAction) {
  openWindow(id: "main")
  NSApplication.shared.activate()   // macOS 14 cooperative form (not ignoringOtherApps:)
  if case .looseEnd(let id) = link {
    model.openLooseEnd(id)
  } else if let dest = PaletteDestination(link) {
    dest.apply(to: model)
  }
}
```

- [ ] **Step 3: Build the app to verify it compiles**

Run:
```bash
xcodebuild -project Pensieve.xcodeproj -scheme Pensieve -configuration Debug -derivedDataPath ./.build-xcode build
```
Expected: BUILD SUCCEEDED. (A compile error here would mean another `switch` over `DeepLink` needs the `.looseEnd` case — the intended no-drift guard.)

- [ ] **Step 4: Smoke-launch the app**

Run:
```bash
BIN=./.build-xcode/Build/Products/Debug/Pensieve.app/Contents/MacOS/Pensieve
PENSIEVE_DB=$(mktemp -u /tmp/pensieve-smoke-XXXX.sqlite) \
PENSIEVE_CAPTURE_DB=$(mktemp -u /tmp/pensieve-smoke-cap-XXXX.sqlite) \
"$BIN" & PID=$!; sleep 4; kill $PID 2>/dev/null; wait $PID 2>/dev/null; echo "smoke ok"
```
Expected: launches without crashing, prints `smoke ok` after the kill.

- [ ] **Step 5: Commit**

```bash
git add Sources/PensieveApp/AppModel.swift Sources/PensieveApp/DeepLinkNavigation.swift
git commit -F- <<'EOF'
feat(app): route pensieve://looseend to node + expanded row (Track C 1b)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01ByuhXmgmAcdshVcYc8Bf1V
EOF
```

---

### Task 7: Full verification

**Files:** none (verification only).

- [ ] **Step 1: Run the full Kit test suite**

Run: `./scripts/test.sh`
Expected: PASS, no failures. New tests (3 DeepLink + 3 LooseEndFacts) included; the `registry ↔ config` EvalTask guard still passes (no new LLM task was added).

- [ ] **Step 2: Clean app build**

Run:
```bash
xcodegen generate && xcodebuild -project Pensieve.xcodeproj -scheme Pensieve -configuration Debug -derivedDataPath ./.build-xcode build
```
Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Record human-verify carries**

These need the built app installed at `/Applications`, a real store, and a plain `open` (not headless-assertable). Note them for the user to run:
- Spotlight-search a phrase from an open loose end's **text** → the loose end appears → selecting it opens Pensieve at its node with the cited row expanded.
- A phrase present only in the cited **quote** also finds the loose end.
- A Work/Personal Focus hides the muted context's loose ends from Spotlight.
- A since-closed loose end's stale Spotlight entry degrades (opens the node, or briefing if deleted) — no crash.
- German entity type name in situ (`-AppleLanguages '(de)'`) — expected to fall back to English "Loose End" (App-Intents strings intentionally not localized, matching `NodeEntity`).

- [ ] **Step 4: No commit** (verification only — nothing changed).

---

## Self-Review Notes

- **Spec coverage:** DeepLink case (Task 1); `LooseEndFacts`/`LooseEndFactsQueries` `all`+`facts(for:)` (Task 2); `LooseEndEntity`+`LooseEndEntityQuery` (Task 3); `OpenLooseEndIntent`+registration (Task 4); `SpotlightIndexer` second entity set with Focus filter (Task 5); `AppModel.openLooseEnd`+`applyDeepLink` routing with preserved no-drift guard (Task 6). Testing section covered by Tasks 1, 2, 7.
- **Open items resolved:** (1) `applyDeepLink`/`PaletteDestination` restructure = failable `init?(_:)` returning nil for `.looseEnd`, routed via `openLooseEnd` (Task 6, keeps the exhaustive-switch guard). (2) `attributeSet.contentType` = `.content`, matching `NodeEntity` (Task 3). (3) German: App-Intents strings stay English literals like `OpenNodeIntent`/`NodeEntity` — no `Localizable.xcstrings` changes (Global Constraints).
- **Type consistency:** `LooseEndFacts.looseEndID` used consistently; `LooseEndFactsQueries.all(_:)`/`facts(for:_:)` signatures match across Tasks 2, 3, 6; `DeepLink.looseEnd(UUID)` spelling consistent across Tasks 1, 4, 6.
