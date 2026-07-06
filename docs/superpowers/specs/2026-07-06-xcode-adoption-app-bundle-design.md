# Xcode adoption + real `Pensieve.app` bundle — design (2026-07-06)

The **foundation** for Pensieve's packaging & OS-integration roadmap: move the `PensieveApp` target off
the unbundled SwiftPM executable and onto a proper, `actool`-built **`Pensieve.app`** produced by an
**XcodeGen**-generated Xcode project that consumes **PensieveKit as a local SwiftPM package**. This is
the one-time build-system adoption that later surfaces (Siri/App Intents, Widgets, Spotlight, CloudKit,
menu-bar item) all depend on — it is *not* those surfaces, each of which gets its own spec.

Chosen approach (see `CONTINUE.md` / prior brainstorm): **A** — adopt Xcode now (over a hand-rolled
bundling script that would dead-end at the first Xcode-gated surface). Project generation: **XcodeGen**
(declarative `project.yml`, agent-maintainable, git-clean). Signing: **ad-hoc** ("sign to run locally").

## Why now / why this shape

- The app is a personal, non-distributed macOS tool run on the author's own Mac (macOS 26.5.2).
- Xcode 26.6 is installed but **not active** (`xcode-select` still points at CommandLineTools).
- The unbundled executable has real, papered-over defects a bundle fixes for free: the app-menu title
  reads the process name ("PensieveApp"), there is no Finder icon, and the app needed an explicit
  `setActivationPolicy(.regular)` workaround to get a Dock/⌘-Tab/menu-bar at all.
- Keeping **PensieveKit an SPM package** means adopting Xcode is *additive*: the tested core (138 tests,
  `./scripts/test.sh`), the `pensieve` CLI, and the launchd dogfooding deploy are all untouched; Xcode
  wraps only the app shell.

## Scope

**In:**
- Activate Xcode (user-run `sudo xcode-select` — a documented prerequisite, not an implementation step).
- Remove the `PensieveApp` executable target + product from `Package.swift` (package keeps PensieveKit
  lib + `pensieve` CLI + test target).
- Add `project.yml` (XcodeGen) defining one `Pensieve` macOS app target that depends on the local
  PensieveKit package; gitignore the generated `Pensieve.xcodeproj`.
- Ship the app icon as the bundled Icon Composer `.icon` (`icons/Pensieve.icon`) compiled by `actool`,
  replacing the runtime `applicationIconImage`.
- Remove the now-unnecessary workarounds: `setActivationPolicy(.regular)`, the runtime icon
  (`applicationIconImage` + `Resources/AppIcon.png` + the Package resource decl), and — once both are
  gone — the empty `AppDelegate` + `@NSApplicationDelegateAdaptor`.
- `Info.plist` metadata: `CFBundleName = "Pensieve"` (fixes the menu title), `CFBundleIdentifier =
  me.mazetti.pensieve`, `LSMinimumSystemVersion = 14.0`.
- Update build/run/test docs (`CLAUDE.md`, `CONTINUE.md`, and the SwiftUI app conventions) to the Xcode
  workflow.

**Out (each its own later spec):**
- Menu-bar item / `LSUIElement` (the app stays a normal windowed, dock-present app).
- Siri / App Intents, WidgetKit, Core Spotlight, CloudKit.
- Personal-team / paid signing (ad-hoc suffices for a locally-built, locally-run app).
- Dynamic Liquid-Glass icon tuning beyond what the `.icon` already carries.
- Any change to PensieveKit logic, the CLI, the daemon, capture/ingest, or the trust gate.

## Prerequisite (user-run, documented — NOT an agent step)

```
sudo xcode-select -s /Applications/Xcode.app
```

`xcodebuild` and `actool` require the active developer directory to be Xcode; this needs `sudo` (a
password prompt an agent cannot drive). All build steps below assume it is done. After it, re-verify the
test flow: `./scripts/test.sh` still works (it reads `xcode-select -p`); plain `swift test` may now also
work — note which, don't assume.

## Design

### 1. Package: drop the app target

`Package.swift` currently declares three products (`PensieveKit` lib, `pensieve` CLI, `PensieveApp`
executable) and the matching targets. Remove **only** the `PensieveApp` product and its
`.executableTarget` (including the `resources:` entry added for the runtime icon). The `Sources/PensieveApp/`
files remain on disk — they become the Xcode target's sources (§2). PensieveKit, the CLI, and
`PensieveKitTests` are unchanged, so `./scripts/test.sh` and the CLI build/deploy are unaffected.

### 2. `project.yml` (XcodeGen) — the project source of truth

A committed `project.yml` at repo root defines the app target. Shape (exact keys validated during
implementation against XcodeGen 2.45.4):

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
        PRODUCT_BUNDLE_IDENTIFIER: me.mazetti.pensieve
        PRODUCT_NAME: Pensieve
        CODE_SIGN_IDENTITY: "-"          # ad-hoc "sign to run locally"
        CODE_SIGNING_REQUIRED: "NO"
        CODE_SIGNING_ALLOWED: "NO"       # foundation: no entitlements yet
        GENERATE_INFOPLIST_FILE: "YES"
        INFOPLIST_KEY_CFBundleDisplayName: Pensieve
        MARKETING_VERSION: "0.2"
        # app-icon wiring resolved in §3
```

- **Local package dep** (`packages.PensieveKit.path: .`) makes the app link the same PensieveKit built
  from this repo — one source of truth.
- The generated `Pensieve.xcodeproj` is **gitignored** (`echo "Pensieve.xcodeproj/" >> .gitignore`);
  `xcodegen generate` reproduces it. `project.yml` is what git tracks.

### 3. App icon — the bundled `.icon` via `actool` (primary), `.icns` fallback

The Icon Composer source `icons/Pensieve.icon` becomes the real app icon, compiled into the bundle by
`actool` (available once Xcode is active). **This is the main implementation unknown** — the exact way an
Icon Composer `.icon` is wired into an Xcode target (direct `.icon` reference vs. inside an
`.xcassets` app-icon set, and the driving build setting, e.g. `ASSETCATALOG_COMPILER_APPICON_NAME`) must
be validated **first** in the plan, before the rest is built on it.

- **Primary:** wire `Pensieve.icon` as the app icon through XcodeGen so `actool` compiles it; confirm the
  built `.app` shows the artwork in Finder and Dock.
- **Fallback (if the direct `.icon` path fights the toolchain):** generate a classic `Pensieve.icns` from
  the 1024 export with `sips` (resize to an `.iconset`) + `iconutil -c icns`, and set it via
  `CFBundleIconFile`. A static icon is an acceptable foundation result; the dynamic `.icon` can be
  revisited. The plan must pick primary-or-fallback based on the early validation, not carry both.

### 4. `PensieveApp.swift` cleanups (bundle removes the workarounds)

With a proper bundle:
- **Remove `setActivationPolicy(.regular)`** — a bundled app with no `LSUIElement` is `.regular` by
  default. Verify at launch (Dock/⌘-Tab/menu-bar present).
- **Remove the runtime icon** — delete the `applicationIconImage` load, `Sources/PensieveApp/Resources/
  AppIcon.png`, and the `resources:` declaration (already dropped in §1).
- With both gone the `AppDelegate` body is empty → **remove the `AppDelegate` class and the
  `@NSApplicationDelegateAdaptor` property**. `PensieveApp.swift` returns to `Stores` + the `App`/`Window`/
  `.commands` scene. `import AppKit` is dropped if nothing else needs it.
- The `icons/` artwork stays in the repo (now consumed by the bundle, not copied into the target).

### 5. Info.plist / metadata

Via XcodeGen `GENERATE_INFOPLIST_FILE` + `INFOPLIST_KEY_*` (or an explicit plist if a key isn't exposed):
- `CFBundleName = Pensieve` → app-menu title reads "Pensieve".
- `CFBundleIdentifier = me.mazetti.pensieve`.
- `LSMinimumSystemVersion = 14.0`.

### 6. Build / run / test workflow (post-migration)

- **App build:** `xcodegen generate` (after any `project.yml` change) → `xcodebuild -project
  Pensieve.xcodeproj -scheme Pensieve -configuration Debug build`. The built `Pensieve.app` lands in
  DerivedData (or a `-derivedDataPath`/`CONFIGURATION_BUILD_DIR` we pin for predictable smoke-launches).
- **App smoke-launch:** launch the built `Pensieve.app` (background + `kill`, throwaway
  `PENSIEVE_DB`/`PENSIEVE_CAPTURE_DB`) — the same non-blocking pattern, now against the `.app` instead of
  `swift run`.
- **PensieveKit tests:** unchanged — `./scripts/test.sh`.
- **CLI + daemon:** unchanged — `swift build -c release`, `~/.local/bin/pensieve`, launchd agent.

## Testing & verification

The app target has **no unit tests** (executable/app target, project convention). No new PensieveKit
tests (no logic moves into the framework). Verification:

1. `./scripts/test.sh` → **138 tests green** (package intact after dropping the app target).
2. `xcodegen generate` produces `Pensieve.xcodeproj` from `project.yml` with no errors.
3. `xcodebuild … build` succeeds → a `Pensieve.app` bundle exists containing: `Info.plist` with
   `CFBundleName = Pensieve` and `CFBundleIdentifier = me.mazetti.pensieve`; a compiled app icon
   (`Assets.car`/`AppIcon` or `Pensieve.icns`); an ad-hoc signature.
4. **Launch the `.app`** and confirm (screenshot + `osascript` frontmost check):
   - App-menu title reads **"Pensieve"** (not "PensieveApp").
   - The **artwork icon shows in the Dock and in Finder**.
   - App is a normal foreground app **without** the activation-policy workaround (owns the menu bar,
     appears in ⌘-Tab).
   - `⌘Q` / `⌘K` (Quick Jump) / `⌘R` (Refresh) / `⌃⌘S` (Show/Hide Sidebar) all work; window frame
     restores across quit/relaunch.
5. `git status` clean of the generated project (`.xcodeproj` gitignored).

## Risks & mitigations

| Risk | Mitigation |
|---|---|
| Icon Composer `.icon` → Xcode wiring is unfamiliar / toolchain-specific | **Validate first** (plan step 1). Fallback to a static `.icns` via `sips`+`iconutil` if the direct path fights us; pick one, don't carry both. |
| Removing `setActivationPolicy(.regular)` regresses Dock/menu-bar | Bundled apps are `.regular` by default; the launch verification (§ Testing 4) catches any surprise — restore only if empirically needed. |
| XcodeGen key names/shape drift from the sketch | The `project.yml` above is a shape, not gospel; validate against XcodeGen 2.45.4 during implementation. |
| `xcode-select` not switched → `xcodebuild`/`actool` error | Documented user-run prerequisite; the first plan task checks `xcode-select -p` points at Xcode and stops with a clear message otherwise. |
| Agents can't run `sudo` | The switch is explicitly a user step; everything agent-run assumes it's done. |
| Dropping the SPM app target breaks `swift run PensieveApp` muscle memory | Docs updated to the `xcodebuild` workflow; the app is now built through Xcode by design. |

## Docs to update (part of the work)

- `CLAUDE.md`: app is now an XcodeGen/Xcode `.app` (build via `xcodegen generate` + `xcodebuild`);
  Xcode active; the SwiftUI-app convention (no more `swift run PensieveApp`; icon via bundle not runtime;
  activation-policy workaround retired).
- `CONTINUE.md`: foundation done; next = the first OS surface(s).
