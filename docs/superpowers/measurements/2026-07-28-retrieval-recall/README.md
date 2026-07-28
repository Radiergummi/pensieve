# Retrieval-recall measurements — 2026-07-28

The evidence behind `specs/2026-07-28-retrieval-eval-harness-design.md`. Committed because that
spec's first draft cited six numbers from probes that were never committed and are now lost — the
same failure mode the transcript-readability spec hit twice. **If a number appears in that spec, the
script that produced it is here.**

These are throwaway measurement probes, not production code: single-file `swift <file>.swift`
scripts, no tests, no error handling. They are kept for auditability, not maintenance.

## Running them

```sh
export PENSIEVE_MEASURE_DIR=/some/scratch/dir   # defaults to cwd
swift rprobe.swift    # anisotropy + per-strategy scores + AUC on provenance gold
swift rprobe2.swift   # same-node relatedness gold set, n=300, head-to-head
swift rprobe3.swift   # hand-written short paraphrase queries, top-3 by inspection
swift rprobe4.swift   # corpus hygiene effect + same-node gold on the CLEANED corpus
```

`$PENSIEVE_MEASURE_DIR` must contain `corpus.jsonl` (see below). `rprobe.swift` writes a `vec.cache`
of embeddings (~5 MB) so later runs are fast; delete it if the corpus changes or the embedder version
moves, or every subsequent number is measured against stale vectors.

## The corpus extract is deliberately NOT committed

`corpus.jsonl` is real captured work text — commit messages, session summaries, loose-end quotes.
It follows the same rule as `.gitignore`'s `.eval/` entry ("private work text + run outputs, never
committed").

**Regenerate it through `EmbeddableCorpus.gather`** — not a hand-rolled SQL mirror, which would
reintroduce exactly the eval/production divergence that reusing `gather` verbatim exists to prevent.
One line per item: `{"kind","itemID","nodeID","text"}` where `kind` ∈ `node` | `loose_end` | `event`.

**Composition at time of measurement** — check any regenerated extract against this before comparing
numbers, so a changed corpus is never mistaken for a changed result:

| kind | count |
|---|---|
| node | 240 |
| loose_end | 704 |
| event | 1,686 |
| **total** | **2,630** |

After the spec's P1 hygiene (drop `git.checkout` events + exact-duplicate texts): **2,264**.

## What each number means, and the one bias that matters

The headline table (`rprobe2`/`rprobe4`) uses a **same-node relatedness** gold set: query = one
document's full text, gold = any other item under the same node, self excluded. Random-baseline P@5 =
0.006, so it carries real signal.

**Its known bias, restated here so it can't be lost:** the query is a *full document*, so this
measures document→document retrieval with long queries, while the real ⌘F/MCP flow is a **short typed
query**. Long queries hand BM25 many rare tokens to match. The direction (BM25 > vector) is
well-supported and corroborated by `rprobe3`'s short paraphrase queries (`vector` ≈ 0/8, `bm25` ≈
2/8), but **the magnitude overstates BM25's edge for short queries.**

`rprobe.swift` also computes the ROC-AUC the spec ended up **deleting** — kept deliberately, because
the reason for deleting it is empirical: AUC ranked `vector` (0.333) above `bm25` (0.062) while BM25's
actual P@5 was 1.7× better. Re-run it before anyone proposes AUC again.

## Provenance

Produced by an adversarial review of the spec's first draft (Opus), then independently re-run and
verified. `rprobe4` was re-executed from this committed copy to confirm the scripts still reproduce
their reported numbers after the path was made configurable.
