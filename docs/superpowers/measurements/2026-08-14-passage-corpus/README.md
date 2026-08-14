# Passage corpus measurement (pre-registered gate, Task 1)

**Date:** 2026-08-15
**Store measured:** the live canonical store at `~/Library/Application Support/Pensieve/pensieve.sqlite`, opened strictly read-only via `openCanonicalDatabaseReadOnly(at:)`. No writes. `PENSIEVE_DB`/`PENSIEVE_CAPTURE_DB` were never set for this measurement — this is not a temp fixture, it is the real store.

## Why this exists

The transcript-passage-chunking spec sizes its design (per-table-hash rebuild mitigation, chunk-limit handling) against jq/grep approximations over raw transcript JSONL: ~7.4k prompts / ~33k replies / ~31 MB. This repo has a scar where exactly that kind of raw-JSONL measurement invalidated a spec's evidence base (the transcript-readability corpus re-measurement). This task re-derives the same figures by running the actual production parser (`TranscriptParser`) over every live transcript, before Task 6 (or any other task) is allowed to depend on the approximation.

## What ran, and why it deviates from the brief's literal recipe

The brief's `probe.swift` is written as a standalone script meant to be compiled with `swiftc -I .build/debug -L .build/debug -lPensieveKit … -o /tmp/passage-probe` against the built module. That does not link as written: `ProvenanceQueries.transcriptPath(in:)` (`Sources/PensieveKit/Query/ProvenanceQueries.swift:67`) and `TextQuality` are both module-**internal**, so an external `import PensieveKit` cannot see them — only `@testable import PensieveKit` can.

Per the brief's own pre-approved fallback, the probe instead ran as a temporary Swift Testing case:

- Created: `Tests/PensieveKitTests/PassageCorpusProbe.swift` — a single `@Test func passageCorpusProbe() throws { … }` with the **exact logic from the brief**, unchanged.
- Ran with: `make test FILTER=passageCorpusProbe` (which is `swift test --filter passageCorpusProbe` under the hood).
- **Deleted** immediately after the run, before this commit — it was scaffolding, not a permanent test.

The evidence copy committed at `probe.swift` alongside this README is that same code (re-expressed as the `@Test` function that actually executed, with a comment explaining the deviation) — not the brief's literal top-level-script form, since that form never ran (it wouldn't link). The logic — which fields are read, how bytes/over-limit counts are computed, which queries hit the database — is byte-for-byte what the brief specified. The numbers below come from `TranscriptParser`, not from grep or jq.

## Command run

```bash
make test FILTER=passageCorpusProbe
```

## Raw output (verbatim)

```
Test Suite 'Selected tests' started at 2026-08-15 00:43:36.103.
Test Suite 'PensievePackageTests.xctest' started at 2026-08-15 00:43:36.103.
Test Suite 'PensievePackageTests.xctest' passed at 2026-08-15 00:43:36.103.
	 Executed 0 tests, with 0 failures (0 unexpected) in 0.000 (0.000) seconds
Test Suite 'Selected tests' passed at 2026-08-15 00:43:36.103.
	 Executed 0 tests, with 0 failures (0 unexpected) in 0.000 (0.001) seconds
Test run started.
Testing Library Version: 1902
Target Platform: arm64e-apple-macos14.0
Test passageCorpusProbe() started.
live=396 missing=710
prompts=2955 bytes=3255844 over2000=460
replies=24057 bytes=10784200 over2000=1621
estimatedDocuments=31174
Test passageCorpusProbe() passed after 24.368 seconds.
Test run with 1 test in 0 suites passed after 24.368 seconds.
```

(Full build+test log also showed the whole suite compiling, since `swift test --filter` still builds the whole test target; only the one test executed, as shown above.)

## The numbers

| Metric | Value |
|---|---|
| `cc.session` events with a transcript path on disk (live) | 396 |
| `cc.session` events whose transcript file is gone (missing) | 710 |
| User-prompt messages (`isUserPrompt == true`) | 2,955 |
| Prompt bytes (UTF-8) | 3,255,844 |
| Prompts over the 2,000-character chunk limit | 460 |
| Assistant-reply messages (`role == "assistant"`) | 24,057 |
| Reply bytes (UTF-8) | 10,784,200 |
| Replies over the 2,000-character chunk limit | 1,621 |
| **Total bytes (prompts + replies)** | **14,040,044 (≈13.4 MB)** |
| **Estimated documents** (`prompts + replies + over2000×2` for each) | **31,174** |

`estimatedDocuments` follows the brief's formula exactly: a message under the chunk limit becomes one passage document; a message over the limit is estimated at 2 documents (one extra split) rather than modeled exactly, matching the spec's own approximation method for the mitigation sizing.

## Comparison against the spec's jq/grep approximation

| Metric | Spec's approximation | Measured (parser-faithful) | Measured as % of estimate |
|---|---|---|---|
| Prompts | ~7,400 | 2,955 | ~40% |
| Replies | ~33,000 | 24,057 | ~73% |
| Total bytes | ~31 MB | ~14.0 MB | ~45% |

**The spec's estimate did not hold as a tight approximation — it overestimated across the board, prompts most severely (by ~2.5×).** Two candidate reasons, not independently verified here since verifying them isn't this task's job: (1) the parser's `isUserPrompt` predicate is deliberately conjunctive and excludes meta/tool-result/injected messages that a naive JSONL/jq count of `"type":"user"` records would include (this is the same asymmetry documented in the transcript-readability work — 309 genuine `type:"user"` records that still fail `isUserPrompt`); (2) only 396 of the 1,106 total `cc.session` events (36%) still have a transcript file on disk — 710 (64%) are missing, so any grep/jq pass over "all transcript files it could find" was working from a smaller and differently-biased set than a full accounting of session events would suggest. Directionally the same shape (replies far outnumber prompts, low tens of MB total), but the absolute figures are meaningfully smaller than the spec assumed, in every dimension.

**Worth flagging to a later implementer, though it is not part of this task's gate:** 64% of `cc.session` events have no transcript file on disk. Whatever the passage-chunking design does for backfill/reconciliation will only ever see the 396 live ones — this measurement is already restricted to those, so it is not an undercount relative to what the parser *can* see, but it means the addressable passage corpus is smaller than the raw event count implies.

## Gate verdict

The brief's gate: **STOP and report if estimated documents exceed 150,000 OR total bytes exceed 100 MB** — the spec's per-table-hash mitigation was sized for ~50k documents and would need revisiting above that.

- Estimated documents: **31,174** — well under 150,000.
- Total bytes: **≈13.4 MB** — well under 100 MB.

**Neither threshold tripped. The gate passes.** The corpus is smaller than the spec assumed on every axis, so the ~50k-sized mitigation has more headroom than planned, not less. No STOP condition applies; Task 6 and later tasks may proceed using these numbers.

## `rebuildPassages` wall-clock (pre-registered gate, Task 6)

**Date:** 2026-08-15
**What ran:** Task 6 gives passages their own `document_passages` FTS5 table with its own corpus hash (`SearchIndexStore.rebuildPassages`/`storedPassagesHash`, `SearchIndexer.syncPassages`), so that a one-line git commit never rebuilds tens of thousands of unchanged passage documents. The spec pre-registers a gate: if a whole-rebuild of a realistic passage corpus exceeds ~2 seconds, the per-table hash is insufficient and incremental indexing must be specified instead.

Measured with a temporary `@Test` (`Tests/PensieveKitTests/PassageRebuildTimingProbe.swift`, deleted immediately after this run, per the same throwaway-probe approach Task 1 used) that builds **50,000** synthetic `EmbeddableItem(kind: "passage")` values of **1,210 characters** each (a repeated 55-character phrase × 22) against a `nodeID` in `.active` state, then times a single call to `SearchIndexStore.rebuildPassages(items:passagesHash:)` on a fresh `tempSearchStore()` using `ContinuousClock`. 50,000 is a deliberate overshoot against the Task 1 measured real corpus of ~31,174 documents.

Command run:

```bash
make test FILTER=passageRebuildTiming
```

Raw output (verbatim):

```
Test Suite 'Selected tests' started at 2026-08-15 01:53:51.028.
Test Suite 'PensievePackageTests.xctest' started at 2026-08-15 01:53:51.028.
Test Suite 'PensievePackageTests.xctest' passed at 2026-08-15 01:53:51.029.
	 Executed 0 tests, with 0 failures (0 unexpected) in 0.000 (0.000) seconds
Test Suite 'Selected tests' passed at 2026-08-15 01:53:51.029.
	 Executed 0 tests, with 0 failures (0 unexpected) in 0.000 (0.001) seconds
Test run started.
Testing Library Version: 1902
Target Platform: arm64e-apple-macos14.0
Test passageRebuildTiming() started.
rebuildPassages(items: 50000) took 0.732862166 seconds
Test passageRebuildTiming() passed after 0.797 seconds.
Test run with 1 test in 1 suite passed after 0.798 seconds.
```

| Metric | Value |
|---|---|
| Synthetic items rebuilt | 50,000 |
| Item size | ~1,210 characters each |
| `rebuildPassages` wall-clock (`ContinuousClock`) | **0.733 s** |
| Gate threshold | ~2 s |

**Gate verdict: PASSES, with headroom to spare.** 0.733 s is well under the ~2 s threshold — at roughly a third of the budget for an overshoot corpus already ~1.6× the measured real one. The per-table hash (whole-drop-and-reinsert on any passage-corpus change, guarded by `passages_hash` so an unchanged corpus costs one read) is sufficient; incremental indexing is not required by this measurement. No STOP condition applies.
