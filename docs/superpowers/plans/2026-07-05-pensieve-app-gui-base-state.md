# Pensieve.app GUI Base-State Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace Pensieve.app's raw imperative `NSApplication` bootstrap with the first-party SwiftUI `App` lifecycle so it gains a standard menu bar, working ⌘Q, window sizing, and automatic frame restoration — a usable native base state before slice 3.

**Architecture:** Adopt `@main struct PensieveApp: App` with a single `Window` scene (macOS's correct primitive for one unique window). The standard menu bar, ⌘Q/⌘W/⌘M, activation, and scene-based restoration come free from the framework. Custom commands (⌘K Quick Jump, ⌘R Refresh) go in a `.commands` block; the ⌘K palette state moves from a hidden-button hack in `RootView` onto `AppModel`. Pure wiring — no PensieveKit/derivation/trust-gate changes.

**Tech Stack:** Swift 6, SwiftUI `App`/`Scene`, SQLiteData (unchanged), SwiftPM executable target (`swift run PensieveApp`).

**Spec:** `docs/superpowers/specs/2026-07-05-pensieve-app-gui-base-state-design.md`

## Global Constraints

- **Platform target: macOS 14** (`Package.swift` `platforms: [.macOS(.v14)]`). `Window(_:id:)`, `SidebarCommands()`, `.defaultSize`, `.windowResizability` are all available on 14.
- **The app target has NO unit tests** (executable target, not covered by `PensieveKitTests`). Verify app changes with `swift build` + a **non-blocking** background smoke-launch (`swift run PensieveApp` blocks on the run loop — background it and `kill` after a few seconds; never foreground it). No new PensieveKit tests are added — this slice moves no logic into PensieveKit.
- **Do NOT perturb the live store.** Every smoke-launch sets throwaway `PENSIEVE_DB` / `PENSIEVE_CAPTURE_DB` (a `/tmp` path). Never run the app against the real store during development.
- **All 138 existing PensieveKit tests must stay green** — run `./scripts/test.sh` (NOT `swift test`; this machine is Command Line Tools–only).
- **Commit messages:** backticks inside a double-quoted `git commit -m "…"` get shell-executed — use the `git commit -F` heredoc form shown in each Commit step. Keep the `Co-Authored-By:` / `Claude-Session:` trailers.
- **Keep views thin; do not move logic into PensieveKit** (there is none to move — this is scene/menu wiring).
- If a build dies with a SwiftSyntax/macro linker error, `rm -rf .build` and retry (disk runs tight).

---

## File Structure

- **Rename:** `Sources/PensieveApp/main.swift` → `Sources/PensieveApp/PensieveApp.swift` — a `@main`-bearing file cannot be named `main.swift` (that name implies top-level executable code). Holds the `Stores` enum (unchanged) and the new `PensieveApp: App` scene.
- **Modify:** `Sources/PensieveApp/AppModel.swift` — idempotent `start()` guard (Task 1); add `@Published var showPalette` and `refreshNow()` (Task 2).
- **Modify:** `Sources/PensieveApp/RootView.swift` — drop the hidden ⌘K button + local `@State`, bind the palette sheet to `AppModel` (Task 2).

Two tasks: **Task 1** retires the safe-area risk with the minimal scene migration (per spec §7, before any menu work); **Task 2** adds the menu commands and removes the palette hack.

---

## Task 1: Adopt the SwiftUI `App` lifecycle (minimal scene migration)

Replace the imperative bootstrap with a `Window` scene wrapping the existing `RootView`. This alone delivers the standard menu bar, ⌘Q, window sizing, and automatic frame restoration. **No `.commands` yet** — `RootView`'s existing hidden ⌘K button still carries the palette, so the app stays fully working. This task exists first to **retire the titlebar safe-area risk** (spec §7) before investing in menus.

**Files:**
- Rename: `Sources/PensieveApp/main.swift` → `Sources/PensieveApp/PensieveApp.swift`
- Modify: `Sources/PensieveApp/AppModel.swift` (idempotent `start()` guard)

**Interfaces:**
- Consumes: `AppModel()` init + `AppModel.start()` (existing); `RootView(model:)` (existing).
- Produces: `struct PensieveApp: App` (the `@main` entry point). `AppModel.start()` becomes idempotent (safe to call more than once).

- [ ] **Step 1: Make `AppModel.start()` idempotent**

In `Sources/PensieveApp/AppModel.swift`, add a `started` flag next to the other private stored properties. Find:

```swift
  private var db: (any DatabaseWriter)?
  private var allNodes: [Node] = []
  private var timer: Timer?
```

Change to:

```swift
  private var db: (any DatabaseWriter)?
  private var allNodes: [Node] = []
  private var timer: Timer?
  private var started = false
```

Then guard `start()`. Find:

```swift
  func start() {
    // Open the canonical store read/write (needed for the launch drain). Missing store degrades to empty.
    db = try? openCanonicalDatabase(at: Stores.canonicalURL)
```

Change to:

```swift
  func start() {
    guard !started else { return }
    started = true
    // Open the canonical store read/write (needed for the launch drain). Missing store degrades to empty.
    db = try? openCanonicalDatabase(at: Stores.canonicalURL)
```

- [ ] **Step 2: Rename `main.swift` to `PensieveApp.swift`**

Run:

```bash
cd /Users/moritz/Projects/pensieve
git mv Sources/PensieveApp/main.swift Sources/PensieveApp/PensieveApp.swift
```

- [ ] **Step 3: Replace the imperative bootstrap with the `App` scene**

Overwrite `Sources/PensieveApp/PensieveApp.swift` with (the `Stores` enum is carried over unchanged; the imperative `NSApplication`/`NSWindow`/`app.run()` block is deleted; `import AppKit` is no longer needed):

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
    // A single unique window — the correct primitive for one main window. Multi-window/tabbing is
    // slice 3's job; `Window` gives the standard menu bar, ⌘Q, and scene frame restoration for free.
    Window("Pensieve", id: "main") {
      RootView(model: model)
        .frame(minWidth: 720, minHeight: 420)
        .task { model.start() }   // idempotent (guarded in AppModel)
    }
    .defaultSize(width: 900, height: 560)
    .windowResizability(.contentMinSize)
  }
}
```

- [ ] **Step 4: Build**

Run: `cd /Users/moritz/Projects/pensieve && swift build 2>&1 | tail -20`
Expected: `Build complete!` (no errors). If a SwiftSyntax/macro linker error appears, `rm -rf .build` and retry.

- [ ] **Step 5: Smoke-launch and verify it starts without crashing (against a throwaway store)**

Run:

```bash
cd /Users/moritz/Projects/pensieve
env PENSIEVE_DB=/tmp/pensieve-smoke.sqlite PENSIEVE_CAPTURE_DB=/tmp/pensieve-smoke-capture.sqlite \
  swift run PensieveApp > /tmp/pensieve-smoke.log 2>&1 &
APP_PID=$!
sleep 8
if kill "$APP_PID" 2>/dev/null; then echo "LAUNCH-OK (process was alive)"; else echo "CRASHED — see log"; fi
cat /tmp/pensieve-smoke.log
```

Expected: `LAUNCH-OK (process was alive)` and a log with no Swift crash/fatalError. A window titled "Pensieve" appears during the 8 s.

- [ ] **Step 6: VERIFY THE SAFE-AREA (spec §7 — the one real risk)**

While the app is running (re-launch it in the background if needed, same env vars), visually confirm the **full-height sidebar clears the traffic-light chrome** — the top of the sidebar's first row must sit *below* the close/minimize/zoom buttons, not scroll under them. This was the bug that originally forced the manual `NSHostingController`.

- If it is correct → the risk is retired; continue.
- If the sidebar scrolls under the traffic lights → **STOP and escalate.** The fallback (spec §7) is adding an `NSApplicationDelegateAdaptor` to nudge the window while keeping the `App` lifecycle — do **not** revert to a manual menu bar. Flag this to the reviewer before proceeding.

- [ ] **Step 7: Confirm the existing test suite is still green**

Run: `cd /Users/moritz/Projects/pensieve && ./scripts/test.sh 2>&1 | tail -5`
Expected: all 138 tests pass (no failures).

- [ ] **Step 8: Commit**

```bash
cd /Users/moritz/Projects/pensieve
git add Sources/PensieveApp/PensieveApp.swift Sources/PensieveApp/AppModel.swift
git commit -F - <<'EOF'
feat(app): adopt SwiftUI App lifecycle (single Window scene)

Replace the imperative NSApplication/NSWindow/app.run() bootstrap with
@main struct PensieveApp: App and a single Window scene. Gives the standard
macOS menu bar, working Quit, window default/min size, and automatic
scene-based frame restoration for free. start() is now idempotent so the
.task invocation is safe. Sidebar safe-area verified (clears the titlebar).

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01GsAu7rTTdD77k3xZHZrhm4
EOF
```

---

## Task 2: Menu commands + retire the palette hack

Add the `.commands` block (Show/Hide Sidebar, plus a "Go" menu with ⌘K Quick Jump and ⌘R Refresh) and hoist the palette state from `RootView`'s hidden button onto `AppModel`, so ⌘K becomes a discoverable menu item.

**Files:**
- Modify: `Sources/PensieveApp/AppModel.swift` (add `showPalette`, `refreshNow()`)
- Modify: `Sources/PensieveApp/RootView.swift` (drop hidden button + local `@State`, bind sheet to `AppModel`)
- Modify: `Sources/PensieveApp/PensieveApp.swift` (add `.commands`)

**Interfaces:**
- Consumes: `struct PensieveApp: App` and `AppModel.start()` (Task 1); `AppModel.drainThenRefresh()` (existing private); `PaletteView(model:isPresented:)` (existing, takes `isPresented: Binding<Bool>`).
- Produces: `AppModel.showPalette: Bool` (`@Published`); `AppModel.refreshNow() async`. `RootView` no longer owns palette state.

- [ ] **Step 1: Add `showPalette` and `refreshNow()` to `AppModel`**

In `Sources/PensieveApp/AppModel.swift`, add the published flag. Find:

```swift
  @Published var briefingCards: [BriefingCard] = []
```

Add directly after it:

```swift
  @Published var briefingCards: [BriefingCard] = []
  /// Drives the ⌘K Quick Jump palette. Hoisted here (from RootView @State) so the "Go" menu command
  /// can open it.
  @Published var showPalette = false
```

Then add an on-demand refresh for the ⌘R command. Find the existing private `drainThenRefresh()`:

```swift
  private func drainThenRefresh() async {
    if let db, let spool = try? CaptureSpool(at: Stores.spoolURL) {
      _ = try? await Ingester(spool: spool, db: db).drain()   // no LLM: spool → events only
    }
    refresh()
  }
```

Add this method directly above it:

```swift
  /// On-demand equivalent of the launch drain+refresh, for the ⌘R Refresh menu command.
  func refreshNow() async { await drainThenRefresh() }

  private func drainThenRefresh() async {
    if let db, let spool = try? CaptureSpool(at: Stores.spoolURL) {
      _ = try? await Ingester(spool: spool, db: db).drain()   // no LLM: spool → events only
    }
    refresh()
  }
```

- [ ] **Step 2: Remove the hidden ⌘K button from `RootView`; bind the sheet to `AppModel`**

Overwrite `Sources/PensieveApp/RootView.swift` with:

```swift
// Sources/PensieveApp/RootView.swift
import SwiftUI
import PensieveKit

struct RootView: View {
  @ObservedObject var model: AppModel

  var body: some View {
    NavigationSplitView {
      SidebarView(model: model)
        .navigationSplitViewColumnWidth(min: 200, ideal: 240)
    } content: {
      ContentListView(model: model)
        .navigationSplitViewColumnWidth(min: 240, ideal: 300)
    } detail: {
      if let id = model.selectedNodeID, let node = model.node(id) {
        DetailView(model: model, node: node)
      } else if model.sidebarSelection == .briefing {
        BriefingView(model: model)
      } else {
        ContentUnavailableView("Select a project", systemImage: "sidebar.left")
      }
    }
    .navigationTitle("Pensieve")
    // ⌘K now lives in the "Go" menu (see PensieveApp.commands); the palette state lives on AppModel.
    .sheet(isPresented: $model.showPalette) {
      PaletteView(model: model, isPresented: $model.showPalette)
    }
  }
}
```

- [ ] **Step 3: Add the `.commands` block to the scene**

In `Sources/PensieveApp/PensieveApp.swift`, extend the scene. Find:

```swift
    .defaultSize(width: 900, height: 560)
    .windowResizability(.contentMinSize)
  }
}
```

Change to:

```swift
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

- [ ] **Step 4: Build**

Run: `cd /Users/moritz/Projects/pensieve && swift build 2>&1 | tail -20`
Expected: `Build complete!` (no errors).

- [ ] **Step 5: Smoke-launch without crashing (throwaway store)**

Run:

```bash
cd /Users/moritz/Projects/pensieve
env PENSIEVE_DB=/tmp/pensieve-smoke.sqlite PENSIEVE_CAPTURE_DB=/tmp/pensieve-smoke-capture.sqlite \
  swift run PensieveApp > /tmp/pensieve-smoke.log 2>&1 &
APP_PID=$!
sleep 8
if kill "$APP_PID" 2>/dev/null; then echo "LAUNCH-OK (process was alive)"; else echo "CRASHED — see log"; fi
cat /tmp/pensieve-smoke.log
```

Expected: `LAUNCH-OK` and no crash in the log.

- [ ] **Step 6: Confirm the test suite is still green**

Run: `cd /Users/moritz/Projects/pensieve && ./scripts/test.sh 2>&1 | tail -5`
Expected: all 138 tests pass.

- [ ] **Step 7: Commit**

```bash
cd /Users/moritz/Projects/pensieve
git add Sources/PensieveApp/AppModel.swift Sources/PensieveApp/RootView.swift Sources/PensieveApp/PensieveApp.swift
git commit -F - <<'EOF'
feat(app): menu commands (Show/Hide Sidebar, Quick Jump ⌘K, Refresh ⌘R)

Add a .commands block: SidebarCommands() plus a "Go" menu with Quick Jump (⌘K)
and Refresh (⌘R). Hoist the palette's showPalette state from RootView's hidden
zero-size shortcut button onto AppModel so the menu item can open it, and add
AppModel.refreshNow() for on-demand drain+refresh. Removes the hidden-button
hack; ⌘K is now discoverable in the menu bar.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01GsAu7rTTdD77k3xZHZrhm4
EOF
```

---

## Task 3: App icon (runtime Dock icon)

User-requested add-on. Set the running app's Dock/⌘-Tab icon from the artwork in `icons/` via the first-party `NSApplication.applicationIconImage`, shipped as a SwiftPM resource. The app is an **unbundled** SwiftPM executable (no `.app` bundle / asset catalog), so this runtime path is the correct way to set the icon now; the fully bundled `.icon` (Finder icon, all appearances, shown when not running) arrives with the deferred v0.2 bundling pillar, which will consume `icons/Pensieve.icon` as its source.

**Files:**
- Create: `Sources/PensieveApp/Resources/AppIcon.png` (copy of `icons/Pensieve Exports/Pensieve-iOS-Default-1024@1x.png`)
- Modify: `Package.swift` (add `resources:` to the `PensieveApp` target)
- Modify: `Sources/PensieveApp/PensieveApp.swift` (add `import AppKit`, an `AppDelegate`, and the `@NSApplicationDelegateAdaptor`)
- Also commit: the `icons/` source folder (artwork source-of-truth for v0.2 bundling)

**Interfaces:**
- Consumes: `struct PensieveApp: App` (Task 1). `Bundle.module` (synthesized once the target has resources).
- Produces: a Dock icon at runtime. No new public API other tasks depend on.

- [ ] **Step 1: Copy the artwork into the app target's resources**

Run:

```bash
cd /Users/moritz/Projects/pensieve-gui-base
mkdir -p Sources/PensieveApp/Resources
cp "icons/Pensieve Exports/Pensieve-iOS-Default-1024@1x.png" Sources/PensieveApp/Resources/AppIcon.png
ls -la Sources/PensieveApp/Resources/AppIcon.png
```

Expected: the file exists (~1 MB PNG).

- [ ] **Step 2: Declare the resource in `Package.swift`**

In `Package.swift`, find:

```swift
    .executableTarget(
      name: "PensieveApp",
      dependencies: ["PensieveKit"]
    ),
```

Change to:

```swift
    .executableTarget(
      name: "PensieveApp",
      dependencies: ["PensieveKit"],
      resources: [.copy("Resources/AppIcon.png")]
    ),
```

- [ ] **Step 3: Set the icon at launch via an app delegate**

In `Sources/PensieveApp/PensieveApp.swift`, add `import AppKit` at the top of the import block:

```swift
import AppKit
import Foundation
import SwiftUI
import PensieveKit
```

Then, directly above `@main struct PensieveApp: App {`, add the delegate:

```swift
/// Sets the Dock / ⌘-Tab icon at launch. Pensieve.app is an unbundled SwiftPM executable (no .app
/// bundle, so no asset-catalog icon yet — that arrives with the v0.2 bundling step). `applicationIconImage`
/// is the first-party way to set the running app's icon in the meantime; the artwork ships as a
/// SwiftPM resource loaded via `Bundle.module`.
final class AppDelegate: NSObject, NSApplicationDelegate {
  func applicationDidFinishLaunching(_ notification: Notification) {
    if let url = Bundle.module.url(forResource: "AppIcon", withExtension: "png"),
       let image = NSImage(contentsOf: url) {
      NSApplication.shared.applicationIconImage = image
    }
  }
}
```

Then wire the delegate into the scene by adding the adaptor property. Find:

```swift
@main
struct PensieveApp: App {
  // One AppModel for the app's lifetime. Its init reads/writes the lastOpenedAt UserDefault.
  @StateObject private var model = AppModel()
```

Change to:

```swift
@main
struct PensieveApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
  // One AppModel for the app's lifetime. Its init reads/writes the lastOpenedAt UserDefault.
  @StateObject private var model = AppModel()
```

- [ ] **Step 4: Build**

Run: `cd /Users/moritz/Projects/pensieve-gui-base && swift build 2>&1 | tail -20`
Expected: `Build complete!` (no errors). If a SwiftSyntax/macro **linker** error appears, `rm -rf .build` and retry.

- [ ] **Step 5: Smoke-launch without crashing (throwaway store)**

Run:

```bash
cd /Users/moritz/Projects/pensieve-gui-base
env PENSIEVE_DB=/tmp/pensieve-smoke.sqlite PENSIEVE_CAPTURE_DB=/tmp/pensieve-smoke-capture.sqlite \
  swift run PensieveApp > /tmp/pensieve-smoke.log 2>&1 &
APP_PID=$!
sleep 8
if kill "$APP_PID" 2>/dev/null; then echo "LAUNCH-OK (process was alive)"; else echo "CRASHED — see log"; fi
cat /tmp/pensieve-smoke.log
```

Expected: `LAUNCH-OK` and no crash in the log. (The Dock icon itself is verified visually by the controller/user — see the acceptance checklist.)

- [ ] **Step 6: Confirm the test suite is still green**

Run: `cd /Users/moritz/Projects/pensieve-gui-base && ./scripts/test.sh 2>&1 | tail -5`
Expected: all 138 tests pass.

- [ ] **Step 7: Commit**

```bash
cd /Users/moritz/Projects/pensieve-gui-base
git add Package.swift Sources/PensieveApp/PensieveApp.swift Sources/PensieveApp/Resources/AppIcon.png icons
git commit -F - <<'EOF'
feat(app): Dock icon at runtime via applicationIconImage

Ship the app artwork (icons/) and set the running app's Dock / ⌘-Tab icon at
launch through an NSApplicationDelegate + @NSApplicationDelegateAdaptor, loading
the 1024 PNG as a SwiftPM resource (Bundle.module). The app is still an unbundled
executable, so this is the first-party way to set its icon; the fully bundled
.icon (Finder, all appearances) comes with the v0.2 bundling step, which will
consume icons/Pensieve.icon as its source.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01GsAu7rTTdD77k3xZHZrhm4
EOF
```

---

## Final acceptance checklist (user-run, interactive)

Automated smoke-launches only confirm the app builds and starts without crashing. These interactive behaviors need a human at the keyboard — run the app once (throwaway store) and confirm:

- [ ] Window appears, centered, ~900×560.
- [ ] **The Dock / ⌘-Tab icon shows the Pensieve artwork** (Task 3).
- [ ] **Sidebar clears the traffic lights** (safe-area — the §7 check).
- [ ] Menu bar shows Pensieve / File / Edit / View / Window / Help.
- [ ] **⌘Q quits** the app.
- [ ] **⌘K** opens the Quick Jump palette; **Go ▸ Quick Jump…** does the same.
- [ ] **View ▸ Show/Hide Sidebar (⌃⌘S)** toggles the sidebar.
- [ ] **⌘R** triggers a refresh (no crash; counts/lists update).
- [ ] Resize the window, **⌘Q, relaunch → the frame is restored**.
- [ ] The window cannot be resized below ~720×420.

---

## Self-review notes

- **Spec coverage:** §1 bootstrap→App (Task 1); §2 `Window` scene (Task 1); §3 menus incl. `SidebarCommands`/Go/⌘K/⌘R (Task 2); §4 `showPalette` hoist (Task 2); §5 idempotent `start()` + `refreshNow()` (Tasks 1–2); §6 sizing/restoration (Task 1 scene); §7 safe-area check (Task 1 Step 6, before menu work). All covered.
- **No new PensieveKit tests:** intentional — no logic moves into PensieveKit (spec Testing section + Global Constraints).
- **Type consistency:** `showPalette` (`AppModel`, `Bool`), `refreshNow()` (`async`), `drainThenRefresh()` (existing private), `PaletteView(model:isPresented:)` binding, `RootView(model:)` — names match across tasks and existing code.
