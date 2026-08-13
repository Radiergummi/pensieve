# Loose-End Resolution Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give a loose end a way to end — `open` / `done` / `dropped` — with a burn-down triage
queue, a Completed list, a per-node record, and correct propagation into counts, ranking and search.

**Architecture:** The `status` column has shipped since Phase 1B and nothing has ever written it. It
becomes a real `RawRepresentable` enum with two new cases; `LooseEnd.isOpen` is **not edited**, so
every existing consumer (detail view, menu-bar count, App-Intents facts, What's-Next ranking, search
corpus, Spotlight) gets correct behaviour for free. New work is: one write verb, three feed queries,
one shared `isActionable` predicate applied at three call sites, one shared searchable allow-list
rendered into both the SQL filter and the canonical re-check, and four thin app surfaces.

**Tech Stack:** Swift 6, SQLiteData (GRDB), FTS5, SwiftUI, Swift Testing.

**Spec:** `docs/superpowers/specs/2026-08-13-loose-end-resolution-design.md`.

## Global Constraints

Every task's requirements implicitly include this section.

- **`LooseEnd.isOpen` changes by exactly one word, and its MEANING not at all.** It currently reads
  `columns.status.eq("open") && columns.label.neq("noise")` (`LooseEnd.swift:32`); the raw literal
  stops typechecking once `status` is an enum, so it becomes `.eq(LooseEndStatus.open)`. Nothing else
  about it may change, `openSQLPredicate` (raw SQL) is genuinely untouched, and **no consumer of
  either needs any edit**. An implementation that changes what `isOpen` *selects* has gone wrong; one
  that retypes its literal has not. (An earlier draft of both documents claimed the file was never
  edited. That was false, and following it produces a tree that does not compile.)
- **The trust gate is untouched.** No task reads, writes or references
  `TranscriptVocabulary.injectionMarkers` or `TranscriptParser.isInjectedOrCommand`. No quote is
  edited or re-pointed.
- **`Ingester.drain()` remains the only writer** of everything on a loose end except `label`
  (`LooseEndCommands.setLabel`) and, after Task 2, `status`/`resolvedAt` (`LooseEndCommands.resolve`).
- **Names are explicit — no abbreviations, no single letters.** Write `database`, `looseEnd`, `node`,
  `event`. Wire-format keys (`node_id`, `item_status`, `include_archived`) stay `snake_case` behind
  explicit `CodingKeys`.
- **SQLiteData predicates use `.eq(x)`, never `== x`.** `==` is `unavailable` and will not compile.
- **SwiftLint runs in CI as `swiftlint lint --strict`**, with a **400-line file cap**. Check the line
  count of any file you grow; `AppModel.swift` has already been split once for this reason
  (`AppModel+Organizing.swift`).
- **Tests:** `./scripts/test.sh` (a thin `swift test` passthrough), optionally `--filter <name>`.
  Baseline at the start of this plan is **625 tests**. Test idiom is Swift Testing:
  `@Test func name() throws`, `#expect(...)`, database via `openCanonicalDatabase(at: tempURL("x"))`.
- **The app target has no unit tests.** Keep derivation in PensieveKit; keep views thin. App
  verification = `xcodegen generate` → `xcodebuild` build → a **non-blocking** smoke launch of the
  inner binary with throwaway `PENSIEVE_DB`/`PENSIEVE_CAPTURE_DB`, then eyeball carries for a human.
- **Never set `PENSIEVE_DB`/`PENSIEVE_CAPTURE_DB` when touching the live store**; always set them for
  smoke tests.
- **`xcodebuild … | tail` reports `tail`'s exit code, not the build's.** Redirect to a log, check `$?`
  unpiped, and grep for `** BUILD SUCCEEDED **`.
- **Localization:** every new app string goes into `Sources/PensieveApp/Localizable.xcstrings` (en +
  de) **by hand** — `xcodebuild` does not populate the catalog, and a mis-keyed `de` value silently
  falls back to English. Loose-end text, quotes and node names are **content** and are never
  localized. German is impersonal/infinitive.
- **Work in an isolated git worktree.** Another agent is concurrently finishing
  `worktree-macos26-floor`; do not touch it, and rebase before merging.

---

## File Structure

**Created:**

| File | Responsibility |
|---|---|
| `Sources/PensieveKit/Model/LooseEndStatus.swift` | The three-case status enum + the searchable allow-list |
| `Tests/PensieveKitTests/LooseEndResolutionTests.swift` | Status enum, migration, `resolve`, feed queries |
| `Tests/PensieveKitTests/LooseEndSearchStatusTests.swift` | Allow-list agreement, corpus membership, hash sensitivity |
| `Sources/PensieveApp/LooseEndStatusMenu.swift` | The shared resolve verbs (context menu + swipe actions) |

**Modified:** `Sources/PensieveKit/Model/LooseEnd.swift`,
`Sources/PensieveKit/Store/CanonicalStore.swift`,
`Sources/PensieveKit/Query/LooseEndCommands.swift`,
`Sources/PensieveKit/Query/LooseEndQueries.swift`,
`Sources/PensieveKit/Query/SalienceReviewQueries.swift`,
`Sources/PensieveKit/Query/NextQueries.swift`,
`Sources/PensieveKit/Query/SmartLists.swift`,
`Sources/PensieveKit/Query/SessionContextQueries.swift`,
`Sources/PensieveKit/Query/SearchHit.swift`,
`Sources/PensieveKit/Query/SearchHitResolver.swift`,
`Sources/PensieveKit/Query/SearchQueries.swift`,
`Sources/PensieveKit/Search/EmbeddableItem.swift`,
`Sources/PensieveKit/Search/SearchIndexer.swift`,
`Sources/PensieveKit/Search/SearchIndexStore.swift`,
`Sources/pensieve/Commands/Next.swift`, `Sources/pensieve/Commands/Mcp.swift`,
`Sources/PensieveApp/AppModel+Types.swift`, `Sources/PensieveApp/AppModel.swift`,
`Sources/PensieveApp/AppModel+Recall.swift`, `Sources/PensieveApp/AppModel+Search.swift`,
`Sources/PensieveApp/SidebarView.swift`, `Sources/PensieveApp/ContentListView.swift`,
`Sources/PensieveApp/DetailView.swift`, `Sources/PensieveApp/LooseEndRow.swift`,
`Sources/PensieveApp/NodeContextMenu.swift`, `Sources/PensieveApp/PensieveCommands.swift`,
`Sources/PensieveApp/Localizable.xcstrings`, plus six test files carrying `"resolved"` literals and
three whose assertions this plan changes (`SmartListsTests`, `SessionContextQueriesTests`,
`SalienceReviewQueriesTests`).

**`RootView.swift` is NOT modified.** The sidebar rows live in `Sources/PensieveApp/SidebarView.swift`
(the Review Suggestions row is at `SidebarView.swift:22-33`); `RootView.swift` holds only the
`NavigationSplitView`, the sheets and the one `.alert`. An earlier draft named the wrong file.

**Command placement:** locate the app's existing `.commands` builder (the Find submenu ships as
`FindCommands`) and add the resolve verbs beside it; the filename above is indicative — use whatever
file already declares the app's command groups.

**Task order is load-bearing in one place:** Task 5 (the allow-list + index schema + SQL filter) must
land **before** Task 6 (widening the corpus). Reversed, the failure mode is a silently shrinking
result page instead of a red test — spec §12 risk 2.

---

### Task 1: `LooseEndStatus`, `resolvedAt`, and migration v12

**Files:**
- Create: `Sources/PensieveKit/Model/LooseEndStatus.swift`
- Create: `Tests/PensieveKitTests/LooseEndResolutionTests.swift`
- Modify: `Sources/PensieveKit/Model/LooseEnd.swift`
- Modify: `Sources/PensieveKit/Store/CanonicalStore.swift` (append after the `v11-looseend-label` migration)
- Modify: `Sources/PensieveKit/Query/SalienceReviewQueries.swift` (two `"open"` literals)
- Modify (test literals only): `Tests/PensieveKitTests/{SearchQueriesTests,ExtractionRunnerTests,SalienceReviewQueriesTests,LooseEndFactsTests,MonitorSnapshotTests,NodeFactsTests}.swift`

**Interfaces:**
- Produces: `LooseEndStatus.open` / `.done` / `.dropped`; `LooseEnd.status: LooseEndStatus`;
  `LooseEnd.resolvedAt: Date?`; `LooseEnd.init(..., status: LooseEndStatus = .open, ..., resolvedAt: Date? = nil, ...)`.
- Consumes: nothing.

- [ ] **Step 1: Verify the precondition against the live store**

The type change is only safe because every stored row holds `"open"`. Run, read-only:

```bash
sqlite3 -readonly ~/Library/Application\ Support/Pensieve/pensieve.sqlite \
  "select status, count(*) from looseEnds group by 1;"
```

Expected: exactly one row, `open|968` (the count may have grown). **If any other value appears, STOP
and report** — the plan assumes no legacy value needs an alias.

- [ ] **Step 2: Write the failing tests**

Create `Tests/PensieveKitTests/LooseEndResolutionTests.swift`:

```swift
import Foundation
import Testing
import SQLiteData
@testable import PensieveKit

/// Seeds one node + source + event + loose end, and returns the loose end's id.
@discardableResult
func seedLooseEnd(_ database: any DatabaseWriter, text: String = "t", quote: String = "q",
                  status: LooseEndStatus = .open, label: String = "",
                  resolvedAt: Date? = nil, daysAgo: Int = 0) throws -> UUID {
  let node = Node(name: "N")
  let source = Source(nodeID: node.id, kind: SourceKind.claudeCode, key: "/src/\(UUID().uuidString)")
  let when = Calendar.current.date(byAdding: .day, value: -daysAgo, to: Date())!
  let event = Event(nodeID: node.id, sourceID: source.id, occurredAt: when,
                    kind: CaptureKind.ccSession, summary: "s", detailJSON: "{}")
  let looseEnd = LooseEnd(nodeID: node.id, sourceEventID: event.id, text: text, quote: quote,
                          status: status, label: label, resolvedAt: resolvedAt)
  try database.write { database in
    try Node.insert { node }.execute(database)
    try Source.insert { source }.execute(database)
    try Event.insert { event }.execute(database)
    try LooseEnd.insert { looseEnd }.execute(database)
  }
  return looseEnd.id
}

@Test func looseEndStatusRoundTripsThroughTheStore() throws {
  let database = try openCanonicalDatabase(at: tempURL("les-roundtrip"))
  let openID = try seedLooseEnd(database, quote: "still open")
  let doneID = try seedLooseEnd(database, quote: "finished", status: .done)
  let droppedID = try seedLooseEnd(database, quote: "abandoned", status: .dropped)
  let stored = try database.read { try LooseEnd.all.fetchAll($0) }
  #expect(stored.first { $0.id == openID }?.status == .open)
  #expect(stored.first { $0.id == doneID }?.status == .done)
  #expect(stored.first { $0.id == droppedID }?.status == .dropped)
}

/// The on-disk spelling must stay exactly what the shipped store holds, so no migration is needed
/// for the type change. Reads the raw column, deliberately bypassing the enum.
@Test func looseEndStatusStoresItsRawStringUnchanged() throws {
  let database = try openCanonicalDatabase(at: tempURL("les-raw"))
  try seedLooseEnd(database, quote: "open one")
  try seedLooseEnd(database, quote: "done one", status: .done)
  let raw = try database.read { database in
    try String.fetchAll(database, sql: #"SELECT "status" FROM "looseEnds" ORDER BY "status""#)
  }
  #expect(raw == ["done", "open"])
}

/// The whole feature rests on this: `isOpen` was not edited, and the new states fall out of it.
@Test func isOpenExcludesDoneAndDroppedWithoutBeingEdited() throws {
  let database = try openCanonicalDatabase(at: tempURL("les-isopen"))
  let openID = try seedLooseEnd(database, quote: "open one")
  try seedLooseEnd(database, quote: "done one", status: .done)
  try seedLooseEnd(database, quote: "dropped one", status: .dropped)
  try seedLooseEnd(database, quote: "noisy one", label: LooseEndLabel.noise)
  let open = try database.read { try LooseEnd.where { LooseEnd.isOpen($0) }.fetchAll($0) }
  #expect(open.map(\.id) == [openID])
}

@Test func resolvedAtDefaultsToNilAndPersists() throws {
  let database = try openCanonicalDatabase(at: tempURL("les-resolvedat"))
  let stamp = Date(timeIntervalSince1970: 1_700_000_000)
  try seedLooseEnd(database, quote: "never resolved")
  try seedLooseEnd(database, quote: "resolved", status: .done, resolvedAt: stamp)
  let stored = try database.read { try LooseEnd.all.fetchAll($0) }
  #expect(stored.filter { $0.resolvedAt == nil }.count == 1)
  #expect(stored.compactMap(\.resolvedAt).first.map { Int($0.timeIntervalSince1970) } == 1_700_000_000)
}
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `./scripts/test.sh --filter LooseEndResolution`
Expected: FAIL — `LooseEndStatus` is undefined and `LooseEnd.init` has no `resolvedAt:`.

- [ ] **Step 4: Create the status enum**

Create `Sources/PensieveKit/Model/LooseEndStatus.swift`:

```swift
import Foundation
import SQLiteData

/// A loose end's lifecycle. A real enum rather than raw strings, like `NodeKind` / `NodeState` —
/// this codebase converted those precisely to kill the mistyped-literal hazard, and `status` is
/// compared at more call sites than either.
///
/// The raw values are the strings already on disk, so this type change needs **no migration**:
/// every stored row holds `"open"`, and `done` / `dropped` are new spellings that no historical row
/// can carry. The retired `"resolved"` spelling was never written by production code and is
/// deliberately given no alias.
///
/// `isOpen` is not defined here and is not edited anywhere: `status.eq(.open)` already excludes both
/// new cases, which is what propagates resolution through every existing consumer for free.
public enum LooseEndStatus: String, QueryBindable, Sendable {
  /// Live work. The only state that counts, ranks, or surfaces by default.
  case open
  /// Was a real loose end; it has been handled.
  case done
  /// Was a real loose end; it will not be handled. Distinct from a 👎 label, which asserts the
  /// extractor was wrong and feeds the salience training corpus — this asserts it was right.
  case dropped

  /// Anything that is not `open`. Named rather than spelled `!= .open` at call sites so the
  /// per-node and Completed feeds cannot disagree about what "closed" means.
  public var isClosed: Bool { self != .open }
}
```

- [ ] **Step 5: Change the model**

In `Sources/PensieveKit/Model/LooseEnd.swift`, change the `status` property and add `resolvedAt`:

```swift
  public var status: LooseEndStatus   // open | done | dropped
  public var role: String            // role of the cited message (e.g. "user")
  public var sourceMessageIndex: Int // index of the cited message within the transcript
  public var label: String           // human-confirmed salience: "" unlabeled | "salient" | "noise"
  public var labelSuggestion: String // machine-suggested salience (same values); never enters the corpus
  /// When this was resolved; nil ⇔ never resolved. Ordering only — the Completed feed answers
  /// "what did I finish lately", which the source event's date cannot answer.
  public var resolvedAt: Date?
  public var createdAt: Date
```

and the initializer:

```swift
  public init(id: UUID = UUID(), nodeID: UUID, sourceEventID: UUID, text: String,
              quote: String, status: LooseEndStatus = .open, role: String = "",
              sourceMessageIndex: Int = 0, label: String = "", labelSuggestion: String = "",
              resolvedAt: Date? = nil, createdAt: Date = Date()) {
    self.id = id; self.nodeID = nodeID; self.sourceEventID = sourceEventID
    self.text = text; self.quote = quote; self.status = status
    self.role = role; self.sourceMessageIndex = sourceMessageIndex
    self.label = label; self.labelSuggestion = labelSuggestion
    self.resolvedAt = resolvedAt; self.createdAt = createdAt
  }
```

Then retype `isOpen`'s literal — this is required, not optional, and is the ONLY change permitted to
it:

```swift
  public static func isOpen(_ columns: TableColumns) -> some QueryExpression<Bool> {
    columns.status.eq(LooseEndStatus.open) && columns.label.neq("noise")
  }
```

`openSQLPredicate` (raw SQL, line ~39) is genuinely untouched — the on-disk spelling has not changed,
which is exactly why `looseEndOpenPredicatesAgree` keeps passing. Update the comment on the `status`
property if it still names the old two-value pair.

- [ ] **Step 6: Add migration v12**

In `Sources/PensieveKit/Store/CanonicalStore.swift`, immediately after the `v11-looseend-label`
migration block:

```swift
  migrator.registerMigration("v12-looseend-resolvedat") { database in
    // Nullable on purpose: NULL means "never resolved", the honest reading for every existing row,
    // and there are no closed rows to backfill. v11's three-valued-logic warning does not apply —
    // nothing filters on this column, it is only an ORDER BY key.
    try #sql(#"ALTER TABLE "looseEnds" ADD COLUMN "resolvedAt" TEXT"#).execute(database)
  }
```

- [ ] **Step 7: Remove the `status` filter from Review Suggestions (spec D9 / §7.3)**

`SalienceReviewQueries.pending` and `pendingCount` both filter `$0.status.eq("open")`. Do **not**
merely retype the literal — **drop the status clause entirely** from both:

```swift
        .where { $0.label.eq(LooseEndLabel.unlabeled) && $0.labelSuggestion.neq("") }
```

Add above the type's doc comment:

```swift
/// Deliberately NOT filtered by `status`: a closed loose end is still labellable. Triage is about to
/// become the default surface, and 846 of 968 items are unlabeled — filtering on status would mean
/// every item burned down destroys a training example that was never collected. "Was the extractor
/// right" stays a meaningful question after "is this handled" has been answered.
```

This changes an existing test's expectation: `SalienceReviewQueriesTests.swift:30` seeds a resolved
item precisely to assert it is excluded. Update that test — it should now assert the closed item IS
returned, with a comment naming D9 as the reason. That is a deliberate behaviour change, not a
regression.

- [ ] **Step 8: Fix the test literals**

In the six test files listed under **Files**, replace `status: "resolved"` with `status: .done` and
`"resolved"` string comparisons with `.done`. In `SalienceReviewQueriesTests.swift` the private
`seed` helper's parameter becomes `status: LooseEndStatus = .open`. In `NodeFactsTests.swift` the
tuple table at lines ~161–162 lists `("resolved", …)` triples — change those to `(LooseEndStatus.done, …)`
and adjust the tuple's declared type.

- [ ] **Step 9: Run the full suite**

Run: `./scripts/test.sh`
Expected: PASS, +4 tests over the 625 baseline. Every existing schema suite (`SchemaTests`, `SchemaV3`, `SchemaV4`, `SchemaV7`–`SchemaV11`; there is no V5 or V6) must still pass
unchanged — that is how the byte-identical on-disk claim is verified.

- [ ] **Step 10: Commit**

```bash
git add Sources/PensieveKit Tests/PensieveKitTests
git commit -F - <<'EOF'
feat(kit): a loose end's status becomes a three-case enum

open/done/dropped over the column that has shipped since Phase 1B and
that nothing has ever written. The stored strings are unchanged, so the
type change needs no migration; v12 adds only a nullable resolvedAt,
which the Completed feed orders by.

isOpen is deliberately untouched: status.eq(.open) already excludes both
new cases, which is what carries resolution into the detail view, the
menu-bar count, App-Intents facts, What's-Next ranking, the search
corpus and Spotlight without editing any of them.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_013K3R3eWgpmuS2MqQzXhPgo
EOF
```

---

### Task 2: `LooseEndCommands.resolve`

**Files:**
- Modify: `Sources/PensieveKit/Query/LooseEndCommands.swift`
- Modify: `Tests/PensieveKitTests/LooseEndResolutionTests.swift`

**Interfaces:**
- Consumes: `LooseEndStatus` (Task 1).
- Produces: `LooseEndCommands.resolve(_ database:, id: UUID, status: LooseEndStatus, now: Date = Date()) throws -> Bool`.

- [ ] **Step 1: Write the failing tests**

Append to `Tests/PensieveKitTests/LooseEndResolutionTests.swift`:

```swift
@Test func resolveStampsResolvedAtAndClearsItOnReopen() throws {
  let database = try openCanonicalDatabase(at: tempURL("les-resolve"))
  let id = try seedLooseEnd(database, quote: "work item")
  let closedAt = Date(timeIntervalSince1970: 1_700_000_000)

  #expect(try LooseEndCommands.resolve(database, id: id, status: .done, now: closedAt))
  var stored = try database.read { try LooseEnd.where { $0.id.eq(id) }.fetchOne($0) }
  #expect(stored?.status == .done)
  #expect(stored?.resolvedAt.map { Int($0.timeIntervalSince1970) } == 1_700_000_000)

  #expect(try LooseEndCommands.resolve(database, id: id, status: .open, now: Date()))
  stored = try database.read { try LooseEnd.where { $0.id.eq(id) }.fetchOne($0) }
  #expect(stored?.status == .open)
  #expect(stored?.resolvedAt == nil)   // a reopened end is indistinguishable from one never closed
}

@Test func resolveRefusesAnUnknownLooseEndWithoutWriting() throws {
  let database = try openCanonicalDatabase(at: tempURL("les-resolve-unknown"))
  let id = try seedLooseEnd(database, quote: "real one")
  #expect(try LooseEndCommands.resolve(database, id: UUID(), status: .done) == false)
  let stored = try database.read { try LooseEnd.where { $0.id.eq(id) }.fetchOne($0) }
  #expect(stored?.status == .open)     // the real row is untouched
}

@Test func resolveSwitchesBetweenDoneAndDroppedAndRestamps() throws {
  let database = try openCanonicalDatabase(at: tempURL("les-resolve-flip"))
  let id = try seedLooseEnd(database, quote: "flip me")
  let first = Date(timeIntervalSince1970: 1_700_000_000)
  let second = Date(timeIntervalSince1970: 1_700_009_999)
  #expect(try LooseEndCommands.resolve(database, id: id, status: .done, now: first))
  #expect(try LooseEndCommands.resolve(database, id: id, status: .dropped, now: second))
  let stored = try database.read { try LooseEnd.where { $0.id.eq(id) }.fetchOne($0) }
  #expect(stored?.status == .dropped)
  #expect(stored?.resolvedAt.map { Int($0.timeIntervalSince1970) } == 1_700_009_999)
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `./scripts/test.sh --filter resolve`
Expected: FAIL — no member `resolve` on `LooseEndCommands`.

- [ ] **Step 3: Implement `resolve`**

In `Sources/PensieveKit/Query/LooseEndCommands.swift`, first widen the type's doc comment (it
currently says it is "the only writer of `LooseEnd.label` / `.labelSuggestion`"):

```swift
/// The only writer of `LooseEnd.label` / `.labelSuggestion` / `.status` / `.resolvedAt`.
/// `Ingester.drain()` stays the only writer of the rest of a loose end. `label` is set by the user
/// (👍/👎) and answers "was the extractor right"; `status` is set by the user and answers "is this
/// handled" — two orthogonal axes that must not be conflated, because `label` feeds the salience
/// training corpus and `status` does not.
```

Then add, after `setLabel`:

```swift
  /// Resolve (or reopen) a loose end. Stamps `resolvedAt` when closing and clears it when reopening,
  /// so a reopened end is indistinguishable from one never closed. Returns false, writing nothing,
  /// if the id is unknown — the caller surfaces that as a refusal (stale state), not a failure.
  @discardableResult
  public static func resolve(_ database: any DatabaseWriter, id: UUID,
                             status: LooseEndStatus, now: Date = Date()) throws -> Bool {
    try database.write { database in
      guard try LooseEnd.where({ $0.id.eq(id) }).fetchOne(database) != nil else { return false }
      let stamp: Date? = status.isClosed ? now : nil
      try LooseEnd.where { $0.id.eq(id) }.update {
        $0.status = status
        $0.resolvedAt = #bind(stamp)
      }.execute(database)
      return true
    }
  }
```

- [ ] **Step 4: Run to verify they pass**

Run: `./scripts/test.sh --filter resolve`
Expected: PASS.

- [ ] **Step 5: Run the full suite**

Run: `./scripts/test.sh`
Expected: PASS, +3 tests.

- [ ] **Step 6: Commit**

```bash
git add Sources/PensieveKit/Query/LooseEndCommands.swift Tests/PensieveKitTests/LooseEndResolutionTests.swift
git commit -F - <<'EOF'
feat(kit): one verb resolves and reopens a loose end

resolve stamps resolvedAt on close and clears it on reopen, so a
reopened end is indistinguishable from one never closed. Returns false
without writing for an unknown id, matching setLabel's contract so the
app can classify it as a refusal rather than a failure.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_013K3R3eWgpmuS2MqQzXhPgo
EOF
```

---

### Task 3: The three feed queries

**Files:**
- Modify: `Sources/PensieveKit/Query/LooseEndQueries.swift`
- Modify: `Tests/PensieveKitTests/LooseEndResolutionTests.swift`

**Interfaces:**
- Consumes: `LooseEndStatus`, `LooseEndView` (existing: `looseEnd`, `occurredAt`, `ageDays`).
- Produces:
  - `LooseEndQueries.openAcrossNodes(_ database:, visibleNodeIDs: Set<UUID>, now: Date) throws -> [LooseEndView]`
  - `LooseEndQueries.closedAcrossNodes(_ database:, visibleNodeIDs: Set<UUID>, now: Date) throws -> [LooseEndView]`
  - `LooseEndQueries.closed(_ database:, nodeID: UUID, now: Date) throws -> [LooseEndView]`

- [ ] **Step 1: Write the failing tests**

Append to `Tests/PensieveKitTests/LooseEndResolutionTests.swift`:

```swift
/// Seeds a node in a given state with one loose end, returning both ids.
private func seedIn(_ database: any DatabaseWriter, nodeState: NodeState,
                    status: LooseEndStatus, resolvedAt: Date? = nil,
                    daysAgo: Int = 0) throws -> (node: UUID, looseEnd: UUID) {
  let node = Node(name: "N", state: nodeState)
  let source = Source(nodeID: node.id, kind: SourceKind.claudeCode, key: "/src/\(UUID().uuidString)")
  let when = Calendar.current.date(byAdding: .day, value: -daysAgo, to: Date())!
  let event = Event(nodeID: node.id, sourceID: source.id, occurredAt: when,
                    kind: CaptureKind.ccSession, summary: "s", detailJSON: "{}")
  let looseEnd = LooseEnd(nodeID: node.id, sourceEventID: event.id, text: "t", quote: "q",
                          status: status, resolvedAt: resolvedAt)
  try database.write { database in
    try Node.insert { node }.execute(database)
    try Source.insert { source }.execute(database)
    try Event.insert { event }.execute(database)
    try LooseEnd.insert { looseEnd }.execute(database)
  }
  return (node.id, looseEnd.id)
}

@Test func openAcrossNodesIsOldestFirstAndActiveVisibleOnly() throws {
  let database = try openCanonicalDatabase(at: tempURL("les-feed-open"))
  let newer = try seedIn(database, nodeState: .active, status: .open, daysAgo: 1)
  let older = try seedIn(database, nodeState: .active, status: .open, daysAgo: 30)
  let archived = try seedIn(database, nodeState: .archived, status: .open, daysAgo: 10)
  let muted = try seedIn(database, nodeState: .muted, status: .open, daysAgo: 10)
  let hidden = try seedIn(database, nodeState: .active, status: .open, daysAgo: 5)
  try seedIn(database, nodeState: .active, status: .done, daysAgo: 2)   // closed: never in this feed

  let visible: Set<UUID> = [newer.node, older.node, archived.node, muted.node]
  let feed = try LooseEndQueries.openAcrossNodes(database, visibleNodeIDs: visible, now: Date())
  #expect(feed.map(\.looseEnd.id) == [older.looseEnd, newer.looseEnd])   // oldest source first
  #expect(!feed.map(\.looseEnd.id).contains(archived.looseEnd))          // archived node excluded
  #expect(!feed.map(\.looseEnd.id).contains(muted.looseEnd))             // muted node excluded
  #expect(!feed.map(\.looseEnd.id).contains(hidden.looseEnd))            // outside the Focus set
}

@Test func closedAcrossNodesIsMostRecentlyResolvedFirst() throws {
  let database = try openCanonicalDatabase(at: tempURL("les-feed-closed"))
  let old = try seedIn(database, nodeState: .active, status: .done,
                       resolvedAt: Date(timeIntervalSince1970: 1_700_000_000))
  let recent = try seedIn(database, nodeState: .active, status: .dropped,
                          resolvedAt: Date(timeIntervalSince1970: 1_700_009_999))
  let stillOpen = try seedIn(database, nodeState: .active, status: .open)

  let visible: Set<UUID> = [old.node, recent.node, stillOpen.node]
  let feed = try LooseEndQueries.closedAcrossNodes(database, visibleNodeIDs: visible, now: Date())
  #expect(feed.map(\.looseEnd.id) == [recent.looseEnd, old.looseEnd])
}

@Test func closedForOneNodeReturnsOnlyThatNodesClosedEnds() throws {
  let database = try openCanonicalDatabase(at: tempURL("les-feed-node"))
  let mine = try seedIn(database, nodeState: .active, status: .done,
                        resolvedAt: Date(timeIntervalSince1970: 1_700_000_000))
  let other = try seedIn(database, nodeState: .active, status: .done,
                         resolvedAt: Date(timeIntervalSince1970: 1_700_000_500))
  let openOnMine = try database.write { database -> UUID in
    let looseEnd = LooseEnd(nodeID: mine.node,
                            sourceEventID: try Event.where { $0.nodeID.eq(mine.node) }
                              .fetchOne(database)!.id,
                            text: "t", quote: "open", status: .open)
    try LooseEnd.insert { looseEnd }.execute(database)
    return looseEnd.id
  }
  let feed = try LooseEndQueries.closed(database, nodeID: mine.node, now: Date())
  #expect(feed.map(\.looseEnd.id) == [mine.looseEnd])
  #expect(!feed.map(\.looseEnd.id).contains(other.looseEnd))
  #expect(!feed.map(\.looseEnd.id).contains(openOnMine))
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `./scripts/test.sh --filter AcrossNodes`
Expected: FAIL — no such members.

- [ ] **Step 3: Implement the three queries**

Append to `Sources/PensieveKit/Query/LooseEndQueries.swift`, inside `enum LooseEndQueries`:

```swift
  /// The burn-down triage feed: every open loose end in an ACTIVE, Focus-visible node, ordered
  /// SUGGESTED-SALIENT FIRST, then oldest source — the ordering `SalienceReviewQueries` already uses.
  ///
  /// Not pure oldest-first, and the reason is measured: every loose end in this store is 0–2 months
  /// old, and the first 200 in oldest-first order come from 13 nodes with 149 of them from three
  /// projects. "Oldest" is not "stalest" on this corpus — it is "grind through three repos". Leading
  /// with what a machine already thinks is a real loose end brings the scarce positives forward and
  /// spreads the queue across projects.
  ///
  /// Scoping lives here rather than at the caller because this is a cross-node feed: `open(nodeID:)`
  /// is already scoped by the node the user picked, but a global list that quietly included archived
  /// or Focus-muted work would contradict every other list in the app.
  public static func openAcrossNodes(_ database: any DatabaseReader, visibleNodeIDs: Set<UUID>,
                                     now: Date) throws -> [LooseEndView] {
    try openViews(database, visibleNodeIDs: visibleNodeIDs, now: now)
      .sorted { left, right in
        let leftRank = left.looseEnd.labelSuggestion == LooseEndLabel.salient ? 0 : 1
        let rightRank = right.looseEnd.labelSuggestion == LooseEndLabel.salient ? 0 : 1
        if leftRank != rightRank { return leftRank < rightRank }
        return left.occurredAt < right.occurredAt
      }
  }

  /// The Completed feed: closed loose ends in ACTIVE, Focus-visible nodes, most recently resolved
  /// first. Ordered by `resolvedAt` (not the source event) because this answers "what did I finish
  /// lately", and a loose end mined from a two-year-old session can be closed today.
  /// 👎-labelled ends are excluded, here and in `closed(nodeID:)`: an item the user declared was
  /// never a loose end has no place in a list they read as a record of their own work, and 98 rows
  /// carry that label today. (Search excludes them for a different reason — they are not in the
  /// corpus at all — so the two exclusions are independent, not one rule applied twice.)
  public static func closedAcrossNodes(_ database: any DatabaseReader, visibleNodeIDs: Set<UUID>,
                                       now: Date) throws -> [LooseEndView] {
    try closedViews(database, visibleNodeIDs: visibleNodeIDs, now: now)
      .sorted { ($0.looseEnd.resolvedAt ?? .distantPast) > ($1.looseEnd.resolvedAt ?? .distantPast) }
  }

  /// One node's closed loose ends, most recently resolved first — the detail pane's collapsed record.
  /// Deliberately NOT node-state-scoped: the caller already has this node open, so filtering it out
  /// by state would render an empty section on a node whose ends plainly exist.
  public static func closed(_ database: any DatabaseReader, nodeID: UUID,
                            now: Date) throws -> [LooseEndView] {
    try database.read { database in
      let ends = try LooseEnd
        .where { $0.nodeID.eq(nodeID) && $0.status.neq(LooseEndStatus.open)
                 && $0.label.neq(LooseEndLabel.noise) }
        .fetchAll(database)
      return try attachEvents(ends, database, now: now)
        .sorted { ($0.looseEnd.resolvedAt ?? .distantPast) > ($1.looseEnd.resolvedAt ?? .distantPast) }
    }
  }

  /// The two cross-node feeds' shared body, written as two small functions rather than one taking a
  /// predicate closure. `(LooseEnd.TableColumns) -> some QueryExpression<Bool>` is NOT expressible:
  /// `some` is allowed in a parameter's own position (SE-0341) but not in the RESULT position of a
  /// function-typed parameter, which would be a reverse-generic. Making it generic over the predicate
  /// would work, but two four-line functions are plainer than one generic one, and only the filter +
  /// event join genuinely need sharing.
  private static func openViews(_ database: any DatabaseReader, visibleNodeIDs: Set<UUID>,
                                now: Date) throws -> [LooseEndView] {
    try database.read { database in
      let ends = try LooseEnd.where { LooseEnd.isOpen($0) }.fetchAll(database)
      return try attachEvents(scoped(ends, visibleNodeIDs: visibleNodeIDs, database),
                              database, now: now)
    }
  }

  private static func closedViews(_ database: any DatabaseReader, visibleNodeIDs: Set<UUID>,
                                  now: Date) throws -> [LooseEndView] {
    try database.read { database in
      let ends = try LooseEnd
        .where { $0.status.neq(LooseEndStatus.open) && $0.label.neq(LooseEndLabel.noise) }
        .fetchAll(database)
      return try attachEvents(scoped(ends, visibleNodeIDs: visibleNodeIDs, database),
                              database, now: now)
    }
  }

  /// Keep only ends whose node is ACTIVE and Focus-visible. Node state is read from the store rather
  /// than trusted from `visibleNodeIDs`, which carries Focus visibility only.
  private static func scoped(_ ends: [LooseEnd], visibleNodeIDs: Set<UUID>,
                             _ database: Database) throws -> [LooseEnd] {
    let activeNodeIDs = Set(try Node.where { $0.state.eq(NodeState.active) }
      .fetchAll(database).map(\.id))
    return ends.filter { activeNodeIDs.contains($0.nodeID) && visibleNodeIDs.contains($0.nodeID) }
  }

  /// Pairs each loose end with its source event's date, dropping any whose event has vanished —
  /// the same rule `open` already applies, kept in one place so the four feeds cannot disagree.
  private static func attachEvents(_ ends: [LooseEnd], _ database: Database,
                                   now: Date) throws -> [LooseEndView] {
    var views: [LooseEndView] = []
    for looseEnd in ends {
      guard let event = try Event.where({ $0.id.eq(looseEnd.sourceEventID) }).fetchOne(database)
      else { continue }
      let days = Calendar.current.dateComponents([.day], from: event.occurredAt, to: now).day ?? 0
      views.append(LooseEndView(looseEnd: looseEnd, occurredAt: event.occurredAt, ageDays: days))
    }
    return views
  }
```

Refactor the existing `open(_:nodeID:now:)` to call `attachEvents` rather than repeating the loop —
it is the same code, and leaving two copies is how the four feeds start disagreeing.

- [ ] **Step 4: Run to verify they pass**

Run: `./scripts/test.sh --filter AcrossNodes`
Expected: PASS.

Also add a test that both closed feeds exclude a 👎-labelled closed end (seed one with
`status: .done, label: LooseEndLabel.noise` and assert it appears in neither `closedAcrossNodes` nor
`closed(nodeID:)`), and one that `openAcrossNodes` puts a suggested-salient item before an older
unsuggested one.

- [ ] **Step 5: Run the full suite**

Run: `./scripts/test.sh`
Expected: PASS, +5 tests (three feed tests, the 👎-exclusion test, the ordering test).

- [ ] **Step 6: Commit**

```bash
git add Sources/PensieveKit/Query/LooseEndQueries.swift Tests/PensieveKitTests/LooseEndResolutionTests.swift
git commit -F - <<'EOF'
feat(kit): three feeds — triage, completed, and one node's record

openAcrossNodes is the burn-down queue (oldest source first, active and
Focus-visible nodes only); closedAcrossNodes and closed order by
resolvedAt, because "what did I finish lately" cannot be answered by the
source event's date.

The shared attachEvents body is extracted rather than copied, including
out of the existing open(nodeID:) — four feeds with four copies of the
same event join is how they start disagreeing.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_013K3R3eWgpmuS2MqQzXhPgo
EOF
```

---

### Task 4: `isActionable` — a finished project leaves What's Next

**Files:**
- Modify: `Sources/PensieveKit/Query/NextQueries.swift`
- Modify: `Sources/PensieveKit/Query/SmartLists.swift`
- Modify: `Sources/PensieveKit/Query/SessionContextQueries.swift` (`rankedContext`)
- Modify: `Sources/pensieve/Commands/Next.swift`
- Modify: `Tests/PensieveKitTests/LooseEndResolutionTests.swift`

**Interfaces:**
- Consumes: `NextItem` (existing: `project`, `openLooseEnds`, `daysDormant`, `score`).
- Produces: `NextItem.closedLooseEnds: Int`; `NextItem.isActionable: Bool`.

**READ THIS BEFORE WRITING ANY CODE.** The obvious predicate — `openLooseEnds > 0` — is wrong and
would gut the feature. Measured on the live store: 162 active nodes carry events, only **32** have any
open loose end, and **123 of the remaining 130 have never had a single `cc.session` event**. Loose
ends are mined only from Claude Code transcripts, so a git-only node can never satisfy that predicate
no matter how much work goes into it; those nodes would disappear permanently from What's Next, MCP
`whats_next`, `pensieve next` and the menu bar. *Finished* is the narrow, earned case: **it had open
ends and they are all closed.**

- [ ] **Step 1: Write the failing test**

Append to `Tests/PensieveKitTests/LooseEndResolutionTests.swift`:

```swift
/// Closing the last open end must remove a node from What's Next but NOT from Dormant — it is
/// finished, not neglected, and the two lists answer different questions.
@Test func closingTheLastEndLeavesWhatsNextButStaysDormant() throws {
  let database = try openCanonicalDatabase(at: tempURL("les-actionable"))
  let node = Node(name: "Finished")
  let source = Source(nodeID: node.id, kind: SourceKind.gitRepo, key: "/repo/\(UUID().uuidString)")
  let longAgo = Calendar.current.date(byAdding: .day, value: -40, to: Date())!
  let event = Event(nodeID: node.id, sourceID: source.id, occurredAt: longAgo,
                    kind: CaptureKind.gitCommit, summary: "s", detailJSON: "{}")
  let looseEnd = LooseEnd(nodeID: node.id, sourceEventID: event.id, text: "t", quote: "q")
  try database.write { database in
    try Node.insert { node }.execute(database)
    try Source.insert { source }.execute(database)
    try Event.insert { event }.execute(database)
    try LooseEnd.insert { looseEnd }.execute(database)
  }

  var lists = try SmartLists.compute(database, now: Date())
  #expect(lists.whatsNext.map(\.project.id).contains(node.id))
  #expect(lists.dormant.map(\.project.id).contains(node.id))

  #expect(try LooseEndCommands.resolve(database, id: looseEnd.id, status: .done))

  lists = try SmartLists.compute(database, now: Date())
  #expect(!lists.whatsNext.map(\.project.id).contains(node.id))   // nothing to pick up
  #expect(lists.dormant.map(\.project.id).contains(node.id))      // still quiet, still listed
}

@Test func rankedContextOmitsNodesWithNoOpenEnds() throws {
  let database = try openCanonicalDatabase(at: tempURL("les-ranked-context"))
  let withWork = try seedIn(database, nodeState: .active, status: .open, daysAgo: 5)
  let finished = try seedIn(database, nodeState: .active, status: .done, daysAgo: 5)
  let items = try SessionContextQueries.rankedContext(limit: 10, context: nil, database, now: Date())
  #expect(items.map(\.nodeID).contains(withWork.node))
  #expect(!items.map(\.nodeID).contains(finished.node))
}

/// THE test that guards the 123-node case. A git-only node never produces a loose end, so "no open
/// ends" cannot mean "finished" for it — it means never measured, and unmeasured work must keep
/// showing up. Without this, the naive predicate removes 130 of 162 nodes on day one.
@Test func aNodeThatNeverHadALooseEndStaysInWhatsNext() throws {
  let database = try openCanonicalDatabase(at: tempURL("les-never-measured"))
  let node = Node(name: "Git only")
  let source = Source(nodeID: node.id, kind: SourceKind.gitRepo, key: "/repo/\(UUID().uuidString)")
  let event = Event(nodeID: node.id, sourceID: source.id, occurredAt: Date(),
                    kind: CaptureKind.gitCommit, summary: "commit", detailJSON: "{}")
  try database.write { database in
    try Node.insert { node }.execute(database)
    try Source.insert { source }.execute(database)
    try Event.insert { event }.execute(database)
  }
  let lists = try SmartLists.compute(database, now: Date())
  #expect(lists.whatsNext.map(\.project.id).contains(node.id))
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `./scripts/test.sh --filter Actionable`
Expected: FAIL — the finished node is still in `whatsNext` and in `rankedContext`.

- [ ] **Step 3: Add the predicate**

In `Sources/PensieveKit/Query/NextQueries.swift`, add `closedLooseEnds` to `NextItem` (and to its
memberwise init and the construction inside `ranked`), then:

```swift
extension NextItem {
  /// Is there anything here to pick up? True when open work remains — and ALSO true when this node
  /// has never produced a loose end at all. Loose ends come only from Claude Code transcripts, and
  /// 123 of this store's 162 active nodes are git-only, so for them "no open ends" means "never
  /// measured", not "finished". Treating those as done empties the list without anyone finishing
  /// anything.
  ///
  /// Not actionable is therefore the narrow, earned case: it HAD open ends and they are all closed.
  ///
  /// The single definition, applied by the three surfaces that answer "what should I pick up next" —
  /// `SmartLists.whatsNext`, `SessionContextQueries.rankedContext` (MCP `whats_next`) and the CLI's
  /// `pensieve next`. Deliberately NOT applied inside `ranked`, which also feeds Dormant and Recently
  /// Active: those answer "what is quiet" and "what moved", and a finished project belongs in both.
  public var isActionable: Bool { openLooseEnds > 0 || closedLooseEnds == 0 }
}
```

In `ranked`, count the closed ends beside the open ones — the same shape as the existing per-node
count, keeping this query's N+1 structure rather than introducing a second one:

```swift
        let closed = try LooseEnd.where { $0.nodeID.eq(project.id)
                                          && $0.status.neq(LooseEndStatus.open) }
          .fetchCount(database)
```

- [ ] **Step 4: Apply it at all three call sites**

`SmartLists.compute` — the `whatsNext` bucket only:

```swift
    let ranked = try NextQueries.ranked(database, now: now)
    // Dormant and Recently Active deliberately keep every ranked node: a finished project is still
    // quiet and still recently touched. Only "what should I pick up" requires something to pick up.
    let whatsNext = ranked.filter(\.isActionable)
    let dormant = ranked
      .filter { $0.daysDormant >= dormantAfterDays }
      .sorted { $0.daysDormant > $1.daysDormant }
    let recentlyActive = ranked
      .filter { $0.daysDormant <= activeWithinDays }
      .sorted { $0.daysDormant < $1.daysDormant }
    return SmartLists(whatsNext: whatsNext, dormant: dormant, recentlyActive: recentlyActive)
```

`SessionContextQueries.rankedContext` — change the first line of the body:

```swift
    let items = try NextQueries.ranked(database, now: now).filter(\.isActionable)
```

`Sources/pensieve/Commands/Next.swift:9`:

```swift
    for item in try NextQueries.ranked(try openCanonical(), now: Date()).filter(\.isActionable) {
```

- [ ] **Step 5: Run to verify they pass**

Run: `./scripts/test.sh --filter Actionable`
Expected: PASS.

- [ ] **Step 6: Run the full suite**

Run: `./scripts/test.sh`

**Two existing tests are expected to fail, and both are pre-identified.** Read each before touching
it:

- `Tests/PensieveKitTests/SmartListsTests.swift:26` — `#expect(lists.whatsNext.count == 2)`. Its
  fixture seeds two nodes with one event each and **zero loose ends**. Under the corrected predicate
  those nodes are "never measured" and **stay** in What's Next, so this assertion should still hold.
  If it does not, the predicate was implemented as the naive `openLooseEnds > 0` — fix the code.
- `Tests/PensieveKitTests/SessionContextQueriesTests.swift:134` —
  `#expect(try SessionContextQueries.rankedContext(...).count == 2)`. Only the `work` node has a
  loose end; `personal` has none and is therefore also "never measured", so this should still hold
  too.

`NextQueriesTests.swift` is unaffected — `ranked` itself is unchanged apart from the added count.

If a Dormant or Recently Active assertion fails, the filter was applied too broadly — fix the code,
not the test.

- [ ] **Step 7: Confirm the spec already matches**

§5 of the spec was corrected on 2026-08-13 (commit `791b1c5`) and already states the three call sites
and the two-part predicate. Re-read it against what you implemented; if they disagree, the code is
wrong, not the spec.

- [ ] **Step 8: Commit**

```bash
git add Sources/PensieveKit Sources/pensieve Tests/PensieveKitTests docs/superpowers/specs
git commit -F - <<'EOF'
feat(kit): a project with no open ends is finished, not neglected

One isActionable predicate, applied by the three surfaces that answer
"what should I pick up next" -- SmartLists.whatsNext, rankedContext
(MCP whats_next) and the CLI's next. Not applied inside ranked, which
also feeds Dormant and Recently Active: those answer "what is quiet" and
"what moved", and a finished project belongs in both.

The spec said two call sites; the CLI calls NextQueries.ranked directly,
so it is three. Corrected there too.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_013K3R3eWgpmuS2MqQzXhPgo
EOF
```

---

### Task 5: The searchable allow-list and index schema v4

**MUST land before Task 6.** Widening the corpus first would let closed rows into an index whose SQL
filter cannot exclude them — a silently shrinking result page instead of a red test (spec §12 risk 2).

**Files:**
- Modify: `Sources/PensieveKit/Model/LooseEndStatus.swift`
- Modify: `Sources/PensieveKit/Search/EmbeddableItem.swift` (the `EmbeddableItem` struct only)
- Modify: `Sources/PensieveKit/Search/SearchIndexStore.swift`
- Modify: `Sources/PensieveKit/Search/SearchIndexer.swift` (`corpusHash`)
- Create: `Tests/PensieveKitTests/LooseEndSearchStatusTests.swift`

**Interfaces:**
- Consumes: `LooseEndStatus`.
- Produces: `LooseEndStatus.searchable(includeClosed:) -> [LooseEndStatus]`;
  `LooseEndStatus.isSearchable(includeClosed:) -> Bool`;
  `EmbeddableItem.status: String` (defaulted `LooseEndStatus.open.rawValue` in `init`);
  `SearchIndexStore.search(_:limit:includeArchived:includeClosed:)`.

- [ ] **Step 1: Write the failing tests**

Create `Tests/PensieveKitTests/LooseEndSearchStatusTests.swift`:

```swift
import Foundation
import Testing
import SQLiteData
@testable import PensieveKit

@Test func searchableIsAnAllowListNotADenyList() {
  #expect(LooseEndStatus.searchable(includeClosed: false) == [.open])
  #expect(Set(LooseEndStatus.searchable(includeClosed: true)) == [.open, .done, .dropped])
  #expect(LooseEndStatus.done.isSearchable(includeClosed: false) == false)
  #expect(LooseEndStatus.done.isSearchable(includeClosed: true))
  #expect(LooseEndStatus.open.isSearchable(includeClosed: false))
}

/// The whole point of schema v4: the index must be able to exclude a closed row in SQL. If it
/// cannot, the resolver drops it afterwards and the page silently shrinks.
@Test func theIndexExcludesClosedRowsUnlessAskedForThem() throws {
  let store = SearchIndexStore(url: tempURL("idx-status"))
  let nodeID = UUID().uuidString
  let openItem = EmbeddableItem(itemID: UUID().uuidString, kind: "loose_end", nodeID: nodeID,
                                state: NodeState.active.rawValue, text: "kestrel migration notes",
                                status: LooseEndStatus.open.rawValue)
  let closedItem = EmbeddableItem(itemID: UUID().uuidString, kind: "loose_end", nodeID: nodeID,
                                  state: NodeState.active.rawValue, text: "kestrel migration notes",
                                  status: LooseEndStatus.done.rawValue)
  store.rebuild(items: [openItem, closedItem], corpusHash: "h1")

  let query = FTSQueryBuilder.build("kestrel", file: nil)!
  let narrow = store.search(query, limit: 10, includeArchived: false, includeClosed: false)
  #expect(narrow.map(\.itemID) == [openItem.itemID])
  let wide = store.search(query, limit: 10, includeArchived: false, includeClosed: true)
  #expect(Set(wide.map(\.itemID)) == [openItem.itemID, closedItem.itemID])
}

/// Closing a loose end changes only its status. If the corpus hash ignores status, the rebuild guard
/// skips the rebuild, the index keeps calling the row open, and a closed end keeps surfacing in the
/// default scope forever.
@Test func corpusHashChangesWhenOnlyAStatusChanges() {
  let itemID = UUID().uuidString, nodeID = UUID().uuidString
  let asOpen = EmbeddableItem(itemID: itemID, kind: "loose_end", nodeID: nodeID,
                              state: NodeState.active.rawValue, text: "same text",
                              status: LooseEndStatus.open.rawValue)
  let asDone = EmbeddableItem(itemID: itemID, kind: "loose_end", nodeID: nodeID,
                              state: NodeState.active.rawValue, text: "same text",
                              status: LooseEndStatus.done.rawValue)
  #expect(SearchIndexer.corpusHash([asOpen]) != SearchIndexer.corpusHash([asDone]))
}

/// The path table holds only event rows, which are never closable — so it carries no status filter.
/// Pinned so a future producer that puts files on a closable item is forced to revisit this.
@Test func onlyEventRowsEverCarryFilePaths() throws {
  let database = try openCanonicalDatabase(at: tempURL("idx-files-kind"))
  try seedLooseEnd(database, quote: "an end")
  let corpus = try EmbeddableCorpus.gather(database)
  #expect(corpus.allSatisfy { $0.files.isEmpty || $0.kind == "event" })
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `./scripts/test.sh --filter SearchStatus`
Expected: FAIL — no `searchable(includeClosed:)`, no `status:` on `EmbeddableItem`.

- [ ] **Step 3: Add the allow-list**

Append to `Sources/PensieveKit/Model/LooseEndStatus.swift`:

```swift
extension LooseEndStatus {
  /// The statuses a search may surface: `open` always, closed states only when the caller opted in.
  /// An allow-list, never a deny-list — a future state can never leak in by omission.
  ///
  /// The single source for this rule, and it is applied TWICE per query on purpose: once in SQL so
  /// the index returns only eligible rows, once again when each candidate is re-resolved against
  /// canonical. Those two applications MUST agree, or rows pass the query and are then silently
  /// dropped, shrinking the page with nothing failing. Sharing one definition is what makes them
  /// agree. Deliberately mirrors `NodeState.searchable(includeArchived:)`, which solves the same
  /// problem for the other dimension.
  public static func searchable(includeClosed: Bool) -> [LooseEndStatus] {
    includeClosed ? [.open, .done, .dropped] : [.open]
  }

  public func isSearchable(includeClosed: Bool) -> Bool {
    Self.searchable(includeClosed: includeClosed).contains(self)
  }
}
```

- [ ] **Step 4: Carry the status on the indexable item**

In `Sources/PensieveKit/Search/EmbeddableItem.swift`, add the property, doc comment and initializer
parameter:

```swift
  /// The item's own lifecycle state, as `LooseEndStatus` raw values. Node and event rows carry
  /// `"open"`: the SQL filter then applies the allow-list uniformly instead of switching on `kind`,
  /// and a kind-conditional filter is exactly the asymmetry that lets the index and the canonical
  /// re-check drift apart.
  public let status: String
  public init(itemID: String, kind: String, nodeID: String, state: String, text: String,
              files: String = "", language: String = "",
              status: String = LooseEndStatus.open.rawValue) {
    self.itemID = itemID; self.kind = kind; self.nodeID = nodeID
    self.state = state; self.text = text; self.files = files; self.language = language
    self.status = status
  }
```

- [ ] **Step 5: Fold status into the corpus hash**

In `Sources/PensieveKit/Search/SearchIndexer.swift`, add one line to `corpusHash`'s loop and extend
its doc comment:

```swift
      hash.absorbField(item.itemID); hash.absorbField(item.contentHash)
      hash.absorbField(item.files); hash.absorbField(item.kind)
      hash.absorbField(item.nodeID); hash.absorbField(item.state)
      hash.absorbField(item.language); hash.absorbField(item.status)
```

Add to the doc comment:

```
  /// `status` is folded in because closing a loose end changes NOTHING else about its document — the
  /// text, id, kind, node and language are all identical. Omit it and the guard skips the rebuild,
  /// leaving the index calling a closed end open, so it keeps surfacing in the default scope forever.
```

- [ ] **Step 6: Bump the index schema and filter on status**

In `Sources/PensieveKit/Search/SearchIndexStore.swift`:

```swift
  private static let schemaVersion = 4
```

Add the column to the `documents` table (leave `document_files` alone — see the doc comment below):

```swift
        try database.execute(sql: """
          CREATE VIRTUAL TABLE IF NOT EXISTS documents USING fts5(
            text,
            item_id UNINDEXED, kind UNINDEXED, node_id UNINDEXED, state UNINDEXED,
            language UNINDEXED, item_status UNINDEXED,
            tokenize = 'unicode61 remove_diacritics 2')
          """)
```

Insert it:

```swift
        let documentInsert = try database.cachedStatement(sql: """
          INSERT INTO documents(text, item_id, kind, node_id, state, language, item_status)
          VALUES (?, ?, ?, ?, ?, ?, ?)
          """)
```
```swift
          try documentInsert.execute(
            arguments: [item.text, item.itemID, item.kind, item.nodeID, item.state, item.language,
                        item.status])
```

Add the status filter beside the existing state filter:

```swift
  /// The SQL rendering of `LooseEndStatus.searchable(includeClosed:)` — the same allow-list the
  /// canonical re-check applies, built from the enum's own raw values for the same reason
  /// `stateFilter` is: a hand-written `'open'` here would reintroduce the mistyped-literal hazard
  /// this codebase converted the enums to kill.
  ///
  /// Applied only to `documents`. `document_files` holds event rows exclusively — events are not
  /// closable, and `onlyEventRowsEverCarryFilePaths` pins that — so a status filter there would be
  /// dead SQL. A future producer that puts paths on a closable item must add one.
  private static func statusFilter(alias: String = "", includeClosed: Bool) -> String {
    let allowed = LooseEndStatus.searchable(includeClosed: includeClosed)
    return "\(alias)item_status IN (\(allowed.map { "'\($0.rawValue)'" }.joined(separator: ",")))"
  }
```

Thread `includeClosed` through `search` and into the two `documents` queries — `textRestrictedByPath`
gets `AND \(Self.statusFilter(alias: "d.", includeClosed: includeClosed))` and `textWithPathProbe`'s
text query gets `AND \(Self.statusFilter(includeClosed: includeClosed))`. `pathHits` is unchanged and
keeps its existing signature.

```swift
  public func search(_ query: FTSQuery, limit: Int, includeArchived: Bool,
                     includeClosed: Bool = false) -> [SearchIndexHit] {
```

- [ ] **Step 7: Add the targeted status update**

Folding `status` into the corpus hash is correct, and on its own it would make every one of 968
closes rebuild the whole index — on this store ~3,700 FTS5 documents including a JSON decode per
event. `item_status` is `UNINDEXED`, so it can be written in place. Add to `SearchIndexStore`:

```swift
  /// Update one document's status in place. `item_status` is an UNINDEXED column, so this touches no
  /// FTS5 term index and costs nothing next to `rebuild`, which drops and reinserts the entire
  /// corpus. Updates every document sharing the item id, so a translated document tracks its
  /// original — leaving one behind would put a German row in a scope its English original is not in.
  ///
  /// Deliberately does NOT touch `corpus_hash`: the stored hash stays stale, so the next daemon or
  /// launch sync performs exactly ONE honest full rebuild instead of nine hundred.
  public func updateStatus(itemID: String, status: String) {
    guard let database else { return }
    do {
      try database.write { database in
        try database.execute(sql: "UPDATE documents SET item_status = ? WHERE item_id = ?",
                             arguments: [status, itemID])
      }
    } catch {
      Log.search.error("SearchIndexStore: status update failed: \(error, privacy: .public)")
    }
  }
```

And a test that closes the loop the agreement test cannot reach — it builds index and canonical in
lockstep, which is precisely why the first draft of this plan missed the staleness:

```swift
/// After a close, the default-scope page must not silently shrink. The agreement test builds index
/// and canonical together and so cannot catch a write path that updates only one of them.
@Test func aClosedEndLeavesTheDefaultScopeWithoutShrinkingThePage() throws {
  let database = try openCanonicalDatabase(at: tempURL("stale-close"))
  let keptID = try seedLooseEnd(database, text: "kestrel alpha", quote: "kestrel alpha")
  let closedID = try seedLooseEnd(database, text: "kestrel beta", quote: "kestrel beta")
  let store = SearchIndexStore(url: tempURL("stale-close-index"))
  let corpus = try EmbeddableCorpus.gather(database)
  store.rebuild(items: corpus, corpusHash: SearchIndexer.corpusHash(corpus))

  #expect(try LooseEndCommands.resolve(database, id: closedID, status: .done))
  store.updateStatus(itemID: closedID.uuidString, status: LooseEndStatus.done.rawValue)

  let visible = Set(try database.read { try Node.all.fetchAll($0) }.map(\.id))
  let hits = SearchQueries.search(query: "kestrel",
                                  scope: SearchScope(visibleNodeIDs: visible),
                                  store: store, database)
  #expect(hits.map(\.id) == [keptID])
}
```

- [ ] **Step 8: Run to verify they pass**

Run: `./scripts/test.sh --filter SearchStatus`
Expected: PASS.

- [ ] **Step 9: Run the full suite**

Run: `./scripts/test.sh`
Expected: PASS. Existing `SearchIndexStore` tests keep passing because `includeClosed` defaults to
`false` and every existing item defaults to `status: "open"`.

- [ ] **Step 10: Commit**

```bash
git add Sources/PensieveKit Tests/PensieveKitTests
git commit -F - <<'EOF'
feat(kit): the search index can exclude a closed loose end in SQL

Index schema v4 carries each document's own status, and one
LooseEndStatus.searchable allow-list renders into the SQL filter -- the
same discipline NodeState.searchable already documents, for the other
dimension. Node and event rows carry "open" so the filter is uniform
rather than switching on kind; a kind-conditional filter is the
asymmetry that lets the index and the canonical re-check drift apart.

corpusHash now folds status, because closing a loose end changes nothing
else about its document. Without it the rebuild guard would skip the
rebuild and the index would call a closed end open forever.

document_files deliberately gets no status filter: it holds event rows
only, and a test pins that.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_013K3R3eWgpmuS2MqQzXhPgo
EOF
```

---

### Task 6: Closed loose ends join the corpus

**Files:**
- Modify: `Sources/PensieveKit/Search/EmbeddableItem.swift` (`EmbeddableCorpus.gather`)
- Modify: `Tests/PensieveKitTests/LooseEndSearchStatusTests.swift`

**Interfaces:**
- Consumes: `EmbeddableItem.status` (Task 5), `LooseEndStatus`.
- Produces: no new API — `gather`'s output grows closed loose ends.

- [ ] **Step 1: Write the failing tests**

Append to `Tests/PensieveKitTests/LooseEndSearchStatusTests.swift`:

```swift
@Test func gatherIndexesClosedEndsTaggedWithTheirStatus() throws {
  let database = try openCanonicalDatabase(at: tempURL("corpus-closed"))
  let openID = try seedLooseEnd(database, quote: "open work")
  let doneID = try seedLooseEnd(database, quote: "finished work", status: .done)
  let droppedID = try seedLooseEnd(database, quote: "abandoned work", status: .dropped)

  let corpus = try EmbeddableCorpus.gather(database)
  let byID = Dictionary(corpus.filter { $0.kind == "loose_end" }.map { ($0.itemID, $0.status) },
                        uniquingKeysWith: { first, _ in first })
  #expect(byID[openID.uuidString] == LooseEndStatus.open.rawValue)
  #expect(byID[doneID.uuidString] == LooseEndStatus.done.rawValue)
  #expect(byID[droppedID.uuidString] == LooseEndStatus.dropped.rawValue)
}

/// A thumbs-down asserts the text was never real content, so indexing it would pollute retrieval.
/// A closed end WAS real work. The two axes stay apart in the corpus exactly as they do in the model.
@Test func gatherStillExcludesNoiseLabelledEnds() throws {
  let database = try openCanonicalDatabase(at: tempURL("corpus-noise"))
  let noisy = try seedLooseEnd(database, quote: "not a loose end", label: LooseEndLabel.noise)
  let noisyAndClosed = try seedLooseEnd(database, quote: "noisy and closed",
                                        status: .done, label: LooseEndLabel.noise)
  let corpus = try EmbeddableCorpus.gather(database)
  let ids = Set(corpus.map(\.itemID))
  #expect(!ids.contains(noisy.uuidString))
  #expect(!ids.contains(noisyAndClosed.uuidString))
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `./scripts/test.sh --filter gather`
Expected: FAIL — closed ends are absent from the corpus.

- [ ] **Step 3: Widen the corpus**

In `EmbeddableCorpus.gather`, replace the loose-end fetch and its loop:

```swift
      // Open AND closed. Closing hides work from the live views; it does not make the work
      // unrecallable — the same reasoning that put archived nodes in this corpus. Each item carries
      // its own status, which is what lets the query layer scope per search scope.
      //
      // `label = "noise"` stays EXCLUDED, and that asymmetry is deliberate: 👎 asserts the text was
      // never a loose end at all, so indexing it would pollute retrieval, whereas a closed end was
      // real work someone finished. `isOpen` conflates the two, so this predicate spells them out
      // separately instead of reusing it.
      let ends = try LooseEnd.where { $0.label.neq(LooseEndLabel.noise) }.fetchAll(database)
      for looseEnd in ends {
        guard let state = stateByNodeID[looseEnd.nodeID] else { continue }
        out.append(.init(itemID: looseEnd.id.uuidString, kind: "loose_end", nodeID: looseEnd.nodeID.uuidString,
                         state: state, text: [looseEnd.text, looseEnd.quote].filter { !$0.isEmpty }.joined(separator: " — "),
                         status: looseEnd.status.rawValue))
        // Text ONLY — never the quote. The original document is "text — quote"; a translated
        // document that re-appended the English quote would manufacture a duplicate hit, and the
        // quote is verbatim provenance that must never be adjacent to a translation.
        appendTranslatedLooseEnd(.looseEndText, of: looseEnd.text, kind: "loose_end",
                                 from: looseEnd, state: state, status: looseEnd.status.rawValue)
      }
```

**`appendTranslatedLooseEnd` MUST gain that `status` parameter and pass it into the `EmbeddableItem`
it appends** — the call above already does, and the helper's signature has to match. This is not
optional cleanup: `EmbeddableItem.status` defaults to `"open"`, so a helper left unchanged emits a
German document for a *closed* loose end tagged `open`. That document then passes the SQL filter in
the default scope and is dropped by the resolver — the exact §8.1 page-shrinking failure, reachable
only through the translation path. Extend the helper's doc comment with the same reasoning it already
carries for `kind`: a translated document that disagreed with its original about eligibility would
appear in a scope its original does not.

Add a test alongside Task 6's others that seeds a closed loose end with a stored translation and
asserts **both** its documents carry the closed status.

Update the type doc comment: "active AND archived nodes + their open loose ends" becomes "+ their
loose ends, open and closed (👎-labelled ones excluded)".

- [ ] **Step 4: Run to verify they pass**

Run: `./scripts/test.sh --filter gather`
Expected: PASS.

- [ ] **Step 5: Run the full suite**

Run: `./scripts/test.sh`
Expected: PASS, +3 tests.

- [ ] **Step 6: Commit**

```bash
git add Sources/PensieveKit Tests/PensieveKitTests
git commit -F - <<'EOF'
feat(kit): closed loose ends join the search corpus

Closing hides work from the live views; it does not make the work
unrecallable -- the same reasoning that put archived nodes in this
corpus. Each document carries its own status, so the query layer scopes
per search scope.

Thumbs-down items stay excluded, and the asymmetry is deliberate: 👎
asserts the text was never a loose end, so indexing it would pollute
retrieval, whereas a closed end was real work. isOpen conflates the two,
so the corpus predicate spells them out rather than reusing it.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_013K3R3eWgpmuS2MqQzXhPgo
EOF
```

---

### Task 7: The resolver re-check, `SearchScope.includeClosed`, and `SearchHit.status`

**Files:**
- Modify: `Sources/PensieveKit/Query/SearchHit.swift`
- Modify: `Sources/PensieveKit/Query/SearchHitResolver.swift`
- Modify: `Sources/PensieveKit/Query/SearchQueries.swift`
- Modify: `Tests/PensieveKitTests/LooseEndSearchStatusTests.swift`

**Interfaces:**
- Consumes: `LooseEndStatus.isSearchable(includeClosed:)`, `SearchIndexStore.search(…includeClosed:)`.
- Produces: `SearchHit.status: LooseEndStatus` (`.open` for node and event hits);
  `SearchScope.includeClosed: Bool` (defaulted `false`).

- [ ] **Step 1: Write the failing test — the agreement test**

This is the most important test in the plan: it is what fails loudly instead of shrinking a page
silently. Append to `Tests/PensieveKitTests/LooseEndSearchStatusTests.swift`:

```swift
/// The index filter and the canonical re-check must agree for every scope. If they disagree, rows
/// pass the SQL query and are then dropped by the resolver — the page shrinks and nothing fails.
/// Asserted end-to-end through the real query path rather than by comparing the two rules by eye.
@Test func indexAndResolverAgreeAboutClosedEndsInEveryScope() throws {
  let database = try openCanonicalDatabase(at: tempURL("agree-closed"))
  let openID = try seedLooseEnd(database, text: "kestrel migration", quote: "kestrel migration")
  let doneID = try seedLooseEnd(database, text: "kestrel rollout", quote: "kestrel rollout",
                                status: .done)
  let store = SearchIndexStore(url: tempURL("agree-closed-index"))
  let corpus = try EmbeddableCorpus.gather(database)
  store.rebuild(items: corpus, corpusHash: SearchIndexer.corpusHash(corpus))
  let visible = Set(try database.read { try Node.all.fetchAll($0) }.map(\.id))

  let narrow = SearchQueries.search(
    query: "kestrel",
    scope: SearchScope(visibleNodeIDs: visible, includeArchived: false, includeClosed: false),
    store: store, database)
  #expect(narrow.map(\.id).contains(openID))
  #expect(!narrow.map(\.id).contains(doneID))

  let wide = SearchQueries.search(
    query: "kestrel",
    scope: SearchScope(visibleNodeIDs: visible, includeArchived: false, includeClosed: true),
    store: store, database)
  #expect(Set(wide.map(\.id)) == [openID, doneID])
  #expect(wide.first { $0.id == doneID }?.status == .done)
  #expect(wide.first { $0.id == openID }?.status == .open)
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `./scripts/test.sh --filter indexAndResolverAgree`
Expected: FAIL — `SearchScope` has no `includeClosed`, `SearchHit` has no `status`.

- [ ] **Step 3: Add `status` to the hit**

In `Sources/PensieveKit/Query/SearchHit.swift`, after `isArchived`:

```swift
  /// The loose end's own lifecycle state, so the view can badge a closed row. Always `.open` for
  /// node and event hits, which have no lifecycle of their own — the same shape as `isArchived`,
  /// which is always false unless the caller opted in.
  public let status: LooseEndStatus
```

Add it to the memberwise initializer with a default of `.open` so node and event construction sites
need no change.

- [ ] **Step 4: Teach the resolver the allow-list**

In `Sources/PensieveKit/Query/SearchHitResolver.swift`, add the knob beside `includeArchived`:

```swift
  let includeArchived: Bool
  /// Widens the loose-end re-check to closed ends. A SEPARATE knob from `includeArchived` because
  /// the two dimensions are orthogonal — a hit can be an archived node's open end or an active
  /// node's closed one — even though the app's scope bar happens to drive both from one control.
  var includeClosed: Bool = false
```

Replace the hardcoded `LooseEnd.isOpen` in the `.looseEnd` case. Fetch the row without a status
predicate, then apply the allow-list in Swift, so the resolver and the index are both reading the
same `searchable(includeClosed:)`:

```swift
    case .looseEnd:
      // Fetched WITHOUT a status predicate, then filtered through the shared allow-list — the same
      // rule the SQL filter renders. A hardcoded `isOpen` here is what made this the one place the
      // two could disagree. The `label != noise` half of `isOpen` is kept unconditionally: a 👎 item
      // is not in the corpus at all, so surfacing one would mean the index is stale.
      guard let looseEnd = try LooseEnd.where({ $0.id.eq(itemID) }).fetchOne(database),
            looseEnd.label != LooseEndLabel.noise,
            looseEnd.status.isSearchable(includeClosed: includeClosed),
            let node = try Node.where({ $0.id.eq(looseEnd.nodeID) }).fetchOne(database),
            eligible(node) else { return nil }
      return SearchHit(id: looseEnd.id, kind: .looseEnd, nodeID: looseEnd.nodeID,
                       nodeName: node.name, title: looseEnd.text,
                       snippet: snippet(preferring: [looseEnd.text, looseEnd.quote,
                                                     translations(.looseEndText, looseEnd.text) ?? ""]),
                       score: score, isArchived: node.state == .archived,
                       status: looseEnd.status)
```

- [ ] **Step 5: Thread the scope through**

In `Sources/PensieveKit/Query/SearchQueries.swift`, add the field to `SearchScope`:

```swift
public struct SearchScope: Sendable {
  public var visibleNodeIDs: Set<UUID>
  public var excludingIDs: Set<UUID>
  public var limit: Int
  public var includeArchived: Bool
  /// Widen to closed (done/dropped) loose ends. Orthogonal to `includeArchived` in this kernel; the
  /// app's scope bar drives both from one control, which is a UI decision, not a model one.
  public var includeClosed: Bool
  public init(visibleNodeIDs: Set<UUID>, excludingIDs: Set<UUID> = [],
              limit: Int = SearchQueries.resultCap, includeArchived: Bool = false,
              includeClosed: Bool = false) {
    self.visibleNodeIDs = visibleNodeIDs
    self.excludingIDs = excludingIDs
    self.limit = limit
    self.includeArchived = includeArchived
    self.includeClosed = includeClosed
  }
}
```

Then pass `includeClosed: scope.includeClosed` into the `store.search(...)` call and into the
`SearchHitResolver(...)` construction inside `search`. Find both by compiler error after adding the
field — do not guess at their line numbers.

- [ ] **Step 6: Run to verify it passes**

Run: `./scripts/test.sh --filter indexAndResolverAgree`
Expected: PASS.

- [ ] **Step 7: Run the full suite**

Run: `./scripts/test.sh`
Expected: PASS, +2 tests (the agreement test and its translated-document case).

- [ ] **Step 8: Commit**

```bash
git add Sources/PensieveKit Tests/PensieveKitTests
git commit -F - <<'EOF'
feat(kit): the canonical re-check reads the same allow-list as the index

SearchHitResolver's loose-end case hardcoded isOpen, which made it the
one place the index filter and the re-check could disagree -- and when
they disagree, rows pass the query and are then dropped, so the page
shrinks with nothing failing. Both now render
LooseEndStatus.searchable(includeClosed:), and a test asserts they agree
end-to-end through the real query path in both scopes.

The label != noise half of isOpen stays unconditional: a 👎 item is not
in the corpus at all, so surfacing one would mean the index is stale.

SearchScope grows includeClosed as a SEPARATE knob from includeArchived
-- the dimensions are orthogonal in the kernel, and conflating them is a
UI decision the app makes, not a model one.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_013K3R3eWgpmuS2MqQzXhPgo
EOF
```

---

### Task 8: MCP `search` carries the widened scope and reports it

**Files:**
- Modify: `Sources/pensieve/Commands/Mcp.swift`
- Modify: `Tests/PensieveKitTests/LooseEndSearchStatusTests.swift` (wire-shape assertion only if a
  test target already reaches `SearchItem`; otherwise verify by the manual step below)

**Interfaces:**
- Consumes: `SearchScope.includeClosed`, `SearchHit.status`.
- Produces: MCP `search` items gain a `closed` boolean.

The spec calls this out by name because the archived-content ship shipped this exact field dropped at
the MCP boundary, and only a final whole-branch review caught it.

- [ ] **Step 1: Widen the scope the tool builds**

At `Sources/pensieve/Commands/Mcp.swift:148`, `include_archived` is read into `includeArchived`. The
`SearchScope` built from it (around line 250) gains the closed dimension:

```swift
    // One control, two dimensions: `include_archived` widens BOTH node state and loose-end status,
    // matching the app's single scope bar. The kernel keeps them separate; conflating them is the
    // caller's choice, and this is the caller.
    scope: SearchScope(visibleNodeIDs: visible, limit: limit,
                       includeArchived: includeArchived, includeClosed: includeArchived),
```

Update the tool's JSON-schema description at line ~80:

```swift
             "include_archived": .object(["type": .string("boolean"),
                                          "description": .string("also search archived projects and closed loose ends (default false)")]),
```

- [ ] **Step 2: Carry the flag on the wire**

In the `SearchItem` struct (around line 301):

```swift
  var archived: Bool
  /// The loose end is done or dropped. Always false for node and event items. A widened scope whose
  /// items cannot say WHICH rows the widening admitted is a half-finished change.
  var closed: Bool
```
```swift
    archived = hit.isArchived
    closed = hit.status.isClosed
```
```swift
    case id, kind, title, snippet, score, archived, closed
```

- [ ] **Step 3: Build the CLI**

Run:
```bash
xcodebuild -project Pensieve.xcodeproj -scheme PensieveCLI -configuration Debug \
  -derivedDataPath ./.build-xcode build > /tmp/cli-build.log 2>&1; echo "exit=$?"
grep -c "BUILD SUCCEEDED" /tmp/cli-build.log
```
Expected: `exit=0` and a non-zero grep count. Run `xcodegen generate` first if the project file is
absent. Do **not** pipe `xcodebuild` into `tail` — the exit code would be `tail`'s.

- [ ] **Step 4: Verify the wire shape by hand**

The MCP server speaks stdio JSON-RPC; assert the field exists against a throwaway store:

```bash
PENSIEVE_DB=/tmp/mcp-closed.sqlite PENSIEVE_CAPTURE_DB=/tmp/mcp-closed-capture.sqlite \
  ./.build-xcode/Build/Products/Debug/pensieve mcp <<'EOF' | grep -o '"closed":[a-z]*' | head -3
{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"plan","version":"1"}}}
{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"search","arguments":{"query":"anything"}}}
EOF
```

An empty store returns no items, so an empty result here is expected and proves only that the server
starts. **The real check is the human-verify carry** at the end of this plan, run against the real
store after reinstalling the app.

- [ ] **Step 5: Run the full suite**

Run: `./scripts/test.sh`
Expected: PASS, unchanged (no Kit change in this task).

- [ ] **Step 6: Commit**

```bash
git add Sources/pensieve/Commands/Mcp.swift
git commit -F - <<'EOF'
feat(mcp): search's widened scope reaches closed loose ends, and says so

include_archived widens both node state and loose-end status, matching
the app's single scope bar -- the kernel keeps the two dimensions
separate, and conflating them is the caller's choice.

Items carry a closed flag beside archived. Called out explicitly because
the archived-content ship shipped this exact field dropped at the MCP
boundary: a widened scope whose items cannot say which rows the widening
admitted is a half-finished change.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_013K3R3eWgpmuS2MqQzXhPgo
EOF
```

---

### Task 9: The resolve verbs on a loose-end row, with undo

**Files:**
- Create: `Sources/PensieveApp/LooseEndStatusMenu.swift`
- Modify: `Sources/PensieveApp/AppModel+Recall.swift`
- Modify: `Sources/PensieveApp/LooseEndRow.swift`
- Modify: `Sources/PensieveApp/Localizable.xcstrings`

**Interfaces:**
- Consumes: `LooseEndCommands.resolve`, `LooseEndStatus`.
- Produces: `AppModel.resolveLooseEnd(_ looseEndID: UUID, _ status: LooseEndStatus, previous: LooseEndStatus, undoManager: UndoManager?)`;
  `LooseEndStatusMenu` (a `View` usable in both `.contextMenu` and `.swipeActions`);
  `LooseEndRow.onResolve: ((UUID, LooseEndStatus, LooseEndStatus) -> Void)?`.

- [ ] **Step 1: Add the model write**

In `Sources/PensieveApp/AppModel+Recall.swift`, after `setLooseEndLabel`:

```swift
  /// Resolve or reopen a loose end, registering the inverse with the responder chain's undo manager.
  /// Undo is not polish here: triage is a rapid keyboard flow by design, so a mis-key must be one ⌘Z
  /// away. `previous` is passed in rather than re-read because the row already holds the snapshot,
  /// and re-reading after the write would record the NEW value as the thing to undo to.
  func resolveLooseEnd(_ looseEndID: UUID, _ status: LooseEndStatus,
                       previous: LooseEndStatus, undoManager: UndoManager?) {
    guard let database else { return }
    do {
      let succeeded = try LooseEndCommands.resolve(database, id: looseEndID, status: status)
      if succeeded {
        // The index must not lag the write. `refresh()` does NOT sync the search indexes — only
        // `drainThenRefresh` and `refreshFromWatch` do — so without this the index keeps calling the
        // row open: it passes the SQL filter, the resolver drops it on the canonical re-check, and
        // because LIMIT is applied in SQL the result page silently shrinks. A targeted UNINDEXED
        // update rather than `syncSearchIndexes()`, which would rebuild ~3,700 documents per close.
        searchIndexStore?.updateStatus(itemID: looseEndID.uuidString, status: status.rawValue)
        undoManager?.registerUndo(withTarget: self) { model in
          model.resolveLooseEnd(looseEndID, previous, previous: status, undoManager: undoManager)
        }
        undoManager?.setActionName(String(localized: "Resolve Loose End"))
        refresh()
      } else {
        refuse(String(localized: "update"), String(localized: "this loose end"))
      }
    } catch {
      fail(String(localized: "update"), String(localized: "this loose end"), error)
    }
  }
```

`refresh()` is called on success because the row must leave the open feed (unlike `setLabel`, whose
row already re-filters on the next reload).

`searchIndexStore` is whichever `SearchIndexStore` instance `AppModel` already holds for
`syncSearchIndexes` — reuse it; do not construct a second one, since two handles on the same file
would each carry their own busy-timeout behaviour. If the existing one is created per-sync rather
than stored, hoist it to an `@ObservationIgnored` property first.

- [ ] **Step 2: Create the shared verb menu**

Create `Sources/PensieveApp/LooseEndStatusMenu.swift`:

```swift
// Sources/PensieveApp/LooseEndStatusMenu.swift
import SwiftUI
import PensieveKit

/// The resolve verbs for one loose end, shared by the row's context menu and its swipe actions so
/// the two can never offer different verbs. Deliberately NOT merged with the 👍/👎 thumbs: those
/// answer "was the extractor right" and feed the salience training corpus, while these answer "is
/// this handled" — conflating them would poison the corpus with work that was real but abandoned.
struct LooseEndStatusMenu: View {
  let status: LooseEndStatus
  /// Applies the chosen new status. The row supplies the previous one, so this takes only the target.
  let resolve: (LooseEndStatus) -> Void

  var body: some View {
    if status == .open {
      Button("Mark as done") { resolve(.done) }
      Button("Drop") { resolve(.dropped) }
    } else {
      Button("Reopen") { resolve(.open) }
      if status == .done {
        Button("Mark as dropped") { resolve(.dropped) }
      } else {
        Button("Mark as done") { resolve(.done) }
      }
    }
  }
}
```

- [ ] **Step 3: Wire the row**

In `Sources/PensieveApp/LooseEndRow.swift`, add the input **immediately after `onTranslate` and
before `expandedLooseEndID`** — the struct's memberwise initializer takes arguments in declaration
order, and every call site in Tasks 9–11 passes `onResolve` after `onTranslate`. Declaring it beside
`onLabel` instead (position 4) makes all three call sites fail to compile.

```swift
  /// Resolves this loose end: `(looseEndID, newStatus, previousStatus)`. `nil` in surfaces that do
  /// not offer resolution — no caller may show a dead button.
  var onResolve: ((UUID, LooseEndStatus, LooseEndStatus) -> Void)?
```

Add an optimistic local override next to `localLabel`, for the same reason it exists:

```swift
  /// Optimistic override of the status so a tap reflects immediately (the injected `LooseEndView` is
  /// an immutable snapshot). nil = show the stored value.
  @State private var localStatus: LooseEndStatus?
  private var currentStatus: LooseEndStatus { localStatus ?? view.looseEnd.status }

  private func resolve(_ newStatus: LooseEndStatus) {
    let previous = currentStatus
    localStatus = newStatus
    onResolve?(view.looseEnd.id, newStatus, previous)
  }
```

In the existing `.contextMenu`, add the verbs **above** the salience ones with a divider, so the
common action is first:

```swift
    .contextMenu {
      if onResolve != nil {
        LooseEndStatusMenu(status: currentStatus, resolve: resolve)
        Divider()
      }
      Button("Mark as a real loose end") { setLabel(LooseEndLabel.salient) }
      ...
```

And add swipe actions on the row (outside the `.contextMenu`, on the same `VStack`):

```swift
    // Swipe is a pointer affordance in the List-backed feeds; the context menu is the discoverable
    // one everywhere; the keyboard verbs in Step 3b are the burn-down one. All three render the same
    // two commands so they cannot drift apart.
    //
    // NOTE: this is INERT in `DetailView`, which renders loose ends in a VStack inside a ScrollView
    // rather than a List. That is expected, not a regression — the detail pane is covered by the
    // context menu and the menu commands.
    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
      if onResolve != nil, currentStatus == .open {
        Button("Mark as done") { resolve(.done) }.tint(.green)
        Button("Drop") { resolve(.dropped) }.tint(.orange)
      }
    }
```

- [ ] **Step 3b: Add the keyboard verbs (spec §6 — required, not optional)**

Without these the queue is pointer-only, and the undo registered above is justified by "a mis-key
must be one ⌘Z away" with no key to mis-hit. At 968 items this is the difference between a queue and
a chore.

Find the file declaring the app's existing command groups (the shipped Find submenu is `FindCommands`,
added via `CommandGroup(after: .textEditing)` because this SDK has no `.find` placement) and add a
sibling group. Follow `FindCommands`' pattern exactly, including how it reaches the focused scene's
state via an explicit `FocusedValueKey` — `@FocusedValue` has no `init(_ objectType:)` for a plain
`@Observable` class in this SDK, which is why the shipped code does it that way:

```swift
/// Resolve verbs for the selected row of a loose-end feed. `⌘⏎` / `⌥⌘⏎` / `⇧⌘⏎` deliberately avoid
/// bare letters (List type-ahead) and the shipped ⌘F / ⌥⌘F / ⌘G find bindings.
struct LooseEndCommands: Commands {
  @FocusedValue(\.looseEndSelection) private var selection: LooseEndSelection?

  var body: some Commands {
    CommandGroup(after: .pasteboard) {
      Divider()
      Button("Mark as Done") { selection?.resolve(.done) }
        .keyboardShortcut(.return, modifiers: .command)
        .disabled(selection?.canClose != true)
      Button("Drop") { selection?.resolve(.dropped) }
        .keyboardShortcut(.return, modifiers: [.option, .command])
        .disabled(selection?.canClose != true)
      Button("Reopen") { selection?.resolve(.open) }
        .keyboardShortcut(.return, modifiers: [.shift, .command])
        .disabled(selection?.canReopen != true)
    }
  }
}
```

`LooseEndSelection` is a tiny value the feed column publishes as a focused value: the selected loose
end's id, its current status (so the three buttons enable correctly), and a `resolve` closure onto
`AppModel.resolveLooseEnd`. Publish it from `ContentListView` when the middle column is showing
`.triage` or `.completed`, and **not otherwise** — the verbs must be disabled everywhere else rather
than acting on a stale selection. Register the group in the `App`'s `.commands` beside the existing
ones.

- [ ] **Step 4: Pass it from the two existing call sites**

`DetailView.swift` and `ContentListView.swift`'s `looseEndList()` both construct `LooseEndRow`. Add
to each:

```swift
                    onResolve: { id, status, previous in
                      model.resolveLooseEnd(id, status, previous: previous, undoManager: undoManager)
                    },
```

with `@Environment(\.undoManager) private var undoManager` on each view. Leave `reviewList()` without
`onResolve` — Review Suggestions audits the training corpus, and offering resolution there is what D3
rejected.

- [ ] **Step 5: Add the strings**

Add to `Sources/PensieveApp/Localizable.xcstrings` (en base + de), by hand:

| Key | en | de |
|---|---|---|
| `Mark as done` | Mark as done | Als erledigt markieren |
| `Drop` | Drop | Verwerfen |
| `Reopen` | Reopen | Wieder öffnen |
| `Mark as dropped` | Mark as dropped | Als verworfen markieren |
| `Mark as Done` | Mark as Done | Als erledigt markieren |
| `Resolve Loose End` | Resolve Loose End | Losen Faden abschließen |

`Mark as Done` is a separate key from `Mark as done` on purpose: menu items take Title Case, inline
buttons do not, and String Catalog keys are case-sensitive. `Drop` and `Reopen` are shared by both
surfaces, which is correct — they are the same word in both registers.

**Before adding any row, check whether the key already exists in the catalog with a different
value.** This bit the project once already: the catalog holds `"Done"` → de `"Fertig"`, consumed by
`FindBar.swift:28`'s dismiss button, so a new `"Done"` row would silently relabel the find bar. None
of the five keys above collides, but Task 10 adds one that does.

- [ ] **Step 6: Build and smoke**

```bash
xcodegen generate
xcodebuild -project Pensieve.xcodeproj -scheme Pensieve -configuration Debug \
  -derivedDataPath ./.build-xcode build > /tmp/app-build.log 2>&1; echo "exit=$?"
grep -c "BUILD SUCCEEDED" /tmp/app-build.log
PENSIEVE_DB=/tmp/smoke.sqlite PENSIEVE_CAPTURE_DB=/tmp/smoke-capture.sqlite \
  ./.build-xcode/Build/Products/Debug/Pensieve.app/Contents/MacOS/Pensieve &
sleep 8; kill %1
```
Expected: `exit=0`, `BUILD SUCCEEDED` present, no crash in the smoke window. **If the smoke launch
hangs**, it is likely the known keychain prompt on an ad-hoc-signed Debug build (see Gotchas at the
end) — record it rather than working around it.

- [ ] **Step 7: Commit**

```bash
git add Sources/PensieveApp
git commit -F - <<'EOF'
feat(app): a loose end can be marked done, dropped, or reopened

One LooseEndStatusMenu renders the verbs for both the context menu and
the swipe actions, so the discoverable affordance and the fast one
cannot drift apart. The row keeps an optimistic local status for the
same reason it already keeps an optimistic local label.

Undo is registered per resolve and is not polish: triage is a rapid
keyboard flow by design, so a mis-key must be one ⌘Z away. The previous
status is passed in rather than re-read, because re-reading after the
write would record the new value as the thing to undo to.

Review Suggestions deliberately gets no resolve verb -- it audits the
salience training corpus, a different job.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_013K3R3eWgpmuS2MqQzXhPgo
EOF
```

---

### Task 10: The Loose Ends and Completed sidebar buckets

**Files:**
- Modify: `Sources/PensieveApp/AppModel+Types.swift`
- Modify: `Sources/PensieveApp/AppModel.swift` (`middleKind()`)
- Modify: `Sources/PensieveApp/AppModel+Recall.swift` (two feed accessors)
- Modify: `Sources/PensieveApp/RootView.swift` (two sidebar rows)
- Modify: `Sources/PensieveApp/ContentListView.swift`
- Modify: `Sources/PensieveApp/Localizable.xcstrings`

**Interfaces:**
- Consumes: `LooseEndQueries.openAcrossNodes` / `closedAcrossNodes`, `LooseEndStatusMenu`.
- Produces: `SidebarSelection.triage` / `.completed`; `MiddleKind.triage` / `.completed`;
  `AppModel.triageItems()` / `completedItems()`; `AppModel.focusLooseEnd(_ looseEnd: LooseEnd)`.

- [ ] **Step 1: Extend the two enums**

In `Sources/PensieveApp/AppModel+Types.swift`:

```swift
enum SidebarSelection: Hashable {
  case briefing
  case reviewSuggestions
  /// The burn-down queue: every open loose end, oldest first.
  case triage
  /// The record: loose ends already done or dropped, most recently closed first.
  case completed
  case smartList(SmartListKind)
  case node(UUID)
}
```

```swift
enum MiddleKind: Equatable {
  case nodes([Node])
  case looseEndsOf(UUID)
  case reviewSuggestions
  case triage
  case completed
}
```

These are **not** `SmartListKind` cases: that enum's `itemsKeyPath` returns `[NextItem]` (nodes), and
these two buckets hold loose ends. `.reviewSuggestions` set the precedent for a sidebar row that is
not a smart list. `DeepLink` is therefore untouched — none of these three is deep-linkable, and its
`SmartList` raw values keep matching `SmartListKind` exactly.

- [ ] **Step 2: Route the middle column**

In `Sources/PensieveApp/AppModel.swift`'s `middleKind()`:

```swift
    case .reviewSuggestions:
      return .reviewSuggestions
    case .triage:
      return .triage
    case .completed:
      return .completed
```

- [ ] **Step 3: Add the feed accessors**

In `Sources/PensieveApp/AppModel+Recall.swift`, beside `reviewItems()`:

```swift
  /// The burn-down queue. Focus-scoped like every other list; the Kit query adds active-node scoping.
  func triageItems() -> [LooseEndView] {
    guard let database else { return [] }
    return (try? LooseEndQueries.openAcrossNodes(database, visibleNodeIDs: visibleNodeIDs(),
                                                 now: Date())) ?? []
  }

  /// Closed loose ends across all projects, most recently resolved first.
  func completedItems() -> [LooseEndView] {
    guard let database else { return [] }
    return (try? LooseEndQueries.closedAcrossNodes(database, visibleNodeIDs: visibleNodeIDs(),
                                                   now: Date())) ?? []
  }
```

`visibleNodeIDs()` is the Focus-visible set `AppModel` already computes for its lists — reuse the
existing helper rather than recomputing `NodeContextResolver.visibleNodeIDs` here. If it is currently
inlined at its call site, extract it to a private method first and use it in all three places.

Add the navigation the spec's §6 requires — selecting a feed row shows its node in the detail pane
with the cited row expanded, so you judge against full provenance rather than a summary:

```swift
  /// Land the detail pane on a feed row's loose end. Deliberately does NOT change `sidebarSelection`:
  /// the queue must stay in the middle column, or every decision would cost you your place in it.
  /// Same two writes as `selectSearchHit`'s loose-end branch, which lands the same way from search.
  func focusLooseEnd(_ looseEnd: LooseEnd) {
    selectedNodeID = looseEnd.nodeID
    expandedLooseEndID = looseEnd.id
  }
```

- [ ] **Step 4: Add the two sidebar rows**

In **`Sources/PensieveApp/SidebarView.swift`** — not `RootView.swift`, which holds only the
`NavigationSplitView`, the sheets and the `.alert` — beside the existing Review Suggestions row at
`SidebarView.swift:22-33` (which tags `SidebarSelection.reviewSuggestions` with a `checklist` icon),
add two rows tagging `.triage` and `.completed`. Match the existing row's `Label { … } icon: { … }`
structure exactly:

```swift
      Label {
        HStack {
          Text("Loose Ends")
          Spacer()
          Text("\(model.triageCount)").foregroundStyle(.secondary)
        }
      } icon: {
        Image(systemName: "tray.full").foregroundStyle(.blue)
      }
      .tag(SidebarSelection.triage)
      Label("Completed", systemImage: "checkmark.circle").foregroundStyle(.green)
      .tag(SidebarSelection.completed)
```

Add `var triageCount = 0` to `AppModel` beside `reviewCount`, and set it in the same refresh block
(`AppModel.swift:310`):

```swift
    triageCount = (try? LooseEndQueries.openAcrossNodes(database, visibleNodeIDs: visibleNodeIDs(),
                                                        now: Date()).count) ?? 0
```

Completed carries no count on purpose: it grows without bound and a number there invites reading it
as a score.

- [ ] **Step 5: Render the two feeds**

In `Sources/PensieveApp/ContentListView.swift`, add state and switch arms:

```swift
  @State private var triageItems: [LooseEndView] = []
  @State private var completedItems: [LooseEndView] = []
  /// The feed row the detail pane is currently showing. Local to the column, not on `AppModel`:
  /// it is a cursor into this list, and a recall window opened from here must not inherit it.
  @State private var focusedFeedID: UUID?
```
```swift
      case .reviewSuggestions: reviewList()
      case .triage: crossNodeList(triageItems, showsStatusBadge: false)
      case .completed: crossNodeList(completedItems, showsStatusBadge: true)
```
```swift
      case .looseEndsOf(let id): looseEnds = model.looseEnds(forNode: id)
      case .reviewSuggestions: reviewItems = model.reviewItems()
      case .triage: triageItems = model.triageItems()
      case .completed: completedItems = model.completedItems()
      case .nodes: looseEnds = []; reviewItems = []; triageItems = []; completedItems = []
```

Add the shared builder beside `reviewList()`. It is a sibling rather than a generalization of
`reviewList()`: that list is find-unscoped, resolve-less and has its own empty state, and folding
three surfaces into one builder with three flags would be harder to read than one small duplicate.

```swift
  /// The two cross-node loose-end feeds. Rows carry the owning node's name (they come from
  /// everywhere) and offer the resolve verbs; the Completed feed additionally badges each row with
  /// the verb that closed it, which is the only consumer that distinguishes done from dropped.
  @ViewBuilder private func crossNodeList(_ items: [LooseEndView],
                                          showsStatusBadge: Bool) -> some View {
    // A `List(selection:)` rather than plain rows: ↑↓ then walks the queue and the detail pane
    // follows, which is the whole burn-down loop. It also avoids fighting `LooseEndRow`'s own tap,
    // which toggles its inline provenance — a row-level `.onTapGesture` would swallow that.
    List(selection: Binding(
      get: { focusedFeedID },
      set: { newValue in
        focusedFeedID = newValue
        if let newValue, let match = items.first(where: { $0.looseEnd.id == newValue }) {
          model.focusLooseEnd(match.looseEnd)
        }
      })) {
      ForEach(items, id: \.looseEnd.id) { view in
        VStack(alignment: .leading, spacing: 2) {
          HStack {
            if let name = model.node(view.looseEnd.nodeID)?.name {
              Text(name).font(.caption).foregroundStyle(.secondary)
            }
            if showsStatusBadge {
              Spacer()
              LooseEndStatusBadge(status: view.looseEnd.status)
            }
          }
          LooseEndRow(view: view, loadProvenance: model.provenance, onLabel: model.setLooseEndLabel,
                      displaySummary: model.displayed(field: .looseEndText,
                                                      sourceText: view.looseEnd.text),
                      onTranslate: { text in await model.translate(field: .looseEndText, sourceText: text) },
                      onResolve: { id, status, previous in
                        model.resolveLooseEnd(id, status, previous: previous, undoManager: undoManager)
                      },
                      compact: true)
        }
        .tag(view.looseEnd.id)
      }
    }
    .overlay {
      if items.isEmpty {
        if showsStatusBadge {
          ContentUnavailableView("Nothing completed yet", systemImage: "checkmark.circle")
        } else {
          ContentUnavailableView("No open loose ends", systemImage: "tray")
        }
      }
    }
  }
```

Add the badge view at the bottom of the file, beside `ArchivedBadge`:

```swift
/// Marks a closed loose end with the verb that closed it. Renders nothing for an open one, so the
/// same row builder serves both feeds.
struct LooseEndStatusBadge: View {
  let status: LooseEndStatus
  var body: some View {
    switch status {
    case .open: EmptyView()
    // Own catalog keys, NOT the bare "Done" — that key exists and belongs to FindBar's dismiss
    // button, where its German is "Fertig".
    case .done: badge(Text("Loose end done"), .green)
    case .dropped: badge(Text("Loose end dropped"), .secondary)
    }
  }

  private func badge(_ label: Text, _ tint: Color) -> some View {
    label
      .font(.caption2)
      .padding(.horizontal, 5)
      .padding(.vertical, 1)
      .background(.quaternary, in: Capsule())
      .foregroundStyle(tint)
  }
}
```

Extend `subtitle(for:)` and `MiddleLoadKey.Tag` with the two new cases — both switch exhaustively and
will not compile until you do:

```swift
    case .triage:
      return String(localized: "\(triageItems.count) open")
    case .completed:
      return String(localized: "\(completedItems.count) closed")
```
```swift
    enum Tag: Hashable { case nodes, looseEnds(UUID), review, triage, completed }
```

Add `@Environment(\.undoManager) private var undoManager` to `ContentListView`.

- [ ] **Step 6: Add the strings**

| Key | en | de |
|---|---|---|
| `Loose Ends` | Loose Ends | Lose Fäden |
| `Completed` | Completed | Abgeschlossen |
| `No open loose ends` | No open loose ends | Keine losen Fäden offen |
| `Nothing completed yet` | Nothing completed yet | Noch nichts abgeschlossen |
| `Loose end done` | Done | Erledigt |
| `Loose end dropped` | Dropped | Verworfen |
| `%lld closed` | %lld closed | %lld abgeschlossen |

**Do NOT add a bare `"Done"` key.** The catalog already holds `"Done"` → de `"Fertig"`, consumed by
`FindBar.swift:28`'s dismiss button; adding a row would silently relabel the find bar to "Erledigt",
and reusing the existing entry would render the badge as "Fertig", which is not the intended word
either. The badge therefore uses its own keys — `"Loose end done"` / `"Loose end dropped"` — whose
English *values* are still "Done" / "Dropped". Reference them in `LooseEndStatusBadge` as
`Text("Loose end done")`, not `Text("Done")`.

`%lld open` already exists (→ de `%lld offen`) and is reused rather than re-added. `Include Archived`
also exists (→ de `Archivierte einschließen`) and is retired in Task 11.

- [ ] **Step 7: Build, smoke, and check the line count**

Run the build + smoke from Task 9 Step 6, plus:

```bash
swiftlint lint --strict 2>&1 | tail -5
wc -l Sources/PensieveApp/ContentListView.swift Sources/PensieveApp/AppModel.swift
```
Expected: 0 violations, and both files under 400 lines. `ContentListView.swift` starts at 239 and
gains ~60 — if it crosses 400, split the search-results half into `ContentSearchList.swift` rather
than trimming comments.

- [ ] **Step 8: Commit**

```bash
git add Sources/PensieveApp
git commit -F - <<'EOF'
feat(app): a burn-down queue and a Completed list in the sidebar

Two new sidebar buckets over the middle column's existing cross-node
loose-end shape -- no new pane, no new navigation model. Loose Ends is
the triage queue (oldest first, so the stalest item comes first);
Completed is the record, badged with the verb that closed each one,
which is the only consumer that distinguishes done from dropped.

They are SidebarSelection cases rather than SmartListKind cases: that
enum's itemsKeyPath returns nodes, and these hold loose ends.
Review Suggestions set the precedent. DeepLink is untouched.

Completed carries no sidebar count on purpose: it grows without bound,
and a number there invites reading it as a score.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_013K3R3eWgpmuS2MqQzXhPgo
EOF
```

---

### Task 11: The per-node record, and the widened scope bar

**Files:**
- Modify: `Sources/PensieveApp/DetailView.swift`
- Modify: `Sources/PensieveApp/AppModel+Recall.swift`
- Modify: `Sources/PensieveApp/AppModel+Search.swift`
- Modify: `Sources/PensieveApp/ContentListView.swift` (scope picker label + search row badge)
- Modify: `Sources/PensieveApp/Localizable.xcstrings`

**Interfaces:**
- Consumes: `LooseEndQueries.closed(nodeID:)`, `SearchScope.includeClosed`, `SearchHit.status`,
  `LooseEndStatusBadge`.
- Produces: nothing new.

- [ ] **Step 1: Add the per-node read**

In `Sources/PensieveApp/AppModel+Recall.swift`:

```swift
  /// One node's closed loose ends — the detail pane's collapsed record.
  func closedLooseEnds(forNode nodeID: UUID) -> [LooseEndView] {
    guard let database else { return [] }
    return (try? LooseEndQueries.closed(database, nodeID: nodeID, now: Date())) ?? []
  }
```

- [ ] **Step 2: Render the disclosure**

In `Sources/PensieveApp/DetailView.swift`, add `@State private var closedLooseEnds: [LooseEndView] = []`
and load it in the same `.task` that sets `looseEnds` (around line 120):

```swift
      closedLooseEnds = model.closedLooseEnds(forNode: node.id)
```

**Placement is load-bearing.** Put the disclosure at the very BOTTOM of the pane's `VStack` — after
Recent Activity, not inside the Loose Ends section. An earlier draft placed it inside that section
and justified deferring find-indexing with "closed ends render after everything else", which was
false: the recap (`DetailView.swift:69`) and Recent Activity (`:87`) both follow Loose Ends, so
appending closed slots to `NodeFindDocument` would have put them after `.narration` and every
`.event` — violating the "match order equals on-screen order" contract and recreating the exact
slice-A × in-node-find defect the spec cites as its own justification. Rendering it last makes the
sentence true and keeps the deferral honest.

Still gate it on `showsLooseEnds`, so a childless focused strand does not grow a stray section:

```swift
              // The record, collapsed. Rendered only when non-empty: an always-present "Done · 0"
              // would announce a slot that is usually empty, the same failure the recap's removed
              // caps header had.
              if !closedLooseEnds.isEmpty {
                DisclosureGroup {
                  ForEach(closedLooseEnds, id: \.looseEnd.id) { view in
                    HStack(alignment: .top, spacing: 8) {
                      LooseEndStatusBadge(status: view.looseEnd.status)
                      LooseEndRow(view: view, loadProvenance: model.provenance,
                                  onLabel: model.setLooseEndLabel,
                                  displaySummary: model.displayed(field: .looseEndText,
                                                                  sourceText: view.looseEnd.text),
                                  onTranslate: { text in await model.translate(field: .looseEndText, sourceText: text) },
                                  onResolve: { id, status, previous in
                                    model.resolveLooseEnd(id, status, previous: previous,
                                                          undoManager: undoManager)
                                  },
                                  compact: false)
                    }
                  }
                } label: {
                  Text("Done · \(closedLooseEnds.count)").font(.callout).foregroundStyle(.secondary)
                }
                .padding(.top, 4)
              }
```

Add `@Environment(\.undoManager) private var undoManager` if Task 9 did not already.

**Do NOT add these rows to `NodeFindDocument`.** In-node ⌘F over the disclosure is deliberately out of
scope (spec §7.1): the document's contract is that match order equals on-screen order via
pre-allocated per-loose-end slots, and — *given the placement above* — closed rows now genuinely do
render after everything else, so appending their slots later stays compatible. Adding them now
without extending that contract would reintroduce the exact defect the slice-A × in-node-find merge
produced.

Known day-one consequence, accepted: ⌘F over an expanded "Done · N" reports no matches for text
plainly on screen. It is behind a collapsed disclosure of already-closed work, which is the least bad
place in the pane for that gap.

- [ ] **Step 3: Widen the search scope**

In `Sources/PensieveApp/AppModel+Search.swift`, the `.all` scope now widens both dimensions:

```swift
    // One control, two dimensions. The kernel keeps `includeArchived` and `includeClosed` separate
    // because they are orthogonal — an archived node's open end and an active node's closed end are
    // different things — but the UI offers one widening, so both are driven from it.
    let includeArchived = (searchScope == .all)
    let includeClosed = (searchScope == .all)
```

and pass `includeClosed: includeClosed` into the `PensieveKit.SearchScope(...)` construction.

The node-eligibility line just below (`$0.state.isSearchable(includeArchived:)`) is about nodes and
stays exactly as it is.

- [ ] **Step 4: Relabel the scope picker and badge closed rows**

In `ContentListView.searchScopePicker()`:

```swift
      Text("Include Archived & Closed").tag(AppModel.SearchScope.all)
```

In `searchRow(_:)`, beside the archived badge:

```swift
        if hit.isArchived { Spacer(); ArchivedBadge() }
        if hit.status.isClosed { LooseEndStatusBadge(status: hit.status) }
```

Note the existing `Spacer()` lives inside the `isArchived` branch; if both badges can show, hoist the
`Spacer()` out so the row does not push twice.

- [ ] **Step 5: Add the strings**

| Key | en | de |
|---|---|---|
| `Done · %lld` | Done · %lld | Erledigt · %lld |
| `Include Archived & Closed` | Include Archived & Closed | Archivierte und abgeschlossene einschließen |

The old `Include Archived` key becomes unused — **remove it from the catalog** in the same commit, so
the catalog does not accumulate orphans.

- [ ] **Step 6: Build, smoke, lint**

Run the build + smoke + `swiftlint lint --strict` from Task 10 Step 7.
Expected: `exit=0`, `BUILD SUCCEEDED`, 0 violations.

- [ ] **Step 7: Verify the catalog by parsing it, not by eye**

The slice-A verify pass found six keys that never matched their literals, and the lesson recorded in
`CONTINUE.md` is that this is checkable mechanically:

```bash
plutil -convert json -o - Sources/PensieveApp/Localizable.xcstrings \
  | grep -o '"[^"]*"' | sort -u > /tmp/catalog-keys.txt
```

Confirm every key added in Tasks 9–11 is present **and has a `de` value**, and that format specifiers
match between `en` and `de` (`%lld` on both sides). A `de` value that is missing or mis-keyed falls
back to English silently.

- [ ] **Step 8: Commit**

```bash
git add Sources/PensieveApp
git commit -F - <<'EOF'
feat(app): a node keeps its record, and search can reach it

A collapsed "Done · N" disclosure at the foot of the detail pane's Loose
Ends section, rendered only when non-empty -- an always-present "Done ·
0" would announce a slot that is usually empty, the same failure the
recap's caps header had.

The ⌥⌘F scope bar's second option now widens both dimensions and says so
("Include Archived & Closed"), and closed rows badge the verb that
closed them. The kernel keeps the two dimensions separate; conflating
them is this control's choice.

The disclosure is deliberately NOT indexed by in-node ⌘F: the find
document's contract is that match order equals on-screen order via
pre-allocated per-loose-end slots, and closed rows render last, so
appending their slots later stays compatible.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_013K3R3eWgpmuS2MqQzXhPgo
EOF
```

---

### Task 12: Per-node bulk close

Added after adversarial review (spec D10). 288 open ends sit on one node; item-by-item is not a path
for that tail, and `resolve(status: .open)` reverses the verb, so the "indistinguishable from data
loss" framing that first deferred it does not hold.

**Files:**
- Modify: `Sources/PensieveKit/Query/LooseEndCommands.swift`
- Modify: `Sources/PensieveApp/AppModel+Recall.swift`
- Modify: `Sources/PensieveApp/NodeContextMenu.swift`
- Modify: `Sources/PensieveApp/Localizable.xcstrings`
- Modify: `Tests/PensieveKitTests/LooseEndResolutionTests.swift`

**Interfaces:**
- Consumes: `LooseEndCommands.resolve`, `LooseEndStatus`.
- Produces: `LooseEndCommands.resolveAllOpen(_ database:, nodeID: UUID, status: LooseEndStatus, now: Date) throws -> [UUID]`
  (the ids it actually closed, so undo can reopen exactly that set).

- [ ] **Step 1: Write the failing test**

```swift
@Test func bulkCloseClosesOnlyThisNodesOpenEndsAndReportsThem() throws {
  let database = try openCanonicalDatabase(at: tempURL("les-bulk"))
  let mine = try seedIn(database, nodeState: .active, status: .open)
  let other = try seedIn(database, nodeState: .active, status: .open)
  let alreadyClosed = try database.write { database -> UUID in
    let event = try Event.where { $0.nodeID.eq(mine.node) }.fetchOne(database)!
    let looseEnd = LooseEnd(nodeID: mine.node, sourceEventID: event.id, text: "t", quote: "already",
                            status: .dropped,
                            resolvedAt: Date(timeIntervalSince1970: 1_700_000_000))
    try LooseEnd.insert { looseEnd }.execute(database)
    return looseEnd.id
  }

  let closed = try LooseEndCommands.resolveAllOpen(database, nodeID: mine.node, status: .done,
                                                   now: Date())
  #expect(closed == [mine.looseEnd])   // only the OPEN one, and only on this node

  let stored = try database.read { try LooseEnd.all.fetchAll($0) }
  #expect(stored.first { $0.id == other.looseEnd }?.status == .open)      // other node untouched
  #expect(stored.first { $0.id == alreadyClosed }?.status == .dropped)    // not re-stamped
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `./scripts/test.sh --filter bulkClose`
Expected: FAIL — no `resolveAllOpen`.

- [ ] **Step 3: Implement it**

```swift
  /// Close every OPEN loose end on one node, returning the ids it changed so the caller can register
  /// a single undo that reopens exactly that set. Already-closed ends are left alone — re-stamping
  /// their `resolvedAt` would move work you finished weeks ago to the top of the Completed feed.
  ///
  /// 👎-labelled ends ARE included: they are open by `status`, and leaving them behind would mean the
  /// count in the confirmation dialog disagreed with what the node's open feed shows.
  @discardableResult
  public static func resolveAllOpen(_ database: any DatabaseWriter, nodeID: UUID,
                                    status: LooseEndStatus, now: Date = Date()) throws -> [UUID] {
    try database.write { database in
      let open = try LooseEnd.where { $0.nodeID.eq(nodeID) && $0.status.eq(LooseEndStatus.open) }
        .fetchAll(database)
      guard !open.isEmpty else { return [] }
      let stamp: Date? = status.isClosed ? now : nil
      try LooseEnd.where { $0.nodeID.eq(nodeID) && $0.status.eq(LooseEndStatus.open) }.update {
        $0.status = status
        $0.resolvedAt = #bind(stamp)
      }.execute(database)
      return open.map(\.id)
    }
  }
```

- [ ] **Step 4: Run to verify it passes**

Run: `./scripts/test.sh --filter bulkClose`
Expected: PASS.

- [ ] **Step 5: Wire the app action**

In `AppModel+Recall.swift`:

```swift
  /// Close every open end on a node in one action, with ONE undo that reopens exactly the set it
  /// closed — not "reopen everything on this node", which would resurrect ends closed weeks ago.
  func closeAllLooseEnds(onNode nodeID: UUID, undoManager: UndoManager?) {
    guard let database else { return }
    do {
      let closed = try LooseEndCommands.resolveAllOpen(database, nodeID: nodeID, status: .done)
      for id in closed {
        searchIndexStore?.updateStatus(itemID: id.uuidString, status: LooseEndStatus.done.rawValue)
      }
      undoManager?.registerUndo(withTarget: self) { model in
        model.reopenLooseEnds(closed, undoManager: undoManager)
      }
      undoManager?.setActionName(String(localized: "Close All Loose Ends"))
      refresh()
    } catch {
      fail(String(localized: "update"), String(localized: "this node"), error)
    }
  }

  /// Undo's inverse of `closeAllLooseEnds`. Registers its own redo so ⌘Z / ⇧⌘Z toggles cleanly.
  private func reopenLooseEnds(_ ids: [UUID], undoManager: UndoManager?) {
    guard let database else { return }
    for id in ids {
      _ = try? LooseEndCommands.resolve(database, id: id, status: .open)
      searchIndexStore?.updateStatus(itemID: id.uuidString, status: LooseEndStatus.open.rawValue)
    }
    undoManager?.registerUndo(withTarget: self) { model in
      for id in ids { _ = try? LooseEndCommands.resolve(database, id: id, status: .done) }
      model.refresh()
    }
    refresh()
  }
```

In `NodeContextMenu.swift`, add the item plus a `.confirmationDialog` naming the count — the dialog
is what makes the verb reviewable, since the plan deliberately does not show the items first:

```swift
      Button("Close all open loose ends…", role: .destructive) { confirmingBulkClose = true }
```

- [ ] **Step 6: Strings**

| Key | en | de |
|---|---|---|
| `Close all open loose ends…` | Close all open loose ends… | Alle offenen losen Fäden abschließen … |
| `Close %lld loose ends?` | Close %lld loose ends? | %lld lose Fäden abschließen? |
| `They can be reopened individually or with ⌘Z.` | They can be reopened individually or with ⌘Z. | Sie lassen sich einzeln oder mit ⌘Z wieder öffnen. |
| `Close All Loose Ends` | Close All Loose Ends | Alle losen Fäden abschließen |

- [ ] **Step 7: Build, smoke, lint, then commit**

```bash
git add Sources/PensieveKit Sources/PensieveApp Tests/PensieveKitTests
git commit -F - <<'EOF'
feat: close every open loose end on one node, with one undo

288 open ends sit on a single node, so item-by-item is not a path for
that tail. The verb is reversible, which is why the "indistinguishable
from data loss" framing that first deferred it does not hold -- but it
still confirms, naming the count, and registers ONE undo that reopens
exactly the set it closed rather than everything on the node.

Already-closed ends are left alone: re-stamping resolvedAt would move
work finished weeks ago to the top of the Completed feed.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_013K3R3eWgpmuS2MqQzXhPgo
EOF
```

---

## Final verification

- [ ] **Full suite:** `./scripts/test.sh` → 0 failures. Baseline is **625**; each task states its own
      delta, and the total lands near **655**. Treat a mismatch as a prompt to check which task's
      tests were skipped, not as a target to hit.
- [ ] **Lint:** `swiftlint lint --strict` → 0 violations; no file over 400 lines.
- [ ] **Both builds:** `xcodegen generate`, then the `Pensieve` and `PensieveCLI` schemes, each
      checked for `** BUILD SUCCEEDED **` in an unpiped log.
- [ ] **The invariant that matters is semantic, not textual:**
      `git diff main -- Sources/PensieveKit/Model/LooseEnd.swift` should show `isOpen`'s literal
      retyped to `.eq(LooseEndStatus.open)` **and nothing else about what it selects**;
      `openSQLPredicate` unchanged; `looseEndOpenPredicatesAgree` passing. A diff that changes which
      rows `isOpen` matches means the design was not followed.
- [ ] **The predicate that would have gutted What's Next:** confirm `isActionable` is
      `openLooseEnds > 0 || closedLooseEnds == 0` and that `aNodeThatNeverHadALooseEndStaysInWhatsNext`
      passes. Then sanity-check against the real store, read-only, that What's Next has not collapsed:
      `sqlite3 -readonly ~/Library/Application\ Support/Pensieve/pensieve.sqlite "select count(*) from nodes where state='active';"`
      and compare with the app's list.
- [ ] **Index freshness:** `aClosedEndLeavesTheDefaultScopeWithoutShrinkingThePage` passes, and
      `resolveLooseEnd` calls `updateStatus` (grep for it — its absence is silent).
- [ ] **Trust gate:** `git diff main --stat` touches neither `TranscriptVocabulary.swift` nor
      `TranscriptParser.swift`.
- [ ] **Live store untouched:** every smoke run set `PENSIEVE_DB`/`PENSIEVE_CAPTURE_DB`; confirm
      `~/Library/Application Support/Pensieve/pensieve.sqlite`'s mtime did not move during the work.
- [ ] Whole-branch **Opus** review, then `superpowers:finishing-a-development-branch`.

## Human-verify carries (need the built app at `/Applications` and the real store)

The app target has no unit tests, so all of this is eyeball-only.

- **The burn-down loop itself:** select Loose Ends, walk it with ↑↓, close several with the swipe and
  the context menu. Does the count in the sidebar drop as you go? Does the **detail pane follow the
  ↑↓ cursor**, landing on each row's node with the cited row expanded — and does the queue keep your
  place in the middle column rather than navigating away from it?
- **⌘Z after a mis-key** restores the previous status *and* puts the row back in the queue.
- **A project actually finishes:** close every open end on one small node. It must leave What's Next
  and remain in Dormant. `pensieve next` must agree with the app.
- **The per-node record:** the "Done · N" disclosure appears only on nodes with closed ends, and
  reopening from inside it moves the row back up into Loose Ends.
- **Completed ordering** is genuinely most-recent-first, and the done/dropped badges are right.
- **⌥⌘F, both scopes:** a phrase that exists only in a closed loose end returns nothing under Active
  and returns the badged row under Include Archived & Closed.
- **Spotlight does NOT return closed ends** — that is D8, deliberate.
- **MCP from a real session:** `search` with `include_archived: true` returns items carrying
  `"closed": true`, and `whats_next` no longer lists projects with no open ends.
- **German in situ** (`-AppleLanguages '(de)'`): the two sidebar rows, both badges, the disclosure
  label, the widened scope-bar option, and the undo action name in the Edit menu.
- **Focus scoping:** with a Work focus active, the two new buckets show only work nodes' ends.

## Gotchas carried into this work

- **`log` is shadowed by a shell function here — always use `/usr/bin/log`.** A bare `log show` fails
  with `too many arguments` and prints nothing, which reads exactly like "no events".
- **Smoke-launching an ad-hoc-signed Debug build can block on a keychain prompt** (observed
  2026-08-12 on the macOS 26 floor slice): a fresh code-signing identity makes macOS ask to allow
  access to the stored cloud-LLM secret, and on a locked screen nothing can answer it. If the launch
  hangs in `KeychainSecretStore.read`, that is this — report it, do not work around it.
- **`open ./.build-xcode/…` from the main checkout launches main's app, not the worktree's.** Confirm
  with `pgrep -lf Pensieve.app/Contents/MacOS/Pensieve` before concluding a branch regressed.
- **Merging a branch that adds files which exist untracked in the main checkout can abort a
  fast-forward** — back the untracked copy aside first.
