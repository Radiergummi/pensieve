# LLM Evaluation Harness — Design

**Date:** 2026-07-11
**Status:** Approved (brainstorm + two adversarial reviews folded in; ready for plan)
**Topic:** A structured, automated way to pick the default LLM per task — on-device-first, cheapest-online-when-necessary.

> **Revision note (post-review).** This spec was revised after two independent adversarial reviews (design-soundness + methodology). The load-bearing changes: **stage-isolation** (swap the provider only at the stage under test; pin everything else) to kill an FM-vs-cloud path asymmetry and keep the classifiers honestly out of scope; **incumbent-anchored acceptance bars** (bars = measured FM-as-shipped, turning the filter into a regression test); **judge calibration** against human labels + blinding + temperature 0; **description** re-modeled as a pinned `ProjectContext` snapshot (its real component reads the live git tree); **briefing + prioritization deferred** (no LLM component exists to drive); and **label-keyed Keychain** (flavor-keying collides across the OpenAI-compatible roster).

## Motivation

OpenAI, xAI and Google have shipped cheaper/faster/capable models. Pensieve routes several *generative* tasks through the `LLMProvider` seam, and today the default is chosen by hand. We want a **repeatable, automated harness** that, for each task, recommends a **defensible default model on a structured basis** — re-runnable when a new model drops.

North star: **automation, and surfacing what's important or forgotten.** You calibrate the judge once, then the harness runs the matrix and hands you a recommendation. You are the spot-check, not the labeler.

Second bias: **local-first + private.** Prefer on-device Foundation Models wherever it clears the bar; reach online only where necessary. Chinese-hosted models (DeepSeek, Qwen) are **excluded** — the tool reads private work and those providers are not trusted to see it.

## Scope

### In scope — the capable/generative tasks (each has a real component to drive today)
- **Loose-end extraction** — the generative candidate-extraction call inside `LooseEndExtractor`. Objective bar (precision sacred; recall matters). See "Stage-isolation" for exactly which call is swapped.
- **Narration / "Last Work Done"** — `SummaryBuilder.narrate`. Rubric-judged.
- **Description / strand writing** — `NodeDescriber`, driven from a pinned `ProjectContext` snapshot (see below). Rubric-judged.

### Out of scope
- **The classifiers** (`IntentClassifier`, `SalienceClassifier`). Headed for a *trained* on-device model, not a prompted one. In the harness they are **held fixed at a reference provider** (see Stage-isolation), never swapped — so provider choice never leaks into what they gate.
- **Briefing collection** and **next-task prioritization**. *No LLM component exists* — `BriefingQueries` and `SmartLists` are deterministic queries today (grep-confirmed: zero provider references). The harness's core rule is "drive the *real* component, never author prompts," so these cannot enter scope until an LLM-backed briefing/ranking component ships. **Deferred**, not prospective.
- **The production routing/escalation layer.** Wiring the winning model/hybrid into the app/daemon is a **follow-up spec** grounded in this harness's numbers. See "Deferred."
- Streaming, production per-request telemetry, non-generative tasks.

## Candidate roster

Exact model ids/prices live in committed config, **not** code — the harness reads current numbers at runtime. Directional:

| Provider | Cheap-tier candidate(s) | Notes |
|---|---|---|
| **Apple** | Foundation Models (on-device) | free; already wired; the **incumbent** / preferred default |
| **OpenAI** | GPT-5 nano, GPT-5 mini | user lean; nano extremely cheap |
| **xAI** | Grok 4.1 Fast | OpenAI-compatible API |
| **Google** | Gemini 2.5 Flash-Lite, Flash | rides the OpenAI-compat endpoint |
| **Anthropic** | Haiku class | via `CloudProvider` Anthropic flavor |
| **Judge** | Claude Opus / Sonnet | the one place we spend more per call |

**Excluded:** DeepSeek, Qwen, any China-hosted model (privacy).

Plumbing: `CloudProvider`/`CloudLLMProvider` already speaks **Anthropic + arbitrary OpenAI-compatible** (flavor + base URL + model + key), so every candidate reaches the model through the existing seam. But "config only, no new code" is **not** true end-to-end — the harness adds stage-isolation injection, label-keyed Keychain accounting, a judge verdict decoder, and per-task corpus DTOs (see below).

## Stage-isolation (core correctness principle)

The real pipelines are multi-stage and some stages call the model. Naively "running the real component with the provider swapped" swaps stages we don't intend to measure — and does so *asymmetrically*:

- `LooseEndExtractor.extract` internally runs `IntentClassifier` on the same provider **before** extracting. `ExtractionRunner` then also runs `SessionSummarizer` on that provider. The trust gate itself (`LooseEndVerifier`) is a deterministic verbatim-substring check — provider-independent.
- The classifier path is asymmetric by provider: the default `classifyGenuineIndices` **throws** on an unparseable response and `IntentClassifier` then **fails open (keeps all)**, while `FoundationModelsProvider` does a real guided-generation drop. So a cloud model that formats indices poorly silently *keeps more* input — inflating its candidate count/recall versus FM.

**Rule:** the harness swaps the model **only at the stage under evaluation** and pins every other model-calling stage to a **fixed reference provider** (default: on-device FM). Concretely, for the extraction task we measure the **candidate-generation call only**; `IntentClassifier` and `SessionSummarizer` run on the fixed reference for every model under test. This (a) makes "classifiers out of scope" honest, (b) removes the fail-open asymmetry from the numbers, and (c) makes per-subtask reporting real. (The `SalienceClassifier` "salience" stage is **not wired** in production and is not part of the extraction task — earlier drafts wrongly named it.)

Where a task has genuine model-calling stages, the harness can evaluate each independently (others pinned), which is exactly the per-subtask data the follow-up routing spec needs.

## The decision rule

Per-task **threshold selection**, not a global ranking:

```
1. Filter to models CLEARING the task's acceptance bar (bars are incumbent-anchored; see below).
   - extraction: precision ≥ incumbent precision (fabrication is a HARD fail) AND recall ≥ incumbent recall
   - soft tasks: judge quality ≥ incumbent quality
   A model must clear the bar ROBUSTLY — by a margin ≥ observed run-to-run noise.
2. Among survivors, rank by:  PRIVACY/LOCALITY → COST → LATENCY → quality
3. Recommend the winner. Do NOT switch away from the incumbent unless a challenger BEATS it
   by ≥ the noise margin. A hybrid strategy competes here like any other model.
```

### Incumbent-anchored bars (how bars are set)
Bars are **not** hand-picked constants. The harness first runs the **currently-shipped default (on-device FM)** over the frozen corpus to measure its precision/recall/quality, and sets each task's bar to that measured incumbent performance (optionally minus a small margin). "Clears the bar" then means **"no worse than what ships today,"** and "recommend a challenger" means **"measurably beats the incumbent"** — a regression test, not an arbitrary filter. Bars, roster, pricing, margins, and the reference provider all live in a committed `eval-config.json`.

## Architecture

New module `Sources/PensieveKit/Eval/`, driven by a thin `pensieve eval` CLI.

### Units
- **`ModelUnderTest`** — a labeled config (`"openai/gpt-5-nano"`) that `makeProvider() -> any LLMProvider` (either `FoundationModelsProvider`, or a `CloudProvider` with flavor + base URL + model id + Keychain key) and carries pricing (`$/1M in`, `$/1M out`; on-device = `$0 (compute)`).
- **`EvalTask`** — binds a task id to (a) the real component + the **stage** it swaps, (b) which corpus items feed it, (c) its scorer. Extensible.
- **`EvalCorpus`** — a **frozen** snapshot sampled once, serialized to a **gitignored** local dir (`.eval/corpus/`). Never committed — private work text. See Corpus.
- **`Runner`** — sweeps `task × model × corpus-item`, calls the provider at the isolated stage, records raw output + wall-clock latency + token counts + outcome. Outcomes distinguish **transport/provider error** vs **output-parse failure** vs **success** (a parse failure is a harness/formatting issue, not model badness, and **never trips the precision hard-gate**).
- **`Judge`** — an Opus/Sonnet `CloudProvider`, run **blinded** (model label stripped, output order shuffled) at **temperature 0**, scoring each output against the task rubric and returning a structured verdict (new decoder — not "config only").

Results aggregate into a **`Scorecard`**.

### Hybrids are first-class competitors
A hybrid FM→online routing strategy is, to the harness, just another `ModelUnderTest` in the same sweep, scored on the same axes. We author a hybrid for a task **only after** the data shows FM breaking somewhere in it — no speculative decomposition (measure-first).

## Extensibility & discoverability

A first-class goal: **adding a new task must be small, and any agent adding a new LLM-backed feature should naturally reach for the harness.** A new capable feature isn't "done" until its default model is justified here.

### Small by construction
Adding a task is a **single-file, ~one-`EvalTask`-value addition** plus a config line — no runner/judge/report changes:
1. Implement an `EvalTask` value: `id`; the real component + the **isolated stage** it swaps + the fixed reference for the rest; a corpus selector + `Codable` DTO; and a scorer (reuse the objective extraction scorer or the rubric judge — a new task usually just supplies **rubric dimensions**, not new scoring code).
2. Register it in the task registry (one line).
3. Add its acceptance bar to `eval-config.json` (or let it inherit from the measured incumbent on first run).

The `EvalTask` protocol is designed to make (1) mostly declarative — the runner, judge, scorecard, cost/latency capture, k=3-near-bar logic, and reporting are all task-agnostic and inherited.

### Discoverability (three pointers, where agents already look)
- **CLAUDE.md convention** (always in context): a short rule — *"Any new `LLMProvider`-backed task must register an `EvalTask` and get a default chosen by `pensieve eval`, not hand-picked. See `Sources/PensieveKit/Eval/README.md`."* This is the primary lever, because CLAUDE.md loads every session.
- **Doc-comment on `LLMProvider`** (the seam you can't skip): a one-line pointer to the harness + the README, so an agent wiring a new model call sees it inline.
- **`Sources/PensieveKit/Eval/README.md`**: a copy-paste "Add a task in 3 steps" recipe with a worked example (narration), the stage-isolation rule, and the incumbent-anchored-bar convention.

### Guardrail
A unit test asserts **registry ↔ config consistency**: every registered `EvalTask` has a bar entry (or an explicit inherit-from-incumbent flag) and vice-versa — so a task added without an eval story fails the suite rather than silently shipping a hand-picked default.

## Scoring & calibration

Tasks under test run at **temperature 0** (extraction/narration/description are not creative; determinism removes most output variance and matches how we'd want them in production). For any model landing **within the noise margin** of a bar, the runner re-runs **k=3** and takes the median; a fabrication must **reproduce** before it fails the hard gate.

- **Objective (extraction).** Precision is sacred: the judge labels each surfaced candidate `grounded | fabricated` against its source text; **any (reproduced) fabrication is a hard fail**. Recall is measured against a **hand-labeled gold set** (~10 items, `pensieve eval gold extraction`).
- **Judge calibration (required before trusting numbers).** The gold set **also carries human `grounded | fabricated` labels on surfaced candidates**, so the harness computes and reports **judge-vs-human agreement** on the precision task. If agreement is poor, no downstream precision number is trustworthy. This is the one calibration the whole precision gate rests on.
- **Rubric judge (soft tasks).** 0–1 per dimension — narration: *grounded / complete / concise / no invented facts*; description: *accurate / specific*. One blinded, temperature-0 pass per output (no ensembles — YAGNI for a single-user tool). The report surfaces a few judge rationales per task for spot-checking.

## Corpus, config & secrets

- **Corpus** — `pensieve eval sample [--n 30] [--seed S]` freezes a sample to `.eval/corpus/`. **Stratified by transcript shape/size (short / long / compacted) AND node kind**, plus **hand-injected stress items**: the longest transcript in the store, one compacted session, one empty/near-empty node — the shapes that actually break cheap models (context truncation, corrupted indices). For description, the corpus item is a **pinned `ProjectContext` snapshot** (the gathered git context, with the source commit SHA recorded in the manifest) — because `NodeDescriber` reads the *live* git working tree and writes back to the DB; the harness drives a read-only `ProjectContext → prompt → complete → sanitize` slice instead.
  - **Reproducibility** comes from the committed-once frozen file (identified by content hash in the manifest), **not** from `--seed` alone: the live store grows between runs, so re-running a seed later draws a *different* sample. Every scorecard records the corpus hash it ran against.
  - Corpus serialization needs explicit **`Codable` DTOs per task family** — `TranscriptMessage`/`Event` are not `Codable` today. Real work; captured as an open item.
- **Config** — one committed `eval-config.json`: roster (label, flavor, base URL, model id, pricing), reference provider, per-task bars/margins, judge model, corpus size/seed. Adding a newly-released model is a config edit.
- **Secrets** — API keys in the **Keychain** via the existing store, keyed by **`ModelUnderTest` label** (`openai/gpt-5-nano`) — **not** by flavor. The roster has several `openAICompatible` vendors (OpenAI, Gemini, xAI) that would collide on a single flavor-keyed slot (the shipped code already migrated off flavor-keying for exactly this reason). `pensieve eval keys set <label>` prompts and stores. Keys never touch config, corpus, logs, or report. Missing key ⇒ that model is skipped with a note (partial runs are fine).

## CLI & reporting

```
pensieve eval sample [--n] [--seed]        # freeze/refresh the corpus (stratified + stress items)
pensieve eval run [--task x] [--model y]   # sweep task×model (filters optional); temp 0; k=3 near bars
pensieve eval report                        # render latest scorecard
pensieve eval keys set <label>              # Keychain (per ModelUnderTest label)
pensieve eval gold extraction               # label recall + human grounded/fabricated (judge calibration)
```

`run` writes machine-readable `scorecard.json` plus a gitignored `report.md`: per task, a table of **model × quality × precision/recall × p50/p95 latency × $/run × outcome-breakdown (success / parse-fail / provider-error)**, the **judge-vs-human agreement**, the **recommended default** per the decision rule, and a few judge rationales. Caveats printed in-report: latency is **not like-for-like** (FM is hardware-bound local compute + multiple calls; cloud is a network round-trip), per-run `$` is **candidate production cost only** (the judge's Opus/Sonnet spend is eval-time, excluded from model cost; FM = `$0 (compute)`), and "recommendation valid for work resembling corpus `<hash>` — re-sample if your workload shifts." Progress + per-call token/latency go through `os.Logger` under a new **`eval`** category. Both `scorecard.json` and `report.md` live under gitignored `.eval/`.

## Testing

Repo rule: **logic is tested PensieveKit; real model calls are not** (they cost money + need keys). Unit tests with a **fake provider + fake judge** cover the silently-wrong parts:
- scorecard aggregation,
- the decision rule (incumbent-anchored bars, robust-margin filter, locality→cost→latency→quality, precision hard-gate, don't-switch-without-margin),
- k=3 median + fabrication-must-reproduce,
- cost math (judge cost excluded; FM `$0`),
- deterministic/stratified sampling + stress-item injection,
- outcome classification (parse-fail vs provider-error vs success),
- config parsing, missing-key skip, label-keyed Keychain resolution,
- **registry ↔ config consistency** (every registered `EvalTask` has a bar entry or an explicit inherit-from-incumbent flag, and vice-versa).

The actual matrix run is a **manual/integration step** you invoke, gated behind keys — never in CI.

## Deferred (explicit)

- **Production routing/escalation layer** — its own follow-up spec, grounded in this harness's per-subtask numbers. You cannot design the escalation boundary before the data shows where FM breaks.
- **Briefing collection + next-task prioritization** — no LLM component exists; enter scope only once an LLM-backed component ships (and authoring their prompts is out of the harness's remit).
- **Judge ensembles / statistical CIs** — YAGNI for a single-user tool; one blinded temperature-0 pass + human calibration + k=3 near-threshold.
- **Streaming, production per-request cost telemetry, non-generative tasks.**

## Files (anticipated)

- `Sources/PensieveKit/Eval/` — `ModelUnderTest`, `EvalTask` (+ per-task definitions with stage-isolation), `EvalCorpus` (+ per-task `Codable` DTOs), `Runner`, `Judge` (+ verdict decoder), `Scorecard`, `EvalConfig`.
- `Sources/PensieveKit/Eval/README.md` — the "Add a task in 3 steps" recipe (discoverability).
- `Sources/pensieve/` — `eval` subcommand group (thin over the Kit).
- Possibly a small refactor exposing `NodeDescriber`'s `ProjectContext → prompt → complete → sanitize` slice for read-only, snapshot-driven evaluation.
- `Sources/PensieveKit/LLM/LLMProvider.swift` — a one-line doc-comment pointer to the harness/README (discoverability at the seam).
- `CLAUDE.md` — a convention line: new `LLMProvider`-backed tasks register an `EvalTask` and get their default from `pensieve eval`.
- `eval-config.json` — committed roster/bars/margins/pricing/reference-provider.
- `.gitignore` — add `.eval/` (before the first `eval sample`).
- `Tests/PensieveKitTests/` — harness-logic suites with fakes (incl. registry ↔ config consistency).

## Open items for the plan

- Exact `EvalTask` protocol shape (how a task exposes its real component + the isolated stage + fixed reference provider to the runner).
- The `NodeDescriber` refactor vs. pinned-SHA approach for description reproducibility (spec leans: freeze `ProjectContext`, read-only slice).
- Judge verdict schema (rubric dimensions + grounded/fabricated as a typed struct).
- Corpus item schema + `Codable` DTOs per task family.
- Gold-set size and the exact judge-vs-human agreement metric/threshold that gates trust.
- The concrete noise-margin estimate (from an initial repeated-run probe) that feeds the robust-clear rule.
