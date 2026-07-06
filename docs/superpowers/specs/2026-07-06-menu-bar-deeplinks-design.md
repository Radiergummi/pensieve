# Menu-bar item + `pensieve://` deep links (v0.2) — design

**Date:** 2026-07-06
**Status:** approved (brainstorm complete), pre-plan
**Pillar:** #1 (Menu-bar item / `LSUIElement`) from `docs/superpowers/backlog.md`, folding in the
foundational `pensieve://` URL scheme from the "Platform extension points" menu.

## Goal

Add a menu-bar status item to `Pensieve.app` — a rich popover glance that shows the capture
heartbeat **and** a short "What's Next" list you can click to jump into the main window — and, as
its first real consumer, register a minimal `pensieve://` URL scheme with a tested deep-link router.

This is the first OS-integration surface. It is unblocked by the completed `.app` bundle (Xcode
adoption). It reads the **already-tested grounded kernel** (`MonitorSnapshot` + `SmartLists`) and
never re-derives or fabricates — the north-star discipline is satisfied by construction.

## Non-goals (deferred → backlog ledger)

- The `LSUIElement` / "hide dock icon (menu-bar only)" toggle. It needs a Settings surface to host
  it and is a real behavior change; **the app stays additive** (dock icon + window untouched).
- A count badge on the menu-bar icon.
- Showing Dormant / Recently-Active in the popover (What's Next only; "Open Pensieve" for the rest).
- External deep-link consumers (widgets, Spotlight, notifications). The scheme is *built* here; each
  consumer arrives with its own spec.

## Decisions locked during brainstorming

1. **Primary job:** both equal weight — heartbeat **and** What's Next — so a rich popover, not a
   lightweight dropdown menu.
2. **Dock relationship:** additive only, no toggle. No activation-policy change.
3. **`pensieve://`:** fold in a *minimal* scheme now (register + tested router), with the menu-bar
   actions as the first consumer, proving it end-to-end.
4. My-call details the user approved: **top-5** What's Next depth; **refresh-on-open**; **What's Next
   only** in the popover; **icon-only** menu-bar label (no count badge).

## Architecture — one app, two scenes

Add a second SwiftUI `Scene` — `MenuBarExtra(...)` with `.menuBarExtraStyle(.window)` (a rich
popover) — alongside the existing `Window("Pensieve", id: "main")` in `PensieveApp`. **Same process,
same `Pensieve.app` bundle**; no separate agent. `MenuBarExtra` and `.window` style are macOS 13+;
the deployment target is macOS 14.0, so both are available.

The `@StateObject private var model = AppModel()` stays hoisted at the `App` level (it already is)
and is injected into **both** scenes. They share **one polling model and one source of truth** — the
existing 3 s `Timer` + launch drain in `AppModel` feed the menu bar for free.

The always-visible menu-bar **label is an SF Symbol tinted by `snapshot.status`**
(`active` / `idle` / `notSetUp`) — icon-only, no count badge. `Label`/`Image` with a
`.foregroundStyle` driven by status; template-rendered so it adapts to menu-bar light/dark.

```
┌─ menu-bar popover (.window) ──────────────┐
│ ● Active · captured 2m ago · 3 open       │   heartbeat line  (model.snapshot)
│───────────────────────────────────────────│
│ What's Next                               │
│  pensieve-sync      2 open · 6d dormant   │   top 5 of model.lists.whatsNext,
│  auth-refactor      1 open · 14d dormant  │   each row a jump-in target
│  briefing-home      0 open · 21d dormant  │
│───────────────────────────────────────────│
│  Open Pensieve            Refresh    Quit │   footer actions
└───────────────────────────────────────────┘
```

Empty state: when `whatsNext` is empty, the list area shows a single muted "Nothing queued" row;
the heartbeat line and footer still render.

## Components

### PensieveKit (tested — derivation lives here)

- **`DeepLink`** — a `public enum` with cases `briefing`, `node(UUID)`, `smartList(SmartList)`,
  where `SmartList` is a nested `public enum { whatsNext, dormant, recentlyActive }` owned by
  `DeepLink` (so no UI concern — the app's `SmartListKind` title/symbol — leaks into the kit).
  - `public init?(url: URL)` — parses `pensieve://briefing`, `pensieve://node/<uuid>`,
    `pensieve://smartlist/<whatsNext|dormant|recentlyActive>`. Returns `nil` for an unknown scheme,
    unknown host, malformed UUID, or unknown smart-list token.
  - `public var url: URL` — serializes the inverse. Round-trips: `DeepLink(url: link.url) == link`.
  - Host-based routing: `pensieve://<host>/<path>`. Host = `briefing` | `node` | `smartlist`.
  - Unit-tested: round-trip for every case + rejection of each malformed form.

`DeepLink` is `Equatable` to make round-trip assertions clean.

### PensieveApp (thin views)

- **`MenuBarView`** — the popover content. Renders:
  - the heartbeat line from `model.snapshot` (status dot + color, last-capture relative age via
    `Date.RelativeDateTimeFormatter`/`.formatted`, open-loose-end count);
  - the top-5 `model.lists.whatsNext` rows (`NextItem` → node `name` + "`openLooseEnds` open ·
    `daysDormant`d dormant");
  - the footer: **Open Pensieve**, **Refresh**, **Quit**.
  - On popover open (`.task` / `onAppear`): calls `model.refresh()` (cheap, read-only, **no drain**)
    so the glance is fresh between 3 s ticks.
  - Rows and "Open Pensieve" call `openURL(deepLink.url)` — routing **through the scheme**, not
    setting `AppModel` state directly. (Row → `.node(id)`; Open Pensieve → `.briefing`.)
  - **Refresh** calls `model.refreshNow()` (the existing drain+refresh, matching ⌘R). **Quit** is
    the standard terminate.

- **`.onOpenURL` handler** on the `Window` scene — the **single entry point** both internal
  menu-bar clicks and future external `open pensieve://…` calls flow through:
  `DeepLink(url:)` → `openWindow(id: "main")` → activate/focus → apply navigation to `AppModel`
  (map `DeepLink` → `SidebarSelection`: `.briefing`, `.node(id)` sets `selectedNodeID`,
  `.smartList` maps `DeepLink.SmartList` → app `SmartListKind`). A `nil` parse is ignored (no-op).
  The existing `PaletteDestination.apply(to:)` is the model for the navigation-application code;
  reuse or mirror it — do not duplicate navigation logic loosely.

### project.yml

Registering the scheme needs `CFBundleURLTypes` — an **array of dicts**, *not* a scalar
`INFOPLIST_KEY_*`. Switch the `Pensieve` target from `GENERATE_INFOPLIST_FILE: "YES"` to an
**XcodeGen-managed `info:` plist** with `properties: { CFBundleURLTypes: [{ CFBundleURLName:
"me.mazetti.pensieve", CFBundleURLSchemes: ["pensieve"] }] }`. XcodeGen still fills the standard
generated keys. This is the one contained infrastructure change; verify the built
`Info.plist` contains `CFBundleURLTypes` after `xcodegen generate` + build.

## Data flow

1. The existing 3 s `Timer` in `AppModel` refreshes `snapshot` + `lists` (unchanged).
2. Both scenes read the shared `@Published` state; the menu bar additionally refreshes on popover
   open.
3. Menu-bar row tap → `openURL("pensieve://node/<uuid>")` → `.onOpenURL` on the `Window` → parse →
   `openWindow` + activate + apply navigation. Jump-in is proven end-to-end via the exact path an
   external caller would take.

## Testing / verification

- **`DeepLink` round-trip + malformed-URL rejection** tests in `PensieveKitTests` — the tested
  portion; views stay thin. Cover every case's round-trip and each malformed form
  (bad scheme, bad host, non-UUID node, unknown smart-list token, missing path).
- The app target has **no unit tests** (per project convention). Verify with:
  - `xcodegen generate` → `xcodebuild -project Pensieve.xcodeproj -scheme Pensieve -configuration
    Debug -derivedDataPath ./.build-xcode build` succeeds;
  - non-blocking smoke-launch of the inner binary
    (`./.build-xcode/Build/Products/Debug/Pensieve.app/Contents/MacOS/Pensieve`, background + `kill`,
    throwaway `PENSIEVE_DB`/`PENSIEVE_CAPTURE_DB`);
  - full suite (138 existing + new `DeepLink` tests) green via `./scripts/test.sh`.
  - Manual smoke: menu-bar icon appears and tints by status; popover shows heartbeat + What's Next;
    clicking a row opens/focuses the window at that node; `open "pensieve://node/<uuid>"` from a
    terminal navigates the running app.

## Risks / notes

- `MenuBarExtra`'s `.window` popover has quirks around sizing; keep the content a fixed-ish width
  (~300pt) with a bounded height so it lays out predictably.
- Two scenes sharing one `AppModel` is fine (it's `@MainActor`, `ObservableObject`); the poll runs
  off the model, not a view, so it survives the main window being closed.
- The `info:` plist switch is the only change that can break the build config — verify the generated
  `Info.plist` explicitly.

## Deferred → backlog ledger (record on merge)

- `LSUIElement` / hide-dock toggle (needs a Settings surface).
- Menu-bar icon count badge.
- Dormant / Recently-Active peek in the popover.
- External `pensieve://` consumers (widgets, Spotlight, notifications) — scheme is ready.
