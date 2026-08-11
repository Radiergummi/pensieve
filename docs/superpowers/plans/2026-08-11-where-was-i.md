# "Where Was I" Implementation Plan (slice A)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the app answer "where does this project stand?" in the first glance — by carrying a real `Date` out of the Kit, promoting grounded facts above best-effort prose, and repairing five String Catalog keys that have been silently falling back to English.

**Architecture:** Three additive Kit changes (a `lastActivityAt: Date?` on `NodeFacts`, a `lastActivityAt: Date` on `BriefingCard`, and one batched two-aggregate query for list rows) feed a single new app file, `NodeMeta.swift`, that owns every rendering of a node's facts as text. Four view files then consume it. `daysDormant` is retained everywhere it exists — it is a ranking input, not a display value.

**Tech Stack:** Swift 6, SwiftUI (macOS 15 target), Swift Testing (`swift test`), SQLiteData 1.6.6 / GRDB, XcodeGen + Xcode 26.6.

**Spec:** `docs/superpowers/specs/2026-08-11-where-was-i-design.md` — read it first. It records why `daysDormant` survives, why the header is a line and not a grid, and the `%@` vs `%lld` table that explains the localization defect.

## Global Constraints

- **Names are explicit — no abbreviations, no single letters.** Write `database`/`node`/`looseEnd`/`event`, not `db`/`n`/`le`/`ev`. SwiftLint `identifier_name` is enforced in CI (`swiftlint lint --strict`); do not relax it.
- **SQLiteData 1.6.6 predicates use `.eq(x)` / `.neq(x)`, NOT `==` / `!=`.** `==` is `unavailable` and will not compile.
- **Do not touch `groundedScore`, `NextQueries.ranked`, or the `SmartLists` thresholds.** They read `daysDormant`. Any change there is a ranking change and is out of scope. Their existing tests passing unchanged is this plan's proof that ranking was preserved.
- **Kit tests only.** `Sources/PensieveApp/` has no unit tests. App tasks verify by build + smoke-launch + eyeball.
- **Run Kit tests with `./scripts/test.sh`** (optionally `--filter <name>`).
- **App build:** `xcodegen generate` then `xcodebuild -project Pensieve.xcodeproj -scheme Pensieve -configuration Debug -derivedDataPath ./.build-xcode build`.
- **Smoke-launch the INNER BINARY, never the bundle:** `./.build-xcode/Build/Products/Debug/Pensieve.app/Contents/MacOS/Pensieve`, backgrounded then killed, with throwaway `PENSIEVE_DB`/`PENSIEVE_CAPTURE_DB`. A bundle launch touches the real store and real Login Items.
- **Discard transient `Package.resolved` churn after an `xcodebuild`.** MarkdownUI is an xcodebuild-only dependency; `swift test` must stay unaffected.
- **Catalog keys are authored by hand and MUST match the Swift literal's specifiers.** An interpolated `Int` produces `%lld`; a `String` or a `\(value, format:)` produces `%@`. A mismatched key falls back to English **silently** — that is the entire defect this plan repairs. `xcodebuild` does not extract keys (IDE-only).
- **Chrome is localized; content never is.** Node names, descriptions, loose-end text, quotes, `branchKey`, event summaries and roles stay verbatim.
- **Read-only slice.** No writes, no schema change, no migration. If you find yourself adding a write, stop and re-read the spec.
- **The trust gate is untouched.** Do not modify `TranscriptVocabulary`, `TranscriptParser.isInjectedOrCommand`, or the narration `nil` contract.
- **Commit after every task**, conventional-commit prefixes as used in this repo (`feat(kit)`, `fix(app)`, `docs`).

## File Structure

**Create (App):**
- `Sources/PensieveApp/NodeMeta.swift` — the single place a node's facts become text: `NodeMeta` (recency + count helpers), `NodeMetaLine` (detail header), `NodeRowMeta` (list row second line).

**Modify (Kit):**
- `Sources/PensieveKit/Model/LooseEnd.swift` — add `openSQLPredicate` beside `isOpen`.
- `Sources/PensieveKit/Query/NodeFacts.swift` — `NodeFacts.lastActivityAt`; new `NodeRowFacts` + `NodeFactsQueries.rowFacts`.
- `Sources/PensieveKit/Query/BriefingQueries.swift` — `BriefingCard.lastActivityAt`.

**Modify (App):**
- `Sources/PensieveApp/AppModel.swift` — `nodeRowFacts` property, populated in `refresh()`.
- `Sources/PensieveApp/DetailView.swift` — header state line, section reorder, recap demotion.
- `Sources/PensieveApp/ContentListView.swift` — node row second line.
- `Sources/PensieveApp/BriefingView.swift` — weighting, honest dates.
- `Sources/PensieveApp/LooseEndRow.swift` — thumbs on hover + context menu, footer date.
- `Sources/PensieveApp/Localizable.xcstrings` — key repairs and additions.

**Modify (Tests):**
- `Tests/PensieveKitTests/NodeFactsTests.swift`
- `Tests/PensieveKitTests/BriefingQueriesTests.swift`

---

### Task 1: `NodeFacts` carries the timestamp

**Files:**
- Modify: `Sources/PensieveKit/Query/NodeFacts.swift`
- Test: `Tests/PensieveKitTests/NodeFactsTests.swift`

**Interfaces:**
- Produces: `NodeFacts.lastActivityAt: Date?` — the latest `Event.occurredAt` for the node, `nil` when the node has no events. `NodeFacts.init(node:openLooseEnds:daysDormant:lastActivityAt:)`.

- [ ] **Step 1: Write the failing tests**

Append to `Tests/PensieveKitTests/NodeFactsTests.swift`:

```swift
@Test func nodeFactsCarriesTheLatestEventTimestamp() throws {
  let database = try openCanonicalDatabase(at: tempURL("nodefacts-timestamp"))
  let resolver = ProjectResolver(database: database)
  let (testNode, testNodeSource) = try resolver.resolve(path: "/p/stamp", kind: SourceKind.claudeCode)
  let older = Calendar.current.date(byAdding: .day, value: -10, to: Date())!
  let newest = Calendar.current.date(byAdding: .day, value: -2, to: Date())!
  try database.write { database in
    try Event.insert {
      Event(nodeID: testNode.id, sourceID: testNodeSource.id, occurredAt: older,
            kind: CaptureKind.ccSession, summary: "old", detailJSON: "{}", fingerprint: "ts1")
    }.execute(database)
    try Event.insert {
      Event(nodeID: testNode.id, sourceID: testNodeSource.id, occurredAt: newest,
            kind: CaptureKind.gitCommit, summary: "new", detailJSON: "{}", fingerprint: "ts2")
    }.execute(database)
  }
  let facts = try NodeFactsQueries.all(database, now: Date())
  let testNodeFacts = try #require(facts.first { $0.node.id == testNode.id })
  let lastActivityAt = try #require(testNodeFacts.lastActivityAt)
  #expect(abs(lastActivityAt.timeIntervalSince(newest)) < 0.001)
  #expect(testNodeFacts.daysDormant == 2)   // unchanged: still derived from the same event
}

@Test func nodeFactsHasNoTimestampWithoutEvents() throws {
  let database = try openCanonicalDatabase(at: tempURL("nodefacts-no-events"))
  let emptyID = UUID()
  try database.write { database in
    try Node.insert { Node(id: emptyID, name: "Empty") }.execute(database)
  }
  let facts = try NodeFactsQueries.facts(for: [emptyID], database, now: Date())
  let emptyFacts = try #require(facts.first)
  #expect(emptyFacts.lastActivityAt == nil)   // honest absence, NOT a fake zero
  #expect(emptyFacts.daysDormant == 0)        // the old integer still reports 0 for ranking
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `./scripts/test.sh --filter nodeFacts`
Expected: FAIL — `value of type 'NodeFacts' has no member 'lastActivityAt'`.

- [ ] **Step 3: Add the property**

In `Sources/PensieveKit/Query/NodeFacts.swift`, replace the struct and the private helper's return:

```swift
public struct NodeFacts: Sendable {
  public let node: Node
  public let openLooseEnds: Int
  public let daysDormant: Int   // days since latest Event; 0 if the node has no events
  /// The latest `Event.occurredAt`, or nil when the node has no captured events.
  ///
  /// Carried ALONGSIDE `daysDormant`, never instead of it: `daysDormant` is an input to
  /// `groundedScore` and to the `SmartLists` thresholds, so replacing it would silently re-rank
  /// What's Next. Views read this `Date` (it formats itself, in locale); ranking reads the `Int`.
  /// Both derive from the same event and cannot disagree.
  public let lastActivityAt: Date?

  public init(node: Node, openLooseEnds: Int, daysDormant: Int, lastActivityAt: Date?) {
    self.node = node; self.openLooseEnds = openLooseEnds; self.daysDormant = daysDormant
    self.lastActivityAt = lastActivityAt
  }
}
```

and in `private static func facts(for:_:now:)` change the final line to:

```swift
    return NodeFacts(node: node, openLooseEnds: open, daysDormant: dormant,
                     lastActivityAt: latest?.occurredAt)
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `./scripts/test.sh --filter nodeFacts`
Expected: PASS, all four `nodeFacts…` tests.

- [ ] **Step 5: Run the full suite — nothing else may move**

Run: `./scripts/test.sh`
Expected: PASS. In particular `NextQueriesTests`, `SmartListsTests` and `SessionContextQueriesTests` must be **unchanged and green** — that is the evidence that keeping `daysDormant` preserved ranking.

- [ ] **Step 6: Commit**

```bash
git add Sources/PensieveKit/Query/NodeFacts.swift Tests/PensieveKitTests/NodeFactsTests.swift
git commit -m "feat(kit): NodeFacts carries lastActivityAt beside daysDormant"
```

---

### Task 2: `BriefingCard` carries the timestamp

**Files:**
- Modify: `Sources/PensieveKit/Query/BriefingQueries.swift`
- Test: `Tests/PensieveKitTests/BriefingQueriesTests.swift`

**Interfaces:**
- Produces: `BriefingCard.lastActivityAt: Date` — **non-optional**, because `BriefingQueries.cards` skips nodes with no events (`guard let latest = events.first else { continue }`), so a card cannot exist without one. `BriefingCard.init(node:movedSince:latestSummary:openLooseEnds:topLooseEnd:daysDormant:lastActivityAt:)`.

- [ ] **Step 1: Write the failing test**

Append to `Tests/PensieveKitTests/BriefingQueriesTests.swift`:

```swift
@Test func briefingCardCarriesTheLatestEventTimestamp() throws {
  let database = try openCanonicalDatabase(at: tempURL("briefing-timestamp"))
  let resolver = ProjectResolver(database: database)
  let (testNode, testNodeSource) = try resolver.resolve(path: "/p/brief-stamp", kind: SourceKind.claudeCode)
  let older = Calendar.current.date(byAdding: .day, value: -6, to: Date())!
  let newest = Calendar.current.date(byAdding: .day, value: -1, to: Date())!
  try database.write { database in
    try Event.insert {
      Event(nodeID: testNode.id, sourceID: testNodeSource.id, occurredAt: older,
            kind: CaptureKind.ccSession, summary: "old", detailJSON: "{}", fingerprint: "bt1")
    }.execute(database)
    try Event.insert {
      Event(nodeID: testNode.id, sourceID: testNodeSource.id, occurredAt: newest,
            kind: CaptureKind.gitCommit, summary: "new", detailJSON: "{}", fingerprint: "bt2")
    }.execute(database)
  }
  let since = Calendar.current.date(byAdding: .day, value: -3, to: Date())!
  let cards = try BriefingQueries.cards(database, since: since, now: Date())
  let card = try #require(cards.first { $0.node.id == testNode.id })
  #expect(abs(card.lastActivityAt.timeIntervalSince(newest)) < 0.001)
  #expect(card.movedSince == 1)      // only the newest event is after `since`
  #expect(card.daysDormant == 1)     // unchanged
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `./scripts/test.sh --filter briefingCard`
Expected: FAIL — `value of type 'BriefingCard' has no member 'lastActivityAt'`.

- [ ] **Step 3: Add the property and thread it through**

In `Sources/PensieveKit/Query/BriefingQueries.swift`, add to `BriefingCard` after `daysDormant`:

```swift
  public let daysDormant: Int
  /// The latest event's `occurredAt`. NON-optional: `cards` skips nodes with no events, so a card
  /// always has one. Carried alongside `daysDormant`, never instead of it — see `NodeFacts`.
  public let lastActivityAt: Date
```

update the initializer:

```swift
  public init(node: Node, movedSince: Int, latestSummary: String,
              openLooseEnds: Int, topLooseEnd: String?, daysDormant: Int, lastActivityAt: Date) {
    self.node = node; self.movedSince = movedSince; self.latestSummary = latestSummary
    self.openLooseEnds = openLooseEnds; self.topLooseEnd = topLooseEnd; self.daysDormant = daysDormant
    self.lastActivityAt = lastActivityAt
  }
```

add the field to the private carrier:

```swift
private struct NodeActivity {
  let node: Node
  let movedSince: Int
  let latestSummary: String
  let daysDormant: Int
  let lastActivityAt: Date
}
```

populate it where `NodeActivity` is built (the `latest` binding is already in scope):

```swift
        result.append(NodeActivity(node: node, movedSince: moved, latestSummary: latest.summary,
                                   daysDormant: dormant, lastActivityAt: latest.occurredAt))
```

and pass it at the `BriefingCard` construction:

```swift
      cards.append(BriefingCard(
        node: nodeActivity.node, movedSince: nodeActivity.movedSince,
        latestSummary: nodeActivity.latestSummary,
        openLooseEnds: ends.count, topLooseEnd: ends.first?.looseEnd.text,
        daysDormant: nodeActivity.daysDormant, lastActivityAt: nodeActivity.lastActivityAt))
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `./scripts/test.sh --filter briefing`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/PensieveKit/Query/BriefingQueries.swift Tests/PensieveKitTests/BriefingQueriesTests.swift
git commit -m "feat(kit): BriefingCard carries lastActivityAt"
```

---

### Task 3: One batched facts query for list rows

The middle column needs recency and open-count for every visible node. Both existing paths are N+1 — `NodeFactsQueries.facts(for:)` issues two queries per node, and `BriefingQueries.cards` fetches every event row per node merely to count. At 178 projects that is ~356 round trips on the hottest interaction in the app.

The typed builder has no grouped-aggregate usage anywhere in this codebase, so this uses raw SQL — the established pattern in `SearchIndexStore` and `NarrationCache`. That means the "open loose end" rule gets written a second time, in a second language, so it is declared **next to** the typed one and pinned by an agreement test.

**Files:**
- Modify: `Sources/PensieveKit/Model/LooseEnd.swift`
- Modify: `Sources/PensieveKit/Query/NodeFacts.swift`
- Test: `Tests/PensieveKitTests/NodeFactsTests.swift`

**Interfaces:**
- Consumes: `NodeFacts.lastActivityAt` from Task 1 (used by the agreement test).
- Produces:
  - `LooseEnd.openSQLPredicate: String` — the raw-SQL twin of `LooseEnd.isOpen`.
  - `NodeRowFacts` — `public let lastActivityAt: Date?`, `public let openLooseEnds: Int`; `Sendable, Equatable`.
  - `NodeFactsQueries.rowFacts(_ database: any DatabaseReader) throws -> [UUID: NodeRowFacts]` — every node that has at least one event or one open loose end. A node with neither is **absent from the dictionary**; callers treat a miss as "no activity, zero open".

- [ ] **Step 1: Write the failing tests**

Append to `Tests/PensieveKitTests/NodeFactsTests.swift`:

```swift
@Test func rowFactsAgreesWithPerNodeFacts() throws {
  let database = try openCanonicalDatabase(at: tempURL("rowfacts-agreement"))
  let resolver = ProjectResolver(database: database)
  let (nodeA, sourceA) = try resolver.resolve(path: "/p/row-a", kind: SourceKind.claudeCode)
  let (nodeB, sourceB) = try resolver.resolve(path: "/p/row-b", kind: SourceKind.gitRepo)
  let older = Calendar.current.date(byAdding: .day, value: -9, to: Date())!
  let newest = Calendar.current.date(byAdding: .day, value: -4, to: Date())!
  try database.write { database in
    let eventA1 = Event(nodeID: nodeA.id, sourceID: sourceA.id, occurredAt: older,
                        kind: CaptureKind.ccSession, summary: "a1", detailJSON: "{}", fingerprint: "rf1")
    let eventA2 = Event(nodeID: nodeA.id, sourceID: sourceA.id, occurredAt: newest,
                        kind: CaptureKind.gitCommit, summary: "a2", detailJSON: "{}", fingerprint: "rf2")
    let eventB = Event(nodeID: nodeB.id, sourceID: sourceB.id, occurredAt: older,
                       kind: CaptureKind.gitCommit, summary: "b1", detailJSON: "{}", fingerprint: "rf3")
    try Event.insert { eventA1 }.execute(database)
    try Event.insert { eventA2 }.execute(database)
    try Event.insert { eventB }.execute(database)
    // nodeA: one open, one resolved, one confirmed-noise → exactly 1 open
    try LooseEnd.insert { LooseEnd(nodeID: nodeA.id, sourceEventID: eventA1.id, text: "open", quote: "q") }.execute(database)
    try LooseEnd.insert { LooseEnd(nodeID: nodeA.id, sourceEventID: eventA1.id, text: "done", quote: "q", status: "resolved") }.execute(database)
    try LooseEnd.insert { LooseEnd(nodeID: nodeA.id, sourceEventID: eventA1.id, text: "noise", quote: "q",
                                   label: LooseEndLabel.noise) }.execute(database)
  }
  let batched = try NodeFactsQueries.rowFacts(database)
  let perNode = try NodeFactsQueries.facts(for: [nodeA.id, nodeB.id], database, now: Date())
  for facts in perNode {
    let row = try #require(batched[facts.node.id], "batched result missing \(facts.node.name)")
    #expect(row.openLooseEnds == facts.openLooseEnds)
    switch (row.lastActivityAt, facts.lastActivityAt) {
    case let (batchedDate?, perNodeDate?):
      // A tolerance, not exact equality: a mismatch between the raw-SQL date decoder and
      // SQLiteData's would show up here as hours, not microseconds.
      #expect(abs(batchedDate.timeIntervalSince(perNodeDate)) < 0.001)
    case (nil, nil): break
    default: Issue.record("one side had a date and the other did not for \(facts.node.name)")
    }
  }
  #expect(batched[nodeA.id]?.openLooseEnds == 1)
  #expect(batched[nodeB.id]?.openLooseEnds == 0)
}

@Test func looseEndOpenPredicatesAgree() throws {
  let database = try openCanonicalDatabase(at: tempURL("open-predicate-agreement"))
  let resolver = ProjectResolver(database: database)
  let (testNode, testNodeSource) = try resolver.resolve(path: "/p/predicate", kind: SourceKind.claudeCode)
  let testEvent = Event(nodeID: testNode.id, sourceID: testNodeSource.id, occurredAt: Date(),
                        kind: CaptureKind.ccSession, summary: "s", detailJSON: "{}", fingerprint: "pa1")
  try database.write { database in
    try Event.insert { testEvent }.execute(database)
    // Every status × label combination the predicate must judge.
    for (status, label, suggestion) in [
      ("open", "", ""), ("open", LooseEndLabel.salient, ""), ("open", LooseEndLabel.noise, ""),
      ("open", "", LooseEndLabel.noise), ("resolved", "", ""),
      ("resolved", LooseEndLabel.salient, ""), ("resolved", LooseEndLabel.noise, ""),
    ] {
      try LooseEnd.insert {
        LooseEnd(nodeID: testNode.id, sourceEventID: testEvent.id, text: "t", quote: "q",
                 status: status, label: label, labelSuggestion: suggestion)
      }.execute(database)
    }
  }
  let typedCount = try database.read { database in
    try LooseEnd.where { LooseEnd.isOpen($0) }.fetchCount(database)
  }
  // The SQL spelling is exercised through the production path rather than re-issued here — no test
  // file in this suite imports GRDB, and going through `rowFacts` tests the code that ships.
  let batched = try NodeFactsQueries.rowFacts(database)
  #expect(typedCount == 3)   // open+unlabeled, open+salient, open+suggestion-only-noise
  #expect(batched[testNode.id]?.openLooseEnds == typedCount)   // the two spellings must never diverge
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `./scripts/test.sh --filter rowFacts`
Expected: FAIL — `type 'NodeFactsQueries' has no member 'rowFacts'`.

- [ ] **Step 3: Add the SQL twin of the open predicate**

In `Sources/PensieveKit/Model/LooseEnd.swift`, inside the existing `extension LooseEnd`, below `isOpen`:

```swift
  /// The raw-SQL spelling of `isOpen`, for the batched aggregates the typed builder can't express.
  /// MUST stay logically identical to `isOpen` above; `looseEndOpenPredicatesAgree` in
  /// `NodeFactsTests` fails the suite if they ever diverge. Interpolated into a SQL literal, so it
  /// contains no user input and needs no binding.
  public static let openSQLPredicate = #"("status" = 'open' AND "label" <> 'noise')"#
```

- [ ] **Step 4: Add the batched query**

In `Sources/PensieveKit/Query/NodeFacts.swift`, change the imports to add GRDB (needed for `Row`):

```swift
import Foundation
import GRDB
import SQLiteData
```

and append at the end of the file:

```swift
/// Recency + open-count for many nodes at once — the list-row shape, without the node itself.
public struct NodeRowFacts: Sendable, Equatable {
  public let lastActivityAt: Date?
  public let openLooseEnds: Int

  public init(lastActivityAt: Date?, openLooseEnds: Int) {
    self.lastActivityAt = lastActivityAt
    self.openLooseEnds = openLooseEnds
  }
}

extension NodeFactsQueries {
  /// Facts for every node at once, as **two grouped aggregates in one read** — deliberately NOT the
  /// per-node loop `facts(for:)` uses, which is two queries per node and would be ~356 round trips
  /// against the real store on every middle-column selection change.
  ///
  /// A node with neither events nor open loose ends is absent from the result; callers treat a miss
  /// as "no activity, zero open".
  public static func rowFacts(_ database: any DatabaseReader) throws -> [UUID: NodeRowFacts] {
    try database.read { database in
      var latest: [UUID: Date] = [:]
      let latestRows = try Row.fetchAll(database, sql: """
        SELECT "nodeID", MAX("occurredAt") AS "lastActivityAt" FROM "events" GROUP BY "nodeID"
        """)
      for row in latestRows {
        guard let identifier: String = row["nodeID"], let nodeID = UUID(uuidString: identifier),
              let occurredAt: Date = row["lastActivityAt"] else { continue }
        latest[nodeID] = occurredAt
      }

      var open: [UUID: Int] = [:]
      let openRows = try Row.fetchAll(database, sql: """
        SELECT "nodeID", COUNT(*) AS "openCount" FROM "looseEnds"
        WHERE \(LooseEnd.openSQLPredicate) GROUP BY "nodeID"
        """)
      for row in openRows {
        guard let identifier: String = row["nodeID"], let nodeID = UUID(uuidString: identifier),
              let count: Int = row["openCount"] else { continue }
        open[nodeID] = count
      }

      var result: [UUID: NodeRowFacts] = [:]
      for nodeID in Set(latest.keys).union(open.keys) {
        result[nodeID] = NodeRowFacts(lastActivityAt: latest[nodeID], openLooseEnds: open[nodeID] ?? 0)
      }
      return result
    }
  }
}
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `./scripts/test.sh --filter "rowFacts|looseEndOpen"`
Expected: PASS.

The `String` decode is safe by construction: the STRICT schema declares `"nodeID" TEXT NOT NULL` on both `events` and `looseEnds` (`CanonicalStore.swift`), so the column cannot hold a blob. The `Date` decode is the one worth watching — `occurredAt` is TEXT in GRDB's `YYYY-MM-DD HH:MM:SS.SSS` form, and `rowFactsAgreesWithPerNodeFacts` is what catches a decoder mismatch: it would surface as an hours-sized difference, not a rounding one.

If a test fails here, fix the decode. Do **not** fall back to the per-node loop — that reinstates the N+1 this task exists to remove.

- [ ] **Step 6: Run the full suite**

Run: `./scripts/test.sh`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add Sources/PensieveKit/Model/LooseEnd.swift Sources/PensieveKit/Query/NodeFacts.swift Tests/PensieveKitTests/NodeFactsTests.swift
git commit -m "feat(kit): batched NodeRowFacts via two grouped aggregates"
```

---

### Task 4: `AppModel.nodeRowFacts` and the `NodeMeta` renderers

**Files:**
- Create: `Sources/PensieveApp/NodeMeta.swift`
- Modify: `Sources/PensieveApp/AppModel.swift`
- Modify: `Sources/PensieveApp/Localizable.xcstrings`

**Interfaces:**
- Consumes: `NodeRowFacts`, `NodeFactsQueries.rowFacts` from Task 3.
- Produces:
  - `AppModel.nodeRowFacts: [UUID: NodeRowFacts]` — refreshed in `refresh()`, read by view bodies.
  - `NodeMeta.recency(_ date: Date?) -> Text`
  - `NodeMeta.recencyDetailed(_ date: Date?) -> Text`
  - `NodeMeta.openCount(_ count: Int) -> Text`
  - `NodeMetaLine(node: Node, facts: NodeRowFacts?)` — the detail header's adaptive line.
  - `NodeRowMeta(facts: NodeRowFacts?)` — a list row's second line.

- [ ] **Step 1: Add the model property**

In `Sources/PensieveApp/AppModel.swift`, beside the other refreshed state (near `var briefingCards: [BriefingCard] = []`):

```swift
  /// Recency + open-count per node, for list rows and the detail header. Refreshed with everything
  /// else in `refresh()` rather than per view, so one batched query serves every surface. Tracked by
  /// `@Observable` on purpose — view bodies read it.
  var nodeRowFacts: [UUID: NodeRowFacts] = [:]
```

and inside `refresh()`, immediately after the `briefingCards` assignment block:

```swift
    if let facts = try? NodeFactsQueries.rowFacts(database) { nodeRowFacts = facts }
```

(`refreshGlance()` is deliberately left alone — the menu-bar popover reads `lists`, not these facts.)

- [ ] **Step 2: Create the renderers**

Create `Sources/PensieveApp/NodeMeta.swift`:

```swift
// Sources/PensieveApp/NodeMeta.swift
import SwiftUI
import PensieveKit

/// How a node's grounded facts render as text. One place, so the detail header, the middle-column row
/// and the Briefing agree on wording — and on what a node with no captured activity looks like.
///
/// Relative dates carry **no String Catalog key at all**: `Text(_, format: .relative(...))` is
/// localized by Foundation. That is the whole point of the Kit carrying a `Date` rather than a day
/// count — see the spec's `%@` vs `%lld` table for what the hand-keyed integer strings did instead.
enum NodeMeta {
  /// "3 weeks ago" / "vor 3 Wochen". A node with no captured events says so, rather than claiming a
  /// zero it does not have.
  static func recency(_ date: Date?) -> Text {
    guard let date else { return Text("no activity captured") }
    return Text(date, format: .relative(presentation: .named))
  }

  /// "3 weeks ago · 21 Jul, 18:04" — for the detail header, which has the width for both. The
  /// absolute stamp is the one the Recent Activity timeline below repeats.
  static func recencyDetailed(_ date: Date?) -> Text {
    guard let date else { return Text("no activity captured") }
    return Text(date, format: .relative(presentation: .named))
      + Text(verbatim: " · ")
      + Text(date, format: .dateTime.day().month().hour().minute())
  }

  /// "14 open" / "14 offen". Interpolates an `Int`, so its catalog key MUST be `"%lld open"` —
  /// `"%@ open"` will not match and will silently fall back to English.
  static func openCount(_ count: Int) -> Text { Text("\(count) open") }
}

/// The detail header's state line, assembled on a **mark-the-exception rule**: a fact renders only
/// when it is not the unmarked default. A project says no kind; an active node says no state; a node
/// without a branch renders no branch slot. This is why it is a line and not a fixed grid — a grid
/// would leave an empty cell on most nodes.
struct NodeMetaLine: View {
  let node: Node
  let facts: NodeRowFacts?

  var body: some View {
    joined(tokens).metaText()
  }

  private var tokens: [Text] {
    var result: [Text] = []
    if node.kind != .project { result.append(Text(AppearanceStyle.kindLabel(node.kind))) }
    if node.state != .active { result.append(Text(AppearanceStyle.stateLabel(node.state))) }
    result.append(NodeMeta.recencyDetailed(facts?.lastActivityAt))
    result.append(NodeMeta.openCount(facts?.openLooseEnds ?? 0))
    // Content, never localized — a branch name is verbatim.
    if let branchKey = node.branchKey, !branchKey.isEmpty {
      result.append(Text(branchKey).monospaced())
    }
    return result
  }

  private func joined(_ parts: [Text]) -> Text {
    guard let first = parts.first else { return Text(verbatim: "") }
    return parts.dropFirst().reduce(first) { $0 + Text(verbatim: " · ") + $1 }
  }
}

/// A list row's second line: recency and volume, the two facts that fit a narrow column. It replaces
/// the node's kind label, which was identical on every row and so discriminated nothing.
struct NodeRowMeta: View {
  let facts: NodeRowFacts?

  var body: some View {
    (NodeMeta.recency(facts?.lastActivityAt)
      + Text(verbatim: " · ")
      + NodeMeta.openCount(facts?.openLooseEnds ?? 0))
      .font(.caption)
      .foregroundStyle(.secondary)
  }
}
```

- [ ] **Step 3: Add the two new catalog keys**

In `Sources/PensieveApp/Localizable.xcstrings`, add these entries in alphabetical position among the existing keys. **Note `%lld`, not `%@`.**

```json
    "%lld open" : {
      "extractionState" : "manual",
      "localizations" : {
        "de" : { "stringUnit" : { "state" : "translated", "value" : "%lld offen" } },
        "en" : { "stringUnit" : { "state" : "translated", "value" : "%lld open" } }
      }
    },
```

```json
    "no activity captured" : {
      "extractionState" : "manual",
      "localizations" : {
        "de" : { "stringUnit" : { "state" : "translated", "value" : "noch nichts erfasst" } },
        "en" : { "stringUnit" : { "state" : "translated", "value" : "no activity captured" } }
      }
    },
```

- [ ] **Step 4: Build**

Run:
```bash
xcodegen generate
xcodebuild -project Pensieve.xcodeproj -scheme Pensieve -configuration Debug -derivedDataPath ./.build-xcode build
```
Expected: BUILD SUCCEEDED. `NodeMeta.swift` is not yet referenced by any view — that is expected; this task lands the foundation.

- [ ] **Step 5: Discard dependency churn and commit**

```bash
git checkout -- Package.resolved 2>/dev/null || true
git add Sources/PensieveApp/NodeMeta.swift Sources/PensieveApp/AppModel.swift Sources/PensieveApp/Localizable.xcstrings
git commit -m "feat(app): NodeMeta renderers + batched nodeRowFacts on AppModel"
```

---

### Task 5: Detail header state line, section order, recap demotion

**Files:**
- Modify: `Sources/PensieveApp/DetailView.swift`
- Modify: `Sources/PensieveApp/Localizable.xcstrings`

**Interfaces:**
- Consumes: `NodeMetaLine` and `AppModel.nodeRowFacts` from Task 4.

- [ ] **Step 1: Replace the header and reorder the sections**

In `Sources/PensieveApp/DetailView.swift`, replace the `VStack(alignment: .leading, spacing: 20) { … }` contents (the "WHAT IT IS" through "RECENT ACTIVITY" block) with:

```swift
      VStack(alignment: .leading, spacing: 20) {
        // WHAT IT IS — name, the adaptive state line, description.
        HStack(alignment: .top, spacing: 12) {
          NodeBadge(node: node, size: 44)
          VStack(alignment: .leading, spacing: 4) {
            Text(node.name).font(.largeTitle).bold()
            NodeMetaLine(node: node, facts: model.nodeRowFacts[node.id])
            descriptionBlock
          }
        }

        // LOOSE ENDS — cited and verbatim, so they come BEFORE the best-effort prose below.
        // Omitted when the middle column already shows them (the one-home rule).
        if showsLooseEnds {
          section("Loose Ends") {
            if looseEnds.isEmpty {
              Text("None open.").foregroundStyle(.secondary)
            } else {
              ForEach(looseEnds, id: \.looseEnd.id) { view in
                LooseEndRow(view: view, loadProvenance: model.provenance,
                            onLabel: model.setLooseEndLabel,
                            expandedLooseEndID: model.expandedLooseEndID, compact: false)
                  .id(view.looseEnd.id)
              }
            }
          }
        }

        // RECAP — deliberately headerless. A caps header announces a slot, so an empty slot reads as
        // a failure; narration is best-effort and returns nil, and its absence must read as nothing.
        // The attribution line is a trust marker separating best-effort prose from cited content and
        // is NOT optional.
        if narrationEnabled, let lastWorkDone, loadedNodeID == node.id {
          VStack(alignment: .leading, spacing: 4) {
            Divider()
            Text(lastWorkDone).prose().padding(.top, 4)
            Label("Generated summary", systemImage: "sparkles")
              .font(.caption2)
              .foregroundStyle(.secondary)
          }
        } else if narrationEnabled, isNarrating, loadedNodeID == node.id {
          ProgressView().controlSize(.small)
        }

        // RECENT ACTIVITY (GitHub-style rail timeline)
        section("Recent Activity") {
          if recentEvents.isEmpty {
            Text("No captured activity.").foregroundStyle(.secondary)
          } else {
            ActivityTimeline(events: recentEvents)
          }
        }
      }
```

Leave the `.toolbar`, `.task(id:)` and `.onChange` modifiers below it **exactly as they are** — the load state machine is unchanged and its ordering is load-bearing (two prior reviews).

- [ ] **Step 2: Build**

Run:
```bash
xcodegen generate
xcodebuild -project Pensieve.xcodeproj -scheme Pensieve -configuration Debug -derivedDataPath ./.build-xcode build
```
Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Smoke-launch the inner binary**

Run:
```bash
PENSIEVE_DB=/tmp/pensieve-smoke.sqlite PENSIEVE_CAPTURE_DB=/tmp/pensieve-smoke-capture.sqlite \
  ./.build-xcode/Build/Products/Debug/Pensieve.app/Contents/MacOS/Pensieve &
sleep 5; kill %1
```
Expected: launches and exits without crashing.

- [ ] **Step 4: Eyeball against the real store**

Open the built app normally (`open ./.build-xcode/Build/Products/Debug/Pensieve.app`) and confirm:
- A **project** shows no kind token and no branch; a **strand** shows both.
- An **archived** node shows `Archived`; an active one shows no state token.
- The recap sits **below** the loose ends, with no caps header, and its `✦ Generated summary` line is present.
- A node whose narration is unavailable shows no gap where the recap was.

- [ ] **Step 5: Commit**

```bash
git checkout -- Package.resolved 2>/dev/null || true
git add Sources/PensieveApp/DetailView.swift
git commit -m "feat(app): detail leads with an adaptive state line, cited before prose"
```

---

### Task 6: Middle-column rows carry recency, not a repeated kind label

**Files:**
- Modify: `Sources/PensieveApp/ContentListView.swift`

**Interfaces:**
- Consumes: `NodeRowMeta` and `AppModel.nodeRowFacts` from Task 4.

- [ ] **Step 1: Replace the row's second line**

In `Sources/PensieveApp/ContentListView.swift`, inside `nodeList(_:)`, replace:

```swift
        VStack(alignment: .leading, spacing: 2) {
          Text(node.name)
          Text(AppearanceStyle.kindLabel(node.kind)).font(.caption).foregroundStyle(.secondary)
        }
```

with:

```swift
        VStack(alignment: .leading, spacing: 2) {
          Text(node.name)
          // Was `kindLabel`, which read "Project / Project / Project" down the whole column and so
          // discriminated nothing. Recency and volume are what tell these rows apart.
          NodeRowMeta(facts: model.nodeRowFacts[node.id])
        }
```

- [ ] **Step 2: Build**

Run:
```bash
xcodegen generate
xcodebuild -project Pensieve.xcodeproj -scheme Pensieve -configuration Debug -derivedDataPath ./.build-xcode build
```
Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Eyeball**

Open the built app and confirm the middle column under Briefing and under each smart list reads as dates and counts, and that scrolling a long list stays smooth (the facts come from one batched dictionary, so no query fires per row).

- [ ] **Step 4: Commit**

```bash
git checkout -- Package.resolved 2>/dev/null || true
git add Sources/PensieveApp/ContentListView.swift
git commit -m "feat(app): middle-column rows show recency and open count"
```

---

### Task 7: Briefing — weight tracks importance, dates are honest

**Files:**
- Modify: `Sources/PensieveApp/BriefingView.swift`
- Modify: `Sources/PensieveApp/Localizable.xcstrings`

**Interfaces:**
- Consumes: `BriefingCard.lastActivityAt` (Task 2), `NodeMeta.recency` (Task 4).

- [ ] **Step 1: Add the persisted disclosure state**

In `Sources/PensieveApp/BriefingView.swift`, add below `var model: AppModel`:

```swift
  @AppStorage("briefing.quiet.expanded") private var quietExpanded = false
```

- [ ] **Step 2: Replace the Quiet section with a disclosure of one-liners**

Replace:

```swift
        if !quiet.isEmpty {
          section("Quiet") { ForEach(quiet) { card(for: $0) } }
        }
```

with:

```swift
        // Quiet projects get one line each, collapsed. Visual mass should track importance, and five
        // dormant projects rendered as full cards outweigh the one that actually moved.
        if !quiet.isEmpty {
          DisclosureGroup(isExpanded: $quietExpanded) {
            VStack(alignment: .leading, spacing: 0) {
              ForEach(quiet) { quietRow(for: $0) }
            }
          } label: {
            Text("Quiet").sectionHeader()
          }
        }
```

- [ ] **Step 3: Add the one-liner row and fix the moved card's count**

Add below `card(for:)`:

```swift
  /// One quiet project: name, and how long ago it was last touched. Deliberately a bare relative
  /// date and not "dormant for N days" — the section header already says these are quiet, and the
  /// bare date is the only phrasing here that needs no plural rule in either language.
  private func quietRow(for briefingCard: BriefingCard) -> some View {
    Button { model.selectedNodeID = briefingCard.node.id } label: {
      HStack(spacing: 8) {
        NodeBadge(node: briefingCard.node, size: 16)
        Text(briefingCard.node.name).font(.system(size: 13))
        Spacer()
        NodeMeta.recency(briefingCard.lastActivityAt)
          .font(.system(size: 12))
          .foregroundStyle(.secondary)
          .monospacedDigit()
      }
      .padding(.vertical, 5)
      .frame(maxWidth: .infinity, alignment: .leading)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }
```

Then in `card(for:)`, replace the whole trailing branch:

```swift
          if briefingCard.movedSince > 0 {
            Text("\(briefingCard.movedSince) since last visit").metaText()
          } else {
            Text("dormant \(briefingCard.daysDormant)d").font(.system(size: 12)).foregroundStyle(.tertiary)
          }
```

with:

```swift
          // `card(for:)` now renders ONLY moved projects, so the dormant branch is gone with its
          // `dormant %lldd` string — which never matched its `dormant %@d` catalog key anyway.
          Text("\(briefingCard.movedSince) new").metaText().monospacedDigit()
```

- [ ] **Step 4: Add the new catalog key**

In `Sources/PensieveApp/Localizable.xcstrings`, add (note `%lld`):

```json
    "%lld new" : {
      "extractionState" : "manual",
      "localizations" : {
        "de" : { "stringUnit" : { "state" : "translated", "value" : "%lld neu" } },
        "en" : { "stringUnit" : { "state" : "translated", "value" : "%lld new" } }
      }
    },
```

- [ ] **Step 5: Build and eyeball**

Run:
```bash
xcodegen generate
xcodebuild -project Pensieve.xcodeproj -scheme Pensieve -configuration Debug -derivedDataPath ./.build-xcode build
open ./.build-xcode/Build/Products/Debug/Pensieve.app
```
Confirm: Moved cards carry the weight; Quiet is collapsed by default, expands to one-liners, and the expansion survives a relaunch; no `dormant 0d` anywhere.

- [ ] **Step 6: Commit**

```bash
git checkout -- Package.resolved 2>/dev/null || true
git add Sources/PensieveApp/BriefingView.swift Sources/PensieveApp/Localizable.xcstrings
git commit -m "feat(app): briefing weights moved work and collapses the quiet ones"
```

---

### Task 8: Loose-end thumbs on hover, and an honest footer date

**Files:**
- Modify: `Sources/PensieveApp/LooseEndRow.swift`
- Modify: `Sources/PensieveApp/Localizable.xcstrings`

- [ ] **Step 1: Add hover state and extract the label write**

In `Sources/PensieveApp/LooseEndRow.swift`, add beside the other `@State` properties:

```swift
  @State private var hovering = false
```

Add this helper next to `thumbs`:

```swift
  /// Both the thumb buttons and the context menu write through here.
  private func setLabel(_ value: String) {
    localLabel = value
    onLabel(view.looseEnd.id, value)
  }

  /// A thumb the user has actually set stays visible unconditionally — a confirmed label is recorded
  /// state, not an affordance, and hiding it would make the app appear to forget a decision. The
  /// machine's *suggestion* earns no such permanence.
  private var showsThumbs: Bool { hovering || !currentLabel.isEmpty }
```

- [ ] **Step 2: Gate the thumbs and add the context menu**

Change the `thumbs` property body to apply the gate:

```swift
  @ViewBuilder private var thumbs: some View {
    HStack(spacing: 10) {
      thumb(systemFilled: "hand.thumbsup.fill", systemOutline: "hand.thumbsup",
            value: LooseEndLabel.salient, help: String(localized: "Mark as a real loose end"))
      thumb(systemFilled: "hand.thumbsdown.fill", systemOutline: "hand.thumbsdown",
            value: LooseEndLabel.noise, help: String(localized: "Mark as not a loose end"))
    }
    .font(.caption)
    // Opacity, not `if` — the row must not reflow when the pointer arrives.
    .opacity(showsThumbs ? 1 : 0)
    .allowsHitTesting(showsThumbs)
    .accessibilityHidden(!showsThumbs)
  }
```

Change `thumb(…)`'s action to route through the helper:

```swift
    Button {
      setLabel(confirmed ? LooseEndLabel.unlabeled : value)
    } label: {
```

Then on the outermost `VStack(alignment: .leading, spacing: 6)` of `body`, add — after the existing `.padding(.vertical, 2)`:

```swift
    .onHover { hovering = $0 }
    // Keyboard- and pointer-free access to the same two verbs the hover-revealed thumbs offer.
    .contextMenu {
      Button("Mark as a real loose end") { setLabel(LooseEndLabel.salient) }
      Button("Mark as not a loose end") { setLabel(LooseEndLabel.noise) }
      if !currentLabel.isEmpty {
        Divider()
        Button("Clear rating") { setLabel(LooseEndLabel.unlabeled) }
      }
    }
```

- [ ] **Step 3: Replace the footer's hand-built "Nd ago"**

Replace:

```swift
          Text("\(roleText) · \(view.occurredAt, format: .dateTime.year().month().day()) · \(view.ageDays)d ago")
            .metaText()
```

with:

```swift
          // Was a hand-built `%lldd ago` whose catalog key said `%@d ago`, so it never matched and
          // rendered English inside a German window. Foundation formats the date instead — no
          // interpolated Int, no key, no way to mis-author it.
          (Text(roleText)
            + Text(verbatim: " · ")
            + Text(view.occurredAt, format: .dateTime.year().month().day())
            + Text(verbatim: " · ")
            + Text(view.occurredAt, format: .relative(presentation: .named)))
            .metaText()
```

- [ ] **Step 4: Add the new catalog key**

In `Sources/PensieveApp/Localizable.xcstrings`:

```json
    "Clear rating" : {
      "extractionState" : "manual",
      "localizations" : {
        "de" : { "stringUnit" : { "state" : "translated", "value" : "Bewertung entfernen" } },
        "en" : { "stringUnit" : { "state" : "translated", "value" : "Clear rating" } }
      }
    },
```

- [ ] **Step 5: Build and eyeball**

Run:
```bash
xcodegen generate
xcodebuild -project Pensieve.xcodeproj -scheme Pensieve -configuration Debug -derivedDataPath ./.build-xcode build
open ./.build-xcode/Build/Products/Debug/Pensieve.app
```
Confirm:
- Thumbs are invisible until the pointer enters a row, and the row does **not** shift when they appear.
- A loose end you rate 👍 keeps its filled thumb visible after the pointer leaves.
- Right-click offers both verbs, plus `Clear rating` only on an already-rated row.
- The expanded provenance footer reads e.g. `user · 3 July 2026 · 1 month ago`.

- [ ] **Step 6: Commit**

```bash
git checkout -- Package.resolved 2>/dev/null || true
git add Sources/PensieveApp/LooseEndRow.swift Sources/PensieveApp/Localizable.xcstrings
git commit -m "fix(app): thumbs reveal on hover, footer date is localized"
```

---

### Task 9: Repair the stale catalog keys and verify both locales

Four keys are now dead (their Swift literals are gone) and two are still live but mis-specified. The two live ones are in the menu-bar popover, whose *redesign* belongs to slice B — but this is a one-character key bug, not a redesign, and leaving two knowingly-broken strings to honour a slice boundary would be pedantry.

**Files:**
- Modify: `Sources/PensieveApp/Localizable.xcstrings`

- [ ] **Step 1: Fix the two live mis-keyed entries**

`MenuBarView.swift:51` renders `Text("\(model.snapshot.looseEndCount) open")` and `MenuBarView.swift:67` renders `Text("\(item.openLooseEnds) open · \(item.daysDormant)d dormant")`. Both interpolate `Int`s, so both produce `%lld`.

- The existing `"%@ open"` entry is superseded by the `"%lld open"` entry added in Task 4. **Delete the `"%@ open"` entry.**
- **Rename** the key `"%@ open · %@d dormant"` to `"%lld open · %lldd dormant"`, and change both its values' specifiers:
  - `en`: `"%1$lld open · %2$lldd dormant"`
  - `de`: `"%1$lld offen · %2$lldT ruhend"`

- [ ] **Step 2: Delete the four dead entries**

Their Swift literals no longer exist anywhere:

- `"dormant %@d"` — removed in Task 7.
- `"%@ since last visit"` — removed in Task 7.
- `"%@ · %@ · %@d ago"` — removed in Task 8.
- `"Last Work Done"` — the section header removed in Task 5. **Keep** `"Show “Last Work Done” narration"`, which is a different, still-live Settings key.

- [ ] **Step 3: Verify no dead key remains and no live literal is unkeyed**

Run:
```bash
grep -nE '"(dormant %@d|%@ since last visit|%@ · %@ · %@d ago|%@ open|%@ open · %@d dormant|Last Work Done)" :' Sources/PensieveApp/Localizable.xcstrings
```
Expected: no output.

Run:
```bash
grep -nE '"(%lld open|%lld new|%lld open · %lldd dormant|no activity captured|Clear rating)" :' Sources/PensieveApp/Localizable.xcstrings
```
Expected: five matches.

- [ ] **Step 4: Build and verify the German bundle**

Run:
```bash
xcodegen generate
xcodebuild -project Pensieve.xcodeproj -scheme Pensieve -configuration Debug -derivedDataPath ./.build-xcode build
plutil -p ./.build-xcode/Build/Products/Debug/Pensieve.app/Contents/Resources/de.lproj/Localizable.strings | grep -E "offen|neu|erfasst|ruhend"
```
Expected: the German values are present in the compiled bundle.

- [ ] **Step 5: Forced-locale launch — the only check that catches a mis-key**

Run:
```bash
open ./.build-xcode/Build/Products/Debug/Pensieve.app --args -AppleLanguages '(de)'
```
Walk every surface this slice touched and confirm **no English fragment survives**:
- Briefing: `%lld neu` on moved cards; the Quiet disclosure's relative dates in German.
- Middle column: `vor 3 Wochen · 14 offen`.
- Detail header: kind, state and count tokens all German.
- An expanded loose end's footer: `vor 1 Monat`.
- **Menu-bar popover**: `868 offen` and `288 offen · 0T ruhend`.

Then relaunch with `--args -AppleLanguages '(en)'` and confirm English is intact.

Five mis-keyed entries shipped undetected before this; if any string still renders English under `(de)`, its key does not match its Swift literal — compare specifier by specifier.

- [ ] **Step 6: Run the full Kit suite one last time**

Run: `./scripts/test.sh`
Expected: PASS. Kit is unchanged since Task 3, so this is a regression guard, not new coverage.

- [ ] **Step 7: Commit**

```bash
git checkout -- Package.resolved 2>/dev/null || true
git add Sources/PensieveApp/Localizable.xcstrings
git commit -m "fix(app): repair six String Catalog keys that never matched their literals"
```

---

## Done when

- `./scripts/test.sh` passes, with `NextQueriesTests` / `SmartListsTests` / `SessionContextQueriesTests` untouched and green.
- The app builds and launches, and under `-AppleLanguages '(de)'` no count or date renders in English.
- No surface renders `0d`, `dormant 0d`, `N since last visit`, or `Nd ago`.
- A node with no captured events says so instead of claiming zero.

## Carries out of this slice

- Slice B (Liquid Glass, the macOS 26 floor, the menu-bar popover **redesign**) and slice C (transcript speaker column) remain in `backlog.md`.
- `ProjectContextRender` still emits `0d dormant` into MCP and the CLI SessionStart hook. Same root cause, agent-facing consumer, own decision.
- Whichever of this branch and `plans/2026-08-11-in-node-find.md` lands second needs a rebase — both modify `DetailView.swift` and `LooseEndRow.swift`.
- `LooseEndView.ageDays` loses its only app-side consumer in Task 8, but stays — three `pensieve` CLI commands (`LooseEnds`, `Digest`, `Status`) still print it. Do not remove it; the CLI's own date rendering is a separate question.
