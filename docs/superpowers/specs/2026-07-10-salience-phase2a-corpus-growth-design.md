# Salience Phase 2a — corpus-growth engine — design

**Date:** 2026-07-10
**Status:** approved (brainstorm) — pending user sign-off → plan
**Depends on:** the salience labeling loop **Phase 1** (`2026-07-09-salience-labeling-loop-design.md`,
shipped: `looseEnds.label`/`labelSuggestion`, `LooseEndCommands.setLabel`/`.suggest`, in-app 👍/👎)
and the salience-gate eval decision (`salience-eval-2026-07-09.md`).
**Followed by:** **Phase 2b** — *train & gate*: an on-device Create ML `MLTextClassifier` +
the reversible soft auto-filter (its own spec), gated on the corpus this phase produces.

## Why

The `2026-07-08` "Ingestion Intelligence Quality" spec shipped an LLM salience gate; the
`2026-07-09` eval **failed** it (on-device ~3B recall **0.68** — it confidently deleted genuine
loose ends, non-deterministically) and **disabled** it. The chosen replacement is a **deterministic
on-device Create ML classifier fed by a human-labeled corpus**, with **Haiku (`claude -p`) as an
offline bootstrap labeler**. Phase 1 built the labeling loop; the corpus is now the bottleneck:

- **~40 salient positives** total (live store: **22 salient / 75 noise / 531 unlabeled**; plus **19
  salient / 101 non-salient** hand-adjudicated quotes parked out-of-store in
  `~/Library/Application Support/Pensieve/salience-corpus/labels-2026-07-09.json`).
- Salient is the **minority class (~16%)**, so **positive-example volume is the dominant cost**
  (eval doc). A `MLTextClassifier` trained on ~40 positives would overfit and could not be
  validated against any recall floor.

So Phase 2 is **split, corpus-first**. **This spec (2a)** grows the human-confirmed corpus by
pre-labeling the backlog with Haiku and making bulk human audit fast. **Phase 2b** trains the
classifier and wires the soft auto-filter, once the corpus is real. Each ships value on its own; we
do **not** build a gate we cannot yet validate.

## Goal & non-goals

**Goal:** take the human-confirmed salience corpus from ~40 → **~150+ salient** by (1) an offline
Haiku **bootstrap labeler** that pre-fills `labelSuggestion` over the backlog, and (2) an efficient
**bulk audit UX** where the human confirms/flips those suggestions into `label`. Value now: fast
triage of the 500+ open backlog.

**End-state (context, delivered in 2b — NOT here):** once trained, a confident *noise* verdict
**reversibly soft-hides** a loose end from the open worklist (the same reversible mechanism a human
👎 uses today — `LooseEnd.isOpen` already excludes `label == "noise"`), surfaced in a Hidden/review
view, un-hide → a `salient` label. Never deletes. Gated behind a proven recall floor.

**Non-goals (2a — all deferred to 2b):**
- **No trained classifier / Create ML / Core ML / `NLModel` / feature engineering.**
- **No auto-filter, no hiding, no Hidden view, no change to `LooseEnd.isOpen`.** In 2a, machine
  suggestions are **purely advisory pre-fills**; only a human `label` ever hides anything (today's
  rule). Haiku's ~0.23 precision is nowhere near trustworthy enough to hide on its own.
- **No schema migration.** `label`/`labelSuggestion` already exist (Phase 1, migration v11).
- **No daemon / `sync` / `Ingester.drain()` / capture / `LooseEndVerifier` change.** The bootstrap
  is a deliberate, offline, manually-run CLI — never in the sacred cheap auto-flow.
- **No destructive re-mine** (the parked A6). Nothing is ever deleted.

## Guiding principles

- **Grounded-with-provenance stays sacred.** The verbatim trust gate is untouched; every loose end
  still cites real user text. Suggestions never create, delete, or hide — they only *pre-fill a
  guess* a human confirms.
- **The human is the only writer of the corpus.** `label` is written **exclusively** by human
  confirmation (`LooseEndCommands.setLabel`) — in the app or via the one-shot import of previously
  human-adjudicated labels. Haiku writes only `labelSuggestion` (`.suggest`), which "never enters
  the corpus" (Phase-1 invariant).
- **On-device-first, offline escalation.** The live pipeline stays on-device and lossless. Haiku is
  an **offline** batch pre-labeler run by hand (`claude -p`, subscription — no API key needed; the
  eval already ran it this way), never a runtime gate and never in the daemon.

---

## Component 1 — CLI `pensieve label-suggest` (the bootstrap labeler)

```
pensieve label-suggest [--limit N] [--force]
pensieve label-suggest --import <path-to-labels.json>
```

**Default mode (suggest).** Pre-label the backlog:
1. **Select candidates:** open loose ends that are **unlabeled** (`label == ""`) and have **no
   suggestion** (`labelSuggestion == ""`), unless `--force` (re-suggest even if already suggested).
   `--limit N` caps the batch for a bounded first run.
2. **Rebuild context (the folded-in decision): quote + surrounding-transcript window.** Group
   candidates by `sourceEventID`; for each source event, resolve its transcript path (the same
   event→transcript resolution `ExtractionRunner` uses) and **parse it once**; build each
   candidate's input from its verbatim `quote` plus a **char-capped window of neighbouring turns**
   around `sourceMessageIndex`, reusing `SalienceClassifier.contextWindow`. **Degrade to quote-only**
   for any candidate whose transcript is missing/compacted/unparseable — never abort the run.
3. **Classify via Haiku:** batch by char budget (reusing `SalienceClassifier.batches`/`buildPrompt`
   and the `classifyNonSalientIndices` provider call) against a provider pinned to `claude -p`
   `claude-haiku-4-5-…`. Haiku returns the **non-salient (drop) set** per batch (the established
   conservative shape); everything else is salient.
4. **Write suggestions:** `LooseEndCommands.suggest(id, "noise")` for the drop set,
   `.suggest(id, "salient")` for the rest. **Never** touches `label`.
5. **Report:** `N candidates → M suggested (X salient / Y noise), Z quote-only (no transcript)`.

**Import mode (`--import <file>`).** Fold the parked hand-adjudicated labels into the store's
**human** `label`: the file is a JSON list of `{quote: String, salient: Bool}` (120 entries today).
For each entry, **quote-match** to stored loose ends and write `label = salient ? "salient" :
"noise"` via `setLabel`; **skip** entries whose quote no longer matches any stored loose end
(report skipped count). Idempotent (re-writing the same `label` is a no-op). This is real human
adjudication — up to **+19 salient / +101 noise** with zero new hand-labeling (net-new bounded by overlap — the
120 were sampled *from* the store's open set, so any already labeled in-app are no-ops).

**Shape:** thin CLI over a new tested Kit unit (below) + the existing `LooseEndCommands`. Committed
and **re-runnable** (new loose ends arrive daily; re-run to cover them) — not a throwaway script,
not a daemon pass.

## Component 2 — Kit: `SalienceSuggester` + `SalienceReviewQueries` (tested)

**`SalienceSuggester`** — the store-facing bootstrap engine the CLI's suggest mode calls. Over a
canonical store + an injected `LLMProvider` + a transcript reader:
- selects candidates (unlabeled, open, no suggestion — or all-unlabeled under `--force`),
- groups by `sourceEventID`, parses each transcript once (best-effort; quote-only fallback on
  missing/unparseable), builds per-candidate `quote + contextWindow`,
- reuses `SalienceClassifier`'s batching/prompt/decoding (extract a store-friendly entry point if
  `filter`'s shared-`messages` signature doesn't fit — the plan settles reuse-vs-thin-refactor),
- writes `labelSuggestion` via `LooseEndCommands.suggest`, and returns a summary
  (`candidates`/`suggested`/`salient`/`noise`/`quoteOnly`).

Determinism note: the classifier is a non-deterministic LLM, so `SalienceSuggester`'s **provider
call** is exercised in tests with a **stub provider** (fixed drop-set) — candidate selection,
grouping, quote-only fallback, and the suggestion writes are deterministic and unit-tested. The
real-Haiku run is a manual dogfooding step, not CI.

**`SalienceReviewQueries`** — a read-only query backing the app Review surface: open loose ends that
are **unlabeled** (`label == ""`) and **have** a `labelSuggestion`, ordered **suggested-salient
first** (Haiku's 0.947 recall means nearly all true positives sit in its salient bucket, so
confirming that bucket both harvests the scarce positives and corrects its false positives into
negatives — both feed the corpus), then a stable secondary order. Returns each item with enough
node context to display and navigate. Pure, seeded-store unit tests (filtering + ordering + the
node join).

## Component 3 — App: "Review Suggestions" surface + inline ghost pre-fills

**Review Suggestions (N) — a dedicated sidebar surface.** A flat, cross-node list backed by
`SalienceReviewQueries`; the bulk-audit tool this phase exists for. Each row: the verbatim quote
(with its inline provenance available as elsewhere), the source node, and Haiku's **ghosted 👍/👎
pre-fill** (the suggestion, visibly distinct from a confirmed label). One tap **confirms** the
suggestion or **flips** it → `LooseEndCommands.setLabel` writes the human `label` (leaves the
Review list on confirm, so the session flows). A live count reflects remaining unlabeled-with-
suggestion items. Thin view; all derivation in `SalienceReviewQueries`.

**Inline ghost pre-fills.** Everywhere loose-end rows already render (per-node detail, existing
worklists), show `labelSuggestion` as a **dim/ghosted** pre-fill on the existing 👍/👎 so a
suggestion is confirmable in place too — a small increment on top of surfacing `labelSuggestion`.

Nothing here hides or filters — the Review view lists items *for confirmation*, not because they
were hidden. German l10n for the new chrome (the surface title + any labels); quotes/content stay
English-fallback per the localization rule.

---

## Data flow

```
pensieve label-suggest                          (offline, manual, re-runnable)
  select unlabeled+un-suggested open loose ends
    → group by sourceEventID → parse transcript once → quote + context window
      (quote-only fallback if transcript gone)
    → Haiku (claude -p) batch classify → non-salient drop set
    → LooseEndCommands.suggest(id, "noise"|"salient")     [labelSuggestion only]

pensieve label-suggest --import labels.json     (one-shot human-label fold-in)
  quote-match → LooseEndCommands.setLabel(id, "salient"|"noise")   [human corpus]

App ▸ Review Suggestions (N)                     (bulk human audit)
  SalienceReviewQueries → rows w/ ghosted pre-fill
    → tap confirm/flip → LooseEndCommands.setLabel   [human corpus]

App ▸ per-node loose-end rows                    (inline audit)
  ghosted labelSuggestion pre-fill → setLabel      [human corpus]
```

`label` (the corpus) is written **only** by human confirmation or the import of prior human
adjudication. `labelSuggestion` is written **only** by Haiku and never counts as corpus.

## Exit criterion → Phase 2b

Informal: **~150+ confirmed `salient` labels** in the store (a rough floor for training a
non-overfitting `MLTextClassifier` on a ~16%-minority class; 2b's eval sets the authoritative bar).
2a is "done" when the CLI + Review UX exist and a real Haiku run + audit session have demonstrably
grown the corpus toward that floor.

## Testing

- **`SalienceReviewQueries`** (deterministic CI) — seeded store: only `label == "" && labelSuggestion
  != "" && open` rows returned; **suggested-salient ordered first**; node join correct; resolved/
  human-labeled/un-suggested rows excluded.
- **`SalienceSuggester`** (deterministic CI, **stub provider**) — candidate selection (skips labeled
  + already-suggested; `--force` includes suggested); grouping-by-event; **quote-only fallback** when
  a transcript is absent; writes `labelSuggestion` (never `label`) matching the stub's drop set; the
  summary counts.
- **Import** (deterministic CI) — quote-match writes the correct human `label`; non-matching entries
  skipped and counted; idempotent re-run.
- **App** — no unit tests (app target); verify via `xcodebuild` build + non-blocking smoke-launch
  with throwaway `PENSIEVE_DB`/`PENSIEVE_CAPTURE_DB`. Keep views thin; derivation in Kit.
- **Manual dogfooding (acceptance)** — run `label-suggest` (+ `--import`) against the real store,
  audit a session in the Review view, and confirm the salient count rose. Not CI.

## Files (anticipated)

- `Sources/PensieveKit/Intelligence/SalienceSuggester.swift` — new; store-facing bootstrap engine
  reusing `SalienceClassifier` machinery + transcript re-parse + quote-only fallback.
- `Sources/PensieveKit/Query/SalienceReviewQueries.swift` — new; read-only Review query.
- `Sources/PensieveKit/Query/LooseEndCommands.swift` — reused as-is (`setLabel`/`suggest`); no change
  expected beyond possibly a bulk helper.
- `Sources/pensieve/…` — new `label-suggest` subcommand (suggest + `--import` modes).
- `Sources/PensieveApp/` — Review Suggestions surface (sidebar entry + list view) + inline ghost
  pre-fill on the shared loose-end row; `AppModel` wiring; `Localizable.xcstrings` keys (en + de).
- `Tests/PensieveKitTests/` — `SalienceReviewQueries`, `SalienceSuggester` (stub provider), import.

## Risks & mitigations

- **Haiku precision ~0.23 → the suggested-salient bucket is mostly false positives.** Accepted: high
  *recall* (0.947) is what matters for not missing positives, and every flip is a useful negative
  label. Suggested-salient-first ordering minimizes taps-per-true-positive; the +context window
  lifts precision to cut the wade. Suggestions never hide, so a wrong suggestion costs one glance.
- **Transcript re-parse cost / missing transcripts.** Group-by-event parses each session once;
  quote-only fallback keeps the run going when a transcript is gone. Offline CLI → latency is a
  non-issue.
- **Import quote-match misses (compaction/edits changed the stored quote).** Skip + report; the item
  simply stays unlabeled for the app audit. No partial/incorrect corpus writes.
- **`claude -p` / subscription unavailable.** The suggest run fails loudly (it's a manual tool); the
  app audit + import paths don't depend on it. No pipeline impact (Haiku is never in the auto-flow).
- **Scope creep toward 2b.** This spec deliberately builds **no** classifier and **no** hiding; the
  reversible auto-filter and `MLTextClassifier` are 2b, gated on this corpus.
