# Observability: `os.Logger` + MetricKit — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add structured logging (`os.Logger`) across PensieveKit and the app, plus a MetricKit diagnostic subscriber that persists crash/hang payloads to the filesystem — making operational health visible to Console.app and coding agents reading files.

**Architecture:** A thin `Log` enum in PensieveKit exposes `Logger` instances per category (sync, extraction, llm, ingest, discovery). The app adds its own `AppLog` + a `DiagnosticsCollector` (`MXMetricManagerSubscriber`) that writes each received `MXDiagnosticPayload`/`MXMetricPayload` as a JSON file under `~/Library/Logs/Pensieve/diagnostics/`. A README template at that path documents the `log show` commands for agents. Retention: 30 files max, pruned on app launch.

**Tech Stack:** Swift 6, `os` framework (`Logger`), `MetricKit` (`MXMetricManager`), Foundation `FileManager`/`JSONSerialization`. No new SwiftPM dependencies. MetricKit is app-target-only (framework linked in `project.yml`).

## Global Constraints

- **Swift only. No Python, ever.**
- **No new SwiftPM dependencies.** `os` and `MetricKit` are system frameworks.
- **CLI `print()` is untouched.** The CLI's stdout IS its user interface; logging is library/app only.
- **No behavioral change.** Logging is observational — no control flow, no error handling, no test behavior change.
- **Privacy:** node names, paths, session IDs → `.public` (single-user machine). Prompt/completion text → `.private` (redacted by default).
- **`swift test` must still pass unchanged** (Logger calls are side-effect-free and execute in-process; no mocking needed).
- **App build:** `xcodegen generate && xcodebuild -project Pensieve.xcodeproj -scheme Pensieve -configuration Debug -derivedDataPath ./.build-xcode build`; verify with a non-blocking smoke-launch.
- **Localization:** no new user-facing strings (logging is developer-only).

---

## File Structure

**PensieveKit (SwiftPM)**
- `Sources/PensieveKit/Support/Log.swift` (new) — `enum Log` with per-category `Logger` instances.

**PensieveApp (Xcode target)**
- `Sources/PensieveApp/AppLog.swift` (new) — `enum AppLog` with the `app` category logger.
- `Sources/PensieveApp/DiagnosticsCollector.swift` (new) — `MXMetricManagerSubscriber`, JSON file writer, retention pruner.

**Instrumentation (modify — add log calls)**
- `Sources/PensieveKit/Sync/SyncRunner.swift`
- `Sources/PensieveKit/Ingest/Ingester.swift`
- `Sources/PensieveKit/Intelligence/ExtractionRunner.swift`
- `Sources/PensieveKit/Intelligence/LooseEndExtractor.swift`
- `Sources/PensieveKit/LLM/CloudProvider.swift`
- `Sources/PensieveKit/LLM/FoundationModelsProvider.swift`
- `Sources/PensieveKit/LLM/ClaudeCLIProvider.swift`
- `Sources/PensieveKit/Discovery/SourceScanner.swift` (if discovery logging is useful)
- `Sources/PensieveApp/AppModel.swift`

**Docs**
- `CLAUDE.md` (modify) — add the `log show`/`log stream` commands.

**Project config**
- `project.yml` (modify) — link `MetricKit.framework` to the app target.

---

## Task 1: `Log` enum — PensieveKit logger instances

**Files:**
- Create: `Sources/PensieveKit/Support/Log.swift`

**What:**

Create the central logger namespace. Internal visibility (not `public`) — callers within PensieveKit use `Log.sync.info(...)` etc.; the app target defines its own.

```swift
import os

enum Log {
  static let sync       = Logger(subsystem: "me.mazetti.pensieve", category: "sync")
  static let extraction = Logger(subsystem: "me.mazetti.pensieve", category: "extraction")
  static let llm        = Logger(subsystem: "me.mazetti.pensieve", category: "llm")
  static let ingest     = Logger(subsystem: "me.mazetti.pensieve", category: "ingest")
  static let discovery  = Logger(subsystem: "me.mazetti.pensieve", category: "discovery")
}
```

**Verification:**
- `./scripts/test.sh` passes (no behavioral change).
- The file compiles as part of PensieveKit.

- [ ] Step 1: Create `Sources/PensieveKit/Support/Log.swift` with the enum above.
- [ ] Step 2: Run `./scripts/test.sh` — confirm green.

---

## Task 2: `AppLog` — app-target logger

**Files:**
- Create: `Sources/PensieveApp/AppLog.swift`

**What:**

```swift
import os

enum AppLog {
  static let app = Logger(subsystem: "me.mazetti.pensieve", category: "app")
}
```

**Verification:**
- App builds (`xcodegen generate && xcodebuild …`).

- [ ] Step 1: Create `Sources/PensieveApp/AppLog.swift`.
- [ ] Step 2: Verify the app builds.

---

## Task 3: Instrument `SyncRunner` + `Ingester`

**Files:**
- Modify: `Sources/PensieveKit/Sync/SyncRunner.swift`
- Modify: `Sources/PensieveKit/Ingest/Ingester.swift`

**What:**

`SyncRunner.run()`:
- `.info` at entry: `"Sync cycle start"`
- `.info` at exit: `"Sync complete: ingested=\(ingested, privacy: .public) discovered=\(discovered.count, privacy: .public) extracted=\(extracted, privacy: .public)"`

`Ingester.drain()`:
- `.info` at entry: `"Drain start: \(rows.count, privacy: .public) pending rows"`
- `.debug` per successful row: `"Ingested row \(row.id, privacy: .public) kind=\(row.kind, privacy: .public) events=\(n, privacy: .public)"`
- `.error` per failed row: `"Spool row \(row.id, privacy: .public) failed: \(error, privacy: .public)"`
- `.info` at exit: `"Drain complete: \(created, privacy: .public) events created"`

`Ingester.nameStrand()`:
- `.info` on success: `"Strand named: \(name, privacy: .public) (id=\(strandID, privacy: .public))"`

`Ingester.refineProjectNames()`:
- `.info`: `"Refining project names: \(candidates.count, privacy: .public) candidates"`

**Verification:**
- `./scripts/test.sh` passes.
- `swift run pensieve sync` then `log show --predicate 'subsystem == "me.mazetti.pensieve" AND category == "sync"' --last 1m` shows messages. (Manual — document as a human-verify carry.)

- [ ] Step 1: Add `Log.sync` calls to `SyncRunner.run()` (entry + exit).
- [ ] Step 2: Add `Log.ingest` calls to `Ingester.drain()` (entry + per-row + exit).
- [ ] Step 3: Add `Log.ingest` calls to `Ingester.nameStrand()` and `refineProjectNames()`.
- [ ] Step 4: Run `./scripts/test.sh` — confirm green.

---

## Task 4: Instrument `ExtractionRunner`

**Files:**
- Modify: `Sources/PensieveKit/Intelligence/ExtractionRunner.swift`

**What:**

`ExtractionRunner.run()`:
- `.info` at entry: `"Extraction start: \(events.count, privacy: .public) sessions to evaluate"`
- `.info` per session extracted (not skipped): `"Extracted session \(sessionID, privacy: .public): proposed=\(proposed, privacy: .public) verified=\(verified, privacy: .public) inserted=\(inserted, privacy: .public)"`
- `.debug` per session skipped (unchanged size): `"Extraction skip (unchanged): \(sessionID, privacy: .public)"`
- `.error` per session failed: `"Extraction failed for \(sessionID, privacy: .public): \(error, privacy: .public)"`
- `.info` at exit: `"Extraction complete: \(results.count, privacy: .public) sessions processed"`

**Verification:**
- `./scripts/test.sh` passes.

- [ ] Step 1: Add `Log.extraction` calls to `ExtractionRunner.run()` at the documented points.
- [ ] Step 2: Run `./scripts/test.sh` — confirm green.

---

## Task 5: Instrument LLM providers

**Files:**
- Modify: `Sources/PensieveKit/LLM/CloudProvider.swift`
- Modify: `Sources/PensieveKit/LLM/FoundationModelsProvider.swift`
- Modify: `Sources/PensieveKit/LLM/ClaudeCLIProvider.swift`

**What:**

Each provider's `complete(prompt:)`:
- `.debug` at dispatch: `"LLM prompt dispatched (len=\(prompt.count, privacy: .public), provider=<kind>)"`
- `.debug` on success: `"LLM completion received (len=\(result.count, privacy: .public))"`
- `.error` on failure: `"LLM provider failed (<kind>): \(error, privacy: .public)"`

`CloudLLMProvider.complete`:
- `.error` on HTTP non-2xx: already throws, but add a log *before* the throw with status + snippet length.

`ClaudeCLIProvider`:
- `.debug` on subprocess launch: `"claude -p subprocess launched"`
- `.error` on timeout/SIGPIPE/non-zero exit.

`FoundationModelsProvider`:
- `.debug` on structured-output schema build.
- `.error` on inference failure.

**Verification:**
- `./scripts/test.sh` passes (provider tests use real instances but side-effect-free logging doesn't interfere).

- [ ] Step 1: Add `Log.llm` calls to `CloudProvider.swift`.
- [ ] Step 2: Add `Log.llm` calls to `FoundationModelsProvider.swift`.
- [ ] Step 3: Add `Log.llm` calls to `ClaudeCLIProvider.swift`.
- [ ] Step 4: Run `./scripts/test.sh` — confirm green.

---

## Task 6: Instrument `AppModel` lifecycle

**Files:**
- Modify: `Sources/PensieveApp/AppModel.swift`

**What:**

`start()`:
- `.info`: `"App started — canonical=\(Stores.canonicalURL.path, privacy: .public) spool=\(Stores.spoolURL.path, privacy: .public)"`
- `.info`: `"Liveness watchers registered"`

`drainThenRefresh()`:
- `.info`: `"Drain+refresh triggered"`

`drainThenRefreshFromWatch()` / `refreshFromWatch()`:
- `.debug`: `"Spool watcher fired → drain"` / `"Canonical watcher fired → refresh"`

`focusContextDidChange()`:
- `.info` (only when actually changed): `"Focus context changed: '\(old)' → '\(new)'"` (use `.public` — it's just "work"/"personal"/"")

`rebuildSummaryBuilder()`:
- `.info`: `"Provider rebuilt: \(providerKind, privacy: .public)"`

**Verification:**
- App builds + smoke-launches.

- [ ] Step 1: Add `AppLog.app` calls to `AppModel` at the documented points.
- [ ] Step 2: Build the app; smoke-launch; `log show --predicate 'subsystem == "me.mazetti.pensieve" AND category == "app"' --last 1m` shows "App started".

---

## Task 7: `DiagnosticsCollector` — MetricKit subscriber

**Files:**
- Create: `Sources/PensieveApp/DiagnosticsCollector.swift`
- Modify: `project.yml` (link MetricKit)
- Modify: `Sources/PensieveApp/AppModel.swift` or `AppDelegate.swift` (register on launch)

**What:**

```swift
import Foundation
import MetricKit
import os
import PensieveKit

final class DiagnosticsCollector: NSObject, MXMetricManagerSubscriber {
  static let shared = DiagnosticsCollector()

  private let outputDir: URL = PensievePaths.logsDirectory()
    .appendingPathComponent("diagnostics", isDirectory: true)
  private let maxFiles = 30

  func start() {
    try? FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
    prune()
    writeREADMEIfNeeded()
    MXMetricManager.shared.add(self)
    AppLog.app.info("DiagnosticsCollector registered")
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
    AppLog.app.info("MetricKit payload written: \(name, privacy: .public)")
    prune()
  }

  private func prune() {
    guard let files = try? FileManager.default.contentsOfDirectory(
      at: outputDir, includingPropertiesForKeys: nil)
      .filter({ $0.pathExtension == "json" })
      .sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
    else { return }
    if files.count > maxFiles {
      for file in files.prefix(files.count - maxFiles) {
        try? FileManager.default.removeItem(at: file)
      }
    }
  }

  private func writeREADMEIfNeeded() {
    let readme = PensievePaths.logsDirectory().appendingPathComponent("README.md")
    guard !FileManager.default.fileExists(atPath: readme.path) else { return }
    let content = """
    # Pensieve logs & diagnostics

    ## Structured logs (os.Logger → unified log)

    Stream live:
      log stream --predicate 'subsystem == "me.mazetti.pensieve"' --level debug

    Recent entries (last 1h):
      log show --predicate 'subsystem == "me.mazetti.pensieve"' --last 1h --style compact

    Filter by category:
      log show --predicate 'subsystem == "me.mazetti.pensieve" AND category == "extraction"' --last 1h

    Export as JSON (for agent consumption):
      log show --predicate 'subsystem == "me.mazetti.pensieve"' --last 2h --style ndjson

    ## MetricKit diagnostics

    JSON files in ./diagnostics/ — one per MXMetricManager delivery (crashes, hangs, CPU/disk exceptions).
    Delivered by the system on the app's next launch after the event.

    ## Crash reports (automatic, no code)

    ~/Library/Logs/DiagnosticReports/Pensieve-*.ips
    """
    try? content.write(to: readme, atomically: true, encoding: .utf8)
  }
}
```

`project.yml` addition (under the Pensieve target's `dependencies` or `settings`):

```yaml
    frameworks:
      - MetricKit
```

Registration — add to `AppModel.start()` (after the `guard !started` gate, before the drain):

```swift
DiagnosticsCollector.shared.start()
```

**Verification:**
- App builds with MetricKit linked.
- Smoke-launch: `~/Library/Logs/Pensieve/diagnostics/` directory exists; `README.md` written.
- `log show` confirms "DiagnosticsCollector registered" message.

- [ ] Step 1: Add `MetricKit` framework linkage in `project.yml`.
- [ ] Step 2: Create `Sources/PensieveApp/DiagnosticsCollector.swift`.
- [ ] Step 3: Register `DiagnosticsCollector.shared.start()` in `AppModel.start()`.
- [ ] Step 4: `xcodegen generate && xcodebuild …` — confirm the build succeeds.
- [ ] Step 5: Smoke-launch the app; verify directory + README + log message.

---

## Task 8: Update `CLAUDE.md` with log commands

**Files:**
- Modify: `CLAUDE.md` (project root)

**What:**

Add a new section (after "Build & test", before "Architecture"):

```markdown
## Observability

Structured logging is via `os.Logger` (subsystem `me.mazetti.pensieve`). Useful commands:

- **Stream live (all categories):** `log stream --predicate 'subsystem == "me.mazetti.pensieve"' --level debug`
- **Recent logs (last 2h):** `log show --predicate 'subsystem == "me.mazetti.pensieve"' --last 2h --style compact`
- **Single category:** `log show --predicate 'subsystem == "me.mazetti.pensieve" AND category == "extraction"' --last 1h`
- **JSON export (for parsing):** `log show --predicate 'subsystem == "me.mazetti.pensieve"' --last 2h --style ndjson`
- **MetricKit diagnostics (crash/hang payloads):** `ls ~/Library/Logs/Pensieve/diagnostics/`
- **macOS crash reports:** `ls ~/Library/Logs/DiagnosticReports/Pensieve-*.ips`

Categories: `sync`, `extraction`, `llm`, `ingest`, `discovery`, `app`.
```

**Verification:**
- Read the updated `CLAUDE.md` and confirm the section is coherent.

- [ ] Step 1: Add the "Observability" section to `CLAUDE.md`.

---

## Task 9: Final verification

**Files:** none (verification only).

**Verification steps:**

- [ ] Step 1: `./scripts/test.sh` — all tests pass (no behavioral change).
- [ ] Step 2: `xcodegen generate && xcodebuild -project Pensieve.xcodeproj -scheme Pensieve -configuration Debug -derivedDataPath ./.build-xcode build` — clean build.
- [ ] Step 3: Smoke-launch the app (`PENSIEVE_DB` + `PENSIEVE_CAPTURE_DB` pointing at temp files):
  - Confirm `~/Library/Logs/Pensieve/diagnostics/` exists.
  - Confirm `~/Library/Logs/Pensieve/README.md` exists.
  - `log show --predicate 'subsystem == "me.mazetti.pensieve"' --last 1m --style compact` shows "App started" + "DiagnosticsCollector registered".
- [ ] Step 4: Run `swift run pensieve sync` (or `ingest` if a spool row exists) and confirm `log show … category == "sync"` shows cycle messages.

---

## Human-verify carries (need a running app + real store)

- MetricKit payload delivery: provoke a hang (e.g., `Thread.sleep` on main) or wait for the system to naturally deliver a metric payload. Confirm a `.json` file appears in `diagnostics/`. (May require a day to accumulate.)
- Retention: create >30 dummy files in `diagnostics/`; relaunch; confirm oldest are pruned.
- Console.app: open Console, filter by subsystem `me.mazetti.pensieve`, trigger a sync — see structured messages with categories and levels color-coded.

---

## Sequencing & parallelism

Tasks 1–2 are independent (Kit vs. app) and can run in parallel.
Tasks 3–6 depend on Task 1 (they import `Log`). Tasks 3, 4, 5, 6 are independent of each other.
Task 7 depends on Task 2 (imports `AppLog`). Task 7 is independent of Tasks 3–6.
Task 8 is independent of all code tasks.
Task 9 depends on all prior tasks.

```
  1 (Log.swift)──┬──3 (Sync+Ingest)──┐
                 ├──4 (Extraction)────┤
                 ├──5 (LLM)───────────┤
                 └──6 (AppModel)──────┤
  2 (AppLog)────────7 (MetricKit)─────┤
  8 (CLAUDE.md)───────────────────────┤
                                      └──9 (Final verify)
```
