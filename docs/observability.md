# Observability — guide for coding agents

How to diagnose Pensieve issues autonomously. All data lives on the local machine — no cloud dashboards, no API keys needed.

## Quick-start: something went wrong

```bash
# 1. Check recent errors (last 2 hours)
log show --predicate 'subsystem == "me.mazetti.pensieve"' --last 2h --style compact --info 2>&1 | grep -i error

# 2. Check for crashes
ls ~/Library/Logs/DiagnosticReports/Pensieve-*.ips 2>/dev/null

# 3. Check for hangs (MetricKit diagnostic payloads)
ls ~/Library/Logs/Pensieve/diagnostics/diagnostic-*.json 2>/dev/null

# 4. Read the most recent crash/hang payload
cat "$(ls -t ~/Library/Logs/Pensieve/diagnostics/diagnostic-*.json 2>/dev/null | head -1)"
```

## Structured logs (`os.Logger`)

Pensieve logs to the macOS unified log with subsystem `me.mazetti.pensieve`. Messages are **not** in files — they live in the system log store and are queried with the `log` CLI.

### Categories

| Category | Where it fires | What to look for |
|----------|---------------|------------------|
| `sync` | `SyncRunner.run()` | Cycle start/end, ingested/discovered/extracted counts |
| `ingest` | `Ingester.drain()`, `nameStrand`, `refineProjectNames` | Per-row outcome (created/deduped/failed), strand naming, project name refinement |
| `extraction` | `ExtractionRunner.run()` | Per-session proposed/verified/inserted counts, skips (unchanged), errors |
| `llm` | `CloudLLMProvider`, `FoundationModelsProvider`, `ClaudeCLIProvider` | Prompt dispatched (length, provider kind), completion received, HTTP errors, timeouts |
| `discovery` | `SourceScanner`, `TranscriptDiscovery` | Candidates found, sessions spooled |
| `app` | `AppModel` lifecycle | App start (store paths), drain/refresh triggers, watcher fires, focus context changes, provider rebuilds |
| `capture` | `appendCapture` (every `pensieve capture-*`) | **The sacred path.** One line only, and it is the one that matters: `CAPTURE LOST (kind=…)` when a capture could not be spooled. Silence here is success. A lost capture is unrecoverable — the git hook has already exited 0 and git will never mention it again — so this is the only place it is ever visible. Watch with `--predicate 'category == "capture"'` while committing if a commit seems not to have been recorded |
| `translation` | `TranslationStore` (open / put / prune) | Cache open failures, write failures, prune failures. Its own category since 2026-08-24: these logged under `search`, so a translation-cache outage read as a retrieval problem |
| `widget` | `WidgetDigestPublisher.publishQuietly` (write), `WhatsNextProvider.getTimeline` (read) | Both halves of the digest hand-off, and the only signal either failed. `publishQuietly` swallows every error by contract, so a bad publish can never surface as a failed sync or a UI error. On the read side the appex logs `timeline: <state> items=<n> age=<s>s` per render — `state` distinguishes a genuinely empty queue from a failed read, which both render as "Open Pensieve to get started". A widget that looks stale is diagnosed here: compare the render's `age` against the digest's own mtime |

### Log levels

| Level | Meaning | Visible by default? |
|-------|---------|-------------------|
| `.debug` | Per-row/per-event detail (high volume) | No — add `--level debug` to `log stream`, `--debug` to `log show` |
| `.info` | Cycle summaries, lifecycle transitions | No in `log show` — add `--info`; yes in `log stream --level debug` |
| `.error` | Failures that lose data or degrade output | **Yes** — always persisted and shown |
| `.fault` | Invariant violations (should never happen) | **Yes** |

### Commands

```bash
# Stream live — all categories, all levels (best for watching a sync/extraction in real time)
log stream --predicate 'subsystem == "me.mazetti.pensieve"' --level debug

# Recent history — errors only (fastest scan)
log show --predicate 'subsystem == "me.mazetti.pensieve"' --last 2h --style compact

# Recent history — include info (cycle summaries, lifecycle)
log show --predicate 'subsystem == "me.mazetti.pensieve"' --last 2h --style compact --info

# Recent history — include everything
log show --predicate 'subsystem == "me.mazetti.pensieve"' --last 2h --style compact --info --debug

# Filter to one category
log show --predicate 'subsystem == "me.mazetti.pensieve" AND category == "extraction"' --last 1h --info

# JSON export (machine-parseable)
log show --predicate 'subsystem == "me.mazetti.pensieve"' --last 2h --style ndjson --info
```

**Gotcha:** `log show` without `--info` or `--debug` shows only `.error` and `.fault`. Most operational messages are `.info`. Always add `--info` unless you only care about errors.

### Privacy annotations

- **`.public`** (visible in all log contexts): node names, file paths, session IDs, counts, durations, provider kinds, focus contexts — all single-user operational metadata.
- **`.private`** (redacted unless dev-mode override): prompt and completion text — avoids leaking transcript content into the shared log stream.

## MetricKit diagnostics

`DiagnosticsCollector` (registered in `AppDelegate.applicationDidFinishLaunching`) subscribes to `MXMetricManager`. The system delivers payloads **on the next app launch** after a crash, hang, or daily metric collection.

### File layout

```
~/Library/Logs/Pensieve/
├── sync.log              ← summary line per sync cycle, appended by the bundled agent's helper
│                            (size-capped at 1 MB — trimmed to its newest half past that)
├── README.md             ← short doc with log commands
└── diagnostics/
    ├── diagnostic-2026-07-09T14:32:00Z.json   ← crash/hang payload
    └── metrics-2026-07-09T14:32:00Z.json      ← daily performance metrics
```

- **Retention:** 30 files max, oldest pruned on launch and after each write.
- **Empty is normal:** MetricKit only delivers payloads when events occur. An empty `diagnostics/` directory means no crashes or hangs have been captured.

### Reading a diagnostic payload

Each `.json` file is a serialized `MXDiagnosticPayload` or `MXMetricPayload`. Key fields:

- `crashDiagnostics` — crash call stacks
- `hangDiagnostics` — main-thread-blocking call trees (the only automatic source of hang stacks)
- `cpuExceptionDiagnostics`, `diskWriteExceptionDiagnostics` — resource limit violations

```bash
# Pretty-print the most recent diagnostic
# `plutil` is built in and needs no toolchain; this repo's rule is Swift only, no Python.
plutil -p "$(ls -t ~/Library/Logs/Pensieve/diagnostics/diagnostic-*.json | head -1)" | head -100
```

## macOS crash reports

Standard `.ips` files — no Pensieve code involved, the OS writes these automatically:

```bash
ls ~/Library/Logs/DiagnosticReports/Pensieve-*.ips
```

## Debugging recipes

### "The spool isn't draining"
```bash
# Check for ingest errors
log show --predicate 'subsystem == "me.mazetti.pensieve" AND category == "ingest"' --last 1h --info
# Look for "Spool row X failed" errors — the row stays pending and retries next drain
```

### "Extraction produces no loose ends"
```bash
# Check extraction category — look for skip (unchanged), proposed/verified/inserted counts
log show --predicate 'subsystem == "me.mazetti.pensieve" AND category == "extraction"' --last 2h --info
# If proposed > 0 but verified = 0, the verifier is rejecting — quotes don't match the transcript
```

### "LLM narration isn't working"
```bash
# Check llm category — look for provider errors, timeouts
log show --predicate 'subsystem == "me.mazetti.pensieve" AND category == "llm"' --last 1h --info
# Common: "Cloud HTTP 401" (bad key), "claude -p timed out" (subprocess hung), "FoundationModels: ..." (on-device failure)
```

### "The app shows stale data"
```bash
# Check app category — are watchers firing? Is drain+refresh triggering?
log show --predicate 'subsystem == "me.mazetti.pensieve" AND category == "app"' --last 30m --info --debug
# Look for "Spool watcher fired -> drain" and "Canonical watcher fired -> refresh"
# If missing, the FSEventStream watches may have stopped
```

### "Background sync isn't running"
```bash
# Check the bundled SMAppService agent's launchd job (registered from /Applications/Pensieve.app)
launchctl print gui/$(id -u)/me.mazetti.pensieve.sync 2>&1 | grep -iE "state|last exit"
# `last exit code = 78 (EX_CONFIG)` / `needs LWCR update` ⇒ stale cdhash after a rebuild;
# relaunch the app (registerIfNeeded does unregister()+register() to refresh the LWCR).
# Summary line per cycle, appended by the helper (mtime feeds SystemStatus.lastSyncAt):
tail -50 ~/Library/Logs/Pensieve/sync.log
# os.Logger from the helper shows up under process name "PensieveSyncAgent"
log show --predicate 'subsystem == "me.mazetti.pensieve" AND process == "PensieveSyncAgent"' --last 1h --info
```

### "The widget shows nothing, or stale data"

The digest is a file, so start there rather than in the log:

```bash
# Does it exist, how old is it, and does it hold REAL project names?
D=~/Library/Group\ Containers/TH593VRB6W.me.mazetti.pensieve/widget-digest.json
stat -f "%Sm  %z bytes" "$D" && plutil -p "$D"
```

- **File missing** → nobody has published. The widget renders "Open Pensieve to get started", which is
  correct behaviour, not a bug. Launch the app, or wait for a sync-agent pass.
- **File present but old** → the widget labels it "as of HH:MM" by design. Check whether the agent is
  alive (`launchctl print gui/$UID/me.mazetti.pensieve.sync`) — a dead agent means the 300 s floor is
  gone and only the app republishes.
- **File present and fresh, widget still wrong** → check the publish actually succeeded. `publishQuietly`
  swallows every error by contract, so a failure appears NOWHERE except this category:

```bash
log show --predicate 'subsystem == "me.mazetti.pensieve" AND category == "widget"' --last 2h --info
```

- **Widget shows "Open Pensieve to get started" while the file plainly exists** → the sandbox cannot see
  it. That is the App Group entitlement, not the digest: `secd`/`trustd` log
  `Entitlement com.apple.security.application-groups=(…) is ignored because of invalid application
  signature or incorrect provisioning profile` when no provisioning profile has been minted. The app is
  unaffected because it is not sandboxed and writes the path directly — which is exactly why this failure
  looks like "the widget is broken" rather than "signing is incomplete".

```bash
log show --predicate 'eventMessage CONTAINS "application-groups"' --last 10m --style syslog
```

## Source code

| File | Role |
|------|------|
| `Sources/PensieveKit/Support/Log.swift` | `enum Log` — 9 category loggers (internal to PensieveKit): sync, extraction, llm, ingest, discovery, semantic, search, widget, translation |
| `Sources/PensieveApp/AppLog.swift` | `enum AppLog` — app-target `app` category logger |
| `Sources/PensieveApp/DiagnosticsCollector.swift` | MetricKit subscriber, JSON writer, retention pruner |
