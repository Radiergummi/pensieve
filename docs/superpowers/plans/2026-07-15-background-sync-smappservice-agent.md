# Background Sync via a Bundled SMAppService Agent — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Retire the hand-installed `com.pensieve.sync` launchd LaunchAgent and replace it with a bundled, code-signed `SMAppService.agent` one-shot backed by a new thin `PensieveSyncAgent` helper target that runs the existing `SyncRunner`.

**Architecture:** A small in-bundle helper (`Contents/Library/Helpers/PensieveSyncAgent`) runs `SyncRunner.run()` on a launchd `StartInterval`, exiting between runs. A committed, **home-independent** LaunchAgent plist at `Contents/Library/LaunchAgents/me.mazetti.pensieve.sync.plist` schedules it; the helper resolves the machine-specific `PATH` and `sync.log` path at runtime (the plist cannot, since launchd does no `~` expansion). The app owns register/unregister/status via a thin `BackgroundSyncService`, gated to the installed app (never `.build` paths). Runs independently of the GUI → no force-quit gap.

**Tech Stack:** Swift 6, SwiftUI, ServiceManagement (`SMAppService`, macOS 13+), XcodeGen, SQLiteData/GRDB, Swift Testing.

## Global Constraints

- **Platform:** macOS 15 deployment target (`project.yml`). `Package.swift` stays `.macOS(.v14)` (all `SMAppService` code is app-/helper-target-only).
- **Signing:** ad-hoc (`CODE_SIGN_IDENTITY: "-"`, no paid Apple team). SMAppService login-items/agents do NOT need the paid-team entitlement (unlike App Groups/CloudKit), but registration is pinned to the app's on-disk **path + cdhash** → the app MUST be run from `/Applications/Pensieve.app`, not DerivedData.
- **Swift only. No Python, ever.**
- **Agent label:** `me.mazetti.pensieve.sync` (new; distinct from legacy `com.pensieve.sync` to avoid a launchd collision).
- **Trust gate untouched:** extraction stays on-device (`makeDefaultLLMProvider(defaults:)` resolves the on-device provider by default). This plan changes *where* sync runs, not *what* it does.
- **App target has NO unit tests** (`Sources/PensieveApp` is an Xcode target, not covered by `PensieveKitTests`). Keep derivation/guard logic in tested PensieveKit; verify app changes with `xcodebuild` build + a **non-blocking** smoke-launch of the inner binary.
- **German l10n is chrome-only** — reconcile `Localizable.xcstrings` keys by hand (xcodebuild does not auto-populate them).
- **SQLiteData predicates use `.eq(x)`, not `== x`.**
- **Kit build/test:** `./scripts/test.sh` (thin `swift test`). **App build:** `xcodegen generate && xcodebuild -project Pensieve.xcodeproj -scheme Pensieve -configuration Debug -derivedDataPath ./.build-xcode build`; app at `./.build-xcode/Build/Products/Debug/Pensieve.app`.

**Task 6 is a GATE.** Tasks 1–5 build the minimal bundled agent needed to run the spike. If the spike (Task 6) shows ad-hoc SMAppService registration cannot reach `.enabled`, STOP and reassess before Tasks 7–10.

---

### Task 1: Move `openSpool` / `openCanonical` into PensieveKit

The helper target links only PensieveKit, so the two store-opening helpers the sync path needs must live in the framework (they're currently free functions in the `pensieve` CLI module). `openCanonicalReadOnly` stays CLI-side (only `prime`/`mcp` use it).

**Files:**
- Create: `Sources/PensieveKit/Store/StoreOpen.swift`
- Modify: `Sources/pensieve/Pensieve.swift:22-38` (remove the two moved functions; keep `openCanonicalReadOnly`)
- Test: `Tests/PensieveKitTests/StoreOpenTests.swift`

**Interfaces:**
- Produces: `public func openSpool() throws -> CaptureSpool`, `public func openCanonical() throws -> any DatabaseWriter` (both in PensieveKit; honor `PENSIEVE_CAPTURE_DB` / `PENSIEVE_DB`).
- Consumes: existing Kit `CaptureSpool.init(at:)`, `openCanonicalDatabase(at:)`, `PensievePaths.captureURL()/canonicalURL()`.

- [ ] **Step 1: Write the failing test**

```swift
// Tests/PensieveKitTests/StoreOpenTests.swift
import Testing
import Foundation
import SQLiteData
@testable import PensieveKit

@Test func openSpoolHonorsCaptureDBOverride() throws {
  let tmp = FileManager.default.temporaryDirectory
    .appendingPathComponent("cap-\(UUID().uuidString).sqlite")
  setenv("PENSIEVE_CAPTURE_DB", tmp.path, 1)
  defer { unsetenv("PENSIEVE_CAPTURE_DB"); try? FileManager.default.removeItem(at: tmp) }
  let spool = try openSpool()
  #expect(FileManager.default.fileExists(atPath: tmp.path))
  _ = spool
}

@Test func openCanonicalHonorsDBOverride() throws {
  let tmp = FileManager.default.temporaryDirectory
    .appendingPathComponent("canon-\(UUID().uuidString).sqlite")
  setenv("PENSIEVE_DB", tmp.path, 1)
  defer { unsetenv("PENSIEVE_DB"); try? FileManager.default.removeItem(at: tmp) }
  _ = try openCanonical()
  #expect(FileManager.default.fileExists(atPath: tmp.path))
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `./scripts/test.sh --filter StoreOpenTests`
Expected: FAIL — `openSpool` / `openCanonical` not found in PensieveKit.

- [ ] **Step 3: Create the Kit file**

```swift
// Sources/PensieveKit/Store/StoreOpen.swift
import Foundation
import SQLiteData

/// Opens the spool at the standard location (override for tests via PENSIEVE_CAPTURE_DB).
public func openSpool() throws -> CaptureSpool {
  if let override = ProcessInfo.processInfo.environment["PENSIEVE_CAPTURE_DB"] {
    return try CaptureSpool(at: URL(fileURLWithPath: override))
  }
  return try CaptureSpool(at: PensievePaths.captureURL())
}

/// Opens the canonical store at the standard location (override for tests via PENSIEVE_DB).
public func openCanonical() throws -> any DatabaseWriter {
  if let override = ProcessInfo.processInfo.environment["PENSIEVE_DB"] {
    return try openCanonicalDatabase(at: URL(fileURLWithPath: override))
  }
  return try openCanonicalDatabase(at: PensievePaths.canonicalURL())
}
```

- [ ] **Step 4: Delete the two moved functions from the CLI**

In `Sources/pensieve/Pensieve.swift`, delete the `func openSpool()` and `func openCanonical()` definitions (lines 22–38). **Keep** `func openCanonicalReadOnly()`. The CLI files already `import PensieveKit`, so their `openSpool()` / `openCanonical()` calls now resolve to the Kit versions.

- [ ] **Step 5: Run the full suite + build the CLI**

Run: `./scripts/test.sh && swift build`
Expected: all tests PASS; CLI builds (no duplicate-symbol / missing-symbol errors).

- [ ] **Step 6: Commit**

```bash
git add Sources/PensieveKit/Store/StoreOpen.swift Sources/pensieve/Pensieve.swift Tests/PensieveKitTests/StoreOpenTests.swift
git commit -m "refactor(kit): move openSpool/openCanonical into PensieveKit for the sync helper"
```

---

### Task 2: `SyncAgentEnvironment.resolvedPATH` (the C1 guard)

launchd replaces (does not inherit) the login `PATH`; `SyncRunner` spawns `/usr/bin/env git` and `/usr/bin/env claude`. The helper must inject `PATH` at runtime. This pure builder carries the exact PATH the retired `LaunchAgentPlist` used, with a test that guards against dropping it.

**Files:**
- Create: `Sources/PensieveKit/Sync/SyncAgentEnvironment.swift`
- Test: `Tests/PensieveKitTests/SyncAgentEnvironmentTests.swift`

**Interfaces:**
- Produces: `public enum SyncAgentEnvironment { public static func resolvedPATH(home: URL) -> String }`

- [ ] **Step 1: Write the failing test** (mirrors the retired `LaunchAgentPlistTests` PATH asserts)

```swift
// Tests/PensieveKitTests/SyncAgentEnvironmentTests.swift
import Testing
import Foundation
@testable import PensieveKit

@Test func resolvedPATHCoversGitClaudeAndHasNoTilde() {
  let path = SyncAgentEnvironment.resolvedPATH(home: URL(fileURLWithPath: "/Users/tester"))
  #expect(!path.contains("~"))                        // launchd does not expand ~
  #expect(path.contains("/usr/bin"))                  // Git.run needs /usr/bin/env git
  #expect(path.contains("/bin"))
  #expect(path.contains("/Users/tester/.local/bin"))  // claude -p fallback
  #expect(path.contains("/opt/homebrew/bin"))         // Homebrew git/claude
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `./scripts/test.sh --filter SyncAgentEnvironmentTests`
Expected: FAIL — `SyncAgentEnvironment` not found.

- [ ] **Step 3: Implement**

```swift
// Sources/PensieveKit/Sync/SyncAgentEnvironment.swift
import Foundation

/// Runtime environment for the bundled sync agent. launchd REPLACES the job PATH (no login-PATH
/// inheritance), and a committed static plist cannot carry a home-relative PATH — so the helper
/// sets this at launch. `/usr/bin`+`/bin` are mandatory for `Git.run`'s `/usr/bin/env git`;
/// `~/.local/bin` (expanded) + `/opt/homebrew/bin` resolve `claude` for the extraction fallback.
public enum SyncAgentEnvironment {
  public static func resolvedPATH(home: URL) -> String {
    "\(home.path)/.local/bin:/opt/homebrew/bin:/usr/bin:/bin"
  }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `./scripts/test.sh --filter SyncAgentEnvironmentTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/PensieveKit/Sync/SyncAgentEnvironment.swift Tests/PensieveKitTests/SyncAgentEnvironmentTests.swift
git commit -m "feat(kit): SyncAgentEnvironment.resolvedPATH — the sync agent's runtime PATH"
```

---

### Task 3: The committed, home-independent LaunchAgent plist + parse test

The plist ships as a committed static file (viable only because it is home-independent). The parse test asserts the home-independent keys AND — as the C1/C2 regression guard — that it carries **no** `EnvironmentVariables` and **no** `StandardOutPath` (those are the helper's runtime job).

**Files:**
- Create: `SyncAgent/me.mazetti.pensieve.sync.plist` (repo root; outside any compile glob)
- Test: `Tests/PensieveKitTests/BackgroundSyncPlistTests.swift`

**Interfaces:** none (a static resource + a test that reads it).

- [ ] **Step 1: Create the plist file**

```xml
<!-- SyncAgent/me.mazetti.pensieve.sync.plist -->
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>me.mazetti.pensieve.sync</string>
  <key>BundleProgram</key>
  <string>Contents/Library/Helpers/PensieveSyncAgent</string>
  <key>StartInterval</key>
  <integer>300</integer>
  <key>ProcessType</key>
  <string>Background</string>
  <key>RunAtLoad</key>
  <true/>
</dict>
</plist>
```

- [ ] **Step 2: Write the failing test**

```swift
// Tests/PensieveKitTests/BackgroundSyncPlistTests.swift
import Testing
import Foundation

@Test func committedAgentPlistIsHomeIndependentAndComplete() throws {
  // Navigate from this test file up to the repo root: Tests/PensieveKitTests/<file> → repo root.
  let repoRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
  let plistURL = repoRoot.appendingPathComponent("SyncAgent/me.mazetti.pensieve.sync.plist")
  let obj = try PropertyListSerialization.propertyList(
    from: Data(contentsOf: plistURL), format: nil) as! [String: Any]

  #expect(obj["Label"] as? String == "me.mazetti.pensieve.sync")
  #expect(obj["BundleProgram"] as? String == "Contents/Library/Helpers/PensieveSyncAgent")
  #expect(obj["StartInterval"] as? Int == 300)
  #expect(obj["ProcessType"] as? String == "Background")
  #expect(obj["RunAtLoad"] as? Bool == true)

  // C1/C2 regression guard: env + logging are the helper's runtime job, NOT the static plist
  // (launchd does no ~ expansion, so a committed file cannot carry a home-relative PATH/log path).
  #expect(obj["EnvironmentVariables"] == nil)
  #expect(obj["StandardOutPath"] == nil)
  #expect(obj["StandardErrorPath"] == nil)
}
```

- [ ] **Step 3: Run test to verify it passes** (the file already exists from Step 1)

Run: `./scripts/test.sh --filter BackgroundSyncPlistTests`
Expected: PASS. (If it fails to find the file, confirm the `#filePath` → repo-root hop matches `Tests/PensieveKitTests/`.)

- [ ] **Step 4: Commit**

```bash
git add SyncAgent/me.mazetti.pensieve.sync.plist Tests/PensieveKitTests/BackgroundSyncPlistTests.swift
git commit -m "feat: committed home-independent LaunchAgent plist for the sync agent + guard test"
```

---

### Task 4: `PensieveSyncAgent` helper target + bundle embedding

A command-line-tool Xcode target whose `main` sets `PATH`, ensures the log dir, runs `SyncRunner`, and appends the summary line to `sync.log` (keeping `SystemStatus.lastSyncAt`'s mtime moving). Embedded + signed into the app bundle, with the plist copied to `Contents/Library/LaunchAgents`.

**Files:**
- Create: `Sources/PensieveSyncAgent/PensieveSyncAgent.swift`
- Modify: `project.yml` (new `PensieveSyncAgent` target; app-target embed + plist copy-files phase)

**Interfaces:**
- Consumes (from Tasks 1–2): `openSpool()`, `openCanonical()`, `SyncAgentEnvironment.resolvedPATH(home:)`, plus existing `SyncRunner`, `makeDefaultLLMProvider(defaults:)`, `PensieveDefaults.shared()`, `PensievePaths.{homeDirectory,logsDirectory,syncLogURL,claudeProjectsURL}()`.

- [ ] **Step 1: Write the helper entry point**

```swift
// Sources/PensieveSyncAgent/PensieveSyncAgent.swift
import Foundation
import PensieveKit

@main
enum PensieveSyncAgent {
  static func main() async {
    let home = PensievePaths.homeDirectory()
    // launchd replaces PATH; SyncRunner spawns `/usr/bin/env git` and `claude` which resolve from it.
    setenv("PATH", SyncAgentEnvironment.resolvedPATH(home: home), 1)
    // launchd will not create the log dir.
    try? FileManager.default.createDirectory(
      at: PensievePaths.logsDirectory(), withIntermediateDirectories: true)

    let line: String
    let now = Date().ISO8601Format()
    do {
      let s = try await SyncRunner(
        spool: try openSpool(),
        db: try openCanonical(),
        provider: makeDefaultLLMProvider(defaults: PensieveDefaults.shared()),
        projectsDir: PensievePaths.claudeProjectsURL()).run()
      line = "\(now) sync: ingested \(s.ingested) event(s), discovered \(s.discovered) session(s), extracted \(s.extracted) loose end(s)\n"
    } catch {
      line = "\(now) sync FAILED: \(error)\n"
    }
    appendToSyncLog(line)
  }

  /// Append the summary line to sync.log (creating it if absent). This is what keeps the log's
  /// mtime moving so `SystemStatus.lastSyncAt` stays honest without a plist `StandardOutPath`.
  private static func appendToSyncLog(_ line: String) {
    let url = PensievePaths.syncLogURL()
    let data = Data(line.utf8)
    if let handle = try? FileHandle(forWritingTo: url) {
      defer { try? handle.close() }
      _ = try? handle.seekToEnd()
      try? handle.write(contentsOf: data)
    } else {
      try? data.write(to: url)
    }
  }
}
```

- [ ] **Step 2: Add the helper target + embedding to `project.yml`**

Add a new target under `targets:`:

```yaml
  PensieveSyncAgent:
    type: tool
    platform: macOS
    sources:
      - Sources/PensieveSyncAgent
    dependencies:
      - package: PensieveKit
        product: PensieveKit
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: me.mazetti.pensieve.sync
        CODE_SIGN_IDENTITY: "-"
        CODE_SIGNING_ALLOWED: "YES"
        CODE_SIGNING_REQUIRED: "NO"
        SWIFT_VERSION: "6.0"
```

In the existing `Pensieve` app target, add the helper as an embedded, signed dependency and add the plist copy-files phase. Replace the app target's `dependencies:` and `sources:` blocks with:

```yaml
    sources:
      - Sources/PensieveApp
      - icons/Pensieve.icon
      - path: SyncAgent/me.mazetti.pensieve.sync.plist
        buildPhase:
          copyFiles:
            destination: wrapper
            subpath: Contents/Library/LaunchAgents
    dependencies:
      - package: PensieveKit
        product: PensieveKit
      - package: MarkdownUI
        product: MarkdownUI
      - sdk: MetricKit.framework
      - target: PensieveSyncAgent
        embed: true
        codeSign: true
        copy:
          destination: wrapper
          subpath: Contents/Library/Helpers
```

> NOTE: the exact XcodeGen keys for a copy-files destination (`wrapper` + `subpath`) and for embedding a `tool` dependency are verified in Step 4 by inspecting the built bundle. If `xcodegen generate` rejects a key, consult the XcodeGen docs for `Dependency.copy` / `TargetSource.buildPhase.copyFiles` and adjust; the REQUIRED outcome is: signed helper at `Contents/Library/Helpers/PensieveSyncAgent` and the plist at `Contents/Library/LaunchAgents/me.mazetti.pensieve.sync.plist`.

- [ ] **Step 3: Generate + build**

Run:
```bash
xcodegen generate && xcodebuild -project Pensieve.xcodeproj -scheme Pensieve -configuration Debug -derivedDataPath ./.build-xcode build
```
Expected: BUILD SUCCEEDED. (If a SwiftSyntax/macro linker error appears, `rm -rf .build` and retry.)

- [ ] **Step 4: Verify the bundle layout + signing**

Run:
```bash
find ./.build-xcode/Build/Products/Debug/Pensieve.app/Contents/Library
codesign -dv ./.build-xcode/Build/Products/Debug/Pensieve.app/Contents/Library/Helpers/PensieveSyncAgent 2>&1 | head
```
Expected: the `find` lists `Contents/Library/Helpers/PensieveSyncAgent` and `Contents/Library/LaunchAgents/me.mazetti.pensieve.sync.plist`; `codesign -dv` shows the helper is signed (ad-hoc). If either path is wrong, fix the `project.yml` copy phases and re-run Steps 3–4.

- [ ] **Step 5: Commit**

```bash
git add Sources/PensieveSyncAgent/PensieveSyncAgent.swift project.yml
git commit -m "feat: PensieveSyncAgent helper target embedded + signed in the app bundle"
```

---

### Task 5: `BackgroundSyncService` + `BackgroundSyncGuard` + launch wiring

The app-target wrapper over `SMAppService.agent(...)`, a pure Kit guard that blocks management from `.build` paths, and the `AppDelegate` launch wiring (legacy boot-out off the main thread + status-gated, guarded auto-register).

**Files:**
- Create: `Sources/PensieveKit/Sync/BackgroundSyncGuard.swift`
- Create: `Sources/PensieveApp/BackgroundSyncService.swift`
- Modify: `Sources/PensieveApp/AppDefaults.swift` (add `backgroundSyncEnabledKey` + default-true accessor)
- Modify: `Sources/PensieveApp/AppDelegate.swift:24-35` (call `configureBackgroundSync()`)
- Test: `Tests/PensieveKitTests/BackgroundSyncGuardTests.swift`

**Interfaces:**
- Produces (Kit): `public enum BackgroundSyncGuard { public static func shouldManage(bundlePath: String) -> Bool }`
- Produces (app): `enum BackgroundSyncService` with `plistName`, `agent`, `status`, `register()`, `unregister()`; `AppDefaults.backgroundSyncEnabledKey`, `AppDefaults.backgroundSyncEnabled`.

- [ ] **Step 1: Write the failing guard test**

```swift
// Tests/PensieveKitTests/BackgroundSyncGuardTests.swift
import Testing
@testable import PensieveKit

@Test func guardRefusesBuildPathsAndAllowsInstalled() {
  #expect(BackgroundSyncGuard.shouldManage(bundlePath: "/Applications/Pensieve.app") == true)
  #expect(BackgroundSyncGuard.shouldManage(
    bundlePath: "/Users/x/Projects/pensieve/.build-xcode/Build/Products/Debug/Pensieve.app") == false)
  #expect(BackgroundSyncGuard.shouldManage(bundlePath: "/repo/.build/debug/Pensieve.app") == false)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `./scripts/test.sh --filter BackgroundSyncGuardTests`
Expected: FAIL — `BackgroundSyncGuard` not found.

- [ ] **Step 3: Implement the guard**

```swift
// Sources/PensieveKit/Sync/BackgroundSyncGuard.swift
/// Refuse to register/boot the background agent when the app runs from a `.build` path (a throwaway
/// xcodebuild smoke-launch), which would otherwise pollute real Login Items and tear down the live
/// agent. Mirrors the retired DaemonInstaller.ensureStable "refuse from /.build/" rule.
public enum BackgroundSyncGuard {
  public static func shouldManage(bundlePath: String) -> Bool {
    !bundlePath.contains("/.build")
  }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `./scripts/test.sh --filter BackgroundSyncGuardTests`
Expected: PASS.

- [ ] **Step 5: Add the AppDefaults key**

In `Sources/PensieveApp/AppDefaults.swift`, add inside the `AppDefaults` enum (mirroring `narrationEnabled`):

```swift
  static let backgroundSyncEnabledKey = "app.backgroundSyncEnabled"

  /// Background sync is ON by default (preserving the always-syncing daemon behavior). Non-View
  /// readers (AppDelegate) must honor the same default as the Settings toggle.
  static var backgroundSyncEnabled: Bool {
    UserDefaults.standard.object(forKey: backgroundSyncEnabledKey) == nil
      ? true : UserDefaults.standard.bool(forKey: backgroundSyncEnabledKey)
  }
```

- [ ] **Step 6: Implement `BackgroundSyncService`**

```swift
// Sources/PensieveApp/BackgroundSyncService.swift
import ServiceManagement

/// Thin wrapper over the bundled SMAppService LaunchAgent. Smoke-verified by hand (SMAppService
/// mutates live system state); the scheduled logic (SyncRunner) is tested in PensieveKit. Uses the
/// app target's own `AppLog.app` logger — PensieveKit's `Log` enum is internal to the framework.
enum BackgroundSyncService {
  static let plistName = "me.mazetti.pensieve.sync.plist"
  static var agent: SMAppService { SMAppService.agent(plistName: plistName) }
  static var status: SMAppService.Status { agent.status }

  /// Status-gated register: only from `.notRegistered`, and never re-enable a user-disabled item.
  static func registerIfNeeded() {
    guard agent.status == .notRegistered else { return }
    do { try agent.register() }
    catch { AppLog.app.error("SMAppService register failed: \(error, privacy: .public)") }
  }

  static func unregister() {
    do { try agent.unregister() }
    catch { AppLog.app.error("SMAppService unregister failed: \(error, privacy: .public)") }
  }
}
```

- [ ] **Step 7: Wire launch behavior in `AppDelegate`**

In `Sources/PensieveApp/AppDelegate.swift`, add a call at the end of `applicationDidFinishLaunching` and the method:

```swift
  func applicationDidFinishLaunching(_ notification: Notification) {
    KeychainSecretStore.migrateFromLegacyService()
    DiagnosticsCollector.shared.start()
    applyDockVisibility()
    configureBackgroundSync()
  }

  /// Retire the legacy hand-installed agent, then (if enabled and safe) register the bundled one.
  /// Guarded off `.build` paths so a throwaway smoke-launch never touches real Login Items.
  private func configureBackgroundSync() {
    guard BackgroundSyncGuard.shouldManage(bundlePath: Bundle.main.bundlePath) else { return }
    // Legacy boot-out runs launchctl synchronously → keep it off the main thread.
    Task.detached {
      DaemonInstaller.unload(plistURL: PensievePaths.launchAgentURL(), uid: String(getuid()))
    }
    if AppDefaults.backgroundSyncEnabled {
      BackgroundSyncService.registerIfNeeded()
    }
  }
```

- [ ] **Step 8: Build + guarded smoke-launch (must NOT register)**

Run:
```bash
xcodegen generate && xcodebuild -project Pensieve.xcodeproj -scheme Pensieve -configuration Debug -derivedDataPath ./.build-xcode build
BIN=./.build-xcode/Build/Products/Debug/Pensieve.app/Contents/MacOS/Pensieve
PENSIEVE_DB=/tmp/pv-$$.sqlite PENSIEVE_CAPTURE_DB=/tmp/pc-$$.sqlite "$BIN" &
APP_PID=$!; sleep 4; kill $APP_PID 2>/dev/null
launchctl print gui/$(id -u)/me.mazetti.pensieve.sync 2>&1 | tail -1
```
Expected: BUILD SUCCEEDED; the app launches from the `.build-xcode` path, and the `launchctl print` reports the job is **not** found (the `.build` guard blocked registration). Also confirm the live legacy `com.pensieve.sync` is untouched by this run.

- [ ] **Step 9: Commit**

```bash
git add Sources/PensieveKit/Sync/BackgroundSyncGuard.swift Sources/PensieveApp/BackgroundSyncService.swift Sources/PensieveApp/AppDefaults.swift Sources/PensieveApp/AppDelegate.swift Tests/PensieveKitTests/BackgroundSyncGuardTests.swift
git commit -m "feat(app): BackgroundSyncService + guarded status-gated launch registration"
```

---

### Task 6: SPIKE / GATE — verify SMAppService under ad-hoc signing from `/Applications`

Manual verification. No code (unless a fix is needed). **Do not proceed to Task 7 until every check passes.** If registration cannot reach `.enabled`, STOP and report — the design must be reassessed.

- [ ] **Step 1: Install the built app to `/Applications`**

```bash
rm -rf /Applications/Pensieve.app
cp -R ./.build-xcode/Build/Products/Debug/Pensieve.app /Applications/
open /Applications/Pensieve.app
```

- [ ] **Step 2: Approve + confirm `.enabled`**

Approve "Pensieve" (or "PensieveSyncAgent") in System Settings ▸ General ▸ Login Items ▸ "Allow in the Background". Then:
```bash
launchctl print gui/$(id -u)/me.mazetti.pensieve.sync 2>&1 | grep -i "state\|program" | head
```
Expected: the job exists and its program path points into `/Applications/Pensieve.app/Contents/Library/Helpers/PensieveSyncAgent`. **CHECK (Risk 1): registration reached enabled under ad-hoc signing.**

- [ ] **Step 3: Confirm a real cycle extracts (Risk: PATH + on-device provider)**

Wait one interval (≤ ~5 min, tolerate power-throttle drift) or kickstart:
```bash
launchctl kickstart -k gui/$(id -u)/me.mazetti.pensieve.sync
sleep 20
tail -3 ~/Library/Logs/Pensieve/sync.log
```
Expected: a fresh ISO-timestamped summary line appears; on a machine without Foundation Models, `extracted N loose end(s)` with N reflecting real work (proves `PATH`/`claude` resolve). **CHECK (Risks C1 + 4).**

- [ ] **Step 4: Path-stability check (Risk 2)**

```bash
osascript -e 'quit app "Pensieve"'; sleep 2
rm -rf ./.build-xcode
sleep 320
tail -1 ~/Library/Logs/Pensieve/sync.log   # should still get a new cycle — job runs from /Applications, not DerivedData
```
Expected: the agent still fired after DerivedData was deleted (it runs from `/Applications`). **CHECK (Risk 2).**

- [ ] **Step 5: cdhash-churn check (Risk 1b)**

Rebuild, reinstall to `/Applications`, relaunch. Confirm whether the job survives / silently re-registers, or whether macOS forces re-approval on every rebuild:
```bash
xcodebuild -project Pensieve.xcodeproj -scheme Pensieve -configuration Debug -derivedDataPath ./.build-xcode build
rm -rf /Applications/Pensieve.app && cp -R ./.build-xcode/Build/Products/Debug/Pensieve.app /Applications/
open /Applications/Pensieve.app
launchctl print gui/$(id -u)/me.mazetti.pensieve.sync 2>&1 | grep -i state | head -1
```
Expected: document the outcome. If it forces re-approval every rebuild, note it as a dogfooding tax (acceptable; the release cadence is low) but not a blocker.

- [ ] **Step 6: Record the spike outcome**

Append a short "Spike outcome" note to the spec (`docs/superpowers/specs/2026-07-14-background-sync-smappservice-agent-design.md`) capturing the four check results, then commit:
```bash
git add docs/superpowers/specs/2026-07-14-background-sync-smappservice-agent-design.md
git commit -m "docs(spec): record SMAppService ad-hoc spike outcome"
```

---

### Task 7: Settings ▸ General "Background sync" section + l10n

Surface the toggle + live status + an "Open Login Items" affordance for the `.requiresApproval` case, so the user can enable/disable and see the approval state.

**Files:**
- Modify: `Sources/PensieveApp/Settings/GeneralSettingsTab.swift`
- Modify: `Sources/PensieveApp/Localizable.xcstrings` (add keys, EN + DE)

- [ ] **Step 1: Add the section to `GeneralSettingsTab`**

Replace the body of `GeneralSettingsTab` with (keeping the existing Hide-Dock section):

```swift
import SwiftUI
import AppKit
import ServiceManagement
import PensieveKit

struct GeneralSettingsTab: View {
  @AppStorage(AppDefaults.hideDockIconKey) private var hideDockIcon = false
  @AppStorage(AppDefaults.backgroundSyncEnabledKey) private var backgroundSyncEnabled = true
  @State private var syncStatus: SMAppService.Status = .notRegistered

  var body: some View {
    Form {
      Section {
        Toggle("Hide Dock icon (menu bar only)", isOn: $hideDockIcon)
          .onChange(of: hideDockIcon) { _, hidden in
            NSApp.setActivationPolicy(hidden ? .accessory : .regular)
            if !hidden { NSApp.activate(ignoringOtherApps: true) }
          }
      }

      Section("Background sync") {
        Toggle("Keep Pensieve synced in the background", isOn: $backgroundSyncEnabled)
          .onChange(of: backgroundSyncEnabled) { _, on in
            if on { BackgroundSyncService.registerIfNeeded() } else { BackgroundSyncService.unregister() }
            syncStatus = BackgroundSyncService.status
          }
        LabeledContent("Status") { Text(statusText) }
        if syncStatus == .requiresApproval {
          Button("Open Login Items Settings") { SMAppService.openSystemSettingsLoginItems() }
        }
      }
    }
    .formStyle(.grouped)
    .frame(width: 460)
    .onAppear { syncStatus = BackgroundSyncService.status }
  }

  private var statusText: LocalizedStringKey {
    switch syncStatus {
    case .enabled: return "Enabled"
    case .requiresApproval: return "Needs approval"
    case .notRegistered: return "Off"
    case .notFound: return "Not found"
    @unknown default: return "Off"
    }
  }
}
```

- [ ] **Step 2: Add the l10n keys by hand**

In `Sources/PensieveApp/Localizable.xcstrings`, add entries (EN base + `de`) for the new literals. German (impersonal/infinitive; "Pensieve" stays English):
- `"Background sync"` → `"Hintergrund-Synchronisierung"`
- `"Keep Pensieve synced in the background"` → `"Pensieve im Hintergrund synchronisieren"`
- `"Status"` → `"Status"`
- `"Enabled"` → `"Aktiviert"`
- `"Needs approval"` → `"Genehmigung erforderlich"`
- `"Off"` → `"Aus"`
- `"Not found"` → `"Nicht gefunden"`
- `"Open Login Items Settings"` → `"Anmeldeobjekte-Einstellungen öffnen"`

Follow the exact JSON shape of existing entries in the catalog (`localizations.en.stringUnit.value` / `localizations.de.stringUnit.value`, `state: "translated"`).

- [ ] **Step 3: Build + smoke-launch**

Run:
```bash
xcodegen generate && xcodebuild -project Pensieve.xcodeproj -scheme Pensieve -configuration Debug -derivedDataPath ./.build-xcode build
```
Expected: BUILD SUCCEEDED. Confirm `de.lproj/Localizable.strings` in the built bundle contains the new German values:
```bash
plutil -p ./.build-xcode/Build/Products/Debug/Pensieve.app/Contents/Resources/de.lproj/Localizable.strings | grep -i "Hintergrund\|Genehmigung"
```

- [ ] **Step 4: Commit**

```bash
git add Sources/PensieveApp/Settings/GeneralSettingsTab.swift Sources/PensieveApp/Localizable.xcstrings
git commit -m "feat(app): Settings Background sync section (toggle + status + login-items) + German"
```

---

### Task 8: Reconcile `SystemStatus` — the Advanced tab must not lie

`SystemStatusGatherer.gather` currently derives `daemonInstalled` from the existence of the legacy plist file — which this migration deletes. Repoint it to an injected boolean the app computes from `SMAppService`, keeping the gather kernel pure/testable.

**Files:**
- Modify: `Sources/PensieveKit/Query/SystemStatus.swift`
- Modify: `Sources/PensieveApp/Settings/AdvancedSettingsTab.swift:21-23,65-70`
- Modify: `Tests/PensieveKitTests/SystemStatusTests.swift` (find the existing test file; update the field + param)

**Interfaces:**
- Changes: `SystemStatus.daemonInstalled: Bool` → `SystemStatus.backgroundSyncEnabled: Bool`; `gather(...)` param `launchAgentURL: URL` → `backgroundSyncEnabled: Bool`.

- [ ] **Step 1: Update the failing test first**

Locate the existing `SystemStatusGatherer` test (grep `gather(` under `Tests/`). Replace the `launchAgentURL:` argument with `backgroundSyncEnabled: true` (or `false`) and assert `status.backgroundSyncEnabled == <that value>` instead of `daemonInstalled`. Example expected call:

```swift
let status = SystemStatusGatherer.gather(
  db: db, defaults: defaults, cloudConfig: nil, apiKey: nil,
  backgroundSyncEnabled: true, syncLogURL: tmpLog)
#expect(status.backgroundSyncEnabled == true)
```

- [ ] **Step 2: Run test to verify it fails**

Run: `./scripts/test.sh --filter SystemStatus`
Expected: FAIL — compile error (`daemonInstalled` / `launchAgentURL` gone).

- [ ] **Step 3: Update `SystemStatus.swift`**

- Rename the field `daemonInstalled` → `backgroundSyncEnabled` (property + `init` param + assignment).
- In `gather(...)`: remove the `launchAgentURL: URL` parameter and the `FileManager.default.fileExists(...)` line; add a `backgroundSyncEnabled: Bool` parameter and pass it straight through to the result.
- Update the doc comment on the field to "The SMAppService background agent is registered + enabled."

- [ ] **Step 4: Update `AdvancedSettingsTab.swift`**

- Change the row (line ~21) to:
```swift
        LabeledContent("Background sync") {
          Text(status?.backgroundSyncEnabled == true ? "Enabled" : "Off")
        }
```
- In `load()` (line ~65), replace the `launchAgentURL:` argument with the live SMAppService status:
```swift
    status = SystemStatusGatherer.gather(db: model.db,
                                         defaults: .standard,
                                         cloudConfig: config,
                                         apiKey: key,
                                         backgroundSyncEnabled: BackgroundSyncService.status == .enabled,
                                         syncLogURL: PensievePaths.syncLogURL())
```
- Add `import ServiceManagement` (for the `.enabled` comparison via `BackgroundSyncService`).
- Add the two l10n keys `"Background sync"` (reuse from Task 7) and `"Enabled"`/`"Off"` (already added in Task 7) — no new German needed if Task 7 ran first; otherwise add them.

- [ ] **Step 5: Run Kit tests + build the app**

Run:
```bash
./scripts/test.sh --filter SystemStatus
xcodegen generate && xcodebuild -project Pensieve.xcodeproj -scheme Pensieve -configuration Debug -derivedDataPath ./.build-xcode build
```
Expected: test PASS; BUILD SUCCEEDED.

- [ ] **Step 6: Commit**

```bash
git add Sources/PensieveKit/Query/SystemStatus.swift Sources/PensieveApp/Settings/AdvancedSettingsTab.swift Tests/PensieveKitTests/SystemStatusTests.swift
git commit -m "refactor: Advanced tab reports SMAppService background-sync status, not the deleted legacy plist"
```

---

### Task 9: Remove `install-daemon` + dead daemon machinery

Delete the now-obsolete runtime plist-writing path and its tests; keep `DaemonInstaller.unload` (legacy cleanup) and `PensievePaths.launchAgentURL()` (its argument).

**Files:**
- Delete: `Sources/pensieve/Commands/InstallDaemon.swift`, `Sources/PensieveKit/Daemon/LaunchAgentPlist.swift`, `Tests/PensieveKitTests/DaemonInstallerTests.swift`, `Tests/PensieveKitTests/LaunchAgentPlistTests.swift`
- Modify: `Sources/pensieve/Pensieve.swift` (drop `InstallDaemon.self` from `subcommands`), `Sources/PensieveKit/Daemon/DaemonInstaller.swift` (keep only `unload` + its private `launchctl`)

- [ ] **Step 1: Trim `DaemonInstaller.swift`**

Reduce the file to only what legacy cleanup needs:

```swift
// Sources/PensieveKit/Daemon/DaemonInstaller.swift
import Foundation

/// Boots out + removes the LEGACY hand-installed `com.pensieve.sync` LaunchAgent. Retained after the
/// SMAppService migration purely to retire the old agent on first launch of the new app.
public enum DaemonInstaller {
  public static func unload(plistURL: URL, uid: String) {
    _ = launchctl(["bootout", "gui/\(uid)", plistURL.path])
    try? FileManager.default.removeItem(at: plistURL)
  }

  @discardableResult
  private static func launchctl(_ args: [String]) -> Int32 {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
    p.arguments = args
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { return -1 }
    p.waitUntilExit()
    return p.terminationStatus
  }
}
```

- [ ] **Step 2: Delete the obsolete files**

```bash
git rm Sources/pensieve/Commands/InstallDaemon.swift \
       Sources/PensieveKit/Daemon/LaunchAgentPlist.swift \
       Tests/PensieveKitTests/DaemonInstallerTests.swift \
       Tests/PensieveKitTests/LaunchAgentPlistTests.swift
```

- [ ] **Step 3: Drop the subcommand**

In `Sources/pensieve/Pensieve.swift`, remove `InstallDaemon.self,` from the `subcommands:` array.

- [ ] **Step 4: Full build + test**

Run: `./scripts/test.sh && swift build`
Expected: all tests PASS; CLI builds with no reference to the removed symbols. Then confirm the app still builds:
```bash
xcodegen generate && xcodebuild -project Pensieve.xcodeproj -scheme Pensieve -configuration Debug -derivedDataPath ./.build-xcode build
```
Expected: BUILD SUCCEEDED.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "chore: remove install-daemon + LaunchAgentPlist; keep DaemonInstaller.unload for legacy cleanup"
```

---

### Task 10: Docs — CLAUDE.md + observability runbook

Reflect that the app owns the agent, `install-daemon` is gone, the app installs to `/Applications`, and the first-launch approval step is mandatory.

**Files:**
- Modify: `CLAUDE.md` (the Dogfooding + Sync-daemon bullets)
- Modify: `docs/observability.md` (sync-log note, if it references `install-daemon`)

- [ ] **Step 1: Update `CLAUDE.md`**

- In the **Sync daemon** and **Dogfooding** bullets, replace the `install-daemon` / `com.pensieve.sync` LaunchAgent description with: the app registers a bundled `SMAppService.agent` (`me.mazetti.pensieve.sync`) from `/Applications/Pensieve.app`; it boots out the legacy `com.pensieve.sync` on first launch; approve it in System Settings ▸ Login Items; `sync.log` is written by the helper.
- Add a one-line **gotcha**: SMAppService pins registration to path+cdhash — run the app from `/Applications`, not `.build-xcode`; a rebuild may re-prompt for Login-Items approval.

- [ ] **Step 2: Update `docs/observability.md`**

If it mentions `install-daemon` or the LaunchAgent, update to the SMAppService agent + note the helper writes `sync.log` itself.

- [ ] **Step 3: Commit**

```bash
git add CLAUDE.md docs/observability.md
git commit -m "docs: SMAppService background agent replaces the install-daemon LaunchAgent"
```

---

## Post-merge runbook (human, after the branch merges)

1. Rebuild + reinstall the release CLI to `~/.local/bin/pensieve` (loses `install-daemon`): `swift build -c release && cp .build/release/pensieve ~/.local/bin/pensieve`.
2. Build the app and **install to `/Applications`**: `xcodegen generate && xcodebuild … build && rm -rf /Applications/Pensieve.app && cp -R ./.build-xcode/Build/Products/Debug/Pensieve.app /Applications/`.
3. `open /Applications/Pensieve.app` → confirm legacy `com.pensieve.sync` is gone (`launchctl print gui/$(id -u)/com.pensieve.sync` → not found).
4. Approve "Pensieve" in System Settings ▸ General ▸ Login Items → Settings ▸ General ▸ Background sync shows **Enabled**.
5. Confirm `~/Library/Logs/Pensieve/sync.log` gets fresh timestamped cycles and loose-end counts climb.
