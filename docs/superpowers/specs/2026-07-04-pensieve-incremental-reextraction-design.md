# Incremental Re-Extraction (Design)

**Date:** 2026-07-04. **Status:** approved in brainstorming, ready for a plan. **Prerequisite
sub-project** for the sync daemon (`…-sync-daemon-design.md`), and independently useful — it makes
even a manual `pensieve ingest` lossless across paused/resumed sessions.

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

## Architecture

### Event model — two new fields

Add to `Model/Event.swift` (additive migration **v7**, both `INTEGER NOT NULL DEFAULT 0`):

- `extractedMessageCount: Int` — how many parsed messages have already been extracted (a
  watermark/offset into `ParsedSession.messages`). Parser indices are dense, 0-based, and stable for
  an append-only transcript, so a plain count is a correct high-water mark.
- `extractedTranscriptSize: Int` — the transcript's byte size at the last extraction; a cheap
  change detector (a `stat`, no parse). Append-only transcripts grow monotonically, so
  `currentSize == extractedTranscriptSize` reliably means "nothing new."

`Event.init` gains both parameters, defaulted to `0`; all existing call sites (the ingester) are
unchanged. `extractedAt` stays as the "last extracted at" timestamp (for display/ordering).

### `ExtractionRunner.run()` change

1. Select **all** `cc.session` events (remove the `extractedAt == nil` filter).
2. For each, `stat` the transcript's byte size:
   - unreadable/missing → skip this event (don't crash; retry next run).
   - `size == event.extractedTranscriptSize` → **skip** (unchanged — the cost guard that avoids
     re-parsing multi-MB transcripts every cycle).
3. Otherwise parse the transcript and extract from the **new slice only**:
   `session.messages[event.extractedMessageCount...]` (empty slice → nothing new; still fall through
   to update size). Verify each candidate against the **full** `session.messages` (the quote lives in
   the slice; verifier semantics unchanged) and dedup-insert exactly as today.
4. In the same write, update the event: `extractedMessageCount = session.messages.count`,
   `extractedTranscriptSize = <current byte size>`, `extractedAt = now`.

Per-session error isolation is unchanged: a failure leaves the event's watermark/size **unadvanced**
so it retries next run (never a silent skip).

### Legacy rows

No special-casing. Pre-migration session events default to `extractedMessageCount = 0`,
`extractedTranscriptSize = 0`, so on the first post-migration run each is treated as "grown from 0"
and re-extracted once; the quote-dedup makes that harmless, and the size-gate skips it thereafter.
In the current real store this is ~zero cost (no session events ingested yet); for a large store it
is a one-time, on-device (free) re-pass.

## Data flow

```
ExtractionRunner.run()  (called by `ingest` today; by the daemon later)
  for each cc.session event:
    stat(transcriptPath).size
      == extractedTranscriptSize?  ── yes ─▶ skip (unchanged)
      │ no
      ▼
    parse → messages[extractedMessageCount...] ─▶ LooseEndExtractor
      ─▶ LooseEndVerifier (verbatim, vs full messages)   [trust gate, unchanged]
      ─▶ dedup by normalized quote vs open loose ends     [unchanged]
      ─▶ insert new; update {count, size, extractedAt}
```

## Testing

`ExtractionRunnerTests` (extend existing):
- **Growth re-extracts only new messages:** ingest+extract a session; append new user prose to its
  transcript file; re-run → only the new loose end(s) inserted, `extractedMessageCount` advanced, no
  duplicate of the earlier ones.
- **Unchanged transcript is a no-op:** re-run on an unchanged transcript inserts nothing and does not
  re-parse-extract (assert via the result counts / a spy provider that would record a call).
- **Fresh session extracts fully:** a never-extracted session (count 0, size 0) extracts all, matching
  today's behavior.
- **Trust gate intact on re-extraction:** a re-extracted loose end's quote is verbatim-present in the
  transcript (a fabricated candidate is still dropped) — reuse the verifier's guarantees.
- **Unreadable transcript skips, doesn't crash;** watermark unadvanced so it retries.

Migration test (`SchemaV7Tests` or extend the schema tests): a session `Event` round-trips with the
two new fields defaulting to 0.

All under `./scripts/test.sh`.

## Non-goals / future (belongs to the daemon sub-project)

- **SessionEnd hook** and **discovering *new* (never-ingested) sessions** — the daemon sub-project.
  This sub-project only makes *existing* session events re-extract on growth.
- **Scheduling / cadence** — driven by whoever calls `ExtractionRunner.run()` (`ingest` now, the
  daemon later).
- **Re-extraction of resolved loose ends:** dedup collapses only against *open* loose ends
  (unchanged). If a resolved loose end's exact quote reappears in new content it will resurface as
  open — accepted as correct (it genuinely came up again), and it is the pre-existing behavior.

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

- **Placeholders:** none — concrete fields, gate logic, and update semantics.
- **Consistency:** "safe by construction" matches the existing re-parse + quote-dedup in
  `ExtractionRunner`; "trust gate untouched" matches changing only the extractor input + selection
  gate; the two new fields map to the two jobs (watermark = where to resume; size = whether to
  bother).
- **Scope:** one model change + one migration + one `ExtractionRunner` method change + tests — a
  single, tight plan. Daemon/hook explicitly separated.
- **Ambiguity pinned:** change detection = transcript byte size; watermark = parsed-message count;
  new slice = `messages[count...]`; verify against full messages; legacy rows re-extract once via the
  0-defaults (deduped), no special path.
