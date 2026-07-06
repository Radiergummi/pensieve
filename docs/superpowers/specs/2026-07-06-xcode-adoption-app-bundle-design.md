# Xcode adoption + real `Pensieve.app` bundle — design (2026-07-06)

The **foundation** for Pensieve's packaging & OS-integration roadmap: move the `PensieveApp` target off
the unbundled SwiftPM executable and onto a proper, `actool`-built **`Pensieve.app`** produced by an
**XcodeGen**-generated Xcode project that consumes **PensieveKit as a local SwiftPM package**. This is
the one-time build-system adoption that later surfaces (Siri/App Intents, Widgets, Spotlight, CloudKit,
menu-bar item) all depend on — it is *not* those surfaces, each of which gets its own spec.

Chosen approach: **A** — adopt Xcode now (over a hand-rolled bundling script that would dead-end at the
first Xcode-gated surface). Project generation: **XcodeGen** (declarative `project.yml`, agent-maintainable,
git-clean). Signing: **ad-hoc** ("sign to run locally").

> **Revised 2026-07-06 after two independent adversarial spec reviews** (build-system + icon/toolchain
> lenses). Their empirically-verified findings are folded in: the real toolchain-activation steps (a bare
> `xcode-select` is not enough — `actool` failed to launch until `-runFirstLaunch`), the app-icon target
> wiring, the signing-settings contradiction, and the `swift test`/`test.sh` inversion after the switch.

## Why now / why this shape

- The app is a personal, non-distributed macOS tool run on the author's own Mac (macOS 26.5.2).
- Xcode 26.6 is installed but **not active** (`xcode-select` still points at CommandLineTools) **and never
  first-launched** (so `actool`/`xcodebuild` don't run yet — see Prerequisite).
- The unbundled executable has real, papered-over defects a bundle fixes for free: the app-menu title
  reads the process name ("PensieveApp"), there is no Finder icon, and the app needed an explicit
  `setActivationPolicy(.regular)` workaround to get a Dock/⌘-Tab/menu-bar at all.
- Keeping **PensieveKit an SPM package** means adopting Xcode is *additive*: the tested core (138 tests),
  the `pensieve` CLI, and the launchd dogfooding deploy are untouched; Xcode wraps only the app shell.

## Scope

**In:**
- Activate + first-launch Xcode (user-run sudo — a documented prerequisite, not an agent step).
- Remove the `PensieveApp` executable target + product from `Package.swift` (package keeps PensieveKit
  lib + `pensieve` CLI + test target).
- Add `project.yml` (XcodeGen) defining one `Pensieve` macOS app target depending on the local PensieveKit
  package; gitignore the generated `Pensieve.xcodeproj` and the pinned Xcode build dir.
- Ship the app icon as the bundled Icon Composer `.icon` (`icons/Pensieve.icon`) compiled by `actool`,
  replacing the runtime `applicationIconImage`.
- Remove the now-unnecessary / now-uncompilable workarounds: `setActivationPolicy(.regular)`, the runtime
  icon (`applicationIconImage` + `Resources/AppIcon.png` + the Package resource decl), and — once both are
  gone — the empty `AppDelegate` + `@NSApplicationDelegateAdaptor`.
- `Info.plist` metadata: `CFBundleName = "Pensieve"` (via `PRODUCT_NAME`; fixes the menu title),
  `CFBundleIdentifier = me.mazetti.pensieve`, `LSMinimumSystemVersion = 14.0`.
- Update build/run/test docs (`CLAUDE.md`, `CONTINUE.md`) to the Xcode workflow, **including rewriting the
  now-false "NOT plain `swift test` / CommandLineTools-only" gotcha** and retiring/simplifying `scripts/test.sh`.

**Out (each its own later spec):** menu-bar item / `LSUIElement`; Siri/App Intents; WidgetKit; Core
Spotlight; CloudKit; personal-team / paid signing; dynamic Liquid-Glass icon tuning beyond what the
`.icon` carries; any change to PensieveKit logic, the CLI, the daemon, capture/ingest, or the trust gate.

## Prerequisite (user-run, documented — NOT agent steps; all need `sudo`)

A bare `xcode-select -s` is **not** sufficient: a freshly-installed Xcode that has never been first-launched
cannot run `actool`/`xcodebuild` (the adversarial review empirically hit
`"A required plugin failed to load … try running 'xcodebuild -runFirstLaunch'"`). The full activation is:

```
sudo xcode-select -s /Applications/Xcode.app
sudo xcodebuild -runFirstLaunch     # installs the IB/actool plugins + system components
sudo xcodebuild -license accept     # clears the EULA gate
```

All build steps below assume these are done. The **first plan task is a hard gate** that *actually runs*
`xcodebuild -version` **and** `actool --version` (and `xcodegen --version`) and **stops with a clear message
if any is non-zero** — it must NOT merely check where `xcode-select -p` points (that check passes while
`actool` is still dead). After activation, re-verify the test flow (see §6 / Testing).

## Design

### 1. Package: drop the app target

`Package.swift` declares three products (`PensieveKit` lib, `pensieve` CLI, `PensieveApp` executable) and
matching targets. Remove **only** the `PensieveApp` product and its `.executableTarget` (including the
`resources:` entry added for the runtime icon). The `Sources/PensieveApp/` files remain on disk — they
become the Xcode target's sources (§2). PensieveKit, the CLI, and `PensieveKitTests` are unchanged.
Confirmed by review: nothing else in the package graph depends on `PensieveApp`, so the package still
builds and `./scripts/test.sh` is unaffected. **Coupled ordering:** an Xcode app target has no
SPM-synthesized `Bundle.module`, so the `Bundle.module.url(...)` icon load in `PensieveApp.swift` *must* be
removed in the same change (§4) or the Xcode target won't compile.

### 2. `project.yml` (XcodeGen) — the project source of truth

A committed `project.yml` at repo root defines the app target. Exact keys validated against XcodeGen
2.45.4 during implementation; shape:

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
      - icons/Pensieve.icon        # MUST be a target build input or actool has nothing to compile
    dependencies:
      - package: PensieveKit
        product: PensieveKit
    settings:
      base:
        PRODUCT_NAME: Pensieve                 # → CFBundleName → the app-menu bold title
        PRODUCT_BUNDLE_IDENTIFIER: me.mazetti.pensieve
        ASSETCATALOG_COMPILER_APPICON_NAME: Pensieve   # names the .icon (basename "Pensieve")
        GENERATE_INFOPLIST_FILE: "YES"
        MARKETING_VERSION: "0.2"
        # Ad-hoc "sign to run locally": ALLOWED=YES so xcodebuild actually seals the bundle
        # with the ad-hoc identity; REQUIRED=NO so a missing team is not fatal. (entitlements
        # are independent of signing — none are needed for the foundation.)
        CODE_SIGN_IDENTITY: "-"
        CODE_SIGNING_ALLOWED: "YES"
        CODE_SIGNING_REQUIRED: "NO"
```

- **Local package dep** (`packages.PensieveKit.path: .`) links the same PensieveKit built from this repo.
  Xcode *resolves* the whole manifest (including the CLI's `swift-argument-parser`) but only *builds* the
  `PensieveKit` product the app links — the `pensieve` executable target is not built. Expect a one-time
  argument-parser resolve/fetch; no breakage. `project.yml` + `Package.swift` sharing the repo root is a
  standard, working XcodeGen pattern.
- The generated `Pensieve.xcodeproj` is **gitignored**; `xcodegen generate` reproduces it. `project.yml` is
  what git tracks. Also gitignore the pinned build dir (§6).

### 3. App icon — the bundled `.icon` via `actool`

The Icon Composer source `icons/Pensieve.icon` (repo root; `icon.json` + `Assets/Image.png`, git-tracked)
becomes the real app icon, compiled into the bundle by `actool`. Wiring (per Apple's "Creating your app
icon using Icon Composer" + confirmations in review): the `.icon` is a **target build input** (added to
`sources`, §2) and **`ASSETCATALOG_COMPILER_APPICON_NAME` names it** (`Pensieve`, matching the file
basename). `actool` then emits both the layered macOS-26 `Assets.car` **and an automatically-generated
backward-compatible `.icns`** for older macOS — so **deployment target 14 is fully compatible** and needs
no manual icon work.

**Decision criterion (corrected from the first draft): the only real fork is "does `actool` run at all."**
- If the prerequisite first-launch succeeded, `actool` runs and the primary path gives the Dock + Finder
  icon (and the pre-26 `.icns`) for free — **no manual fallback needed**.
- The manual fallback (`sips` → `.iconset` with the standard 16/32/128/256/512 @1x/@2x names → `iconutil
  -c icns` → `CFBundleIconFile` pointing at the icns in `Resources/`) is a correct-but-redundant escape
  hatch, warranted **only** if `actool` cannot be made to run. The plan validates `actool` in task 1 and
  picks one path — it does not carry both.

The plan's early validation is therefore: after the toolchain gate, run a minimal `xcodegen generate` +
`xcodebuild build` and confirm the built `.app` contains a compiled `AppIcon`/`Assets.car` and the artwork
shows in Finder/Dock — before building anything else on top.

### 4. `PensieveApp.swift` cleanups (required + enabled by the bundle)

- **Remove the runtime icon** — delete the `applicationIconImage` load (which uses `Bundle.module`),
  `Sources/PensieveApp/Resources/AppIcon.png`, and the `resources:` declaration (dropped in §1). This is
  **load-bearing for compilation**, not optional polish: `Bundle.module` does not exist in an Xcode app
  target, so the app won't compile until this is gone.
- **Remove `setActivationPolicy(.regular)`** — a bundled app with no `LSUIElement` is `.regular` by default
  (Dock/⌘-Tab/menu-bar), including when the inner binary is exec'd directly (it reads its `Info.plist`).
  Verify at launch; restore only if empirically needed.
- With both gone the `AppDelegate` body is empty → **remove the `AppDelegate` class and the
  `@NSApplicationDelegateAdaptor` property** (confirmed: nothing else references them; no other adaptor).
  `PensieveApp.swift` returns to `Stores` + the `App`/`Window`/`.commands` scene; drop `import AppKit` if
  nothing else needs it.
- The `icons/` artwork stays in the repo, now consumed by the bundle (§2/§3), not copied into the target.

### 5. Info.plist / metadata

Via XcodeGen `GENERATE_INFOPLIST_FILE`:
- **`CFBundleName = Pensieve`** — auto-defaults to `$(PRODUCT_NAME)` (there is no `INFOPLIST_KEY_CFBundleName`
  setting); the macOS app-menu bold title reads `CFBundleName`, so setting `PRODUCT_NAME: Pensieve` is what
  fixes "PensieveApp" → "Pensieve". If for any reason the generated plist doesn't take, fall back to an
  explicit `Info.plist` with `CFBundleName`.
- `CFBundleIdentifier = me.mazetti.pensieve` (via `PRODUCT_BUNDLE_IDENTIFIER`).
- `LSMinimumSystemVersion = 14.0` (from the deployment target).

### 6. Build / run / test workflow (post-migration)

- **App build:** `xcodegen generate` (after any `project.yml` change) → `xcodebuild -project
  Pensieve.xcodeproj -scheme Pensieve -configuration Debug -derivedDataPath ./.build-xcode build`. Pinning
  `-derivedDataPath ./.build-xcode` makes the output path predictable
  (`./.build-xcode/Build/Products/Debug/Pensieve.app`); gitignore `.build-xcode/`.
- **App smoke-launch (non-blocking):** exec the **inner binary directly** so env is forwarded —
  `PENSIEVE_DB=/tmp/… PENSIEVE_CAPTURE_DB=/tmp/… ./.build-xcode/Build/Products/Debug/Pensieve.app/Contents/MacOS/Pensieve &` then `kill`. (Do **not** use `open -a`, which won't forward `PENSIEVE_DB`/`PENSIEVE_CAPTURE_DB`.)
  A bundled app exec'd directly still becomes `.regular`, so activation is correct without the workaround.
- **PensieveKit tests:** `./scripts/test.sh` (re-verify post-switch — its `-F` path becomes a harmless
  no-op under Xcode; plain `swift test` should also work natively now, so the wrapper can be simplified/
  retired as part of the docs task).
- **CLI + daemon:** unchanged — `swift build -c release`, `~/.local/bin/pensieve`, launchd agent.

## Testing & verification

The app target has **no unit tests** (project convention). No new PensieveKit tests (no logic moves into
the framework). Verification:

1. **Toolchain gate** (plan task 1): `xcodebuild -version`, `actool --version`, `xcodegen --version` all
   exit 0 — else stop with the Prerequisite instructions.
2. `./scripts/test.sh` → **138 tests green** (package intact after dropping the app target), re-confirmed
   under the now-active Xcode toolchain.
3. `xcodegen generate` produces `Pensieve.xcodeproj` from `project.yml` with no errors.
4. `xcodebuild … build` succeeds → a `Pensieve.app` bundle containing: `Info.plist` with
   `CFBundleName = Pensieve` and `CFBundleIdentifier = me.mazetti.pensieve`; a compiled app icon
   (`Assets.car`/`AppIcon`); and a **sealed ad-hoc signature** (`codesign -dv Pensieve.app` shows an ad-hoc
   signature — this now holds because `CODE_SIGNING_ALLOWED = YES`).
5. **Launch the `.app`** and confirm (screenshot + `osascript` frontmost check):
   - App-menu title reads **"Pensieve"** (not "PensieveApp").
   - The **artwork icon shows in the Dock and in Finder**.
   - Normal foreground app **without** the activation workaround (owns the menu bar, in ⌘-Tab).
   - `⌘Q` / `⌘K` / `⌘R` / `⌃⌘S` work; window frame restores across quit/relaunch.
6. `git status` clean of the generated project + build dir (both gitignored).

## Risks & mitigations

| Risk | Mitigation |
|---|---|
| Xcode installed but never first-launched → `actool`/`xcodebuild` fail (empirically hit) | Prerequisite adds `sudo xcodebuild -runFirstLaunch` + `-license accept`; task-1 gate runs `actool --version`/`xcodebuild -version` and stops on failure (not just `xcode-select -p`). |
| `.icon` omitted from the target → icon-less app ships silently | `icons/Pensieve.icon` added to target `sources` **and** `ASSETCATALOG_COMPILER_APPICON_NAME: Pensieve`; launch verification checks Finder/Dock icon. |
| Signing settings contradiction (`ALLOWED: NO` + identity `-` leaves bundle unsigned) | `CODE_SIGNING_ALLOWED: YES` + `CODE_SIGN_IDENTITY: "-"` + `CODE_SIGNING_REQUIRED: NO` → actually ad-hoc-seals the bundle; verification 4 checks `codesign -dv`. |
| Menu-title fix relied on a nonexistent `INFOPLIST_KEY_CFBundleName` | Driven by `PRODUCT_NAME` (→ `CFBundleName`); explicit `Info.plist` fallback if the generated plist doesn't take. |
| `Bundle.module` removal missed → Xcode target won't compile | §1/§4 make removing the runtime icon load-bearing and coupled to dropping the SPM target. |
| DerivedData path unpredictable for smoke-launch | Pin `-derivedDataPath ./.build-xcode`; exec the inner binary directly (forwards env). |
| `test.sh`/CLAUDE.md "can't use `swift test`" becomes false | Docs task rewrites the gotcha and simplifies/retires the wrapper; verification 2 re-confirms tests under Xcode. |
| XcodeGen key shape drift | `project.yml` above is a validated shape; task-1 smoke-`generate` catches drift immediately. |

## Docs to update (part of the work)

- `CLAUDE.md`: app is now an XcodeGen/Xcode `.app` (`xcodegen generate` + `xcodebuild -derivedDataPath
  ./.build-xcode`); Xcode active; **rewrite the "Build & test" gotcha** — `swift test` now works under Xcode,
  `scripts/test.sh` retired/simplified; the SwiftUI-app convention (no `swift run PensieveApp`; icon via the
  bundled `.icon` not runtime; activation-policy workaround retired).
- `CONTINUE.md`: foundation done; next = the first OS surface(s).
- `.gitignore`: `Pensieve.xcodeproj/` and `.build-xcode/`.
