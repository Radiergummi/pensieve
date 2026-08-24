# Quality backlog — opened 2026-08-24

Companion to `2026-08-24-codebase-quality-sweep.md`. Everything the fix sweep did **not** land, and
everything new that fell out while fixing. Each entry says why it is here rather than fixed.

Categories:
- **DEFERRED** — real, agreed, but too large or too design-loaded for a mechanical fix sweep.
- **DECISION NEEDED** — the fix requires a call only you can make.
- **NEW** — found while fixing, not in the original sweep.
- **CONTRACT CHANGE** — landed, but it changes something externally visible; flagged so it is not a surprise.

---

## DECISION NEEDED

### Q1. Emoji and symbol search is impossible, not merely broken
The search index uses `tokenize = 'unicode61 remove_diacritics 2'` with no `tokenchars`, so Unicode
So/Sm (emoji, `—`, `*`) are separators. Measured against a real FTS5 table: a document
`'a bug 🐛 here'` produces the vocabulary `[a, bug, here]` — the emoji is not stored at all, so
`MATCH '"🐛"'` is 0 rows *by construction*. The sweep fix (2.3) makes such a query return nil
("nothing searchable was typed") instead of a query guaranteed to match nothing, and stops it
zeroing real terms typed alongside it. But it does not make emoji *findable*.
**Decision:** accept that (emoji in captured text are unsearchable), or add `tokenchars` to all three
FTS5 tables — which needs a schema-version bump and a **full reindex**, and would change ranking.
Out of scope for a fix sweep; flagged rather than chosen.

-> what would be the effect of either, long term?

### Q2. What should an unparseable spool timestamp do? (finding 2.36)
`CaptureSpool.pending()` substitutes `Date()` when `ts` will not parse. The substitution is now
logged rather than silent, and it was left in place deliberately — that value becomes the event's
`occurredAt` (`Ingester.swift:120`, `:175`) and is compared against the absent-transcript grace
period (`:138`), so a sentinel like `.distantPast` would both misdate the work and silently drop the
row. But "now" does make a corrupt row look like it just happened.
**Decision:** leave it (logged), quarantine such rows into a dead-letter state, or reject them at
`append` time so a malformed timestamp can never enter the spool. Rejecting at append touches the
sacred path, which is why the fix sweep did not choose.

-> rejecting at append time sounds like the correct thing to do here, if it doesn't introduce overhead.

### Q4. Merge the 9 phantom project nodes (finding 2.1)
The code path that minted them is fixed, but the existing rows are still in the live store: 9 phantom
nodes holding ~42 events that belong to `Pensieve`, plus ~30 more splitting `laravel-openapi`, and
one node literally named `/`. `pensieve group` merges nodes and exists for exactly this, but choosing
the primaries and the mapping is a judgement call over your own data.
**Decision:** which nodes merge into which. A `pensieve scan`-style report of sources whose key is
not a `.git` common-dir would make the list; that report does not exist yet.

## CONTRACT CHANGES landed

- **`pensieve track` now refuses a non-git path** with a `ValidationError` instead of creating a node
  keyed by the raw directory. That key could never match what a git hook later produces, which is
  precisely how `…/pensieve` became the node "Pensieve Signal Viewer" alongside `…/pensieve/.git` →
  "Pensieve" (641 events). Registering a repo is the command's whole job, so refusing is the honest
  answer; the previous behaviour silently created a permanent duplicate.
- **A search query with no tokenizable content now returns no query rather than an empty-matching
  one.** `FTSQueryBuilder.build("* ")`, `("— ")`, `("🐛 ")` now return nil. Callers already handle nil
  (it is what an empty box returns), and this is what stops one punctuation word zeroing the whole
  conjunction. Two existing tests asserted the old shapes and were updated with the measurement that
  justifies it.
- **`PensievePaths.narrationCacheURL(in:)` was removed.** It had no production caller once
  `narrationCacheURL()` started following `PENSIEVE_DB`; its one test now asserts the real seam
  (`narrationCacheURL(storeOverride:support:)`). Removing an orphan my own change created, per the
  house rule; no external caller existed.

## NEW findings

- **`Package.resolved` churns on every app build** (documented in CLAUDE.md) and also on
  `swift test`. Harmless, but it means `git status` is never clean mid-sweep; discarded each time
  rather than committed, as CLAUDE.md instructs.
- **`Tests/PensieveKitTests/PensievePathsTests.swift` still asserts `semantic-index.sqlite`**
  (line ~26). That is the removed vector engine's sidecar. It is on the dead-code list below; the
  assertion is harmless but documents an engine that no longer exists.

## DEFERRED

*(nothing yet — waves B onward will populate this)*


## Dead code — still present, deletion is your call

Carried over from the sweep verbatim; the fix sweep deliberately did not delete any of it.

- `Query/PassageProvenance.window(session:passage:event:radius:)` — zero callers, including tests
- `Query/NodeFindDocument.text(for:)` — tests only
- `Query/MonitorSnapshot.gather(canonicalURL:spoolURL:now:activeWithin:)` — tests only
- `Query/LooseEndCommands.corpus` — tests only
- `SmartLists.compute`'s `dormantAfterDays` / `activeWithinDays` parameters — never passed non-default
- `Eval/Judge.labelGrounding`, `Eval/Agreement.rate`, `CellSample.estInput/OutputTokens`,
  `JudgeVerdict.dimensionScores`, the unreachable `judgeAgreement` report branch — the whole
  judge-calibration loop
- `Intelligence/SalienceClassifier` and its provider method — deliberately unwired
- `LLM/FoundationModelsProbe.roundTrip`
- `Intelligence/SummaryBuilder.assembleFacts`
- `Translation/TranslationStore.pruneKeeping`
- `Log.semantic`
- a `semantic-index.sqlite` expectation still in the tests
- the legacy `DaemonInstaller` path

## Notes carried from the fix sweep

- **`TranslationStore.pruneKeeping` is field-agnostic while its only live text producer excludes
  narration** (finding 1.38's sibling). It is currently dead code, so nothing is broken — but if it
  is ever wired up, it will delete rows for any field the producer does not enumerate. Left in place
  (dead code is not deleted by this sweep); noted so wiring it is not done blindly.
- **The translation cache key deliberately has no producer token.** `NarrationCacheKey` includes one
  because cloud and on-device narration differ sharply. On-device translation is the only translator,
  so the producer is constant; a `translationRule` version token was added instead, which is the half
  that was genuinely missing. If a second translator is ever added, the key needs the producer too.
- **Adding `translationRule` to the cache key invalidates every existing cached translation** on this
  machine. Disposable by design — they re-translate on demand — but the first render after this lands
  will do real work. `pruneKeeping` reclaims the stranded rows.
- **`docs/observability.md` gains a `translation` log category.** Translation failures previously
  logged under `search`, so a translation outage looked like a retrieval problem.

## Field evidence found during the fix sweep

**Finding 2.7 (the FSEvents busy-loop) is not hypothetical — it is in your MetricKit payloads.**

`~/Library/Logs/Pensieve/diagnostics/` holds two **CPU-exception** payloads from 2026-08-22, 75
minutes apart (`07:03:18Z`, `08:18:00Z`). MetricKit raises these only on sustained CPU use. Both:

| | 07:03 | 08:18 |
|---|---|---|
| `totalCPUTime` / `totalSampledTime` | 90 s / 175 s | 90 s / 154 s |
| effective sustained CPU | ~51% | ~58% |
| top binaries in the sampled stacks | `Pensieve.debug.dylib` (736), `CoreFoundation` (349), `libsqlite3.dylib` (167), `libswiftDispatch` (136) | `Pensieve.debug.dylib` (644), `CoreFoundation` (307), `SwiftUICore` (164), `libsqlite3.dylib` (118) |

The 08:18 payload additionally carries **`FSEvents` frames inside the sampled call stack**, which ties
the CPU burn directly to FSEvents callbacks. That is precisely the mechanism 2.7 describes:
`refreshFromWatch` opens fresh store connections *in the directory the watcher watches*, the
`-wal`/`-shm` churn re-fires the watch, and each turn costs a full main-actor `refresh()`, a
whole-corpus gather, and a Spotlight delete-and-reindex — SQLite- and SwiftUI-heavy work, exactly the
binaries that dominate. `SwiftUICore` high in the second payload matches repeated view invalidation
from repeated `refresh()`.

Consequences for planning:
- 2.7's confidence in the report is upgraded from "likely that the loop fires today" to **observed**.
- It should be treated as the top app-target fix, above its original ranking.
- Payloads are **unsymbolized** (address-only, `offsetIntoBinaryTextSegment`), so the exact function
  cannot be named from them — the binary mix and the FSEvents frames are the evidence.
- Recorded on macOS 26.6.1 (25G76), arm64e, against a `.debug` build, so absolute CPU numbers are not
  release-representative; the *loop* is the finding, not the constant factor.

## DEFERRED — needs a product call

### D1. A missing source event still yields no "unavailable" provenance entry (finding 2.26, second half)
The swallowed read failure is now logged and the per-id queries are batched, but the asymmetry
remains: a missing event produces no entry at all rather than an explicit "unavailable" one.
`ProvenanceContext.sourceEvent` is non-optional, the case is schema-unreachable today
(`NOT NULL REFERENCES … ON DELETE CASCADE`), and making it optional would degrade
`SessionContextQueries`' non-optional `sessionOccurredAt`. **Decision:** leave it relying on the
schema guarantee, or make the type admit absence and pay the downstream cost.

### D2. The fourth "no events" rule is a type-level split, not a duplication (finding 1.4)
Three of the four derivations were folded onto `NodeFactsQueries.activity`. The fourth cannot be
without a visible behaviour change: `NextItem` and `BriefingCard` declare `lastActivityAt`
**non-optional** — each documenting why — so they must skip a node with no events, whereas
`NodeFacts` makes it optional and reports `daysDormant: 0`. **Decision:** change those two public
types to admit absence (and decide what the UI shows), or accept two documented rules.
The fix sweep deliberately did not force this.

### D3. `Log` has no `app` category inside PensieveKit
`CLAUDE.md` lists `app` as a category, but that is the app target's own `AppLog`; the Kit's `Log`
enum has no such case. Kit code that wanted it (the monitor heartbeat, provenance read failures) used
`sync` and `search` instead, following `PassageQueries`' precedent. **Decision:** add `Log.app` to the
Kit, or accept that Kit-side app-ish logging borrows a neighbouring category.

## More NEW findings (from the fix waves)

- **The `SessionContextQueries.bundle` narration tests were vacuous** and are now covered. Both
  `bundleServesCachedProseWithoutABuilder` and `bundleNarratesOnMissAndWritesThrough` passed under the
  mutation that restored `recentLimit` to 8 — because each fixture holds fewer events than the window
  under test, so the window never bound anything. **The pattern is the lesson**: a fixture smaller
  than the quantity under test cannot detect a change to it. Worth grepping for elsewhere.
- **`NodeFactsQueries.rowFacts` now also returns `(nil, 0)` for a node holding only CLOSED loose
  ends.** Indistinguishable from a miss to every caller by construction, and documented rather than
  special-cased — recorded here in case a future caller wants to tell the two apart.
- **`isolation: "worktree"` branches from `main`, not from the current branch.** All four fix agents
  were created at `b7dc69a` — the pre-sweep tip — rather than the briefed base, and each had to
  fast-forward to `638bfe5` before it could work (the shared helpers its tasks depended on did not
  exist at `b7dc69a`). The brief's "confirm HEAD, stop if wrong" guard is what caught it. Any future
  worktree fan-out from a feature branch needs the same check.
- **Five parallel SwiftPM worktrees exhausted the disk** (3.5–5.9 GB of `.build` each; the volume hit
  100%, and one `make all` died with `ENOSPC`). Worktree isolation is not free — budget ~4 GB per
  agent, or serialize.

## DEFERRED (continued)

### D4. The `EmbeddableItem` / `EmbeddableCorpus` rename needs one owner (finding 4.2)
Declined during the sweep, correctly. The report claimed 2 references outside `Search/`; the real
count is **100 across 22 files**, five outside any single agent's ownership
(`Translation/TranslatableCorpus.swift`, `Translation/TranslationStore.swift`,
`Intelligence/SummaryBuilder.swift`, `Query/SearchHitResolver.swift`,
`PensieveApp/AppModel+Translation.swift`). A `typealias` bridge would leave five production files on
the old name — two names for one type. **Decision:** do the whole rename to
`SearchDocument`/`SearchCorpus` (including the file rename) in one commit, or keep the vector-era
names and drop the finding. Cosmetic either way; no wire format or `CodingKeys` involved.

### D5. Should `pensieve eval` validate its own judge? (finding 2.24)
`Judge.labelGrounding`, `Agreement.rate` and `TaskScorecard.judgeAgreement` are complete and never
invoked, so the judge every rubric score depends on is unvalidated. Deliberately not wired — it is a
product decision. **Decision:** should a sweep spend a judge pass per gold-labelled extraction item to
compute judge↔human agreement, and what agreement floor should invalidate the sweep?

### D6. SearchHitResolver doc comment — DONE 2026-08-24
Doc comment only; the engine was removed. One-line fix, left because the file belonged to another
agent's scope at the time.

### D7. Two files are at their structural ceiling
`EmbeddableCorpus.gather` hit 51 code lines against a 50-line limit during the sweep (an
`appendEventDocuments` extraction fixed it), and `Search/SearchIndexStore.swift` sat at exactly 400
lines — the file cap — and needed comment trimming to absorb its changes. **The next change to either
forces a split.** Worth choosing the seam deliberately rather than under lint pressure.

### D8. decodeFrozenItem restates the corpus task folders — DONE 2026-08-24
`CorpusBuilder.taskFolders` is now the single list, but `decodeFrozenItem`'s `switch` still spells the
three names with `default: return nil`, so a folder added without a decode case loads nothing
silently. Not statically checkable as written; noted in a comment.

### D9. Eval.Gold keys off the literal "extraction" — DONE 2026-08-24
Harmless today — it validates a user-supplied subcommand argument, not a trust gate — but it is the
same literal finding 1.17 was about, and would silently stop matching a renamed task id.

## More NEW findings (waves B and C)

- **`SSH_AUTH_SOCK` is not inherited by subagents**, so every agent-authored commit in this sweep is
  UNSIGNED regardless of whether the agent is running. This is a new cause for the existing
  commit-signing note: the subagent environment, not the machine. The whole branch needs one linear
  re-sign pass before it reaches `main` (see Q3).
- **`.build/index-build` is ~2.1 GB per worktree** — the SourceKit index store, which `swift build`
  and `swift test` do not need. It is the bulk of a worktree's 3.5 GB. A `make clean` variant that
  drops only `index-build`, or excluding it in worktrees, would make parallel fan-out affordable.
- **Coverage gaps left honestly untested rather than papered over:** the 120 s Foundation Models cap
  (asserting it needs a 120 s wall-clock wait or a clock injected into `LanguageModelSession` — a
  design change), and the two `.attemptedEmpty` write-failure paths (forcing `database.write` to fail
  needs a deliberately broken writer the harness has no facility for). Both were read-verified.
- **`ExtractionRunnerTests.swift` is at 395 of the 400-line cap** and all its helpers are `private`,
  so a sibling test file cannot reuse them. Finding 2.2's tests went into a new
  `ExtractionWatermarkTests.swift` with a duplicated seeding helper. Promoting those five helpers to a
  shared `ExtractionTestSupport.swift` would avoid a third copy.
- **A real hole in `TextQuality`'s code-fence strip**, found while routing finding 1.13: the
  `NodeDescriber` copy removed the backticks but not the language tag, so a fenced JSON array became
  the word `json` followed by an array and read as prose. Only `isProseNotStructured` handled the tag.
  Now one shared `strippingCodeFence`. This is a live path — descriptions come from the same providers
  that produced the 139 JSON-array "recaps" the code comments already record.

## DEFERRED (from the ingest/capture wave)

### D10. Finish finding 2.10 — or do not touch it (needs two files together)
The *visibility* half landed: a permanently-undecodable spool row now says so. The "stop
re-attempting it" half was implemented, **caught breaking `StoreRelocator`, and reverted** — and the
reason is worth keeping. `recoverPendingRows` infers "rows may still be stranded" from
`pendingCount() != 0` and refuses to recycle the old folder on exactly that basis. Marking a poison
row ingested would make a relocation report a clean migration and then **delete the folder holding
the only copy of the data**. `anUnrecoverableRowBlocksRecycling` is what caught it.
"Stop retrying this row" and "nothing is stranded" are two different facts and the spool stores one.
**Decision:** add a `failed`/`attempts` column to `CaptureSpool` *and* teach `StoreRelocator` to
distinguish discarded from recovered, in one change — or leave the row retrying forever, which is
merely noisy rather than dangerous.

### D11. Where should the degenerate-root guard live? (finding 1.12)
One guard now sits in `Ingester.identityKey(forHookPath:)`, covering both git capture kinds. Moving it
into `ProjectResolver.resolve` would additionally cover `pensieve track` and `SourceScanner.accept` —
a true chokepoint — but it changes `accept`'s batch semantics. **Decision:** chokepoint or per-caller.

### D12. `Event.kind` / `Source.kind` are still raw `String` columns (finding 4.1)
Assessed and deliberately not done: converting them needs a migration-compatibility review across
`Query/`, `Search/`, `Widget/` and the app target simultaneously. A genuine hand-off, not a skip.

### D13. `strandNameCap` is not monotonic
A strand past the per-drain naming cap keeps its branch name with no marker to revisit it, so it is
never renamed later. Documented in the code as an accepted cost. A retry marker is a product decision.

### D14. 35 test sites still build temp paths by hand
`tempURL` now roots everything under one per-process directory removed at `atexit`, and a full suite
run leaves **zero** test-prefixed artifacts (measured; ~25,000 had accumulated before). But 35 sites
use `FileManager.default.temporaryDirectory` / `NSTemporaryDirectory()` directly — concentrated in
`StoreRelocator*Tests`, `StoreOpenTests`, `PassageStoreTests`, `SyncRunnerTests`,
`TranscriptDiscoveryTests`, `CLIToolInstallerTests` — and are not covered. Routing them through
`tempURL` is mechanical but touches 20 files; not done during the sweep to keep the diff reviewable.

## Test-quality wave — one finding withdrawn

### Finding 8.11 is not fixable by a test. Withdrawn.
`NarrationCacheKeyRuleTests` was flagged for pinning the rule token's *presence* while nothing pins
it being *bumped*. On inspection the test is already stronger than the report credited: it asserts
`key != "\(id)|none|local"`, the exact pre-rule format, which proves every entry written before the
rule existed now misses rather than being silently reused.
The residual gap — "someone edits the fact-sheet rule and forgets to bump `factSheetRule`" — cannot
be detected by a test without hashing the fact-sheet-producing code, which would fail on every
unrelated edit and teach people to bump the token meaninglessly. The real guard is the doc comment on
`factSheetRule`, which already states the obligation. **No change made, deliberately.**

### Also corrected: finding 7 of the app wave (`"Briefing"`)
`"Briefing"` is not merely missing a catalog key — it is an explicit `allowedMissingKeys: ["Briefing"]`
entry in `CatalogCoverageTests`, which is why the suite passes today. Adding the key therefore has a
second half: removing the allowlist entry, or the allowlist keeps hiding the next regression.

## Closed while waiting on the last two waves (2026-08-24)

- **D6 done.** `SearchHitResolver`'s header no longer claims a live vector engine. Rewritten to say
  why the type still earns its place: text search, the file-path probe and passage search each pick
  and highlight candidates differently and must still agree on what may surface.
- **D8 done, and upgraded from a comment to a compile error.** `CorpusBuilder.Task` is now a
  `String`-raw-valued `CaseIterable` enum; `decodeFrozenItem` switches over it exhaustively with no
  `default:`. Verified by adding a fourth case and building: `error: switch must be exhaustive`.
  Previously a new task compiled, wrote its items to disk, loaded **zero** of them back, and
  `TaskRegistry.consistency` still called the registry consistent because the folder *was* listed.
- **D9 done.** `Eval.Gold` compares against `CorpusBuilder.Task.extraction.rawValue`.
- **App Group identifier (finding 1.35) done.** The id lives in Swift once and in three
  `.entitlements` plists that cannot reference it, so the enforcement point is a test:
  `everyEntitlementsFileDeclaresTheAppGroupSwiftUses`. Mutation-verified — changing the Swift constant
  fails against all three files. This failure mode was worth pinning because it is silent and
  one-sided: every unsandboxed process constructs the container path directly and keeps working,
  while only the sandboxed widget asks the system using the *entitlement's* string, so the app
  publishes to one path and the widget reads another with nothing logged as an error.

## Q4 decision data — the phantom nodes, measured

The backlog previously said this list "does not exist yet". It does now. Read-only queries against
`~/Library/Application Support/Pensieve/pensieve.sqlite`, 2026-08-24. **No data was modified.**

Store totals: **198 sources** (167 `gitRepo`), **306 nodes**, **3,110 events**.
**42 of 167 git sources have a key that is not a `.git` common-dir** — every one of them a node that
should not exist.

| origin repo | phantom nodes | events stranded | merge target | target node id |
|---|---|---|---|---|
| pensieve | 4 | 37 | **Pensieve** (`…/pensieve/.git`, 641 events) | `682476ee-467b-44b2-b6b2-20fd10ca4871` |
| laravel-openapi | 34 | 52 | **Radiergummi Laravel OpenAPI** (`…/laravel-openapi/.git`, 239 events) | `b716032a-4bb6-42fe-9764-ed1d192d6781` |
| other | 4 | 4 | — (inspect individually) | — |

The mapping is mechanical: a source key containing `/pensieve/` merges into the Pensieve node, one
containing `/laravel-openapi/` into the laravel-openapi node. Both `.claude/worktrees/…` paths and
`/private/tmp/claude-501/…/scratchpad/wt-…` paths are covered — the latter are agent scratch
worktrees, which is why nodes like "Weight Transfer Tool" (from `wt-550`) and "Web Trace Viewer 570"
(from `wt-570`) exist at all. `pensieve group <primary> <absorbed…>` already does exactly this merge.

Two extra nodes worth deciding separately:

- **`Pensieve Signal Viewer`** — source `/Users/moritz/Projects/pensieve` (no `.git`), 1 event. This
  is finding 1.2's live proof, sitting beside the real `Pensieve` node. Merge it.
- **`/`** — source `/`, **427 events**, i.e. 14% of the entire store. All `cc.session`, and **all from
  2026-07-09 to 2026-07-10** with **zero in the last 7 days**. So `ProjectResolver.isDegenerateRoot`
  is working: this is historical residue from before that guard existed, not an ongoing leak. It is
  also by far the largest single cleanup available, and unlike the others its events are not
  re-attributable from the source key (cwd `/` says nothing about which project they belong to) —
  the honest options are archive it or delete it, not merge it.
  **Decision: archive, delete, or leave.** Nothing surfaces it today except node lists, since a
  degenerate root has no meaningful recall value.

**Recommended sequence, once you decide:** merge the 38 pensieve/laravel-openapi phantoms with
`pensieve group` (mechanical, reversible only by re-ingest, so do it after a store backup), inspect
the 4 "other" nodes by hand, then decide `/` separately. Doing this *after* the fix waves land is
correct — the code path that mints them is fixed, so the list cannot grow while you decide.

## CONTRACT CHANGES (continued)

- **MCP's advertised resource URI changed from `pensieve://smartlist/whats-next` to
  `pensieve://smartlist/whatsNext`**, and the old spelling is now rejected with
  `-32602 Invalid params: unknown resource`. This is the correct direction — the old string was
  unparseable by `DeepLink`, the grammar every other surface (app, widget, Spotlight) uses, so a
  client that handed the advertised URI back got nothing. But **any MCP client that hardcoded the old
  string breaks**. Verified in both directions against the built server.
- **Eight CLI commands now exit non-zero on failure** (`status`, `checkpoint`, `looseends`, `rename`,
  `retype`, `nest`, `group`, `add-node`, plus `ingest`'s extraction failure): 64 + usage for
  argument-shape errors, 1 for a well-formed but unsatisfiable request, both on stderr.
  **Hook-invoked commands deliberately still exit 0** — `prime`, `capture-*`, and `sync` — because a
  non-zero exit from a SessionStart or git hook is exactly what the capture path forbids. Each
  caller was checked before the decision.

## NEW findings (continued)

- **`Commands/Scan.swift` prints `setup-failed` rows to stdout and exits 0** — the same defect class
  as the eight fixed above, but it is a *partial* success (e.g. 9 of 10 sources registered), so
  whether that should be non-zero is a product decision. **Deliberately left alone.**
- **A vacuous test was deleted rather than patched.** `anIntegerArgumentWrittenAsAFloatStillDecodes`
  stayed green when the `Double`→`Int` fallback it existed to cover was removed — `JSONDecoder`
  already decodes `3.0` into `Int`. The fallback was dead speculative code, so `MCPArgument.integer`
  was removed entirely and the test dropped. Worth remembering as a shape: a test guarding
  speculative code passes whether or not the code is there.
