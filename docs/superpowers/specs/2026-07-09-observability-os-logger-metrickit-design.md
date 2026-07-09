# Observability: `os.Logger` + MetricKit — design (2026-07-09)

Replace the current ad-hoc `print()`/`sync.log` output with **Apple's first-party observability stack**:
structured logging via `os.Logger` (unified log → Console.app) and MetricKit crash/hang/diagnostic
collection persisted to a filesystem sink. The primary consumer is **a coding agent** reading structured
files to diagnose issues; the secondary consumer is the developer via Console.app. No in-app UI for now.

Side benefit: when a paid Apple Developer team account is acquired and the app moves to App Store /
TestFlight distribution, MetricKit payloads automatically surface in **Xcode Organizer** with zero
additional code — the subscriber + persistence code built here stays, and gains a dashboard for free.

## Motivation

- **Drain/extraction errors vanish.** The launchd daemon redirects stdout/stderr to `sync.log`, which
  is unstructured plain text (one `print()` per command). The app's background work logs nothing. A
  stuck spool row, a failing LLM call, or a crash between launches is invisible.
- **Coding agents need structured, parseable context.** When reporting a bug or asking for a fix, the
  agent needs to read recent logs, crashes, and performance data from known file paths — not hunt
  through `Console.app` interactively.
- **MetricKit hang diagnostics are the only automatic source of main-thread-blocking call trees.**
  Crashes land in `~/Library/Logs/DiagnosticReports/` automatically, but hangs (Foundation Models
  inference, SQLite contention, DNS lookup in `CloudLLMProvider`) do not unless MetricKit captures them.

## Scope

**In:**

1. **`os.Logger` subsystem + categories** across PensieveKit and PensieveApp, replacing `print()` in
   operational paths. Structured messages with privacy-annotated interpolation.
2. **MetricKit subscriber** (app-target only) receiving `MXDiagnosticPayload` on launch, persisting
   each payload as a timestamped JSON file under a known logs directory.
3. **Filesystem sink** for both: a `~/Library/Logs/Pensieve/diagnostics/` directory with one
   `.json` per MetricKit delivery, and a symlink/note pointing agents at the unified-log query for
   structured logs.
4. **Documented `log` commands** (in `CLAUDE.md`) so a coding agent can retrieve recent logs without
   Console.app.
5. **CLI `print()` is untouched** — the CLI's stdout is its UI; logging is for the library/app layers.

**Out:**

- In-app diagnostics UI (deferred; pairs with the "error surfacing" backlog carry).
- Custom performance metrics / `os_signpost` spans (future layer; add per-operation when profiling).
- Alerting / notifications on error (deferred to the in-app background-service migration).
- Changing the launchd daemon's log mechanism (it already has `sync.log`; the daemon will be retired).
- Any change to the trust gate, capture path, or store schema.

## Design

### 1. `os.Logger` — subsystem & categories

Subsystem: `"me.mazetti.pensieve"` (matches `CFBundleIdentifier`).

| Category | Location | Key messages |
|----------|----------|-------------|
| `sync` | `SyncRunner`, `Ingester.drain()` | cycle start/end, rows processed, events created, errors |
| `extraction` | `ExtractionRunner`, `LooseEndExtractor`, `LooseEndVerifier` | session processed, proposed/verified/inserted counts, provider errors, context-overflow re-splits |
| `llm` | `LLMProvider` impls, `SummaryBuilder` | prompt dispatched (length, provider kind), completion received (length, latency), errors |
| `ingest` | `Ingester.ingest(_:)` per-row | kind, outcome (created/deduped/dropped/error), fingerprint |
| `app` | `AppModel.start()`, `drainThenRefresh`, `focusContextDidChange` | lifecycle transitions, refresh triggers, watcher events |
| `discovery` | `SourceScanner`, `TranscriptDiscovery` | candidates found, sessions spooled |

Log levels:

- `.debug` — per-row/per-event detail (high volume, off by default in unified log)
- `.info` — cycle summaries, lifecycle transitions, provider selection
- `.error` — failures that lose data or degrade output (stuck row, provider timeout, Keychain read fail)
- `.fault` — invariant violations that should never happen (cycle guard triggered, schema mismatch)

Privacy: node names, file paths, session IDs are `.public` (single-user, no PII concern for your own
machine). Prompt/completion text is `.private` (redacted in non-developer Console unless overridden) to
avoid leaking transcript content into a shared log stream.

### 2. Logger instance placement

A single shared `Logger` instance per category, exposed from PensieveKit as internal (not public —
callers don't need to know about logging). Pattern:

```swift
// Sources/PensieveKit/Support/Log.swift
import os

enum Log {
  static let sync       = Logger(subsystem: "me.mazetti.pensieve", category: "sync")
  static let extraction = Logger(subsystem: "me.mazetti.pensieve", category: "extraction")
  static let llm        = Logger(subsystem: "me.mazetti.pensieve", category: "llm")
  static let ingest     = Logger(subsystem: "me.mazetti.pensieve", category: "ingest")
  static let discovery  = Logger(subsystem: "me.mazetti.pensieve", category: "discovery")
}
```

The app target adds its own:

```swift
// Sources/PensieveApp/AppLog.swift
import os

enum AppLog {
  static let app = Logger(subsystem: "me.mazetti.pensieve", category: "app")
}
```

### 3. MetricKit subscriber

App-target only (MetricKit requires a running `NSApplication`; the CLI doesn't qualify).

```swift
// Sources/PensieveApp/DiagnosticsCollector.swift
import MetricKit

final class DiagnosticsCollector: NSObject, MXMetricManagerSubscriber {
  static let shared = DiagnosticsCollector()

  private let outputDir: URL = PensievePaths.logsDirectory()
    .appendingPathComponent("diagnostics", isDirectory: true)

  func start() {
    try? FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
    MXMetricManager.shared.add(self)
  }

  func didReceive(_ payloads: [MXMetricPayload]) {
    for payload in payloads {
      write(payload.jsonRepresentation(), prefix: "metrics")
    }
  }

  func didReceive(_ payloads: [MXDiagnosticPayload]) {
    for payload in payloads {
      write(payload.jsonRepresentation(), prefix: "diagnostic")
    }
  }

  private func write(_ data: Data, prefix: String) {
    let ts = ISO8601DateFormatter().string(from: Date())
    let name = "\(prefix)-\(ts).json"
    let url = outputDir.appendingPathComponent(name)
    try? data.write(to: url, options: .atomic)
    Log.sync.info("MetricKit payload written: \(name, privacy: .public)")
  }
}
```

Registered in `AppModel.start()` (or `AppDelegate.applicationDidFinishLaunching`):

```swift
DiagnosticsCollector.shared.start()
```

### 4. Filesystem layout

```
~/Library/Logs/Pensieve/
├── sync.log                          ← existing (launchd stdout; retired with daemon)
├── diagnostics/
│   ├── diagnostic-2026-07-09T14:32:00Z.json   ← MXDiagnosticPayload
│   ├── diagnostic-2026-07-09T14:32:00Z.json
│   └── metrics-2026-07-09T14:32:00Z.json      ← MXMetricPayload (daily)
└── README.md                         ← short doc for agents: what's here + log commands
```

`README.md` contents (committed as a template, written on first `DiagnosticsCollector.start()`):

```markdown
# Pensieve logs & diagnostics

## Structured logs (os.Logger → unified log)

Stream live:
  log stream --predicate 'subsystem == "me.mazetti.pensieve"' --level debug

Recent entries (last 1h):
  log show --predicate 'subsystem == "me.mazetti.pensieve"' --last 1h --style compact

Filter by category:
  log show --predicate 'subsystem == "me.mazetti.pensieve" AND category == "extraction"' --last 1h

## MetricKit diagnostics

JSON files in ./diagnostics/ — one per MXMetricManager delivery (crashes, hangs, disk/CPU exceptions).
Delivered by the system on the app's next launch after the event occurred.

## Crash reports (automatic, no code)

~/Library/Logs/DiagnosticReports/Pensieve-*.ips
```

### 5. Retention

MetricKit payloads: keep the last **30 files** (≈30 days of daily metrics + sporadic diagnostics).
`DiagnosticsCollector.start()` prunes on launch: list directory, sort by name (ISO timestamp prefix
makes lexicographic = chronological), delete oldest beyond 30. Lightweight — no background timer.

### 6. Coding-agent integration

A coding agent debugging Pensieve can:

1. `log show --predicate 'subsystem == "me.mazetti.pensieve"' --last 2h --style json` → structured
   JSON lines with timestamp, category, level, message.
2. `ls ~/Library/Logs/Pensieve/diagnostics/` → see if any crash/hang payloads exist.
3. `cat ~/Library/Logs/Pensieve/diagnostics/diagnostic-*.json | python3 -m json.tool` → read the
   call tree of a hang or crash stack.
4. `ls ~/Library/Logs/DiagnosticReports/Pensieve-*.ips` → standard macOS crash reports.

The `CLAUDE.md` update documents these commands so any agent session has them in context.

### 7. Instrumentation sites (non-exhaustive; expand as needed)

| Site | Level | Example message |
|------|-------|-----------------|
| `SyncRunner.run()` entry/exit | `.info` | `"Sync cycle start"` / `"Sync complete: ingested=\(n) discovered=\(d) extracted=\(e)"` |
| `Ingester.drain()` per-row error | `.error` | `"Spool row \(id) failed: \(error)"` |
| `Ingester.ingest(_:)` outcome | `.debug` | `"Ingested row kind=\(kind) outcome=created"` |
| `ExtractionRunner.run()` per-session | `.info` | `"Extraction: session \(id) proposed=\(p) verified=\(v) inserted=\(i)"` |
| `LLMProvider.complete` dispatch | `.debug` | `"LLM prompt dispatched (len=\(n), provider=\(kind))"` |
| `LLMProvider.complete` error | `.error` | `"LLM provider failed: \(error)"` |
| `AppModel.start()` | `.info` | `"App started, canonical=\(path), spool=\(path)"` |
| `AppModel.drainThenRefresh` | `.info` | `"Drain+refresh: \(n) events created"` |
| `DirectoryWatcher` fire | `.debug` | `"FSEvent: \(category) watcher fired"` |
| `KeychainSecretStore.read` fail | `.error` | `"Keychain read failed for account=\(acct)"` |
| `CloudLLMProvider` HTTP error | `.error` | `"Cloud HTTP \(status): \(snippet)"` |
| `FoundationModelsProvider` error | `.error` | `"FoundationModels: \(error)"` |
| Strand birth | `.info` | `"Strand materialized: \(name) under \(project)"` |
| Transcript discovery | `.debug` | `"Discovered \(n) new transcripts"` |

### 8. Migration path

- `print()` calls in the CLI **stay** (they are user-facing output, not logging).
- `print()` calls that currently exist in PensieveKit operational code (there are none today — the
  library is silent) would be replaced by logger calls. The CLI commands that `print()` results are
  the CLI's responsibility and stay as-is.
- The launchd daemon's `sync.log` (stdout redirect) continues to work — `os.Logger` writes to the
  unified log independently. When the daemon is retired (in-app background service), `sync.log`
  disappears naturally.

## Risks & mitigations

| Risk | Mitigation |
|------|-----------|
| Unified log fills with debug noise | `.debug` is off by default; only `.info`+ persists. Explicitly enable with `log config --subsystem me.mazetti.pensieve --mode level:debug` when investigating. |
| MetricKit payloads never delivered (ad-hoc signed) | Empirically verify on first build. If the system requires distribution signing, degrade gracefully (subscriber registered but no payloads; the diagnostics dir stays empty until signing is resolved). Document the finding. |
| Log messages leak transcript content | `.private` on prompt/completion text; `.public` only on operational metadata (counts, IDs, paths, durations). |
| Disk accumulation in diagnostics/ | 30-file cap enforced on launch. At ~50KB/payload, worst case is ~1.5 MB. |

## Acceptance criteria

1. `log show --predicate 'subsystem == "me.mazetti.pensieve"' --last 5m` shows structured messages
   after a `pensieve sync` or an app drain.
2. `~/Library/Logs/Pensieve/diagnostics/` exists and `DiagnosticsCollector` is registered (even if
   no payloads have been delivered yet — verify via the `.info` log on start).
3. `CLAUDE.md` documents the log-query commands.
4. No `print()` added or removed in the CLI layer; no change to capture/ingest/trust behavior.
5. `swift test` passes (logging is side-effect-free; no test changes expected).
6. Existing `sync.log` mechanism is **undisturbed** (additive only).

## Non-goals / future layers

- **`os_signpost` performance spans** — add per-operation (drain, extraction, LLM call) when actively
  profiling. Not day-one; the `.debug` log with timestamps gives coarse timing.
- **In-app diagnostics surface** — a Settings tab showing last-drain outcome, error count, recent
  MetricKit summaries. Pairs with the "error surfacing" backlog carry.
- **Alerting** — a local notification when MetricKit delivers a crash diagnostic. Trivial to add on
  top of `DiagnosticsCollector` later.
- **Structured export for CI / automation** — if builds move to a CI machine, `log collect` can
  archive the unified log for a time range into a `.logarchive` that Xcode/Console can open.
