# Pensieve.app Settings surface (first cut) — design

**Date:** 2026-07-08
**Status:** approved (design), pending spec review → plan
**Scope:** app-target Settings scene + one small PensieveKit preference seam. First cut only.

## Goal

Pensieve.app has no Settings/Preferences window today. A growing set of features are
blocked on one. Build a first-party SwiftUI `Settings` scene (standard **⌘,** /
"Pensieve ▸ Settings…") hosting the first three config knobs, each persisted where it
belongs. This is the near-term pillar raised on 2026-07-08 (see `backlog.md` → "⭐ App
Settings surface").

**First cut = scaffold + three existing knobs.** No net-new LLM subsystem.

## Non-goals (explicitly deferred, not foreclosed)

- **Cloud/API LLM provider + Keychain-stored key + model selection** — the motivating
  long-term case, but a meaty net-new subsystem (an HTTP `LLMProvider`, credential
  storage). Its own future spec. The scaffold + provider-preference seam built here is
  the foundation it will extend.
- **Organizing-writes error surfacing** — needs an app error-presentation mechanism; a
  separate concern (backlog "Code-quality review carries"). Pairs with, but is not, this.
- **Other knobs** — capture/scan folders, daemon interval, etc. Add per-need later.
- **Tabbed multi-pane Settings** — a single General pane suffices for three knobs; tabs
  are a trivial later change if knobs multiply.

## Architecture

A SwiftUI **`Settings` scene** added to the app's `App` body alongside the existing
`Window("main")` + `MenuBarExtra`. This yields the standard **⌘, / Pensieve ▸ Settings…**
menu item natively — no custom window, no `NSWindow` work. A single **General pane**
(`Form`) for the first cut.

Three knobs, each persisted where it belongs — matching the project rule *"UI prefs →
UserDefaults; anything sync-bound → the canonical store"*:

| Knob | Persistence | Rationale |
|---|---|---|
| **LLM provider** — Auto / Foundation Models / claude -p | Shared file `~/Library/Application Support/Pensieve/preferences.json` | Must be read by **both** the app and the launchd daemon/CLI; machine-local (Foundation Models availability differs per machine) so **not** sync-bound → not the canonical CloudKit store |
| **Hide Dock icon** (menu-bar-only mode) | app `@AppStorage("app.hideDockIcon")` | Pure app-process UI behavior |
| **"Last Work Done" narration** on/off | app `@AppStorage("app.narrationEnabled")` | Pure app-process UI behavior |

Only the one genuinely cross-process knob (provider) pays for a shared file; the two
app-only toggles stay in `UserDefaults`.

**Why a shared file is possible here (and Widgets weren't):** the app is **not
sandboxed** (no App Sandbox entitlement) and the CLI/daemon certainly isn't, so both
processes can read/write a plain file in `PensievePaths.supportDirectory()` — no App
Group / Team-ID entitlement required. (This is unrelated to the App-Groups gate that
blocks Widgets/CloudKit.)

## Component 1 — the provider preference (the only PensieveKit change)

Machine-local, tested, small. Lives in `Sources/PensieveKit/LLM/` next to the providers.

- **`ProviderPreference`** — a single enum `.auto` / `.foundationModels` / `.claudeCLI`,
  raw-string-backed (stable on-disk values `"auto"` / `"foundationModels"` /
  `"claudeCLI"`). This is the *only* new type — no second `ProviderKind` enum (the
  resolver returns the existing `String` kind, keeping `defaultProviderKind()`'s contract).
- **`Preferences`** — reads/writes the JSON prefs file at an **explicit URL passed in**
  (no env-reading inside PensieveKit — see below):
  - `Preferences.read(from: URL) -> ProviderPreference` and
    `Preferences.write(_:to: URL)`.
  - Atomic write (`Data.write(to:options:.atomic)`).
  - Missing file, unreadable, or corrupt JSON ⇒ `.auto` (today's behavior — never throws
    into a caller; the read is best-effort).
  - Shape is a single small JSON object, e.g. `{"llmProvider":"claudeCLI"}` — additive
    keys allowed later without breaking older readers (unknown keys ignored; missing keys
    default).
- **`PensievePaths.preferencesURL()`** — new; `supportDirectory()/preferences.json`.
- **`resolveProviderKind(preference:foundationAvailable:) -> String`** — a **pure**
  function holding the whole decision, fully unit-testable. Returns the existing kind
  strings (`"foundationModels"` / `"claudeCLI"`):
  - `.auto` → `foundationAvailable ? "foundationModels" : "claudeCLI"` (today's logic).
  - `.foundationModels` → `"foundationModels"` if available, else **falls back to**
    `"claudeCLI"` (transparent — the UI notes this).
  - `.claudeCLI` → always `"claudeCLI"`.
- **`makeDefaultLLMProvider(prefsURL: URL? = nil)`** and
  **`defaultProviderKind(prefsURL: URL? = nil)`** — read the preference (from `prefsURL`
  when provided, else the env override `PENSIEVE_PREFS` if set, else
  `PensievePaths.preferencesURL()`) + run the existing `FoundationModelsProbe`, feed both
  into `resolveProviderKind`, and construct the chosen provider.
  - **The five existing call sites (`Ingest`, `Digest`, `Sync`, `AppModel`) keep calling
    argument-free** — the defaulted param means no call-site change; real runs resolve
    env-or-default.
  - **Tests always pass an explicit `prefsURL`** (a temp file, or a nonexistent path to
    force `.auto`), so tests never read `ProcessInfo.environment` and can't race on the
    process-global env under Swift Testing's parallel execution. This is why env
    resolution lives in the factory behind an injectable override, not inside
    `Preferences`, and not as a bare `getenv` in the test path.

**The trust gate is untouched.** This selects *which* provider runs behind the gate; the
grounding/citation logic is unchanged.

**Existing test that must change:** `DefaultProviderTests` (`Tests/PensieveKitTests/`)
calls `defaultProviderKind()` and string-matches the result. Once that function consults
a prefs file it would read the **real** `~/Library/Application Support/Pensieve/preferences.json`
on this dogfooding machine and flip if the user has picked `claudeCLI`. Update the test to
pass an explicit nonexistent `prefsURL` (forcing `.auto`), preserving its assertion. This
is listed in the change set — the "existing tests stay green" promise depends on it.

## Component 2 — the two app-process toggles (app target only)

**Hide Dock icon (menu-bar-only mode).** Persisted under a **shared constant key** (e.g.
`AppDefaults.hideDockIconKey`, alongside the existing `FocusFilterDefaults`/narration-cache
keys) so the SettingsView `@AppStorage` binding and the AppDelegate reader can't drift.
Two application points:
- **At launch:** `AppDelegate` currently implements only `application(_:open:)` — this cut
  **adds an `applicationDidFinishLaunching`** that reads `UserDefaults.standard.bool(forKey:)`
  (an `NSObject` delegate can't use `@AppStorage`) and calls `NSApp.setActivationPolicy`.
- **On toggle:** an `@AppStorage` write has no side effect by itself, so the toggle uses an
  explicit `.onChange` that calls `NSApp.setActivationPolicy(.accessory / .regular)` **and**,
  when switching back to `.regular`, `NSApp.activate(ignoringOtherApps: true)` +
  `makeKeyAndOrderFront` so the window returns to the foreground (transitioning to
  `.accessory` orders the app out of foreground; without the explicit re-activation the
  main window can fail to front again). This mitigation is baked into the plan, not left to
  smoke-test.

The `MenuBarExtra` keeps the app alive with no dock icon; with the dock hidden and the
window closed, the menu-bar "Open Pensieve" path (`DeepLinkNavigation` → `openWindow(id:
"main")` + `NSApplication.shared.activate()`) reopens it — so the app is never unreachable.
Closes the `LSUIElement` item deferred from v0.2 — done at runtime via activation policy,
so the static `Info.plist` default stays dock-visible.

**"Last Work Done" narration on/off.** `@AppStorage("app.narrationEnabled")` bool (default
true). When off, `DetailView` must gate **both** the auto-narrate `.task` (no generation)
**and** the cached-prose render (no showing a previously-cached recap), and ⌘R must not
force narration while off. Accepted behavior (state it): because the `.task(id:)` key does
not include this bool, flipping narration back **on** while a node is already open won't
regenerate until node-change or ⌘R — fine for a toggle. No PensieveKit change — narration
is already best-effort and outside the trust gate.

## Data flow

```
Settings pane (Form)
  ├─ Provider Picker ──write──▶ Preferences.write(preferences.json)   [shared support dir]
  │                             │
  │                             ├─▶ AppModel rebuilds its summaryBuilder ─▶ app: next narration/⌘R
  │                             └─▶ makeDefaultLLMProvider() re-read ─────▶ daemon: next `pensieve sync`
  ├─ Hide Dock toggle ──write──▶ @AppStorage ──.onChange──▶ NSApp.setActivationPolicy(...)
  └─ Narration toggle ─write──▶ @AppStorage ──▶ DetailView .task + render gate
```

**Daemon side is automatic:** each `pensieve sync`/`ingest` is a fresh process that calls
`makeDefaultLLMProvider()` anew, so it reads the file on its next 300 s launchd cycle (or a
manual run).

**App side is NOT automatic and must be wired:** `AppModel.summaryBuilder` is a
`private lazy var` constructed once with `makeDefaultLLMProvider()` and holds its provider
in a `let`, so it never re-reads the preference within a session. The Provider Picker's
write must therefore **rebuild `summaryBuilder`** (reset the lazy var / re-init with a
freshly resolved provider) so the change takes effect on the next narration — otherwise
the in-app knob is a no-op until relaunch. This rebuild is the *real* reason `AppModel` is
touched (not a `@Published` mirror of the preference). No live cross-process signalling is
needed for a single-user tool.

## Error handling

- Preference read: any failure ⇒ `.auto`. Never throws into a caller.
- Preference write: atomic; a failed write is best-effort (the picker reflects the
  in-memory selection; worst case the on-disk value lags — acceptable, single user). The
  app has no error-presentation surface yet (see deferred item); a write failure here is
  silent by necessity in this cut.
- Foundation Models requested-but-unavailable ⇒ resolver falls back to `.claudeCLI`; the
  UI shows the availability state so the fallback is not surprising.

## Testing

- **PensieveKit unit tests** (the unit-testable surface):
  - `Preferences.read`/`.write` round-trip through a **temp file URL passed explicitly**
    (matching every other Kit test — no env-var use, so no parallel-test race).
  - Missing / unreadable / corrupt-JSON file all resolve to `.auto`.
  - `resolveProviderKind` covers every (preference × foundationAvailable) combination,
    including `.foundationModels` + unavailable → `.claudeCLI` fallback.
  - **`DefaultProviderTests` updated** to pass an explicit nonexistent `prefsURL` (forcing
    `.auto`) so it doesn't read the live prefs file — its existing assertion is preserved.
  - Existing tests stay green (no changes to the trust gate or ingestion); net +1 test file
    (`PreferencesTests`) plus the one-line `DefaultProviderTests` change.
- **App target** (no unit tests, per convention): `xcodebuild` build + non-blocking
  smoke-launch of the inner binary with throwaway
  `PENSIEVE_DB`/`PENSIEVE_CAPTURE_DB`/`PENSIEVE_PREFS`. Add a matching **disabled
  `PENSIEVE_PREFS`** entry to the Xcode scheme's env vars (next to the existing disabled
  `PENSIEVE_DB`/`PENSIEVE_CAPTURE_DB`) so a sandboxed dev run doesn't read/write the LIVE
  `preferences.json`.

### Human-verify carries (interactive; can't be asserted headlessly)

- **⌘,** (and Pensieve ▸ Settings…) opens the Settings pane.
- Each knob persists across an app relaunch.
- Provider picker shows Foundation Models' real availability; picking it on an
  unsupported machine shows the fallback note.
- A provider choice made in the app is honored by a subsequent `pensieve sync` /
  ingestion run (both processes read the same file).
- Hide Dock icon actually removes the dock tile (menu-bar item remains, window usable);
  un-toggling restores it — across relaunch too.
- Narration toggle off hides/does-not-generate "Last Work Done"; on restores it.
- German renders in situ (`-AppleLanguages '(de)'`) for all new chrome.

## Localization

German localization of **the new chrome the app actually owns** into the String Catalog
(`Localizable.xcstrings`): the `Form` section headers, the three knob labels, and the
availability/fallback note. **Not** the "Settings…" menu item or the Preferences window
title — macOS supplies and localizes those from `CFBundleName` + locale; they are not ours
to key. Reconciled **by hand** against the Swift literals (the known xcstrings gotcha:
`xcodebuild` does not auto-populate the source catalog). Provider *names* ("Foundation
Models", "claude -p") are proper nouns and stay as-is. The availability note is a **locale
string driven off `FoundationModelsProbe.isAvailable()`** — do not surface
`availabilityDescription()`'s raw English diagnostic text in the UI. No captured content is
ever localized.

## Files (anticipated)

**PensieveKit (new/changed):**
- `Sources/PensieveKit/LLM/Preferences.swift` — new: `ProviderPreference` (the only new
  type), `Preferences.read(from:)/.write(_:to:)`, `resolveProviderKind(…) -> String`.
- `Sources/PensieveKit/LLM/DefaultProvider.swift` — `makeDefaultLLMProvider(prefsURL:)` /
  `defaultProviderKind(prefsURL:)` resolve the prefs URL (explicit → `PENSIEVE_PREFS` →
  default), read the preference + probe through the resolver.
- `Sources/PensieveKit/Support/PensievePaths.swift` — add `preferencesURL()`.
- `Tests/PensieveKitTests/PreferencesTests.swift` — new.
- `Tests/PensieveKitTests/DefaultProviderTests.swift` — pass an explicit nonexistent
  `prefsURL` (force `.auto`).

**App target (new/changed):**
- `Sources/PensieveApp/SettingsView.swift` — new: the `Settings` scene General pane.
  Reads/writes `Preferences` **directly** and calls `FoundationModelsProbe.isAvailable()`
  directly for the availability note (no `@Published` mirror on `AppModel`); on a provider
  write it asks `AppModel` to rebuild its summary builder.
- `Sources/PensieveApp/PensieveApp.swift` — add the `Settings` scene to the `App` body.
- `Sources/PensieveApp/AppDelegate.swift` — add `applicationDidFinishLaunching` reading the
  shared `hideDockIcon` key and applying activation policy.
- `Sources/PensieveApp/DetailView.swift` — gate auto-narration `.task` **and** cached-prose
  render on `narrationEnabled`.
- `Sources/PensieveApp/AppModel.swift` — the **one** change: a method to rebuild
  `summaryBuilder` with a freshly resolved provider (called after a provider-pref write).
- A shared defaults-key constant (e.g. `AppDefaults`) for `hideDockIcon` /
  `narrationEnabled` so the `@AppStorage` bindings and the `AppDelegate` reader can't drift.
- `Sources/PensieveApp/Localizable.xcstrings` — new German keys (Form labels + note only).
- `project.yml` — add a disabled `PENSIEVE_PREFS` scheme env var (then `xcodegen generate`).

## Process

Design-first → this spec → **adversarial spec review** (done: two independent Opus
subagents vs. the real code; no Critical, verdict "revise then plan") → `writing-plans` →
subagent-driven build in an isolated worktree (Sonnet impl+review per task; **Opus**
whole-branch review) → `finishing-a-development-branch`.

**Adversarial review folded in (2026-07-08):** the lazy `summaryBuilder` no-op (app knob
needs an explicit rebuild, diagram corrected); `DefaultProviderTests` would read the live
prefs file (now takes an explicit `prefsURL`); `PENSIEVE_PREFS` moved out of PensieveKit
into the injectable factory param (explicit-URL injection in tests, no parallel-test env
race); the missing `applicationDidFinishLaunching` + explicit `NSApp.activate` on
toggle-back; shared defaults-key constant (AppDelegate can't use `@AppStorage`); narration
gate must cover cached render, not just generation; Settings menu/window titles are
system-localized (not ours); availability note driven off `isAvailable()`, not raw
`availabilityDescription()`; single `ProviderPreference` enum (no second `ProviderKind`);
provider read/write in `SettingsView` directly (no `@Published` mirror); disabled
`PENSIEVE_PREFS` scheme env var for isolated dev runs.
