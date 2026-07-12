# App Settings v2 + organizing-writes error surfacing — design

**Date:** 2026-07-12
**Status:** approved (brainstorm)
**Scope:** app-target-only, plus one tested PensieveKit status kernel. No trust-gate, capture, or
schema changes. This is **Spec 1 of 2** for the "Settings follow-ups" track; **Spec 2** (its own
brainstorm) will cover the backend-touching source-management GUI and sync-daemon interval editing.

## Motivation

Two threads deferred out of the first Settings cut (2026-07-08), plus a general polish pass:

1. **Organizing-writes error surfacing.** The app's five tree-organizing writes (New/Edit/Move/
   Merge/Delete) and the loose-end label write all `try?`-swallow failures in `AppModel`, giving the
   user no signal when an operation silently does nothing. Roadmap item under "Settings follow-ups."
2. **Settings polish.** The current `SettingsView` is a single grouped `Form` (General + Intelligence)
   at a fixed 460 pt width. It has no About/status/store info and the cloud subsection is cramped.

The user asked to tackle the deferred error surfacing **and** polish the Settings pane generally. The
polish decomposes into: tabbed restructure, visual refinement, cheap status/path readouts, and an
About entry (which belongs in the native "About Pensieve" menu item, not a Settings tab).

## Non-goals (deferred to Spec 2)

- **Source management GUI** (wrapping `pensieve scan`: list/add/remove capture-and-scan folders).
- **Sync-daemon interval editing** (rewriting the `com.pensieve.sync` LaunchAgent plist + re-bootstrap).

The Advanced tab in this spec only *reads* daemon/provider status; it never mutates the daemon.

## Design

### 1. Tabbed Settings window

Replace the single grouped `Form` in `SettingsView` with a native macOS multi-pane `TabView` — the
first-party settings pattern — with three tabs, each an SF-Symbol `.tabItem`:

- **General** (`gearshape`) — Hide Dock icon (menu-bar-only) toggle. Intentionally short; standard
  macOS General tabs often are. `onChange` behavior (activation policy) is unchanged.
- **Intelligence** (`sparkles`) — "Last Work Done" narration toggle; LLM Provider picker + help
  caption + FM-availability note + the cloud subsection. **Behavior unchanged** — the existing cloud
  logic (Keychain commit-on-submit/close/disappear, Fetch models, vendor presets, `rebuildSummaryBuilder`)
  is moved verbatim into the Intelligence tab, just given vertical room.
- **Advanced** (`wrench.and.screwdriver`) — status readouts + store paths/logs (section 2).

The fixed `.frame(width: 460)` moves onto each tab's content (or a shared modifier) so each tab sizes
consistently; the window sizes to the visible tab, per standard settings behavior.

Refactor note: to keep files focused, the cloud subsection (`cloudSection`, `modelOptions`, `canFetch`,
`vendorSelection`, `resetCloudFieldsForVendorChange`, `reloadKeyForAccount`, `commitKey`, `fetchModels`
and their `@State`/`@AppStorage`) may be extracted into an `IntelligenceSettingsTab` view; General and
Advanced become their own small tab views. `SettingsView` becomes the thin `TabView` shell. This is a
targeted improvement of a file that will otherwise grow — not unrelated refactoring.

### 2. Advanced tab — status readouts + store paths/logs

**Tested Kit kernel** `SystemStatus` (SwiftUI-free, no throw, best-effort — every field degrades to a
sensible default rather than throwing):

```
public struct SystemStatus: Sendable, Equatable {
  public var providerKind: String          // resolved kind, e.g. "foundation-models" / "claude-cli" / "cloud"
  public var foundationModelsAvailable: Bool
  public var daemonInstalled: Bool          // LaunchAgent plist file exists
  public var lastSyncAt: Date?              // sync.log file mtime (nil if absent)
  public var lastEventAt: Date?             // most-recent canonical Event.at (nil if store empty/unreadable)
}

public enum SystemStatusGatherer {
  public static func gather(db: (any DatabaseReader)?,
                            defaults: UserDefaults,
                            cloudConfig: CloudConfig?,
                            apiKeyPresent: Bool,
                            launchAgentURL: URL,   // PensievePaths.launchAgentURL()
                            syncLogURL: URL,        // PensievePaths.syncLogURL()
                            now: Date) -> SystemStatus
}
```

- `providerKind` reuses the existing shared `resolvedProviderKind(defaults:cloudConfig:apiKey:)`.
- `foundationModelsAvailable` reuses `FoundationModelsProbe.isAvailable()`.
- `daemonInstalled` = `FileManager.fileExists` at the LaunchAgent plist URL.
- `lastSyncAt` = mtime of `syncLogURL` via `resourceValues(.contentModificationDateKey)`.
- `lastEventAt` = a read-only `max(Event.at)` query (best-effort; `nil` on empty/error).

Paths and `defaults`/URLs are **injected** so the kernel is deterministically testable against a temp
store + temp files, mirroring the existing provider-resolution tests. No hidden globals.

**View** (thin `AdvancedSettingsTab`): renders the status fields as labeled rows (provider name +
FM-availability note; "Sync daemon: Installed/Not installed"; "Last sync: <relative/absolute>";
"Last captured activity: <…>"). Absent values show an honest em-dash / "Never".

**Store & Logs** group: rows for canonical / spool / support / logs paths, each with a **Reveal in
Finder** button (`NSWorkspace.shared.activateFileViewerSelecting([url])`), plus an **Open Logs Folder**
button (`NSWorkspace.shared.open(logsDirectory)`). Paths come from `Stores.canonicalURL` /
`Stores.spoolURL` / `PensievePaths.supportDirectory()` / `PensievePaths.logsDirectory()`.

The Advanced tab reads status once on appear (and could refresh on `.onAppear`); no live observation is
required — it's an informational glance, consistent with the read-only settings surface.

### 3. Organizing-writes error surfacing

Every write today has **two** failure modes, both currently swallowed by `_ = try? …`:

- **Refusal** — the command returns a non-success value without throwing: `reparent`→`false`,
  `add`/`update`→`nil`/`false`, `delete`→`.blocked`/`.notFound`. These are guard/stale-state
  rejections (e.g. a node deleted by a concurrent sync between menu-open and click; the pickers
  already exclude most illegal targets).
- **Throw** — an actual DB error (unexpected).

**Mechanism:**

```
struct AppError: Identifiable { let id = UUID(); let title: String; let message: String }
// on AppModel:
@Published var presentedError: AppError?
```

Mounted once in `RootView`:

```
.alert(item: $model.presentedError) { err in
  Alert(title: Text(err.title), message: Text(err.message), dismissButton: .default(Text("OK")))
}
```

**Wiring** — the six writes drop `try?` and classify the outcome:

| Write             | Success | Refusal → message | Throw → message |
|-------------------|---------|-------------------|-----------------|
| `commitNewNode`   | `Node`  | `nil` (unknown parent) | error |
| `updateNode`      | `true`  | `false` (unknown node) | error |
| `move`            | `true`  | `false` (cycle/unknown/stale) | error |
| `merge`           | (void via `group`) | — (no bool; catch throw only) | error |
| `deleteNode`      | `.deleted` | `.blocked` / `.notFound` | error |
| `setLooseEndLabel`| `true`  | `false` | error |

- **Refusal copy** (honest, non-alarming): e.g. *"Couldn't move "\<name\>". It may have changed — try
  again."* `delete` `.blocked` gets its own copy: *"Can't delete "\<name\>" — it still has captured
  sources or activity that would return on the next sync."* (mirrors the existing gating rationale).
- **Error copy**: *"Couldn't move "\<name\>": \<error localizedDescription\>."*
- On refusal/error, the write does **not** proceed with post-write state changes (selection moves,
  refresh happens only on success — matching current behavior, which only refreshed after the op).

`AppError` is a plain struct; the refusal/throw classification lives inline in the thin `AppModel`
writes (no new Kit surface — the Kit commands already return the distinguishing values). `merge` has no
boolean return from `ProjectResolver.group`, so only its throw is surfaced (a self-merge is already
guarded by `sourceID != targetID`).

### 4. About menu (native)

Add to the app's `.commands`:

```
CommandGroup(replacing: .appInfo) {
  Button("About Pensieve") { AppInfo.showAboutPanel() }
}
```

`AppInfo.showAboutPanel()` calls `NSApplication.shared.orderFrontStandardAboutPanel(options:)` with
`.applicationName`, `.applicationVersion`/build (from `Bundle.main.infoDictionary`), and a short
`.credits` `NSAttributedString`: *"A personal tool for reloading context across parallel projects. Not
a product."* No Settings tab for About.

### 5. Localization & testing

- All new chrome strings → German keys in `Localizable.xcstrings` (impersonal/infinitive). Paths,
  version/build numbers, provider raw kinds, and vendor names stay untranslated.
- **Tested in PensieveKit:** `SystemStatusGatherer.gather` (deterministic against a temp store + temp
  files + injected `UserDefaults`; covers each field present/absent). This is the only new logic that
  can be unit-tested.
- **App views stay thin** (`TabView` shell, three tab views, `AdvancedSettingsTab` reading the kernel,
  the `.alert`). Verified by `xcodebuild` build + a non-blocking smoke-launch of the inner binary with
  throwaway `PENSIEVE_DB`/`PENSIEVE_CAPTURE_DB`.

## Human-verify carries (need the built app + real store + plain `open`)

- ⌘, opens a tabbed window; General/Intelligence/Advanced switch; each knob persists across relaunch;
  the cloud subsection is fully functional in its new home (Fetch, key persistence, model reset).
- Advanced shows the resolved provider, FM-availability note, daemon Installed/Not, last-sync and
  last-activity times; Reveal-in-Finder opens each store path; Open Logs Folder works.
- Force a refused write (e.g. delete an activity-born node via a stale menu, or trigger a stale move)
  → the alert appears with honest copy and the op does nothing; a normal op still succeeds silently.
- "About Pensieve" (app menu) shows version/build + the credit line.
- German in situ (`-AppleLanguages '(de)'`) for all new chrome; paths/versions/vendor names stay
  English.

## Build

`xcodegen generate && xcodebuild -project Pensieve.xcodeproj -scheme Pensieve -configuration Debug
-derivedDataPath ./.build-xcode build`, then `open ./.build-xcode/Build/Products/Debug/Pensieve.app`.
