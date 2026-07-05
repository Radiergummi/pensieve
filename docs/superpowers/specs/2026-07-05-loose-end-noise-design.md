# Loose-end noise reduction — design

**Date:** 2026-07-05
**Status:** approved (brainstorming); adversarial review folded (2× opus, 1 Critical +
6 Major/Minor resolved); pending user sign-off → plan
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

> **Revision note (post adversarial review, 2026-07-05):** the first draft detected
> agent briefs by *conversational openers* (`"You are a…"`, `"Your task is…"`). Two
> independent reviews flagged this **Critical**: in a coding-agent session the human's
> genuine intent *is* imperative instruction, so those openers collide with real
> directives (`"You are absolutely right, let's fix the migration"` — the commonest
> Claude approval opener — matches `"You are a…"` and would be silently dropped). The
> design below re-keys brief detection on **length + template structure** (never on
> short conversational messages), moves checklist handling to the candidate level so a
> real ask wrapped around a checklist survives, and fixes truncation at its source.
> See "Risks" and "Validation" for the recall guards.

Each filter is a pure `[X] -> [X]` transform, unit-testable in isolation, and the
two noise families are handled where they are structurally separable: **long
generated blocks** at the message level (so both a brief's opening *and* its interior
sentences die together) and **individual noise quotes** at the candidate level.

### ① `StructuralNoiseFilter` (message-level) — briefs/review-packages only

`static func strip(_ messages: [TranscriptMessage]) -> [TranscriptMessage]`

Runs inside `LooseEndExtractor.extract`, on the `isUserPrompt` set, **before**
`IntentClassifier`. Drops a whole message **only when it is a long, generated agent
brief / review package** — i.e. it satisfies **both**:

1. **Long** — `text.count >= 800` (a threshold no terse human directive reaches;
   tunable, validated by the recall fixture). Short messages are **never** dropped
   here — they flow on to `IntentClassifier` and `CandidateFilter`.
2. **Template-structured** — matches **≥ 2** distinct generated-brief signals:
   - an SDD/review opener at message start: `You are implementing`, `You are
     reviewing`, `You are RE-reviewing`, `You are dispatched`, `High-scrutiny`;
   - an agent-meta-instruction phrase: `Return ONLY`, `Do not `, `Acceptance
     criteria`, `Deliverable:`, `Your job is`, `task-brief`, `review-package`;
   - a task-number reference matching `Task \d+`;
   - **≥ 2** markdown section headers (`^#{1,6} ` or `^\*\*.+:\*\*`).

The free-standing role openers (`You are a/an/the`, bare `Your task is`) are **gone** —
too collision-prone. `IntentClassifier` remains the semantic backstop for briefs this
conservative gate misses; because the gate never touches short messages, it cannot
pre-empt a genuine human directive. **Checklists are NOT handled here** (that was the
old M4 bug — a real ask wrapped around a checklist would lose the ask); checklist
*lines* are dropped at the candidate level instead.

### ② `CandidateFilter` (candidate-level)

`static func strip(_ candidates: [LooseEndCandidate]) -> [LooseEndCandidate]`

Runs in `ExtractionRunner`, on the extractor's output, **before** `verify`. Drops a
candidate when its **quote** (whitespace-normalised, lowercased) is:

- **A closure/ack** — curated set: `looks good`, `sounds good`, `all good`,
  `carry on`, `go ahead`, `approved`, `perfect`, `great`, `nice`,
  `thanks`/`thank you`, `yes`/`yeah`/`yep`/`ok`/`okay`/`done`, `lgtm`. Fires **only
  when the entire quote is closure/filler with no substantive remainder** — either
  the whole quote is a closure token or every clause is (`"looks good, yes."`,
  `"all good, carry on"`). A closure that **prefixes a substantive directive or
  question is KEPT** (`"yes, let's fix 2 and 3 too"`, `"approved, write up the
  spec"`). Concretely: split on `,`/`;`/`—`; strip leading clauses that are wholly a
  closure token; if any remaining clause is substantive (contains a directive verb or
  is a question), keep the candidate. *(Note: the verifier's `minQuoteLength = 15`
  already discards `lgtm`, `all good`, `carry on`, `ok`, `done` etc. before storage;
  this rule's live effect is the >15-char multi-clause closures like `"looks good,
  yes."` — the curated list is complete but the tests should not claim credit for the
  sub-15 drops the length gate already makes.)*
- **A status-check** — the whole quote is a bare progress query, no substantive
  remainder: `are you done`, `is it done`, `did you finish`, `are we ready`,
  `what's the status`, `is … still running`.
- **A checklist / tool-output line** — the quote begins with (or is dominated by)
  `✅`/`❌`/`☑`/`- [ ]`/`- [x]` or a diff marker (`+++`, `@@`). This is the
  candidate-level home for checklist noise (moved here from ①).

**No truncation heuristic here.** The old "starts mid-token / leading lowercase" rule
is **removed** — it could not distinguish a truncation artifact from a legitimate
mid-sentence quote (`"still need to migrate the auth tables before launch"` is a real
loose end and starts lowercase). Truncation is fixed at its source instead (③).

**Curated, not heuristic breadth** — this is what honours the definition boundary.
Directives and substantive questions survive; only the named closure/status/checklist
vocabulary dies.

### ③ Source-level truncation fix

`LooseEndExtractor.splitIntoFragments` / `splitChunk` currently cut oversized
messages (`> chunkCharBudget`, 2500) on **raw character boundaries**, mid-word, then
tag each slice with the message index. The LLM then quotes from a mid-word slice,
producing verbatim-but-truncated quotes (`"om. #479 untouched."`). Fix: split on the
nearest **whitespace boundary** at/under the budget (never mid-word). No fragment cut
mid-token is ever presented to the model, so the truncation noise class disappears at
its source rather than being guessed downstream. (Messages under the budget are
unaffected — the vast majority.)

### Extractor prompt nudge

One sentence added to `LooseEndExtractor.buildPrompt`:

> "Do not extract acknowledgements, approvals, status checks, checklist items, or
> agent task briefs (e.g. 'looks good', 'carry on', 'are you done') — those are not
> loose ends."

Reduces candidates at the source; the deterministic filters are the guarantee.

## Data flow / integration points

- `LooseEndExtractor.extract` (`Sources/PensieveKit/Intelligence/LooseEndExtractor.swift`):
  insert `StructuralNoiseFilter.strip` between `messages.filter { $0.isUserPrompt }`
  and `IntentClassifier(...).filterGenuine`.
- `ExtractionRunner.run` (`Sources/PensieveKit/Intelligence/ExtractionRunner.swift`,
  line 79–80): `let candidates = CandidateFilter.strip(try await LooseEndExtractor…)`
  before `LooseEndVerifier.verify`.
- `LooseEndExtractor.splitIntoFragments`/`splitChunk` (same file): change the split
  point from a raw character offset to the nearest whitespace at/under the budget (③).
- New files: `Sources/PensieveKit/Intelligence/StructuralNoiseFilter.swift`,
  `Sources/PensieveKit/Intelligence/CandidateFilter.swift`.

The two filters are pure and take no dependencies (no DB, no LLM); the split fix is
pure string logic. None can affect capture, ingest, or the verbatim gate. Message
indices are **stored** (`TranscriptMessage.index`, assigned monotonically at parse),
not array positions — confirmed by both reviews — so dropping messages in
`StructuralNoiseFilter` cannot misalign `LooseEndVerifier`'s `messageIndex`
resolution or `sourceMessageIndex`.

## Retroactive cleanup (one-time, live store)

Extraction only *inserts*; re-mining with the new filters produces fewer candidates
but does not remove already-stored noisy loose ends, so a deletion + re-mine is
required. Confirmed safe: `checkpoint` writes a separate `checkpoints` table, and
`ExtractionRunner` is the **only** inserter of loose ends — so no hand-authored loose
ends exist. **But "reconstructable from a transcript" is not an invariant** (reviewer
2, Major 1): `ExtractionRunner` skips events whose transcript file is now
unreadable/missing (line 38–40), and Claude Code `.jsonl` files are external and
user-deletable. An open loose end whose backing transcript is gone would be deleted
and **never re-created** — hence the pre-flight guard below. (Empirically today,
read-only inspection found every open loose end's transcript present on disk, none
zero-byte; and there are currently **0 resolved** loose ends, so the "keep resolved"
step is defensive-but-inert on this store.)

Procedure (performed carefully, once, with before/after counts reported):

1. **Back up** `~/Library/Application Support/Pensieve/pensieve.sqlite`.
2. **Quiesce the daemon** — `launchctl unload
   ~/Library/LaunchAgents/com.pensieve.sync.plist` so the live 300s `pensieve sync`
   (which also runs `RunAtLoad`) cannot race the cleanup (reviewer 2, Major 2).
   Reload at the end.
3. **Pre-flight existence check** — for every `open` loose end, resolve its
   `sourceEventID` → transcript path and `stat` it. **Abort and report** if any is
   missing/unreadable (those would be permanently lost by the delete). Proceed only
   when all exist.
4. **Delete all `open` loose ends**; **keep `resolved`** (dismissals; they also
   suppress re-creation via the existing cross-status verbatim dedup).
5. **Reset watermarks** on every `cc.session` event: `extractedMessageCount = 0`,
   `extractedTranscriptSize = 0` (deliberately **not** `-1` — that is the "legacy,
   don't re-mine" sentinel; `0 != current size` forces the size-gate to fire and,
   with `messageCount >= 0`, `start = 0` re-mines the whole transcript). Verified
   line-by-line by reviewer 2.
6. **Run extraction** via `pensieve sync` → open set rebuilt clean through the new
   filters; resolved dismissals stay suppressed.
7. **Reload the daemon** — `launchctl load ~/Library/LaunchAgents/com.pensieve.sync.plist`.

A one-shot maintenance operation, not a new CLI subcommand (single cleanup of one
personal store — YAGNI).

## Validation (both: labeled fixtures + acceptance run)

Two complementary fixtures — one for precision, one for recall — because they measure
different things (reviewer 1, Major 3: a fixture sampled only from *surviving* loose
ends can go green while production recall regresses on inputs it never contained).

- **Unit tests (TDD)** — per pure function:
  - `StructuralNoiseFilter` — drops long template-structured briefs; **keeps** short
    imperative directives even when they open like a brief (`"You are absolutely
    right, fix the migration"`, `"Your task is to wire up the webhook"`, `"You are
    implementing #2 first, then stop"`); keeps a real ask that merely *contains* a
    checklist.
  - `CandidateFilter` — drops pure closures/status and checklist/tool-output lines;
    **keeps** closure-prefixed directives (`"yes, let's fix 2 and 3 too"`), substantive
    questions (`"can we fix this?"`), and legitimate mid-sentence quotes (`"still need
    to migrate the auth tables before launch"`).
  - `splitIntoFragments`/`splitChunk` — an oversized message splits only on
    whitespace; no fragment starts or ends mid-word.
- **Precision fixture** — sample ~80–100 of the current live loose ends (weighted to
  the noisy nodes `matchory-webapp`/`laravel-openapi`), hand-label each
  loose-end / not-a-loose-end, freeze. Assert **precision rises materially** (noise
  labels dropped) *and* **zero labeled-real quotes dropped**.
- **Adversarial recall fixture** — hand-authored **raw user messages** that are real
  loose ends but *resemble* noise: brief-like openers with genuine intent, closure
  prefixes on real directives, mid-sentence-quotable asks, a real ask wrapped around
  a checklist. Assert the filters **keep** every one (this is the guard the precision
  fixture structurally cannot provide). Frozen as a permanent regression test.
- **On-device acceptance run** — after landing, run real extraction (Foundation
  Models) over a few real transcripts + the noisy ones; eyeball 0-noise /
  0-fabrication and confirm real loose ends survive. Final gate before merge,
  matching the Phase-1B ritual.

## Success criteria

- Noise classes 1–4 materially reduced in the live open loose-end set.
- Both fixtures pass: precision up, **zero real loose ends dropped** (incl. the
  adversarial cases).
- `LooseEndVerifier` untouched; capture/ingest paths untouched.
- On-device acceptance run clean.

## Risks & mitigations

- **Over-aggressive filtering drops real loose ends** → curated vocabularies, not
  breadth; brief detection gated on length+structure (never short messages); the
  adversarial recall fixture is a hard gate; `IntentClassifier` stays as backstop (we
  only *add* deterministic drops, never loosen it).
- **A long human message resembles a generated brief** → requires length ≥ 800 *and*
  ≥ 2 template signals; residual cases are exactly what the adversarial recall fixture
  is built to catch, and the length gate keeps every terse directive safe.
- **Retroactive delete loses a loose end whose transcript is gone** → pre-flight
  existence check aborts before any delete; full DB backup taken first.
- **Daemon races the cleanup** → LaunchAgent unloaded for the duration.
- **Novel brief phrasings the length+structure gate misses** → acceptable residual
  (noise, not lost signal); the precision fixture quantifies it; Approach C (a
  semantic pass) remains available later if the tail is material.
