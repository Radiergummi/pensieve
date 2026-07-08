# Ingestion intelligence quality — design

**Date:** 2026-07-08
**Status:** approved (brainstorming); pending user sign-off → plan
**Depends on:** Phase-1B intelligence layer (trust gate, extraction pipeline),
the loose-end noise spec (`2026-07-05-loose-end-noise-design.md`), the app narration
feature (slice 3a).

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
  handled cheaply by the existing manual dismiss + age.
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

**Key property:** salience is largely **judgeable from the statement itself** — the
distinguishing signal is deferral / optionality / branching. This keeps the judgment
grounded (the quote is the evidence) and cheap (no cross-session state needed). Context
may sharpen it but is not required for the first cut.

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

- **Input:** the verified quote + its short paraphrase (and optionally a small window
  of surrounding transcript text, if the fixture shows statement-alone is too weak —
  start with statement-alone for simplicity/groundedness).
- **Batching / context budget:** batch candidates like `IntentClassifier` does, with a
  char budget and structured index return, so a batch never blows the context window.
- **Fail-open on hard provider error** (a throw) — matching `IntentClassifier`: a
  transient glitch must not silently zero out extraction. An empty *structured* result
  legitimately drops a batch.
- **The seam:** `SalienceClassifier` takes an `LLMProvider`. Swapping to `claude -p` or
  a future Create ML classifier is a one-line provider/impl change, no pipeline surgery.

**Why a new stage rather than only sharpening the prompt:** the earlier noise spec
(`2026-07-05`) explicitly deferred "Approach C — a semantic is-this-a-loose-end pass" as
a recall gamble, because that noise was *structural* and deterministic filters gave a
provable gain. This problem is different: the residual noise is **genuine, verbatim,
substantive prose that simply isn't deferred work** — exactly the semantic judgment
Approach C described, now scoped tightly to *salience* and guarded by a recall fixture.

### Validation (corpus-driven)

- **Precision fixture** — sample ~100–150 of the current live loose ends (weighted to
  the noisy nodes), hand-label each **salient / not-salient**, freeze. Assert precision
  rises materially (non-salient labels dropped) **and zero labeled-salient items dropped**.
- **Adversarial recall fixture** — hand-authored real deferred/decision items that
  *resemble* in-the-moment requests (terse deferrals, decision phrasings, parked ideas).
  Assert the classifier **keeps** every one. Frozen as a permanent regression test.
- **Unit tests** — `SalienceClassifier` batching/decoding/fail-open, with a stub provider
  (deterministic), mirroring `IntentClassifier`'s test style.
- **On-device acceptance run** — after landing, run real Foundation Models extraction
  over several real transcripts (incl. the noisy nodes); eyeball 0-noise /
  0-fabrication / real deferred items survive. Final merge gate (the Phase-1B ritual).
- The labeled precision set is retained as the **seed corpus** for a future Create ML
  salience classifier (out of scope here).

### Retroactive cleanup (one-time, live store)

Extraction only inserts; re-mining with the salience gate produces fewer candidates but
does not remove already-stored non-salient loose ends. Same careful ritual as the
`2026-07-05` noise spec — a one-shot maintenance operation, **not** a new CLI command:

1. **Back up** `pensieve.sqlite`.
2. **Quiesce the daemon** (`launchctl unload …com.pensieve.sync.plist`) so the 300 s
   `sync` (RunAtLoad) can't race the cleanup. Reload at the end.
3. **Pre-flight existence check** — for every `open` loose end, resolve `sourceEventID`
   → transcript path and `stat` it. **Abort and report** if any is missing (those would
   be permanently lost by the delete, never re-created). Proceed only when all exist.
4. **Delete all `open` loose ends**; **keep `resolved`** (dismissals suppress
   re-creation via the existing cross-status verbatim dedup).
5. **Reset watermarks** on every `cc.session` event: `extractedMessageCount = 0`,
   `extractedTranscriptSize = 0` (**not** `-1`, the "legacy don't re-mine" sentinel).
6. **Run extraction** (`pensieve sync` / `ingest`) → open set rebuilt clean through the
   salience gate; resolved dismissals stay suppressed. Report before/after counts.
7. **Reload the daemon.**

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
  - Summarizing one session's *actual text* is a far easier task for the ~3B model than
    narrating from metadata, so on-device should do well; `claude -p` remains the
    escalation if a fixture says otherwise.
- **Narrate over substance.** `SummaryBuilder.assembleFacts` composes the fact sheet from
  **real content**: commit subjects (already rich) + the per-session `workSummary` for
  recent sessions, instead of `"session (N prompts)"`. The narrator finally has something
  to narrate. `makePrompt` is otherwise unchanged (still "narrate ONLY these facts").
- **Spreads for free:** digest, briefing, and Share (`RecallMarkdown`) all read the
  richer facts.

### Why not narration-time raw-prompt enrichment

Pulling raw prompts into the fact sheet at narration time re-reads transcripts in the
app, risks the narrator quoting noise, and recomputes every open. Storing a session
summary once is more reusable and pairs with Part C's persistence.

### Validation

- Unit test `assembleFacts` composes commit subjects + `workSummary` (not
  `"session (N prompts)"`) when present, and degrades gracefully when `workSummary` is nil
  (older/unre-extracted events) — falls back to the terse `summary`.
- On-device acceptance: narration on a session-heavy real node reads as *what was worked
  on*, not "many commits and checkouts". Eyeball, part of the same acceptance run.

---

## Part C — Persist narration, invalidate only on change

- **Persist** each node's narration prose keyed by node id, alongside an **invalidation
  key** derived from exactly what narration depends on: the identity of the top-15 events
  (latest event id + event count), `node.state`, and — since Part B feeds them in — a
  signal that the session `workSummary`s changed (the latest `extractedAt` / a size-sum
  works, or simply fold `workSummary` presence into the event-identity hash). Concretely:
  a composite key `hash(latestEventID, eventCount, node.state, latestExtractedAt)`.
- **Invalidate precisely.** On launch/⌘R, replace the blanket `narrationCache.removeAll()`
  with: for each node, keep the persisted prose iff its stored key equals the freshly
  computed key; otherwise regenerate on next open. New/changed nodes regenerate; untouched
  nodes never do — including across launches.
- **Where:** **device-local, keyed per DB path** (the `lastOpenedAt` precedent in
  `UserDefaults`), **not** the canonical store. Narration is a derived, provider-specific
  cache; it must not sync across devices that may run different providers, and it needs no
  schema/migration. Keying per DB path also keeps throwaway smoke/test stores from
  polluting the real cache.

### Validation

- Kit-level: a pure `NarrationCacheKey` (or equivalent) helper that computes the
  invalidation key from `(events, node)` is unit-tested (same key for unchanged inputs;
  different key when an event is added / state changes). Keep the derivation in tested
  PensieveKit; keep the app's `UserDefaults` read/write thin.
- App smoke: relaunch shows persisted prose without an LLM call for unchanged nodes; a new
  commit/session on a node invalidates and regenerates it.

---

## Data flow / integration points

- **A①** `LooseEndExtractor.buildPrompt` — sharpen definition + few-shot (same file).
- **A②** New `Sources/PensieveKit/Intelligence/SalienceClassifier.swift` (pure struct
  over an `LLMProvider`, batching + structured decode + fail-open). Wired in
  `ExtractionRunner.run` **after** `LooseEndVerifier.verify`, before insert.
- **B** `ExtractionRunner.run` — produce + persist `workSummary` in the same write that
  advances the watermark. New `SummaryBuilder` (or a small `SessionSummarizer`) method
  for the per-session summary prompt. Migration **v10** (`events.workSummary`) in
  `CanonicalStore.migrateCanonical`. `Event` model gains `workSummary: String?`.
  `SummaryBuilder.assembleFacts` composes over it.
- **C** New tested `NarrationCacheKey` helper in PensieveKit;
  `AppModel.narrationCache` becomes persisted-per-DB-path (`UserDefaults`) with
  key-based invalidation replacing `removeAll()`; `DetailView` unchanged (still calls
  `cachedNarration` / `narration`).

None of A/B/C touches capture, `Ingester.drain()`'s LLM-free path, or
`LooseEndVerifier`. All new LLM judgments run on `makeDefaultLLMProvider()`.

## Success criteria

- **A:** loose-end precision up materially on the live corpus (non-salient items gone);
  precision + adversarial-recall fixtures pass (zero labeled-salient dropped); retroactive
  re-mine rebuilds the live open set clean; verbatim gate untouched.
- **B:** narration on session-heavy nodes describes *what was worked on*; `assembleFacts`
  composes over stored `workSummary`; degrades gracefully for un-enriched events.
- **C:** unchanged nodes reuse persisted prose across launches/⌘R with no LLM call;
  changed nodes regenerate; cache is device-local and per-DB-path.
- On-device acceptance run clean (0 noise / 0 fabrication / real deferred items survive /
  substantive narration).

## Risks & mitigations

- **Salience gate drops real deferred items** → adversarial recall fixture is a hard
  gate; classifier runs *after* the recall stages and only filters; sharpened prompt +
  classifier are validated together against the labeled corpus; `IntentClassifier`
  backstop unchanged.
- **~3B model too weak for the salience binary** → measured against the fixture; the
  one-seam design lets us escalate that single judgment to `claude -p` (and later the
  Settings-selected provider / a Create ML classifier) without pipeline changes.
- **~3B session summaries are thin/wrong** → the task (summarize present text) is far
  easier than metadata-narration; `assembleFacts` still degrades to the terse summary if
  `workSummary` is nil; acceptance run eyeballs quality; escalation seam available.
- **Retroactive delete loses a loose end whose transcript is gone** → pre-flight
  existence check aborts before any delete; full backup first (same guard as the noise
  spec).
- **Invalidation key misses a dependency (stale prose)** → key includes event identity +
  count + state + latest extraction stamp; ⌘R always forces a recompute of the key (not a
  blind regenerate), so a user can still refresh; worst case is one stale recap until the
  next event, which ⌘R fixes.
- **v10 migration** is additive/nullable → no backfill needed; existing events read
  `workSummary = nil` and re-enrich naturally on their next size-changed extraction (or
  immediately after the Part-A retroactive re-mine, which re-parses every session).
