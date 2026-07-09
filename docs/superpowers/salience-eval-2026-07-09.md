# Salience gate — eval outcome & decision (2026-07-09)

**TL;DR:** The merged on-device (~3B Foundation Models) salience gate **fails** a hand-labeled
eval on real data (recall 0.68 — it confidently drops genuine loose ends). `claude -p` Haiku is
far better (recall 0.947) but precision stays modest (0.23) and it is non-deterministic. **Decision:
disable the LLM salience gate (extraction stays lossless) and redesign salience as a deterministic
on-device Create ML classifier fed by an in-app labeling loop, with Haiku as an offline bootstrap
labeler.** The destructive retroactive re-mine (A6) stays parked — an LLM must never be the thing
that deletes loose ends.

## What was evaluated

The "Ingestion Intelligence Quality" plan (already merged to `main`, 2026-07-08) added a post-verify
`SalienceClassifier` drop stage in `ExtractionRunner`: after the verbatim trust gate, an LLM is
asked which verified loose ends are "in-the-moment requests" (drop) vs "deferred / parked / decision
work" (keep). The plan's A5 go/no-go — **hand-labeled eval on real quotes** — had never been run; the
committed fixture was 10 synthetic examples.

## Method

- Drew a fixed **120-item weighted random sample** of `status='open'` loose ends from the live store
  (naturally weighted to the noisy nodes: Pensieve 156 open, Matchory Web App 128, wazuh 92, …; 587
  open total).
- **Hand-labeled** each `{quote, salient}` (user-adjudicated): **19 salient / 101 non-salient**.
- Ran `SalienceClassifier` over the labeled set via `SalienceEvalTests.salienceEvalReport`
  (`PENSIEVE_SALIENCE_EVAL=1`), once on-device and once through `claude -p` Haiku
  (`PENSIEVE_SALIENCE_EVAL_PROVIDER=claude`, `claude-haiku-4-5-20251001`).
- Real labels are kept out of git (they contain private project content): saved under
  `~/Library/Application Support/Pensieve/salience-corpus/` (`labels-2026-07-09.json`,
  `sample-raw-2026-07-09.json`). The in-repo fixture stays the synthetic seed; point the harness at a
  real file with `PENSIEVE_SALIENCE_LABELS`.

## Results

| metric | on-device FM (~3B) | `claude -p` Haiku |
|---|---|---|
| recall (of 19 salient) | **0.68** (lost 6) | **0.947** (lost 1) |
| precision (of kept) | 0.17–0.19 | 0.23 |
| kept / dropped (of 120) | 77–68 / 43–52 | 78 / 42 |
| determinism | **no** (43 vs 52 dropped across identical runs) | one run; LLMs not deterministic |

Genuine loose ends the **on-device** gate deleted: *"going forward, I'd like to combine
tofu/terraform and puppet…"*, *"i would like to decouple this from git… think in terms of
'sources'"*, *"let's use the canonical environment names…"*, *"we should probably pick a consistent
name… think about the API surface"*, *"build the Spotlight integration on top of the AppIntents
skeleton?"*, *"minimal-yet-flexible API… don't just copy the old surface"*. Haiku's single miss was
a borderline item mixing deferred cleanup with an in-the-moment request.

**Un-gated baseline precision** = 19/120 = 0.158. Both models only lift precision modestly
(≤ 0.23) — the gate removes ~40% of noise at best, not the majority.

### Caveat (context degeneracy)

The eval feeds sampled quotes stripped of their real transcript neighbors (all
`sourceMessageIndex = 0`), so the classifier sees minimal context. In real extraction it gets the
actual surrounding turns, which likely helps — so **absolute** precision is probably pessimistic vs.
production. The **relative** result (Haiku ≫ FM) is robust, and the 6 loose ends FM dropped are
self-evident without any context.

## Decision & rationale

1. **Disable the LLM salience gate.** `ExtractionRunner` no longer calls `SalienceClassifier`;
   every verified (verbatim-cited) loose end is surfaced. For a "never lose a real loose end" tool,
   lossless-but-noisy beats a gate that deletes genuine items non-deterministically. The dropped
   items are recoverable later (raw transcripts persist; a watermark-reset re-mine re-proposes them).
2. **Keep the components.** `SalienceClassifier`, `classifyNonSalientIndices`, the sharpened
   extractor prompt, and the eval harness remain for reuse and future evals.
3. **Park the destructive re-mine (A6).** No LLM gate is trustworthy enough to permanently delete
   the open-loose-end backlog.
4. **Redesign salience** as its own brainstorm → spec:
   - **Deterministic on-device gate:** a Create ML `MLTextClassifier` (Swift, on-device, Core ML /
     `NLModel` inference), ideally with `NLContextualEmbedding` features for the subtle
     deferred-vs-in-the-moment semantics.
   - **In-app labeling loop:** one-tap "not a loose end" / "real loose end" on rows during triage →
     accumulating labels → periodic on-device retrain. Distinguish **noise** (negative) from
     **resolved** (positive-that-was-correctly-surfaced) — conflating them poisons training.
   - **Haiku as offline bootstrap labeler:** its 0.947 recall makes it a good pre-labeler for a
     large corpus you then audit — not a runtime gate.
   - Salient is the minority class (~16%), so positive-example volume is the main cost; the in-app
     loop + bootstrap address it.

## Kept assets

- `Tests/PensieveKitTests/SalienceEvalTests.swift` — provider-selectable eval harness (on-device /
  `claude -p`, model via `PENSIEVE_CLAUDE_MODEL`).
- `~/Library/Application Support/Pensieve/salience-corpus/` — the 120 hand-labeled real quotes + raw
  sample (seed corpus for the classifier).
