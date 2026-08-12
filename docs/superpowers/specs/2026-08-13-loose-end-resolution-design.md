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
   search corpus and Spotlight. **Adding states to `status` propagates through all of them without
   changing the predicate's meaning**, because anything that is not `open` already fails it. The
   predicate's *text* does change by one word — see §3.3, which corrects an earlier draft of this
   spec that claimed the file was untouched.

3. **The resurrection guard is already built.** `ExtractionRunner.insertVerifiedLooseEnds` dedups
   proposed loose ends against *every* existing loose end for the node, "regardless of status", with
   a comment stating that re-extraction "must not resurrect a RESOLVED loose end the user already
   dismissed". Closing one makes it stay closed; nothing to build. **One caveat, accepted:** the
   dedup is scoped to `event.nodeID`, so if strand auto-birth repoints a loose end to a new node, a
   later re-extraction on the *origin* node can re-insert that quote as `open`. Narrow, self-healing
   (close it again), and not worth a cross-node scan on the extraction path.

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
| D4 | Closing the last end drops a node from **What's Next only**, via a shared `isActionable` predicate — **but "no open ends" alone is not the test**, see §5 | Filtering inside `NextQueries.ranked` (would also empty Dormant/Recently Active); reworking `groundedScore` (a deliberate ADHD affordance); the naive `openLooseEnds > 0`, which measurement showed removes 130 of 162 nodes on day one |
| D9 | **Review Suggestions stops filtering on `status`** — a closed loose end is still labellable | Leaving it: triage becomes the default surface, and every item burned down destroys a training example that 846 of 968 items have not yet produced |
| D10 | **Per-node bulk close is in v1**, with confirmation and undo | Deferring it: 288 open ends sit on one node, and "indistinguishable from data loss" overstates a verb that `resolve(status: .open)` reverses |
| D11 | The triage queue leads with **suggested-salient**, then oldest | Pure oldest-first: measured, the first 200 oldest come from 13 nodes and 149 from three, so the queue would read as "grind through three projects" |
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

### 3.3 `isOpen` changes by one word, and its meaning not at all

**Correction (adversarial review, 2026-08-13).** An earlier draft of this spec claimed `isOpen` was
never edited, and made that the load-bearing invariant. **That claim was false.** The predicate reads
`columns.status.eq("open") && columns.label.neq("noise")` (`LooseEnd.swift:32`), and a raw `"open"`
literal stops typechecking the moment `status` is an enum: the column's `QueryValue` becomes
`LooseEndStatus`, and `LooseEndStatus` is not `ExpressibleByStringLiteral`. It must become:

```swift
    columns.status.eq(LooseEndStatus.open) && columns.label.neq("noise")
```

— the same one-word change every `NodeState` / `NodeKind` comparison in the tree already carries.

**The property that actually holds, and that the plan must verify, is semantic:** `isOpen` still
means exactly what it meant, `openSQLPredicate` (raw SQL) is genuinely untouched,
`looseEndOpenPredicatesAgree` still passes, and **no consumer of either predicate needs any change**.
That is the reason the feature is small — not the absence of a diff. An implementation that finds
itself changing what `isOpen` *selects* has gone wrong; one that retypes its literal has not.

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

**"No open loose ends" is NOT the test, and getting this wrong would gut the feature.** Measured on
the live store: 162 active nodes carry events (today's What's Next universe) and only **32** have any
open loose end. A naive `openLooseEnds > 0` removes 130 nodes the day it ships — and **123 of those
have never had a single `cc.session` event**. Loose ends are mined only from Claude Code transcripts,
so a git-only node can never satisfy that predicate however much work goes into it. Those 130 would
vanish permanently from What's Next, MCP `whats_next`, `pensieve next` and the menu bar, and the
headline number would collapse for a reason that has nothing to do with anything being finished.

*Finished* is the narrower claim this feature can actually make: **it had open loose ends, and they
are all closed.** A node that never produced one is not finished — it is unmeasured, and unmeasured
work must keep showing up.

```swift
extension NextItem {
  /// Is there anything here to pick up? True when open work remains, and ALSO true when this node
  /// has never produced a loose end at all — 123 of this store's 162 active nodes are git-only, and
  /// loose ends come only from Claude Code transcripts, so for them "no open ends" means "never
  /// measured", not "finished". Treating those as done would empty the list without anyone
  /// finishing anything.
  ///
  /// Not actionable is therefore the narrow, earned case: `openLooseEnds == 0 && closedLooseEnds > 0`.
  public var isActionable: Bool { openLooseEnds > 0 || closedLooseEnds == 0 }
}
```

`NextItem` grows `closedLooseEnds: Int`, counted in `NextQueries.ranked` beside the open count.
`ranked` keeps returning every node — the filter is applied by its callers, never inside it, so
Dormant and Recently Active are unaffected.

Applied at exactly **three** places, all of which answer *what should I pick up next*:

1. `SmartLists.compute` — the `whatsNext` bucket only.
2. `SessionContextQueries.rankedContext` (`SessionContextQueries.swift:150`), which backs **MCP
   `whats_next`**. Its other `groundedScore` use at line ~124 is inside `bundle` (a single node's
   `project_context`) and is **not** a call site for this predicate.
3. `Sources/pensieve/Commands/Next.swift:9`, which calls `NextQueries.ranked` directly rather than
   going through `SessionContextQueries`.

`groundedScore` is unchanged.

---

## 6. The triage surface (the burn-down queue)

A new sidebar bucket, **Loose Ends**.

The middle column already supports a cross-node loose-end mode: `ContentListView` has three content
modes (`.nodes`, `.looseEndsOf(UUID)`, `.reviewSuggestions`), and `.reviewSuggestions` already
renders a global list of loose ends each labeled with its node's name. **The triage bucket is that
shape with a different query** — no new pane, no new navigation model, no new window.

**Query.** A cross-node feed over open loose ends, with three scopings the existing `nodeID: nil`
path lacks:

- **active nodes only** — today it would include archived nodes' loose ends;
- **Focus-visible nodes only** — via the existing `NodeContextResolver.visibleNodeIDs(for:in:)`,
  consistent with every other list in the app;
- **ordered suggested-salient first, then oldest source** — the ordering `SalienceReviewQueries`
  already uses, for the reason measurement gave: every loose end here is 0–2 months old, and the
  first 200 in pure oldest-first order come from 13 nodes with **149 of them from three projects**.
  Pure oldest-first is not "stalest first" on this corpus; it is "grind through Matchory Web App,
  then two Radiergummi repos". Leading with the items a machine already thinks are real makes the
  scarce positives arrive first and spreads the queue across projects.

**Selecting a row** opens its node in the detail pane with that loose end expanded, reusing the three
shipped `scrollTo(UUID)` landings (Spotlight tap, `pensieve://looseend/<uuid>`, ⌥⌘F result click). You
see full cited provenance before deciding, which is the whole point of deciding here rather than from
a list of summaries.

**Verbs.** Three affordances over the same two commands, so the queue is usable by pointer *and*
keyboard:

- `.swipeActions` on the row (trailing: **Done**, **Dropped**);
- the existing `.contextMenu` on `LooseEndRow`, which already hosts the 👍/👎 verbs;
- **an Edit-menu command group with real shortcuts** — `⌘⏎` Mark as Done, `⌥⌘⏎` Drop, `⇧⌘⏎` Reopen —
  acting on the queue's selected row, so it is walkable ↑↓ and closable without the pointer. These
  avoid list type-ahead (no bare letters) and the shipped ⌘F / ⌥⌘F / ⌘G find bindings. **This is not
  optional polish:** it is the difference between a queue and a chore at 968 items, and the undo
  requirement below is justified by "a mis-key must be one ⌘Z away", which presumes a key exists.
- **Per-node bulk close** (D10): "Close all open ends" in a node's context menu, behind a
  `.confirmationDialog` naming the count, registering **one** undo that reopens exactly the set it
  closed. 288 open ends sit on a single node; item-by-item is not a path for that tail, and the verb
  is reversible, so the destructive framing that first deferred it does not hold.

---

## 7. Where closed loose ends live

### 7.1 Per-node record — the local view

A `DisclosureGroup` reading "Done · 12", collapsed by default, rendered only when non-empty, each row
badged `done` or `dropped`. One new read: `LooseEndQueries.closed(database, nodeID:, now:)`, which —
like the Completed feed — **excludes 👎-labelled ends**: an item the user declared was never a loose
end has no place in a list they read as a record of their own work, and 98 rows carry that label
today.

**It renders BELOW Recent Activity, at the very bottom of the pane** — not inside the Loose Ends
section. An earlier draft placed it there and justified deferring find-indexing with "closed ends
render after everything else", which was simply false: the recap and Recent Activity both follow the
Loose Ends section. Putting the disclosure last makes that sentence true, which is what keeps the
deferral below honest.

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

- closed loose ends across all projects, **most-recently-closed first** (`resolvedAt` descending),
  **excluding 👎-labelled ends** for the reason §7.1 gives;
- each row badged `done` or `dropped`, and labeled with its node's name as `.reviewSuggestions`
  rows already are;
- Focus-scoped and active-nodes-only, like every other list;
- rows offer **reopen** and **flip done ↔ dropped**, through the same `resolve` verb.

This is what makes D1's second verb pay for itself: "what did I actually finish" is a different
artifact from "what did I give up on", and here they are visibly distinct.

---

### 7.3 Review Suggestions stops filtering on `status` (D9)

`SalienceReviewQueries.pending` / `pendingCount` filter `status = 'open'`. Left alone, this feature
would quietly destroy the salience training corpus: triage becomes the default surface, and every
item closed there leaves Review Suggestions **forever** with its 👍/👎 never collected — 846 of 968
items are still unlabeled. The two axes are orthogonal in the model but were about to become
*competitive in the workflow*.

The `status` predicate is therefore **removed** from both functions. A closed loose end is still
labellable: "was the extractor right" remains a meaningful question after "is this handled" has been
answered, and the corpus (`LooseEndCommands.corpus`, which reads confirmed labels only) is unaffected
by status either way.

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

### 8.4 The index must not lag the write, and must not cost a rebuild per close

Two consequences the first draft missed, both found by review, both mandatory:

**The resolve write must refresh the index.** `AppModel.refresh()` does **not** call
`syncSearchIndexes()` — only `drainThenRefresh` (launch, ⌘R) and `refreshFromWatch` do. A close that
only calls `refresh()` therefore leaves the index carrying `item_status = 'open'`: the row passes the
SQL filter under the default scope, the resolver drops it on the canonical re-check, and because
`LIMIT` is applied in SQL the page **silently shrinks** — the precise failure §8.1 exists to prevent,
reintroduced through the back door. Resolution must refresh the index, and the in-flight guard on
`syncSearchIndexes` (`guard !isSyncingIndexes else { return }`) must **re-run rather than drop** a
coalesced request, or rapid triage will reliably leave the index behind.

**A close must not trigger a whole-corpus rebuild.** Folding `status` into `corpusHash` (§8.2) is
correct and necessary, but on its own it means every one of 968 closes rebuilds ~3,700 FTS5 documents
— every node, every event (with a JSON decode each for `changedFiles`), every loose end. `item_status`
is an `UNINDEXED` column, so the write path instead issues a **targeted
`UPDATE documents SET item_status = ? WHERE item_id = ?`**. The stored corpus hash is deliberately
left stale by that update, so the next daemon or launch sync performs exactly **one** honest full
rebuild rather than nine hundred.

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
- **Cross-node bulk close** ("close everything older than N months"). Per-node bulk close is in v1
  (D10); a global one is a different, riskier verb and stays out.
- **Machine-proposed resolutions** ("a later commit suggests this is done"). Would need a grounded
  signal and a trust story; nothing here presumes it.
- **In-node ⌘F over the Done disclosure** (§7.1).
- **A `pensieve` CLI verb** for resolving. Cheap to add later; no demand today.

---

## 11. Testing

**Kit (the tested surface).**

- `LooseEndStatus` round-trip, and **on-disk byte-identity verified the way the `NodeKind` /
  `NodeState` conversion verified it** — the existing schema tests (`SchemaTests`, `SchemaV3`,
  `SchemaV4`, `SchemaV7`–`SchemaV11`; there is no `SchemaV5`/`SchemaV6` suite) must pass unchanged,
  because the stored strings, the STRICT columns and the absence of a migration for the type change
  are all unchanged. Plus a `SchemaV12` test for the additive `resolvedAt` column.
- **`isActionable` measured, not just asserted**: a test that a node with events, zero loose ends and
  no closed ends **stays** in What's Next (the 123-node case), beside one that a node whose only end
  was closed leaves it.
- **Index freshness after a close** (§8.4): resolve a loose end *after* an index rebuild and assert
  the default-scope result page does not shrink. Task-level agreement tests that build index and
  canonical in lockstep cannot catch this, which is how the first draft missed it.
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
5. **`.swipeActions` is inert in the detail pane.** `DetailView` renders loose ends in a `VStack`
   inside a `ScrollView`, not a `List`, so swipe works only in the middle-column feeds. Stated here
   so it is not later read as a regression; the context menu and the keyboard verbs cover that pane.

## 13. Why not just archive the node?

Review raised this and it deserves an answer in writing: **Archive already removes a node from every
count and ranking** (`NextQueries.ranked` filters `state == .active`), at a cost of one action per
finished project rather than 968. If the only goal were a shorter list, archiving would win outright.

The goals differ. Archiving asserts *this whole area of work is over* and hides it wholesale —
including work that is still live inside it. Resolution asserts *this specific item is handled* while
the project keeps running, which is the common case here: the store's open ends are concentrated on
six nodes that are all active. Archive is the right verb for a finished project and stays exactly as
it is; resolution is the only verb available for a finished *item*. They compose — a project whose
ends are all closed is a good archive candidate, and now it is visibly one.
