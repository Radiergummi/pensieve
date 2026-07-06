# Xcode Adoption + Real Pensieve.app Bundle — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move the `PensieveApp` target off the unbundled SwiftPM executable onto a proper, `actool`-built `Pensieve.app` produced by an XcodeGen project that consumes PensieveKit as a local SwiftPM package.

**Architecture:** A committed `project.yml` (XcodeGen) defines one macOS app target depending on the local PensieveKit package (`path: .`). The package keeps the PensieveKit library, the `pensieve` CLI, and the test target unchanged — Xcode wraps only the app shell. Ad-hoc signing; the bundled Icon Composer `.icon` compiled by `actool`. The unbundled-era workarounds (`setActivationPolicy(.regular)`, runtime `applicationIconImage`, the `AppDelegate`) are removed — a real bundle makes them unnecessary, and the `Bundle.module` icon load won't even compile in an Xcode target.

**Tech Stack:** XcodeGen 2.45.4, Xcode 26.6 (active), Swift 6, SwiftUI `App`/`Scene`, SwiftPM (PensieveKit + CLI + tests), macOS 26.5.2 host.

**Spec:** `docs/superpowers/specs/2026-07-06-xcode-adoption-app-bundle-design.md`

## Global Constraints

- **Toolchain is active** (verified 2026-07-06): `xcode-select -p` → `/Applications/Xcode.app/Contents/Developer`, `xcodebuild -version` → Xcode 26.6, `actool --version` runs. No sudo steps remain. Task 1 still gates on these defensively.
- **Deployment target: macOS 14** (unchanged). `actool` auto-emits a pre-26 `.icns` from the `.icon`, so 14 is compatible with the bundled icon.
- **The app target has NO unit tests** (project convention). Verify app changes with `xcodebuild` build + a **non-blocking** background smoke-launch (exec the **inner binary** `…/Pensieve.app/Contents/MacOS/Pensieve` so `PENSIEVE_DB`/`PENSIEVE_CAPTURE_DB` env is forwarded; never `open -a`, which drops env; background + `kill`). No new PensieveKit tests — no logic moves into the framework.
- **Do NOT perturb the live store.** Every smoke-launch sets throwaway `PENSIEVE_DB` / `PENSIEVE_CAPTURE_DB` (a `/tmp` path).
- **All 138 PensieveKit tests must stay green** — `./scripts/test.sh` (still works under Xcode; Task 3 simplifies it once plain `swift test` is confirmed).
- **Signing:** ad-hoc — `CODE_SIGN_IDENTITY: "-"`, `CODE_SIGNING_ALLOWED: "YES"`, `CODE_SIGNING_REQUIRED: "NO"` (ALLOWED must be YES or the bundle is left unsigned).
- **App icon:** primary = the bundled `icons/Pensieve.icon` via `actool` (added to the target `sources` **and** `ASSETCATALOG_COMPILER_APPICON_NAME: Pensieve`). `.icns` fallback (`sips`+`iconutil`+`CFBundleIconFile`) only if `actool` cannot run — it can, so the primary path is expected.
- **Pinned Xcode build dir:** `xcodebuild … -derivedDataPath ./.build-xcode` → `./.build-xcode/Build/Products/Debug/Pensieve.app`. Both `Pensieve.xcodeproj/` and `.build-xcode/` are gitignored.
- **The CLI + daemon are untouched** — the `pensieve` target stays in the package; no `~/.local/bin/pensieve` rebuild/reinstall is needed for this work.
- **Commit messages:** use the `git commit -F` heredoc form (backticks in `-m "…"` get shell-executed); keep the `Co-Authored-By:` / `Claude-Session:` trailers.
- **All paths below are relative to the repo root** (the worktree root during execution).

---

## File Structure

- **Create:** `project.yml` — XcodeGen definition of the `Pensieve` app target (source of truth; the `.xcodeproj` is generated + gitignored).
- **Modify:** `Package.swift` — remove the `PensieveApp` product + `.executableTarget` (package keeps PensieveKit lib, `pensieve` CLI, test target).
- **Modify:** `Sources/PensieveApp/PensieveApp.swift` — remove the `AppDelegate`, the `@NSApplicationDelegateAdaptor`, the runtime icon load, `setActivationPolicy`, and the now-unused `import AppKit`.
- **Delete:** `Sources/PensieveApp/Resources/AppIcon.png` (and the empty `Resources/` dir).
- **Modify:** `.gitignore` — add `Pensieve.xcodeproj/` and `.build-xcode/`.
- **Modify:** `scripts/test.sh` — simplify to a plain `swift test` passthrough (Task 3).
- **Modify:** `CLAUDE.md`, `CONTINUE.md` — Xcode workflow; rewrite the now-false `swift test` gotcha; status/next (Task 3).

Three tasks: **Task 1** the build-system migration (app builds as an Xcode `.app`, generic icon); **Task 2** the bundled `.icon` (the one validated-first unknown, isolated); **Task 3** docs + test-wrapper cleanup.

---

## Task 1: Migrate the app to an XcodeGen/Xcode `.app` bundle (no custom icon yet)

Swap the build system: create the XcodeGen project, drop the SPM app target, and remove the unbundled workarounds (the `Bundle.module` icon load won't compile in an Xcode target, so this removal is mandatory, not optional). Deliverable: `xcodegen generate` + `xcodebuild build` produces a launchable, ad-hoc-signed `Pensieve.app` with the **"Pensieve"** menu title and correct foreground activation — a generic icon at this stage (Task 2 adds the artwork).

**Files:**
- Create: `project.yml`
- Modify: `Package.swift` (remove PensieveApp product + target)
- Modify: `Sources/PensieveApp/PensieveApp.swift` (remove workarounds)
- Delete: `Sources/PensieveApp/Resources/AppIcon.png`
- Modify: `.gitignore`

**Interfaces:**
- Consumes: the existing `Sources/PensieveApp/*.swift` (AppModel, RootView, etc., unchanged) and the local PensieveKit package product.
- Produces: `project.yml` (the Xcode project source of truth); a buildable `Pensieve` scheme → `./.build-xcode/Build/Products/Debug/Pensieve.app`. Task 2 extends `project.yml`.

- [ ] **Step 1: Toolchain gate**

Run:

```bash
xcodebuild -version && actool --version >/dev/null 2>&1 && echo "actool OK" && xcodegen --version
```

Expected: `Xcode 26.6`, `actool OK`, `Version: 2.45.4`. If any command fails, STOP — the prerequisite (`sudo xcode-select -s /Applications/Xcode.app`, and if `actool` errors with a plugin-load failure, `sudo xcodebuild -runFirstLaunch`) is not satisfied; report BLOCKED.

- [ ] **Step 2: Create `project.yml`**

Create `project.yml` at the repo root (note: **no icon yet** — Task 2 adds `icons/Pensieve.icon` to `sources` and `ASSETCATALOG_COMPILER_APPICON_NAME`):

```yaml
name: Pensieve
options:
  bundleIdPrefix: me.mazetti
  deploymentTarget:
    macOS: "14.0"
packages:
  PensieveKit:
    path: .
targets:
  Pensieve:
    type: application
    platform: macOS
    sources:
      - Sources/PensieveApp
    dependencies:
      - package: PensieveKit
        product: PensieveKit
    settings:
      base:
        PRODUCT_NAME: Pensieve
        PRODUCT_BUNDLE_IDENTIFIER: me.mazetti.pensieve
        GENERATE_INFOPLIST_FILE: "YES"
        MARKETING_VERSION: "0.2"
        CODE_SIGN_IDENTITY: "-"
        CODE_SIGNING_ALLOWED: "YES"
        CODE_SIGNING_REQUIRED: "NO"
```

- [ ] **Step 3: Gitignore the generated project + build dir**

Append to `.gitignore`:

```
# Xcode (generated by XcodeGen; project.yml is the source of truth)
Pensieve.xcodeproj/
.build-xcode/
```

- [ ] **Step 4: Drop the `PensieveApp` target from `Package.swift`**

In `Package.swift`, remove the product line. Find:

```swift
    .executable(name: "pensieve", targets: ["pensieve"]),
    .executable(name: "PensieveApp", targets: ["PensieveApp"]),
  ],
```

Change to:

```swift
    .executable(name: "pensieve", targets: ["pensieve"]),
  ],
```

Then remove the target. Find:

```swift
    .executableTarget(
      name: "PensieveApp",
      dependencies: ["PensieveKit"],
      resources: [.copy("Resources/AppIcon.png")]
    ),
    .testTarget(
```

Change to:

```swift
    .testTarget(
```

- [ ] **Step 5: Remove the unbundled workarounds from `PensieveApp.swift`**

Overwrite `Sources/PensieveApp/PensieveApp.swift` with (the `AppDelegate`, the `@NSApplicationDelegateAdaptor`, the runtime icon load, `setActivationPolicy`, and `import AppKit` are all gone; `Stores` and the `App`/`Window`/`.commands` scene remain):

```swift
import Foundation
import SwiftUI
import PensieveKit

/// Resolves store locations the same way the CLI does (honors PENSIEVE_DB / PENSIEVE_CAPTURE_DB).
enum Stores {
  static var canonicalURL: URL {
    if let o = ProcessInfo.processInfo.environment["PENSIEVE_DB"] { return URL(fileURLWithPath: o) }
    return PensievePaths.canonicalURL()
  }
  static var spoolURL: URL {
    if let o = ProcessInfo.processInfo.environment["PENSIEVE_CAPTURE_DB"] { return URL(fileURLWithPath: o) }
    return PensievePaths.captureURL()
  }
}

@main
struct PensieveApp: App {
  // One AppModel for the app's lifetime. Its init reads/writes the lastOpenedAt UserDefault.
  @StateObject private var model = AppModel()

  var body: some Scene {
    // A single unique window — the correct primitive for one main window. `Window` gives the standard
    // menu bar, ⌘Q, and scene frame restoration for free. A real .app bundle makes the app `.regular`
    // by default, so no manual activation-policy is needed; the icon comes from the bundled .icon.
    Window("Pensieve", id: "main") {
      RootView(model: model)
        .frame(minWidth: 720, minHeight: 420)
        .task { model.start() }   // idempotent (guarded in AppModel)
    }
    .defaultSize(width: 900, height: 560)
    .windowResizability(.contentMinSize)
    .commands {
      SidebarCommands()   // standard Show/Hide Sidebar (⌃⌘S) in the View menu
      CommandMenu("Go") {
        Button("Quick Jump…") { model.showPalette = true }
          .keyboardShortcut("k", modifiers: .command)
        Divider()
        Button("Refresh") { Task { await model.refreshNow() } }
          .keyboardShortcut("r", modifiers: .command)
      }
    }
  }
}
```

- [ ] **Step 6: Delete the now-unused runtime icon resource**

Run:

```bash
git rm Sources/PensieveApp/Resources/AppIcon.png
rmdir Sources/PensieveApp/Resources 2>/dev/null || true
```

Expected: `AppIcon.png` staged for deletion; the `Resources/` dir removed if empty.

- [ ] **Step 7: Generate the Xcode project**

Run: `xcodegen generate`
Expected: `Loaded project ...` / `Created project at Pensieve.xcodeproj`. No errors. (Xcode will resolve the whole package incl. swift-argument-parser on first build — a one-time fetch, not a failure.)

- [ ] **Step 8: Build the app**

Run:

```bash
xcodebuild -project Pensieve.xcodeproj -scheme Pensieve -configuration Debug -derivedDataPath ./.build-xcode build 2>&1 | tail -15
```

Expected: `** BUILD SUCCEEDED **`. The bundle is at `./.build-xcode/Build/Products/Debug/Pensieve.app`.

- [ ] **Step 9: Confirm the ad-hoc signature + bundle identity**

Run:

```bash
APP=./.build-xcode/Build/Products/Debug/Pensieve.app
codesign -dv "$APP" 2>&1 | grep -i "Signature\|Identifier" || true
/usr/libexec/PlistBuddy -c "Print :CFBundleName" "$APP/Contents/Info.plist"
```

Expected: a line reporting `Signature=adhoc`, `Identifier=me.mazetti.pensieve`, and `CFBundleName` → `Pensieve`.

- [ ] **Step 10: Smoke-launch the built app (throwaway store), verify no crash + foreground**

Run:

```bash
APP=./.build-xcode/Build/Products/Debug/Pensieve.app
env PENSIEVE_DB=/tmp/pensieve-smoke.sqlite PENSIEVE_CAPTURE_DB=/tmp/pensieve-smoke-capture.sqlite \
  "$APP/Contents/MacOS/Pensieve" > /tmp/pensieve-smoke.log 2>&1 &
APP_PID=$!
sleep 6
FRONT=$(osascript -e 'tell application "System Events" to name of first process whose frontmost is true' 2>/dev/null || echo "?")
if kill "$APP_PID" 2>/dev/null; then echo "LAUNCH-OK; frontmost=$FRONT"; else echo "CRASHED — see log"; fi
cat /tmp/pensieve-smoke.log
```

Expected: `LAUNCH-OK; frontmost=Pensieve` (the bundled app becomes `.regular` and foreground without the removed workaround), no crash in the log.

- [ ] **Step 11: Confirm the package still builds + all tests pass**

Run: `./scripts/test.sh 2>&1 | tail -3`
Expected: `Test run with 138 tests ... passed` (the package builds fine after dropping the app target).

- [ ] **Step 12: Commit**

```bash
git add project.yml Package.swift Sources/PensieveApp/PensieveApp.swift .gitignore
git rm --cached --ignore-unmatch Sources/PensieveApp/Resources/AppIcon.png
git commit -F - <<'EOF'
feat(app): build Pensieve.app via XcodeGen/Xcode (local SPM package)

Add project.yml (XcodeGen) defining a macOS app target that links PensieveKit
as a local SwiftPM package; drop the PensieveApp SPM executable target/product
from Package.swift. Remove the unbundled-era workarounds from PensieveApp.swift
(AppDelegate, @NSApplicationDelegateAdaptor, setActivationPolicy(.regular), the
runtime applicationIconImage load + Resources/AppIcon.png) — a real .app bundle
is .regular by default, and Bundle.module doesn't exist in an Xcode target.
Ad-hoc signed; CFBundleName=Pensieve fixes the menu title. Generated
Pensieve.xcodeproj + ./.build-xcode are gitignored. CLI/tests untouched.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01GsAu7rTTdD77k3xZHZrhm4
EOF
```

---

## Task 2: Bundle the app icon (`icons/Pensieve.icon`) via `actool`

Wire the Icon Composer `.icon` into the app target so `actool` compiles it into the bundle (Dock + Finder icon, plus the auto-generated pre-26 `.icns`). This is the spec's one validated-first unknown, isolated here.

**Files:**
- Modify: `project.yml` (add the icon source + the app-icon-name setting)

**Interfaces:**
- Consumes: `project.yml` and the `Pensieve` target from Task 1; `icons/Pensieve.icon` (already in the repo).
- Produces: a `Pensieve.app` whose `Contents/Resources` contains a compiled `Assets.car`/`AppIcon`.

- [ ] **Step 1: Add the `.icon` to the target and name it**

In `project.yml`, add the icon to the target `sources`. Find:

```yaml
    sources:
      - Sources/PensieveApp
```

Change to:

```yaml
    sources:
      - Sources/PensieveApp
      - icons/Pensieve.icon
```

Then add the driving build setting. Find:

```yaml
        PRODUCT_BUNDLE_IDENTIFIER: me.mazetti.pensieve
```

Change to:

```yaml
        PRODUCT_BUNDLE_IDENTIFIER: me.mazetti.pensieve
        ASSETCATALOG_COMPILER_APPICON_NAME: Pensieve
```

- [ ] **Step 2: Regenerate and rebuild**

Run:

```bash
xcodegen generate && \
xcodebuild -project Pensieve.xcodeproj -scheme Pensieve -configuration Debug -derivedDataPath ./.build-xcode build 2>&1 | tail -15
```

Expected: `** BUILD SUCCEEDED **`. If `actool` errors that it cannot find/compile the icon, STOP and report — the documented fallback is a static `.icns` (`sips` → `.iconset` with the standard 16/32/128/256/512 @1x/@2x names → `iconutil -c icns Pensieve.iconset -o Pensieve.icns` → add to the target + `CFBundleIconFile: Pensieve`), but `actool` is confirmed runnable so the primary path is expected.

- [ ] **Step 3: Confirm the icon compiled into the bundle**

Run:

```bash
APP=./.build-xcode/Build/Products/Debug/Pensieve.app
ls "$APP/Contents/Resources/" | grep -iE "Assets.car|AppIcon|\.icns" || echo "NO ICON ARTIFACT"
/usr/libexec/PlistBuddy -c "Print :CFBundleIconName" "$APP/Contents/Info.plist" 2>/dev/null || \
  /usr/libexec/PlistBuddy -c "Print :CFBundleIcons" "$APP/Contents/Info.plist" 2>/dev/null || true
```

Expected: an `Assets.car` (and/or an `AppIcon`/`.icns`) present, and an icon key in Info.plist. `NO ICON ARTIFACT` means the wiring didn't take — report it.

- [ ] **Step 4: Smoke-launch (throwaway store), no crash**

Run:

```bash
APP=./.build-xcode/Build/Products/Debug/Pensieve.app
env PENSIEVE_DB=/tmp/pensieve-smoke.sqlite PENSIEVE_CAPTURE_DB=/tmp/pensieve-smoke-capture.sqlite \
  "$APP/Contents/MacOS/Pensieve" > /tmp/pensieve-smoke.log 2>&1 &
APP_PID=$!
sleep 6
kill "$APP_PID" 2>/dev/null && echo "LAUNCH-OK" || echo "CRASHED"
cat /tmp/pensieve-smoke.log
```

Expected: `LAUNCH-OK`, no crash. (The Dock/Finder icon pixels are a controller/user visual check — see the acceptance checklist.)

- [ ] **Step 5: Commit**

```bash
git add project.yml
git commit -F - <<'EOF'
feat(app): bundle the Pensieve.icon app icon via actool

Add icons/Pensieve.icon to the Pensieve target sources and set
ASSETCATALOG_COMPILER_APPICON_NAME=Pensieve so actool compiles it into the
bundle (Dock + Finder icon, plus the auto-generated pre-26 .icns). Replaces the
runtime applicationIconImage removed in the previous commit.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01GsAu7rTTdD77k3xZHZrhm4
EOF
```

---

## Task 3: Docs + test-wrapper cleanup

Now that Xcode is active, plain `swift test` works and the `scripts/test.sh` CLT-specific flags are dead no-ops. Simplify the wrapper (keeping the `./scripts/test.sh` entry point so all references stay valid) and rewrite the now-false docs.

**Files:**
- Modify: `scripts/test.sh`
- Modify: `CLAUDE.md`
- Modify: `CONTINUE.md`

**Interfaces:**
- Consumes: nothing new — closes out the migration.
- Produces: accurate build/test docs describing the Xcode workflow.

- [ ] **Step 1: Confirm plain `swift test` runs the suite natively**

Run: `swift test 2>&1 | tail -3`
Expected: `Test run with 138 tests ... passed` (Swift Testing loads under the active Xcode toolchain — no wrapper flags needed).

- [ ] **Step 2: Simplify `scripts/test.sh` to a passthrough**

Overwrite `scripts/test.sh` with:

```sh
#!/bin/sh
# Run the PensieveKit test suite. Under an active Xcode toolchain, plain `swift test`
# loads Swift Testing natively; this wrapper is kept as the stable entry point (and for
# passing filters, e.g. ./scripts/test.sh --filter projectRoundTrips).
exec swift test "$@"
```

- [ ] **Step 3: Verify the simplified wrapper still works**

Run: `./scripts/test.sh 2>&1 | tail -3`
Expected: `Test run with 138 tests ... passed`.

- [ ] **Step 4: Update `CLAUDE.md`**

In `CLAUDE.md`, rewrite the Build & test bullet. Find:

```
- **Run the test suite with `./scripts/test.sh`** (optionally `--filter <name>`). **NOT plain `swift test`** — even though **Xcode 26.6 is installed**, `xcode-select` still points at Command Line Tools, so `swift test` still can't load the Swift Testing framework; the wrapper puts it on the search path/rpath. (After `sudo xcode-select -s /Applications/Xcode.app`, plain `swift test` may start working — verify before relying on it.) `swift build` and `swift run` work normally.
```

Change to:

```
- **Run the test suite with `./scripts/test.sh`** (optionally `--filter <name>`) — now a thin `exec swift test "$@"` passthrough; plain `swift test` also works (Xcode 26.6 is the active toolchain, so Swift Testing loads natively). `swift build`/`swift run` work normally.
```

Then update the SwiftUI-app convention bullet. Find:

```
- **The app uses the SwiftUI `App` lifecycle** (`@main struct PensieveApp: App`, single `Window` scene) — the framework hosts the window correctly, so the titlebar safe-area inset that once forced a manual `NSHostingController` is handled for free. **Unbundled-executable gotcha:** set `NSApplication.setActivationPolicy(.regular)` in the `AppDelegate` (`applicationWillFinishLaunching`) or the app has no Dock icon / ⌘-Tab entry / menu-bar ownership. The app icon is set at runtime via `applicationIconImage` until there's a real `.app` bundle.
```

Change to:

```
- **The app is a real `.app` bundle built by XcodeGen + Xcode** — `project.yml` (source of truth) defines a macOS app target linking PensieveKit as a local SwiftPM package. Build: `xcodegen generate` then `xcodebuild -project Pensieve.xcodeproj -scheme Pensieve -configuration Debug -derivedDataPath ./.build-xcode build`; the app lands at `./.build-xcode/Build/Products/Debug/Pensieve.app`. Smoke-launch the **inner binary** (`…/Contents/MacOS/Pensieve`) so `PENSIEVE_DB`/`PENSIEVE_CAPTURE_DB` env is forwarded. The bundle is `.regular` by default (no activation-policy workaround) and its icon is the bundled `icons/Pensieve.icon` compiled by `actool` (no runtime `applicationIconImage`). `Pensieve.xcodeproj/` + `.build-xcode/` are gitignored; regenerate with `xcodegen generate`. `swift run PensieveApp` no longer exists.
```

Then update the Build & test line that still says `swift run`. Find:

```
- Run the CLI: `swift run pensieve <subcommand>`. Tests/CLI honor `PENSIEVE_DB` and `PENSIEVE_CAPTURE_DB` env overrides to point at temp SQLite files.
```

Change to:

```
- Run the CLI: `swift run pensieve <subcommand>` (the CLI + PensieveKit stay a SwiftPM package). Tests/CLI honor `PENSIEVE_DB` and `PENSIEVE_CAPTURE_DB` env overrides to point at temp SQLite files. The **app** is built via Xcode (above), not `swift run`.
```

- [ ] **Step 5: Update the Status + Next in `CLAUDE.md`**

In `CLAUDE.md`, find the Xcode bullet:

```
- **Xcode 26.6 installed** (`/Applications/Xcode.app`) — but `xcode-select` still points at CommandLineTools, so it is **installed-not-active** (`xcodebuild`/`actool` still error until `sudo xcode-select -s /Applications/Xcode.app`). Unlocks the bundling / OS-integration path: `actool` + the full Icon Composer `.icon`, App Intents/Siri, WidgetKit, CloudKit.
```

Change to:

```
- **Xcode adoption — DONE** (merged): the app is now a real `Pensieve.app` bundle built by **XcodeGen** (`project.yml`) + Xcode 26.6 (active toolchain), linking PensieveKit as a local SwiftPM package; ad-hoc signed; bundled `icons/Pensieve.icon` via `actool`; `CFBundleName=Pensieve` fixes the menu title; the unbundled workarounds are gone. Spec/plan: `docs/superpowers/{specs,plans}/2026-07-06-xcode-adoption-app-bundle*`.
```

Then find the Next bullet:

```
- **Next (chosen): a packaging & OS-integration brainstorm** — a real `.app` bundle (fixes the app-menu title "PensieveApp"→"Pensieve" via `CFBundleName`, ships the bundled `.icon`), a menu-bar item, then OS surfaces (Siri/Shortcuts, Spotlight, Widgets, CloudKit). Keep **PensieveKit as an SPM package the Xcode app consumes** so adopting Xcode is additive, not a rewrite. **Also queued: three-pane app slices 3–6** — 3: inspector (⌘⌥I) + LLM "Last Work Done" narration + `ValueObservation` liveness; 4: organizing writes; 5: talk-to-system; 6: forks (gated on the unbuilt fork-capture backend). See `docs/superpowers/backlog.md` **Roadmap**.
```

Change to:

```
- **Next: the first OS-integration surfaces** (foundation now in place) — menu-bar item / `LSUIElement`, then Siri/Shortcuts (App Intents), Spotlight, Widgets, CloudKit, each its own spec. **Also queued: three-pane app slices 3–6** — 3: inspector (⌘⌥I) + LLM "Last Work Done" narration + `ValueObservation` liveness; 4: organizing writes; 5: talk-to-system; 6: forks (gated on the unbuilt fork-capture backend). See `docs/superpowers/backlog.md` **Roadmap**.
```

- [ ] **Step 6: Update `CONTINUE.md`**

In `CONTINUE.md`, replace the "Xcode is now installed" section and the "THE NEXT ACTION" section to reflect that adoption is done. Find the section header line:

```
## Xcode is now installed (changes the roadmap)
```

Replace that entire section (down to but not including the `## THE NEXT ACTION (start here)` header) with:

```
## Xcode adoption — DONE

The app is now a real **`Pensieve.app`** bundle: **XcodeGen** (`project.yml`, the source of truth) + Xcode
26.6 (active — `xcode-select` → `/Applications/Xcode.app`), app target linking **PensieveKit as a local
SwiftPM package**, ad-hoc signed, bundled `icons/Pensieve.icon` via `actool`, `CFBundleName=Pensieve`. The
unbundled workarounds (setActivationPolicy, runtime applicationIconImage, AppDelegate) are gone. Build:
`xcodegen generate` → `xcodebuild -project Pensieve.xcodeproj -scheme Pensieve -configuration Debug
-derivedDataPath ./.build-xcode build`; app at `./.build-xcode/Build/Products/Debug/Pensieve.app`; smoke-launch
the inner binary (`…/Contents/MacOS/Pensieve`). `Pensieve.xcodeproj/` + `.build-xcode/` are gitignored.
`swift test` now works natively (`scripts/test.sh` is a thin passthrough). The `pensieve` CLI + daemon are
unchanged — no reinstall needed.
```

Then find the next-action header + its first paragraph:

```
## THE NEXT ACTION (start here)

**A packaging & OS-integration brainstorm** (the user's chosen next, now that Xcode is in). Scope to settle:
```

Change to:

```
## THE NEXT ACTION (start here)

**The first OS-integration surface(s)** — the Xcode/bundle foundation is in place. Scope to settle:
```

- [ ] **Step 7: Commit**

```bash
git add scripts/test.sh CLAUDE.md CONTINUE.md
git commit -F - <<'EOF'
docs: Xcode workflow + retire the CLT-only test wrapper

Simplify scripts/test.sh to a plain `swift test` passthrough (Swift Testing
loads natively under the active Xcode toolchain). Rewrite the now-false
"NOT plain swift test / CommandLineTools-only" gotcha, document the
xcodegen/xcodebuild app workflow (swift run PensieveApp is gone), and update
Status/Next to mark Xcode adoption done with OS-integration surfaces next.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01GsAu7rTTdD77k3xZHZrhm4
EOF
```

---

## Final acceptance checklist (user-run, interactive)

Automated steps confirm build + no-crash launch + tests. These need a human at the keyboard — build and launch the app (throwaway store) and confirm:

- [ ] `Pensieve.app` launches; window appears, centered, ~900×560.
- [ ] **App-menu title reads "Pensieve"** (not "PensieveApp").
- [ ] **The artwork icon shows in the Dock and in Finder** (Task 2).
- [ ] App owns the menu bar / appears in ⌘-Tab **without** the old activation workaround.
- [ ] ⌘Q / ⌘K / ⌘R / ⌃⌘S work; window frame restores across quit/relaunch.
- [ ] `git status` clean (no `Pensieve.xcodeproj/` or `.build-xcode/` tracked).

---

## Self-review notes

- **Spec coverage:** Prerequisite/toolchain gate → Task 1 Step 1; drop SPM app target → T1 S4; `project.yml` + local package + ad-hoc signing → T1 S2; `.gitignore` → T1 S3; remove workarounds (Bundle.module/activation/AppDelegate) → T1 S5–6; menu title (PRODUCT_NAME→CFBundleName) → T1 S9; bundled `.icon` via actool + APPICON_NAME → T2; docs + test.sh rewrite → T3. All spec §§1–6 + risks covered.
- **No app unit tests** (convention) — verification is build + smoke-launch + `./scripts/test.sh`, per Global Constraints.
- **Type/name consistency:** `Pensieve` scheme/target/PRODUCT_NAME, `me.mazetti.pensieve`, `ASSETCATALOG_COMPILER_APPICON_NAME: Pensieve` (matches `Pensieve.icon` basename), `./.build-xcode/Build/Products/Debug/Pensieve.app` used consistently across tasks.
- **Icon isolated in Task 2** so the one validated-first unknown has its own reviewable gate; Task 1 leaves a working (generic-icon) app.
