# Background sync via a bundled SMAppService agent — design

**Status:** approved (brainstorm) + hardened by two independent adversarial reviews. Not yet planned.
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

A second fact reframes the work (verified in review against `AppModel.swift:310,326`): **the GUI app
today runs neither extraction, discovery, nor strand-naming.** Its FSEvents "self-drain" is
`Ingester.drain()` only (spool → events, no LLM). The launchd daemon is the *sole* generator of loose
ends via `SyncRunner.run()`. So "retire the daemon" is not "drop a redundant agent" — the background
service must keep running the full `SyncRunner` pipeline, just under a better host.

## Run model — a bundled, launchd-scheduled one-shot

A LaunchAgent plist bundled inside the app at
`Pensieve.app/Contents/Library/LaunchAgents/me.mazetti.pensieve.sync.plist`, registered via
`SMAppService.agent(plistName:)`. It runs a small in-bundle helper on a `StartInterval` and **exits
between runs** — the same proven "no resident process" model as today, now ServiceManagement-managed.

- Runs **independently of the GUI** — on schedule whether or not any window is open — *while the user
  is logged in* (same limit as today's agent; it does not run at the login window / logged-out). This
  removes the "what if the app is force-quit?" gap: the durable spool + git keep accruing captures and
  the scheduled agent extracts them regardless of the GUI's state.
- **No resident GUI process, no login item for the app.** The GUI stays open-on-demand and keeps its
  FSEvents self-drain purely for live UI freshness while a window is open; the agent owns the
  authoritative, LLM-bearing sync.
- **On-device provider only.** The helper resolves the provider exactly as `pensieve sync` does today
  (`makeDefaultLLMProvider(defaults: PensieveDefaults.shared())` — `PensieveDefaults.shared()` is
  `UserDefaults(suiteName: "me.mazetti.pensieve")`, which a same-user, non-sandboxed bundled agent
  reads correctly, verified in review). Extraction stays on-device by design (the trust gate).

### The committed plist stays home-independent; the helper owns runtime environment

This is the load-bearing correction from review. launchd performs **no `~`/`$HOME`/shell expansion**
of plist values, and the app is ad-hoc signed and rebuilt often — so a *committed static plist*
cannot encode any machine-specific absolute path. Two things in today's plist are machine-specific
and must therefore **move out of the plist and into the helper at runtime**:

1. **`PATH`.** Today's `LaunchAgentPlist` injects
   `EnvironmentVariables.PATH = "$HOME/.local/bin:/opt/homebrew/bin:/usr/bin:/bin"` **deliberately**:
   launchd replaces (does not inherit) the login PATH, and `Git.run` spawns `/usr/bin/env git` while
   `ClaudeCLIProvider` spawns `/usr/bin/env claude`. Drop this and `claude` (and Homebrew git) stop
   resolving → extraction silently yields **zero loose ends** on any machine without on-device
   Foundation Models. **Fix:** `PensieveSyncAgent/main.swift` resolves the real home at runtime and
   `setenv("PATH", …, 1)` (covering `~/.local/bin`, `/opt/homebrew/bin`, `/usr/bin`, `/bin`) before
   constructing `SyncRunner`, so the spawned git/`claude` children inherit it.
2. **`sync.log`.** Today the plist redirects `StandardOutPath`/`StandardErrorPath` to
   `~/Library/Logs/Pensieve/sync.log`. `SystemStatus.lastSyncAt` reads that file's **mtime**, and the
   observability runbook (`CLAUDE.md`) is `tail -f …/sync.log`. **Fix:** the helper opens
   `~/Library/Logs/Pensieve/sync.log` (runtime-resolved home) for append and writes the same
   ISO-timestamped summary line the CLI prints today — so `sync.log`, its mtime, `lastSyncAt`, and the
   runbook all keep working unchanged, with no machine-specific path in the committed plist.
   (`SyncRunner` itself also logs via `os.Logger`, subsystem `me.mazetti.pensieve`.)

The committed plist therefore contains only **home-independent** keys: `Label`
(`me.mazetti.pensieve.sync`), `BundleProgram` (bundle-root-relative helper path), `StartInterval`
(300), `ProcessType` (`Background`), `RunAtLoad` (true). No `EnvironmentVariables`, no
`Standard*Path`.

### Why not the alternatives (recorded)

- **`SMAppService.loginItem` (auto-launch the GUI, sync in-process)** — rejected. A resident GUI app is
  the opposite of the power profile we want, ties sync to the app being open (reintroduces the
  force-quit gap), and runs the LLM inside the GUI process.
- **`SMAppService.daemon` (root LaunchDaemon)** — rejected. Runs as root, system-wide, needs proper
  (non-ad-hoc) signing + admin approval. Wrong scope for a per-user tool.

## The sync executable inside the bundle

SMAppService requires the agent's program to live inside the app and be signed with it. The current
`pensieve` CLI is a SwiftPM binary in `~/.local/bin` — outside the bundle. Fix:

**A dedicated Xcode helper target `PensieveSyncAgent`** — a small `main.swift` that (a) resolves the
real home and `setenv`s `PATH`, (b) opens `sync.log` for append, (c) constructs a `SyncRunner` and
calls `.run()`, reusing the *same tested PensieveKit struct* the CLI uses, (d) writes the ISO summary
line. Built and signed by Xcode, embedded in `Pensieve.app/Contents/Library/Helpers/PensieveSyncAgent`.
The bundled plist references it via the **`BundleProgram`** key, whose value is the **bundle-root-
relative** path string `Contents/Library/Helpers/PensieveSyncAgent` (the exact string + the
`Contents/Library/{Helpers,LaunchAgents}` layout are confirmed in the opening spike — see Risks).

- The tiny `openSpool()` / `openCanonical()` store-opening helpers currently in `Sources/pensieve`
  move into PensieveKit so both the CLI and the helper share one definition (they carry the
  `PENSIEVE_CAPTURE_DB` / `PENSIEVE_DB` env overrides, harmless in the framework; the read-only
  `openCanonicalReadOnly` stays CLI-side). No behavior change.
- Rejected alternative: bundling the existing `pensieve` CLI via a build phase running
  `swift build -c release --product pensieve` — nests a SwiftPM build inside `xcodebuild` (slow,
  fragile, `.build` contention against the known intermittent macro-linker flakiness) and drags the
  whole ArgumentParser CLI in to run one subcommand.

## Registration, control surface, status

A thin **app-target `BackgroundSyncService`** wraps `SMAppService.agent(plistName:)`. SMAppService/
launchctl mutate live system state, so — matching the daemon precedent — this wrapper is
**smoke-verified by hand**, not unit-tested; the real logic it schedules (`SyncRunner`) is tested.

**Register is status-gated, not blindly idempotent.** `register()` throws once the user has disabled
the item in System Settings, and blindly re-registering fights that choice. So on launch:

1. Read `agent.status`.
2. Only call `register()` when status is `.notRegistered` **and** the preference is on. Wrap in
   `try?`/do-catch; a throw is non-fatal (logged, surfaced as status). Never auto-re-enable a
   user-disabled item.

**Both auto-register and legacy cleanup are guarded to the installed app**, mirroring the existing
`DaemonInstaller.ensureStable` "refuse from `/.build/`" rule: skip when `Bundle.main.bundlePath`
contains `.build` / `.build-xcode`. This prevents the documented DerivedData **smoke-launch** from
registering a throwaway agent into the user's real Login Items or booting out the live legacy daemon.

**Settings ▸ General ▸ "Background sync"** section:

- Toggle *"Keep Pensieve synced in the background"* bound to `AppDefaults.backgroundSyncEnabledKey`
  (default `true`). `onChange`: `true` → `register()`, `false` → `unregister()`.
- A status line derived from `agent.status`:
  - `.enabled` → "Enabled"
  - `.requiresApproval` → "Needs approval" + a button calling
    `SMAppService.openSystemSettingsLoginItems()`
  - `.notRegistered` → "Off"
  - `.notFound` → "Not found" (bundle/plist issue)
- German localization for the new chrome.

## Reconciling the existing status UI

The current **Advanced Settings** tab shows a "Sync daemon: Installed/Not installed" row whose value
is `SystemStatusGatherer.gather` → `daemonInstalled = fileExists(launchAgentURL)`, i.e. it tests for
the **legacy** `~/Library/LaunchAgents/com.pensieve.sync.plist` — the exact file this migration
deletes. Left alone it would report "Not installed" forever while the new agent runs. **Fix (in
scope):** repoint that signal to `SMAppService.agent(…).status` (the honest source) or remove the row.
`SystemStatus.lastSyncAt` (sync.log mtime) is **unchanged** because the helper still writes `sync.log`.

## Legacy migration

The live machine currently has a hand-installed `~/Library/LaunchAgents/com.pensieve.sync.plist`
bootstrapped into the gui domain. The bundled agent uses a **new namespaced label
`me.mazetti.pensieve.sync`** (distinct from legacy `com.pensieve.sync`), avoiding a launchd label
collision. On launch (guarded to the installed app, per above), before registering, run an idempotent
legacy cleanup: if `~/Library/LaunchAgents/com.pensieve.sync.plist` exists, `launchctl bootout
gui/<uid> <path>` (uid = `String(getuid())`) then remove the file (reuse `DaemonInstaller.unload`).
Best-effort, a no-op when already gone. `unload` runs `launchctl` synchronously via `Process`; since
booting out an absent job returns fast, keep it, but hop off the main thread (or run once behind a
guard) so first launch never blocks on it.

Capture hooks (`SessionStart`/`SessionEnd` → `pensieve capture-*`), `pensieve prime`, and
`pensieve mcp` are untouched — only the *scheduling* of `sync` moves. `pensieve sync` stays runnable
by hand.

## The live-machine transition (runbook)

After merge the user rebuilds and **installs `Pensieve.app` to `/Applications`** (see Risks — required,
not optional). On first launch it boots out the legacy agent and calls `register()`, which on a fresh
bundle returns **`.requiresApproval`** — the new agent does **not** run until the user approves it in
System Settings ▸ General ▸ Login Items. This is a real window where sync stops. The runbook must make
these **mandatory** post-launch steps, and the app should surface the "needs approval" state somewhere
glanceable (menu-bar / main window), not only inside the Settings pane the user may never open:

1. Rebuild + reinstall the release CLI (loses `install-daemon`) and the app to `/Applications`.
2. Launch the app once → confirm legacy `com.pensieve.sync` is gone.
3. Approve "Pensieve Background" in Login Items → confirm status shows **Enabled**.
4. Confirm `sync.log` gets fresh timestamped cycles and loose-end counts climb.

## Testing & verification

Following the daemon precedent (system-mutating calls are hand-verified, pure parts are tested):

- The bundled plist becomes a **committed static file** (now viable — it is home-independent). A cheap
  parse test asserts its **string** keys: `Label == me.mazetti.pensieve.sync`, `BundleProgram ==
  Contents/Library/Helpers/PensieveSyncAgent`, `StartInterval == 300`, `ProcessType == Background`,
  `RunAtLoad == true`, and — as a guard against the C1/C2 regression — that it carries **no**
  `EnvironmentVariables` / `StandardOutPath` (env + logging are the helper's job). The test asserts
  the string only; that `BundleProgram` *resolves* to a signed helper is a human/spike check.
- `SyncRunner` stays tested as-is (the real pipeline logic is unchanged).
- **Enumerate every removed symbol + test** so the build stays green: deleting
  `DaemonInstaller.writePlist` / `load` / `ensureStable` / `stablePensievePath` /
  `DaemonInstallError` breaks `DaemonInstallerTests`; deleting the runtime `LaunchAgentPlist` writer
  breaks `LaunchAgentPlistTests`. Both test files are pruned/rewritten in the same change. Keep
  `DaemonInstaller.unload`. Resolve `PensievePaths.launchAgentURL()` retention — legacy cleanup still
  needs the legacy path; keep it (or inline the path), don't leave a dangling reference.
- App smoke-launch of the inner binary as usual — now safe because auto-register/cleanup are guarded
  off for `.build-xcode` paths.

**Human-verify carries** (need the built, signed app installed to `/Applications`):

- Settings toggle **on** → `register()`; item appears in System Settings ▸ Login Items; after approval
  status shows **Enabled**. Toggle **off** → `unregister()`; item disappears; status **Off**.
- `launchctl print gui/$(id -u)/me.mazetti.pensieve.sync` shows the job; the helper resolves the
  on-device provider and a first 300 s cycle actually extracts loose ends (proves PATH/env correct).
- `sync.log` gets fresh timestamped cycles (tolerate drift under power throttling — `ProcessType:
  Background` coalesces wakes, so ~300 s is a floor, not a guarantee); loose-end counts still climb.
- Legacy `com.pensieve.sync` is gone; the Advanced-tab daemon row reflects the new agent, not the
  deleted file.

## Scope

**In scope:**

- New Xcode helper target `PensieveSyncAgent` (`main.swift`: resolve home, `setenv` PATH, open
  `sync.log`, run `SyncRunner`, write summary line).
- Move `openSpool` / `openCanonical` from `Sources/pensieve` into PensieveKit (shared).
- Committed static plist (home-independent keys only) + `project.yml` wiring: a second executable
  target, a copy-files phase embedding the **signed** helper at `Contents/Library/Helpers`, and a
  copy-files phase placing the plist at `Contents/Library/LaunchAgents` (**not** Resources). This is
  genuinely fiddly, not "wiring" — the spike dumps the built bundle tree and `codesign -dv`s the
  helper before the UI is built.
- App-target `BackgroundSyncService` (status-gated register / unregister / status) + build-location
  guard + Settings "Background sync" section (toggle + status + open-Login-Items button) + German l10n.
- Auto-register on launch (default-on, status-gated, guarded to installed app) + idempotent legacy
  boot-out on launch (off the main thread).
- Repoint `SystemStatusGatherer.daemonInstalled` to `SMAppService` status (or remove the row).
- **Remove** the `pensieve install-daemon` command and the now-dead runtime plist machinery
  (`DaemonInstaller.writePlist` / `load` / `ensureStable` / `stablePensievePath` /
  `DaemonInstallError`, `LaunchAgentPlist` runtime use) + their tests. **Keep** `DaemonInstaller.unload`.
- Update `CLAUDE.md` / runbook (`install-daemon` gone; app owns the agent; `/Applications` install;
  approval step).

**Non-goals (deferred / by design):**

- CloudKit sync, iOS companion (pillar #4).
- A resident / event-driven agent — the one-shot `StartInterval` model is sufficient, same as today.
- FSEvents-based real-time monitoring (pillar #6) — the GUI's FSEvents self-drain stays for UI
  freshness only.
- Cloud extraction — extraction stays on-device behind the trust gate.

## Risks to resolve in the opening spike (gate the full build on these)

1. **Ad-hoc signing + cdhash churn.** SMAppService login-items/agents do *not* require the paid-team
   entitlement that gates App Groups / CloudKit (see "Signing / App Groups gate"), so registration
   *should* work ad-hoc — but ad-hoc (`CODE_SIGN_IDENTITY: "-"`) mints a **new cdhash every build**,
   and SMAppService pins the registration to path + cdhash. Spike must: (a) `register()` from an
   installed app reaches `.enabled` after approval; (b) rebuild + reinstall (new cdhash) — does the
   job survive, silently re-register, or force re-approval every update? If it's re-approval on every
   rebuild, that's a dogfooding tax to surface now.
2. **Launch location — hard requirement, not "may".** SMAppService ties registration to the app's
   on-disk path/identity; DerivedData isn't a stable/Gatekeeper-valid location, and the project's
   routine `rm -rf .build-xcode` recovery would delete a registered bundle out from under launchd.
   **Install to `/Applications/Pensieve.app` before `register()`.** Spike must: register from
   `/Applications`, quit the app, `rm -rf .build-xcode`, wait one interval, confirm the job still
   fires.
3. **`BundleProgram` key + bundle layout.** Confirm the exact key (`BundleProgram`) and the
   bundle-root-relative string resolve to the launched helper; dump `find Pensieve.app/Contents/Library`
   and `codesign -dv` the embedded helper.
4. **On-device provider under the bundled helper.** Confirm `makeDefaultLLMProvider` resolves to the
   on-device provider and actually extracts within the first successful cycle (process identity/signing
   differs from today's bare-binary agent).

If (1) or (2) is a hard blocker under ad-hoc signing, stop and reassess before building the full
surface.

## Spike outcome (2026-07-16) — GATE PASSED

Verified on the live machine with the bundled helper installed to `/Applications/Pensieve.app`
(ad-hoc signed). Bundle layout and signing are correct (Risk 3): the helper lands at
`Contents/Library/Helpers/PensieveSyncAgent` and the plist at
`Contents/Library/LaunchAgents/me.mazetti.pensieve.sync.plist`, both ad-hoc signed;
`BundleProgram = Contents/Library/Helpers/PensieveSyncAgent` resolves and launchd launches it.

1. **Ad-hoc registration reaches enabled (Risk 1) — PASS.** `register()` from the installed app
   registers the agent (`launchctl print gui/$uid/me.mazetti.pensieve.sync` shows a `Submitted` job
   `managed_by = com.apple.xpc.ServiceManagement`), and after the one-time Login-Items approval the
   job spawns and runs. The paid-team entitlement is *not* required, as expected.

2. **cdhash churn (Risk 1b) — REAL PROBLEM, MITIGATED IN CODE.** Every ad-hoc rebuild mints a new
   helper cdhash, and SMAppService pins the registration to path + cdhash via a LightWeight Code
   Requirement (LWCR). A registration left over from a previous build **spawn-fails on every interval
   with `last exit code = 78 (EX_CONFIG)` and `needs LWCR update`** — the job never runs. A bare
   `agent.register()` on an already-`.enabled` item is a **silent no-op that does NOT refresh the
   LWCR**, so the app cannot self-heal with `register()` alone. **`unregister()` + `register()` DOES
   refresh the LWCR** to the current binary, and — critically — **approval PERSISTS across the cycle**
   for an already-approved bundle id (the job went straight back to `running`, no re-prompt). Fix
   applied: `BackgroundSyncService.registerIfNeeded()` now does `unregister()` then `register()` on
   every launch (when the pref is on). Cost on a normal launch is nil; it only heals the cdhash after
   a rebuild. (Accepted trade-off: a user who disables the item in System Settings but leaves the
   in-app toggle on would see it resurrected to "needs approval" — acceptable for a single-user tool
   where the in-app toggle is the authoritative control; the toggle-off path calls `unregister()` and
   does not re-register.)

3. **On-device provider under the bundled helper (Risk 4) — PASS.** `makeDefaultLLMProvider(defaults:)`
   resolves to `FoundationModelsProvider` inside the helper, and the runtime `PATH` (`~/.local/bin`,
   `/opt/homebrew/bin`, `/usr/bin`, `/bin`) is set correctly so `git`/`claude` children resolve. The
   helper **does** extract — a scare during the spike (the helper appeared to "hang" at the first LLM
   call) turned out to be a **~5-day extraction backlog** (the legacy daemon had been dead since
   Jul 11; ~900 transcripts to catch up on) processed at ~2–3 s per on-device inference, which simply
   exceeded the short manual timeouts. Confirmed by streaming debug logs: steady `LLM prompt
   dispatched` / `LLM completion received` pairs, `looseEnds` count climbing (679+ and counting). A
   minimal standalone `LanguageModelSession.respond` round-trip returns instantly, and the bare CLI
   exhibits the identical backlog behavior — nothing helper-specific, no hang.

4. **Path stability (Risk 2) — TO VERIFY (human).** Register from `/Applications`, quit, `rm -rf
   .build-xcode`, wait one interval, confirm the job still fires. Low risk (the job runs from
   `/Applications`, independent of DerivedData) but not yet exercised end-to-end; deferred to the
   post-merge human runbook along with the one-time Login-Items approval.
