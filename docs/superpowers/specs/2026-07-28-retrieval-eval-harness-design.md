# Retrieval eval harness — measure before fixing semantic recall

**Date:** 2026-07-28
**Status:** design, awaiting user review
**Scope:** a **measurement instrument only**. No production change to retrieval, ranking, or the
similarity floor. The fix is a separate spec, written once this harness has produced numbers.
**Supersedes the diagnosis in:** `backlog.md` → "Semantic relevance floor is inert — OPEN DEFECT".
That entry's *symptom* is confirmed; its *cause* and its lead remedy are wrong (§Why the original
diagnosis was wrong).

## Problem

Semantic recall ships default-on and feeds ⌘F "Related" plus the MCP `search` tool that every Claude
Code session calls. It does not work, and the reason is not what the defect report says.

The report frames it as a threshold-calibration bug: the `floor: 0.25` cutoff
(`Mcp.swift:220`, `AppModel.swift:531`) never rejects anything because mean-pooled contextual
embeddings are anisotropic, so cosine is compressed far above 0.25. Fix the calibration, fix the
feature. That framing is wrong in a way that matters: **it would have us tune a threshold on a score
that carries almost no signal to threshold.**

### Reproduced measurements

Reproduced 2026-07-28 with a standalone probe that duplicates `NLContextualEmbedder` exactly
(per-token → mean-pool → unit-normalize), over an 18-document corpus shaped like what Pensieve
indexes (git commit subjects, loose-end sentences, node names) and 6 topical + 3 negative queries.

**Baseline anisotropy — the number the defect report was missing:**

| Statistic (unrelated corpus doc vs doc, n=66 pairs) | Cosine |
|---|---|
| min | 0.8214 |
| **mean** | **0.8930** |
| max | 0.9507 |

Every vector lives in a cone between ~0.72 and ~0.96. No constant in that band separates anything —
consistent with the defect report.

**But the encoder, not the threshold, is the problem:**

| Strategy | correct@1 | worst true match | best gibberish | **separation** |
|---|---|---|---|---|
| `NLContextualEmbedding` mean-pooled (**ships today**) | 3/6 | 0.8494 | 0.8801 | **−0.031** |
| `NLEmbedding.sentenceEmbedding` (Apple's sentence model) | 3/6 | 0.4063 | 0.4678 | **−0.062** |
| ~20 lines of idf-weighted lexical overlap | **5/6** | 2.9444 | 1.7047 | **+1.240** |

*Separation* = worst true-match score − best gibberish score. **Negative separation means gibberish
outranks real matches**, so no threshold can enforce relevance regardless of calibration. A crude
lexical baseline is positive by a wide margin — a usable threshold exists for it.

**The report's lead remedy was tested and fails.** Mean-centering (subtract corpus mean vector from
docs and query, renormalize) spreads the scores out — and makes separation *worse*, −0.031 → **−0.507**,
with correct@1 unchanged at 3/6. Centering is near-monotone per query; it cannot repair a ranking that
is already wrong. Spreading a score distribution is not the same as making it discriminate.

### Why the original diagnosis was wrong

Anisotropy is real and measured (mean pairwise 0.893), and it *does* explain why 0.25 never fires. It
does **not** explain gibberish at 0.880 outranking a true match at 0.849 — that is a ranking failure,
not a scale failure. Mean-pooled token vectors from a contextual model were never a sentence-similarity
encoder; that is what SBERT-style training exists to fix. The defect is **retrieval quality**; the
inert floor is a symptom of it.

### Honest limits of this evidence

The probe is 18 documents, 6 topical queries, labels chosen by the author, and — decisively — **biased
toward lexical**: the queries share literal rare tokens ("sqlite-vec", "keychain") with their targets,
which is the case semantic search is *not* needed for. The one low-overlap query ("focus mode filtering
work vs personal") was rank 2 lexically and rank **7** by vector, so the vector did not win there either
— but a 9-query probe cannot choose an architecture. **That is precisely why this spec builds an
instrument instead of a fix.** The prior transcript-readability spec had its evidence base invalidated
twice by loose measurement methodology; this spec treats its own probe as a hypothesis, not a result.

## Goal & non-goals

**Goal.** Produce a trustworthy, repeatable answer to: *which retrieval strategy should Pensieve ship,
and does a usable relevance threshold exist for it?*

**Non-goals** (each deliberately excluded):
- **No production change.** The inert floor stays as-is this cycle. `SemanticQueries`, `SearchQueries`,
  `Mcp.swift`, `AppModel.swift` are untouched except where a strategy adapter *reads* them.
- **No cloud embeddings.** Retrieval stays on-device. Cloud appears only as an opt-in for *gold-set
  generation* (§Gold set).
- **No transcript-passage chunking.** Its own spec (`2026-07-19-transcript-passage-chunking-design.md`);
  it changes the corpus and would confound this measurement.
- **The trust gate is untouched.** The harness is read-only over already-extracted data and calls no
  extraction path. It cannot affect what may become a loose end.

## Architecture

### Placement: a sibling harness, not an `EvalTask`

`pensieve eval`'s protocol is `run(item:model:reference:) -> TaskOutput` where the thing under test is
an `LLMProvider`, and `CellScore` is keyed by model with cost/latency/fabrication. Retrieval has **no
model under test** (the LLM only builds gold offline), its candidates are *strategies*, and its outputs
are ranked lists. Forcing it through `EvalTask` would mean a meaningless `model:` parameter and a
`TaskOutput` that carries no ranking. So: new types, same conventions.

Reused from the existing harness — **conventions, not code**:
- frozen, content-hashed corpus (`CorpusHash`) so runs are comparable;
- `.eval/` for all private work text and run outputs (**gitignored**: "private work text + run outputs,
  never committed"), while bars live in the **committed** `eval-config.json`;
- **incumbent-anchored bars** — never a hand-picked constant;
- a **registry ↔ config consistency test** that fails the suite if strategies and bars drift apart.

```
Sources/PensieveKit/Eval/Retrieval/
  RetrievalStrategy.swift     protocol + the 6 strategy adapters' shared types
  RetrievalGoldSet.swift      gold/negative queries, strata, leakage tags, provenance metadata
  RetrievalCorpus.swift       freeze/load over EmbeddableCorpus.gather
  RetrievalMetrics.swift      recall@k, MRR, nDCG, ROC-AUC, threshold search  (pure)
  RetrievalGoldBuilder.swift  provenance pairs + LLM paraphrase generation + leakage guard
  RetrievalRunner.swift       strategy × query sweep → scorecard
  RetrievalReport.swift       markdown report + recommendation
```

### Corpus

**Reuse `EmbeddableCorpus.gather(db)` verbatim.** The eval must measure the corpus production actually
indexes; a parallel corpus definition would silently diverge and invalidate every number.

**All six strategies MUST read the same frozen snapshot** — otherwise `vector` (which would query the
live `semantic-index.sqlite`) and `exact` (which needs a canonical `DatabaseReader`) would be scored
against different, drifting data and the comparison would be meaningless. So freezing produces three
artifacts under `.eval/retrieval/`, all derived from one point-in-time **read-only copy** of the
canonical store:

| Artifact | Built from | Consumed by |
|---|---|---|
| `snapshot.sqlite` | file-copy of the canonical store | `exact` (as its `DatabaseReader`), and the canonical re-resolve every strategy shares |
| `corpus.json` | `EmbeddableCorpus.gather(snapshot)` — the item list, content-hashed | all strategies; the hash goes in the scorecard |
| `vectors.sqlite` / `fts.sqlite` | built **from `corpus.json`**, not from the live index | `vector`/`vectorCentered`/`vectorSentence` and `bm25`/`hybridRRF` |

The live `semantic-index.sqlite` is never read — it is incrementally maintained and may lag the
canonical store, which would confound the measurement with indexer staleness. A stale snapshot can
never be mistaken for a fresh run because the corpus hash is recorded in every scorecard.

### The six strategies

One protocol, six adapters, all on-device and read-only, zero API cost:

```swift
public struct ScoredItem: Sendable { public let itemID: String; public let score: Double }

public protocol RetrievalStrategy: Sendable {
  var id: String { get }                       // "vector" | "exact" | "bm25" | ...
  /// Ranked best-first. `score` is strategy-scale-specific and NEVER compared across strategies.
  func retrieve(query: String, k: Int) async -> [ScoredItem]
}
```

| id | What it is | Why it's in the roster |
|---|---|---|
| `vector` | today's `NLContextualEmbedder` + sqlite-vec KNN | **the incumbent anchor** — the bar |
| `exact` | shipped `SearchQueries` substring match | what you already get today |
| `bm25` | SQLite **FTS5** + `bm25()` over the same corpus | tokenized lexical; verified available in system SQLite 3.51.0 |
| `hybridRRF` | reciprocal-rank fusion of `vector` + `bm25` | the standard hybrid; scale-free fusion, so it needs no score normalization |
| `vectorCentered` | `vector` with corpus-mean-centered vectors | settles the backlog's proposed remedy on the **real** corpus, not an 18-doc probe |
| `vectorSentence` | `NLEmbedding.sentenceEmbedding` encoder | settles "is it the pooling or the model?" |

**Note on `exact`:** `SearchQueries.swift:57` matches the **whole query as a case-insensitive
substring**, untokenized. A multi-word natural query matches only if that entire string appears
contiguously, so `bm25` is not a variation on what ships — it is a different capability. This is why
both are in the roster.

### Gold set

Three parts, because one part alone would mislead.

**1. Provenance pairs — free, no LLM.** A loose end cites a specific source event; that pair *is* a
relevance judgment already in the canonical store. Query = loose-end text, gold = the cited event.
**Tagged as the `provenance` (lexically-easy) stratum** — its text overlaps the event heavily, so it
flatters lexical strategies. It must never be pooled with paraphrase results.

**2. LLM paraphrase queries — the discriminating set.** For each sampled document, generate the query a
person would actually type to find it, prompted **not to reuse the document's distinctive tokens**.
Gold = the source document. Stratified across item kinds (node / loose end / event).
- Provider: `makeDefaultLLMProvider()` (on-device FM) by default, `--provider` to override to cloud.
  The provider + model is **recorded in the gold file**, so every run is attributable and reproducible.
- **Leakage guard (load-bearing):** after generation, check the query for the gold document's rare
  tokens — "rare" = **top-quartile idf computed over the frozen corpus itself**, not a hand-picked
  constant, so the guard adapts to whatever the corpus actually contains. A violator is regenerated
  once, then tagged `lexicalLeak: true` if it still leaks. Metrics are reported **with and without** leaked queries. Without this guard, "hybrid
  wins" could be a pure artifact of vocabulary bleed-through — the exact bias that makes the author's
  own probe untrustworthy.
- **Spot-check:** `pensieve eval retrieval gold --review` prints a sample for human eyeball; the gold
  file records `reviewed: true|false` and the report states which.

**3. Negative queries — what actually tests the floor.** Deterministic gibberish (fixed word list, no
RNG) plus real-but-unrelated queries ("sourdough starter hydration ratio", "flight change fee"). Gold =
**empty set**. Without negatives, no threshold claim is measurable at all — their absence is why the
original defect report could describe the symptom but not evaluate a remedy.

Stored at `.eval/retrieval/gold.json` (gitignored — it contains real work text).

### Metrics

**Ranking quality, reported per stratum and never pooled:** recall@{1,5,10}, MRR@10, nDCG@10.
Pooling `provenance` with `paraphrase` would let lexically-easy pairs mask paraphrase failure — the
single most likely way this eval could lie.

**Threshold viability** — the floor question, answered properly. Raw scores live on incompatible scales
(cosine ≈0.9 vs BM25's negative log), so **thresholds are never compared across strategies.** Instead:
- **ROC-AUC of gold-hit scores vs negative-query top scores** — scale-free, hence the primary
  cross-strategy separation number. 0.5 = coin flip.
- **The operating point:** the highest threshold retaining recall@10 ≥ 0.8 while rejecting ≥90% of
  negative queries — reported per strategy in that strategy's own units.
- An explicit **"NO VIABLE THRESHOLD"** verdict when the distributions overlap such that no operating
  point satisfies both. Today's `vector` is expected to print exactly this; the report must be able to
  say so rather than emitting a falsely precise number.

### Decision rule

Incumbent-anchored, mirroring the LLM harness. `vector` runs first and **its measured performance is
the bar** — no hand-picked constants. A challenger is recommended only if it beats the incumbent on
**paraphrase** nDCG@10 *and* on AUC, by more than the run-to-run noise margin. Bars live in the
committed `eval-config.json` under a `retrieval` section; a **"no strategy clears the bar"** outcome is
a legitimate, reportable result (and would itself be an argument for turning semantic recall off).

### CLI

Nested under the existing command (which already has `sample`/`run`/`report`/`keys`/`gold`):

```
pensieve eval retrieval gold    [--n N] [--provider auto|local|cloud] [--review]
pensieve eval retrieval run     [--strategy id] [--k 10]
pensieve eval retrieval report
```

Outputs `.eval/retrieval/{scorecard.json,report.md}`: strategy × stratum table, the AUC and
operating-point columns, corpus hash, gold provenance and `reviewed` flag, and a recommendation line
with its reasons.

## Testing

Deterministic, hermetic, no model assets in CI — the real-corpus run stays a local command, matching
the existing harness:
- **Metric math** against hand-built ranked lists with known answers: recall@k, MRR, nDCG (including
  tie handling), ROC-AUC (including the degenerate all-same-score case → 0.5), threshold search
  (including the no-viable-threshold branch).
- **RRF fusion** — ordering under disagreeing input rankings; stability under ties.
- **Leakage guard** — a query reusing a rare token is caught; a legitimate paraphrase is not.
- **Gold set** round-trip (de)serialization, including strata and tags.
- **End-to-end on a tiny fixture corpus** with a **stub embedder and stub LLM** (both already the
  established pattern in this repo's tests), asserting the report renders and the recommendation
  follows the decision rule.

Kit-only, so `./scripts/test.sh` covers all of it. Baseline is **524 tests**.

## Risks

| Risk | Mitigation |
|---|---|
| Generated queries are unnatural / biased, making the instrument itself wrong | leakage guard + `--review` spot-check + per-stratum reporting + recorded generator provenance; cloud opt-in if on-device FM writes poor queries |
| Small single-user corpus → noisy differences | report n per stratum; require a challenger to beat the incumbent by more than a noise margin, not by any margin |
| The author's probe biased the roster toward lexical | the negative-query set and the leakage guard both exist to catch exactly this; `vectorSentence` and `vectorCentered` are in the roster specifically to give the vector side its best shot |
| Eval and production corpora drift apart | `EmbeddableCorpus.gather` is reused verbatim, and the corpus hash is recorded in every scorecard |
| Measuring becomes a substitute for fixing | scope is deliberately one cycle: harness, numbers, then a fix spec |

## Open question deferred to the fix spec

If no on-device strategy clears the bar on paraphrase queries, the fix spec must choose between
lexical-primary retrieval (accepting that "find without exact words" is not actually delivered),
shipping a genuinely better on-device sentence encoder (a bundled model — a real dependency decision),
or turning semantic recall off. **This spec deliberately does not pre-judge that**; it exists to make
the choice evidence-based.
