# Phase 1A — Outcome & Phase 1B Design Inputs

**Date:** 2026-07-03. **Status:** Phase 1A complete and merged to `main`. Read this before planning Phase 1B.

## What Phase 1A shipped

A headless Swift package (`Pensieve`) implementing the capture → ingest → query pipeline, per `plans/2026-07-03-pensieve-phase1a-capture-ingest.md`. 19 tests, green via `./scripts/test.sh`.

- **`PensieveKit`** framework:
  - `Model/` — `Project`, `Source`, `Event`, `LooseEnd`, `Checkpoint` (SQLiteData `@Table`, UUID PKs, STRICT). **`LooseEnd` and `Checkpoint` tables exist but are UNPOPULATED — Phase 1B fills `LooseEnd`.**
  - `Store/CanonicalStore.swift` — `openCanonicalDatabase(at:)` + GRDB `DatabaseMigrator` (migrations `v1-projects`, `v2-...`). `Store/CaptureSpool.swift` — the dumb append-only spool (WAL, busy-timeout).
  - `Capture/CapturePayloads.swift` — `CaptureKind`/`SourceKind` constants + `GitCommitPayload`/`GitCheckoutPayload`/`SessionRefPayload` + `encodeJSON`. `Capture/HookInstaller.swift` — writes git hooks (absolute pensieve path, marker-guarded against clobbering).
  - `Transcript/TranscriptParser.swift` — **defensively parses Claude Code `.jsonl` transcripts** into `ParsedSession { sessionID, cwd, startedAt, endedAt, userPromptCount, messages }`. This is the raw material Phase 1B mines for loose ends. It currently extracts cwd, timestamps, prompt count, and message text; **it does NOT yet extract TodoWrite state / stated-but-unfinished plans — that extraction is Phase 1B's job.**
  - `Ingest/Ingester.swift` — `drain()` turns spool rows into enriched `Event`s (returns events *created*). `Ingest/ProjectResolver.swift` — path→project/source resolution (canonicalizes paths; `resolve(_ db:...)` overload for atomic use), plus `group(_:into:)`.
  - `Query/ProjectQueries.swift` — `all`, `status(name:limit:)`.
  - `Support/` — `Git.run` (subprocess helper), `PensievePaths`.
- **`pensieve` CLI** subcommands: `capture-commit`, `capture-checkout`, `ingest-session`, `ingest`, `list`, `status`, `track`, `group`, `install-hooks`.

## Reviews applied

Every task passed individual spec+quality review during subagent-driven execution. Then a final whole-branch review (Opus) and a separate high-effort multi-agent review (`/code-review high --fix`) ran. Fixes merged: cc.session retry-on-missing-cwd, consistent path canonicalization, session-attribution-by-repo-root, accurate ingest count, per-row spool marking, atomic resolve+insert, single `git show`, spool WAL, absolute pensieve path in hooks, and `group()` repointing looseEnds/checkpoints before delete.

## Phase 1B design inputs (carry these forward)

These are the deferred/known items 1B must account for:

1. **Ingester idempotency / dedup key (IMPORTANT).** `drain()` has no dedup key, and the spool + canonical store are separate SQLite files so a row-claim can't be made atomic across them. Two concurrent `pensieve ingest` runs, or a re-drain after a partial failure, can insert duplicate events. **1B should add a natural unique key** (e.g. unique index on `(sourceID, kind, git-hash)` for commits and on `(sourceID, sessionID)` for sessions) and make ingestion upsert/ignore-on-conflict. This also protects the loose-end extraction from re-processing the same session repeatedly.

2. **Project addressing by non-unique name.** `status`/`group` resolve a project by its `name`, which is the path basename — two different repos both named `api` collide and one is picked arbitrarily. There's no unique constraint on `name`. When 1B (or the app) grows the surface, prefer ID-based addressing / disambiguation. (Canonicalization fixed *path* consistency, not *name* uniqueness.)

3. **Loose-end extraction needs richer transcript parsing.** `TranscriptParser` currently yields cwd/timestamps/prompt-count/message-text. To ground loose ends, 1B likely needs to extract TodoWrite todo lists (completed vs pending), stated intentions ("I'll also do X"), and ops steps discussed but not done — and correlate against commits. Extend the parser or add a dedicated extractor; keep it defensive (skip unparseable records).

4. **`group()` invariant.** It already repoints `looseEnds`/`checkpoints` to the primary before deleting a merged project. Once 1B populates `looseEnds`, keep this invariant if you touch merge logic (there's a test: `groupPreservesLooseEndsAndCheckpoints`).

## What Phase 1B must build (from the design spec §Intelligence)

The make-or-break gate. Grounded, lazy, provenance-cited:
- **`LLMProvider` protocol** with a default implementation that **shells out to `claude -p`** (subscription auth, no API key). Provider-agnostic so OpenAI/Gemini/etc. can slot in later. Model tiering: cheap model for per-item extraction, stronger for synthesis.
- **Loose-end extraction** from captured transcripts → populate `LooseEnd` rows, each with **provenance** (source event + verbatim quote). *If it can't cite real captured text, it doesn't appear.* This rule is the entire defense against hallucination.
- **Grounded summaries** per project: What It Is, Last Work Done (grounded core), Blockers (only when signal exists), Loose Ends (cited).
- **"What's Next"** ranking on grounded signals only (days dormant, # open loose ends, unfinished-looking branch). No invented risk scores.
- **CLI:** `next`, `digest` (a generated morning markdown digest), `checkpoint` (manual note).

**Validation gate:** on a sample of Moritz's real recent projects, loose ends must be *real and cited, with zero hallucinated items*, before any UI work. That is the whole point of doing 1B before the app.
