# App Settings Surface (first cut) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a first-party SwiftUI `Settings` scene (⌘,) to Pensieve.app hosting three knobs — LLM provider, hide-Dock-icon, and "Last Work Done" narration on/off — each persisted where it belongs.

**Architecture:** One machine-local, cross-process provider preference (a JSON file in the shared, non-sandboxed support dir, read by a pure resolver inside `makeDefaultLLMProvider`, so both the app and the launchd daemon honor it) plus two app-only `@AppStorage` toggles. The Settings view reads/writes `Preferences` directly; the only `AppModel` change is rebuilding its one-shot `summaryBuilder` when the provider changes.

**Tech Stack:** Swift 6, SwiftUI (`Settings` scene, `Form`, `@AppStorage`), AppKit (`NSApp.setActivationPolicy`), PensieveKit, Swift Testing, XcodeGen + xcodebuild.

## Global Constraints

- **No Python, ever. Swift only.**
- **SQLiteData predicates use `.eq(x)`, not `== x`.** (Not exercised here, but the rule stands.)
- **Trust gate is sacred and untouched** — this feature selects *which* provider runs behind the gate; grounding/citation logic is unchanged.
- **Deployment target macOS 15; `Package.swift` stays `.macOS(.v14)`.** App-target code may use macOS-15 APIs; PensieveKit must compile on 14.
- **Swift 6 language mode** on both targets (`SWIFT_VERSION: "6.0"`; strict concurrency).
- **Localize chrome only, never captured content.** German (`de`) + English base in `Localizable.xcstrings`, reconciled **by hand** (xcodebuild does not auto-populate the catalog). Proper nouns ("Foundation Models", "claude -p", "Pensieve") stay as-is.
- **The app target has no unit tests** — verify with `xcodegen generate` → `xcodebuild … build` + a non-blocking smoke-launch of the inner binary with throwaway `PENSIEVE_DB`/`PENSIEVE_CAPTURE_DB`/`PENSIEVE_PREFS`. Keep logic in tested PensieveKit; keep views thin.
- **Build the app:** `xcodegen generate && xcodebuild -project Pensieve.xcodeproj -scheme Pensieve -configuration Debug -derivedDataPath ./.build-xcode build`. App at `./.build-xcode/Build/Products/Debug/Pensieve.app`.
- **Run Kit tests:** `./scripts/test.sh` (thin `swift test` passthrough).
- **Commit messages:** use `git commit -F` with a quoted heredoc (backticks in `-m "…"` get shell-executed). Keep the trailers:
  ```
  Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_0166xomvLAWC4giBvGG7ZUcw
  ```

**Spec:** `docs/superpowers/specs/2026-07-08-app-settings-surface-design.md`.

## File Structure

**PensieveKit (new/changed):**
- `Sources/PensieveKit/LLM/Preferences.swift` — **new.** `ProviderPreference` enum + `Preferences` read/write to an explicit URL.
- `Sources/PensieveKit/Support/PensievePaths.swift` — add `preferencesURL()`.
- `Sources/PensieveKit/LLM/DefaultProvider.swift` — add `resolveProviderKind`; `makeDefaultLLMProvider(prefsURL:)` / `defaultProviderKind(prefsURL:)` consult the preference.
- `Tests/PensieveKitTests/PreferencesTests.swift` — **new.**
- `Tests/PensieveKitTests/DefaultProviderTests.swift` — pass an explicit nonexistent `prefsURL`.

**App target (new/changed):**
- `Sources/PensieveApp/AppDefaults.swift` — **new.** Shared UserDefaults key constants.
- `Sources/PensieveApp/SettingsView.swift` — **new.** The Settings `Form`.
- `Sources/PensieveApp/PensieveApp.swift` — add the `Settings` scene + `Stores.preferencesURL`.
- `Sources/PensieveApp/AppModel.swift` — `summaryBuilder` becomes rebuildable + `rebuildSummaryBuilder()`.
- `Sources/PensieveApp/AppDelegate.swift` — `applicationDidFinishLaunching` applies Dock visibility.
- `Sources/PensieveApp/DetailView.swift` — gate narration render + generation on the toggle.
- `Sources/PensieveApp/Localizable.xcstrings` — German keys for the new chrome.
- `project.yml` — disabled `PENSIEVE_PREFS` scheme env var.

---

## Task 1: Provider preference type + path (PensieveKit)

**Files:**
- Create: `Sources/PensieveKit/LLM/Preferences.swift`
- Modify: `Sources/PensieveKit/Support/PensievePaths.swift` (add `preferencesURL()`)
- Test: `Tests/PensieveKitTests/PreferencesTests.swift`

**Interfaces:**
- Produces:
  - `public enum ProviderPreference: String, Sendable, Codable { case auto, foundationModels, claudeCLI }`
  - `public enum Preferences { static func read(from: URL) -> ProviderPreference; static func write(_ preference: ProviderPreference, to: URL) }`
  - `PensievePaths.preferencesURL() -> URL`

- [ ] **Step 1: Write the failing test**

Create `Tests/PensieveKitTests/PreferencesTests.swift`:

```swift
import Foundation
import Testing
@testable import PensieveKit

private func tempPrefsURL() -> URL {
  FileManager.default.temporaryDirectory
    .appendingPathComponent("pensieve-prefs-\(UUID().uuidString).json")
}

@Test func writeThenReadRoundTrips() {
  let url = tempPrefsURL()
  defer { try? FileManager.default.removeItem(at: url) }
  Preferences.write(.claudeCLI, to: url)
  #expect(Preferences.read(from: url) == .claudeCLI)
  Preferences.write(.foundationModels, to: url)
  #expect(Preferences.read(from: url) == .foundationModels)
}

@Test func missingFileReadsAsAuto() {
  let url = tempPrefsURL()   // never written
  #expect(Preferences.read(from: url) == .auto)
}

@Test func corruptFileReadsAsAuto() throws {
  let url = tempPrefsURL()
  defer { try? FileManager.default.removeItem(at: url) }
  try Data("not json".utf8).write(to: url)
  #expect(Preferences.read(from: url) == .auto)
}

@Test func unknownProviderValueReadsAsAuto() throws {
  let url = tempPrefsURL()
  defer { try? FileManager.default.removeItem(at: url) }
  try Data(#"{"llmProvider":"gpt5"}"#.utf8).write(to: url)
  #expect(Preferences.read(from: url) == .auto)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `./scripts/test.sh --filter PreferencesTests`
Expected: FAIL — `cannot find 'Preferences' in scope` / `cannot find 'ProviderPreference' in scope`.

- [ ] **Step 3: Add `preferencesURL()` to PensievePaths**

In `Sources/PensieveKit/Support/PensievePaths.swift`, add after `captureURL()`:

```swift
  /// `~/Library/Application Support/Pensieve/preferences.json` — machine-local app/daemon
  /// settings (currently the LLM provider choice). NOT synced.
  public static func preferencesURL() -> URL {
    supportDirectory().appendingPathComponent("preferences.json")
  }
```

- [ ] **Step 4: Create the Preferences type**

Create `Sources/PensieveKit/LLM/Preferences.swift`:

```swift
import Foundation

/// The user's LLM-provider choice. `.auto` = today's local-first behavior (Foundation Models
/// when available on this machine, else `claude -p`). Raw values are the stable on-disk strings.
public enum ProviderPreference: String, Sendable, Codable {
  case auto
  case foundationModels
  case claudeCLI
}

/// Machine-local settings persisted as a small JSON file in the shared (non-sandboxed) support
/// dir, so BOTH the app and the launchd daemon read the same choice. Reads are best-effort and
/// never throw into a caller: a missing, unreadable, corrupt, or unknown value ⇒ `.auto`.
/// Callers pass an explicit URL (tests inject a temp path; the app/CLI resolve it once via the
/// factory below) — this type deliberately does not read the environment.
public enum Preferences {
  private struct Payload: Codable { var llmProvider: String? }

  public static func read(from url: URL) -> ProviderPreference {
    guard let data = try? Data(contentsOf: url),
          let payload = try? JSONDecoder().decode(Payload.self, from: data),
          let raw = payload.llmProvider,
          let preference = ProviderPreference(rawValue: raw)
    else { return .auto }
    return preference
  }

  public static func write(_ preference: ProviderPreference, to url: URL) {
    guard let data = try? JSONEncoder().encode(Payload(llmProvider: preference.rawValue))
    else { return }
    try? PensievePaths.ensureParentDirectory(of: url)
    try? data.write(to: url, options: .atomic)
  }
}
```

- [ ] **Step 5: Run test to verify it passes**

Run: `./scripts/test.sh --filter PreferencesTests`
Expected: PASS (4 tests).

- [ ] **Step 6: Commit**

```bash
git add Sources/PensieveKit/LLM/Preferences.swift Sources/PensieveKit/Support/PensievePaths.swift Tests/PensieveKitTests/PreferencesTests.swift
git commit -F - <<'EOF'
feat(kit): machine-local ProviderPreference + preferences.json read/write

Best-effort read (missing/corrupt/unknown ⇒ .auto); atomic write; explicit
URL passed in (no env-reading in Kit). PensievePaths.preferencesURL().

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_0166xomvLAWC4giBvGG7ZUcw
EOF
```

---

## Task 2: Provider resolver + factory wiring (PensieveKit)

**Files:**
- Modify: `Sources/PensieveKit/LLM/DefaultProvider.swift`
- Test: `Tests/PensieveKitTests/PreferencesTests.swift` (add resolver tests), `Tests/PensieveKitTests/DefaultProviderTests.swift` (fix)

**Interfaces:**
- Consumes: `ProviderPreference`, `Preferences.read(from:)`, `PensievePaths.preferencesURL()` (Task 1); `FoundationModelsProbe.isAvailable()`.
- Produces:
  - `public func resolveProviderKind(preference: ProviderPreference, foundationAvailable: Bool) -> String` (returns `"foundationModels"` / `"claudeCLI"`)
  - `public func makeDefaultLLMProvider(prefsURL: URL? = nil) -> any LLMProvider`
  - `public func defaultProviderKind(prefsURL: URL? = nil) -> String`

- [ ] **Step 1: Write the failing resolver tests**

Append to `Tests/PensieveKitTests/PreferencesTests.swift`:

```swift
@Test func resolverAutoFollowsAvailability() {
  #expect(resolveProviderKind(preference: .auto, foundationAvailable: true) == "foundationModels")
  #expect(resolveProviderKind(preference: .auto, foundationAvailable: false) == "claudeCLI")
}

@Test func resolverForcedFoundationFallsBackWhenUnavailable() {
  #expect(resolveProviderKind(preference: .foundationModels, foundationAvailable: true) == "foundationModels")
  #expect(resolveProviderKind(preference: .foundationModels, foundationAvailable: false) == "claudeCLI")
}

@Test func resolverForcedClaudeAlwaysClaude() {
  #expect(resolveProviderKind(preference: .claudeCLI, foundationAvailable: true) == "claudeCLI")
  #expect(resolveProviderKind(preference: .claudeCLI, foundationAvailable: false) == "claudeCLI")
}

@Test func defaultProviderKindHonorsExplicitPrefsFile() throws {
  let url = tempPrefsURL()
  defer { try? FileManager.default.removeItem(at: url) }
  Preferences.write(.claudeCLI, to: url)
  #expect(defaultProviderKind(prefsURL: url) == "claudeCLI")
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `./scripts/test.sh --filter PreferencesTests`
Expected: FAIL — `cannot find 'resolveProviderKind' in scope`; `defaultProviderKind(prefsURL:)` extra-argument error.

- [ ] **Step 3: Rewrite DefaultProvider.swift**

Replace the whole body of `Sources/PensieveKit/LLM/DefaultProvider.swift` with:

```swift
import Foundation

/// True when Foundation Models is compiled in, requires macOS 26+, and the on-device
/// model reports itself available on this machine. Shared by the factory and the resolver
/// so they can never disagree.
private func foundationModelsIsSelectable() -> Bool {
  FoundationModelsProbe.isAvailable()
}

/// The whole provider decision as one pure function. Returns the concrete kind string
/// (`"foundationModels"` / `"claudeCLI"`) — never `.auto`. Forced Foundation Models falls
/// back to `claude -p` when the model isn't available here; `.auto` picks the same way.
public func resolveProviderKind(preference: ProviderPreference, foundationAvailable: Bool) -> String {
  switch preference {
  case .auto, .foundationModels:
    return foundationAvailable ? "foundationModels" : "claudeCLI"
  case .claudeCLI:
    return "claudeCLI"
  }
}

/// Resolve which prefs file to read: an explicit URL (tests), else the `PENSIEVE_PREFS`
/// env override (throwaway dev runs), else the real support-dir file. Tests always pass an
/// explicit URL, so the env is never consulted from a test — no process-global race under
/// Swift Testing's parallel execution.
private func resolvedPrefsURL(_ explicit: URL?) -> URL {
  if let explicit { return explicit }
  if let override = ProcessInfo.processInfo.environment["PENSIEVE_PREFS"] {
    return URL(fileURLWithPath: override)
  }
  return PensievePaths.preferencesURL()
}

/// Local-first, preference-aware selection. All existing call sites keep calling this
/// argument-free; the defaulted param exists for test injection.
public func makeDefaultLLMProvider(prefsURL: URL? = nil) -> any LLMProvider {
  let kind = defaultProviderKind(prefsURL: prefsURL)
  #if canImport(FoundationModels)
  if #available(macOS 26.0, *), kind == "foundationModels" {
    return FoundationModelsProvider()
  }
  #endif
  return ClaudeCLIProvider()
}

/// Pure, testable readout of which provider `makeDefaultLLMProvider` would select, honoring
/// the persisted preference + on-device availability.
public func defaultProviderKind(prefsURL: URL? = nil) -> String {
  let preference = Preferences.read(from: resolvedPrefsURL(prefsURL))
  return resolveProviderKind(preference: preference, foundationAvailable: foundationModelsIsSelectable())
}
```

- [ ] **Step 4: Fix the existing DefaultProviderTests**

Replace `Tests/PensieveKitTests/DefaultProviderTests.swift` with:

```swift
import Foundation
import Testing
@testable import PensieveKit

@Test func defaultProviderIsSelectable() async throws {
  // Force the .auto path by pointing at a nonexistent prefs file, so this test asserts the
  // machine's native availability regardless of the real ~/Library preferences.json.
  let noPrefs = URL(fileURLWithPath: "/nonexistent/pensieve-prefs-\(UUID().uuidString).json")

  let provider = makeDefaultLLMProvider(prefsURL: noPrefs)
  _ = provider   // either FoundationModelsProvider or Claude — both are usable LLMProviders

  let kind = defaultProviderKind(prefsURL: noPrefs)
  if FoundationModelsProbe.availabilityDescription() == "available" {
    #expect(kind == "foundationModels")
  } else {
    #expect(kind == "claudeCLI")
  }
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `./scripts/test.sh --filter PreferencesTests` then `./scripts/test.sh --filter DefaultProviderTests`
Expected: PASS.

- [ ] **Step 6: Run the full Kit suite (no regressions)**

Run: `./scripts/test.sh`
Expected: PASS (all existing tests + the new ones green).

- [ ] **Step 7: Commit**

```bash
git add Sources/PensieveKit/LLM/DefaultProvider.swift Tests/PensieveKitTests/PreferencesTests.swift Tests/PensieveKitTests/DefaultProviderTests.swift
git commit -F - <<'EOF'
feat(kit): provider factory honors the persisted preference

Pure resolveProviderKind + makeDefaultLLMProvider(prefsURL:)/
defaultProviderKind(prefsURL:) read the pref (explicit URL → PENSIEVE_PREFS
→ support dir). Forced Foundation Models falls back to claude when
unavailable. Existing test pinned to .auto via an explicit prefsURL.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_0166xomvLAWC4giBvGG7ZUcw
EOF
```

---

## Task 3: Settings scene + provider picker (app)

**Files:**
- Create: `Sources/PensieveApp/SettingsView.swift`
- Modify: `Sources/PensieveApp/PensieveApp.swift` (add `Stores.preferencesURL` + the `Settings` scene)
- Modify: `Sources/PensieveApp/AppModel.swift` (rebuildable `summaryBuilder` + `rebuildSummaryBuilder()`)
- Modify: `project.yml` (disabled `PENSIEVE_PREFS` scheme env var)

**Interfaces:**
- Consumes: `ProviderPreference`, `Preferences.read/write`, `FoundationModelsProbe.isAvailable()`, `makeDefaultLLMProvider()`.
- Produces: `Stores.preferencesURL: URL`; `AppModel.rebuildSummaryBuilder()`; a `Settings` scene → ⌘, menu item.

- [ ] **Step 1: Add `Stores.preferencesURL` in PensieveApp.swift**

In `Sources/PensieveApp/PensieveApp.swift`, inside `enum Stores`, add after `spoolURL`:

```swift
  static var preferencesURL: URL {
    if let o = ProcessInfo.processInfo.environment["PENSIEVE_PREFS"] { return URL(fileURLWithPath: o) }
    return PensievePaths.preferencesURL()
  }
```

- [ ] **Step 2: Make `summaryBuilder` rebuildable in AppModel.swift**

In `Sources/PensieveApp/AppModel.swift`, replace line 136:

```swift
  private lazy var summaryBuilder = SummaryBuilder(provider: makeDefaultLLMProvider())
```

with:

```swift
  // NOT lazy: rebuilt when the provider preference changes (SettingsView), so an in-session
  // provider switch takes effect on the next narration instead of requiring a relaunch.
  private var summaryBuilder = SummaryBuilder(provider: makeDefaultLLMProvider())

  /// Rebuild the narration provider from the current persisted preference. Called by
  /// SettingsView after it writes a new ProviderPreference.
  func rebuildSummaryBuilder() {
    summaryBuilder = SummaryBuilder(provider: makeDefaultLLMProvider())
  }
```

- [ ] **Step 3: Create SettingsView.swift (provider picker only for now)**

Create `Sources/PensieveApp/SettingsView.swift`:

```swift
import SwiftUI
import PensieveKit

/// The app's Settings pane (⌘,). Reads/writes the machine-local Preferences directly — no
/// @Published mirror on AppModel; the only AppModel touch is rebuilding its summary builder
/// when the provider changes.
struct SettingsView: View {
  @ObservedObject var model: AppModel
  @State private var provider: ProviderPreference = Preferences.read(from: Stores.preferencesURL)

  private var foundationAvailable: Bool { FoundationModelsProbe.isAvailable() }

  var body: some View {
    Form {
      Section("Intelligence") {
        Picker("LLM Provider", selection: $provider) {
          Text("Automatic").tag(ProviderPreference.auto)
          Text("Foundation Models").tag(ProviderPreference.foundationModels)
          Text("claude -p").tag(ProviderPreference.claudeCLI)
        }
        .onChange(of: provider) { _, newValue in
          Preferences.write(newValue, to: Stores.preferencesURL)
          model.rebuildSummaryBuilder()
        }
        if provider == .foundationModels && !foundationAvailable {
          Label("Foundation Models isn’t available on this Mac — using claude -p instead.",
                systemImage: "exclamationmark.triangle")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
    }
    .formStyle(.grouped)
    .frame(width: 460)
  }
}
```

- [ ] **Step 4: Add the Settings scene to the App body**

In `Sources/PensieveApp/PensieveApp.swift`, add after the `MenuBarExtra { … }.menuBarExtraStyle(.window)` block (still inside `var body: some Scene`):

```swift
    Settings {
      SettingsView(model: model)
    }
```

- [ ] **Step 5: Add the disabled `PENSIEVE_PREFS` scheme env var**

In `project.yml`, under `scheme.environmentVariables`, add after the `PENSIEVE_CAPTURE_DB` entry:

```yaml
        - variable: PENSIEVE_PREFS
          value: "/Users/moritz/Library/Application Support/Pensieve-Dev/preferences.json"
          isEnabled: false
```

- [ ] **Step 6: Build**

Run:
```bash
xcodegen generate && xcodebuild -project Pensieve.xcodeproj -scheme Pensieve -configuration Debug -derivedDataPath ./.build-xcode build 2>&1 | tail -5
```
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 7: Smoke-launch (non-blocking, throwaway stores)**

Run:
```bash
mkdir -p /tmp/psv-smoke && APP="./.build-xcode/Build/Products/Debug/Pensieve.app/Contents/MacOS/Pensieve"; PENSIEVE_DB=/tmp/psv-smoke/pensieve.sqlite PENSIEVE_CAPTURE_DB=/tmp/psv-smoke/capture.sqlite PENSIEVE_PREFS=/tmp/psv-smoke/preferences.json "$APP" >/tmp/psv-smoke/out.log 2>&1 & PID=$!; sleep 3; kill $PID 2>/dev/null; echo "launched pid $PID, log:"; cat /tmp/psv-smoke/out.log
```
Expected: process launches without a crash/log error (empty or benign log). (⌘, and picker behavior are human-verify carries.)

- [ ] **Step 8: Commit**

```bash
git add Sources/PensieveApp/SettingsView.swift Sources/PensieveApp/PensieveApp.swift Sources/PensieveApp/AppModel.swift project.yml
git commit -F - <<'EOF'
feat(app): Settings scene (⌘,) with LLM provider picker

Settings pane reads/writes Preferences directly + shows Foundation Models
availability; on change rebuilds AppModel.summaryBuilder so the app honors
the switch without relaunch. Stores.preferencesURL + disabled PENSIEVE_PREFS
scheme var for sandboxed dev runs.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_0166xomvLAWC4giBvGG7ZUcw
EOF
```

---

## Task 4: Hide-Dock-icon toggle (app)

**Files:**
- Create: `Sources/PensieveApp/AppDefaults.swift`
- Modify: `Sources/PensieveApp/AppDelegate.swift`
- Modify: `Sources/PensieveApp/SettingsView.swift`

**Interfaces:**
- Produces: `enum AppDefaults { static let hideDockIconKey: String; static let narrationEnabledKey: String }` (narration key defined here, consumed in Task 5).
- Consumes: nothing new.

- [ ] **Step 1: Create AppDefaults.swift**

Create `Sources/PensieveApp/AppDefaults.swift`:

```swift
import Foundation

/// UserDefaults keys shared between an `@AppStorage` binding in a View and a plain
/// `UserDefaults` read elsewhere (e.g. the AppDelegate, which can't use `@AppStorage`), so
/// the two can't drift. Mirrors the existing FocusFilterDefaults pattern.
enum AppDefaults {
  static let hideDockIconKey = "app.hideDockIcon"
  static let narrationEnabledKey = "app.narrationEnabled"
}
```

- [ ] **Step 2: Apply Dock visibility at launch in AppDelegate**

In `Sources/PensieveApp/AppDelegate.swift`, add these methods inside the `AppDelegate` class (after `application(_:open:)`):

```swift
  func applicationDidFinishLaunching(_ notification: Notification) {
    applyDockVisibility()
  }

  /// Reads the shared hide-Dock preference and sets the activation policy. `.accessory` hides
  /// the Dock tile + ⌘-Tab entry (menu-bar-only); the MenuBarExtra keeps the app alive.
  func applyDockVisibility() {
    let hidden = UserDefaults.standard.bool(forKey: AppDefaults.hideDockIconKey)
    NSApp.setActivationPolicy(hidden ? .accessory : .regular)
  }
```

- [ ] **Step 3: Add the General section + toggle to SettingsView**

In `Sources/PensieveApp/SettingsView.swift`, add `import AppKit` at the top (below `import PensieveKit`), add the storage property inside the struct (below the `provider` `@State`):

```swift
  @AppStorage(AppDefaults.hideDockIconKey) private var hideDockIcon = false
```

and add a `General` section as the **first** section in the `Form` (above `Section("Intelligence")`):

```swift
      Section("General") {
        Toggle("Hide Dock icon (menu bar only)", isOn: $hideDockIcon)
          .onChange(of: hideDockIcon) { _, hidden in
            NSApp.setActivationPolicy(hidden ? .accessory : .regular)
            if !hidden {
              // Returning to .regular: re-front the app, or it can stay backgrounded with no
              // key window.
              NSApp.activate(ignoringOtherApps: true)
            }
          }
      }
```

- [ ] **Step 4: Build**

Run:
```bash
xcodegen generate && xcodebuild -project Pensieve.xcodeproj -scheme Pensieve -configuration Debug -derivedDataPath ./.build-xcode build 2>&1 | tail -5
```
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Smoke-launch (non-blocking)**

Run:
```bash
APP="./.build-xcode/Build/Products/Debug/Pensieve.app/Contents/MacOS/Pensieve"; PENSIEVE_DB=/tmp/psv-smoke/pensieve.sqlite PENSIEVE_CAPTURE_DB=/tmp/psv-smoke/capture.sqlite PENSIEVE_PREFS=/tmp/psv-smoke/preferences.json "$APP" >/tmp/psv-smoke/out.log 2>&1 & PID=$!; sleep 3; kill $PID 2>/dev/null; echo "ok pid $PID"; cat /tmp/psv-smoke/out.log
```
Expected: launches cleanly (default false ⇒ `.regular`, no behavior change). (Actual Dock hide/restore is a human-verify carry.)

- [ ] **Step 6: Commit**

```bash
git add Sources/PensieveApp/AppDefaults.swift Sources/PensieveApp/AppDelegate.swift Sources/PensieveApp/SettingsView.swift
git commit -F - <<'EOF'
feat(app): hide-Dock-icon (menu-bar-only) toggle

Shared AppDefaults keys; AppDelegate.applicationDidFinishLaunching applies
the activation policy at launch; the Settings toggle flips it live and
re-activates on return to .regular.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_0166xomvLAWC4giBvGG7ZUcw
EOF
```

---

## Task 5: Narration on/off toggle + DetailView gating (app)

**Files:**
- Modify: `Sources/PensieveApp/SettingsView.swift`
- Modify: `Sources/PensieveApp/DetailView.swift`

**Interfaces:**
- Consumes: `AppDefaults.narrationEnabledKey` (Task 4).

- [ ] **Step 1: Add the narration toggle to SettingsView**

In `Sources/PensieveApp/SettingsView.swift`, add the storage property inside the struct (below `hideDockIcon`):

```swift
  @AppStorage(AppDefaults.narrationEnabledKey) private var narrationEnabled = true
```

and add this `Toggle` inside `Section("Intelligence")`, above the `Picker`:

```swift
        Toggle("Show “Last Work Done” narration", isOn: $narrationEnabled)
```

- [ ] **Step 2: Read the toggle in DetailView**

In `Sources/PensieveApp/DetailView.swift`, add below `@ObservedObject var model: AppModel` (line 6):

```swift
  @AppStorage(AppDefaults.narrationEnabledKey) private var narrationEnabled = true
```

- [ ] **Step 3: Gate the render (both branches)**

In `Sources/PensieveApp/DetailView.swift`, change the narration render guards (lines 42 and 51):

```swift
        if narrationEnabled, let lastWorkDone, loadedNodeID == node.id {
```
and
```swift
        } else if narrationEnabled, isNarrating, loadedNodeID == node.id {
```

- [ ] **Step 4: Gate generation in the `.task`**

In `Sources/PensieveApp/DetailView.swift`, inside the `.task`, immediately after the `shareMarkdown = …` assignment (currently line 104, before the `if !isRefresh, let cached …` line) insert:

```swift
      guard narrationEnabled else { lastWorkDone = nil; isNarrating = false; return }
```

(With narration off, no cached prose is shown and no LLM call is made; toggling back on regenerates on the next node-change or ⌘R — accepted per spec.)

- [ ] **Step 5: Build**

Run:
```bash
xcodegen generate && xcodebuild -project Pensieve.xcodeproj -scheme Pensieve -configuration Debug -derivedDataPath ./.build-xcode build 2>&1 | tail -5
```
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 6: Smoke-launch (non-blocking)**

Run:
```bash
APP="./.build-xcode/Build/Products/Debug/Pensieve.app/Contents/MacOS/Pensieve"; PENSIEVE_DB=/tmp/psv-smoke/pensieve.sqlite PENSIEVE_CAPTURE_DB=/tmp/psv-smoke/capture.sqlite PENSIEVE_PREFS=/tmp/psv-smoke/preferences.json "$APP" >/tmp/psv-smoke/out.log 2>&1 & PID=$!; sleep 3; kill $PID 2>/dev/null; echo "ok pid $PID"; cat /tmp/psv-smoke/out.log
```
Expected: launches cleanly (default true ⇒ narration behaves as today).

- [ ] **Step 7: Commit**

```bash
git add Sources/PensieveApp/SettingsView.swift Sources/PensieveApp/DetailView.swift
git commit -F - <<'EOF'
feat(app): "Last Work Done" narration on/off toggle

Settings toggle (default on); DetailView gates both the render (cached +
in-flight) and the generation .task on it, so off means no prose shown and
no LLM call.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_0166xomvLAWC4giBvGG7ZUcw
EOF
```

---

## Task 6: German localization + whole-branch verification

**Files:**
- Modify: `Sources/PensieveApp/Localizable.xcstrings`

**Interfaces:** none (chrome reconciliation + verification only).

The new user-facing English literals introduced by Tasks 3–5 (each becomes a catalog key):
`"General"`, `"Intelligence"`, `"Hide Dock icon (menu bar only)"`, `"Show “Last Work Done” narration"`, `"LLM Provider"`, `"Automatic"`, `"Foundation Models isn’t available on this Mac — using claude -p instead."`. (`"Foundation Models"` and `"claude -p"` are proper nouns — leave them English-fallback; do not add German values.)

- [ ] **Step 1: Add each key with its German translation**

Edit `Sources/PensieveApp/Localizable.xcstrings` by hand (JSON). For each key above, add an entry under `"strings"` with an English base and a `de` localization. Use this mapping for the `de` values (match the existing catalog's entry shape — `"extractionState": "translated"`, `"stringUnit"` with `"state": "translated"` + `"value"`):

| Key (English base) | `de` value |
|---|---|
| `General` | `Allgemein` |
| `Intelligence` | `Intelligenz` |
| `Hide Dock icon (menu bar only)` | `Dock-Symbol ausblenden (nur Menüleiste)` |
| `Show “Last Work Done” narration` | `„Zuletzt erledigt“-Zusammenfassung anzeigen` |
| `LLM Provider` | `LLM-Anbieter` |
| `Automatic` | `Automatisch` |
| `Foundation Models isn’t available on this Mac — using claude -p instead.` | `Foundation Models ist auf diesem Mac nicht verfügbar – stattdessen wird claude -p verwendet.` |

Match the exact literal (curly quotes `“ ”`, apostrophe `’`, em dash `—`) from the Swift source so the key resolves — a mis-keyed `de` value silently falls back to English.

- [ ] **Step 2: Build**

Run:
```bash
xcodegen generate && xcodebuild -project Pensieve.xcodeproj -scheme Pensieve -configuration Debug -derivedDataPath ./.build-xcode build 2>&1 | tail -5
```
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Verify the German compiled into the bundle**

Run:
```bash
plutil -p "./.build-xcode/Build/Products/Debug/Pensieve.app/Contents/Resources/de.lproj/Localizable.strings" | grep -E "Allgemein|Intelligenz|Dock-Symbol|LLM-Anbieter|Automatisch|nicht verfügbar"
```
Expected: the German values print (each key compiled into `de.lproj`).

- [ ] **Step 4: Full Kit test suite (final regression gate)**

Run: `./scripts/test.sh`
Expected: PASS — all tests green (the Task 1–2 additions + everything pre-existing).

- [ ] **Step 5: Final smoke-launch**

Run:
```bash
APP="./.build-xcode/Build/Products/Debug/Pensieve.app/Contents/MacOS/Pensieve"; PENSIEVE_DB=/tmp/psv-smoke/pensieve.sqlite PENSIEVE_CAPTURE_DB=/tmp/psv-smoke/capture.sqlite PENSIEVE_PREFS=/tmp/psv-smoke/preferences.json "$APP" >/tmp/psv-smoke/out.log 2>&1 & PID=$!; sleep 3; kill $PID 2>/dev/null; echo "ok pid $PID"; cat /tmp/psv-smoke/out.log
```
Expected: clean launch.

- [ ] **Step 6: Commit**

```bash
git add Sources/PensieveApp/Localizable.xcstrings
git commit -F - <<'EOF'
chore(l10n): German for the Settings pane chrome

General/Intelligence sections, the three knob labels, the provider picker
label + "Automatic", and the Foundation Models fallback note. Proper nouns
(Foundation Models, claude -p) stay English-fallback.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_0166xomvLAWC4giBvGG7ZUcw
EOF
```

---

## Human-verify carries (post-merge; need the built app + real store + plain `open`)

Cannot be asserted headlessly. Build (`xcodegen generate && xcodebuild … build`) then `open ./.build-xcode/Build/Products/Debug/Pensieve.app`:

- **⌘,** (and Pensieve ▸ Settings…) opens the Settings pane; the two sections render.
- Each knob **persists across an app relaunch**.
- Provider picker shows the Foundation Models fallback note when `.foundationModels` is picked on a Mac that can't run it.
- A provider choice made in the app is honored by a subsequent `pensieve sync` / ingestion run (both processes read the same `preferences.json`).
- **Hide Dock icon** removes the Dock tile (menu-bar item remains, main window reachable via "Open Pensieve"); un-toggling restores it and re-fronts the window — across relaunch too.
- **Narration off** hides / does-not-generate "Last Work Done"; on restores it (regenerates on next node-switch or ⌘R).
- German renders in situ: launch with `-AppleLanguages '(de)'` and confirm the pane chrome is German while provider names stay English.

## Self-Review

- **Spec coverage:** Settings scene + ⌘, (Task 3); provider preference shared file + resolver + factory (Tasks 1–2); `DefaultProviderTests` fix (Task 2); `summaryBuilder` rebuild (Task 3); hide-Dock via activation policy + launch hook + `NSApp.activate` (Task 4); narration render+generation gating (Task 5); shared defaults-key constant (Task 4); disabled `PENSIEVE_PREFS` scheme var (Task 3); German chrome (Task 6); every spec "human-verify carry" listed. Non-goals (cloud provider, error surfacing, other knobs, tabs) are not implemented. ✔
- **Placeholder scan:** none — every code step shows complete code; every command shows expected output. ✔
- **Type consistency:** `ProviderPreference` (Task 1) used identically in Tasks 2–3; `resolveProviderKind(preference:foundationAvailable:) -> String` and `makeDefaultLLMProvider(prefsURL:)`/`defaultProviderKind(prefsURL:)` names match across Tasks 2 and the DefaultProviderTests fix; `AppDefaults.hideDockIconKey`/`narrationEnabledKey` defined in Task 4 and consumed in Tasks 4–5; `Stores.preferencesURL` defined and used in Task 3; `AppModel.rebuildSummaryBuilder()` defined and called in Task 3. ✔
