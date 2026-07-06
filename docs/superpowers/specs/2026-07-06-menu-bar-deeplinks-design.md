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
and is injected into **both** scenes (as `@ObservedObject` in the child views — never a second
`@StateObject`). They share **one polling model and one source of truth** — the existing 3 s `Timer`
+ launch drain in `AppModel` feed the menu bar for free.

The always-visible menu-bar **label encodes `snapshot.status` by glyph *shape*, not color**
(`active` → `circle.fill`, `idle` → `circle`, `notSetUp` → `circle.slash` — final glyphs TBD in the
plan). Rationale (review finding): macOS renders menu-bar item images as **template (monochrome)** —
a `.foregroundStyle` color tint is discarded, and opting out of template rendering to force color
loses the automatic light/dark adaptation. Encoding status in the glyph keeps a clean, adaptive
template symbol *and* a visible status change. Icon-only, no count badge.

**Liveness:** the menu bar must not depend on the main window ever having opened. Today `start()`
(which opens the canonical `db` and starts the 3 s `Timer`) fires only from the Window's
`.task { model.start() }`; `refresh()` early-returns with an empty What's Next while `db == nil`.
So the always-mounted `MenuBarExtra` **label** view carries `.task { model.start() }` too (idempotent,
guarded by `started`) — guaranteeing the store is open and polling is running regardless of window
state. The popover additionally calls `model.refresh()` on open (cheap, read-only, no drain), since
the 3 s `Timer` is suppressed while a menu-tracking run loop is active.

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
  where `SmartList` is a nested `public enum SmartList: String { case whatsNext, dormant, recentlyActive }`
  owned by `DeepLink` (so no UI concern — the app's `SmartListKind` title/symbol — leaks into the
  kit). **Its case names / raw values are identical to the app's `SmartListKind` raw values**
  (`SmartListKind: String` in `AppModel.swift` → `"whatsNext"/"dormant"/"recentlyActive"`), so the
  app-side bridge is a one-liner `SmartListKind(rawValue: dl.rawValue)` and the URL token is
  `.rawValue` — no hand-maintained string tables to drift.
  - `public init?(url: URL)` — parses `pensieve://briefing`, `pensieve://node/<uuid>`,
    `pensieve://smartlist/<whatsNext|dormant|recentlyActive>`. Returns `nil` for an unknown scheme,
    unknown host, malformed UUID, or unknown smart-list token.
  - `public var url: URL` — serializes the inverse. Round-trips: `DeepLink(url: link.url) == link`.
  - Host-based routing: `pensieve://<host>/<path>`. Host = `briefing` | `node` | `smartlist`.
  - Unit-tested: round-trip for every case + rejection of each malformed form.

`DeepLink` is `Equatable` to make round-trip assertions clean.

### PensieveApp (thin views)

- **`MenuBarView`** — the popover content. Renders:
  - the heartbeat line from `model.snapshot` (status glyph, last-capture relative age via a **local**
    `RelativeDateTimeFormatter` / `Date.formatted` — never a shared mutable `static`, open-loose-end
    count);
  - the top-5 `model.lists.whatsNext` rows (`NextItem` → node `name` + "`openLooseEnds` open ·
    `daysDormant`d dormant"; note `whatsNext` can include 0-loose-end nodes ranked by dormancy —
    "0 open · 21d dormant" rows are expected and correct);
  - the footer: **Open Pensieve**, **Refresh**, **Quit**.
  - On popover open (`.task` / `onAppear`): calls `model.refresh()` (cheap, read-only, **no drain**).
  - Rows and "Open Pensieve" call the **in-process** `apply(_:)` handler with a `DeepLink` value
    (Row → `.node(id)`; Open Pensieve → `.briefing`) — **not** `openURL` / Launch Services.
  - **Refresh** calls `model.refreshNow()` (the existing drain+refresh, matching ⌘R). **Quit** is
    the standard terminate.

- **One `apply(_ link: DeepLink)` navigation handler**, hosted in a view where
  `@Environment(\.openWindow)` is available in an **always-mounted** scene (the `MenuBarExtra`
  label). It:
  1. converts `DeepLink` → the app's existing **`PaletteDestination`** via a single **exhaustive
     `switch`** (`briefing→.briefing`, `node(id)→.node(id)`,
     `smartList(x)→.smartList(SmartListKind(rawValue: x.rawValue)!)`) — so a future 4th smart list
     fails to compile in both places;
  2. `openWindow(id: "main")`;
  3. `NSApplication.shared.activate()` — the macOS 14 **cooperative** form, **not** the deprecated
     `activate(ignoringOtherApps:)` — so the window fronts even from a background external open;
  4. `dest.apply(to: model)` — the **existing** ⌘K path, which sets *both* `sidebarSelection` **and**
     `selectedNodeID` (`RootView`'s detail pane keys off `selectedNodeID`). **No second navigation
     implementation** is introduced.

### Routing decision (the core mechanism — resolved from spec review)

Both reviewers flagged the original "route every click through `openURL(pensieve://…)` →
`.onOpenURL` on the `Window`" as **unreliable and likely-breaking**: (a) in-process `openURL` of a
custom scheme goes through Launch Services, which may route to a *different* registered `Pensieve.app`
(a stale build under a throwaway derived-data path) or launch a second instance rather than reaching
the live one; and (b) `.onOpenURL` on the `Window` view fires only while that view is *mounted* — but
a menu-bar item's whole point is running with the main window **closed**, so the reopener would live
on the closed window (chicken-and-egg). Resolution:

- **Internal** menu-bar clicks apply navigation **directly in-process** via `apply(_:)` — no Launch
  Services, no dependency on the `Window` being mounted.
- **External** `pensieve://` opens (the terminal smoke test today; future widgets/Spotlight) are
  received by an **`NSApplicationDelegateAdaptor` `AppDelegate.application(_:open:)`** — a
  scene-independent entry point that fires regardless of window state. It parses each URL →
  `DeepLink` and sets a new **`@Published var pendingDeepLink: DeepLink?`** on `AppModel`. The
  always-mounted `MenuBarExtra` label carries `.onChange(of: model.pendingDeepLink)` → calls the same
  `apply(_:)` → clears it. Internal and external entry funnel to **one** `apply(_:)`, and the
  reopener lives on an always-mounted host.
- **No `.onOpenURL` on the `Window`.** (If, during implementation, `.onOpenURL` is proven to reliably
  reopen a closed single `Window` for external opens, the `AppDelegate` may later be simplified away —
  but the `AppDelegate` path is the baseline precisely because it is *not* window-lifetime-dependent.)

### project.yml — Info.plist switch (regression-sensitive; resolved from review)

Registering the scheme needs `CFBundleURLTypes` — an **array of dicts**, *not* a scalar
`INFOPLIST_KEY_*`. Switch the `Pensieve` target from `GENERATE_INFOPLIST_FILE: "YES"` to an
**XcodeGen-managed `info:` plist**. **Both reviewers flagged that this can silently drop keys the
generate path currently synthesizes from build settings.** So the `info:` `properties` must
*explicitly* carry these, not assume them:

```yaml
info:
  path: Sources/PensieveApp/Info.plist   # XcodeGen-managed; path is illustrative
  properties:
    CFBundleName: Pensieve                       # menu-title fix (was via generate)
    CFBundleShortVersionString: "$(MARKETING_VERSION)"   # was auto from MARKETING_VERSION
    CFBundleVersion: "1"   # literal — CURRENT_PROJECT_VERSION isn't set in project.yml (was auto = 1)
    CFBundleIconName: Pensieve                   # was auto from ASSETCATALOG_COMPILER_APPICON_NAME
    LSMinimumSystemVersion: "$(MACOSX_DEPLOYMENT_TARGET)"
    CFBundleURLTypes:
      - CFBundleURLName: me.mazetti.pensieve
        CFBundleURLSchemes: [pensieve]
```

Also **remove `GENERATE_INFOPLIST_FILE`** (or set it `NO`) — leaving it on alongside an
`INFOPLIST_FILE` is a conflicting Xcode config. Keep `ASSETCATALOG_COMPILER_APPICON_NAME: Pensieve`
in `settings` (it still drives asset-catalog compilation; `CFBundleIconName` is the plist key it
would otherwise inject). **Baseline before changing:** the app builds today via generate, so capture
the current `Contents/Info.plist` first, then diff after the switch and confirm `CFBundleName`,
`CFBundleShortVersionString` (= 0.2, not 1.0), `CFBundleIconName`, and `LSMinimumSystemVersion` all
survive — checking `CFBundleURLTypes` alone is **not** sufficient.

## Data flow

1. The existing 3 s `Timer` in `AppModel` refreshes `snapshot` + `lists` (unchanged); the menu bar
   also refreshes on popover open (the `Timer` is suppressed while a menu-tracking run loop is active).
2. Both scenes read the shared `@Published` state.
3. **Internal** jump-in: menu-bar row tap → `apply(.node(id))` (in-process) → `openWindow` +
   `NSApplication.activate()` + `PaletteDestination.apply(to:)`. No Launch Services.
4. **External** entry: `open "pensieve://node/<uuid>"` → `AppDelegate.application(_:open:)` →
   `DeepLink(url:)` → `model.pendingDeepLink` → always-mounted label `.onChange` → same `apply(_:)`.

## Testing / verification

- **`DeepLink` round-trip + malformed-URL rejection** tests in `PensieveKitTests` — the tested
  portion; views stay thin. Cover every case's round-trip and each malformed form
  (bad scheme, bad host, non-UUID node, unknown smart-list token, missing path).
- The app target has **no unit tests** (per project convention). Verify with:
  - **Baseline the Info.plist** (build once pre-change, save `Contents/Info.plist`).
  - `xcodegen generate` → `xcodebuild -project Pensieve.xcodeproj -scheme Pensieve -configuration
    Debug -derivedDataPath ./.build-xcode build` succeeds;
  - **diff the built `Info.plist`** vs baseline: confirm `CFBundleName`, `CFBundleShortVersionString`,
    `CFBundleIconName`, `LSMinimumSystemVersion` survive **and** `CFBundleURLTypes` is present;
  - non-blocking smoke-launch of the inner binary
    (`./.build-xcode/Build/Products/Debug/Pensieve.app/Contents/MacOS/Pensieve`, background + `kill`,
    throwaway `PENSIEVE_DB`/`PENSIEVE_CAPTURE_DB`);
  - full suite (138 existing + new `DeepLink` tests) green via `./scripts/test.sh`.
  - Manual smoke: menu-bar glyph appears and **changes with status** (shape, not color); popover shows
    heartbeat + What's Next; clicking a row opens/focuses the window at that node.
  - **External-open smoke (prove the C1 fix):** before testing `open pensieve://…`, register the built
    bundle so Launch Services resolves the scheme to *this* copy and no stale copy wins —
    `lsregister -f ./.build-xcode/Build/Products/Debug/Pensieve.app` (confirm with `lsregister -dump |
    grep -i pensieve`). Then, **with the main window closed**, run `open "pensieve://node/<uuid>"` and
    confirm the window **reopens and navigates** (add a temporary log in `apply(_:)` to confirm it
    fires in the live process).

## Risks / notes

- `MenuBarExtra`'s `.window` popover has quirks around sizing; keep the content a fixed-ish width
  (~300pt) with a bounded height so it lays out predictably. Its content is instantiated lazily and
  `.task`/`onAppear` fire on each open — so refresh-on-open works.
- Two scenes sharing one `AppModel` is fine (`@MainActor ObservableObject`, `@StateObject` at App
  level, `@ObservedObject` in child views); the poll runs off the model, so it survives the main
  window being closed. The gap is *never-started*, not *stops-after-close* — hence the label's
  `.task { model.start() }` (idempotent) so What's Next populates even if the window never opened.
- The `info:` plist switch is the highest build-config risk — see the explicit before/after diff above.
- The `openURL`→`.onOpenURL` round-trip is **not** used for in-process navigation (see Routing
  decision); external opens use the scene-independent `AppDelegate`.

## Deferred → backlog ledger (record on merge)

- `LSUIElement` / hide-dock toggle (needs a Settings surface).
- Menu-bar icon count badge.
- Dormant / Recently-Active peek in the popover.
- External `pensieve://` consumers (widgets, Spotlight, notifications) — scheme is ready.
