# AppModel → @Observable Migration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Migrate `AppModel` from `ObservableObject`/`@Published` to the Observation framework's `@Observable`, so SwiftUI scopes view invalidation to the exact properties each view reads instead of re-rendering every observing view on any `@Published` write.

**Architecture:** A single, atomic app-target refactor. `AppModel` gains `@Observable` and drops `ObservableObject` conformance + all `@Published` wrappers; every non-UI stored property is marked `@ObservationIgnored`. Injection changes from `@StateObject` to `@State`; the 13 view consumers change from `@ObservedObject var model` to a plain `var model` (or `@Bindable var model` for the one view that needs two-way bindings). No behavior changes — this is a mechanical modernization with no on-disk, schema, or PensieveKit impact.

**Tech Stack:** Swift 6, SwiftUI, the Observation framework (`@Observable`, `@ObservationIgnored`, `@Bindable`) — available macOS 14+, and the app deploys to macOS 15, so no availability gating is needed.

## Global Constraints

- **App target only.** No changes under `Sources/PensieveKit`, `Sources/pensieve`, or `Tests/`. PensieveKit stays at 445 tests, untouched.
- **No behavior change.** This is a pure representation migration; every property keeps its current name, type, access level, and semantics. `@MainActor` on `AppModel` stays.
- **The app target has no unit tests** (documented invariant: logic lives in tested PensieveKit, views are thin). Verification is `xcodebuild` build + a non-blocking smoke-launch of the **inner binary** with throwaway `PENSIEVE_DB`/`PENSIEVE_CAPTURE_DB`, plus a manual eyeball checklist. Do **not** invent app-target unit tests.
- **Atomic compile unit.** `@ObservedObject var model: AppModel` requires `AppModel: ObservableObject`. The instant Task 1 removes that conformance, every consumer in Task 2 stops compiling. Tasks 1 and 2 therefore land in **one commit** — do not commit between them.
- **Build command (from CLAUDE.md):** `xcodegen generate` then `xcodebuild -project Pensieve.xcodeproj -scheme Pensieve -configuration Debug -derivedDataPath ./.build-xcode build`. After an xcodebuild, discard any transient `Package.resolved` churn (`git checkout -- Package.resolved`).
- **Leave `eval-config.json` alone** — it carries a pre-existing unrelated modification; never stage it.

---

## File Structure

| File | Change |
|---|---|
| `Sources/PensieveApp/AppModel.swift` | `@Observable` + drop `ObservableObject`/`@Published`; `@ObservationIgnored` on all non-UI infra; `import Observation`. |
| `Sources/PensieveApp/PensieveApp.swift` | `@StateObject private var model = AppModel()` → `@State private var model = AppModel()`. |
| `Sources/PensieveApp/RootView.swift` | `@ObservedObject var model` → `@Bindable var model` (uses `$model.searchText`, `$model.editingNode`). |
| `Sources/PensieveApp/SidebarView.swift` | `@ObservedObject var model` → `var model`. |
| `Sources/PensieveApp/ContentListView.swift` | `@ObservedObject var model` → `var model`. |
| `Sources/PensieveApp/DetailView.swift` | `@ObservedObject var model` → `var model`. |
| `Sources/PensieveApp/BriefingView.swift` | `@ObservedObject var model` → `var model`. |
| `Sources/PensieveApp/MenuBarView.swift` | `@ObservedObject var model` → `var model` (2 sites). |
| `Sources/PensieveApp/RecallWindowView.swift` | `@ObservedObject var model` → `var model`. |
| `Sources/PensieveApp/SettingsView.swift` | `@ObservedObject var model` → `var model`. |
| `Sources/PensieveApp/Settings/IntelligenceSettingsTab.swift` | `@ObservedObject var model` → `var model`. |
| `Sources/PensieveApp/Settings/AdvancedSettingsTab.swift` | `@ObservedObject var model` → `var model`. |
| `Sources/PensieveApp/NodeOrganizing.swift` | `@ObservedObject var model` → `var model` (4 sites — verify whether these are view structs needing a wrapper or plain helper params; only view `View` structs need the change). |

**Note on binding discovery:** the plan below fixes the two `$model.` sites found today (`RootView`). During execution, re-run the binding grep (Task 2, Step 1) — any additional `$model.<prop>` site, or any `.searchable(text:)`/`.sheet(item:)`/`.alert(item:)`/`.confirmationDialog`/`Picker(selection:)` bound to `model` in another view, means that view also needs `@Bindable` instead of a plain `var`.

---

## Task 1 + 2: The atomic migration (one commit)

**Files:** all rows in the File Structure table above.

**Interfaces:**
- Consumes: nothing new — `AppModel`'s public surface (property names/types/access) is unchanged.
- Produces: `AppModel` as an `@Observable @MainActor final class` with the identical property surface; consumers observe it through SwiftUI's Observation tracking instead of `ObservableObject`.

- [ ] **Step 1: Migrate `AppModel.swift` — the class attribute and conformance**

In `Sources/PensieveApp/AppModel.swift`:
- Add `import Observation` (top of file, with the other imports).
- Change the declaration from:
  ```swift
  @MainActor
  final class AppModel: ObservableObject {
  ```
  to:
  ```swift
  @MainActor
  @Observable
  final class AppModel {
  ```

- [ ] **Step 2: Drop every `@Published` wrapper**

Remove the `@Published` attribute from all ~25 properties (keep the `private(set)` where present, keep names/types/defaults identical). Example transforms:
```swift
@Published var lists = SmartLists(...)          →  var lists = SmartLists(...)
@Published var selectedNodeID: UUID?            →  var selectedNodeID: UUID?
@Published private(set) var refreshToken = 0    →  private(set) var refreshToken = 0
@Published private(set) var semanticHits = []   →  private(set) var semanticHits = []
```
With `@Observable`, a plain stored `var` is automatically tracked when read inside a view `body`. Do not add any wrapper back.

- [ ] **Step 3: Mark all non-UI infrastructure `@ObservationIgnored`**

`@Observable` tracks *every* stored property by default. Stored properties that are never read from a view `body` — DB handles, watchers, task handles, providers, caches, counters, backing state — must be annotated `@ObservationIgnored` so they stay out of the observation machinery (required for `Task`/handle-typed properties; correct hygiene for the rest, and prevents any accidental view coupling). Apply `@ObservationIgnored` to each of these stored properties in `AppModel`:
```
db, spool, allNodes, activeFocusContext, lastForestContext,
observationTask, spoolWatcher, canonicalWatcher, started,
summaryBuilder, descriptionProvider, providerKind,
narrationCache, searchTask, searchToken, embedder, semanticStore
```
Rules:
- `let briefingSince: Date` is an immutable `let` — leave it (constants aren't mutated, so tracking is inert; annotating is optional, prefer leaving it unchanged to stay surgical).
- Do **not** annotate the ~25 former-`@Published` UI-state properties — those must stay observed.
- Any stored property not in either list: decide by "does a view `body` read it?" If no → `@ObservationIgnored`. If unsure, grep the app target for the property name; if no view references it, ignore it.

- [ ] **Step 4: Migrate the injection point**

In `Sources/PensieveApp/PensieveApp.swift`:
```swift
@StateObject private var model = AppModel()   →   @State private var model = AppModel()
```
(`@State` is the correct owner for an `@Observable` reference type; it holds the instance stably for the App/Scene's lifetime, same as `@StateObject` did. Do not change how `model` is passed down — explicit prop-passing stays.)

- [ ] **Step 5: Migrate the plain consumers**

In each of these files, change `@ObservedObject var model: AppModel` to `var model: AppModel` (remove the wrapper; the property becomes a plain stored `let`/`var` on the view struct):
`SidebarView.swift`, `ContentListView.swift`, `DetailView.swift`, `BriefingView.swift`, `MenuBarView.swift` (2 sites), `RecallWindowView.swift`, `SettingsView.swift`, `Settings/IntelligenceSettingsTab.swift`, `Settings/AdvancedSettingsTab.swift`, and the view structs in `NodeOrganizing.swift`.

- [ ] **Step 6: Migrate the binding consumer**

In `Sources/PensieveApp/RootView.swift`, change `@ObservedObject var model: AppModel` to `@Bindable var model: AppModel` (it uses `$model.searchText` and `$model.editingNode`; `@Bindable` is what produces `$`-bindings from an `@Observable` object).

- [ ] **Step 7: Re-scan for any missed binding sites**

Run:
```bash
grep -rn '\$model\.' Sources/PensieveApp/
```
Every file that appears must be `@Bindable var model` (not plain `var model`). Today only `RootView` appears; if execution surfaces others, upgrade them to `@Bindable`.

- [ ] **Step 8: Build**

Run:
```bash
xcodegen generate && xcodebuild -project Pensieve.xcodeproj -scheme Pensieve -configuration Debug -derivedDataPath ./.build-xcode build 2>&1 | tail -8
git checkout -- Package.resolved 2>/dev/null; true
```
Expected: `** BUILD SUCCEEDED **`.

Common failure → fix:
- `Type 'AppModel' does not conform to protocol 'ObservableObject'` on a view → that view still has `@ObservedObject`; change it (Step 5/6).
- `Cannot find '$model' ... has no member` / "value of type 'AppModel' has no dynamic member" for a binding → that view needs `@Bindable` (Step 6/7).
- A `Task`/handle property error → it needs `@ObservationIgnored` (Step 3).

- [ ] **Step 9: Commit (Tasks 1+2 together)**

```bash
git add Sources/PensieveApp/
git commit -m "$(cat <<'EOF'
refactor(app): migrate AppModel to @Observable

Replace ObservableObject/@Published with the Observation framework so SwiftUI
scopes view invalidation to the properties each view reads. Injection moves
@StateObject→@State; consumers move @ObservedObject→plain var (RootView →
@Bindable for its two-way bindings). Non-UI infrastructure is @ObservationIgnored.
No behavior, schema, or PensieveKit change.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01ByuhXmgmAcdshVcYc8Bf1V
EOF
)"
```

---

## Task 3: Verify no regression (build + smoke + eyeball)

**Files:** none (verification only).

**Interfaces:** none.

- [ ] **Step 1: Confirm PensieveKit is untouched**

Run:
```bash
git diff --name-only HEAD~1 | grep -vE '^Sources/PensieveApp/' | grep -vE '^docs/' || echo "app-target-only ✓"
./scripts/test.sh 2>&1 | tail -2
```
Expected: only `Sources/PensieveApp/` files changed; `Test run with 445 tests in 5 suites passed`.

- [ ] **Step 2: Non-blocking smoke-launch of the inner binary**

Run (throwaway stores so the real store is never touched; background + kill so it never blocks):
```bash
TMP=$(mktemp -d)
PENSIEVE_DB="$TMP/p.sqlite" PENSIEVE_CAPTURE_DB="$TMP/c.sqlite" \
  ./.build-xcode/Build/Products/Debug/Pensieve.app/Contents/MacOS/Pensieve &
PID=$!; sleep 4; kill $PID 2>/dev/null; wait $PID 2>/dev/null; echo "exit: launched & killed cleanly"
```
Expected: process launches without an immediate crash (no `SIGABRT`/`Fatal error` in the few seconds before kill). A clean launch-then-kill is the pass signal.

- [ ] **Step 3: Manual eyeball checklist (human, on a real `open` of the built app)**

`@Observable` bugs surface as *stale* or *missing* UI updates, not crashes — so drive the invalidation-sensitive flows and confirm each still updates live:
- [ ] Sidebar selection changes → middle list + detail update.
- [ ] Type in ⌘F search → results update per keystroke; clearing search restores the list.
- [ ] Open New/Edit sheet (⌘N / context menu) → sheet presents; edits commit and reflect; Esc/cancel dismisses.
- [ ] Move… and Merge… pickers present and complete; selection re-homes after merge.
- [ ] ⌘R refresh → lists/briefing/forest refresh; the open detail re-narrates.
- [ ] Menu-bar popover opens and shows live heartbeat + What's Next; click-to-jump fronts the window.
- [ ] Settings tabs (General/Intelligence/Advanced) open; toggles persist and take effect.
- [ ] Open a ⌘⌥N recall window → independent selection; its inline provenance expands.
- [ ] Trigger a refusal (delete a node in one window, act on it stale in another) → the error alert still appears.
- [ ] Background liveness: with the app open, make a commit in a tracked repo (or run `pensieve sync`) → the app updates without ⌘R.

- [ ] **Step 4: Update the changelog**

Add a Status bullet to `CLAUDE.md` and a dated entry to `docs/superpowers/backlog.md` recording the migration (mirroring the house changelog style), and check off the `@Observable` carry in the "Code-quality review carries — 2026-07-07" section. Commit:
```bash
git add CLAUDE.md docs/superpowers/backlog.md docs/superpowers/plans/2026-07-19-appmodel-observable-migration.md
git commit -m "docs: record AppModel @Observable migration"
```

---

## Self-Review Notes

- **Spec coverage:** the migration surface is the 13 consumer files + `AppModel` + the injection point, all enumerated in the File Structure table and Task 1+2 steps. The `@ObservationIgnored` audit (Step 3) covers the tracking subtlety unique to `@Observable`. The binding surface (`$model.`) is handled in Steps 6–7 with a re-scan to catch anything the static grep missed.
- **No new tests:** intentional and correct — the app target is unit-test-free by design; verification is build + smoke + human eyeball (Task 3).
- **Risk register:** (1) a missed `@ObservationIgnored` on a handle property → caught at build (Step 8). (2) a missed `@Bindable` → caught at build (Step 8) or by the Step 7 re-scan. (3) a *silent* stale-UI regression (the one class of bug the build won't catch) → caught by the Task 3 Step 3 eyeball checklist, which is why that checklist targets exactly the invalidation-sensitive flows. (4) `NodeOrganizing.swift`'s 4 `@ObservedObject` hits — verify each is a `View` struct property before changing; a non-view helper taking `model` as a plain parameter needs no wrapper change.
- **Value note (honest):** there is no observed performance symptom today, and the specific `body`-recompute hotspots the original backlog carry cited (`ContentListView.nodesForSelection`, `PaletteView.rows`) no longer exist (removed by the IA rework + ⌘K palette retirement). This migration is proactive modernization — idiomatic-Swift hygiene and future-proofing — not a fix for a live problem. Worth doing as a contained app-target pass; not urgent.
