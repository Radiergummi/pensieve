# Incremental Re-Extraction (Design)

**Date:** 2026-07-04. **Status:** approved in brainstorming; revised after an adversarial review +
empirical transcript verification. Ready for a plan. **Prerequisite sub-project** for the sync daemon
(`…-sync-daemon-design.md`), and independently useful — it makes even a manual `pensieve ingest`
lossless across paused/resumed sessions.

## Goal

Today a Claude session is extracted for loose ends **exactly once** (`ExtractionRunner` filters to
events with `extractedAt == nil`, then stamps it). A session that is ingested mid-work — or ends,
gets extracted, then is resumed — never has its later messages extracted, so **loose ends from the
back half of paused/resumed sessions are silently lost.** Pause-then-resume is the normal ADHD
workflow this tool exists for. This sub-project changes extraction from *once* to *incremental*:
re-extract a session's **new** messages whenever its transcript has grown, without duplicating what
was already surfaced.

## The key realization (why this is small + safe)

`ExtractionRunner.run()` (`Intelligence/ExtractionRunner.swift`) already:
- **re-parses the live transcript** each run from the stored `detailJSON["transcriptPath"]`, so it
  always sees the *current* full message list; and
- **dedups** newly-verified loose ends by normalized quote against the node's existing **open** loose
  ends before inserting.

So re-extraction cannot create duplicates — overlap is deduped by construction. The *only* thing
enforcing extract-once is the `extractedAt == nil` filter (`ExtractionRunner.swift:25`). Replacing
that filter with a change-detected, watermarked pass is the whole feature. **The trust gate
(`LooseEndVerifier`) and the quote-dedup are not touched.**

## Empirical grounding (verified against real transcripts, 2026-07-04)

The watermark's soundness rests on transcripts being append-only and resume growing the same file.
Checked against real `~/.claude/projects/**/*.jsonl` (litellm, docker-swarm, swarm-auto-drain):
- **filename == internal `sessionId`**, and **exactly one `sessionId` per file** → the parser's
  filename→sessionID keying and one-event-per-session model are correct.
- A single file spans **15+ hours (overnight)** and **7+ hours** of activity → a session that pauses
  and resumes **appends in place to the same file** (the exact case this feature targets). Confirmed.
- **No compaction/summary markers** observed. Compaction is not assumed impossible, so the design is
  made robust to it below (a rewrite is treated as "boundary broke → re-extract from 0"), but it is
  not the common path.
- Timestamps are **not strictly monotonic** across lines (interleaved tool/assistant records). The
  design therefore keys the watermark on **line-order message index** (stable under append), never on
  timestamp order.

## Architecture

### Event model — two new fields

Add to `Model/Event.swift` (additive migration **v7**, both `INTEGER NOT NULL DEFAULT 0`):

- `extractedMessageCount: Int` — how many parsed messages have already been extracted (a
  watermark/offset into `ParsedSession.messages`; parser indices are dense, 0-based, line-ordered,
  stable under append).
- `extractedTranscriptSize: Int` — the transcript's byte size at the last extraction; a cheap change
  detector (a `stat`, no parse).

`Event.init` gains both, defaulted to `0`; existing call sites (the ingester) are unchanged.
`extractedAt` stays as the "last extracted at" timestamp and, together with size, distinguishes
legacy rows (below).

### `ExtractionRunner.run()` change

1. Select **all** `cc.session` events (remove the `extractedAt == nil` filter).
2. For each, `stat` the transcript's byte size:
   - unreadable/missing → skip this event (don't crash; retry next run).
   - `size == event.extractedTranscriptSize` → **skip** (unchanged — the cost guard that avoids
     re-parsing multi-MB transcripts every cycle).
3. **Legacy init (one-time, no extraction):** if `event.extractedAt != nil && event.extractedTranscriptSize == 0`
   (a row extracted before this feature existed), the prior extraction already covered the transcript
   as it then stood. Parse to get the message count, set `extractedMessageCount = messages.count` and
   `extractedTranscriptSize = <current size>`, and **do not extract** this pass. This prevents a
   post-migration mass re-extraction that would resurface every previously-**resolved** loose end.
   (Genuinely new sessions have `extractedAt == nil` and take the normal path.)
4. Otherwise parse and choose the slice start with a **clamp/guard** (crash- and misalignment-proof):
   - if `messages.count >= event.extractedMessageCount` → `start = event.extractedMessageCount`
     (normal incremental slice).
   - else (**fewer messages than the watermark** — the transcript shrank/was rewritten, or the parser
     now filters more) → `start = 0` and **log it** ("re-extracting <sessionID> from 0: transcript
     boundary changed"). Re-extract the whole thing; the quote-dedup makes this safe.
   Extract from `session.messages[start...]` (this subscript is now always valid because
   `start <= messages.count`; an empty slice means nothing new). Verify each candidate against the
   **full** `session.messages` (the verifier resolves by absolute `messageIndex`, so slicing the
   *input* never breaks index resolution or `sourceMessageIndex`), and dedup-insert exactly as today.
5. In the same write, update: `extractedMessageCount = session.messages.count`,
   `extractedTranscriptSize = <current byte size>`, `extractedAt = now`.

Per-session error isolation is unchanged: a caught failure leaves that event's watermark/size
**unadvanced** so it retries next run (never a silent skip; the guard in step 4 handles the recoverable
misalignment case *before* the LLM call, so it isn't a "failure").

### Robustness to rewrite / shrink (why the guard is enough)

The size-gate detects any change; the step-4 count-guard recovers from the two ways the append-only
invariant can break — a shrink (size decreases → parse → `messages.count < watermark` → re-extract
from 0) and a future `TranscriptParser` filter change that lowers the parsed count for an unchanged
file (same recovery). Both re-extract from 0, which is *correct* (deduped), never a crash. The one
residual gap — an in-place rewrite that keeps byte size **and** message count identical while changing
earlier content — is undetectable by size and not exhibited by append-only event-log transcripts
(empirically none observed); accepted as a limitation rather than adding a per-message hash.

## Testing

`ExtractionRunnerTests` (extend existing):
- **Growth re-extracts only new messages:** ingest+extract a session; append new user prose to its
  transcript; re-run → only the new loose end(s) inserted, `extractedMessageCount` advanced, no
  duplicate of the earlier ones.
- **Unchanged transcript is a no-op:** re-run inserts nothing and does not re-extract (assert via
  result counts / a spy provider that would record a `complete` call).
- **Shrink / count-drop → re-extract from 0, no crash:** set a session's `extractedMessageCount`
  above the transcript's current message count (simulate rewrite/filter change); re-run must NOT trap,
  must re-extract from 0, and must not duplicate existing open loose ends.
- **Legacy init does not resurrect:** an event with `extractedAt != nil, extractedTranscriptSize == 0`
  and a **resolved** loose end whose quote is still in the transcript → the first run initializes the
  watermark/size and inserts **nothing** (the resolved item is not resurfaced); a later append then
  extracts only the new content.
- **Fresh session extracts fully:** `extractedAt == nil` (count 0, size 0) extracts all, as today.
- **Trust gate intact on re-extraction:** a re-extracted loose end's quote is verbatim-present; a
  fabricated candidate is still dropped.
- **Unreadable transcript skips, doesn't crash;** watermark unadvanced so it retries.
- **Partial trailing line (regression note):** a transcript whose last line is a half-written JSON
  record parses to N messages (the partial line skipped, `TranscriptParser.swift:24-26`); after the
  line completes and the file grows, re-run picks the now-complete message up at index N with no
  offset drift. (Confirms the watermark is robust to mid-write reads.)

Migration test (`SchemaV7Tests` or extend the schema tests): a session `Event` round-trips with the
two new fields defaulting to 0; the columns are `INTEGER NOT NULL DEFAULT 0` on the STRICT table.

All under `./scripts/test.sh`.

## Non-goals / future (belongs to the daemon sub-project)

- **SessionEnd hook** and **discovering *new* (never-ingested) sessions** — the daemon sub-project.
  This sub-project only makes *existing* session events re-extract on growth.
- **Scheduling / cadence** — driven by whoever calls `ExtractionRunner.run()` (`ingest` now, the
  daemon later).
- **Re-extraction of resolved loose ends on new content:** dedup collapses only against *open* loose
  ends (unchanged). If a resolved loose end's exact quote reappears in genuinely new content it will
  resurface as open — accepted as correct (it came up again). The legacy-init path (step 3) exists
  specifically so this does **not** fire en masse for all historical content at migration time.
- **Detecting same-size/same-count in-place rewrites** — see Robustness; accepted limitation.

## Open constraints

- Build/test with `./scripts/test.sh` (optionally `--filter`), NOT `swift test` — Command Line Tools
  only. `swift build`/`swift run` work normally.
- SQLiteData predicates use `.eq(x)`, NOT `== x`; STRICT tables; migration additive (v7 follows v6).
- **The trust gate is untouched** — `LooseEndVerifier` and the normalized-quote dedup are not
  modified. Only the extractor's *input window* (new-message slice) and the *selection gate*
  (`extractedAt == nil` → byte-size change) change.
- Reuse `TranscriptParser`, `LooseEndExtractor`, `LooseEndVerifier`, `normalizeWhitespace` — don't
  reimplement.
- No shared mutable `static ISO8601DateFormatter` (Swift 6).

## Self-review

- **Placeholders:** none — concrete fields, gate/guard logic, legacy path, and update semantics.
- **Consistency:** "safe by construction" matches the existing re-parse + quote-dedup; "trust gate
  untouched" matches changing only the extractor input + selection gate; the empirical section
  justifies the append-only premise the watermark needs; the count-guard resolves both the crash
  (Critical) and the misalignment (Critical); legacy-init resolves the mass-resurrection (Important).
- **Scope:** one model change + one migration + one `ExtractionRunner` method change + tests — a
  single, tight plan. Daemon/hook explicitly separated.
- **Ambiguity pinned:** change detection = byte size; watermark = parsed-message count; slice start =
  clamped (`messages.count >= watermark ? watermark : 0`, log on reset); verify against full messages;
  legacy rows = `extractedAt != nil && size == 0` → init without extracting.
