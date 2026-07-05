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

**Small required change to `Ingester.drain()` — distinguish "not yet flushed" from "will never
attribute".** Today a `ccSession` row whose parse yields no `cwd` *throws* `unattributableSession`,
and `drain` leaves throwing rows unmarked to retry next drain (`Ingester.swift`: `catch { continue }`).
That is correct for a transient (mid-flush) transcript but, now that discovery re-spools any
not-yet-an-event transcript every cycle, a *permanently* unattributable file (a genuinely corrupt or
never-populated `.jsonl`) would be re-spooled and re-thrown forever — an unbounded spool leak that
also inflates `pendingCount()` (the heartbeat's "spool-pending" signal). The 0-byte guard in §B stops
the common case at the source; for a **non-empty but still cwd-less** parse, `drain` must treat it as a
permanent drop (mark the row ingested) rather than an infinite retry. Rule: *empty/unreadable → leave
pending (may fill later); non-empty yet no cwd → drop.* This is a deliberate, tested change to a
shipped component — the plan must cover it and preserve the transient-retry behavior for empty files.

### B. `TranscriptDiscovery` (PensieveKit — pure, testable)

Given the Claude projects directory, `now`, an age bound, and a
`sessionAlreadyIngested(sessionID:) -> Bool` predicate, return the transcript paths to spool this
cycle. Globs `<claudeProjects>/*/*.jsonl`, then for each file:

- **Skip if already an event** — derive `sessionID` from the filename (`deletingPathExtension()
  .lastPathComponent`, the exact derivation `TranscriptParser` uses, so the key always matches) and
  skip when `sessionAlreadyIngested` is true. A cheap DB lookup done **before** reading the file, so
  already-processed multi-MB transcripts are never re-parsed. This is the primary cost guard. The
  lookup queries `Event` by the global `session:<id>` fingerprint (discovery has no `sourceID`).
- **Skip 0-byte / not-yet-populated files** — a `fileSize == 0` guard (free `stat`, no read). Removing
  the grace window means discovery now sees still-forming and crash-stub transcripts; a 0-byte file
  has no `cwd` yet and must not be spooled, or it re-spools every cycle forever (see §A "permanent
  drop" below). A file that later fills is picked up on a subsequent cycle.
- **Skip subagent / sidechain transcripts** — Claude Code writes Task/subagent sessions as *separate
  `.jsonl` files in the same projects directory*, marked `isSidechain: true` inside their records (not
  by filename). Mining agent-internal reasoning prose as loose ends would regress the make-or-break
  precision gate (0 noise / 0 fabrication). Discovery (or the parser it calls) must skip transcripts
  whose records are `isSidechain: true`, ingesting only top-level session files. **Verify against the
  real `~/.claude/projects` layout during implementation and add a precision check.**
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
`cwd`, `transcript_path`, `hook_event_name`, and a `reason`; matcher `""` matches all reasons; the
transcript is fully flushed and safe to read when it fires. Because we register matcher `""` and read
only `transcript_path`, the exact `reason` enum values are immaterial to this design (re-verify
against current docs during implementation, but nothing branches on them). Two reason cases are worth
naming: a `resume`-style end means the transcript can grow *after* this fires — a non-issue, since
periodic discovery + incremental re-extraction re-mine the resumed growth and a later second
`SessionEnd` for the same path dedups to the existing event; a `clear`-style end (user runs `/clear`
mid-CLI) simply spools the completed pre-clear transcript early, which is benign — the new post-clear
session is a different `session_id` handled independently.

*Minor (optional hardening):* the existing `capture-session-start` command is not backgrounded, so for
consistency `capture-session-end` need not be either; but since it does a spool write, appending `&`
(as the git hooks do) would make it fully fire-and-forget and avoid any chance of a busy-spool stalling
session teardown by up to the 5 s timeout. Best-effort + sub-ms writes make this low-stakes; decide in
the plan.

### D. `pensieve install-daemon` (+ `--uninstall`)

Mirrors the existing installer idioms: a pure/testable plist writer + a side-effecting `launchctl`
call.

**Pure plist writer** (PensieveKit) produces `~/Library/LaunchAgents/com.pensieve.sync.plist`. All
paths are **absolute** (launchd does no `~`/shell expansion of plist values):

- `ProgramArguments`: `[<stable pensieve path>, "sync"]`. **The path must be the stable
  `~/.local/bin/pensieve`, not `Bundle.main.executablePath` blindly.** When `install-daemon` is run
  via `swift run`, `executablePath` resolves into `.build/…/pensieve`, and `rm -rf .build` (a
  *routine* recovery step on this machine, per CLAUDE.md) then leaves the LaunchAgent firing every
  5 min against a missing binary — silent, unattended daemon death. `install-daemon` **must** resolve
  the stable installed path and refuse to install (clear error) if the running binary is under
  `.build`. Re-running after a rebuild keeps pointing at the same stable path.
- `StartInterval`: `300` (5 min, default).
- `RunAtLoad`: `true`. (`StartInterval` + `RunAtLoad` do not harmfully double-fire; a coincident tick
  is absorbed by `drain`'s `(sourceID, fingerprint)` dedup. The same-label singleton guarantees a
  cycle longer than 300 s defers the next tick rather than stacking — verified sound.)
- `ProcessType`: `Background` — lowers CPU scheduling priority and implies `LowPriorityIO`, so the
  multi-second on-device extraction never contends with interactive work (worst at login, when
  `RunAtLoad` fires during the login storm on a machine the user is actively working on).
- `StandardOutPath` / `StandardErrorPath`: `<home>/Library/Logs/Pensieve/sync.log`.
- **`EnvironmentVariables.PATH`** (absolute, no `~`):
  `<home>/.local/bin:/opt/homebrew/bin:/usr/bin:/bin`. **The single most important fix — two
  independent needs converge here.** launchd *replaces* the job PATH (no login-PATH inheritance), so:
  (a) `/usr/bin` and `/bin` are mandatory — `Git.run` execs `/usr/bin/env git`, so a PATH without
  `/usr/bin` makes **every** git call fail under the daemon, silently corrupting the tool's core
  output (sessions attribute to a different node than their commits because `git-common-dir` returns
  nil; commit subjects fall back to the raw hash; strands never materialize). The prior feasibility
  spike only exercised git-free extraction, so it did not catch this. (b) `~/.local/bin` (expanded
  absolute) + `/opt/homebrew/bin` let the `claude -p` extraction fallback resolve `claude`. On-device
  Foundation Models is the default and needs no PATH, but the fallback must work.

**Side effects of `install-daemon`:**

- Create `<home>/Library/Logs/Pensieve/` (launchd will not create the log dir; a missing dir makes the
  job fail to launch).
- **Load, reload-always:** `launchctl bootout gui/<uid> <plist>` (ignore the "not loaded" error on a
  fresh install) → then `launchctl bootstrap gui/<uid> <plist>`. Always rewrite the plist and reload,
  so a changed binary path / interval actually takes effect — *not* "detect already-loaded and skip,"
  which would pin the daemon to the stale definition. `bootout` returns before teardown completes, so
  `bootstrap` needs a small retry on the `EALREADY`/busy error; verify with
  `launchctl print gui/<uid>/com.pensieve.sync`. Treat "already bootstrapped" as success; never leave a
  half-installed state.
- `--uninstall`: `launchctl bootout` (safe/no-op if nothing is loaded) + remove the plist.

The plist writer is pure/testable; the `launchctl` calls and dir creation are the side effects.
Mirrors the `SettingsHookInstaller` pattern (idempotent write + a load step).

**Spool-write note (corrected after review).** A `sync` cycle writes the spool DB two ways: discovery
*appends* `SessionRefPayload` rows, and `drain` *marks* rows ingested (`markIngested`). Both are small
and bounded by WAL + the 5 s busy timeout. This does **not** violate the sacred capture path: the git
commit/checkout hooks run `pensieve capture-* … >/dev/null 2>&1 &` then `exit 0` (backgrounded,
error-swallowed), so even a `SQLITE_BUSY` on their spool `append` can neither fail nor delay a commit;
and `markIngested` holds the spool write lock only for a sub-ms `UPDATE` per row (the heavy parse/git
work happens *between* rows, holding no lock). The canonical store stays single-writer.

### E. Observability

`sync` logs a one-line per-cycle summary (drained N, ingested M sessions, extracted K loose ends) to
`sync.log`, **each line prefixed with an ISO timestamp** (local `Date.ISO8601FormatStyle` — no shared
mutable `static` formatter) so a silent failure can be correlated to a time. A cycle that hits a
provider/git error logs it to stderr (same file) and `sync` exits non-zero for that run. Since launchd
appends to `sync.log` forever, note a **log-truncation/rotation follow-up** (bounded size) — deferred,
not in this plan. The **heartbeat window already surfaces the effect** — spool-pending falls, event
and loose-end counts climb — so "is the daemon working?" is answerable at a glance without reading
logs.

## Testing

- **`TranscriptDiscovery`** (the real coverage), pure over a temp projects dir: (a) an already-an-event
  session (predicate true → skipped without reading the file), (b) a finished transcript within the age
  bound, not yet an event (→ returned), (c) an ancient transcript beyond the age bound (→ skipped),
  (d) a **0-byte** transcript (→ skipped, not spooled), (e) an **`isSidechain`/subagent** transcript
  (→ skipped). Assert exactly the top-level, non-empty, in-window, not-yet-ingested transcripts are
  returned. **No grace-window case** — that logic is gone.
- **`Ingester.drain` unattributable handling**: a non-empty, cwd-less `ccSession` row is **dropped**
  (marked ingested, not retried); an empty/unreadable row stays pending (retries when it later fills).
- **plist writer**: asserts `ProgramArguments[0]` is the stable installed path (**not** a `.build`
  path); `StartInterval` / `RunAtLoad` / `ProcessType == Background` / log paths; and
  **`EnvironmentVariables.PATH` is absolute (contains no `~`), includes `/usr/bin`, and includes the
  expanded home `.local/bin` + `/opt/homebrew/bin`**; idempotency (writing twice → one well-formed
  plist).
- **stable-path guard**: `install-daemon` refuses (throws a clear error) when the running binary
  resolves under `.build`.
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
  existing hooks; `sync` is a reader/ingester, entirely separate from the fire-and-forget hooks. Its
  writes are the canonical store (single-writer; existing dedup), discovery's spool `append`s + the
  spool's ingested marks (small, WAL + 5 s busy timeout), and its own plist / log — and because the
  git hooks are `&`-backgrounded + `exit 0`, none of this can block or fail a commit (see §D
  "Spool-write note").
- Reuse existing pieces — `Ingester.drain()`, `ExtractionRunner.run()` (incremental),
  `SessionRefPayload`, `TranscriptParser`, `SettingsHookInstaller`, `PensievePaths`. Don't reimplement.
  (The other installers use `Bundle.main.executablePath` for the hook command path; the daemon must
  *not* — see §D: it requires the stable `~/.local/bin/pensieve` and refuses a `.build` path.)
- Session ingestion resolves each transcript's node from its `cwd` / common-dir (via the existing
  ingester path), so sessions in repos that were never `scan`-ed still attribute correctly.
- Add a `PensievePaths.claudeProjectsURL()` helper built from
  `FileManager.default.homeDirectoryForCurrentUser` (reads `getpwuid`, correct even if launchd doesn't
  export `HOME`) — not `ProcessInfo.processInfo.environment["HOME"]`. Use the same home resolution for
  the plist's absolute `.local/bin`, `Library/Logs`, and `Library/LaunchAgents` paths. (Note: the
  `claude -p` fallback reads `~/.claude` credentials at runtime; under a `gui/<uid>` agent `HOME` is
  set, so this works — an implicit dependency worth stating.)
- No shared mutable `static ISO8601DateFormatter` (Swift 6).

## Adversarial review outcomes (2026-07-05)

Two independent opus reviewers audited this spec against the real code before any implementation.
Findings folded in above:

- **Critical — plist `PATH`.** Two reviewers hit `PATH` from different needs: it must include
  `/usr/bin` (else `Git.run`'s `/usr/bin/env git` fails → attribution silently corrupts) **and** be
  absolute (launchd doesn't expand `~`) so the `claude -p` fallback resolves. Unified value:
  `<home>/.local/bin:/opt/homebrew/bin:/usr/bin:/bin`. §D + Testing updated.
- **Critical — `.build`-pinned binary.** `install-daemon` must write the stable `~/.local/bin/pensieve`
  and refuse to install from a `.build` path (routine `rm -rf .build` would otherwise silently kill the
  daemon). §D + Testing updated.
- **Important — grace-window removal side effects.** Added the 0-byte guard, the `isSidechain`/subagent
  skip (protects the precision gate), and the `drain` permanent-drop rule for non-empty cwd-less rows
  (stops an unbounded spool leak). §A + §B + Testing updated.
- **Important — launchd load semantics.** Reload-always (bootout→bootstrap with race handling), and
  `ProcessType = Background` to avoid contending with interactive work at login. §D updated.
- **Refuted (kept as-is with grounding) — "sync writing the spool violates the sacred path."** One
  reviewer raised it; the other refuted it against the code: the commit hooks are `&`-backgrounded +
  `exit 0`, so a `SQLITE_BUSY` on `append` can't fail/delay a commit, and `markIngested` is a sub-ms
  per-row `UPDATE`. The "Spool-write note" in §D now states this precisely.
- **Verified sound:** mid-write/truncated-line reads (parser drops the partial line; watermark never
  advances past unextracted content), double-trigger dedup across SessionEnd + discovery, the
  filename→`sessionID` keying, `StartInterval` singleton/no-double-fire, and cwd-from-transcript
  attribution for deleted-cwd / unscanned repos.
- **Minor follow-ups noted, not blocking:** optional `capture-session-end` backgrounding; `sync.log`
  rotation; cross-node duplicate loose ends if a resumed session re-attributes to a different node.

## Self-review

- **Placeholders:** none — every component has a concrete interface and default value.
- **Consistency:** `sync = discovery → ingest` matches "reuse `Ingester.drain` + `ExtractionRunner`";
  the launchd one-shot model matches the "no resident process" decision; dropping the grace window
  matches the now-landed incremental re-extraction (mid-write ingest is safe); the `SessionEnd`
  matcher `""` matches the confirmed all-reasons contract.
- **Scope:** `sync` + `TranscriptDiscovery` + `capture-session-end` (+ SessionEnd installer) +
  `install-daemon` (+ plist writer) + the small `Ingester.drain` permanent-drop change — a single
  plan. UI / config surfaces explicitly deferred.
- **Ambiguity pinned:** "already ingested" checked by filename-derived `sessionID` before reading;
  no "finished" distinction (grace window removed) but 0-byte + `isSidechain` files are skipped;
  non-empty cwd-less rows are dropped (not retried); plist PATH is absolute and includes `/usr/bin`;
  the daemon binary is the stable `~/.local/bin/pensieve`; SessionEnd matcher `""`; interval 5 min,
  age bound 7 days — all named defaults.
