# Sync Daemon — Auto-Drain & Session Ingestion (Design, revised)

**Date:** 2026-07-05. **Status:** APPROVED (brainstormed). Supersedes
`2026-07-04-pensieve-sync-daemon-design.md` (DEFERRED). That version was built around the old
extract-once limitation and used an mtime **grace window** to avoid ingesting still-growing
transcripts. **Sub-project 1 (incremental re-extraction) shipped** (merged to `main`,
`ExtractionRunner` now re-mines each transcript's newly-appended slice every run, byte-size-gating
unchanged ones), which removes that constraint. This revision drops the grace window, adds a
`SessionEnd` capture hook as a precise low-latency trigger, and bakes in the confirmed launchd
fixes.

## Goal

Make the live capture pipeline flow **without manual steps.** Today git hooks fill the spool and the
`SessionStart` hook records branches, but nothing drains the spool to the canonical store or extracts
loose ends from session transcripts unless `pensieve ingest` is run by hand. This phase adds a
launchd-scheduled `pensieve sync` that drains the spool *and* discovers + ingests Claude session
transcripts on an interval, plus a `SessionEnd` hook that spools a session's transcript at true
session end — so commits, sessions, and cited loose ends accumulate on their own.

## Run model: launchd-scheduled one-shot

A launchd **LaunchAgent** runs `pensieve sync` every N minutes, then exits — no resident process, no
self-managed loop, no memory concerns. launchd owns scheduling, restarts it at login (`RunAtLoad`),
survives reboot, and will not start a second copy while one is still running (same-label jobs are
singletons), so cycles never stack even when on-device extraction runs long. Latency is bounded by
the interval (default 5 min), fine for a context-reload tool. **Feasibility was verified in a prior
session:** on-device extraction ran correctly under a launchd `gui`-domain agent (a spike ran real
`pensieve ingest` under a LaunchAgent and got 3/3 loose ends, matching interactive).

## Two triggers, one pipeline

Transcripts reach the canonical store two ways, both feeding the same `drain` → event →
incremental-extract pipeline:

1. **`SessionEnd` hook** (precise, low-latency): at true session end, spools the transcript ref, so a
   just-finished session is ingested within one cycle of ending.
2. **Periodic discovery** (catch-all): `pensieve sync` globs the Claude projects dir and spools refs
   for any session not yet an event — catching sessions the hook missed (unclean exits) and, together
   with incremental re-extraction, surfacing loose ends from **in-progress** sessions.

Both can spool the same session; `drain`'s `session:<id>` fingerprint collapses them to one event,
and discovery's already-an-event check skips it on later cycles. Incremental re-extraction rides on
top of both: every cycle, `ExtractionRunner.run()` re-reads each session event's transcript and
extracts only what grew.

## Architecture

### A. `pensieve sync` — one cycle

The command launchd invokes; also runnable by hand. A cycle:

1. **`Ingester.drain()`** — spool → canonical events (commits, checkouts, session-branch rows, and any
   `SessionRefPayload`s the `SessionEnd` hook spooled since last run). Strand birth exactly as today.
2. **`TranscriptDiscovery` (§B)** — glob finished + in-progress transcripts, spool a `SessionRefPayload`
   for each session not yet an event, then **`drain` again** → those become session events.
3. **`ExtractionRunner.run()`** — incremental. Re-reads every `cc.session` event's transcript,
   byte-size-gates unchanged ones (free, no parse), extracts only newly-appended message slices.

Steps 1 + 3 are what `ingest` already does; `sync = discovery → ingest`. `ingest` is unchanged
(manual drain+extract of what is already spooled); `sync` layers discovery on top and is what the
daemon runs. The daemon does **no** LLM work beyond the existing on-device extraction (free, private).

### B. `TranscriptDiscovery` (PensieveKit — pure, testable)

Given the Claude projects directory, `now`, an age bound, and a
`sessionAlreadyIngested(sessionID:) -> Bool` predicate, return the transcript paths to spool this
cycle. Globs `<claudeProjects>/*/*.jsonl`, then for each file:

- **Skip if already an event** — derive `sessionID` from the filename (the parser already keys a
  session by its filename) and skip when `sessionAlreadyIngested` is true. A cheap DB lookup done
  **before** reading the file, so already-processed multi-MB transcripts are never re-parsed. This is
  the primary cost guard.
- **Bound the scan** — only consider transcripts with mtime within the last **7 days** (default), so
  ancient transcripts aren't re-globbed every cycle.

**No grace window.** Under the old extract-once rule, ingesting a still-growing transcript
permanently lost its later loose ends, so discovery waited for an mtime-quiet "finished" window.
Incremental re-extraction removes that failure mode: the parser already tolerates a partial trailing
line (see `partialTrailingLinePicksUpAtCorrectIndexAfterCompletion`), the event is created from
whatever is complete, and the next cycle's byte-size-gated re-extract picks up the appended
remainder. So discovery ingests in-progress transcripts safely and no longer distinguishes
"finished" from "active".

The existing fingerprint (`session:<id>`) + per-event watermark/`extractedAt` remain the safety net
beneath the discovery filter — discovery is an optimization over "re-spool everything," never the
sole guarantee.

### C. `capture-session-end` hook + installer

A dumb, fire-and-forget capture command mirroring `capture-session-start`:

- **New CLI command `capture-session-end`**: reads the hook JSON from stdin
  (`session_id`, `cwd`, `transcript_path`, `reason`), and spools
  `SessionRefPayload(transcriptPath: transcript_path)` under `CaptureKind.ccSession` — identical to
  what `ingest-session --path` spools. It never fails a session: decode failure or empty
  `transcript_path` → silent no-op (`try?`), matching `capture-session-start`'s dumbness. No new
  payload type; no ingester change (a SessionEnd-spooled ref is just a `ccSession` row `drain`
  already turns into a session event).
- **Installation**: extend `SettingsHookInstaller` to also install a `SessionEnd` entry into
  `~/.claude/settings.json` — matcher `""` (fires on every `reason`, per the confirmed hook contract)
  → `hooks: [{ type: "command", command: "<pensievePath> capture-session-end" }]` — with the same
  idempotent, foreign-hook-preserving JSON merge it already does for `SessionStart`. The existing
  `install-session-hook` command installs **both** hooks; re-running is a no-op when ours are present.

**Confirmed `SessionEnd` hook contract** (Claude Code docs, verified this session): a distinct hook
that fires on *all* exits (best-effort — cannot block termination); stdin carries `session_id`,
`cwd`, `transcript_path`, `hook_event_name`, and `reason` (`clear` / `resume` / `logout` /
`prompt_input_exit` / `bypass_permissions_disabled` / `other`); matcher `""` matches all reasons; the
transcript is fully flushed and safe to read when it fires. `reason == resume` means the transcript
can grow *after* this fires — a non-issue here: periodic discovery + incremental re-extraction re-mine
the resumed growth, and a later second `SessionEnd` for the same path dedups to the existing event.

### D. `pensieve install-daemon` (+ `--uninstall`)

Mirrors the existing installer idioms: a pure/testable plist writer + a side-effecting `launchctl`
call.

**Pure plist writer** (PensieveKit) produces `~/Library/LaunchAgents/com.pensieve.sync.plist`:

- `ProgramArguments`: `[<stable pensieve path>, "sync"]` — the same `Bundle.main.executablePath`
  resolution the other installers use (baked absolute, survives `rm -rf .build`).
- `StartInterval`: `300` (5 min, default).
- `RunAtLoad`: `true`.
- `StandardOutPath` / `StandardErrorPath`: `~/Library/Logs/Pensieve/sync.log`.
- **`EnvironmentVariables.PATH`**: includes `~/.local/bin` and `/opt/homebrew/bin`. **Confirmed
  critical fix** — launchd hands jobs a minimal PATH, but the `claude -p` extraction fallback
  resolves `claude` via PATH. On-device Foundation Models is the default and needs no PATH, but the
  fallback must work under the daemon.

**Side effects of `install-daemon`:**

- Create `~/Library/Logs/Pensieve/` (launchd will not create the log dir; a missing dir makes the job
  fail to launch).
- `launchctl bootstrap gui/<uid> <plist>`, idempotent (bootout-then-bootstrap, or detect
  already-loaded).
- `--uninstall`: `launchctl bootout` + remove the plist.

The plist writer is pure/testable; the `launchctl` call and dir creation are the side effects.
Mirrors the `SettingsHookInstaller` pattern (idempotent write + a load step).

**Honest note:** a `sync` cycle's `drain` step *writes* the spool DB (marks rows ingested via
`markIngested`), bounded by WAL + the 5 s busy timeout — so `sync` is not purely a spool reader,
though it never touches the capture *hooks*. The canonical store stays single-writer.

### E. Observability

`sync` logs a one-line per-cycle summary (drained N, ingested M sessions, extracted K loose ends) to
`sync.log`. The **heartbeat window already surfaces the effect** — spool-pending falls, event and
loose-end counts climb — so "is the daemon working?" is answerable at a glance without reading logs.

## Testing

- **`TranscriptDiscovery`** (the real coverage), pure over a temp projects dir: (a) an already-an-event
  session (predicate true → skipped without reading the file), (b) a finished transcript within the age
  bound, not yet an event (→ returned), (c) an ancient transcript beyond the age bound (→ skipped).
  Assert exactly the in-window, not-yet-ingested transcripts are returned. **No grace-window case** —
  that logic is gone.
- **plist writer**: asserts `ProgramArguments` / `StartInterval` / `RunAtLoad` / log paths, and
  **`EnvironmentVariables.PATH` contains both `~/.local/bin` and `/opt/homebrew/bin`**; idempotency
  (writing twice → one well-formed plist).
- **`SettingsHookInstaller` SessionEnd**: installs the SessionEnd entry (matcher `""`, correct
  command); idempotent; preserves an existing SessionStart entry and foreign hooks.
- **`capture-session-end`**: valid stdin → one `ccSession` spool row with the right path;
  malformed/empty stdin → no-op, no throw.
- **`sync` end-to-end**: seed a spool commit row + a temp projects dir with one transcript → `sync`
  drains the commit, discovers + ingests the session, extraction runs; a second `sync` is a clean
  no-op (dedup + byte-size gate). Plus an **incremental** case: append messages to that transcript,
  `sync` again → only the new slice extracts (proves the daemon rides the incremental path).
- `launchctl` bootstrap/bootout is smoke-verified by hand (mutates the live launchd domain), not
  unit-tested.

All PensieveKit tests run under `./scripts/test.sh`.

## Non-goals / future

- **Resident daemon / event-driven (FSEvents) triggering** — scheduled one-shot is enough; deferred.
- **Pre-generating summaries / digests** on the cycle — the daemon only drains + ingests + extracts;
  summary / `next` / `digest` stay on-demand.
- **A `WatchedRoot`-driven rescan** for newly-created repos — separate concern (source-discovery pass
  2 / periodic rescan); not part of the sync daemon.
- **Windowing / interval configuration UI** — interval (5 min) + discovery age bound (7 days) are
  constants (tunable in the plist / source by hand for now); a settings surface is later.

## Open constraints

- Build/test with `./scripts/test.sh` (optionally `--filter`), NOT `swift test` — Command Line Tools
  only. `swift build` / `swift run` work normally.
- **The capture path stays sacred** — the `SessionEnd` hook is dumb and fire-and-forget like the
  existing hooks; `sync` is a reader/ingester, entirely separate from the fire-and-forget hooks. It
  writes only the canonical store (single-writer; existing dedup), the spool's ingested marks, and its
  own plist / log — never blocking or altering capture.
- Reuse existing pieces — `Ingester.drain()`, `ExtractionRunner.run()` (incremental),
  `SessionRefPayload`, `TranscriptParser`, `SettingsHookInstaller`, `PensievePaths`, the
  `Bundle.main.executablePath` install idiom. Don't reimplement.
- Session ingestion resolves each transcript's node from its `cwd` / common-dir (via the existing
  ingester path), so sessions in repos that were never `scan`-ed still attribute correctly.
- No shared mutable `static ISO8601DateFormatter` (Swift 6).

## Self-review

- **Placeholders:** none — every component has a concrete interface and default value.
- **Consistency:** `sync = discovery → ingest` matches "reuse `Ingester.drain` + `ExtractionRunner`";
  the launchd one-shot model matches the "no resident process" decision; dropping the grace window
  matches the now-landed incremental re-extraction (mid-write ingest is safe); the `SessionEnd`
  matcher `""` matches the confirmed all-reasons contract.
- **Scope:** `sync` + `TranscriptDiscovery` + `capture-session-end` (+ SessionEnd installer) +
  `install-daemon` (+ plist writer) — a single plan. UI / config surfaces explicitly deferred.
- **Ambiguity pinned:** "already ingested" checked by filename-derived `sessionID` before reading;
  no "finished" distinction (grace window removed); SessionEnd matcher `""`; interval 5 min, age
  bound 7 days — all named defaults.
