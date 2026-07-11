# LLM Evaluation Harness — Design

**Date:** 2026-07-11
**Status:** Approved (brainstorm complete, ready for plan)
**Topic:** A structured, automated way to pick the default LLM per task — on-device-first, cheapest-online-when-necessary.

## Motivation

OpenAI and xAI (and Google) have shipped cheaper/faster/capable models. Pensieve routes several *generative* tasks through the `LLMProvider` seam, and today the default is chosen by hand. We want a **repeatable, automated harness** that, for each task, recommends a **defensible default model on a structured basis** — and re-runnable when a new model drops.

Guiding bias (the north star for this feature): **automation, and surfacing what's important or forgotten.** You calibrate the judge once, then the harness runs the matrix and hands you a recommendation. You are the spot-check, not the labeler.

Second guiding bias: **local-first + private.** Prefer on-device Foundation Models wherever it clears the bar; reach for an online model only where necessary. Chinese-hosted models (DeepSeek, Qwen) are **excluded** — the tool reads private work; those providers are not trusted to see it.

## Scope

### In scope — the capable/generative tasks
- **Loose-end extraction** (`LooseEndExtractor`) — has an objective bar (precision is sacred; recall matters).
- **Narration / "Last Work Done"** (`SummaryBuilder.narrate`).
- **Description / strand writing** (`NodeDescriber`).
- **Briefing collection** (LLM-summarized briefing — prospective).
- **Next-task prioritization** (LLM-ranked What's Next — prospective).
- **Future tasks** — the task registry is extensible.

### Out of scope
- **The classifiers** (`IntentClassifier`, `SalienceClassifier` — `classifyGenuineIndices` / `classifyNonSalientIndices`). These are headed for a **trained on-device model**, not a prompted one, so provider choice is irrelevant to them.
- **The production routing/escalation layer.** Wiring the winning model (or hybrid) into the app/daemon is a **follow-up spec**, grounded in this harness's numbers. See "Deferred."
- Streaming, per-request telemetry beyond what the report needs, and any non-generative task.

## Candidate roster

Fast-moving specifics (exact model ids/prices) live in a committed config, **not** in code — the harness reads current numbers at runtime. Directional roster:

| Provider | Cheap-tier candidate(s) | Notes |
|---|---|---|
| **Apple** | Foundation Models (on-device) | free; already wired; the preferred default |
| **OpenAI** | GPT-5 nano, GPT-5 mini | user lean; nano extremely cheap |
| **xAI** | Grok 4.1 Fast | OpenAI-compatible API |
| **Google** | Gemini 2.5 Flash-Lite, Flash | rides the OpenAI-compat endpoint |
| **Anthropic** | Haiku class | via `CloudProvider` Anthropic flavor |
| **Judge** | Claude Opus / Sonnet | the one place we spend more per call |

**Excluded:** DeepSeek, Qwen, any China-hosted model (privacy).

Plumbing note: `CloudProvider` already speaks **Anthropic + OpenAI-compatible**. xAI is OpenAI-compatible; Gemini exposes an OpenAI-compatibility base URL. So **all candidates flow through the existing seam with config only — no new provider code.**

## The decision rule

The choice is **per-task threshold selection**, not a global ranking:

```
1. Filter to models CLEARING the task's acceptance bar.
   - extraction: precision ≥ 0.98 (fabrication is a HARD fail) AND recall ≥ target
   - soft tasks: judge quality ≥ bar
2. Among survivors, rank by:  PRIVACY/LOCALITY → COST → LATENCY → quality
3. Recommend the winner. A hybrid strategy competes here like any other model.
```

The harness **recommends**; the human confirms before it becomes the app/daemon default. Automation surfaces; you decide.

Bars, roster, and pricing live in a committed `eval-config.json` — explicit and tunable, not buried in code.

## Architecture

New module `Sources/PensieveKit/Eval/`, driven by a thin `pensieve eval` CLI. **Core principle: the harness runs the *real* intelligence components with the provider swapped out — it never re-implements prompts.** To evaluate extraction it constructs the actual `LooseEndExtractor(provider: modelUnderTest)` and runs it. Prompts stay single-source; drift is structurally impossible. Swapping the provider also naturally exercises each provider's real path (on-device guided generation vs. the default JSON-decode path).

### Units

- **`ModelUnderTest`** — a labeled config (`"openai/gpt-5-nano"`) that knows how to `makeProvider() -> any LLMProvider` (either `FoundationModelsProvider`, or a `CloudProvider` with flavor + base URL + model id + Keychain key) and carries its pricing (`$/1M in`, `$/1M out`; on-device = $0).

- **`EvalTask`** — binds a task id to (a) the real component it drives, (b) which corpus items feed it, (c) its scorer. One per in-scope task, extensible. Where a task has **natural stages** (extraction: *extract candidates → trust-gate → salience*; narration: *gather facts (already non-LLM) → narrate*), the task reports at **subtask granularity** so the harness shows exactly which stage forces an escalation.

- **`EvalCorpus`** — a **frozen** snapshot sampled once from the real store + on-disk transcripts, serialized to a **gitignored** local dir (`.eval/corpus/*.json`). Never committed — it is private work text. Sampling is **deterministic given a seed** (recorded in the manifest) and **stratified across node kinds**. The corpus is identified by a content hash; every scorecard records the corpus hash it ran against, so numbers are never compared across different corpora by accident.

- **`Runner`** — sweeps `task × model × corpus-item`, calls the provider, records raw output + wall-clock latency + token counts + success/failure. Provider errors become recorded **reliability** data, not crashes. A model with a missing key is **skipped with a note**, enabling partial runs (e.g. FM + OpenAI only).

- **`Judge`** — an Opus/Sonnet `CloudProvider` scoring each output against the task's rubric, returning a **structured verdict**. One pass per output (no ensembles — YAGNI for a single-user tool).

Results aggregate into a **`Scorecard`**.

### Hybrids are first-class competitors

A hybrid FM→online routing strategy (easy stages on-device, escalate only the hard stage to an online model) is, from the harness's view, **just another `ModelUnderTest`** dropped into the same sweep and scored on the same axes. The harness *shape* does not change; hybrids compete in the scorecard and may win. **We author a hybrid for a task only after the data shows FM breaking somewhere in it** — no speculative decomposition (measure-first).

## Scoring

Two scorer types, matched to the task:

- **Objective (extraction only).** Precision is sacred: the judge labels each surfaced candidate `grounded | fabricated` against its source text; **any fabrication is a hard fail** regardless of other scores. Recall is measured against a **small optional hand-labeled gold set** (~10 items, marked once via `pensieve eval gold`) so the harness can say "FM finds 8/10, nano 9/10." Without the gold set, recall degrades to a judge estimate, **flagged as lower-confidence**.

- **Rubric judge (all soft tasks).** The judge scores each output 0–1 on task-specific dimensions:
  - narration: *grounded / complete / concise / no invented facts*
  - description: *accurate / specific*
  - prioritization: *correctly ranked / justified*

  The report surfaces a few **judge rationales per task** so you can spot-check (trust-but-verify) the judge itself.

## Corpus, config & secrets

- **Corpus** — `pensieve eval sample [--n 30] [--seed S]` freezes a representative, stratified sample to `.eval/corpus/`. Each item carries what a task needs (extraction: raw fragments; narration/description: resolved node + events). Reproducible from the seed; identified by content hash.

- **Config** — one committed `eval-config.json`: model roster (label, flavor, base URL, model id, pricing), per-task acceptance bars, judge model, corpus size/seed. Adding a newly-released model is a config edit, no code change.

- **Secrets** — API keys live in the **Keychain** via the existing `KeychainSecretStore`, one entry per provider (`account = flavor`). `pensieve eval keys set <provider>` prompts and stores. Keys are **never** in the config, corpus, logs, or report. Missing key ⇒ that model is skipped with a note.

## CLI & reporting

```
pensieve eval sample [--n] [--seed]        # freeze/refresh the corpus
pensieve eval run [--task x] [--model y]   # sweep task×model (filters optional)
pensieve eval report                        # render latest scorecard
pensieve eval keys set <provider>           # Keychain
pensieve eval gold <task>                    # (optional) label the recall gold set
```

`run` writes machine-readable `scorecard.json` plus a gitignored `report.md`: per task, a table of **model × quality × precision/recall × p50/p95 latency × $/run × reliability**, the **recommended default** per the decision rule, and a handful of judge rationales for spot-checking. Progress + per-call token/latency go through the existing `os.Logger` under a new **`eval`** category.

Both `scorecard.json` and `report.md` live under the gitignored `.eval/` dir — they reference private transcript text.

## Testing

Follows the repo rule — **logic is tested PensieveKit; real model calls are not** (they cost money + need keys). Unit tests with a **fake provider + fake judge** cover the parts that can silently be wrong:
- scorecard aggregation,
- the decision rule (locality→cost→latency→quality, precision hard-gate),
- cost math,
- deterministic/stratified sampling,
- config parsing,
- missing-key skip.

The actual matrix run is a **manual/integration step** you invoke, gated behind keys — never in CI.

## Deferred (explicit)

- **Production routing/escalation layer** — wiring the winning model (or hybrid) into the app/daemon. Its own follow-up spec, grounded in this harness's per-subtask numbers. Deliberately not built here: you cannot design the escalation boundary before the data shows where FM breaks.
- **Judge ensembles / statistical CI** — YAGNI for a single-user tool; one judge pass, human spot-check.
- **Streaming, per-request cost telemetry in production, non-generative tasks.**

## Files (anticipated)

- `Sources/PensieveKit/Eval/` — `ModelUnderTest`, `EvalTask` (+ per-task definitions), `EvalCorpus`, `Runner`, `Judge`, `Scorecard`, `EvalConfig`.
- `Sources/pensieve/` — `eval` subcommand group (thin over the Kit).
- `eval-config.json` — committed roster/bars/pricing.
- `.gitignore` — add `.eval/`.
- `Tests/PensieveKitTests/` — harness-logic suites with fakes.

## Open items for the plan

- Exact `EvalTask` protocol shape (how a task exposes its real component + subtask stages to the runner).
- Whether the recall gold set is per-task or extraction-only at first (start: extraction-only).
- Judge verdict schema (rubric dimensions as a typed struct).
- Corpus item schema per task family.
