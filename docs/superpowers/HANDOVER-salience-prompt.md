# Handover — improve the salience classification prompt

Paste the block below into a fresh session.

---

Read `CLAUDE.md` first, then this.

**Task:** improve the salience classification prompt — the one deciding whether a captured quote is a
*durable* loose end or an *in-the-moment* instruction.

**Do the gold set before the prompt.** Right now any prompt change is unmeasurable, and that is the
whole problem:

- `Tests/PensieveKitTests/Fixtures/salience-labels.json` is a **synthetic starter — 10 invented
  quotes, not sampled from any real store.** Its own header says the real go/no-go needs ~100–150
  hand-labelled quotes from the live store.
- **Those already exist.** The live store holds **122 hand-adjudicated labels** in `LooseEnd.label`
  (24 `salient`, 98 `noise`), all with usable quotes. That is the gold set the eval has been waiting
  for, and nobody has connected the two.
- The eval already runs: `PENSIEVE_SALIENCE_EVAL=1 make test FILTER=salienceEval`, and the fixture
  path is overridable via `PENSIEVE_SALIENCE_LABELS` so real quotes need not be committed.

**Watch the class imbalance.** 24 salient vs 98 noise means "everything is noise" scores 80%
accuracy. Report **precision and recall on the salient class**, not accuracy, or the metric will
reward the degenerate prompt.

**Baseline to beat:** `docs/superpowers/measurements/2026-08-15-salience-prompt-baseline/` — the first
run the pipeline has ever had (20 items, `7 salient / 13 noise`), with the raw rows and a read of
where it went wrong. Noise calls looked right; salient calls were ~2–3 of 7 durable.

**Where the code is:**
- `Sources/PensieveKit/Intelligence/SalienceClassifier.swift` — the prompt and the parse.
- `Sources/PensieveKit/Intelligence/SalienceSuggester.swift` — the offline batch runner
  (writes `labelSuggestion` only, never the human `label`).
- `Sources/pensieve/Commands/LabelSuggest.swift` — `pensieve label-suggest [--limit N] [--force]`.

**The open design question, which may matter more than the prompt.** Suggestion is a manual,
opt-in backfill that has never been run, so two shipped features are inert: the Loose Ends bucket's
salient-first ordering degrades to pure oldest-first (the mode its own doc comment rejects as "grind
through three repos"), and Review Suggestions is *structurally* empty because its query requires a
non-empty `labelSuggestion`. A one-off backfill also leaves every future loose end unlabelled. Decide
whether classification should move into extraction — and note the cost that stopped the last run: a
full pass hands the user a ~986-item audit queue, and until it is audited, salient-first ordering
promotes unaudited guesses above genuinely old work.

**Constraints:**
- `claude -p` with a Claude subscription; **no API key**. Go through `LLMProvider`.
- A model-backed task must register an `EvalTask` and take its default model from `pensieve eval` —
  see `Sources/PensieveKit/Eval/README.md`. A `registry ↔ config` test fails the suite otherwise.
  (Related: backlog **F4** — 9 model-backed tasks against 3 bars.)
- The **trust gate is not in scope**. `labelSuggestion` never enters the search corpus and never
  gates extraction; do not touch `TranscriptVocabulary.injectionMarkers` or `isUserPrompt`.
- The store is live. `label-suggest` writes to it — take a backup first. A previous 20-row trial was
  reverted with `UPDATE looseEnds SET labelSuggestion=''`, and `labelSuggestion` is currently empty
  on all 986 rows, so the slate is clean.

**Background:** backlog § "The salience pipeline is built, wired, and has never been run".
