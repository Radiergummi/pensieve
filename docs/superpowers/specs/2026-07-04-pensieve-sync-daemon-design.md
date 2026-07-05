# Sync Daemon — Auto-Drain & Session Ingestion (Design)

**Date:** 2026-07-04. **Status:** SUPERSEDED by
`2026-07-05-pensieve-sync-daemon-design.md` (revised after incremental re-extraction landed:
grace window dropped, SessionEnd hook added, launchd fixes baked in). Kept for history.

**Original status:** DEFERRED / TO BE REVISED. An adversarial review found the §B
mtime-grace recall approach **critically flawed** (it silently drops loose ends from the back half of
paused/resumed sessions). The fix — **incremental re-extraction + a SessionEnd hook** — was split into
its own prerequisite sub-project (`…-incremental-reextraction-design.md`). This daemon spec will be
revised to depend on that (SessionEnd-hook trigger, mtime-grace demoted to a backstop) + the confirmed
fixes (launchd `PATH` for the `claude -p` fallback — extraction under launchd was **verified working**;
create the log dir; honest "drain writes the spool via `markIngested`" note). Do not implement from this
version.

## Goal

Make the live capture pipeline flow **without manual steps.** Today, git hooks fill the spool and
the SessionStart hook records branches, but nothing drains the spool to the canonical store or
extracts loose ends from session transcripts unless Moritz runs `pensieve ingest` by hand. This
phase adds a launchd-scheduled `pensieve sync` that drains the spool *and* discovers + ingests
finished Claude session transcripts on an interval — so commits, sessions, and cited loose ends
accumulate on their own.

## Run model: launchd-scheduled one-shot

A launchd **LaunchAgent** runs `pensieve sync` every N minutes, then exits — no resident process,
no self-managed loop, no memory concerns. launchd owns scheduling, restarts it at login
(`RunAtLoad`), survives reboot, and will not start a second copy while one is still running
(same-label jobs are singletons), so cycles never stack even when on-device extraction runs long.
Latency is bounded by the interval (default 5 min), which is fine for a context-reload tool.

## Architecture

### A. `pensieve sync` — one cycle

The command launchd invokes; also runnable by hand. A cycle is `ingest` **plus** transcript
discovery in front of it:

1. `Ingester.drain()` — spool → canonical events (commits, checkouts, session-branch rows; strand
   birth exactly as today).
2. **Discover finished session transcripts** (§B), append a `SessionRefPayload` to the spool for
   each, and drain again → session content events.
3. `ExtractionRunner.run()` → loose ends over not-yet-extracted sessions.

Steps 1 + 3 are precisely what `ingest` already does. `sync = transcript discovery → ingest`.
`ingest` is unchanged (manual drain+extract of what is already spooled); `sync` layers discovery on
top and is what the daemon runs. The daemon does **no** LLM work beyond the existing on-device
extraction (free, private).

### B. `TranscriptDiscovery` (PensieveKit — pure, testable)

Given the Claude projects directory, `now`, a grace interval, an age bound, and a
`sessionAlreadyIngested(sessionID:) -> Bool` predicate, return the transcript paths to ingest this
cycle. Globs `<claudeProjects>/*/*.jsonl`, then for each file:

- **Skip if already ingested** — derive `sessionID` from the filename (the parser already keys a
  session by its filename), and skip when `sessionAlreadyIngested` is true. This is a cheap DB
  lookup done **before** reading the file, so already-processed multi-MB transcripts are never
  re-parsed. This is the primary cost guard.
- **Skip if still active** — skip transcripts whose mtime is within the **grace window** (default
  **5 min**), so we ingest *finished* sessions rather than ones mid-write. A session is extracted
  only once (the documented "resumed session won't re-extract" tradeoff), so ingesting a
  still-growing transcript would lose later loose ends; the grace window avoids that in the common
  case.
- **Bound the scan** — only consider transcripts with mtime within the last **7 days** (default), so
  ancient transcripts aren't re-globbed every cycle.

The existing fingerprint (`session:<id>`) + per-event `extractedAt` dedup remains the safety net
beneath the discovery filter — discovery is an optimization over "re-spool everything," never the
sole guarantee.

### C. `pensieve install-daemon` (and `--uninstall`)

Writes `~/Library/LaunchAgents/com.pensieve.sync.plist`:

- `ProgramArguments`: `[<stable pensieve path>, "sync"]` — the same `Bundle.main.executablePath`
  resolution the other installers use (baked absolute, so it survives `rm -rf .build`).
- `StartInterval`: `300` (5 min, default).
- `RunAtLoad`: `true`.
- `StandardOutPath` / `StandardErrorPath`: `~/Library/Logs/Pensieve/sync.log`.

Then `launchctl bootstrap gui/<uid> <plist>` (idempotent — bootout-then-bootstrap, or detect
already-loaded). `--uninstall` boots it out and removes the plist. The plist writer is pure/testable;
the `launchctl` call is the side effect. Mirrors the `SettingsHookInstaller` pattern (idempotent
JSON/plist write + a load step).

### D. Observability

`sync` logs a one-line per-cycle summary (drained N, ingested M sessions, extracted K loose ends) to
`sync.log`. The **heartbeat window already surfaces the effect** — spool-pending falls, event and
loose-end counts climb — so "is the daemon working?" is answerable at a glance without reading logs.

## Testing

- **`TranscriptDiscovery`** (the real coverage): a temp projects dir with (a) an already-ingested
  session (predicate true → skipped without reading), (b) a transcript modified just now (within
  grace → skipped), (c) a finished transcript older than grace but within the age bound (→ returned),
  (d) an ancient transcript beyond the age bound (→ skipped). Assert exactly the finished, not-yet-
  ingested, in-window transcript is returned.
- **plist writer:** asserts `ProgramArguments`/`StartInterval`/`RunAtLoad`/log paths, and idempotency
  (writing twice yields one well-formed plist).
- **`sync` end-to-end:** seed a spool row + a temp transcript dir with one finished transcript →
  `sync` drains the commit, ingests the session, and extraction runs; a second `sync` is a clean
  no-op (dedup).
- `launchctl` bootstrap/bootout is smoke-verified manually (not unit-tested — it mutates the live
  launchd domain).

All PensieveKit tests run under `./scripts/test.sh`.

## Non-goals / future

- **Resident daemon / event-driven (FSEvents) triggering** — scheduled one-shot is enough; deferred.
- **Re-extracting resumed/grown sessions** — a session is ingested + extracted once; re-extraction
  on later growth is out of scope (unchanged from the existing tradeoff).
- **Pre-generating summaries / digests** on the cycle — the daemon only drains + ingests + extracts;
  summary/`next`/`digest` stay on-demand.
- **A `WatchedRoot`-driven rescan** for newly-created repos — separate concern (source-discovery
  pass 2 / periodic rescan); not part of the sync daemon.
- **Windowing/interval configuration UI** — interval + grace are constants (tunable in the plist by
  hand for now); a settings surface is later.

## Open constraints

- Build/test with `./scripts/test.sh` (optionally `--filter`), NOT `swift test` — Command Line Tools
  only. `swift build`/`swift run` work normally.
- **The capture path stays sacred** — `sync` is a *reader/ingester*, entirely separate from the
  fire-and-forget hooks; it must never block or alter capture. It writes only the canonical store
  (single-writer; existing dedup) and its own plist/log.
- Reuse existing pieces — `Ingester.drain()`, `ExtractionRunner.run()`, `SessionRefPayload`,
  `TranscriptParser`, `PensievePaths`, the `Bundle.main.executablePath` install idiom. Don't
  reimplement.
- Session ingestion resolves each transcript's node from its `cwd`/common-dir (via the existing
  ingester path), so sessions in repos that were never `scan`-ed still attribute correctly.
- No shared mutable `static ISO8601DateFormatter` (Swift 6).

## Self-review

- **Placeholders:** none — every component has a concrete interface and default value.
- **Consistency:** `sync = discovery → ingest` matches "reuse `Ingester.drain` + `ExtractionRunner`";
  the launchd one-shot model matches the "no resident process" decision; the grace-window rationale
  matches the "extract-once" tradeoff.
- **Scope:** one `sync` command + `TranscriptDiscovery` + `install-daemon` (+ plist writer) — a single
  plan. UI/config surfaces are explicitly deferred.
- **Ambiguity pinned:** "finished" = mtime older than the 5-min grace; already-ingested checked by
  filename-derived `sessionID` before reading; interval 5 min, age bound 7 days — all named defaults.
