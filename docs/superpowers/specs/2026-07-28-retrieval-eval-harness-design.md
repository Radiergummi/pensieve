# Semantic recall remediation — hygiene, BM25, and a paraphrase-only harness

**Date:** 2026-07-28, **amended 2026-08-03** (§Amendment — P2 rewritten, was: BM25 replaces only the
semantic half behind unchanged public shapes)
**Status:** design, revised after an adversarial review that re-measured on the real corpus
**Scope:** three independently shippable pieces, in order. **P1** corpus hygiene (production change,
ungated). **P2′** BM25 becomes the *single* retrieval path for ⌘F and MCP `search` — the substring
matcher retires, changed-file paths join the corpus, and the vector goes default-off (production
change). **P3** a minimal paraphrase-only eval harness over hand-written queries — the one question
still genuinely unanswered.
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
| **`exact` (`SearchQueries`) in the roster** | **DROPPED** | It queries only `Node` and `LooseEnd` (`SearchQueries.swift:60,88`) — no event path — so it scores 0 on **64%** of the corpus by construction, for reasons unrelated to substring matching. The prose note about `SearchQueries.swift:57` is kept; the misleading column is not. **Revisited 2026-08-03:** dropping `exact` from *measurement* was right, but it silently left the matcher standing in *production* — P2′ deletes it. |
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

## Amendment (2026-08-03) — P2 becomes P2′

Prompted by a competitive scan of [Contextify](https://contextify.sh) (see `backlog.md` →
"Competitive scan"), which ships git-anchored search — *find sessions by the files they touched* —
a capability this spec did not consider. Three findings forced a rewrite of P2 rather than an
addendum to it.

**1. The substring half was left standing, and P2 could not fix it.** Draft 2 dropped `exact`
(`SearchQueries`) from the eval roster as unmeasurable, correctly: it queries only `Node` and
`LooseEnd`, so it scores 0 on 64% of the corpus by construction. But dropping it from *measurement*
quietly left it in *production*. After P2 as written, ⌘F would still have a substring half that
cannot see events, cannot see file paths, and cannot answer a multi-word query at all — `focus filter
spotlight` returns nothing unless that exact phrase exists verbatim, because the matcher is a single
whole-string `range(of:options:.caseInsensitive)` (`SearchQueries.swift:57`). Two engines over
overlapping corpora with different match semantics is not a state to make permanent.

**2. Changed-file paths are captured and indexed nowhere.** `Ingester.swift:58` writes
`["hash", "branch", "files"]` into `Event.detailJSON`; `EmbeddableCorpus.gather` reads none of it.
"What was I doing last time I touched `SemanticQueries.swift`?" is unanswerable today by either half,
and it is the one query where a file path beats both keywords and embeddings.

**3. Stemming — the obvious thing to steal — is not supported by our own evidence.** The committed
probes tokenize with `lowercased().split(whereSeparator: { !isLetter && !isNumber })` and a ≥2-char
filter, **unstemmed** (`rprobe.swift:98`). That is FTS5 `unicode61`, near-exactly. Shipping `porter`
would layer an unmeasured change onto a measured number — the failure mode the draft-2 rescope
exists to prevent — and porter is English-only against an EN+DE corpus. Porter moves to P3's roster.

**Decision: one corpus, one engine, one ranked list; navigation preserved by presentation.** ("One
list" describes the shipped default. Switching the vector toggle on adds a second, labelled,
experimental section — see P2′ ▸ Surfaces — and is not a supported everyday configuration.) The
alternatives considered were (B) keep two halves but split them by *job* — substring for node
navigation, BM25 for everything else — and (C) leave `SearchQueries` untouched and add BM25 purely
additively. B keeps two engines and two corpora alive for a distinction MCP cannot use; C does not
fix the problem this amendment exists for. A single BM25 list with a pinned Top Hit gets navigation
predictability from ~10 lines of pure code instead of from a second retrieval engine.

**What this costs, stated plainly:** P2 promised "the public shapes … are unchanged". P2′ breaks
that deliberately — the hit type changes, `SearchQueries` is deleted, and MCP `search` returns one
array instead of two. Accepted because Pensieve is single-user and the only consumer of that
contract is the author's own sessions.

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
Both are bad; BM25 is less bad. **This gap is exactly what P3 exists to close** — and the reason P2′
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

Tested in Kit (`gather` is already covered); both derived indexes rebuild themselves on next sync —
after P2′ that is the semantic index *and* the FTS5 search index, since both are produced from this
same `gather`.

## P2′ — BM25 becomes the single retrieval path; file paths join the corpus

### Where the index lives

A **new `search-index.sqlite`**, separate from `semantic-index.sqlite`. Both are derived,
rebuildable, never synced, and sit beside the canonical store. They stay in separate *files* because
`SemanticIndexStore` drops and rebuilds its entire database on embedder-version or dimension change —
sharing a file would tie the FTS5 table's lifecycle to an embedder decision it has nothing to do
with, and P2′ is turning the vector *off*. Separate files also let the vector index be deleted
outright later without touching search. The canonical store is untouched: it is the only store that
will ever sync, and a derived index has no business in it.

### What a document is

**One FTS5 row per `EmbeddableItem`**, with the corpus reused verbatim from `EmbeddableCorpus.gather`
(post-P1 hygiene) rather than re-derived — the same discipline P3 applies to its snapshot, so hygiene
fixes land in both indexes at once.

| Column | Indexed | bm25 weight | Contents |
|---|---|---|---|
| `text` | yes | 1.0 | exactly what the vector embeds today: node name + description, loose-end text + quote, event `summary` or `workSummary` |
| `files` | yes | **0.1** (pinned by test) | newline-joined changed-file paths — **events only**, empty elsewhere |
| `item_id`, `kind`, `node_id`, `state` | no | — | metadata, mirroring the `vec0` table so state/archived filtering happens in-query |

`EmbeddableItem` gains one additive field, `files: String` (default empty). **The semantic path
ignores it** — file paths must not enter embedded text. `gather` decodes a `detailJSON` field the
ingester already writes.

**Scope limit to record:** the `files` column makes a commit's paths *findable*; it is not a reverse
file→events index. Querying a path returns commits ranked by BM25, not a complete chronological
history of that file. That answers "what was I doing when I touched this", which is the goal, and it
is not a file-history view.

### Matching

**Tokenizer: `unicode61 remove_diacritics 2`, unstemmed** — reproducing the tokenization every
measured number in this document rests on (§Amendment finding 3). Known divergence: the probes
dropped 1-char tokens, FTS5 indexes them; immaterial to ranking, but "identical" is "near-identical".

**A pure `FTSQuery` builder — user input never reaches `MATCH` raw.** FTS5 `MATCH` is a query
language, so `don't`, `C++`, a stray `:`, or an unbalanced quote throw a SQLite error on ordinary
typing. The builder:

- splits input into balanced quoted phrases and bare terms, recognising a leading `files:` column
  filter — **FTS5's own column syntax, not a hand-rolled parser**;
- emits each term as a double-quoted FTS5 string literal with internal quotes doubled, disabling all
  operator interpretation;
- ANDs terms explicitly;
- appends `*` to the **last** term only, and only when the input did not end in whitespace — the
  as-you-type prefix idiom that makes typing `pens` surface Pensieve;
- returns nil when input tokenizes to nothing, so a malformed `MATCH` is never executed.

**Two limitations, stated rather than discovered later.** Identifiers do not split on case:
`SemanticQueries.swift` yields `semanticqueries` + `swift`, so `Semantic` matches only via the
prefix `*` and `Queries` does not match at all. Path segments tokenize individually, so `PensieveKit`
matches every file beneath it — which is what the 0.1 `files` weight exists to contain.

### Results, guards, and the Top Hit

**One hit type.** `SemanticHit` → `SearchHit`, `similarity` → `score`; the name must not claim an
engine, since P3 may bring a better encoder back behind the same seam.
`SearchResults`/`NodeHit`/`LooseEndHit` retire with `SearchQueries`.

**Every grounding guard survives verbatim** — Focus visibility via `visibleNodeIDs`,
state/`includeArchived` filtering in-query, `excludingIDs`, and the load-bearing **canonical
re-resolve**: each candidate is re-fetched from the canonical store and re-checked against the live
corpus predicate, and anything failing is dropped silently as a stale index row rather than a result.
BM25 changes which rows are *eligible*, never what may be *said* about them. Extraction and narration
are untouched.

**The over-fetch loop simplifies.** `SemanticQueries` over-fetches `k' = max(k*8, 50)` and grows `k`
with a floor-aware early exit. With no floor that exit cannot exist — and per the backlog it never
fired correctly. Termination becomes the honest condition: stop when the index returns fewer rows
than requested (exhausted), or at the 2000 cap.

**The floor:** BM25 scores are unbounded and per-query-scaled, so `floor: 0.25` is meaningless and is
**removed, not retuned**. Relevance is bounded by rank plus the requirement that a document actually
contain the query's terms — which, unlike cosine on this corpus, is a real signal. The honest
consequence stays in the report and in a code comment: **a rank cap is not a relevance threshold**,
and P3 is what would earn one.

**Result cap:** `SearchQueries`' existing `prefix(50)` carries over unchanged as the cap on the
returned list, so the app's result volume does not change with the engine.

**Top Hit is a pure function**, `topHit(query:in:) -> SearchHit?` selected *from the returned hits*
rather than by a second query — the first `kind == "node"` hit
whose name has the query as a case- and diacritic-insensitive word prefix. The app pins it above the
list; MCP ignores it. All navigation predictability lives in ~10 testable lines, with no second
engine behind it.

**Snippets stay `SnippetMaker`**, extended to take the term list and highlight the first term that
occurs. FTS5's native `snippet()` was considered — the platform-primitive answer — and rejected:
display text is deliberately re-resolved from the *canonical* store, so an index-derived snippet
could render text that no longer exists (a grounding regression), and it would mean parsing FTS5's
marker string back into the tested `Snippet` triple. Being unstemmed keeps substring highlighting
correct, since matched text is always a query term or its prefix.

### Maintenance

**Full rebuild, never incremental.** `SemanticIndexer` needs membership/metadata reconciliation
because embedding is expensive; FTS5 has no such cost — 2,264 documents rebuild in milliseconds. Drop
and reinsert in one transaction, deleting a whole class of staleness bugs instead of reimplementing
them. Runs at the seams `SemanticIndexer` already uses (after extraction in `SyncRunner`, and on app
refresh) and stays best-effort: an index failure yields empty results and never blocks capture or
ingest. **No toggle** — BM25 is no longer optional. `PensieveDefaults.semanticSearchKey` now governs
the vector alone, default-off.

### Surfaces

- **⌘F** — one ranked list with the Top Hit pinned above it. The existing Active / Include-Archived
  scope bar now governs the whole list; today it governs only the exact half, so that inconsistency
  disappears for free.
- **MCP `search`** — a single `items` array instead of `exact` + `related`; a structured `file`
  parameter so Claude never constructs query syntax; `include_archived` finally covers everything it
  claims to.
- **Vector toggle on** — vector hits appear as a separate, clearly-labelled section *below* the BM25
  list, excluding what BM25 already returned. Keeps P3's comparison possible without muddying the
  primary result.

**The vector stays in the tree, default-off** behind `PensieveDefaults.semanticSearchKey`. It is not
deleted: P3 may yet justify a better encoder behind the same seam, and the sqlite-vec integration was
hard-won.

### Verification gate

**The `files` column is unmeasured.** P@1 0.433 was measured without it, and adding an indexed column
changes BM25's document-length normalisation even at weight 0.1. The probe scripts are committed
precisely so they can be re-run: after P1 + P2′, re-run `rprobe` on a fresh `VACUUM INTO` snapshot and
confirm **P@1 ≥ 0.433**, or explain the regression. This keeps the amendment inside the evidence
discipline the draft-2 rescope established rather than riding on a number it quietly invalidated.

### Kit-tested

`FTSQuery` builder against hostile input (apostrophes, unbalanced quotes, colons, emoji, CJK,
umlauts, a lone `*`, pure punctuation); index build + rebuild idempotence; a pinned test that a
`files`-only match ranks below a `text` match, so the 0.1 weight cannot drift silently; hygiene
interaction; Focus/archived/`excludingIDs` parity with the vector path (the existing `SemanticQueries`
tests are the template) including a stale index row dropped by the canonical re-resolve; `topHit`
purity; file anchoring end-to-end, both bare and via `files:`; and the MCP JSON contract. The app
target has no unit tests — build + smoke-launch + eyeball, as always.

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

**Strategies:** `bm25` (the new incumbent after P2′), `bm25Porter`, `vector`, `hybridRRF`. Four, not
six — `vectorCentered` and `vectorSentence` are answered (§Evidence), and `exact` is gone rather than
merely unmeasurable, since P2′ deletes it. **`bm25Porter` is new to this amendment:** stemming is the
one Contextify idea with a plausible mechanism that our own evidence neither supports nor refutes
(§Amendment finding 3), and paraphrase recall is exactly where it would show up if it helps.

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
- **A reverse file→events index / file history view** — P2′ makes paths *findable*, not enumerable
  (see P2′ ▸ What a document is).
- **Camel-case identifier splitting** — `Queries` will not match inside `SemanticQueries.swift`.
  A tokenizer change, and unmeasured; revisit if the file-anchored case proves weak in use.
- **Stemming as a shipped default** — moved to P3's roster as `bm25Porter` (§Amendment finding 3).
- **`pensieve doctor` and index-staleness reporting on the answer path** — the honest-degradation
  siblings from the same competitive scan. Own spec; see `backlog.md`.
- **Live Recall (`watch`/`tail`/`since`)** — coordination between parallel sessions, a different
  product axis from recall. Parked in `backlog.md`.

## Risks

| Risk | Mitigation |
|---|---|
| Same-node gold overstates BM25 (long-query bias) | stated in §Problem; P2′ keeps the vector in-tree and off rather than deleting it; P3 measures short queries properly |
| BM25 fails on genuine paraphrase, so P2′ ships a feature that still can't do its headline job | P2′'s report and code comment say plainly that a rank cap is not a relevance threshold; P3 is the go/no-go on fixing it |
| **P2′ deletes the substring matcher, so a query that used to hit literally now depends on ranking** | the Top Hit pin restores guaranteed node navigation; FTS5 phrase queries (`"…"`) restore guaranteed literal matching; both are Kit-tested |
| **The `files` column dilutes BM25 and silently regresses the measured 0.433** | weight pinned at 0.1 by test; §Verification gate re-runs the committed probe and requires P@1 ≥ 0.433 before P2′ is considered done |
| **Raw user input reaches FTS5 `MATCH` and throws on an apostrophe** | input never reaches `MATCH` unescaped — the pure `FTSQuery` builder quotes every term as a string literal, with hostile-input tests |
| **Two derived index files drift apart or double the rebuild cost** | both rebuild from the *same* `EmbeddableCorpus.gather`; the FTS5 rebuild is a full drop-and-reinsert measured in milliseconds, with no reconciliation logic to drift |
| P3's n=30–50 is too small for fine distinctions | margin derived from n; scoped as go/no-go, not a ranking |
| P1 hygiene silently drops something meaningful | `git.checkout` events carry no work content (84 are `checkout HEAD`); de-dup keeps the first occurrence; both covered by Kit tests |
| The snapshot is private work text in the working tree | `VACUUM INTO` under gitignored `.eval/`; state that it must be cleaned after a run |
