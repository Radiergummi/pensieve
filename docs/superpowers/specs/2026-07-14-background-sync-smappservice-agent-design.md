# Background sync via a bundled SMAppService agent — design

**Status:** approved (brainstorm), not yet planned.
**Supersedes:** the hand-rolled `com.pensieve.sync` LaunchAgent from
`docs/superpowers/specs/2026-07-05-pensieve-sync-daemon-design.md`.
**Roadmap:** pillar #3 ("retire the launchd daemon → in-app background service"), plus the
already-shipped `LSUIElement` hide-Dock toggle it was paired with.

## Why

The sync daemon shipped as a hand-written launchd LaunchAgent (plist to
`~/Library/LaunchAgents/`, loaded via `launchctl bootstrap`) for one reason: **at the time
(2026-07-05) there was no app bundle.** Pensieve was a bare SwiftPM CLI at `~/.local/bin/pensieve`,
and `SMAppService` can only register a helper that lives *inside* a code-signed `.app`. The Xcode
app bundle landed the next day (2026-07-06). Now that the bundle exists, we can register the
background service the first-party way and get its platform guarantees — launchd-owned scheduling
and power throttling (Low Power Mode, wake coalescing), code-signed/bundled program, clean
`register()`/`unregister()` lifecycle — instead of shelling out to `launchctl`.

A second fact reframes the work: **the GUI app today runs neither extraction, discovery, nor
strand-naming.** Its FSEvents "self-drain" is `Ingester.drain()` only (spool → events, no LLM). The
launchd daemon is the *sole* generator of loose ends via `SyncRunner.run()`. So "retire the daemon"
is not "drop a redundant agent" — the background service must keep running the full `SyncRunner`
pipeline, just under a better host.

## Run model — a bundled, launchd-scheduled one-shot

A LaunchAgent plist bundled inside the app at
`Pensieve.app/Contents/Library/LaunchAgents/me.mazetti.pensieve.sync.plist`, registered via
`SMAppService.agent(plistName:)`. It runs a small in-bundle helper on a `StartInterval` and **exits
between runs** — the same proven "no resident process" model as today, now ServiceManagement-managed.

- `StartInterval` 300 s, `ProcessType: Background`, `RunAtLoad: true` (all unchanged from today).
- Runs **independently of the GUI** — on schedule whether or not any window is open. This removes the
  "what happens when the app is force-quit?" gap entirely: the durable spool + git keep accruing
  captures, and the scheduled agent extracts them regardless of the GUI's state.
- **No resident GUI process, no login item for the app.** The GUI stays open-on-demand. It keeps its
  existing FSEvents self-drain purely for live UI freshness while a window is open; the agent owns
  the authoritative, LLM-bearing sync.
- **On-device provider only.** The helper resolves the provider exactly as `pensieve sync` does
  today (`makeDefaultLLMProvider(defaults: PensieveDefaults.shared())`); extraction stays on-device
  by design (the trust gate). No change.

### Why not the alternatives (recorded)

- **`SMAppService.loginItem` (auto-launch the GUI, sync in-process)** — rejected. A full GUI app
  resident all day is the opposite of the power profile we want, ties sync to the app being open
  (reintroduces the force-quit gap), and runs the LLM inside the GUI process.
- **`SMAppService.daemon` (root LaunchDaemon)** — rejected. Runs as root, system-wide, needs proper
  (non-ad-hoc) signing + admin approval. Wrong scope for a per-user tool.

## The sync executable inside the bundle

SMAppService requires the agent's program to live inside the app and be signed with it. The current
`pensieve` CLI is a SwiftPM binary in `~/.local/bin` — outside the bundle. Fix:

**A dedicated Xcode helper target `PensieveSyncAgent`** — a ~15-line `main.swift` that constructs a
`SyncRunner` and calls `.run()`, reusing the *same tested PensieveKit struct* the CLI uses. Built and
signed by Xcode, embedded in `Pensieve.app/Contents/Library/Helpers/PensieveSyncAgent`. The bundled
plist references it via the bundle-relative **`BundleProgram`** key (the convention for
SMAppService-managed agents — the absolute bundle path isn't known at author time), confirmed against
the actual key during the spike.

- The tiny `openSpool()` / `openCanonical()` store-opening helpers currently in `Sources/pensieve`
  move into PensieveKit so both the CLI and the helper share one definition. No behavior change.
- Rejected alternative: bundling the existing `pensieve` CLI via a build phase that runs
  `swift build -c release --product pensieve` — nests a SwiftPM build inside `xcodebuild` (slow,
  fragile, `.build` contention against the known intermittent macro-linker flakiness) and drags the
  whole ArgumentParser CLI in to run one subcommand.

The helper is a thin shell over shared, tested logic (`SyncRunner`), so this adds an entry point, not
duplicated substance.

## Registration, control surface, status

A thin **app-target `BackgroundSyncService`** wraps `SMAppService.agent(plistName:)` with three
operations: `register()`, `unregister()`, and a `status` read. SMAppService/launchctl mutate live
system state, so — matching the daemon precedent — this wrapper is **smoke-verified by hand**, not
unit-tested; the real logic it schedules (`SyncRunner`) is already tested.

- **On launch** (`applicationDidFinishLaunching`): run legacy cleanup (below), then, if the
  preference is on (default **true**), call `register()` idempotently.
- **Settings ▸ General ▸ "Background sync"** section:
  - Toggle *"Keep Pensieve synced in the background"* bound to `AppDefaults.backgroundSyncEnabledKey`
    (default `true`). `onChange`: `true` → `register()`, `false` → `unregister()`.
  - A status line derived from `agent.status`:
    - `.enabled` → "Enabled"
    - `.requiresApproval` → "Needs approval" + a button calling
      `SMAppService.openSystemSettingsLoginItems()`
    - `.notRegistered` → "Off"
    - `.notFound` → "Not found" (bundle/plist issue)
  - German localization for the new chrome (vendor/proper-noun rules per the existing catalog).

## Legacy migration

The live machine currently has a hand-installed `~/Library/LaunchAgents/com.pensieve.sync.plist`
bootstrapped into the gui domain. To avoid a launchd **label collision**, the bundled agent uses a
**new namespaced label `me.mazetti.pensieve.sync`** (aligned with the app's bundle-id namespace;
distinct from the legacy `com.pensieve.sync`).

On every launch, before registering, run an idempotent legacy cleanup:

1. If `~/Library/LaunchAgents/com.pensieve.sync.plist` exists, `launchctl bootout gui/<uid> <path>`
   then remove the file (reuse `DaemonInstaller.unload`). Best-effort; a no-op when already gone, so
   it can run unconditionally without a version flag.

Capture hooks (`SessionStart` / `SessionEnd` → `pensieve capture-*`), `pensieve prime`, and
`pensieve mcp` are untouched — only the *scheduling* of `sync` moves. The `pensieve sync` subcommand
stays runnable by hand.

## Testing & verification

Following the daemon precedent (system-mutating calls are hand-verified, pure parts are tested):

- The bundled plist becomes a **committed static file** under the app's resources. A cheap parse
  test asserts its keys: `Label == me.mazetti.pensieve.sync`, the program key (`BundleProgram`)
  resolves to the in-bundle helper, `StartInterval == 300`, `ProcessType == Background`. This is the regression
  guard replacing the retired runtime `LaunchAgentPlist` writer test.
- `SyncRunner` stays tested as-is (the real pipeline logic is unchanged).
- App smoke-launch of the inner binary as usual (`./.build-xcode/.../Contents/MacOS/Pensieve`,
  background + `kill`, throwaway `PENSIEVE_DB`/`PENSIEVE_CAPTURE_DB`).

**Human-verify carries** (need the built, signed app):

- Settings toggle **on** → `register()` succeeds; the item appears in System Settings ▸ General ▸
  Login Items ("Allow in the Background"); status shows **Enabled**.
- Toggle **off** → `unregister()`; the item disappears; status **Off**.
- `launchctl print gui/$(id -u)/me.mazetti.pensieve.sync` shows the job; `sync.log` gets fresh
  timestamped cycles at ~300 s; loose-end counts still climb after new git/session activity.
- Legacy `com.pensieve.sync` is gone (`launchctl print gui/$(id -u)/com.pensieve.sync` → not found;
  `~/Library/LaunchAgents/com.pensieve.sync.plist` deleted).

## Scope

**In scope:**

- New Xcode helper target `PensieveSyncAgent` (thin `main` over `SyncRunner`).
- Move `openSpool` / `openCanonical` from `Sources/pensieve` into PensieveKit (shared).
- Bundled static plist + `project.yml` wiring (embed helper in `Contents/Library/Helpers`, plist in
  `Contents/Library/LaunchAgents`).
- App-target `BackgroundSyncService` (register / unregister / status) + Settings "Background sync"
  section (toggle + status + open-Login-Items button) + German l10n.
- Auto-register on launch (default-on) + idempotent legacy boot-out on launch.
- **Remove** the `pensieve install-daemon` command and the now-dead runtime plist machinery
  (`DaemonInstaller.writePlist` / `load` / `ensureStable`, `LaunchAgentPlist` runtime use). **Keep**
  `DaemonInstaller.unload` for legacy cleanup.
- Post-merge: rebuild + reinstall the release CLI (loses `install-daemon`), and remove the live
  legacy agent (the app does this on first launch, but note it in the runbook).

**Non-goals (deferred / by design):**

- CloudKit sync, iOS companion (pillar #4).
- A resident / event-driven agent — the one-shot `StartInterval` model is sufficient, same as today.
- FSEvents-based real-time monitoring (pillar #6) — the GUI's FSEvents self-drain stays for UI
  freshness only.
- Cloud extraction — extraction stays on-device behind the trust gate.

## Risks to verify early (spike before the full build)

1. **Ad-hoc signing.** SMAppService login-items/agents do *not* require the paid-team entitlement
   that gates App Groups / CloudKit / extensions (see the "Signing / App Groups gate"), so this
   should work under our ad-hoc (`CODE_SIGN_IDENTITY: "-"`) build. Confirm `register()` reaches
   `.enabled` (not a persistent `.requiresApproval` / failure) from the ad-hoc bundle.
2. **Launch location.** SMAppService ties registration to the app's on-disk path/identity. It may
   misbehave when the app runs from `./.build-xcode/…`; verifying may require the app in
   `/Applications`. Treat "move to `/Applications` to verify" as a known verification step, and
   decide whether dogfooding should run the app from a stable install location.

Resolve both in a short spike at the start of the plan; if either is a hard blocker under ad-hoc
signing, stop and reassess before building the full surface.
