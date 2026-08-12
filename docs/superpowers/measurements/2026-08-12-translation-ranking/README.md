# Translation ranking gate — 2026-08-12

Task 12 of `.superpowers/sdd/2026-08-12-on-device-translation/`: the pre-registered gate deciding
whether Tasks 1–11's shipped design — a German translation joins the FTS5 index as its OWN document,
sharing its original's `item_id`, tagged `language UNINDEXED` — ships as built, or is replaced by the
pre-specified fallback (a separate FTS table per language, `documents_de`).

**Decision rule, fixed before measurement** (see `task-12-brief.md`, which supersedes the plan's
original Task 12 text — that text asked to compare against the committed 0.395, which this document's
own corpus-growth history shows is the wrong comparator):

> If English P@1 in the treated arm is **not significantly worse** than the baseline arm at p < 0.05
> (McNemar on discordant P@1 pairs, n = 1500), the design ships as built. If it **is**, the fallback
> ships instead.

## Result

**SHIPS AS BUILT.** Treated-arm P@1 is statistically indistinguishable from baseline (McNemar
discordant pairs 11 vs 10, p = 1.000 — nowhere near the p < 0.05 rejection threshold). Doubling the
collection size for translated items does not measurably move English BM25 ranking on this corpus.

| arm | P@1 | P@5 | MRR@50 |
|---|---|---|---|
| baseline (English-only) | 0.382 | 0.262 | 0.502 |
| treated (+ German documents) | 0.382 | 0.261 | 0.499 |

McNemar on P@1: baseline-only-right = 11, treated-only-right = 10, discordant n = 21, **p = 1.000**.

n = **1418**, not the targeted 1500 — see §Sample size below for why, and why it does not change the
decision.

Baseline absolute P@1 in context (same-node relatedness gold, same methodology, growing corpus):
0.433 → 0.403 → 0.395 (2026-07-28, n=1500, 2,704 baseline items) → **0.382** (this run, n=1418, 2,878
baseline items). The drift is corpus growth — more items under each node dilutes the same-node gold
set with more distractors — not a broken instrument; 0.382 is well above the "stop, something is
broken" floor of 0.30 the brief set in advance.

## Corpus composition

Both arms generated in one pass, from one snapshot, via `EmbeddableCorpus.gather` (never hand-rolled
SQL) — baseline with no translations, treated with a `TranslationStore` populated by the real
`SystemTranslator` (en→de, on-device, this machine's installed language pack).

| kind | baseline | treated: English (`language=""`) | treated: German (`language="de"`) |
|---|---|---|---|
| node | 278 | 278 | 278 |
| loose_end | 870 | 870 | 870 |
| event | 1,730 | 1,730 | 0 (events are never translated — by design) |
| **total** | **2,878** | **2,878** | **1,148** |

Treated arm total: **4,026** = 2,878 (baseline, byte-identical) + 1,148 (one German document per
translated item). Verified programmatically, not just by eyeball: the treated arm's English-language
item_ids are exactly equal to the baseline's item_id set, and every German item_id is a member of that
same set — i.e. the treated arm is baseline-plus-German-rows, never new or missing items. This is
exactly the corpus shape Tasks 6 and 7 tested for; had it not held, the brief called for stopping
rather than measuring, and it held on the first raw check.

## Translation coverage

Bulk-translated every node name, every non-empty node description, and every open loose-end's text
under an active-or-archived node (matching `EmbeddableCorpus.gather`'s own eligibility exactly — the
same set it would look up translations for). Two runs were needed: the first died mid-pass (see
§What surprised us); the generator was made idempotent (check-then-skip on the hash-keyed
`TranslationStore` before calling the translator) and re-run to completion in the foreground.

| field | denominator (rows in the store) | distinct source texts | coverage |
|---|---|---|---|
| node name | 278 | 272 | **100%** of distinct texts |
| node description | 155 | 155 | **100%** |
| loose-end text | 870 | 848 | **100%** of distinct texts |

Zero nils across all 1,303 translation attempts in the completed run (326 newly translated + 977
already present from the interrupted first run + 0 skipped-nil).

**The 272/278 and 848/870 gaps are NOT missing translations — they are legitimate duplicate source
text**, individually checked: `TranslationStore` is keyed by `(field, source_hash, language)`, so two
nodes with the identical name collapse onto one stored row (`INSERT OR REPLACE`), and the same
translation is correctly returned for both when `gather` looks it up by source text. Verified directly
against the snapshot:

- 6 node-name pairs share identical text: `softmess`, `WLW Category Crawler`, `Svelte Development
  Kit`, `Matchory Crawler`, `Libpostal REST Docker`, `Agent` — each appears on exactly 2 distinct
  nodes. 278 − 6 = 272, the exact observed count. None of these are translation nils; each has a real
  stored German translation, confirmed present in `corpus_de.jsonl`.
- Loose-end text: 870 total open loose ends resolve to exactly 848 distinct strings (16 strings each
  repeated across 2+ loose ends — recurring boilerplate like "What's next?" / "Deferred" / "Parked").
  848 matches the stored-row count exactly.

Every node (556 = 278 × 2) and every open loose end (1,740 = 870 × 2) has a translated document in
`corpus_de.jsonl` — including the ones whose name/text collided on a shared translation.

## What surprised us

**1. The first translation run died silently partway through the loose-end pass** (node names and
descriptions complete, loose ends at 522/870) — caught by the session coordinator, not by this
generator, which had no interruption detection. Root cause: it had been launched detached
(`run_in_background`), and the calling turn ended before it finished, which killed the child. Fixed by
(a) making the generator idempotent — check the hash-keyed store before calling the translator, so a
re-run only pays for what is missing — and (b) re-running it in the **foreground** with a generous
timeout instead of backgrounding it. **Lesson for any future bulk on-device-model pass in this
project: run it in the foreground, or make it durably resumable before backgrounding it.**

**2. Porting rprobe4.swift's hygiene pass introduced its own asymmetry.** rprobe4's committed hygiene
(drop bare `checkout <branch>` events + exact-duplicate texts *within a node*) applies its dedup key
generically across every kind, not just events. Measured on the raw treated corpus, that generic rule
dropped 28 items from the treated arm and 0 from baseline — German node/loose-end documents that
happen to collapse onto text already present under the same node (an unchanged proper noun
translating to itself: `Pipeline`, `Seshat`, `/`, `v3`, branch-like strand names; or two distinct
English loose ends translating to the same German rendering). That is a real property of translation,
but it is **not** what `EmbeddableCorpus.gather` actually does — its P1 dedup is event-only by its own
doc comment. Applying the wider rule here would have silently pruned content production really
indexes, understating the treated arm's dilution and biasing toward a false "ships as built" — the
same class of false-negative risk the brief warned about for an incomplete translation pass, just
introduced by the probe instead of the corpus. **Fixed** by narrowing `tprobe.swift`'s hygiene to
events only (matching `gather`'s real, event-scoped rule); re-verified this makes hygiene a true
no-op on both arms (2,878→2,878, 4,026→4,026) once the fix landed. This is exactly what the brief's
"if the two arms' corpus compositions do not differ in the way you expect, stop and report" was
guarding against — surfaced by the raw corpus-shape check catching the drop, not missed by it.

## Sample size: 1,418, not 1,500

The query sample is drawn **once**, from the baseline corpus, restricted to nodes with between 4 and
200 baseline items (same eligibility rprobe4.swift uses) so a same-node gold set is neither degenerate
nor dominated by one giant node — then sampled without replacement (a real user never asks the same
question twice), capped at `min(targetN, eligiblePoolSize)`, the exact safeguard already present in
rprobe4.swift's own query-sampling loop. On this corpus that pool is exactly **1,418** distinct
item_ids: 97 of 278 nodes qualify (1,418 items), 178 nodes are excluded as too small (<4 items, 224
items), and 3 nodes are excluded as too large (>200 items each — one node alone holds 515) . Since
sampling is without replacement, n cannot exceed the pool, so the sample is effectively the *entire*
eligible pool rather than a proper subsample of it. This is a real property of this corpus's node-size
distribution, not a probe defect — and it does not affect the decision here: the discordant McNemar
counts (11 vs 10) are close enough to symmetric noise that no plausible reweighting to n=1500 would
move the p-value near significance.

## Self-review

- **Query sample built once, from the baseline corpus, reused unchanged in both arms.** `querySample`
  is derived solely from `byNode`, itself built only from `baseline` (the loaded `corpus.jsonl`);
  both `evaluate("baseline", …)` and `evaluate("treated", …)` iterate the same `querySample` array.
- **No German document was ever used as a query.** Every query's text is
  `baselineDocByItemID[queryItemID]!.text` — sourced exclusively from `corpus.jsonl`, whose own
  composition table above shows `language=""` for all 2,878 rows; `corpus.jsonl` never contains a
  `language="de"` row at all, because `dumpCorpusForMeasurement` never receives a `TranslationStore`.
- **`itemID` dedup applied in BOTH arms before scoring.** `rankItems` calls `dedupByItemID` on every
  ranked list in both `baselineRank` and `treatedRank` — the same function, same call site shape; a
  no-op in the baseline arm by construction (exactly one row per item_id there), which is the point.
- **BM25 and metric code came from `rprobe4.swift` unmodified** for the tokenizer (`tok`, byte-for-
  byte identical: diacritic-folded, lowercased, split on non-letter/digit, ≥2-char filter), the BM25
  formula (`k1=1.2, b=0.75`, the same idf and tf-saturation expressions), and the McNemar exact test
  (`logFactorial`/`binomialProbability`, two-sided over discordant pairs). The one necessary
  extension — `skip` widens from a single row index to a `Set<Int>` — exists because the treated
  arm's "self" can be two rows (an English original and its German translation) sharing one item_id;
  this is Trap 2's own requirement, not a substitution of the metric.
- **n = 1,500 target; n = 1,418 achieved**, capped by a real corpus-size ceiling (§Sample size),
  using rprobe4.swift's own `min(target, eligiblePoolSize)` safeguard verbatim. Reported as measured,
  not padded or silently rounded.
- **McNemar counts reported both ways with a p-value:** baseline-only-right = 11, treated-only-right
  = 10, discordant n = 21, p = 1.000.
- **The live stores were never touched.** Everything ran against a `VACUUM INTO` snapshot
  (`snapshot.sqlite`, which does not modify its source) copied to scratch, plus a fresh scratch
  `translations.sqlite`; `PENSIEVE_DB`/`PENSIEVE_MEASURE_DB` pointed at the scratch snapshot for
  every step. `~/Library/Application Support/Pensieve/pensieve.sqlite` was read exactly once, via
  `VACUUM INTO`, and never written.

## Reproducing this

```sh
# 1. Snapshot the live canonical store (VACUUM INTO does not touch the source file).
sqlite3 ~/Library/Application\ Support/Pensieve/pensieve.sqlite \
  "VACUUM INTO '/scratch/snapshot.sqlite'"

# 2. Baseline corpus extract (no translations).
PENSIEVE_MEASURE_DIR=/scratch PENSIEVE_MEASURE_DB=/scratch/snapshot.sqlite \
  ./scripts/test.sh --filter dumpCorpusForMeasurement
# -> /scratch/corpus.jsonl

# 3. Bulk-translate + treated corpus extract. Idempotent (safe to re-run after an interruption —
#    it only pays for what is still missing). Run in the FOREGROUND with a generous timeout; do not
#    background it across a turn boundary, or the process dies with the turn (see "What surprised us").
PENSIEVE_MEASURE_DIR=/scratch PENSIEVE_MEASURE_DB=/scratch/snapshot.sqlite \
  ./scripts/test.sh --filter dumpTranslatedCorpusForMeasurement
# -> /scratch/translations.sqlite, /scratch/corpus_de.jsonl

# 4. Measure both arms, paired.
PENSIEVE_MEASURE_DIR=/scratch swift tprobe.swift
```

`corpus.jsonl`, `corpus_de.jsonl`, and `translations.sqlite` are real captured/generated work text and
are **not committed** — same rule as `.gitignore`'s `.eval/` entry and the 2026-07-28 measurements'
own README.

## On `Tests/PensieveKitTests/TranslatedCorpusDumpGenerator.swift`

Committed, deliberately, in `Tests/` rather than beside `tprobe.swift` here. It cannot live in this
directory as a standalone `swift <file>.swift` script the way `tprobe.swift` does: it calls
`EmbeddableCorpus.gather`, `TranslationStore`, `SystemTranslator`, and `openCanonicalDatabase` — real
PensieveKit/SQLiteData code with compiled package dependencies a bare script invocation cannot import.
It has to run through the SwiftPM test target, exactly like its sibling `CorpusDumpGenerator.swift`
(pre-existing, not written for this task), which sets the precedent this file follows: a no-op unless
both `PENSIEVE_MEASURE_DIR`/`PENSIEVE_MEASURE_DB` are set (so it never runs in CI or an ordinary
`swift test`), doc-commented "NOT a test", real production code paths only (no hand-rolled SQL),
kept for reproducibility rather than as a maintained test. Since `CorpusDumpGenerator.swift` already
established that a guarded generator belongs in `Tests/`, and outgrew its original one-off task to
stay useful for this one, the new file is treated the same way rather than moved somewhere it could
not run.

## Provenance

Produced for Task 12 of `.superpowers/sdd/2026-08-12-on-device-translation/`. `tprobe.swift`'s BM25
and metric code is adapted from `docs/superpowers/measurements/2026-07-28-retrieval-recall/rprobe4.swift`
(not edited — a separate file, per the brief). The corpus-generation test files are in
`Tests/PensieveKitTests/{CorpusDumpGenerator,TranslatedCorpusDumpGenerator}.swift`.
