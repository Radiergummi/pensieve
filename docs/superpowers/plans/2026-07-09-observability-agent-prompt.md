# Agent Prompt: Implement Observability (os.Logger + MetricKit)

Implement the observability plan at `docs/superpowers/plans/2026-07-09-observability-os-logger-metrickit.md`. Read that file first — it contains the full task breakdown, file structure, code examples, and verification steps.

Also read the spec at `docs/superpowers/specs/2026-07-09-observability-os-logger-metrickit-design.md` for design rationale and the instrumentation-site table.

## Context

Pensieve is a personal macOS app (Swift 6, SwiftPM library + XcodeGen/Xcode app bundle). The project has zero logging today — operational outcomes (drain/extraction/LLM) are invisible. This task adds Apple's first-party observability: `os.Logger` for structured logging and MetricKit for crash/hang diagnostics persisted to disk.

**Primary consumers:** coding agents reading files + Console.app. No in-app UI.

## Key files you'll touch

**New files:**
- `Sources/PensieveKit/Support/Log.swift` — `enum Log` with per-category `Logger` instances (internal visibility)
- `Sources/PensieveApp/AppLog.swift` — `enum AppLog` with the `app` category
- `Sources/PensieveApp/DiagnosticsCollector.swift` — `MXMetricManagerSubscriber` + JSON file sink

**Instrument (add log calls):**
- `Sources/PensieveKit/Sync/SyncRunner.swift` — cycle start/end
- `Sources/PensieveKit/Ingest/Ingester.swift` — drain entry/exit, per-row outcomes, errors
- `Sources/PensieveKit/Intelligence/ExtractionRunner.swift` — per-session outcomes, skips, errors
- `Sources/PensieveKit/LLM/CloudProvider.swift` — HTTP errors
- `Sources/PensieveKit/LLM/FoundationModelsProvider.swift` — inference errors
- `Sources/PensieveKit/LLM/ClaudeCLIProvider.swift` — subprocess launch, timeout, errors
- `Sources/PensieveApp/AppModel.swift` — lifecycle (start, drain, watcher fires, provider rebuild)

**Config:**
- `project.yml` — add `sdk: MetricKit` framework linkage to the Pensieve target
- `CLAUDE.md` — add an "Observability" section with `log show`/`log stream` commands

## Constraints

- **No new SwiftPM dependencies.** `os` and `MetricKit` are system frameworks.
- **CLI `print()` stays untouched.** Don't add logging to `Sources/pensieve/` — the CLI's stdout IS its UI.
- **No behavioral change.** Logging is purely observational. No test changes should be needed.
- **Privacy annotations:** node names, paths, IDs, counts → `.public`. Prompt/completion text → `.private`.
- **Log levels:** `.debug` for per-row/high-volume detail, `.info` for cycle summaries and lifecycle, `.error` for failures, `.fault` for invariant violations.
- **Swift 6 strict concurrency** — `Logger` is `Sendable`; the `Log` enum is fine as-is.

## How to link MetricKit in project.yml

Under the `Pensieve` target, add a `dependencies` entry for the system framework:

```yaml
    dependencies:
      - package: PensieveKit
        product: PensieveKit
      - package: MarkdownUI
        product: MarkdownUI
      - framework: MetricKit.framework
```

(XcodeGen uses `framework:` for system frameworks.)

## Verification

1. `./scripts/test.sh` must pass (logger calls are side-effect-free).
2. `xcodegen generate && xcodebuild -project Pensieve.xcodeproj -scheme Pensieve -configuration Debug -derivedDataPath ./.build-xcode build` must succeed.
3. Smoke-launch: run `./.build-xcode/Build/Products/Debug/Pensieve.app/Contents/MacOS/Pensieve` in background with `PENSIEVE_DB=/tmp/pensieve-test.sqlite PENSIEVE_CAPTURE_DB=/tmp/pensieve-test-cap.sqlite` and kill after 3s. Confirm:
   - `~/Library/Logs/Pensieve/diagnostics/` directory exists
   - `~/Library/Logs/Pensieve/README.md` exists
   - `log show --predicate 'subsystem == "me.mazetti.pensieve"' --last 1m --style compact` shows messages

## Execution approach

Work through the plan's 9 tasks in order. Tasks 1–2 are foundations (create the logger enums); tasks 3–6 are the instrumentation pass (independent of each other — do them sequentially); task 7 is the MetricKit subscriber; task 8 is the CLAUDE.md docs; task 9 is final verification.

For each task, check the boxes in the plan file as you complete steps if possible, but prioritize getting the code right over updating the plan doc.
