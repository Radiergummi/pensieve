# Bundle the `pensieve` CLI into the App — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Retire the hand-copied `~/.local/bin/pensieve` binary; ship the CLI *inside* `Pensieve.app` as an Xcode `tool` target, and bridge external callers (git hooks, Claude Code hooks, `claude mcp add`) with a version-coherent symlink the app manages via a tested `CLIToolInstaller` kernel.

**Architecture:** `Sources/pensieve/` stops being a SwiftPM product and becomes an Xcode `tool` target embedded + signed at `Pensieve.app/Contents/Helpers/pensieve` (sibling of the existing `PensieveSyncAgent`). A pure PensieveKit kernel (`CLIToolInstaller`) decides what to do with `~/.local/bin/pensieve` given its current filesystem state (create / upToDate / repoint / blockedRealFile); the app auto-creates the symlink on launch when the path is empty and offers install/repair/replace in Settings. PensieveKit + its tests stay SwiftPM (fast `swift test` loop unchanged).

**Tech Stack:** Swift 6, SwiftUI, ServiceManagement (reused guard), XcodeGen, SQLiteData/GRDB, ArgumentParser, MCP SDK, Swift Testing.

## Global Constraints

- **Platform:** macOS 15 deployment target (`project.yml`). `Package.swift` stays `.macOS(.v14)` (all app/CLI-embedding logic is Xcode-target-only; the `CLIToolInstaller` kernel is plain Foundation).
- **Signing:** ad-hoc (`CODE_SIGN_IDENTITY: "-"`, no paid Apple team) — matches `PensieveSyncAgent`.
- **CLI bundle location:** `Contents/Helpers/pensieve` (conventional bundled-CLI spot; deliberately distinct from `PensieveSyncAgent`'s `Contents/Library/Helpers/`, a launchd helper).
- **CLI target identity:** explicit `PRODUCT_BUNDLE_IDENTIFIER: me.mazetti.pensieve.cli` (without it XcodeGen defaults to `me.mazetti.pensieve`, colliding with the app).
- **SPM package pins (mirror `Package.swift` verbatim when moved to `project.yml`):** `sqlite-data` `from: "1.6.0"`, `swift-argument-parser` `from: "1.5.0"`, `swift-sdk` `exactVersion: "0.12.1"`.
- **The symlink is the durable indirection.** Newly-written hook configs must reference `PensievePaths.installedBinaryURL()` (`~/.local/bin/pensieve`), never the resolved bundle path.
- **Launch auto-applies `.create` ONLY.** `.repoint` / `.blockedRealFile` are Settings-only actions — never silently resolved at launch (no clobbering a real file, no hijacking a deliberate foreign symlink).
- **Guard reuse:** management is gated by the existing `BackgroundSyncGuard.shouldManage(bundlePath:)` (refuse from `/.build` paths). No new guard type.
- **German l10n is chrome-only** — reconcile `Localizable.xcstrings` keys by hand (xcodebuild does not auto-populate them). "pensieve"/"Pensieve" stay English.
- **SQLiteData predicates use `.eq(x)`, not `== x`.**
- **Kit build/test:** `./scripts/test.sh` (thin `swift test`) + `swift build`. **App build:** `xcodegen generate && xcodebuild -project Pensieve.xcodeproj -scheme Pensieve -configuration Debug -derivedDataPath ./.build-xcode build`; app at `./.build-xcode/Build/Products/Debug/Pensieve.app`. After an xcodebuild, discard the transient `Package.resolved` churn (`git checkout Package.resolved`).
- **App target has NO unit tests** — verify app changes with an `xcodebuild` build + a **non-blocking** smoke-launch of the inner binary (`…/Contents/MacOS/Pensieve`, background + `kill`; forward throwaway `PENSIEVE_DB`/`PENSIEVE_CAPTURE_DB`).

**Task 3 is the structural pivot** (CLI leaves SwiftPM, joins Xcode). Tasks 1–2 are pure SwiftPM changes that stay green under `swift build`/`swift test` before the pivot. Tasks 4–6 build on the bundled binary produced by Task 3.

---

### Task 1: `CLIToolInstaller` — the tested symlink kernel

The pure decision + mutation logic for the `~/.local/bin/pensieve` symlink. No app types, plain Foundation, fully unit-tested against a temp dir. This is the trust-sensitive core; the app stays thin over it.

**Files:**
- Create: `Sources/PensieveKit/Support/CLIToolInstaller.swift`
- Test: `Tests/PensieveKitTests/CLIToolInstallerTests.swift`

**Interfaces:**
- Produces:
  - `public enum CLIToolInstaller.Plan: Equatable { case create, upToDate, repoint, blockedRealFile }`
  - `public static func bundledCLIURL(appBundleURL: URL) -> URL`
  - `public static func plan(linkPath: URL, desiredTarget: URL, fileManager: FileManager = .default) -> Plan`
  - `public static func apply(_ plan: Plan, linkPath: URL, desiredTarget: URL, fileManager: FileManager = .default) throws`
  - `public static func replace(linkPath: URL, desiredTarget: URL, fileManager: FileManager = .default) throws`
- Consumes: nothing (Foundation only). Callers pair it with `PensievePaths.installedBinaryURL()` (existing) as `linkPath`.

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/PensieveKitTests/CLIToolInstallerTests.swift
import Testing
import Foundation
@testable import PensieveKit

private func tmpDir() -> URL {
  let d = FileManager.default.temporaryDirectory.appendingPathComponent("cli-\(UUID().uuidString)")
  try! FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
  return d
}

@Test func bundledCLIURLAppendsContentsHelpers() {
  let u = CLIToolInstaller.bundledCLIURL(appBundleURL: URL(fileURLWithPath: "/Applications/Pensieve.app"))
  #expect(u.path == "/Applications/Pensieve.app/Contents/Helpers/pensieve")
}

@Test func planIsCreateWhenAbsent() {
  let dir = tmpDir(); defer { try? FileManager.default.removeItem(at: dir) }
  let link = dir.appendingPathComponent("pensieve")
  #expect(CLIToolInstaller.plan(linkPath: link, desiredTarget: URL(fileURLWithPath: "/t")) == .create)
}

@Test func planIsUpToDateWhenSymlinkPointsAtTarget() throws {
  let dir = tmpDir(); defer { try? FileManager.default.removeItem(at: dir) }
  let link = dir.appendingPathComponent("pensieve")
  let target = URL(fileURLWithPath: "/Applications/Pensieve.app/Contents/Helpers/pensieve")
  try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
  #expect(CLIToolInstaller.plan(linkPath: link, desiredTarget: target) == .upToDate)
}

@Test func planIsRepointWhenSymlinkPointsElsewhere() throws {
  let dir = tmpDir(); defer { try? FileManager.default.removeItem(at: dir) }
  let link = dir.appendingPathComponent("pensieve")
  try FileManager.default.createSymbolicLink(at: link, withDestinationURL: URL(fileURLWithPath: "/some/other/pensieve"))
  let target = URL(fileURLWithPath: "/Applications/Pensieve.app/Contents/Helpers/pensieve")
  #expect(CLIToolInstaller.plan(linkPath: link, desiredTarget: target) == .repoint)
}

@Test func planIsBlockedWhenRealFilePresent() throws {
  let dir = tmpDir(); defer { try? FileManager.default.removeItem(at: dir) }
  let link = dir.appendingPathComponent("pensieve")
  try Data("binary".utf8).write(to: link)
  #expect(CLIToolInstaller.plan(linkPath: link, desiredTarget: URL(fileURLWithPath: "/t")) == .blockedRealFile)
}

@Test func applyCreateMakesSymlinkAndParentDir() throws {
  let dir = tmpDir(); defer { try? FileManager.default.removeItem(at: dir) }
  let link = dir.appendingPathComponent("nested/bin/pensieve")  // parent dirs don't exist yet
  let target = dir.appendingPathComponent("Contents/Helpers/pensieve")
  try CLIToolInstaller.apply(.create, linkPath: link, desiredTarget: target)
  #expect((try FileManager.default.destinationOfSymbolicLink(atPath: link.path)) == target.path)
}

@Test func applyRepointReplacesStaleSymlink() throws {
  let dir = tmpDir(); defer { try? FileManager.default.removeItem(at: dir) }
  let link = dir.appendingPathComponent("pensieve")
  try FileManager.default.createSymbolicLink(at: link, withDestinationURL: URL(fileURLWithPath: "/old"))
  let target = URL(fileURLWithPath: "/new/pensieve")
  try CLIToolInstaller.apply(.repoint, linkPath: link, desiredTarget: target)
  #expect((try FileManager.default.destinationOfSymbolicLink(atPath: link.path)) == target.path)
}

@Test func applyIsNoOpForBlockedRealFile() throws {
  let dir = tmpDir(); defer { try? FileManager.default.removeItem(at: dir) }
  let link = dir.appendingPathComponent("pensieve")
  try Data("binary".utf8).write(to: link)
  try CLIToolInstaller.apply(.blockedRealFile, linkPath: link, desiredTarget: URL(fileURLWithPath: "/t"))
  // still a regular file, untouched
  let attrs = try FileManager.default.attributesOfItem(atPath: link.path)
  #expect((attrs[.type] as? FileAttributeType) == .typeRegular)
}

@Test func replaceSwapsRealFileForSymlink() throws {
  let dir = tmpDir(); defer { try? FileManager.default.removeItem(at: dir) }
  let link = dir.appendingPathComponent("pensieve")
  try Data("binary".utf8).write(to: link)
  let target = URL(fileURLWithPath: "/new/pensieve")
  try CLIToolInstaller.replace(linkPath: link, desiredTarget: target)
  #expect((try FileManager.default.destinationOfSymbolicLink(atPath: link.path)) == target.path)
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `./scripts/test.sh --filter CLIToolInstaller`
Expected: FAIL — `CLIToolInstaller` not found.

- [ ] **Step 3: Implement the kernel**

```swift
// Sources/PensieveKit/Support/CLIToolInstaller.swift
import Foundation

/// Decides and applies the state of the `~/.local/bin/pensieve` symlink that bridges external callers
/// (git hooks, Claude Code hooks, `claude mcp add`) to the CLI bundled inside `Pensieve.app`. Pure
/// Foundation, no app types — the app is a thin caller. Uses `lstat`-style `attributesOfItem` (which
/// does NOT follow symlinks) so a symlink, a broken symlink, and a real file are told apart correctly.
public enum CLIToolInstaller {
  public enum Plan: Equatable {
    case create            // nothing at linkPath → make the symlink
    case upToDate          // already our symlink, correct target → no-op
    case repoint           // a symlink pointing elsewhere → (Settings-only) replace it
    case blockedRealFile   // a regular file / dir lives there → (Settings-only) explicit replace
  }

  /// The bundled CLI's on-disk location for a given `.app` bundle URL.
  public static func bundledCLIURL(appBundleURL: URL) -> URL {
    appBundleURL.appendingPathComponent("Contents/Helpers/pensieve")
  }

  /// Inspect the current filesystem state at `linkPath` and decide the action needed to make it point
  /// at `desiredTarget`. Mutates nothing.
  public static func plan(linkPath: URL, desiredTarget: URL, fileManager: FileManager = .default) -> Plan {
    guard let attrs = try? fileManager.attributesOfItem(atPath: linkPath.path) else {
      return .create   // lstat failed → nothing there
    }
    guard (attrs[.type] as? FileAttributeType) == .typeSymbolicLink else {
      return .blockedRealFile   // a real file/dir — never clobber implicitly
    }
    let stored = (try? fileManager.destinationOfSymbolicLink(atPath: linkPath.path)) ?? ""
    let resolved = stored.hasPrefix("/")
      ? stored
      : linkPath.deletingLastPathComponent().appendingPathComponent(stored).path
    return resolved == desiredTarget.path ? .upToDate : .repoint
  }

  /// Apply the SAFE plans: `.create` / `.repoint` create (or replace a stale symlink with) the link,
  /// creating `~/.local/bin` if needed. `.upToDate` / `.blockedRealFile` are no-ops (callers gate).
  public static func apply(_ plan: Plan, linkPath: URL, desiredTarget: URL, fileManager: FileManager = .default) throws {
    switch plan {
    case .create, .repoint:
      try fileManager.createDirectory(
        at: linkPath.deletingLastPathComponent(), withIntermediateDirectories: true)
      if fileManager.fileExists(atPath: linkPath.path) || (try? fileManager.attributesOfItem(atPath: linkPath.path)) != nil {
        try? fileManager.removeItem(at: linkPath)   // remove a stale symlink (never its target)
      }
      try fileManager.createSymbolicLink(at: linkPath, withDestinationURL: desiredTarget)
    case .upToDate, .blockedRealFile:
      return
    }
  }

  /// Explicit + destructive: remove WHATEVER is at `linkPath` (incl. a real file) and create the
  /// symlink. Only called from the Settings "Replace existing binary" confirmation — never at launch.
  public static func replace(linkPath: URL, desiredTarget: URL, fileManager: FileManager = .default) throws {
    try fileManager.createDirectory(
      at: linkPath.deletingLastPathComponent(), withIntermediateDirectories: true)
    if (try? fileManager.attributesOfItem(atPath: linkPath.path)) != nil {
      try fileManager.removeItem(at: linkPath)
    }
    try fileManager.createSymbolicLink(at: linkPath, withDestinationURL: desiredTarget)
  }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `./scripts/test.sh --filter CLIToolInstaller`
Expected: PASS (all 9 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/PensieveKit/Support/CLIToolInstaller.swift Tests/PensieveKitTests/CLIToolInstallerTests.swift
git commit -m "feat(kit): CLIToolInstaller — tested symlink kernel for the bundled CLI"
```

---

### Task 2: Point the hook-install commands at the symlink path

`InstallHooks`, `InstallSessionHook`, and `Scan` bake `Bundle.main.executablePath` into the generated git/Claude-Code hook configs. Run *through* the symlink, that resolves to the in-bundle path, so a fresh `install-*` after migration would hard-code `/Applications/Pensieve.app/…` and lose the indirection. Point all three at `PensievePaths.installedBinaryURL()` (`~/.local/bin/pensieve`), which already exists. This is a pure CLI change — still builds under `swift build` (the CLI is still a SwiftPM target until Task 3).

**Files:**
- Modify: `Sources/pensieve/Commands/InstallHooks.swift:11`
- Modify: `Sources/pensieve/Commands/InstallSessionHook.swift:10`
- Modify: `Sources/pensieve/Commands/Scan.swift:15`

**Interfaces:**
- Consumes: existing `PensievePaths.installedBinaryURL() -> URL` (returns `~/.local/bin/pensieve`).

- [ ] **Step 1: Update `InstallHooks.swift`**

Replace line 11:
```swift
    let pensievePath = Bundle.main.executablePath ?? "pensieve"
```
with:
```swift
    let pensievePath = PensievePaths.installedBinaryURL().path
```

- [ ] **Step 2: Update `InstallSessionHook.swift`**

Replace line 10 (identical replacement):
```swift
    let pensievePath = PensievePaths.installedBinaryURL().path
```

- [ ] **Step 3: Update `Scan.swift`**

Replace line 15 (identical replacement):
```swift
    let pensievePath = PensievePaths.installedBinaryURL().path
```

- [ ] **Step 4: Build to verify it compiles**

Run: `swift build`
Expected: BUILD SUCCEEDED (all three files already `import PensieveKit`, so `PensievePaths` resolves).

- [ ] **Step 5: Commit**

```bash
git add Sources/pensieve/Commands/InstallHooks.swift Sources/pensieve/Commands/InstallSessionHook.swift Sources/pensieve/Commands/Scan.swift
git commit -m "fix(cli): hook installers write the ~/.local/bin/pensieve symlink path, not the resolved binary"
```

---

### Task 3: Move the CLI from SwiftPM to an Xcode `tool` target

Remove the `pensieve` SwiftPM executable (product + target + its CLI-only deps) and add it as an Xcode `tool` target embedded + signed into the app bundle at `Contents/Helpers/pensieve`. PensieveKit + tests stay SwiftPM.

**Files:**
- Modify: `Package.swift` (remove executable product + target; drop `swift-argument-parser` + `swift-sdk` deps; keep `sqlite-data` — PensieveKit uses it)
- Modify: `project.yml` (add 3 packages; add `pensieve` tool target with scheme + bundle id; embed it into the app target)

**Interfaces:**
- Consumes: existing `Sources/pensieve/**` sources unchanged (they already call Kit's `openSpool`/`openCanonical`; `openCanonicalReadOnly` stays CLI-side; CLI directly imports `ArgumentParser`, `MCP`, `SQLiteData`).

- [ ] **Step 1: Edit `Package.swift`**

Replace the whole file with (removes the executable product, the `pensieve` target, and the two CLI-only deps):

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "Pensieve",
  platforms: [.macOS(.v14)],
  products: [
    .library(name: "PensieveKit", targets: ["PensieveKit"]),
  ],
  dependencies: [
    .package(url: "https://github.com/pointfreeco/sqlite-data", from: "1.6.0"),
  ],
  targets: [
    .target(
      name: "PensieveKit",
      dependencies: [.product(name: "SQLiteData", package: "sqlite-data")]
    ),
    .testTarget(
      name: "PensieveKitTests",
      dependencies: ["PensieveKit"],
      resources: [.copy("Fixtures")]
    ),
  ]
)
```

- [ ] **Step 2: Verify Kit still builds + tests pass without the CLI product**

Run: `swift build && ./scripts/test.sh`
Expected: BUILD SUCCEEDED; all tests PASS (the test target imports only PensieveKit — no CLI reference). `swift build` now builds only the library. (`swift run pensieve` no longer exists — expected.)

- [ ] **Step 3: Add the 3 packages to `project.yml`**

In `project.yml`, under the top-level `packages:` map (after `MarkdownUI`), add:

```yaml
  sqlite-data:
    url: https://github.com/pointfreeco/sqlite-data
    from: "1.6.0"
  swift-argument-parser:
    url: https://github.com/apple/swift-argument-parser
    from: "1.5.0"
  swift-sdk:
    url: https://github.com/modelcontextprotocol/swift-sdk
    exactVersion: "0.12.1"
```

- [ ] **Step 4: Add the `pensieve` tool target to `project.yml`**

Under `targets:` (after the `PensieveSyncAgent` target), add:

```yaml
  pensieve:
    type: tool
    platform: macOS
    sources:
      - Sources/pensieve
    dependencies:
      - package: PensieveKit
        product: PensieveKit
      - package: sqlite-data
        product: SQLiteData
      - package: swift-argument-parser
        product: ArgumentParser
      - package: swift-sdk
        product: MCP
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: me.mazetti.pensieve.cli
        CODE_SIGN_IDENTITY: "-"
        CODE_SIGNING_ALLOWED: "YES"
        CODE_SIGNING_REQUIRED: "NO"
        SWIFT_VERSION: "6.0"
    scheme: {}
```

- [ ] **Step 5: Embed the CLI into the app target**

In `project.yml`, in the `Pensieve` app target's `dependencies:` list (after the `PensieveSyncAgent` entry), add:

```yaml
      - target: pensieve
        embed: true
        codeSign: true
        copy:
          destination: wrapper
          subpath: Contents/Helpers
```

- [ ] **Step 6: Generate + build the app**

Run:
```bash
xcodegen generate && xcodebuild -project Pensieve.xcodeproj -scheme Pensieve -configuration Debug -derivedDataPath ./.build-xcode build
```
Expected: BUILD SUCCEEDED. (If a SwiftSyntax/macro linker error appears, `rm -rf .build` and retry. If SPM diamond resolution complains about `sqlite-data` appearing both transitively via the local PensieveKit package and as a top-level package, confirm both resolve to 1.6.x — they pin identically.)

- [ ] **Step 7: Verify the bundled CLI location + signing + standalone scheme**

Run:
```bash
find ./.build-xcode/Build/Products/Debug/Pensieve.app/Contents/Helpers
codesign -dv ./.build-xcode/Build/Products/Debug/Pensieve.app/Contents/Helpers/pensieve 2>&1 | head -4
ls Pensieve.xcodeproj/xcshareddata/xcschemes/
```
Expected: `find` lists `Contents/Helpers/pensieve`; `codesign -dv` shows it signed (`adhoc`); the scheme list contains `pensieve.xcscheme`. If `pensieve.xcscheme` is absent (empty `scheme: {}` didn't emit one), the CLI is still built + embedded via the app scheme — document that `xcodebuild -scheme Pensieve build` is the build path and drop the standalone-`-scheme pensieve` claim in Task 6 docs. Discard the transient `Package.resolved` churn afterward: `git checkout Package.resolved`.

- [ ] **Step 8: Commit**

```bash
git add Package.swift project.yml
git commit -m "refactor: build the pensieve CLI as an embedded Xcode tool target; drop the SwiftPM executable"
```

---

### Task 4: Auto-install the symlink on launch (guarded, `.create` only)

Wire `AppDelegate` to create the `~/.local/bin/pensieve` symlink when the path is empty, guarded to the installed app. `.repoint`/`.blockedRealFile` are left for Settings.

**Files:**
- Modify: `Sources/PensieveApp/AppDelegate.swift:24-42` (add `configureCommandLineTool()` + call)

**Interfaces:**
- Consumes: `CLIToolInstaller.{plan,apply,bundledCLIURL}`, `PensievePaths.installedBinaryURL()`, `BackgroundSyncGuard.shouldManage(bundlePath:)` (all existing/from Task 1).

- [ ] **Step 1: Add the launch call + method**

In `applicationDidFinishLaunching`, add a final call:
```swift
  func applicationDidFinishLaunching(_ notification: Notification) {
    KeychainSecretStore.migrateFromLegacyService()
    DiagnosticsCollector.shared.start()
    applyDockVisibility()
    configureBackgroundSync()
    configureCommandLineTool()
  }
```
Then add the method (below `configureBackgroundSync()`):
```swift
  /// Create the ~/.local/bin/pensieve → in-bundle-CLI symlink when the path is simply empty. Guarded
  /// off `.build` paths (a throwaway smoke-launch must never write ~/.local/bin). Only `.create` is
  /// auto-applied; `.repoint` (a symlink elsewhere — possibly a deliberate dev link) and
  /// `.blockedRealFile` (the legacy hand-copied binary) are surfaced in Settings, never resolved here.
  private func configureCommandLineTool() {
    guard BackgroundSyncGuard.shouldManage(bundlePath: Bundle.main.bundlePath) else { return }
    let link = PensievePaths.installedBinaryURL()
    let target = CLIToolInstaller.bundledCLIURL(appBundleURL: Bundle.main.bundleURL)
    if CLIToolInstaller.plan(linkPath: link, desiredTarget: target) == .create {
      try? CLIToolInstaller.apply(.create, linkPath: link, desiredTarget: target)
    }
  }
```

- [ ] **Step 2: Build + guarded smoke-launch (must NOT write ~/.local/bin from `.build`)**

Run:
```bash
xcodegen generate && xcodebuild -project Pensieve.xcodeproj -scheme Pensieve -configuration Debug -derivedDataPath ./.build-xcode build
git checkout Package.resolved
BIN=./.build-xcode/Build/Products/Debug/Pensieve.app/Contents/MacOS/Pensieve
ls -l ~/.local/bin/pensieve   # note current state BEFORE
PENSIEVE_DB=/tmp/pv-$$.sqlite PENSIEVE_CAPTURE_DB=/tmp/pc-$$.sqlite "$BIN" &
APP_PID=$!; sleep 4; kill $APP_PID 2>/dev/null
ls -l ~/.local/bin/pensieve   # must be UNCHANGED (guard blocked the write from a .build path)
```
Expected: BUILD SUCCEEDED; `~/.local/bin/pensieve` is identical before/after (the `.build-xcode` path contains `/.build`, so `BackgroundSyncGuard.shouldManage` returns false and no write happens). On this machine it stays the legacy 27 MB regular file.

- [ ] **Step 3: Commit**

```bash
git add Sources/PensieveApp/AppDelegate.swift
git commit -m "feat(app): auto-create the ~/.local/bin/pensieve symlink on launch (guarded, .create only)"
```

---

### Task 5: Settings ▸ General "Command-line tool" section + German l10n

Surface status + install/repair/replace so the user can install the symlink or migrate the legacy binary.

**Files:**
- Modify: `Sources/PensieveApp/Settings/GeneralSettingsTab.swift`
- Modify: `Sources/PensieveApp/Localizable.xcstrings` (add keys, EN + DE)

- [ ] **Step 1: Add the section + helpers to `GeneralSettingsTab`**

Add state properties (after the existing `@State private var syncStatus`):
```swift
  @State private var cliPlan: CLIToolInstaller.Plan = .create
  @State private var showReplaceConfirm = false
```
Add a new `Section` inside the `Form` (after the "Background sync" section):
```swift
      Section("Command-line tool") {
        LabeledContent("Status") { Text(cliStatusText) }
        switch cliPlan {
        case .create:
          Button("Install command-line tool") { applyCLI(.create) }
        case .repoint:
          Button("Repair") { applyCLI(.repoint) }
        case .blockedRealFile:
          Button("Replace existing binary") { showReplaceConfirm = true }
            .confirmationDialog(
              "Replace the pensieve binary in ~/.local/bin with a link to the app’s copy?",
              isPresented: $showReplaceConfirm, titleVisibility: .visible) {
                Button("Replace", role: .destructive) { replaceCLI() }
                Button("Cancel", role: .cancel) {}
              }
        case .upToDate:
          EmptyView()
        }
      }
```
Update the `.onAppear` to also refresh the CLI plan:
```swift
    .onAppear {
      syncStatus = BackgroundSyncService.status
      cliPlan = currentCLIPlan()
    }
```
Add helpers (after `statusText`):
```swift
  private var cliStatusText: LocalizedStringKey {
    switch cliPlan {
    case .upToDate: return "Installed"
    case .create: return "Not installed"
    case .repoint: return "Points elsewhere"
    case .blockedRealFile: return "A file is in the way"
    }
  }

  private func currentCLIPlan() -> CLIToolInstaller.Plan {
    CLIToolInstaller.plan(
      linkPath: PensievePaths.installedBinaryURL(),
      desiredTarget: CLIToolInstaller.bundledCLIURL(appBundleURL: Bundle.main.bundleURL))
  }

  private func applyCLI(_ plan: CLIToolInstaller.Plan) {
    try? CLIToolInstaller.apply(
      plan,
      linkPath: PensievePaths.installedBinaryURL(),
      desiredTarget: CLIToolInstaller.bundledCLIURL(appBundleURL: Bundle.main.bundleURL))
    cliPlan = currentCLIPlan()
  }

  private func replaceCLI() {
    try? CLIToolInstaller.replace(
      linkPath: PensievePaths.installedBinaryURL(),
      desiredTarget: CLIToolInstaller.bundledCLIURL(appBundleURL: Bundle.main.bundleURL))
    cliPlan = currentCLIPlan()
  }
```

- [ ] **Step 2: Add the l10n keys by hand**

In `Sources/PensieveApp/Localizable.xcstrings`, add entries (EN base + `de`, `state: "translated"`, matching the existing JSON shape). German is impersonal/infinitive; "pensieve"/"Pensieve"/`~/.local/bin` stay English:
- `"Command-line tool"` → `"Befehlszeilenprogramm"`
- `"Install command-line tool"` → `"Befehlszeilenprogramm installieren"`
- `"Repair"` → `"Reparieren"`
- `"Replace existing binary"` → `"Vorhandene Datei ersetzen"`
- `"Replace the pensieve binary in ~/.local/bin with a link to the app’s copy?"` → `"Die pensieve-Datei in ~/.local/bin durch einen Verweis auf die Kopie der App ersetzen?"`
- `"Replace"` → `"Ersetzen"`
- `"Cancel"` → `"Abbrechen"`
- `"Installed"` → `"Installiert"`
- `"Not installed"` → `"Nicht installiert"`
- `"Points elsewhere"` → `"Verweist woanders hin"`
- `"A file is in the way"` → `"Eine Datei blockiert den Pfad"`

(`"Status"` already exists from the Background sync section — do not duplicate.)

- [ ] **Step 3: Build + confirm German compiled in**

Run:
```bash
xcodegen generate && xcodebuild -project Pensieve.xcodeproj -scheme Pensieve -configuration Debug -derivedDataPath ./.build-xcode build
git checkout Package.resolved
plutil -p ./.build-xcode/Build/Products/Debug/Pensieve.app/Contents/Resources/de.lproj/Localizable.strings | grep -i "Befehlszeilenprogramm\|Vorhandene"
```
Expected: BUILD SUCCEEDED; the `grep` shows the new German values (a miss means a mis-keyed catalog entry silently falling back to English — fix the key text to match the Swift literal exactly).

- [ ] **Step 4: Smoke-launch (non-blocking)**

Run:
```bash
BIN=./.build-xcode/Build/Products/Debug/Pensieve.app/Contents/MacOS/Pensieve
PENSIEVE_DB=/tmp/pv-$$.sqlite PENSIEVE_CAPTURE_DB=/tmp/pc-$$.sqlite "$BIN" &
APP_PID=$!; sleep 4; kill $APP_PID 2>/dev/null
```
Expected: launches + exits cleanly (settings view compiles/renders; guard still prevents any `~/.local/bin` write from the `.build` path).

- [ ] **Step 5: Commit**

```bash
git add Sources/PensieveApp/Settings/GeneralSettingsTab.swift Sources/PensieveApp/Localizable.xcstrings
git commit -m "feat(app): Settings command-line-tool section (install/repair/replace) + German"
```

---

### Task 6: Docs — CLAUDE.md, runbook, observability

Reflect that the CLI ships inside the app; the hand-copied `~/.local/bin/pensieve` is retired in favor of the app-managed symlink; `swift run pensieve` is gone.

**Files:**
- Modify: `CLAUDE.md` (Dogfooding + Build/test bullets)
- Modify: `docs/observability.md` (if it references building/installing the CLI)

- [ ] **Step 1: Update `CLAUDE.md`**

- **Build/test bullet:** replace "Run the CLI: `swift run pensieve <subcommand>`…" with: the CLI is now an Xcode `tool` target (**target `PensieveCLI`, `PRODUCT_NAME: pensieve`** — the target is renamed to avoid a case-insensitive-filesystem collision with the app target `Pensieve`; the shipped binary is still `pensieve`) embedded at `Pensieve.app/Contents/Helpers/pensieve`; build it via `xcodebuild -scheme PensieveCLI build` (or the app scheme `Pensieve`, which also builds + embeds it) — **`swift run pensieve` no longer exists**; PensieveKit + tests stay SwiftPM (`./scripts/test.sh`).
- **Dogfooding bullet:** replace "Release binary at `~/.local/bin/pensieve` (rebuilt via `swift build -c release && cp …`)" with: the CLI ships inside `Pensieve.app`; `~/.local/bin/pensieve` is a **symlink** to `…/Contents/Helpers/pensieve`, auto-created on launch (when absent) and installable/repairable/replaceable via Settings ▸ General ▸ Command-line tool. No more "rebuild + reinstall the release CLI" step — updating the app updates the CLI.
- Add a one-line **gotcha:** external callers (git hooks, `~/.claude/settings.json`, `claude mcp add`) resolve the CLI via the `~/.local/bin/pensieve` symlink; keep `~/.local/bin` on `PATH` for the `claude mcp add pensieve` (bare-token) case.

- [ ] **Step 2: Update `docs/observability.md`**

If it mentions building/installing the CLI to `~/.local/bin` via `swift build`, update to the bundled-CLI + symlink story. (Skip if no such reference — grep first: `grep -n "local/bin\|swift run pensieve\|swift build -c release" docs/observability.md`.)

- [ ] **Step 3: Commit**

```bash
git add CLAUDE.md docs/observability.md
git commit -m "docs: the pensieve CLI ships inside the app; ~/.local/bin/pensieve is an app-managed symlink"
```

---

## Post-merge runbook (human, after the branch merges)

1. Build the app and **install to `/Applications`**: `xcodegen generate && xcodebuild … build && git checkout Package.resolved && rm -rf /Applications/Pensieve.app && cp -R ./.build-xcode/Build/Products/Debug/Pensieve.app /Applications/`.
2. `open /Applications/Pensieve.app` → the launch auto-install sees the legacy real file (`.blockedRealFile`), so it does **nothing** — go to **Settings ▸ General ▸ Command-line tool**, which shows "A file is in the way", and click **Replace existing binary** → confirm.
3. Verify `~/.local/bin/pensieve` is now a symlink into the bundle: `ls -l ~/.local/bin/pensieve`.
4. Confirm callers still work through it: `pensieve list` / `pensieve status`; make a test git commit in a tracked repo (git-hook capture); start a Claude Code session (`SessionStart`/`prime` hook); `claude mcp list` resolves `pensieve mcp`.
5. Rebuild + reinstall the app in place once more → confirm `~/.local/bin/pensieve` still resolves (symlink target path is stable; no reinstall needed).
