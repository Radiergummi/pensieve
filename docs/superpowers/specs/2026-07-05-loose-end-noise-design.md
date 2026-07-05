# Loose-end noise reduction — design

**Date:** 2026-07-05
**Status:** approved (brainstorming), pending adversarial review
**Depends on:** Phase-1B intelligence layer (trust gate, extraction pipeline)

## Problem

Watching the live daemon after Phase-1B, the open loose-end set (232 loose ends,
concentrated in `matchory-webapp` 107 and `laravel-openapi` 62) contains material
noise. Crucially, **this is not a trust-gate failure** — every noisy loose end is
real, verbatim, `role:user` text. `LooseEndVerifier` (the sacred quote gate) is
doing its job; nothing is fabricated. The noise is *real text that is not a loose
end*, slipping through the recall/filter stages that run **before** the gate.

### The noise, characterised from the live store

Four structural classes, in rough order of volume:

1. **Pasted agent briefs / review packages** surfaced as `[user]` loose ends —
   e.g. `"You are implementing Task 6 (the final planned task)…"`,
   `"You are RE-reviewing Task 5…"`, `"High-scrutiny line-by-line CORRECTNESS
   review of…"`, and *mid-brief sentences* like `"The route handlers can branch
   internally or delegate."`. These are the opening/interior prose of
   subagent-driven-development sessions, which Pensieve discovers and mines like
   any human session. The two noisiest nodes are exactly the heaviest
   subagent-driven efforts, so they are saturated with these.

2. **Pasted checklist / tool-output fragments** — `"✅ declare(strict_types=1);
   present"`, `` "✅ Both test names match brief exactly" ``,
   `` "c) **Clean wire protocol — no `" ``.

3. **Closures / acknowledgements / status-checks** — genuine short user turns that
   are the *opposite* of a loose end: `"looks good, yes."`, `"all good, carry on"`,
   `"are you done yet?"`, `"is the research still running?"`. (Note: an approval that
   *prefixes* a real directive — `"yeah, let's draft it"`, `"approved, write up the
   spec"` — is **kept**, per the definition boundary below; only pure closure/status
   turns are targeted.)

4. **Truncated fragments** — `"om. #479 untouched."`, `` "response.no-error` table's " ``,
   `"Missed classes:"`.

### Why they slip through

`TranscriptParser.isUserPrompt` drops `isMeta` records and tag-marked injections
(`<command-name>`, `<system-reminder>`, skill bodies, …) but **deliberately leaves
semantic briefs to `IntentClassifier`** (see its own comment: briefs "have no
reliable marker"). `IntentClassifier` is an on-device LLM that classifies
genuine-intent vs pasted/instructional, **fails open on error**, and — per the live
evidence — misses briefs at volume (some briefs are caught via `isMeta`, others are
not; the classifier is probabilistic and unreliable at scale). Closures/acks are
*genuine* user prose, so neither the parser nor the classifier is meant to drop
them, yet the recall-biased extractor surfaces them as loose ends.

## Goal & non-goals

**Goal:** materially raise loose-end *precision* on the live corpus by removing the
four noise classes, **without dropping any real loose end** and **without touching
the verbatim trust gate**.

**Definition boundary (decided):** keep terse-but-**substantive** questions and
directives (`"let's fix #1 and #2"`, `"take care of the blockers"`, `"can we fix
this?"`); drop only **pure filler** — closures/acks/status-checks and the
structural noise above. This is a curated boundary, not a broad "short & vague"
heuristic.

**Non-goals:** no changes to `LooseEndVerifier`; no new probabilistic stage (a
semantic "is-this-a-loose-end?" LLM pass was considered — Approach C — and
deferred; the noise is overwhelmingly structural and deterministic filters give a
*provable* gain without gambling recall); no new permanent CLI command for the
one-time retroactive cleanup.

## Approach (B — deterministic filter layer)

Two new **pure, deterministic** modules slot into the existing extraction chain.
Nothing else moves. The gate is never touched.

```
messages.filter { isUserPrompt }          // TranscriptParser — UNCHANGED
  → StructuralNoiseFilter.strip(_)        // NEW ①  message-level
  → IntentClassifier.filterGenuine(_)     // existing on-device — now a BACKSTOP, not sole defense
  → LooseEndExtractor.extract(_)          // recall stage — UNCHANGED (+ one prompt sentence)
  → CandidateFilter.strip(_)              // NEW ②  candidate-level
  → LooseEndVerifier.verify(_)            // SACRED verbatim gate — UNCHANGED
```

Two stages because the noise families are structurally different: big pasted blocks
(kill the whole message, so both openings *and* interior sentences die) vs. small
conversational turns (judge the individual quote). Each filter is a pure
`[X] -> [X]` transform, unit-testable in isolation.

### ① `StructuralNoiseFilter` (message-level)

`static func strip(_ messages: [TranscriptMessage]) -> [TranscriptMessage]`

Runs inside `LooseEndExtractor.extract`, on the `isUserPrompt` set, **before**
`IntentClassifier`. Drops a whole message when it matches a deterministic structural
signal:

- **Agent briefs / review packages** — message-start openers (case-sensitive where
  the SDD template is): `You are implementing`, `You are reviewing`,
  `You are RE-reviewing`, `You are taking over`, `You are acting as`,
  `You are a`/`an`/`the` (role assignment), `You are dispatched`,
  `You have been dispatched`, `Your job is`, `Your task is`, `High-scrutiny`.
- **Checklist / tool-output blocks** — a message whose lines are *majority*
  structural: `✅`/`❌`/`☑` / `- [ ]` / `- [x]` bullets, or dominated by a fenced
  code block / diff markers (`+++`, `@@`).

Conservative by construction — patterns no human types as conversational intent.
The `IntentClassifier` remains as a semantic backstop for what these patterns miss.

### ② `CandidateFilter` (candidate-level)

`static func strip(_ candidates: [LooseEndCandidate]) -> [LooseEndCandidate]`

Runs in `ExtractionRunner`, on the extractor's output, **before** `verify`. Drops a
candidate when its **quote** (whitespace-normalised, lowercased) is:

- **A closure/ack** — curated set: `looks good`, `lgtm`, `sounds good`, `all good`,
  `carry on`, `go ahead`, `approved`, `perfect`, `great`, `nice`,
  `thanks`/`thank you`, `yes`/`yeah`/`yep`/`ok`/`okay`/`done`. Fires **only when the
  entire quote is closure/filler with no substantive remainder** — either the whole
  quote is a closure token, or every clause is (`"looks good, yes."`, `"all good,
  carry on"`). A closure that **prefixes a substantive directive or question is
  KEPT** (`"yes, let's fix 2 and 3 too"`, `"approved, write up the spec"`) — err
  toward recall on any remainder that names concrete work. Concretely: strip a
  leading closure token + its comma, and if what remains is itself substantive
  (a directive/question, not another closure), keep the candidate.
- **A status-check** — the whole quote is a bare progress query: `are you done`,
  `is it done`, `did you finish`, `are we ready`, `what's the status`,
  `is … still running` (again, no substantive remainder).
- **A truncated fragment** — clearly cut: ends on a dangling `` ` ``/`(`/`[`; starts
  mid-token (leading lowercase that is not a known intent word — `let's`, `can`,
  `should`, `why`, `how`, `what`, `do`, `would`, `could`, `fix`, `add`,
  `implement`, `we`, `i`, …); or is a bare label ending in `:` (`"Missed classes:"`).

**Curated, not heuristic breadth** — this is what honours the definition boundary.
Directives and substantive questions survive; only the named
closure/status/fragment vocabulary dies.

### Extractor prompt nudge

One sentence added to `LooseEndExtractor.buildPrompt`:

> "Do not extract acknowledgements, approvals, or status checks (e.g. 'looks good',
> 'carry on', 'are you done') — those are not loose ends."

Reduces candidates at the source; the deterministic `CandidateFilter` is the
guarantee.

## Data flow / integration points

- `LooseEndExtractor.extract` (`Sources/PensieveKit/Intelligence/LooseEndExtractor.swift`):
  insert `StructuralNoiseFilter.strip` between `messages.filter { $0.isUserPrompt }`
  and `IntentClassifier(...).filterGenuine`.
- `ExtractionRunner.run` (`Sources/PensieveKit/Intelligence/ExtractionRunner.swift`,
  line 79–80): `let candidates = CandidateFilter.strip(try await LooseEndExtractor…)`
  before `LooseEndVerifier.verify`.
- New files: `Sources/PensieveKit/Intelligence/StructuralNoiseFilter.swift`,
  `Sources/PensieveKit/Intelligence/CandidateFilter.swift`.

Both filters are pure and take no dependencies (no DB, no LLM), so they are trivially
testable and cannot affect capture, ingest, or the gate.

## Retroactive cleanup (one-time, live store)

Extraction only *inserts*; re-mining with the new filters produces fewer candidates
but does not remove already-stored noisy loose ends. Confirmed safe: `checkpoint`
writes a separate `Checkpoint` table, and `ExtractionRunner` is the **only** inserter
of loose ends — so every loose end is reconstructable from a transcript; there are no
hand-authored loose ends to protect.

Procedure (performed carefully, once, with before/after counts reported):

1. **Back up** `~/Library/Application Support/Pensieve/pensieve.sqlite`.
2. **Delete all `open` loose ends**; **keep `resolved`** (they are the user's
   dismissals *and* suppress re-creation via the existing cross-status verbatim
   dedup in `ExtractionRunner`).
3. **Reset watermarks** on every `cc.session` event: `extractedMessageCount = 0`,
   `extractedTranscriptSize = 0` (deliberately **not** `-1` — that is the "legacy,
   don't re-mine" sentinel; `0 != current size` forces the size-gate to fire and,
   with `messageCount >= 0`, `start = 0` re-mines the whole transcript).
4. **Run extraction** via `pensieve sync` → open set rebuilt clean through the new
   filters; resolved dismissals stay suppressed.

A one-shot maintenance operation, not a new CLI subcommand (single cleanup of one
personal store — YAGNI).

## Validation (both: labeled fixture + acceptance run)

- **Unit tests (TDD)** — `StructuralNoiseFilter` (briefs/checklists dropped; real
  messages kept) and `CandidateFilter` (closures/acks/status/fragments dropped;
  directives & substantive questions kept). Pure functions.
- **Labeled fixture** — sample ~80–100 of the current 232 loose ends (weighted to
  the noisy nodes), hand-label each loose-end / not-a-loose-end, freeze as a test
  fixture. A test runs the filters over it and asserts: **precision rises
  materially** *and* the **hard recall guard holds — zero labeled-real quotes
  dropped**. Permanent regression test.
- **On-device acceptance run** — after landing, run real extraction (Foundation
  Models) over a few real transcripts + the noisy ones; eyeball 0-noise /
  0-fabrication and confirm real loose ends survive. Final gate before merge,
  matching the Phase-1B ritual.

## Success criteria

- Noise classes 1–4 gone from the live open loose-end set.
- Every labeled-real loose end retained (recall guard).
- `LooseEndVerifier` untouched; capture/ingest paths untouched.
- On-device acceptance run clean.

## Risks & mitigations

- **Over-aggressive filtering drops real loose ends** → curated vocabularies, not
  breadth; the labeled fixture's recall guard is a hard gate; `IntentClassifier`
  stays as backstop (we only *add* deterministic drops, never loosen it).
- **Brief openers falsely match a human message** (a human writes "You are a…") →
  rare; anchored at message start; caught by the recall guard on the fixture.
- **Retroactive delete removes a wanted open loose end** → it is re-created by
  re-extraction if it is a real loose end; resolved dismissals are preserved.
- **Novel brief phrasings B's patterns miss** → acceptable residual; the fixture
  quantifies it; Approach C (a semantic pass) remains available later if the tail
  is material.
