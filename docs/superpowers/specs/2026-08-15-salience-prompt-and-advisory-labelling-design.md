# Salience: a real gold set, a rewritten prompt, and advisory labelling in the sync path

**Date:** 2026-08-15
**Status:** approved (brainstorm → spec); implementation plan to follow
**Supersedes the instruction in:** `docs/superpowers/HANDOVER-salience-prompt.md` (see § "What the
handover got wrong")

---

## Problem

`SalienceClassifier` decides whether a captured quote is *deferred / parked / decision work the
developer left open* or *an in-the-moment request the assistant simply carried out*. It has been
built since Phase 1B, disabled in extraction since July, and its offline sibling
`SalienceSuggester` has been run exactly once — a 20-item trial on 2026-08-15 that was reverted.

Two shipped features depend on `labelSuggestion`, which is empty on all 986 rows of the live store:

- `LooseEndQueries.openAcrossNodes`' suggested-salient-first tier degrades to pure oldest-first —
  the mode its own doc comment rejects as "grind through three repos".
- `SalienceReviewQueries.pending` is *structurally* empty: it requires `labelSuggestion != ""`.

The stated task was "improve the prompt". Prompt work is unmeasurable without a gold set, and the
gold set question turned out to be the substance of the problem.

---

## What the handover got wrong

Three corrections, all verified against the repo and the live store on 2026-08-15. They are recorded
because acting on the handover as written would have optimised the prompt toward the wrong target.

**1. The gold set already exists, and it is not the one the handover points at.**
`docs/superpowers/salience-eval-2026-07-09.md` records a **120-item hand-labelled random sample**,
still on disk at `~/Library/Application Support/Pensieve/salience-corpus/labels-2026-07-09.json`
(19 salient / 101 noise), already in `PENSIEVE_SALIENCE_LABELS` format. It was labelled *against the
deferred-vs-in-the-moment definition* — the axis this work keeps.

**2. The 122 in-store `LooseEnd.label` values are a different judgment and must not be used as the
gold set.** A 👎 also removes an item from every feed (`LooseEndQueries.swift:100,126`), so it reads
as "don't show me this", not "this isn't deferred work". Adjudicated directly by the user during
this brainstorm: `"are we ready to roll this out?"` and `"Localization. How does that work?"` are
thumbed **salient** in the store and are both **noise** on this axis. Wiring the 122 in as gold —
the handover's headline instruction — would train the prompt toward the wrong target.

**3. There is already a baseline, and it is not the August trial.** July measured, on the random
120: `claude -p` Haiku **recall 0.947 / precision 0.23**; on-device Foundation Models **0.68 /
0.17–0.19**; un-gated baseline precision **0.158** (19/120). The August 20-row trial re-found the
same shape by eye. The July numbers are the baseline to beat because they are the ones on the
held-out set.

A fourth claim was raised during the brainstorm and is **withdrawn**: an apparent 85% human
self-consistency ceiling, computed from 4 disagreements across the 27 quotes the two sets share.
Given (2), most of that spread is the two sets measuring different things, not the labeller
contradicting themselves. There is no measurement ceiling to report.

---

## Goals

1. A gold set large enough that a precision change is resolvable, on one consistent axis.
2. A prompt whose conservatism matches what it is now used for.
3. Classification that runs on new loose ends automatically, without any ability to delete work or
   to reorder the burn-down queue on unaudited guesses.
4. A pre-registered numeric bar deciding whether salient-first ordering may be switched on at all.

**Non-goals.** Extraction stays lossless. The verbatim trust gate,
`TranscriptVocabulary.injectionMarkers` and `isUserPrompt` are untouched. The destructive retroactive
re-mine (plan A6) stays parked. No `EvalTask` registration (§ 5).

---

## 1. The gold set

### Build

Pre-label all 122 thumbed quotes on the deferred-vs-in-the-moment axis via `claude -p`, diff each
against the stored thumb, and hand the user **only the disagreements** to adjudicate — expected
30–50 items, one line each. Agreements are accepted as-is; the user's adjudication is authoritative
on the rest.

### Split — deliberately not merged

| set | items | role |
|---|---|---|
| **Dev** — the 122 relabelled, minus the 27 that also appear in July | ~95 | prompt iteration; few-shot examples drawn from here |
| **Test** — the July 120, untouched | 120 | held out; measured only at the end |

The two are kept apart for two independent reasons, both load-bearing:

- **The July 120 is the only *randomly sampled* set.** That is the only property that makes a
  precision number from it an estimate of production precision. The 122 were selected by the user
  looking at them, so any metric computed on them is biased upward by attention.
- **27 quotes appear in both.** Merging would put test items in the set the prompt is tuned on.

Headline results are therefore reported on the 120. Dev numbers may be reported alongside, labelled
as not production-representative.

### Storage

`~/Library/Application Support/Pensieve/salience-corpus/labels-2026-08-15-dev.json`, beside the July
files — private project content, out of git, the precedent already set in July.
`PENSIEVE_SALIENCE_LABELS` already points the harness at an arbitrary path.

The in-repo `Tests/PensieveKitTests/Fixtures/salience-labels.json` stays as the 10-quote synthetic
compile seed. Its README and the `NOTE:` block atop `SalienceEvalTests.swift` both still claim the
real set does not exist; that text has been stale since July and is corrected as part of this work.

---

## 2. The prompt

Four changes to `SalienceClassifier.buildPrompt`, in descending order of expected effect.

**2.1 — Delete "When you are unsure about an item, do NOT include it (keep it)."**
This single line is the mechanical cause of precision 0.23: it instructs the model to resolve every
doubt toward keeping, and Haiku keeps 78 of 120. It was **correct** for what the prompt was built as
— a deletion gate inside `ExtractionRunner`, where a false drop permanently destroys captured work.
It is wrong for an advisory labeller that deletes nothing. This change is safe *only because of* the
architecture in § 3, and the two must not be separated.

**2.2 — Return a per-item label, not a drop-set.**
Today "salient" and "unsure" are the same output token — the model expresses both by omission. A
three-way answer (`salient` / `noise` / `unsure`) separates them, so the audit queue can lead with
confident positives and park unsure items in a middle tier rather than promoting them.

`labelSuggestion` gains a third value, `unsure`. This is additive on a STRICT `TEXT` column and needs
**no migration**. Both existing consumers already behave correctly on an unrecognised value:
`SalienceReviewQueries.pending` requires only `!= ""` (so unsure items are auditable), and the
comparator tests `== salient` (so unsure ranks with noise). It is added to `LooseEndLabel` as a
suggestion-only constant — the human `label` remains two-valued, and `LooseEndCommands.corpus` reads
confirmed labels only, so an unsure suggestion can never enter the training corpus.

**2.3 — Few-shot from the dev set.**
Real quotes in the user's own voice with the user's own adjudication, including the genuinely hard
ones (`"just a one-time backfill, or flush the database and just ingest everything fresh"`). No
test-set item ever appears in a prompt.

**2.4 — State that the quote may arrive alone.**
~85% of loose ends have lost their transcript (all 20 items in the August trial were quote-only; 18
of 122 open ends on the Pensieve node still have a live transcript). The prompt currently does not
acknowledge an empty context window at all, leaving the model to infer whether absent context is
meaningful. It should say how to judge a bare quote.

`buildPrompt` remains **one definition** shared by `SalienceClassifier.filter` and
`SalienceSuggester`, as its comment requires.

### Measurement

The existing harness: `PENSIEVE_SALIENCE_EVAL=1 make test FILTER=salienceEval`, provider selected via
`PENSIEVE_SALIENCE_EVAL_PROVIDER=claude` and `PENSIEVE_CLAUDE_MODEL`. It already reports precision and
recall **on the salient class**, so the class-imbalance trap ("everything is noise" scores 80%
accuracy) is already handled. Every run is committed to
`docs/superpowers/measurements/2026-08-15-salience-prompt/` with the prompt version that produced it.

---

## 3. Where classification runs

```
extraction  →  verified loose ends            lossless, unchanged
                    ↓
sync path   →  labelSuggestion                advisory; never deletes, never reorders
                    ↓
Review Suggestions  ←  the user audits here
                    ↓
human label  →  salient-first ordering        only audited labels may reorder
```

A bounded, best-effort salience pass in `SyncRunner.run()`, after extraction, over **recently created
loose ends only**. It writes `labelSuggestion` and nothing else; `LooseEndCommands.suggest` is
already the narrow writer for exactly this.

### 3.0 Candidate selection — a lookback window, not the whole backlog

Candidates are loose ends where `label == ""`, `labelSuggestion == ""`, **and `createdAt` is within a
lookback window** (7 days), capped per cycle.

The window is load-bearing, not a tuning knob. Without it, `label == "" && labelSuggestion == ""`
matches the entire 986-row backlog, and the daemon would grind through it a cap-sized bite at a time
over hours — precisely the unattended mass-labelling this design says must be a deliberate human
decision. `createdAt >= cycleStart` would also avoid that, but it silently breaks the retry
guarantee in § 3.2: a batch that fails on a provider error would never be a candidate again. A window
gives both properties — the pre-existing backlog is out of reach because all of it is older, and a
failed item stays a candidate for the next several cycles.

The existing 986-item backlog stays behind `pensieve label-suggest`, run deliberately, so a one-off
decision to generate ~986 audit items is made by a person.

### 3.1 It needs its own provider

`SyncRunner` carries one `provider`, and both production entry points inject
`makeDefaultLLMProvider` — on-device Foundation Models, which July measured at **recall 0.68** on
this exact task, confidently deleting genuine loose ends. `pensieve label-suggest` already sidesteps
this by constructing `ClaudeCLIProvider` with Haiku itself.

So the pass takes a **separate, optional, nil-defaulted `salienceProvider`**, injected explicitly by
`pensieve sync` and `PensieveSyncAgent`. This is the `searchIndexer: SearchIndexer?` pattern already
in this file, adopted for the reason its own comment gives: no internally-constructed fallback, so a
test that builds a `SyncRunner` cannot quietly begin spawning `claude -p`. `nil` = the pass does not
run.

### 3.2 The daemon-spawns-`claude -p` risk

The pass runs from launchd every 300 s, on a subscription, with `label-suggest`'s 120 s per-batch
timeout. Mitigations, all required:

- **Best-effort.** `SalienceSuggester` already writes nothing for a failed batch and retries next
  cycle; that behaviour is kept and must not be "improved" into a throw.
- **Per-cycle item cap** so a backlog cannot turn one sync cycle into an hour-long run.
- **Verified by hand before it is trusted.** One cycle run from the agent's own environment
  (`SyncAgentEnvironment.resolvedPATH`) before this is relied on. If `claude -p` cannot authenticate
  from launchd, the fallback is that suggestion stays CLI-only — which is worth discovering
  deliberately rather than as silent no-ops in `sync.log`.

### 3.3 The shared comparator forks

`LooseEndQueries.suggestedSalientFirstThenOldest` is deliberately one definition; its doc comment
states that a copy is how two orderings that should agree stop agreeing. It now serves two feeds
that need **opposite** behaviour:

| feed | wants |
|---|---|
| `SalienceReviewQueries.pending` — the audit queue | suggested-salient first; that is its entire purpose |
| `LooseEndQueries.openAcrossNodes` — the burn-down queue | must **not** be reordered by unaudited guesses |

They are split into two **named** comparators, each carrying the reason at its definition, rather
than left as one function that serves neither. The burn-down comparator is oldest-first until the
bar in § 4 is cleared.

*Deferred, not foreclosed:* leading the burn-down queue with **human**-`salient` items (24, audited
by definition, trustworthy at no cost). It is what that feed's design goal wanted and is roughly one
line, but it changes behaviour on real rows and is not required by this work.

---

## 4. The pre-registered gate

Measured on the held-out July 120:

> **Salient-first ordering may consume `labelSuggestion` when precision on the salient class is
> ≥ 0.50 with recall ≥ 0.70.**

- **0.50** is the point where a promoted item is right more often than not. Today's 0.23 sits barely
  above the 0.158 base rate, which is why promoting on it is worse than oldest-first.
- **0.70 recall** stops a degenerate high-precision prompt that promotes four items and declares
  victory.

Stated now so it cannot be rationalised later: **if the rewritten prompt does not clear this bar,
salient-first ordering stays off and the work has succeeded.** The deliverable is a number and a
decision, not a shipped reordering.

Review Suggestions starts returning rows regardless of this bar — it needs no gate, because it is a
triage surface where a wrong suggestion costs one audit slot, and it is the only mechanism that
converts machine guesses into the human labels § 3's ordering actually trusts. The gate governs the
burn-down queue's ordering only.

---

## 5. Eval registration

**No bespoke `EvalTask` is registered**, and this is a chosen exception rather than an unnoticed one.

The question the `CLAUDE.md` rule exists to answer — *why this model and not a cheaper or more
private one* — is already answered empirically for salience: on-device FM 0.68 vs Haiku 0.947 recall,
on a real hand-labelled set. `SalienceEvalTests` already computes precision and recall against that
set, which for a single-prompt classifier is a more reproducible artifact than a rubric judge. This
is the same call made for slice-5 naming ("does not register a bespoke task… pinned by committed
probes").

Recorded under backlog **F4** ("9 model-backed tasks against 3 bars") alongside the other exceptions.
Registering it properly would need a new scorer kind plus `CorpusBuilder` plumbing — its own piece of
work, and blocked behind the guardrail hole F4 already documents (a registered task can load zero
corpus items and still pass the suite).

---

## 6. Testing

In `make test` (PensieveKit, deterministic, no model calls):

- Sync-pass candidate selection: unlabelled + unsuggested + inside the lookback window; a backlog
  item older than the window is **never** a candidate; per-cycle cap honoured.
- The three-way response parse, including an unrecognised label.
- Failure semantics: provider throws → nothing written, item still a candidate next cycle.
- `salienceProvider == nil` → the pass is a no-op.
- The comparator split: the audit queue leads with suggested-salient; the burn-down queue does not.

The prompt itself is **measured, not unit-tested**. Its numbers live in
`docs/superpowers/measurements/2026-08-15-salience-prompt/`.

---

## 7. Out of scope, and one defect found on the way

Out of scope: extraction losslessness, the trust gate, `injectionMarkers`, `isUserPrompt`, the
destructive re-mine (A6), and registering an `EvalTask` (§ 5).

**Found, filed, not fixed here:** roughly a dozen of the 98 noise-labelled items are teammate
messages and agent status reports stored with `role: user` — e.g. `<teammate-message
teammate_id="reviewer-1">`, `"Baseline still running"`, `"CHANGELOG auto-merged with both entries."`
All 122 labelled ends carry `role: user`. That is a capture-attribution defect wearing a salience
costume: no prompt can fix "the human did not write this". It inflates the noise class and therefore
mildly deflates measured precision on both sets. Filed to `backlog.md`; fixing it would change what
gets captured, which is a different piece of work.

---

## Success criteria

1. A ~95-item dev set and an untouched 120-item test set exist on one axis, with the adjudication
   round completed.
2. The rewritten prompt is measured on the held-out 120 and the numbers are committed alongside the
   prompt version.
3. New loose ends receive a `labelSuggestion` from the sync path automatically, verified by one
   hand-run cycle from the agent's environment.
4. Review Suggestions returns rows.
5. The § 4 bar is evaluated and the resulting decision — ordering on or ordering off — is recorded.
