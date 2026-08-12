# Loose ends can end — three resolution verbs (`open` / `done` / `dropped`)

**Status:** approved design, 2026-08-13. Successor artifact: an implementation plan under
`docs/superpowers/plans/`.

**One sentence:** a loose end is open forever today, so every count derived from it is a number that
only grows; this gives a loose end a way to *end*, gives the 968 already captured a surface built for
burning them down, and gives the finished ones a place to be seen.

---

## 1. Why now, and what is actually broken

`docs/superpowers/backlog.md` calls this "the single highest-value idea in the whole review", and it
is a data-model change rather than chrome. The concrete complaint: **"Als Nächstes 155" and "Ruhend
112" never shrink, and so neither number means anything.** A project with no open work and no recent
activity reads as *neglected* when it is *finished*.

### Measured starting state (live store, 2026-08-13)

| Fact | Value |
|---|---|
| Loose ends total | **968** |
| …with `status = 'open'` | **968 (all of them)** |
| …unlabeled | 846 |
| …labeled `noise` (👎) | 98 |
| …labeled `salient` (👍) | 24 |
| Nodes | 278 |
| Rows ever written with `status = 'resolved'` | **0** |

### Four findings that make this small

1. **`LooseEnd.status` already exists** (`Sources/PensieveKit/Model/LooseEnd.swift`), documented as
   `"open" | "resolved"`. **No production code has ever written it** — the only `"resolved"` literals
   in the repository are in six test files. The escape hatch was built and never given a verb.

2. **`LooseEnd.isOpen` is a single shared predicate** — `status == "open" && label != "noise"` — with
   a raw-SQL twin (`openSQLPredicate`) pinned by `looseEndOpenPredicatesAgree` in `NodeFactsTests`.
   It is read by the detail view, the menu-bar count, App-Intents facts, What's-Next ranking, the
   search corpus and Spotlight. **Adding states to `status` propagates through all of them with no
   edit to the predicate**, because anything that is not `open` already fails it.

3. **The resurrection guard is already built.** `ExtractionRunner.insertVerifiedLooseEnds` dedups
   proposed loose ends against *every* existing loose end for the node, "regardless of status", with
   a comment stating that re-extraction "must not resurrect a RESOLVED loose end the user already
   dismissed". Closing one makes it stay closed; nothing to build.

4. **👎 already closes a loose end in every surface**, because `isOpen` excludes `label = "noise"`.
   98 items are closed this way today. So the missing capability is not "make it disappear" — it is
   **"close something that was genuinely a loose end"**.

### The two axes, kept apart

| | Meaning | Consumer |
|---|---|---|
| `label` (👍/👎) | *Was the extractor right that this is a loose end?* | The salience **training corpus** (`LooseEndCommands.corpus`) |
| `status` (new) | *The extractor was right, and the item is now handled.* | Backlog hygiene, counts, ranking |

Conflating them would poison the training corpus with items that were real but abandoned. They stay
orthogonal: a `dropped` loose end may be 👍-labeled, and that is coherent.

---

## 2. Decisions taken (with the alternatives that were rejected)

| # | Decision | Rejected alternative |
|---|---|---|
| D1 | Three states: `open` / `done` / `dropped` | A single `closed` state — rejected once the Completed list gave `dropped` a real consumer (D6) |
| D2 | The primary surface is a **burn-down triage queue**, not just per-row verbs | Per-row only (the 968 would stay for months); a modal triage sheet (a whole new surface to build and localize) |
| D3 | The queue is a **sidebar smart list** inside the existing three panes | Folding it into *Review Suggestions* — that queue audits the training corpus, a different job |
| D4 | Closing drops a node from **What's Next only**, via a shared `isActionable` predicate | Filtering inside `NextQueries.ranked` (would also empty Dormant/Recently Active); reworking `groundedScore` (a deliberate ADHD affordance) |
| D5 | Closed ends stay findable in ⌥⌘F behind the **existing scope bar**, via index schema v4 | Dropping them from the corpus (cheapest, but "what did I decide about X" stops working) |
| D6 | Both a **per-node disclosure** and a global **Completed** smart list | Per-node only — leaves `done` vs `dropped` with no consumer worth the extra decision per item |
| D7 | 👎-labeled ends stay **out** of the search corpus | Indexing them alongside closed ends — 👎 asserts the text was never real content |
| D8 | Spotlight stays **open-ends-only** | Widening it too: Spotlight has no scope control, so closed items could never be filtered back out |

---

## 3. Data model

### 3.1 A real status enum

Following the shipped `NodeKind` / `NodeState` conversion precedent exactly:

```swift
public enum LooseEndStatus: String, QueryBindable, Sendable {
  case open, done, dropped
}
```

`LooseEnd.status` changes type from `String` to `LooseEndStatus`.

**On-disk format is byte-identical and there is no migration for this part** — the stored strings are
unchanged for every existing row, exactly as the `NodeKind`/`NodeState` conversion achieved. The
verified precondition is that **all 968 rows hold `"open"`**, so no row can fail to decode into the
enum. *The implementation plan must re-run that check against the live store immediately before the
type change lands, and abort if any other value is present.*

Test-only `"resolved"` literals (in `SearchQueriesTests`, `ExtractionRunnerTests`,
`SalienceReviewQueriesTests`, `LooseEndFactsTests`, `MonitorSnapshotTests`, `NodeFactsTests`) become
`.done` or `.dropped`. No production alias for `"resolved"` is introduced, because no production row
carries it.

**String literals in production that must move to the enum:** `SalienceReviewQueries` filters with
`$0.status.eq("open")` in *both* `pending` and `pendingCount`. These are the only production
comparisons against the raw string and must become `.eq(LooseEndStatus.open)` — leaving them as
literals would compile-break at the type change, which is the desired outcome.

### 3.2 `resolvedAt` and migration v12

The Completed list orders by *when you closed it*, which nothing records. `LooseEnd` gains:

```swift
public var resolvedAt: Date?   // nil ⇔ never resolved
```

```swift
migrator.registerMigration("v12-looseend-resolvedat") { database in
  // Nullable on purpose: NULL means "never resolved", which is the honest reading for every
  // existing row. Nothing filters on it (only ORDER BY), so v11's three-valued-logic warning
  // about `.neq` on a nullable column does not apply here.
  try #sql(#"ALTER TABLE "looseEnds" ADD COLUMN "resolvedAt" TEXT"#).execute(database)
}
```

Additive, consistent with v9–v11. The canonical store is at **v11** today. Zero rows are closed, so
there is no backfill question: every row that will ever have a non-NULL `resolvedAt` gets it from the
write path below.

### 3.3 `isOpen` is untouched

`LooseEnd.isOpen` and `LooseEnd.openSQLPredicate` are **not edited**. `status.eq(.open)` already
excludes `done` and `dropped`. The `looseEndOpenPredicatesAgree` test keeps passing unchanged, and
every one of the predicate's consumers gets correct behaviour for free. *This is the single reason
the feature is small, and any implementation that finds itself editing `isOpen` has gone wrong.*

---

## 4. Write path

`LooseEndCommands` — already the sanctioned non-`Ingester` writer, and already the only writer of
`label` — gains one verb:

```swift
/// Resolve (or reopen) a loose end. Stamps `resolvedAt` when closing; clears it when reopening,
/// so a reopened end is indistinguishable from one never closed. Returns false, writing nothing,
/// if the row is unknown.
@discardableResult
public static func resolve(_ database: any DatabaseWriter, id: UUID,
                           status: LooseEndStatus, now: Date = Date()) throws -> Bool
```

- Reopening is `resolve(status: .open)`; there is no separate `reopen` verb.
- The `Bool` return matches `setLabel`'s existing contract and feeds the **shipped refusal-vs-failure
  classification**: a `false` return is a *refusal* (stale state → refresh, non-alarming alert); a
  throw is a *failure* (alert, no refresh), surfaced through the single `.alert` on `RootView` via
  `AppError` / `presentedError`.
- `Ingester.drain()` remains the only writer of everything else on a loose end.

**Undo.** Every resolve issued from the app registers with `UndoManager`, restoring the previous
`(status, resolvedAt)` pair. This is not optional polish: D2 makes rapid keyboard triage the primary
interaction, and a mis-key must be one ⌘Z away.

---

## 5. What's Next: a node with no open work is finished, not neglected

`SmartLists.compute` derives **all three** buckets from `NextQueries.ranked`, so filtering inside
`ranked` would also empty Dormant and Recently Active. And the ranking is deliberately shared with
`SessionContextQueries` "so the two never silently diverge".

One shared predicate, as the single definition:

```swift
extension NextItem {
  /// Is there anything to pick up? Dormancy alone is a "you forgot this" signal, not work — a node
  /// with no open loose ends has nothing to do, however long it has been quiet.
  public var isActionable: Bool { openLooseEnds > 0 }
}
```

Applied at exactly two places, both of which answer *what should I pick up next*:

1. `SmartLists.compute` — the `whatsNext` bucket only. `dormant` and `recentlyActive` keep listing
   finished projects, because they answer different questions.
2. `SessionContextQueries` (lines ~124 and ~150), which backs **MCP `whats_next`** and the CLI
   `pensieve next` (`Sources/pensieve/Commands/Next.swift:9`).

`NextQueries.ranked` and `groundedScore` are unchanged.

---

## 6. The triage surface (the burn-down queue)

A new sidebar bucket, **Loose Ends**.

The middle column already supports a cross-node loose-end mode: `ContentListView` has three content
modes (`.nodes`, `.looseEndsOf(UUID)`, `.reviewSuggestions`), and `.reviewSuggestions` already
renders a global list of loose ends each labeled with its node's name. **The triage bucket is that
shape with a different query** — no new pane, no new navigation model, no new window.

**Query.** `LooseEndQueries.open(database, nodeID: nil, now:)` already returns every open loose end
sorted oldest-source-first, which *is* burn-down order. It gains two scopings the global case
currently lacks:

- **active nodes only** — today the `nodeID: nil` path would include archived nodes' loose ends;
- **Focus-visible nodes only** — via the existing `NodeContextResolver.visibleNodeIDs(for:in:)`,
  consistent with every other list in the app.

**Selecting a row** opens its node in the detail pane with that loose end expanded, reusing the three
shipped `scrollTo(UUID)` landings (Spotlight tap, `pensieve://looseend/<uuid>`, ⌥⌘F result click). You
see full cited provenance before deciding, which is the whole point of deciding here rather than from
a list of summaries.

**Verbs.** Three affordances over the same two commands, so the queue is usable by pointer *and*
keyboard:

- `.swipeActions` on the row (trailing: **Done**, **Dropped**);
- the existing `.contextMenu` on `LooseEndRow`, which already hosts the 👍/👎 verbs;
- an Edit-menu command group with shortcuts, so the queue is walkable ↑↓ and closable without the
  pointer. **Exact key assignment is deliberately left to the plan** — it must not collide with list
  type-ahead or the shipped ⌘F / ⌥⌘F / ⌘G find bindings.

---

## 7. Where closed loose ends live

### 7.1 Per-node record — the local view

A `DisclosureGroup` at the foot of the detail pane's **Loose Ends** section: "Done · 12", collapsed by
default, rendered only when non-empty, each row badged `done` or `dropped`. One new read:
`LooseEndQueries.closed(database, nodeID:, now:)`.

It honours the existing `showsLooseEnds` flag, so a childless focused strand — whose loose ends live
in the *middle* column, and whose detail pane renders no Loose Ends section at all — does not grow a
stray disclosure.

**Deliberate deferral, flagged loudly.** The disclosure's contents are **not** indexed by in-node ⌘F
in v1. `NodeFindDocument`'s contract is that match order equals on-screen order, via a pre-allocated
slot per loose end — the exact invariant that broke when design slice A and in-node find merged and
the narration slot ended up on the wrong side of the loose ends. Closed ends render *after*
everything else, so appending their slots later stays compatible with that contract. This is a
deferral, not an oversight, and belongs in the plan's out-of-scope list.

### 7.2 Completed — the global view

A fifth sidebar bucket, **Completed**, over the *same* middle-column loose-end mode as §6:

- closed loose ends across all projects, **most-recently-closed first** (`resolvedAt` descending);
- each row badged `done` or `dropped`, and labeled with its node's name as `.reviewSuggestions`
  rows already are;
- Focus-scoped and active-nodes-only, like every other list;
- rows offer **reopen** and **flip done ↔ dropped**, through the same `resolve` verb.

This is what makes D1's second verb pay for itself: "what did I actually finish" is a different
artifact from "what did I give up on", and here they are visibly distinct.

---

## 8. Search and Spotlight

### 8.1 The invariant this must not break

`SearchIndexStore` filters candidates in SQL by the node-state allow-list, and `SearchHitResolver`
re-resolves each survivor against canonical — where the `.looseEnd` case currently hardcodes
`LooseEnd.isOpen`. `NodeState.searchable`'s doc comment states the rule plainly: the allow-list "is
applied twice per query on purpose … and those two applications MUST agree, or rows pass the query
and are then silently dropped." Any design that indexes closed ends without teaching the SQL filter
about them produces exactly that silent page-shrinkage.

### 8.2 What changes

- **`SearchIndexStore` schema v4** (the store is at v3 today, after the translation slice added the
  per-document `language` column): each row carries its own item status alongside the existing node
  `state` column. The two dimensions stay separate — a hit can be *archived node + open end* or
  *active node + closed end*, and the resolver needs both independently. The whole-index rebuild is
  already hash-guarded and automatic, so a schema bump costs nothing operationally.

  **Node and event rows carry `open`.** The status column is populated for every row, not just loose
  ends, so the SQL filter applies the allow-list uniformly rather than switching on `kind`. A
  kind-conditional filter is the kind of asymmetry that lets the two applications of the rule drift
  apart, which is exactly what §8.1 forbids.
- **One shared allow-list**, mirroring `NodeState.searchable` in both shape and discipline:

  ```swift
  extension LooseEndStatus {
    /// The statuses a search may surface. An allow-list, never a deny-list, so a future state can
    /// never leak in by omission. Rendered into BOTH the SQL filter and the canonical re-check.
    public static func searchable(includeClosed: Bool) -> [LooseEndStatus] {
      includeClosed ? [.open, .done, .dropped] : [.open]
    }
  }
  ```

- **`EmbeddableCorpus.gather`** indexes `done`/`dropped` ends, tagged with their status. **👎-labeled
  ends stay absent** (D7): 👎 asserts the text was never real content, so indexing it would pollute
  retrieval, whereas closed ends were real work.
- **`SearchHitResolver`**'s `.looseEnd` case replaces its hardcoded `isOpen` with the allow-list, and
  `SearchHit` carries the status so rows can badge as closed.
- **The ⌥⌘F scope bar's second option widens** to cover archived nodes *and* closed loose ends; **MCP
  `search`'s `include_archived` parameter widens in lockstep**, exactly as the archived-content work
  did. Note this conflates two orthogonal dimensions in one control — an accepted trade-off, chosen
  over adding a third scope, and worth revisiting if a third dimension ever appears.
- **The MCP JSON `SearchItem` gains the closed status**, alongside the `archived` flag it already
  carries. Calling this out explicitly because the archived-content ship shipped this exact field
  dropped at the MCP boundary, and only a final whole-branch review caught it: a widened scope whose
  result items cannot say *which* rows were widened in is a half-finished change.

**Corpus growth is bounded by 968 items.** No ranking gate is warranted: the translation slice
measured that doubling the collection size did not move English P@1 (baseline 0.382 vs treated 0.382,
McNemar p = 1.000, n = 1418), and this change is far smaller than a doubling.

### 8.3 Spotlight is deliberately not widened

`LooseEndFacts.all` (open ends in active nodes) is unchanged, so closing an end removes it from
Spotlight. **Spotlight offers no scope control**, so indexed closed items could never be filtered back
out — every OS-level search would permanently carry finished work. ⌥⌘F gains them because it *has* a
scope bar; Spotlight does not, so it does not.

---

## 9. Trust gate

**Untouched.** This changes only which real, stored rows are eligible to be shown — never what may be
said about them. No quote is edited, no provenance is re-pointed, extraction stays on-device, and
nothing here reaches `TranscriptVocabulary.injectionMarkers` or `TranscriptParser.isInjectedOrCommand`.
A closed loose end keeps its verbatim `quote` and its `sourceEventID`; §7 renders it with the same
citation machinery as an open one.

---

## 10. Out of scope (deferred, not foreclosed)

- **An MCP write tool** letting a Claude Code session close loose ends as it does the work. High
  leverage, but it is the first *agent-initiated* write into the canonical store and deserves its own
  brainstorm about authority and undo.
- **Bulk "close every open end on this node"** — plausible for the 200+ node tail; deliberately not in
  v1 because an unreviewed bulk close is indistinguishable from data loss.
- **Machine-proposed resolutions** ("a later commit suggests this is done"). Would need a grounded
  signal and a trust story; nothing here presumes it.
- **In-node ⌘F over the Done disclosure** (§7.1).
- **A `pensieve` CLI verb** for resolving. Cheap to add later; no demand today.

---

## 11. Testing

**Kit (the tested surface).**

- `LooseEndStatus` round-trip, and **on-disk byte-identity verified the way the `NodeKind` /
  `NodeState` conversion verified it** — the existing `SchemaV4`…`SchemaV11` tests must pass
  unchanged, because the stored strings, the STRICT columns and the absence of a migration for the
  type change are all unchanged. Plus a `SchemaV12` test for the additive `resolvedAt` column.
- `resolve` contract: stamps `resolvedAt` on close, clears it on reopen, returns `false` writing
  nothing for an unknown id.
- **`isOpen` unchanged under all three states** — an explicit test that `done` and `dropped` are
  excluded, and that `looseEndOpenPredicatesAgree` still holds.
- `isActionable` applied at both call sites: a node whose last open end is closed leaves What's Next
  but stays in Dormant / Recently Active.
- Corpus membership per status, including the D7 line: 👎 ends absent, closed ends present.
- **The allow-list agreement test** — SQL filter and `SearchHitResolver` agreeing for every
  `includeClosed` value. This is the direct analogue of `looseEndOpenPredicatesAgree` and is the most
  important test in this spec: it is the one that fails loudly instead of shrinking result pages
  silently.
- Triage and Completed queries: ordering, active-only, Focus scoping.

**App.** `Sources/PensieveApp/` has no unit tests by construction, so derivation stays in PensieveKit
and the surfaces are verified by `xcodebuild` build + a non-blocking smoke launch of the inner binary,
plus an eyeball carry list (triage keyboard walk, undo after a mis-key, the disclosure appearing only
when non-empty, Completed ordering, the widened scope bar, German in situ).

**Localization.** Every new string is app chrome and goes into `Localizable.xcstrings` (en + de),
authored by hand — `xcodebuild` does not populate the catalog. Loose-end text, quotes and node names
stay content and are never localized.

---

## 12. Risks

1. **The status-type change touches many call sites at once.** Mitigated by design: `isOpen` is
   unchanged, so the compiler surfaces exactly the places that compared against raw strings
   (`SalienceReviewQueries` ×2) and nothing silently keeps working with the wrong meaning.
2. **Index schema v4 plus a corpus-membership change land together.** If the allow-list agreement
   test is written *after* the corpus change, a silently-shrinking result page is the failure mode.
   The plan must order the shared allow-list and its test **before** widening the corpus.
3. **The triage queue could be a chore rather than a relief.** 968 items is a lot of decisions. The
   mitigation is that closing is never mandatory — every count is already correct for whatever
   subset has been triaged — and that oldest-first ordering surfaces the stalest items, which are
   the easiest to judge.
4. **Two loose-end-shaped sidebar buckets plus Review Suggestions is three list-like surfaces over
   the same rows.** Accepted: each answers a distinct question (what is open / what did I finish /
   was the extractor right). Worth revisiting if the sidebar starts to read as a menu of near-synonyms.
