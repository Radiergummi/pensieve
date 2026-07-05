# Pensieve.app — GUI UX base-state design (2026-07-05)

Bring `Sources/PensieveApp/` to a **usable, native base state** before layering slice-3 features on
top. Today the app boots as a raw imperative `NSApplication` (hand-built `NSWindow`, `app.run()`, no
`@main` scene, no `NSMenu`, no app delegate) — so it has **no menu bar, ⌘Q does nothing, and window
lifecycle/restoration behaves unlike a real macOS app**. This slice replaces that bootstrap with the
first-party SwiftUI `App` lifecycle and fixes window chrome, sizing, and restoration.

This is **wiring, not new intelligence** — no derivation logic changes, the trust gate is untouched,
the canonical store stays read-only from the app (only `Ingester.drain()` writes). It is a prerequisite
tidy-up for the three-pane app's slice 3.

## Guiding principle

**Platform primitives first** (now in `CLAUDE.md`): prefer the first-party / OS-native mechanism over a
custom implementation wherever one exists. This slice is the principle applied concretely — SwiftUI
`App`/`Scene` + `.commands` replace a hand-rolled `NSApplication`, and scene-based window restoration
replaces manual frame autosave.

## Scope

**In:**
- Migrate the imperative bootstrap to `@main struct PensieveApp: App`.
- Full standard macOS menu bar (Pensieve/File/Edit/View/Window/Help) with working ⌘Q, ⌘W, ⌘M.
- `SidebarCommands()` (Show/Hide Sidebar, ⌃⌘S).
- ⌘K "Quick Jump…" promoted from a hidden-button hack to a real `CommandMenu("Go")` item.
- ⌘R "Refresh" command (immediate drain+refresh).
- Window default size, minimum size, and **automatic scene-based frame restoration**.
- Retire the safe-area risk (sidebar under the traffic lights) with an explicit early verification.

**Out (not this slice):**
- Multi-window / tabbing / open-in-new-window — **slice 3** (this slice deliberately uses a single
  `Window` scene, see §2).
- ⌘⌥I provenance inspector, LLM "Last Work Done" narration, `ValueObservation` liveness — **slice 3**.
- Any in-pane content/interaction redesign, light/dark + materials pass — beyond base chrome.
- Any change to PensieveKit derivation logic, capture, ingest, or the trust gate.

## Approach (chosen)

SwiftUI `App` lifecycle (over hand-building an `NSMenu`, or a preemptive `NSApplicationDelegateAdaptor`
hybrid). Rationale: it is the idiomatic native path, yields the standard menu bar + ⌘Q + activation +
window restoration for free with **less** code than today, and is where every future slice's commands
(⌘⌥I, etc.) belong. The one real risk — the titlebar safe-area inset that originally forced the manual
`NSHostingController` — is retired by an explicit smoke-launch check as the first step; the fallback if
it regresses is adding `NSApplicationDelegateAdaptor` (still keeping the App lifecycle), **not** a retreat
to manual menus.

## Design

### 1. Bootstrap: `main.swift` → `PensieveApp.swift`

Delete the imperative bootstrap (`NSApplication.shared`, manual `NSWindow`, `contentViewController = …`,
`app.run()`). Replace with a `@main struct PensieveApp: App`. Because a `@main`-bearing file cannot be
named `main.swift` (that name implies top-level executable code), **rename the file to
`PensieveApp.swift`**. The `Stores` enum currently living in `main.swift` moves into this file (or a
small `Stores.swift`), unchanged.

```swift
@main
struct PensieveApp: App {
  @StateObject private var model = AppModel()

  var body: some Scene {
    Window("Pensieve", id: "main") {
      RootView(model: model)
        .frame(minWidth: 720, minHeight: 420)
        .task { model.start() }          // idempotent; see §5
    }
    .defaultSize(width: 900, height: 560)
    .windowResizability(.contentMinSize)
    .commands {
      SidebarCommands()                  // Show/Hide Sidebar (⌃⌘S)
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

Activation policy (`.regular`), dock icon, centering, and become-active are all handled by the
framework — the explicit `setActivationPolicy` / `activate(ignoringOtherApps:)` / `center()` calls are
deleted.

### 2. Scene type: `Window`, not `WindowGroup`

Pensieve's main view is a single unique window, so the correct first-party primitive is
`Window(_:id:)` (macOS 13+; target is macOS 14). `WindowGroup` would add a free ⌘N, but every new window
shares the one `AppModel`'s selection state → visibly janky; and multi-window/tabbing is explicitly
**slice 3's** scope. `Window` matches today's single-window behavior exactly and still delivers menus,
⌘Q, restoration, and sizing. Slice 3 can add further scenes (e.g. the inspector) properly when it owns
multi-window.

### 3. Menu bar (all first-party)

- **Free (no code):** Pensieve (About, Quit ⌘Q), Edit (undo/copy/paste — required for the ⌘K search
  field and any future text entry), Window (Minimize ⌘M, Zoom), Help. The standard set is kept **as-is**
  — nothing removed or renamed. With a single `Window` scene there is no "New Window" item to remove.
- **`SidebarCommands()`** — adds the standard Show/Hide Sidebar (⌃⌘S) to the View menu.
- **`CommandMenu("Go")`** with two custom items:
  - **Quick Jump… (⌘K)** — sets `model.showPalette = true`. This **replaces** the current hidden,
    zero-size keyboard-shortcut button in `RootView` (see §4), making the palette discoverable in the
    menu bar instead of an invisible hack.
  - **Refresh (⌘R)** — calls `model.refreshNow()` to drain the spool and recompute immediately rather
    than waiting on the 3 s poll.

### 4. Palette state moves to `AppModel`

Today `showPalette` is `@State` private to `RootView`, toggled by a hidden button carrying the ⌘K
shortcut. For a menu command to open it, hoist it:

- Add `@Published var showPalette = false` to `AppModel`.
- `RootView` drops the hidden-button `.background { … }` block; its `.sheet(isPresented:)` binds to
  `$model.showPalette`.
- The ⌘K shortcut now lives on the "Quick Jump…" menu item (§1), not a hidden view.

### 5. Lifecycle wiring

- `AppModel` becomes a `@StateObject` owned by `PensieveApp` (one instance for the app's lifetime).
- `model.start()` (launch drain + poll `Timer`) is invoked from RootView's `.task`. Make `start()`
  **idempotent** — add a `private var started = false; guard !started else { return }; started = true`
  guard at its top — so it is safe regardless of how the scene re-appears. Pure belt-and-suspenders;
  changes no behavior on the normal single-appearance path.
- Add `func refreshNow() async` to `AppModel` for ⌘R: it runs the same drain-then-refresh as launch
  (`drainThenRefresh()`), giving the user an on-demand version of the poll. (Factor the existing
  `drainThenRefresh()` so both `start()` and `refreshNow()` call it.)

### 6. Window sizing & restoration

- `.defaultSize(width: 900, height: 560)` — today's initial size.
- `.frame(minWidth: 720, minHeight: 420)` on the root content + `.windowResizability(.contentMinSize)`
  so the three-pane layout can't be crushed below its column minimums.
- **Restoration is automatic** with the scene: SwiftUI persists the window frame across launches keyed by
  scene identity. No `setFrameAutosaveName`, no manual persistence — the platform-primitives win.

### 7. Safe-area risk, retired first

The original manual `NSHostingController` existed to propagate the titlebar safe-area inset (else the
full-height sidebar scrolls under the traffic-light chrome). SwiftUI-managed scenes host correctly, so
this should not recur — but it is the hard-won lesson, so **the first implementation step is a
smoke-launch that specifically confirms the sidebar clears the titlebar.** If it regresses: add an
`NSApplicationDelegateAdaptor` and adjust the window (keeping the App lifecycle) — do **not** revert to a
manual menu bar.

## Testing & verification

The app target (`Sources/PensieveApp/`) has **no unit tests** by convention (executable target, not
covered by `PensieveKitTests`). Because this slice moves **no logic into PensieveKit**, it adds no new
PensieveKit tests. Verification is:

1. `swift build` clean.
2. All **138 existing PensieveKit tests** stay green (`./scripts/test.sh`).
3. A **non-blocking** background smoke-launch (background the process, `kill` after a few seconds — never
   foreground `swift run PensieveApp`, it blocks on the run loop) against a **throwaway** `PENSIEVE_DB` /
   `PENSIEVE_CAPTURE_DB` (a `/tmp` path) so the **live store is not perturbed**. Manual checklist:
   - Window appears, centered, at ~900×560.
   - **Sidebar clears the traffic lights** (the §7 safe-area check — do this first).
   - Menu bar present with Pensieve/File/Edit/View/Window/Help.
   - **⌘Q quits** the app.
   - **⌘K** opens the Quick Jump palette; "Go ▸ Quick Jump…" does the same.
   - **View ▸ Show/Hide Sidebar (⌃⌘S)** toggles the sidebar.
   - **⌘R** triggers a refresh (no crash; snapshot/lists update).
   - Resize the window, quit, relaunch → **frame is restored**.
   - Window respects the 720×420 minimum.

## Risks & mitigations

| Risk | Mitigation |
|---|---|
| Safe-area regression (sidebar under traffic lights) | First smoke-launch step checks it; fallback `NSApplicationDelegateAdaptor` (keeps App lifecycle). |
| ⌘K command can't reach view-local state | Hoist `showPalette` to `AppModel` (§4). |
| `start()` double-invoked on scene re-appearance | Idempotent guard (§5). |
| Renaming `main.swift` breaks the SwiftPM executable target | `@main` in a non-`main.swift` file is standard for SwiftPM executables; `swift run PensieveApp` still works. Verified by build + smoke-launch. |

## Out-of-scope carries (unchanged, still slice 3+)

⌘⌥I inspector, LLM "Last Work Done" narration, `ValueObservation` liveness, multi-window/tabbing,
light/dark + materials pass. The two cross-slice carries (key `lastOpenedAt` per DB path; shared per-node
"latest event + dormancy + open-loose-end-count" helper) are **not** pulled into this slice — they belong
with the query-touching work.
