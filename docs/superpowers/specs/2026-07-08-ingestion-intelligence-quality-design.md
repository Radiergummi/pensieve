# Ingestion intelligence quality — design

**Date:** 2026-07-08
**Status:** approved (brainstorming); **two independent adversarial Opus reviews folded
(2026-07-08)**; pending user sign-off → plan
**Depends on:** Phase-1B intelligence layer (trust gate, extraction pipeline),
the loose-end noise spec (`2026-07-05-loose-end-noise-design.md`), the app narration
feature (slice 3a).

> **Review note (2026-07-08).** Two adversarial reviews (one correctness-focused, one
> design/philosophy-focused) verified the spec against the real code. Their findings are
> folded below: Part B's context-overflow strategy + summarizer input + best-effort
> non-throwing computation + a "generated" affordance; Part A's provider-method work, a
> quote+context-window salience input, a keep-on-low-confidence bias, and success restated
> as precision-at-a-recall-floor (not two absolute gates); Part C's order-independent
> invalidation key, corrected ⌘R semantics, and the corrected `lastOpenedAt` claim; the
> `workSummary`-vs-narration storage reconciliation; and a copy-first, A+B-sequenced
> retroactive re-mine. The prose fixtures are acceptance-ritual evals, not deterministic
> CI gates.

## Problem

Three quality problems observed while dogfooding the live store, all in the
ingestion/intelligence layer, all informed by real data:

1. **"Last Work Done" narration is bogus.** It reads "the project received many
   commits and checkouts" or "the last work done involved processing N prompts" —
   never *what was actually worked on*. Root cause: the narrator is fed a fact sheet
   of **metadata**, not content. `SummaryBuilder.assembleFacts` formats each of the
   last 15 events as `- {kind}: {summary}`, where the summaries are
   (`Ingester.swift`): `git.commit` → the commit subject (rich), `git.checkout` →
   `"checkout <branch>"`, `cc.session` → `"session (N prompts)"`. For session-heavy
   nodes the model has nothing but counts to narrate. This is primarily
   input-starvation, not (only) a Foundation Models ceiling.

2. **Narration regenerates on every launch.** The cache is an in-memory
   `[UUID: String]` on `AppModel`; `drainThenRefresh()` calls `narrationCache.removeAll()`
   on every launch **and** every ⌘R, and nothing is persisted. There is **no
   invalidation key** to decide "node unchanged → keep prose." The original intent
   (persist; regenerate only on state change) was never built.

3. **Loose ends capture nearly every prompt.** Items like "read the spec", "can you
   help me fix this?", "subagent-driven, let's go" are surfaced as loose ends. The
   pipeline separates *recall* (an LLM proposes generously) from *trust* (the verbatim
   gate), but the trust gate (`LooseEndVerifier`) only validates that the quote is
   **real** — never whether the item is genuinely **open/deferred**. The sole
   "is-this-a-loose-end?" judgment is a broad prompt string ("things they said they
   would do, planned, or left unfinished") interpreted by the weak on-device ~3B model.
   Ordinary in-the-moment requests sail through every gate.

## Goal & non-goals

**Goal:** materially improve, on the live corpus, (A) loose-end **precision** by
redefining a loose end around **salience** (deferred/parked/decision work, not
in-the-moment requests), (B) narration **substance** by feeding the narrator real
grounded work content, and (C) narration **stability/cost** by persisting it and
regenerating only when a node actually changes — **without touching the verbatim
trust gate** and **on-device first**.

**Non-goals:**
- **Resolution / follow-through detection** (auto-closing loose ends that were later
  addressed) — deferred to its own spec. This spec is *salience-first*; resolution is
  handled cheaply by the existing manual dismiss + age. **Accepted consequence:** salience
  classifies on *how the intent is framed* (deferred / optional / branching vs an
  in-the-moment request), **not** on whether it was later done. A genuinely-deferred item
  that was in fact completed later ("we should migrate the auth tables" — done next
  session) stays open until manually dismissed. That is resolution's job, not this spec's;
  do not try to solve "said-and-done" here.
- **Cloud/API LLM providers and the app Settings surface** — a separate, now
  raised-priority pillar (see `backlog.md`). This spec stays on-device-first with
  `claude -p` as the existing fallback; it only leaves a **clean seam** to swap the
  salience/narration model later.
- **A custom Create ML classifier** — noted as a future path; this spec produces the
  labeled corpus that would seed it, but trains nothing.
- No changes to the sacred capture path or to `Ingester.drain()`'s LLM-free speed.

## Guiding principles

- **On-device first, escalate only if measured necessary.** Every new judgment runs on
  the `LLMProvider` returned by `makeDefaultLLMProvider()` (Foundation Models when
  available, else `claude -p`). Where a fixture shows the ~3B model is insufficient, the
  design isolates that judgment behind one seam so the provider can be swapped without
  rework.
- **Grounded-with-provenance stays sacred.** The verbatim `LooseEndVerifier` gate is
  untouched; every surfaced loose end still cites real user text. Narration remains
  best-effort prose *outside* the cited gate (as today).
- **Corpus-validated.** The live store's accumulated loose ends are the ground truth:
  hand-labeled fixtures gate every precision/recall claim.

---

## Part A — Loose-end salience

### Operational definition (the boundary)

A **loose end** is a **deferred, parked, or branch-point commitment** — work the
developer flagged as *not being done now*, that could be silently forgotten.

- **IN (salient):**
  - *Deferred/future work* — "we should also migrate the auth tables", "let's do X
    later", "TODO: wire up the webhook", "don't forget the rate limiter", "eventually
    we need to…", "at some point", "would be nice to".
  - *Decision points / roads not taken* — "let's go with A instead of B", "park the
    canvas idea for now", "actually let's do Y" (the not-taken branch is the loose end).
  - *Explicitly-parked explorations* — an idea raised and consciously set aside.
- **OUT (not salient), even though genuine, verbatim user prose:**
  - *In-the-moment requests the assistant just executes* — "read the spec", "can you
    help me fix this?", "run the tests", "subagent-driven, let's go".
  - Acknowledgements, approvals, status checks (already partly handled by
    `CandidateFilter`).

**Key property:** the distinguishing signal is **deferral / optionality / branching in how
the intent is framed** — largely readable from the statement, but the ambiguous band
("let's fix the auth bug" — parked note or do-it-now?) needs a little context. So the
classifier judges the **verbatim quote plus a small surrounding-transcript window** (see
②). The quote is still the evidence (grounded); the window only disambiguates framing.

**Honest limit (folded from review):** in the truly ambiguous band, precision and recall
are *jointly* constrained for a ~3B model — keeping every terse deferral that looks like a
request implies keeping some requests that look like deferrals, and vice-versa. We
therefore (a) bias the classifier to **keep on low confidence** (a retained non-salient
item is noise; a dropped salient item is lost signal, and dropping is the whole point of
the stage, so its error cost is asymmetric — see Risks), and (b) restate success as a
**measured precision gain at a stated recall floor**, not two absolute pass/fail gates
(see Validation).

### Mechanism (two coordinated changes; trust gate untouched)

The pipeline gains **one stage** and sharpens one prompt. Nothing else moves.

```
messages.filter { isUserPrompt }        // TranscriptParser — UNCHANGED
  → StructuralNoiseFilter.strip         // UNCHANGED
  → IntentClassifier.filterGenuine      // UNCHANGED (backstop)
  → LooseEndExtractor.extract           // ① sharpened definition + few-shot
  → CandidateFilter.strip               // UNCHANGED
  → LooseEndVerifier.verify             // SACRED verbatim gate — UNCHANGED
  → SalienceClassifier.filter           // ② NEW — on-device binary salience gate
  → insert                              // ExtractionRunner
```

**① Sharpen the recall stage (`LooseEndExtractor.buildPrompt`).** Replace the broad
"things they said they would do, planned, or left unfinished" definition with the
salience definition above, plus a handful of **few-shot keep/drop examples drawn from
the real corpus**. This reduces candidates at the source but is *not* the guarantee.

**② New stage: `SalienceClassifier` (on-device LLM, positioned after verification).**
A crisp **binary** judgment per verified candidate: *"Is this a deferred / parked /
decision item the developer left open, or an in-the-moment request they had the
assistant do now?"* — returning keep/drop (structured/guided generation, like the other
on-device stages). Rationale: a small model answers a sharp binary far more reliably
than it honors a broad extraction definition. Runs **after** `LooseEndVerifier` so it
only ever judges already-verified, real quotes (cheaper: fewer, higher-quality inputs;
and it can never fabricate — it only filters).

- **Input (judge the quote, not the paraphrase):** the **verbatim quote** plus a **small
  surrounding-transcript window** (e.g. the cited message ± a couple of neighbours,
  char-capped). The LLM paraphrase (`LooseEndCandidate.text`) is *not* the evidence and can
  distort — it may be passed as a secondary hint or omitted. The window text is available
  for free (`ExtractionRunner` already holds the full parsed `session.messages`), so no new
  transcript read is needed.
- **Batching / context budget:** batch candidates like `IntentClassifier` does, with a
  char budget and structured index return, so a batch never blows the context window. The
  per-candidate window is itself char-capped so a batch stays bounded.
- **Fail-open on hard provider error** (a throw) — matching `IntentClassifier`: a
  transient glitch must not silently zero out extraction. An empty *structured* result
  legitimately drops a batch. Combined with keep-on-low-confidence, the stage never
  *aggressively* drops.
- **Provider surface (real work, not "one line").** A structured on-device judgment needs
  a **new `LLMProvider` method** — `classifySalientIndices(prompt:) -> [Int]` — mirroring
  `classifyGenuineIndices`: (i) a protocol default extension that runs `complete` + JSON
  decode and **throws on unparseable** (so callers fail open), and (ii) a bespoke
  `GenerationSchema` override in `FoundationModelsProvider` with a *salience* description
  (not the hard-coded "developer's OWN conversational intent" of the genuine-intent schema).
  `ClaudeCLIProvider` rides the default `complete`→decode path (no override). This is the
  established ~4-touch-point pattern (protocol + default extension + FM schema + tests), not
  a one-line change. **The seam** the design buys is that *swapping which provider* powers
  the judgment later (claude -p, a Settings-selected cloud provider, or a Create ML
  classifier) is then a provider substitution, not pipeline surgery.

**Why a new stage rather than only sharpening the prompt:** the earlier noise spec
(`2026-07-05`) explicitly deferred "Approach C — a semantic is-this-a-loose-end pass" as
a recall gamble, because that noise was *structural* and deterministic filters gave a
provable gain. This problem is different: the residual noise is **genuine, verbatim,
substantive prose that simply isn't deferred work** — exactly the semantic judgment
Approach C described, now scoped tightly to *salience*. **But ① and ② must be proven to
differ:** ① re-tunes the *extractor*; ② re-applies the *same salience definition* on the
*same model*. That is plausibly two bites at one apple. The precision fixture **measures
①-alone vs ①+②**; ② is kept only if it demonstrably adds precision. If a sharpened prompt
alone hits the target, we don't ship a redundant stage.

### Validation (corpus-driven; prose evals are acceptance ritual, not CI gates)

Because salience is a **probabilistic on-device LLM**, the precision/recall *fixtures*
cannot be reliably-green deterministic CI tests (unlike the `2026-07-05` deterministic
filters). They are **acceptance-run evals**, run by hand against Foundation Models at
review time — matching the Phase-1B / strand-naming ritual. Only the stub-driven unit
tests are deterministic CI.

- **Precision eval** — sample ~100–150 of the current live loose ends (weighted to the
  noisy nodes), hand-label each **salient / not-salient**, freeze the labels. Measure
  **precision (①-alone vs ①+②)** and the **recall on the labeled-salient subset**. Gate:
  precision rises materially **at a recall floor** agreed at review (e.g. ≥ 95% of
  labeled-salient retained), not "zero dropped, ever".
- **Adversarial recall eval** — hand-authored real deferred/decision items that *resemble*
  in-the-moment requests (terse deferrals, decision phrasings, parked ideas). Measure how
  many survive; near-total retention expected given the keep-on-low-confidence bias. An
  **eval checklist**, not a frozen unit test.
- **Unit tests (deterministic CI)** — `SalienceClassifier` batching / decoding / fail-open
  and the keep-on-low-confidence rule, with a **stub provider**, mirroring
  `IntentClassifier`'s test style.
- **On-device acceptance run** — run real Foundation Models extraction over several real
  transcripts (incl. the noisy nodes); eyeball 0-noise / 0-fabrication / real deferred
  items survive. Final merge gate.
- The labeled set is retained as the **seed corpus** for a future Create ML salience
  classifier (out of scope here).

### Retroactive cleanup (one-time, live store) — copy-first because the gate is stochastic

Extraction only inserts; re-mining with the salience gate produces fewer candidates but
does not remove already-stored non-salient loose ends, so a delete + re-mine is required.
**Unlike the `2026-07-05` cleanup — which re-mined through deterministic filters and so
provably reproduced the same real items minus noise — the salience gate is a
non-deterministic LLM.** A blind delete-all-`open` + re-mine could permanently drop a
genuinely-open salient item a *second* run would have kept (the step-1 backup is the only
recovery). So the ritual gains a **copy-first diff**:

1. **Back up** `pensieve.sqlite`.
2. **Dry-run on a copy first.** Copy the store; run the reset+re-mine on the copy; **diff
   the before/after open set** and eyeball the dropped items. Only proceed on the live
   store if the drops are all genuinely non-salient. (This is the stochastic-gate guard the
   deterministic noise spec didn't need.)
3. **Quiesce the daemon** (`launchctl unload …com.pensieve.sync.plist`) so the 300 s `sync`
   (RunAtLoad) can't race the cleanup. Reload at the end.
4. **Pre-flight existence check** — for every `open` loose end, resolve `sourceEventID` →
   transcript path and `stat` it. **Abort and report** if any is missing (permanently lost
   by the delete otherwise). Proceed only when all exist.
5. **Delete all `open` loose ends**; **keep `resolved`** (dismissals suppress re-creation
   via the existing cross-status verbatim dedup).
6. **Reset watermarks** on every `cc.session` event: `extractedMessageCount = 0`,
   `extractedTranscriptSize = 0` (**not** `-1`, the "legacy don't re-mine" sentinel).
7. **Run extraction** (`pensieve sync` / `ingest`) → open set rebuilt clean through the
   salience gate; **the same pass backfills `workSummary` for every session (Part B), so
   run the cleanup only after A *and* B have both landed** — one full re-parse, not two.
   Report before/after counts. **Cost note:** this re-parses + re-extracts + re-summarizes
   *every* session in the live store in one shot — a long on-device run (or a large
   serialized `claude -p` batch); expect it to take a while.
8. **Reload the daemon.**

A one-shot maintenance operation, **not** a new CLI subcommand (single cleanup of one
personal store — YAGNI).

---

## Part B — Narration substance (feed content, not metadata)

### Approach: enrich at extraction, narrate over content

- **Store a grounded session work-summary on each `cc.session` event.** `ExtractionRunner`
  already parses each session transcript (for loose-end extraction) and already gates on
  transcript byte-size change. In the same pass, produce a short **on-device** summary of
  *what was worked on this session* and store it. Computed **once per size change**
  (reusing the existing parse + watermark), so `Ingester.drain()` stays LLM-free and fast.
  - **Storage:** additive migration **v10** adds `events.workSummary TEXT` (nullable).
    (A `detailJSON` key was considered; a typed STRICT column is cleaner and keeps the
    terse `summary` — used by the timeline — unchanged.)

- **Summarizer input (must be pinned — it's the quality + overflow crux).** `workSummary`
  summarizes the **whole session** (not just the incremental slice — a stored per-session
  summary must be stable, not reflect only the tail), over the **user prompts + assistant
  responses**, with raw tool-output/noise excluded. A useful "what was worked on" summary
  needs the assistant turns — content the loose-end trust gate deliberately never reads
  (`isUserPrompt`-only). **This is an explicit, bounded groundedness exemption** (best-effort
  prose, same category as narration and strand-naming — outside the cited gate), and it is
  the reason the affordance below matters.

- **Context-overflow strategy (the lesson the extractor already learned).** Sessions are
  multi-MB; a single un-chunked `complete` over a whole session overflows the ~3B window —
  exactly why `LooseEndExtractor` chunks + re-splits (`chunkFragments` / `isContextOverflow`
  / `splitChunk`). The summarizer **must reuse that discipline**: a **hard char cap on the
  stored `workSummary`** (e.g. ≤ ~600 chars), and, when the input exceeds the window,
  **chunk → summarize each chunk → reduce** (map-reduce), reusing the extractor's chunk/
  re-split helpers rather than a naive single call. On-device is well-suited to summarizing
  *present text* (easier than metadata-narration), but only with this bounding.

- **Best-effort, non-throwing — must NOT gate loose-end insertion.** `ExtractionRunner`
  wraps each session in a `do/catch`; any throw skips **both** the loose-end insert **and**
  the watermark advance. So the `workSummary` call is computed with **`try?`** *before* the
  synchronous `db.write`, and its failure yields `nil` and never propagates into the
  extraction `do/catch`. Best-effort narration must never abort or stall the sacred
  loose-end path. (Optionally surface it in `ExtractionResult` for observability.)

- **Narrate over substance.** `SummaryBuilder.assembleFacts` composes the fact sheet from
  **real content**: commit subjects (already rich) + the per-session `workSummary` for
  recent sessions, instead of `"session (N prompts)"`. **Bound the fact sheet:** because
  `narrate`/`build` feed `assembleFacts` to a **single un-chunked `complete`**, replacing 15
  terse lines with 15 real summaries can itself overflow → `narrate` returns `nil` → the
  narration section *vanishes* on the busiest nodes (a strict regression on the feature's
  own target). Mitigate with a **total fact-sheet char budget** (cap the number of session
  summaries included and/or truncate each) so the narrator's single call stays within
  budget. `makePrompt` is otherwise unchanged (still "narrate ONLY these facts").

- **Grounding affordance (workSummary is generated, not verbatim).** The narrator is told
  "narrate ONLY the facts"; feeding it an LLM-generated `workSummary` launders generated
  prose into "Last Work Done" as if it were fact. The CLI `Digest` already fences narration
  with `<!-- generated narration -->`; the app `DetailView` shows it bare. So: (a) constrain
  the `workSummary` prompt tightly ("summarize only work actually done; do not speculate or
  infer"); and (b) add a lightweight **"generated" affordance** to the app's Last-Work-Done
  section (a subtle label/icon) so the widened ungrounded surface is honestly marked. This
  spec **explicitly broadens** the existing narration exemption; it does not pretend the
  surface stays as grounded as before.

- **Reach is limited, not "free" (correction).** Only `Digest` (`build → assembleFacts`) and
  the app narration (`narrate → assembleFacts`) consume `assembleFacts`, so only they
  improve automatically. **Briefing** reads `latest.summary` directly (`BriefingQueries.cards`)
  and **Share/`RecallMarkdown`** prints raw `e.summary` in Recent Activity — neither picks up
  `workSummary` unless separately wired. Feeding `workSummary` into `BriefingCard.latestSummary`
  / `RecallMarkdown` is **additional scoped work**, not automatic; this spec's Part B scope is
  the `assembleFacts` consumers (Digest + app narration). Briefing/Share enrichment is a
  noted optional follow-up.

### Why not narration-time raw-prompt enrichment

Pulling raw prompts into the fact sheet at narration time re-reads transcripts in the
app, risks the narrator quoting noise, and recomputes every open. Storing a session
summary once is more reusable and pairs with Part C's persistence.

### Why `workSummary` may live in the (syncing) canonical store while narration may not

Both are derived, provider-specific LLM prose, so the split needs justifying (Part C keeps
narration *out* of the canonical store). The reconciliation: `workSummary` is a per-event
**input** — a stable, re-narratable enrichment of an immutable event (like the `git show`
enrichment `Ingester` already stores), computed once and rarely changing. Narration is an
**output** cache keyed to volatile whole-node state (top-15 events, count) that changes
constantly and is cheap to regenerate. Syncing a stable per-event input is reasonable;
syncing a fast-churning whole-node output cache across devices that may run different
providers is not. (A future provider swap invalidating stored prose is out of scope here —
see Part C's provider-identity note.)

### Validation

- Unit test `assembleFacts` composes commit subjects + `workSummary` (not
  `"session (N prompts)"`) when present, degrades gracefully when `workSummary` is nil
  (older/unre-extracted events → falls back to the terse `summary`), and **respects the
  fact-sheet char budget** (never emits an unbounded sheet).
- Unit test the summarizer's map-reduce path with a stub provider: an over-budget input is
  chunked and reduced; the output respects the `workSummary` char cap; a provider throw
  yields `nil` (best-effort).
- On-device acceptance: narration on a session-heavy real node reads as *what was worked
  on*, not "many commits and checkouts"; the "generated" affordance shows. Eyeball, part of
  the same acceptance run.

---

## Part C — Persist narration, invalidate only on change

- **Persist** each node's narration prose keyed by node id, alongside an **invalidation
  key** derived from exactly the inputs `assembleFacts` consumes.
- **Invalidation key — order-independent (correctness fix).** Do **not** key on "latest
  event id": `ProjectQueries.status` orders by `occurredAt.desc()` with **no tiebreaker**,
  so with tied timestamps (same-second commits, or a commit + its session) the top row is
  nondeterministic and a `latestEventID`-based key would flip run-to-run — regenerating on
  every launch for exactly the busy nodes Part C protects. Instead key on an
  **order-independent** derivation of the **same top-15 event set** the narrator uses: a
  delimited string over the **sorted** top-15 event IDs + event count + `max(extractedAt)`
  **over that same top-15 set** (captures Part B `workSummary` changes). Handle the
  all-nil `extractedAt` case (git-only nodes have no `cc.session`). Use a **delimited
  string** (`"\(sortedIDs.joined)-\(count)-\(maxExtractedAt)"`), not a numeric hash — no
  collision risk, trivially debuggable. `node.state` is **not** load-bearing for the app
  narration path (`narrate` reads only `events`), so it is optional/harmless to include.
- **Invalidate precisely, but keep ⌘R as a force-refresh (semantics fix).** Two distinct
  triggers, no longer both `removeAll()`:
  - **Launch / liveness refresh:** for each node, keep the persisted prose iff its stored
    key equals the freshly computed key; otherwise drop it (regenerate on next open).
    Unchanged nodes never regenerate — including across launches. This replaces the blanket
    clear.
  - **⌘R (Refresh):** **unconditionally regenerate the currently selected node's** narration
    (drop its cached prose regardless of key). ⌘R is the user's only lever to fix a
    bad-but-current narration; key-based keep-if-unchanged would silently remove it. Keep
    ⌘R = re-narrate for the selection; use key-based keep for everything else.
- **Where:** **device-local in `UserDefaults`, keyed per DB path**, **not** the canonical
  store (input-vs-output rationale in Part B). **Correction:** there is **no existing
  per-DB-path precedent** — `lastOpenedAt` (`pensieve.lastOpenedAt`) and the Focus context
  key are **single global keys** today, so a throwaway `PENSIEVE_DB` smoke launch already
  clobbers them. Per-DB-path keying is a **new pattern this spec introduces**: derive the
  key suffix from `Stores.canonicalURL.path` so throwaway smoke/test stores don't pollute
  the real cache. (Consider giving `lastOpenedAt` the same treatment for consistency —
  optional, out of this spec's required scope.)
- **Scale note (honest):** this stores an unbounded per-node prose+key map in the
  UserDefaults plist (loaded wholesale into memory), unlike the single scalar `lastOpenedAt`.
  For a single-user store (hundreds of short strings) this is fine; if node count ever grows
  large, escalate to a per-DB JSON sidecar. Stated so the footprint isn't a surprise.
- **Provider-identity note (future):** the key omits provider identity, so prose generated
  by one provider persists until its *content* key changes even if the user later swaps
  providers (the deferred Settings work). Out of scope now; noted so it isn't a surprise
  when provider selection ships.

### Validation

- Kit-level: a pure `NarrationCacheKey` (or equivalent) helper that computes the
  invalidation key from `(events, node)` is unit-tested — same key for unchanged inputs;
  **same key regardless of tied-timestamp ordering**; different key when an event is
  added/removed or a `workSummary` changes (`extractedAt` moves); correct on all-nil
  `extractedAt`. Keep the derivation in tested PensieveKit; keep the app's `UserDefaults`
  read/write thin.
- App smoke: relaunch shows persisted prose without an LLM call for unchanged nodes; ⌘R on
  the selected node re-narrates; a new commit/session on a node invalidates it.

---

## Data flow / integration points

- **A①** `LooseEndExtractor.buildPrompt` — sharpen definition + few-shot (same file).
  Weigh the few-shot's fixed-prompt overhead against the 2500-char chunk budget (more
  overhead → more context-overflow re-splits); keep the examples compact.
- **A②** New `Sources/PensieveKit/Intelligence/SalienceClassifier.swift` (pure struct over
  an `LLMProvider`, quote+window input, batching + structured decode + fail-open +
  keep-on-low-confidence). Wired in `ExtractionRunner.run` **after** `LooseEndVerifier.verify`,
  before insert. **New `LLMProvider.classifySalientIndices`** (protocol + default
  `complete`→decode extension that throws-on-unparseable) + a salience `GenerationSchema`
  override in `FoundationModelsProvider`.
- **B** `ExtractionRunner.run` — compute `workSummary` with **`try?` before** the synchronous
  `db.write` (never inside the extraction `do/catch`); persist it in the watermark-advancing
  write. New `SessionSummarizer` (or `SummaryBuilder` method) with map-reduce overflow
  handling + char cap. Migration **v10** (`events.workSummary`) in
  `CanonicalStore.migrateCanonical`; `Event` gains `workSummary: String?`.
  `SummaryBuilder.assembleFacts` composes over it under a fact-sheet char budget. App:
  a "generated" affordance on `DetailView`'s Last-Work-Done section.
- **C** New tested `NarrationCacheKey` helper in PensieveKit (order-independent);
  `AppModel.narrationCache` becomes persisted-per-DB-path (`UserDefaults`, keyed off
  `Stores.canonicalURL.path`) with key-based keep-if-unchanged on launch/liveness and
  **unconditional regenerate of the selected node on ⌘R**. `DetailView` still calls
  `cachedNarration` / `narration`.

None of A/B/C touches capture, `Ingester.drain()`'s LLM-free path, or `LooseEndVerifier`.
All new LLM judgments run on `makeDefaultLLMProvider()`.

## Execution sequence (fold-in from review)

B and C are lower-risk, independently valuable wins; A re-opens the semantic-pass "recall
gamble" the noise spec deferred and is gated behind its eval. Recommended plan order:

1. **B + C** first (narration substance + persistence) — no fixture gamble.
2. **A** — land ① + ②, then run the precision/recall evals. **Go/no-go gate:** if ①+② can't
   hit the precision target at the agreed recall floor on-device, either drop ② (if ① alone
   suffices) or escalate the salience judgment to `claude -p` via the provider seam **before**
   merging A. Do not merge A on a failed eval.
3. **Retroactive re-mine last** — once A *and* B are both merged, run the copy-first,
   one-shot cleanup (one full re-parse backfills `workSummary` and rebuilds the salient open
   set together).

(Still one spec/branch per the packaging decision; this is intra-branch sequencing.)

## Success criteria

- **A:** loose-end precision up **materially at the agreed recall floor** on the live corpus
  (non-salient items gone; ①+② beats ①-alone, else ② is dropped); copy-first re-mine rebuilds
  the live open set with an eyeballed clean diff; verbatim gate untouched.
- **B:** narration on session-heavy nodes describes *what was worked on*, marked as
  generated; `assembleFacts` composes over `workSummary` under a bounded fact sheet and never
  overflows the narrator; `workSummary` computation is best-effort and never gates loose-end
  insertion; degrades gracefully for un-enriched events.
- **C:** unchanged nodes reuse persisted prose across launches with no LLM call; ⌘R
  re-narrates the selected node; changed nodes regenerate; the key is order-independent;
  cache is device-local and per-DB-path.
- On-device acceptance run clean (0 noise / 0 fabrication / real deferred items survive /
  substantive, generated-marked narration).

## Risks & mitigations

- **Salience gate drops real deferred items (asymmetric error cost).** The judge is a flaky
  LLM judging high-value, post-verify *real* prose, and — because the watermark advances
  regardless of inserts — each candidate is salience-judged **exactly once** (never
  re-judged except a full from-0 re-mine). A single wrong "drop" permanently loses a genuine
  loose end. → **keep-on-low-confidence bias**; judge the **verbatim quote + context**, not
  the paraphrase; recall eval + copy-first re-mine diff; `IntentClassifier` backstop
  unchanged. (Note: the once-per-lifetime interaction can't be exercised by the isolated
  classifier eval — hence the conservative bias and the live-diff guard.)
- **No re-proposal loop (verified).** A salience-dropped candidate is *not* re-proposed
  forever: the size gate skips unchanged transcripts and the incremental `start =
  extractedMessageCount` never re-feeds old messages. So dropping is safe from looping (it
  is only *lossy*, per the point above).
- **~3B too weak for the salience binary** → measured against the eval; the provider seam
  escalates that single judgment to `claude -p` (later the Settings-selected provider / a
  Create ML classifier) without pipeline changes.
- **Part B overflow regresses narration on busy nodes** → summarizer map-reduce + char cap;
  bounded fact sheet so the narrator's single un-chunked `complete` never overflows;
  `assembleFacts` degrades to the terse summary when `workSummary` is nil.
- **Part B laundering generated prose as fact** → tightly-constrained `workSummary` prompt;
  "generated" affordance in the app; spec explicitly broadens the narration exemption.
- **Retroactive delete loses a loose end** → copy-first dry-run + before/after diff (the
  stochastic-gate guard); pre-flight transcript-existence check; full backup first.
- **Stale narration key** → order-independent key over the exact narrated top-15 set;
  ⌘R unconditionally re-narrates the selection, so the user always has a manual override.
- **v10 migration** is additive/nullable → no backfill; existing events read
  `workSummary = nil` and re-enrich on their next size-changed extraction (or immediately in
  the post-A+B retroactive re-mine).
