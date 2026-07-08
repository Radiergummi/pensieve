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

- **`ProviderPreference`** — an enum `.auto` / `.foundationModels` / `.claudeCLI`,
  raw-string-backed (stable on-disk values `"auto"` / `"foundationModels"` /
  `"claudeCLI"`).
- **`Preferences`** — reads/writes `preferences.json` in
  `PensievePaths.supportDirectory()`:
  - Atomic write (`Data.write(to:options:.atomic)`).
  - Missing file, unreadable, or corrupt JSON ⇒ `.auto` (today's behavior — never throws
    into a caller; the preference read is best-effort).
  - Honors a **`PENSIEVE_PREFS`** env override (path to the prefs file) mirroring the
    existing `PENSIEVE_DB` / `PENSIEVE_CAPTURE_DB` pattern, so tests and throwaway
    launches never touch the real file.
  - Shape is a single small JSON object, e.g. `{"llmProvider":"claudeCLI"}` — additive
    keys allowed later without breaking older readers (unknown keys ignored; missing keys
    default).
- **`resolveProviderKind(preference:foundationAvailable:) -> ProviderKind`** — a **pure**
  function holding the whole decision, fully unit-testable:
  - `.auto` → `foundationAvailable ? .foundationModels : .claudeCLI` (today's logic).
  - `.foundationModels` → `.foundationModels` if available, else **falls back to**
    `.claudeCLI` (transparent — the UI notes this).
  - `.claudeCLI` → always `.claudeCLI`.
- **`makeDefaultLLMProvider()`** and **`defaultProviderKind()`** read the preference file
  + run the existing `FoundationModelsProbe`, feed both into `resolveProviderKind`, and
  construct the chosen provider. **No call-site signature changes** — all five existing
  call sites (`Ingest`, `Digest`, `Sync`, `AppModel`) keep calling argument-free. Both the
  app's narration and the daemon's trust-gated extraction now honor the same choice.

**The trust gate is untouched.** This selects *which* provider runs behind the gate; the
grounding/citation logic is unchanged.

## Component 2 — the two app-process toggles (app target only)

**Hide Dock icon (menu-bar-only mode).** `@AppStorage("app.hideDockIcon")` bool (default
false). Applied via `NSApp.setActivationPolicy(.accessory)` when true / `.regular` when
false, done **at launch** in the existing `AppDelegate` *and* immediately on toggle. The
`MenuBarExtra` already keeps the app alive with no dock icon, so this is a safe real
"menu-bar-only" mode. Closes the `LSUIElement` item deferred from v0.2 — implemented at
runtime via activation policy, so the static `Info.plist` default stays dock-visible.
*Verify in smoke-launch:* toggling to `.accessory` while the main window is key leaves the
window usable (AppKit re-associates; confirm).

**"Last Work Done" narration on/off.** `@AppStorage("app.narrationEnabled")` bool (default
true). `DetailView`'s auto-narrate `.task` gates on it; when off, the narration section
does not render or generate (and ⌘R does not force it while off). No PensieveKit change —
narration is already best-effort and outside the trust gate.

## Data flow

```
Settings pane (Form)
  ├─ Provider Picker ──write──▶ Preferences.write(preferences.json)   [shared support dir]
  │                              ▲
  │        makeDefaultLLMProvider() reads ┤ (app process: next narration/⌘R)
  │        makeDefaultLLMProvider() reads ┘ (daemon process: next `pensieve sync` run)
  ├─ Hide Dock toggle ──write──▶ @AppStorage ──▶ NSApp.setActivationPolicy(...)
  └─ Narration toggle ─write──▶ @AppStorage ──▶ DetailView .task gate
```

The provider choice takes effect on the *next* provider construction in each process
(next narration/⌘R in the app; next 300 s launchd cycle or manual `pensieve sync` in the
daemon) — no live signalling needed for a single-user tool. This is stated as accepted
behavior, not a bug.

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
  - `Preferences` round-trips through a temp file (via `PENSIEVE_PREFS`).
  - Missing / unreadable / corrupt-JSON file all resolve to `.auto`.
  - `resolveProviderKind` covers every (preference × foundationAvailable) combination,
    including `.foundationModels` + unavailable → `.claudeCLI` fallback.
  - Existing 211 tests stay green (no changes to the trust gate or ingestion).
- **App target** (no unit tests, per convention): `xcodebuild` build + non-blocking
  smoke-launch of the inner binary with throwaway
  `PENSIEVE_DB`/`PENSIEVE_CAPTURE_DB`/`PENSIEVE_PREFS`.

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

German localization of **all new chrome** into the String Catalog
(`Localizable.xcstrings`): the Settings/section titles, the three knob labels, the
provider-option display names, and the availability/fallback note. Reconciled **by hand**
against the Swift literals (the known xcstrings gotcha: `xcodebuild` does not
auto-populate the source catalog). Provider *names* ("Foundation Models", "claude -p") are
proper nouns and stay as-is. No captured content is ever localized.

## Files (anticipated)

**PensieveKit (new/changed):**
- `Sources/PensieveKit/LLM/Preferences.swift` — `ProviderPreference`, `Preferences`,
  `resolveProviderKind`, `ProviderKind`.
- `Sources/PensieveKit/LLM/DefaultProvider.swift` — `makeDefaultLLMProvider` /
  `defaultProviderKind` read the preference + probe through the resolver.
- `Tests/PensieveKitTests/PreferencesTests.swift` — new.

**App target (new/changed):**
- `Sources/PensieveApp/SettingsView.swift` — the `Settings` scene General pane (new).
- `Sources/PensieveApp/PensieveApp.swift` — add the `Settings` scene to the `App` body.
- `Sources/PensieveApp/AppDelegate.swift` — apply `hideDockIcon` activation policy at
  launch.
- `Sources/PensieveApp/DetailView.swift` — gate auto-narration on `narrationEnabled`.
- `Sources/PensieveApp/AppModel.swift` — bridge the provider picker to `Preferences`
  read/write (and expose Foundation Models availability for the UI).
- `Sources/PensieveApp/Localizable.xcstrings` — new German keys.

## Process

Design-first → this spec → **adversarial spec review** (1–2 Opus subagents vs. the real
code) → `writing-plans` → subagent-driven build in an isolated worktree (Sonnet
impl+review per task; **Opus** whole-branch review) → `finishing-a-development-branch`.
