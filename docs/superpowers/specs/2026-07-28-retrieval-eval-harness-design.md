# Semantic recall remediation — hygiene, BM25, and a paraphrase-only harness

**Date:** 2026-07-28
**Status:** design, revised after an adversarial review that re-measured on the real corpus
**Scope:** three independently shippable pieces, in order. **P1** corpus hygiene (production change,
ungated). **P2** BM25 replaces the semantic half of ⌘F "Related" + MCP `search`; the vector goes
default-off (production change). **P3** a minimal paraphrase-only eval harness over hand-written
queries — the one question still genuinely unanswered.
**Supersedes the diagnosis in:** `backlog.md` → "Semantic relevance floor is inert — OPEN DEFECT".

## Revision note (this document is a rewrite, not a patch)

**Draft 1** proposed a 7-file eval harness with six strategies, a three-part gold set, and ROC-AUC as
its primary cross-strategy metric, and deliberately shipped no production change. An adversarial
review re-measured everything on the **real 2,630-item corpus** (draft 1 rested on an 18-document
hand-built probe) and invalidated three load-bearing choices. What changed, and why:

| Draft 1 | Verdict | Why |
|---|---|---|
| **ROC-AUC** as primary cross-strategy metric | **DELETED** | It pooled scores *across* queries. BM25's per-query scale varies with query length and idf mass, so AUC punishes it for variance, while cosine's anisotropy pins every score near 0.88 and flatters it. Measured: AUC ranked `vector` 0.333 **above** `bm25` 0.062 while BM25's actual P@5 was **1.7×** better. **The spec's own primary metric would have recommended keeping the broken incumbent.** |
| **Provenance-pair gold stratum** ("free, lexically-easy") | **DELETED** | Two ways wrong. 434 of 704 pairs cite an event whose `workSummary` fails the `isSearchable` gate (`EmbeddableItem.swift:54`), so the gold document **is not in the corpus** and every strategy scores a forced miss. And it is the *hardest* stratum, not the easiest — measured query-token overlap with gold is **mean 14.8%**. A loose end is one verbatim sentence; its event's corpus text is an LLM summary of a whole session. |
| **Gibberish negative queries** | **REPLACED** | Lexical methods reject gibberish *by construction* (every token OOV → no candidates → empty result), so "lexical has positive separation" was partly an artifact of a bar it cannot fail. Replaced with **plausible-but-wrong in-domain** queries — the failure users actually see. |
| **`exact` (`SearchQueries`) in the roster** | **DROPPED** | It queries only `Node` and `LooseEnd` (`SearchQueries.swift:60,88`) — no event path — so it scores 0 on **64%** of the corpus by construction, for reasons unrelated to substring matching. The prose note about `SearchQueries.swift:57` is kept; the misleading column is not. |
| **"File-copy of the canonical store"** for the snapshot | **FIXED** | The store is WAL-mode; a plain copy silently drops everything still in `-wal`. Demonstrated drift on the live store (802 vs 803 loose ends). Use `VACUUM INTO`. |
| **"Top-quartile idf" leakage guard** | **MOOT** | Undefinable on this corpus — 42.7% of token types are hapax, all tied at max idf, so the quartile cut lands *inside* the tie block; the intended semantics would flag 57.5% of vocabulary and fire always. P3's hand-written queries remove the need for the guard entirely. |
| **Incumbent-anchored bar alone** | **AMENDED** | The incumbent always clears its own bar, so "nothing cleared it" could never mean "the incumbent is unusable" — which is the actual situation. P3 pre-registers an **absolute** floor alongside it. |
| **"No production change this cycle"** | **REVERSED** | Corpus hygiene and BM25 are supported *now* by n=300 measurement; withholding them behind a measurement cycle was the framing's main cost. |

**Corrections to draft 1's own evidence.** Its anisotropy figures (mean pairwise 0.893, min 0.821)
were over an 18-document hand-built corpus, not the real one — on the real corpus mean pairwise is
**0.854** and min **0.502**, a materially wider cone. And its claim that mean-centring "was tested and
fails" **does not hold on real data**: centring takes mean cross-document cosine 0.854 → ~0.000 and
*slightly improves* P@1/P@5. The conclusion (centring does not rescue retrieval) survives; the stated
evidence for it was wrong. Draft 1's probe files were never committed and are now **lost** — hence
§Evidence below.

## Problem

Semantic recall ships default-on, feeding ⌘F "Related" and the MCP `search` tool every Claude Code
session calls. It does not work, and the original defect report misdiagnosed why.

The report framed it as threshold calibration: the `floor: 0.25` cutoff (`Mcp.swift:220`,
`AppModel.swift:531`) never rejects anything because anisotropic embeddings compress cosine far above
0.25. That symptom is real. But the cause is **ranking failure, not scale failure** — and no
calibration fixes a ranking that is already wrong:

- Gibberish ("banana zeppelin custard velocipede") tops out at **0.880**.
- For "background sync agent login items" the vector's **#1 hit is the wrong document at 0.921** —
  above gibberish, and above many correct hits. The correct document is in the corpus and adequately
  long; BM25 finds it at rank 1–3, the vector misses it entirely.

Mean-pooled token vectors from a *contextual* model were never a sentence-similarity encoder; that is
what SBERT-style training exists to produce. The inert floor is a symptom of an encoder that does not
discriminate.

### Measured, real corpus (2,630 items: 240 nodes / 704 loose ends / 1,686 events)

Gold set = **same-node relatedness** (query = one document, gold = any other item under the same node;
self excluded), n=300 over 82 eligible nodes. Random-baseline P@5 = 0.006.

| Strategy | P@1 | P@5 | MRR@50 |
|---|---|---|---|
| `vector` (**ships today**) | 0.250 | 0.153 | 0.354 |
| `vectorCentered` | 0.257 | 0.165 | 0.365 |
| **`bm25`** | **0.387** | **0.253** | **0.497** |
| `hybridRRF` | 0.323 | 0.215 | 0.444 |

Per-query head-to-head on P@5: **bm25 better on 128, vector better on 30, 142 ties** (sign test
\|128−30\| = 98 vs 2·SE = 12.6 — overwhelming). After P1 hygiene, BM25 rises further to **P@1 0.433**
while the vector *drops* to 0.125.

**Two results that contradict expectations and must not be lost:** `hybridRRF` is **worse than `bm25`
alone** — the vector contributes negatively, so the reflex "hybrid wins" is false here. And
`vectorCentered` is marginally *better*, not worse.

### Known bias in this evidence (stated, not hidden)

Same-node relatedness uses **a full document as the query**, so it measures document→document
similarity with long queries — whereas the real ⌘F/MCP flow is a **short typed query**. Long queries
hand BM25 many rare tokens to match, so this table's **direction is well-supported but its magnitude
likely overstates BM25's edge for short queries.** Corroborating evidence in the same direction, on 8
hand-written short paraphrase queries scored by inspection: `vector` ≈ **0/8**, `bm25` ≈ **2/8**.
Both are bad; BM25 is less bad. **This gap is exactly what P3 exists to close** — and the reason P2
turns the vector off rather than deleting it.

## P1 — Corpus hygiene (ship first, ungated)

The corpus contains junk that occupies top-k slots and pollutes every strategy:

- **261 of 1,686 events (15.5%) are bare `checkout <branch>` strings** — 84 literally `checkout HEAD`,
  72 `checkout main`. These are the *actual* source of the backlog's headline symptom: its gibberish
  top hit was `checkout feat/pensieve-app-three-pane`, and post-hygiene gibberish's top-3 changes
  entirely.
- **400 rows (15%) are exact duplicate texts** across 111 groups; one string can occupy up to 84
  top-k slots.
- 155 of 704 loose ends (22%) have `text == quote` (bare prompt echo).

**Change:** `EmbeddableCorpus.gather` skips `git.checkout` events and de-duplicates identical texts.
Measured effect: 2,630 → 2,264 items, BM25 P@1 0.387 → **0.433**.

**Not in P1:** the `text == quote` loose ends. They are *real* captured user prompts, and suppressing
them is a grounding/recall judgment, not hygiene — it belongs to whoever owns loose-end quality.

Tested in Kit (`gather` is already covered); the semantic index rebuilds itself on next sync.

## P2 — BM25 replaces the semantic half; vector goes default-off

**Retrieval:** an FTS5 + `bm25()` index over the same `EmbeddableCorpus` items, replacing the vector
behind the *existing* seams — ⌘F "Related" (`AppModel.swift:531`) and MCP `search` (`Mcp.swift:220`).
The public shapes (`SemanticHit`, the MCP `SearchItem` JSON, `includeArchived`, Focus visibility,
`excludingIDs`, the canonical re-resolve) are **unchanged**, because every grounding guard lives there
and none of them are the defect.

**The vector stays in the tree, default-off** behind `PensieveDefaults.semanticSearchKey`. It is not
deleted: P3 may yet justify a better encoder behind the same seam, and the sqlite-vec integration was
hard-won.

**The floor:** BM25 scores are unbounded and per-query-scaled, so `floor: 0.25` is meaningless for it
and is **removed, not retuned**. Relevance is instead bounded by rank (`k`) plus the requirement that
a document actually contain query terms — which, unlike cosine, is a real relevance signal. The honest
consequence is stated in the report and in the code comment: **a rank cap is not a relevance
threshold**, and P3 is what would earn one.

**Grounding is untouched.** Retrieval only chooses *which* real stored rows are eligible; the trust
gate governs what may be *said* about them, and this touches neither extraction nor narration.

**Kit-tested:** BM25 index build/query, hygiene interaction, Focus/archived filtering parity with the
vector path (the existing `SemanticQueries` tests are the template), and the MCP JSON contract.

## P3 — A paraphrase-only harness (the one open question)

Two files, not seven, because only one question is left: **does any on-device strategy deliver
"find without remembering the words"?** Both current candidates fail it (0/8, 2/8).

- `RetrievalCorpus` — `VACUUM INTO` snapshot → `EmbeddableCorpus.gather` (verbatim; no parallel corpus
  definition) → content hash recorded in every run.
- `RetrievalMetrics` — pure: recall@{1,5,10}, MRR@10, nDCG@10, and the **operating-point search**
  ("highest threshold retaining recall@10 ≥ 0.8 while rejecting ≥90% of negatives", in each
  strategy's own units, never compared across strategies) with an explicit **`NO VIABLE THRESHOLD`**
  verdict. **No ROC-AUC.**

**Gold set: 30–50 paraphrase queries the user writes**, from real recall needs, each naming the
item(s) it should find. This single choice dissolves LLM circularity, the leakage guard, and the
`--review` flag together — the sole user's own queries *are* the ground truth. Negatives are
**plausible-but-wrong in-domain** queries; OOV-empty cases are reported separately as a trivially
passed class.

**Decision rule:** incumbent-anchored **plus a pre-registered absolute floor** in `eval-config.json`
(minimum paraphrase nDCG@10, and "a viable operating point must exist"), written *before* running, so
the report can conclude "the incumbent is unusable" — which the incumbent-only bar structurally
could not.

**Strategies:** `bm25` (the new incumbent after P2), `vector`, `hybridRRF`. Three, not six —
`vectorCentered` and `vectorSentence` are answered (§Evidence) and `exact` is unmeasurable.

**Where n matters:** the inherited `"noiseMargin": 0.03` corresponds to n≈300; at n=30–50 the
sampling half-width is ~0.13–0.18. So P3's margin is **derived from n**, and P3 is explicitly a
**go/no-go on a bundled sentence encoder**, not a fine-grained ranking of near-equals.

**CLI:** `pensieve eval retrieval {gold,run,report}`, nested under the existing `eval` command
(already has `sample`/`run`/`report`/`keys`/`gold`).

**Guardrail note:** retrieval strategies are not `EvalTask`s, so `TaskRegistry.consistencyProblems`
does **not** cover them and `CLAUDE.md`'s "must register an `EvalTask`" does not apply. P3 adds its own
parallel registry↔config test; a reader must not assume inherited coverage.

## Evidence

Draft 1's probes were uncommitted and are lost, while the spec cited six numbers from them — the same
failure mode this project already hit with the transcript-readability spec. So: the measurement
scripts behind every number above are committed under
`docs/superpowers/measurements/2026-07-28-retrieval-recall/`, with a README stating what each measures
and how to regenerate the corpus extract.

**The corpus extract itself is deliberately NOT committed** — it is real work text (see `.gitignore`'s
`.eval/` rule and its rationale, "private work text … never committed"). Regenerate it through
`EmbeddableCorpus.gather`; its composition at time of measurement (240 / 704 / 1,686 = 2,630) is
recorded so a future run can confirm it is comparing like with like.

## Non-goals

- **Transcript-passage chunking** — its own spec. Explicitly *not* the cause here: the "background
  sync" target document is already present and adequately long, and the vector still misses it. A
  ranking failure on an existing document.
- **Cloud embeddings** — retrieval stays on-device.
- **A bundled sentence encoder** — the decision P3 exists to inform, not a commitment.
- **Suppressing `text == quote` loose ends** — a grounding call, not hygiene (see P1).
- **The trust gate** — untouched throughout.

## Risks

| Risk | Mitigation |
|---|---|
| Same-node gold overstates BM25 (long-query bias) | stated in §Problem; P2 keeps the vector in-tree and off rather than deleting it; P3 measures short queries properly |
| BM25 fails on genuine paraphrase, so P2 ships a feature that still can't do its headline job | P2's report and code comment say plainly that a rank cap is not a relevance threshold; P3 is the go/no-go on fixing it |
| P3's n=30–50 is too small for fine distinctions | margin derived from n; scoped as go/no-go, not a ranking |
| P1 hygiene silently drops something meaningful | `git.checkout` events carry no work content (84 are `checkout HEAD`); de-dup keeps the first occurrence; both covered by Kit tests |
| The snapshot is private work text in the working tree | `VACUUM INTO` under gitignored `.eval/`; state that it must be cleaned after a run |
