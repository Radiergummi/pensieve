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
