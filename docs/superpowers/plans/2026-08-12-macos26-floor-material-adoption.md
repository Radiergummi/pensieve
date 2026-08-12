# macOS 26 Floor + System Material Adoption Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Raise the app's deployment floor to macOS 26.0 and adopt system scroll-edge material, rebuild the menu-bar popover as a re-entry point, and un-chrome the sidebar status footer — with no explicit Liquid Glass anywhere.

**Architecture:** App-target only. **Zero PensieveKit changes**, so the test count stays at **589**. Every visual change is a SwiftUI modifier or a view-composition change; the one behavioural change is `AppModel.refreshGlance()` also refreshing `nodeRowFacts` so the popover's secondary line isn't stale. The popover reuses the existing `NodeRowMeta` view rather than growing a parallel implementation.

**Tech Stack:** SwiftUI (macOS 26 SDK), XcodeGen, `xcodebuild`, SwiftLint, String Catalog (`.xcstrings`).

**Spec:** `docs/superpowers/specs/2026-08-12-liquid-glass-macos26-floor-design.md`

**Base branch:** `main` (at or after `e7f124d`). The worktree is created at execution time by `superpowers:using-git-worktrees` — do **not** work in `/Users/moritz/Projects/pensieve` directly, and do **not** touch `.claude/worktrees/translation`, where another agent is active.

## A note on testing, read this before Task 1

**There is no TDD cycle in this plan, and that is correct rather than an omission.** `Sources/PensieveApp/` has **no unit tests by design** (`CLAUDE.md`): derivation logic belongs in tested PensieveKit and views stay thin. This slice adds no derivation logic, so there is nothing to test at the unit level. Writing view tests the project deliberately doesn't write would be worse than saying so.

Each task therefore closes on a **build + lint + smoke** gate plus a **named human check** that goes into the carry list in Task 9. Do not invent a test target. Do not add a PensieveKit test to make a task feel complete — if a task seems to need one, the task is wrong, so stop and report instead.

**Tasks 7 and 8 may legitimately produce no commit.** Both are verification tasks whose code change is conditional on what the verification finds. If nothing needed fixing, the deliverable is the *report* — the three recorded appearance outcomes (Task 7) or the triaged catalog findings (Task 8). Report `DONE` with an empty commit list and the outcomes in the report file; do not manufacture a change to have something to commit, and do not treat an empty diff as a failed task.

## Global Constraints

Every task's requirements implicitly include all of these.

- **Deployment floor:** `project.yml` → `deploymentTarget.macOS: "26.0"` exactly. `Package.swift` stays at `platforms: [.macOS(.v14)]` — **never** edit it.
- **No explicit Liquid Glass.** Never write `.glassEffect`, `.buttonStyle(.glass)`, `.glassProminent`, or `GlassEffectContainer`. Rejected in the spec on the spec's own argument. The popover's primary button is `.borderedProminent`.
- **Slice C files are off limits:** never edit `Sources/PensieveApp/LooseEndRow.swift`, `TranscriptSegmentView.swift`, or `TranscriptMessageView.swift`.
- **Never change `Prose.measure`** (`Sources/PensieveApp/ProseStyle.swift:10`, currently `760`). It is slice C's to set.
- **`DetailView.swift` is shared with the concurrent `worktree-on-device-translation` branch.** Add modifiers on new lines only. **Never reindent or restructure the `ScrollViewReader` / `ScrollView` / `VStack` nesting** (opens `:31-33`, closes `:147-148`) — that reindent would span the other branch's hunks in a file whose `.task` ordering two prior reviews called load-bearing.
- **Zero PensieveKit changes.** `swift test` must report **589** tests at every commit. If a change seems to need Kit, stop and report.
- **Exactly one new String Catalog key is permitted:** `More actions` (Task 6, the ellipsis menu's accessible label). Any *other* new key means the task is wrong — stop and report. Keys are not auto-populated by `xcodebuild`; they are reconciled by hand, `en` + `de`.
- **Never pipe `xcodebuild` to `tail`** (or `head`, or `grep`) — the pipeline reports the last command's exit code, so a failed build reads as a success (`cfc1189`). Redirect to a file and inspect the file.
- **Never set `PENSIEVE_DB` / `PENSIEVE_CAPTURE_DB` against the live store.** Smoke launches MUST set both to throwaway `/tmp` paths.
- **`swiftlint --strict`** must report 0 violations. It caps files at 400 lines.
- **Never `rm -rf .build-xcode`** — it would delete a bundle registered with SMAppService.
- **Per-site fallback (pre-committed):** if a column refuses the scroll-edge effect or renders it wrongly, **ship no treatment on that column**. Do not hand-roll a gradient. Do not restructure a column to make the modifier work.

**Build and verify commands** (used verbatim throughout):

```bash
xcodegen generate
xcodebuild -project Pensieve.xcodeproj -scheme Pensieve -configuration Debug \
  -derivedDataPath ./.build-xcode build > /tmp/slice-b-build.log 2>&1; echo "exit=$?"
tail -5 /tmp/slice-b-build.log            # inspect the FILE, never pipe the build itself
swiftlint --strict
./scripts/test.sh                          # must say 589
```

---

### Task 1: Raise the deployment floor to macOS 26.0

**Files:**
- Modify: `project.yml:8-9`

**Interfaces:**
- Consumes: nothing.
- Produces: an app target that may call macOS 26 API unguarded. Task 2 depends on this — `.scrollEdgeEffectStyle` does not compile below it.

- [ ] **Step 1: Confirm the current value**

Run: `sed -n '1,12p' project.yml`

Expected to contain:

```yaml
  deploymentTarget:
    macOS: "15.0"
```

If it is already `"26.0"`, stop and report — someone else has been here.

- [ ] **Step 2: Record the current floor of all three binaries, so the change is provable**

```bash
APP=./.build-xcode/Build/Products/Debug/Pensieve.app
for BIN in "$APP/Contents/MacOS/Pensieve" \
           "$APP/Contents/Helpers/pensieve" \
           "$APP/Contents/Library/Helpers/PensieveSyncAgent"; do
  echo "== $BIN"; otool -l "$BIN" | grep -A4 LC_BUILD_VERSION | grep -E 'minos|sdk'
done
```

Expected: `minos 15.0` and `sdk 26.5` on all three. If `.build-xcode` does not exist yet, run the build from the Global Constraints block first, then re-run this.

- [ ] **Step 3: Make the change**

In `project.yml`, replace exactly:

```yaml
  deploymentTarget:
    macOS: "15.0"
```

with:

```yaml
  deploymentTarget:
    macOS: "26.0"
```

Change nothing else. In particular do **not** add per-target `MACOSX_DEPLOYMENT_TARGET` overrides — the spec deliberately lets the embedded CLI and the sync agent move to 26.0 too.

- [ ] **Step 4: Regenerate and build**

```bash
xcodegen generate
xcodebuild -project Pensieve.xcodeproj -scheme Pensieve -configuration Debug \
  -derivedDataPath ./.build-xcode build > /tmp/slice-b-build.log 2>&1; echo "exit=$?"
tail -5 /tmp/slice-b-build.log
```

Expected: `exit=0` and `BUILD SUCCEEDED`. A failure mentioning `cannot find X in scope` means `xcodegen generate` did not run — it did not, so re-run it.

- [ ] **Step 5: Prove the floor moved on all three binaries**

Re-run the loop from Step 2.

Expected: `minos 26.0` on **all three**. If the app moved but a helper did not, stop and report — that contradicts the spec's project-scope finding and the plan needs revising, not patching.

- [ ] **Step 6: Confirm Kit is untouched**

```bash
git diff --name-only            # must list project.yml and NOTHING else
./scripts/test.sh
```

Expected: `589` tests, 0 failures.

- [ ] **Step 7: Commit**

```bash
git add project.yml
git commit -F - <<'EOF'
build: raise the app's deployment floor to macOS 26.0

Enables scrollEdgeEffectStyle, the slice's one macOS 26 API. The app target
carries zero if #available sites, so this deletes no scaffolding -- it buys API
access only. Package.swift stays at .macOS(.v14): Xcode builds SPM targets at
the package's own floor, so PensieveKit's four gated sites are unaffected.

deploymentTarget is project-scope, so this moves three binaries, not one -- the
app, the embedded pensieve CLI, and PensieveSyncAgent. Accepted deliberately:
all three run only on this machine and CI is already macos-26.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_012R4ySPo4ydYJGUiLrdvZtU
EOF
```

---

### Task 2: Adopt `.soft` scroll-edge material on all four scroll containers

**Files:**
- Modify: `Sources/PensieveApp/SidebarView.swift:52`
- Modify: `Sources/PensieveApp/ContentListView.swift:11-20`
- Modify: `Sources/PensieveApp/DetailView.swift` (one added line after the `ScrollView`'s closing brace at `:147`)
- Modify: `Sources/PensieveApp/BriefingView.swift:42`

**Interfaces:**
- Consumes: the 26.0 floor from Task 1.
- Produces: nothing other tasks read.

**Why the default is not "nothing":** `ScrollEdgeEffectStyle.automatic` is already in force, and `scrollEdgeEffectHidden` exists — you only ship a hide-modifier for an effect that is on by default. This task is a style delta, `.automatic → .soft`. That is why Step 6 is a *comparison*, not a look.

- [ ] **Step 1: Sidebar**

In `SidebarView.swift`, the `List` currently ends:

```swift
    .listStyle(.sidebar)
    .safeAreaInset(edge: .bottom) { StatusFooter(snapshot: model.snapshot) }
  }
```

Change to:

```swift
    .listStyle(.sidebar)
    .scrollEdgeEffectStyle(.soft, for: .top)
    .safeAreaInset(edge: .bottom) { StatusFooter(snapshot: model.snapshot) }
  }
```

- [ ] **Step 2: Content column — on `body`, NOT on `normalContent`**

`ContentListView.body` is two levels. `searchResultsList()` is a **sibling** of the `switch`, not a case in it, so attaching the modifier to `normalContent` would cover three of the four `List`s and silently leave the **search column** untreated — no compile error, and no check would catch it.

Replace `body` (`:11-20`) exactly:

```swift
  var body: some View {
    Group {
      if model.isSearching {
        searchResultsList()
          .navigationTitle(Text("Search"))
      } else {
        normalContent
      }
    }
  }
```

with:

```swift
  var body: some View {
    Group {
      if model.isSearching {
        searchResultsList()
          .navigationTitle(Text("Search"))
      } else {
        normalContent
      }
    }
    // On `body`, not `normalContent`: `searchResultsList()` is a sibling of the switch, so attaching
    // this one level down would leave the search column untreated.
    .scrollEdgeEffectStyle(.soft, for: .top)
  }
```

Leave `normalContent` completely alone.

- [ ] **Step 3: Detail column — add a line, never reindent**

First read the exact region: `sed -n '144,152p' Sources/PensieveApp/DetailView.swift`

You will see the `ScrollView` closing brace and the `ScrollViewReader` closing brace on consecutive lines (`:147-148`, deliberately flat-indented), followed by `.focusedSceneValue(\.nodeFind, find)`.

Insert `.scrollEdgeEffectStyle(.soft, for: .top)` on its own **new** line immediately after the brace that closes the **`ScrollView`** (the first of the two), matching the surrounding flat indentation.

**If the two braces are ambiguous to you, attach the modifier to the `ScrollViewReader` chain instead** — on a new line immediately before `.focusedSceneValue(\.nodeFind, find)`. The effect is identical because `.scrollEdgeEffectStyle` threads into descendant scroll views (`TransformScrollStorageModifier`, the same mechanism as `scrollDisabled`). Choosing the unambiguous placement is better than guessing at brace pairing.

**Adding a new line is permitted. Reindenting or moving any existing line is not** — see Global Constraints.

- [ ] **Step 4: Briefing**

In `BriefingView.swift`, the `ScrollView` opened at `:15` closes at `:42`:

```swift
      .frame(maxWidth: Prose.measure, alignment: .leading)
      .frame(maxWidth: .infinity, alignment: .center)   // center the capped reading column in a wide pane
    }
  }
```

Add the modifier to the `ScrollView` — after its closing brace (`:42`), before `body`'s closing brace:

```swift
      .frame(maxWidth: Prose.measure, alignment: .leading)
      .frame(maxWidth: .infinity, alignment: .center)   // center the capped reading column in a wide pane
    }
    .scrollEdgeEffectStyle(.soft, for: .top)
  }
```

**Do not touch either `.frame` line** — `Prose.measure` is slice C's.

- [ ] **Step 5: Build, lint, and confirm the diff is four files and only additions**

```bash
xcodegen generate
xcodebuild -project Pensieve.xcodeproj -scheme Pensieve -configuration Debug \
  -derivedDataPath ./.build-xcode build > /tmp/slice-b-build.log 2>&1; echo "exit=$?"
tail -5 /tmp/slice-b-build.log
swiftlint --strict
git diff --stat
git diff | grep '^-' | grep -v '^---'    # expected: EMPTY except the ContentListView body rewrite
```

Expected: `exit=0`, 0 lint violations, four files changed. The last command exists to catch an accidental reindent of `DetailView.swift`; if it prints any `DetailView.swift` deletion, revert that file and redo Step 3 as an insertion.

- [ ] **Step 6: Smoke launch**

```bash
PENSIEVE_DB=/tmp/slice-b-smoke.sqlite PENSIEVE_CAPTURE_DB=/tmp/slice-b-smoke-capture.sqlite \
  ./.build-xcode/Build/Products/Debug/Pensieve.app/Contents/MacOS/Pensieve &
sleep 4; kill %1
```

Expected: no crash before the kill.

- [ ] **Step 7: Commit**

```bash
git add Sources/PensieveApp/SidebarView.swift Sources/PensieveApp/ContentListView.swift \
        Sources/PensieveApp/DetailView.swift Sources/PensieveApp/BriefingView.swift
git commit -F - <<'EOF'
feat(app): soften the scroll edge on all four columns

The default was .automatic, not nothing -- scrollEdgeEffectHidden exists, and
the app already linked the 26.5 SDK -- so this is a style delta and the human
check must compare rather than observe presence.

The content column's modifier goes on body, NOT on normalContent:
searchResultsList() is a sibling of the switch, so one level down would have
covered three of four Lists and left the search column untreated with no
compile error.

DetailView gets an added line only; its ScrollViewReader/ScrollView/VStack
nesting is untouched, because the concurrent translation branch has hunks in
that file. Prose.measure is left to slice C.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_012R4ySPo4ydYJGUiLrdvZtU
EOF
```

---

### Task 3: Un-chrome the sidebar status footer

**Files:**
- Modify: `Sources/PensieveApp/SidebarView.swift:88-103`

**Interfaces:**
- Consumes: nothing.
- Produces: nothing.

**Keep the pin. Keep `.bar`. Remove only the `Divider()`.** `.bar` is `Material.bar` — translucent, and already separating. The hairline sitting on top of a material that already separates is what reads as bolted on. Dropping `.bar` too would leave a 7pt dot and an 11pt caption on the same surface the rows scroll over with nothing between them, and this slice specifies a **top**-edge effect only.

- [ ] **Step 1: Make the change**

`StatusFooter.body` currently reads:

```swift
  var body: some View {
    VStack(spacing: 0) {
      Divider()
      HStack(spacing: 6) {
        Circle().fill(color).frame(width: 7, height: 7)
        Text(label).font(.caption).foregroundStyle(.secondary)
        Spacer()
      }
      .padding(.horizontal, 12).padding(.vertical, 6)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .background(.bar)
  }
```

Replace with — the `VStack` goes too, since it existed only to stack the `Divider` above the row:

```swift
  var body: some View {
    HStack(spacing: 6) {
      Circle().fill(color).frame(width: 7, height: 7)
      Text(label).font(.caption).foregroundStyle(.secondary)
      Spacer()
    }
    .padding(.horizontal, 12).padding(.vertical, 6)
    .frame(maxWidth: .infinity, alignment: .leading)
    // `.bar` STAYS: it is a translucent material and it is what separates the footer from the
    // scrolling rows. Only the explicit hairline is gone -- the material's own edge does that job,
    // and the hairline on top of it is what read as a strip taped under the sidebar.
    .background(.bar)
  }
```

Leave `color` and `label` untouched.

- [ ] **Step 2: Build, lint, smoke**

```bash
xcodebuild -project Pensieve.xcodeproj -scheme Pensieve -configuration Debug \
  -derivedDataPath ./.build-xcode build > /tmp/slice-b-build.log 2>&1; echo "exit=$?"
tail -5 /tmp/slice-b-build.log
swiftlint --strict
```

Expected: `exit=0`, 0 violations.

- [ ] **Step 3: Commit**

```bash
git add Sources/PensieveApp/SidebarView.swift
git commit -F - <<'EOF'
feat(app): drop the status footer's hairline, keep its material

.bar is Material.bar -- translucent, and already separating. An earlier draft of
the spec called it opaque and proposed removing it; that diagnosis was wrong.
The hairline sitting on top of a material that already separates is what read as
bolted on, so only the Divider goes. The safeAreaInset pin stays: a List row
would scroll away and the liveness dot would stop being a glance.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_012R4ySPo4ydYJGUiLrdvZtU
EOF
```

---

### Task 4: `refreshGlance()` refreshes `nodeRowFacts`

**Files:**
- Modify: `Sources/PensieveApp/AppModel.swift:252-259`

**Interfaces:**
- Consumes: `NodeFactsQueries.rowFacts(_:) throws -> [UUID: NodeRowFacts]` (existing PensieveKit API, already called at `AppModel.swift:281`).
- Produces: a populated `model.nodeRowFacts` on the popover's own refresh path. **Task 5 depends on this** — without it the popover renders whatever the last full `refresh()` left.

- [ ] **Step 1: Read the current function**

Run: `sed -n '250,262p' Sources/PensieveApp/AppModel.swift`

Expected:

```swift
  /// Narrow refresh for the menu-bar glance: only what the popover shows (heartbeat + What's Next),
  /// skipping the briefing cards / forest that only the main window needs.
  func refreshGlance() {
    snapshot = MonitorSnapshot.gather(canonical: database, spool: spool)
    guard let database else { return }
    guard let raw = try? SmartLists.compute(database, now: Date()) else { return }
    let visible = NodeContextResolver.visibleNodeIDs(for: activeFocusContext, in: allNodes)
    lists = activeFocusContext.isEmpty ? raw : filtered(raw, visible)
  }
```

- [ ] **Step 2: Add the facts refresh**

Replace the body with — note the `nodeRowFacts` line goes **after** the `database` guard and **before** the `SmartLists` guard, so a `SmartLists` failure cannot skip it:

```swift
  /// Narrow refresh for the menu-bar glance: only what the popover shows (heartbeat + What's Next),
  /// skipping the briefing cards / forest that only the main window needs.
  func refreshGlance() {
    snapshot = MonitorSnapshot.gather(canonical: database, spool: spool)
    guard let database else { return }
    // The popover's rows render `NodeRowMeta`, which reads `nodeRowFacts` -- and this is the ONLY
    // refresh the popover runs, so without this line it shows whatever the last full `refresh()`
    // left. Two grouped aggregates, cheaper than the `SmartLists.compute` already on this path.
    if let facts = try? NodeFactsQueries.rowFacts(database) { nodeRowFacts = facts }
    guard let raw = try? SmartLists.compute(database, now: Date()) else { return }
    let visible = NodeContextResolver.visibleNodeIDs(for: activeFocusContext, in: allNodes)
    lists = activeFocusContext.isEmpty ? raw : filtered(raw, visible)
  }
```

- [ ] **Step 3: Confirm you matched the existing call's shape**

Run: `grep -n 'rowFacts' Sources/PensieveApp/AppModel.swift`

Expected: two hits — your new line, and the pre-existing one at ~`:281`. Both must read `if let facts = try? NodeFactsQueries.rowFacts(database) { nodeRowFacts = facts }`. If they differ, make yours match; a second spelling of the same call is how the two drift.

- [ ] **Step 4: Build, lint, and confirm the file is still under the cap**

```bash
xcodebuild -project Pensieve.xcodeproj -scheme Pensieve -configuration Debug \
  -derivedDataPath ./.build-xcode build > /tmp/slice-b-build.log 2>&1; echo "exit=$?"
tail -5 /tmp/slice-b-build.log
swiftlint --strict
wc -l Sources/PensieveApp/AppModel.swift
```

Expected: `exit=0`, 0 violations, and a line count comfortably under **400**. `AppModel.swift` was pushed to 404 lines once before and had to be split — if this addition crosses 400, stop and report rather than splitting the file inside a chrome slice.

- [ ] **Step 5: Commit**

```bash
git add Sources/PensieveApp/AppModel.swift
git commit -F - <<'EOF'
fix(app): the menu-bar glance refreshes the facts its rows render

refreshGlance() set snapshot and lists only; nodeRowFacts was written solely by
the full refresh(). Since the popover's .task calls refreshGlance and nothing
else, its rows would render whatever the last full refresh left.

Placed before the SmartLists guard so a SmartLists failure cannot skip it, and
spelled identically to the existing call site so the two cannot drift.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_012R4ySPo4ydYJGUiLrdvZtU
EOF
```

---

### Task 5: Popover rows — reuse `NodeRowMeta`, add a visible affordance, fix the hit area

**Files:**
- Modify: `Sources/PensieveApp/MenuBarView.swift:55-74`
- Modify: `Sources/PensieveApp/Localizable.xcstrings` (remove one orphaned key)

**Interfaces:**
- Consumes: `model.nodeRowFacts` (populated by Task 4); `NodeRowMeta(facts: NodeRowFacts?)` from `Sources/PensieveApp/NodeMeta.swift:66-76`; `rowHitArea()` from `Sources/PensieveApp/ContentListView.swift:207-213`.
- Produces: nothing other tasks read.

**Reuse, don't reimplement.** `NodeRowMeta` already draws "relative recency · N open", already localized, already used by the middle column. Sharing the view is what makes the two surfaces agree — a second hand-authored string would agree by convention until one drifts, and `NodeMeta.swift:29` documents the `"%lld open"` vs `"%@ open"` trap that silently falls back to English.

- [ ] **Step 1: Replace `whatsNext`**

Current (`:55-74`):

```swift
  @ViewBuilder private var whatsNext: some View {
    let items = Array(model.lists.whatsNext.prefix(Self.maxRows))
    if items.isEmpty {
      Text("Nothing queued").font(.callout).foregroundStyle(.secondary)
    } else {
      ForEach(items, id: \.project.id) { item in
        Button {
          applyDeepLink(.node(item.project.id), model: model, openWindow: openWindow)
        } label: {
          HStack {
            Text(item.project.name).lineLimit(1)
            Spacer()
            Text("\(item.openLooseEnds) open · \(item.daysDormant)d dormant")
              .font(.caption).foregroundStyle(.secondary)
          }
        }
        .buttonStyle(.plain)
      }
    }
  }
```

Replace with:

```swift
  @ViewBuilder private var whatsNext: some View {
    let items = Array(model.lists.whatsNext.prefix(Self.maxRows))
    if items.isEmpty {
      Text("Nothing queued").font(.callout).foregroundStyle(.secondary)
    } else {
      ForEach(items, id: \.project.id) { item in
        MenuBarRow(item: item, facts: model.nodeRowFacts[item.project.id]) {
          applyDeepLink(.node(item.project.id), model: model, openWindow: openWindow)
        }
      }
    }
  }
```

- [ ] **Step 2: Add the row view**

Add below `MenuBarView` (above the `MenuBarLabel` declaration), so `MenuBarView.body` stays readable:

```swift
/// One popover row: a re-entry point, not a scoreboard line. The whole row is the action and now
/// looks like it — a persistent chevron plus a hover fill, rather than five labelled buttons on a
/// five-row surface. The second line reuses `NodeRowMeta`, the middle column's own component, so the
/// two surfaces share one implementation instead of agreeing by convention.
private struct MenuBarRow: View {
  let item: NextItem
  let facts: NodeRowFacts?
  let action: () -> Void
  @State private var isHovering = false

  var body: some View {
    Button(action: action) {
      HStack(spacing: 8) {
        VStack(alignment: .leading, spacing: 1) {
          Text(item.project.name).lineLimit(1)
          NodeRowMeta(facts: facts)
        }
        Spacer()
        Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
      }
      // Without this the `Spacer()` between the text and the chevron is dead space to hit-testing —
      // the same defect slice A's verify pass found in the detail pane's hover thumbs.
      .rowHitArea()
    }
    .buttonStyle(.plain)
    .padding(.horizontal, 6).padding(.vertical, 4)
    .background(isHovering ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear),
                in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    .onHover { isHovering = $0 }
  }
}
```

- [ ] **Step 3: Build and confirm it compiles before touching the catalog**

```bash
xcodebuild -project Pensieve.xcodeproj -scheme Pensieve -configuration Debug \
  -derivedDataPath ./.build-xcode build > /tmp/slice-b-build.log 2>&1; echo "exit=$?"
tail -20 /tmp/slice-b-build.log
```

Expected: `exit=0`. If `NextItem` or `NodeRowFacts` is unresolved, `MenuBarView.swift` already has `import PensieveKit` at the top — confirm it is still there rather than adding a second import.

- [ ] **Step 4: Find the now-orphaned catalog key and confirm its exact text**

Removing the old `Text` leaves a catalog key that no Swift literal resolves to.

```bash
grep -n 'dormant' Sources/PensieveApp/Localizable.xcstrings
grep -rn 'dormant' Sources/PensieveApp/*.swift
```

Expected: the catalog contains a key along the lines of `"%lld open · %lldd dormant"` with a German value, and **no** Swift file still references it. **Verify the exact key text from the grep output before deleting anything** — do not delete a key you have not seen, and do not delete a key that a Swift literal still resolves to.

- [ ] **Step 5: Remove exactly that one key**

Delete the whole JSON entry for that key from `Sources/PensieveApp/Localizable.xcstrings` — the key and its `localizations` object — leaving surrounding entries and the file's trailing structure valid. Then:

```bash
python3 -c "import json;json.load(open('Sources/PensieveApp/Localizable.xcstrings'));print('valid json')"
```

Expected: `valid json`. Remove no other key, even one that looks dead — pre-existing orphans are reported in Task 8, not cleaned up here.

- [ ] **Step 6: Build, lint, smoke**

```bash
xcodebuild -project Pensieve.xcodeproj -scheme Pensieve -configuration Debug \
  -derivedDataPath ./.build-xcode build > /tmp/slice-b-build.log 2>&1; echo "exit=$?"
tail -5 /tmp/slice-b-build.log
swiftlint --strict
PENSIEVE_DB=/tmp/slice-b-smoke.sqlite PENSIEVE_CAPTURE_DB=/tmp/slice-b-smoke-capture.sqlite \
  ./.build-xcode/Build/Products/Debug/Pensieve.app/Contents/MacOS/Pensieve &
sleep 4; kill %1
```

Expected: `exit=0`, 0 violations, no crash.

- [ ] **Step 7: Commit**

```bash
git add Sources/PensieveApp/MenuBarView.swift Sources/PensieveApp/Localizable.xcstrings
git commit -F - <<'EOF'
feat(app): popover rows become re-entry points

The whole row was already the action; now it looks like one -- persistent
chevron plus a hover fill, rather than five labelled buttons on a five-row
surface.

The second line reuses NodeRowMeta, the middle column's own component, so the
two surfaces share one implementation rather than agreeing by convention until
one drifts. That also means no new catalog keys, which matters because
NodeMeta.swift:29 documents the %lld/%@ trap that silently falls back to
English. Removing the old dormancy Text orphaned its key, so the key goes with
it.

Fixes a live hit-testing defect via the existing rowHitArea(): the Spacer()
inside a .plain Button was dead space, the same bug slice A's verify pass found
in the detail pane.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_012R4ySPo4ydYJGUiLrdvZtU
EOF
```

---

### Task 6: Popover footer — a full-width primary action that cannot truncate

**Files:**
- Modify: `Sources/PensieveApp/MenuBarView.swift:32-44` (the `frame(width:)`) and `:76-85` (`footer`)

**Interfaces:**
- Consumes: nothing from other tasks.
- Produces: nothing.

**The fix is structural, not textual.** `Pensieve öffnen` truncates to `Pensieve öf…` because a three-button row is too narrow for German. A full-width button cannot truncate; shortening the string would move the problem to the next translation.

- [ ] **Step 1: Replace `footer`**

Current (`:76-85`):

```swift
  @ViewBuilder private var footer: some View {
    HStack {
      Button("Open Pensieve") {
        applyDeepLink(.briefing, model: model, openWindow: openWindow)
      }
      Spacer()
      Button("Refresh") { Task { await model.refreshNow() } }
      Button("Quit") { NSApplication.shared.terminate(nil) }
    }
  }
```

Replace with:

```swift
  @ViewBuilder private var footer: some View {
    HStack(spacing: 8) {
      // Full-width primary: German cannot truncate a button that owns the row. `.borderedProminent`
      // rather than a glass style — the `.window` popover surface is already system glass, so a
      // glass button on it would be glass on glass. This also picks up the system accent colour.
      Button("Open Pensieve") {
        applyDeepLink(.briefing, model: model, openWindow: openWindow)
      }
      .buttonStyle(.borderedProminent)
      .frame(maxWidth: .infinity)

      Menu {
        Button("Refresh") { Task { await model.refreshNow() } }
        Button("Quit") { NSApplication.shared.terminate(nil) }
      } label: {
        Image(systemName: "ellipsis")
      }
      .menuStyle(.borderlessButton)
      .fixedSize()
      .help("More actions")
    }
  }
```

`Refresh` and `Quit` keep their existing keys, so no catalog change is needed. `"More actions"` is a **new** key — see Step 2.

- [ ] **Step 2: Add the one new catalog key, `en` + `de`**

`"More actions"` is the slice's only new string. Add it to `Sources/PensieveApp/Localizable.xcstrings` following the exact shape of a neighbouring simple entry (`"Refresh"` is a good model — copy its structure, including `extractionState` if its neighbours carry one), with:

- `en`: `More actions`
- `de`: `Weitere Aktionen`

Then confirm the file still parses:

```bash
python3 -c "import json;json.load(open('Sources/PensieveApp/Localizable.xcstrings'));print('valid json')"
```

- [ ] **Step 3: Widen the popover 300 → 320**

In `MenuBarView.body`, change:

```swift
    .frame(width: 300)
```

to:

```swift
    .frame(width: 320)   // two-line rows need the room
```

- [ ] **Step 4: Build, lint, smoke**

```bash
xcodebuild -project Pensieve.xcodeproj -scheme Pensieve -configuration Debug \
  -derivedDataPath ./.build-xcode build > /tmp/slice-b-build.log 2>&1; echo "exit=$?"
tail -5 /tmp/slice-b-build.log
swiftlint --strict
grep -c 'glassEffect\|buttonStyle(.glass\|glassProminent' Sources/PensieveApp/*.swift | grep -v ':0' || echo "no glass: correct"
```

Expected: `exit=0`, 0 violations, and `no glass: correct`.

- [ ] **Step 5: Commit**

```bash
git add Sources/PensieveApp/MenuBarView.swift Sources/PensieveApp/Localizable.xcstrings
git commit -F - <<'EOF'
feat(app): the popover's primary action owns its row

Pensieve öffnen truncated to Pensieve öf… because a three-button row is too
narrow for German. A full-width button cannot truncate; shortening the string
would only move the problem to the next translation. Refresh and Quit demote to
an ellipsis menu.

.borderedProminent, not a glass style: the MenuBarExtra(.window) surface is
already system glass, so a glass button on it is glass on glass -- the same
"translucency on a flat surface" this slice rejects everywhere else. It also
picks up the system accent, which nothing else in this app does.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_012R4ySPo4ydYJGUiLrdvZtU
EOF
```

---

### Task 7: Appearance and accessibility settings — verify, then fix only what fails

**Files:**
- Possibly modify: `Sources/PensieveApp/SidebarView.swift` (conditional hairline, **only if** Step 2 fails)

**Interfaces:**
- Consumes: Task 3's footer change.
- Produces: nothing.

Nothing in the tree handles these settings today — `grep -rn 'accessibilityReduceTransparency\|reduceMotion\|colorSchemeContrast\|differentiateWithoutColor' Sources/` returns nothing. This task closes that by decision, not by omission. **Two of the three checks are expected to need no code.**

- [ ] **Step 1: Confirm the slice adds no custom translucency**

```bash
grep -rn 'opacity(\|\.ultraThin\|\.thin\|Material\|\.bar' Sources/PensieveApp/*.swift
```

Expected: `.background(.bar)` in `SidebarView.swift` and `FindBar.swift`, and nothing else new from this slice. Both are first-party materials that already respond to Reduce Transparency, so there is nothing for this slice to handle. Record the result; make no change.

- [ ] **Step 2: Increase Contrast — the one check that can require code**

Launch the built app, then enable **System Settings ▸ Accessibility ▸ Display ▸ Increase contrast** and look at the sidebar's foot.

The question: with the `Divider()` gone (Task 3), does the `.bar` material's own edge still read as a separator under Increase Contrast? Increase Contrast is the setting that specifically wants hairlines back.

- **If it separates:** no change. Record the outcome and move to Step 3.
- **If it does not:** restore the hairline *conditionally*. In `StatusFooter`, add

```swift
  @Environment(\.colorSchemeContrast) private var contrast
```

and wrap the row so the hairline returns only under increased contrast:

```swift
  var body: some View {
    VStack(spacing: 0) {
      // Increase Contrast wants an explicit hairline; normal contrast gets the material's own edge.
      if contrast == .increased { Divider() }
      HStack(spacing: 6) {
        Circle().fill(color).frame(width: 7, height: 7)
        Text(label).font(.caption).foregroundStyle(.secondary)
        Spacer()
      }
      .padding(.horizontal, 12).padding(.vertical, 6)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .background(.bar)
  }
```

Do **not** abandon Task 3 and restore the unconditional `Divider()` — the point is that normal contrast gets the material's edge.

- [ ] **Step 3: Reduce Motion**

Enable **System Settings ▸ Accessibility ▸ Display ▸ Reduce motion**, scroll each of the four columns.

`.scrollEdgeEffectStyle` is a material, not an animation, so no interaction is expected. Record the outcome. **If** the edge animates distractingly under Reduce Motion, do not patch it here — report it, because the pre-committed fallback is to ship no treatment on the offending column, and that is a decision, not a fix.

- [ ] **Step 4: Commit — only if Step 2 required a change**

```bash
git add Sources/PensieveApp/SidebarView.swift
git commit -F - <<'EOF'
fix(app): restore the footer hairline under Increase Contrast

The material's own edge does not read as a separator when Increase Contrast is
on -- the setting that specifically wants hairlines back. Normal contrast still
gets the material edge, so this is conditional rather than a revert.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_012R4ySPo4ydYJGUiLrdvZtU
EOF
```

If no change was needed, commit nothing and record all three outcomes in the task report instead.

---

### Task 8: The three-leg String Catalog check

**Files:**
- Create: `/tmp/xcstrings-check.py` (a throwaway in the scratchpad — **not** in the repo)

**Interfaces:**
- Consumes: the catalog as edited by Tasks 5 and 6.
- Produces: a findings list for Task 9.

**Legs 1 and 2 alone cannot catch a mis-key**, which is the failure this check exists for: a mis-keyed entry has a perfect `de` value and perfectly matched specifiers and is simply never looked up. Leg 3 is the one that detects it.

- [ ] **Step 1: Write the checker**

```python
#!/usr/bin/env python3
"""Three-leg String Catalog check for Pensieve. Read-only."""
import json, re, sys, pathlib

CATALOG = pathlib.Path("Sources/PensieveApp/Localizable.xcstrings")
SOURCES = sorted(pathlib.Path("Sources/PensieveApp").rglob("*.swift"))
SPEC = re.compile(r"%(?:\d+\$)?[@a-zA-Z]|%lld|%lf")

catalog = json.loads(CATALOG.read_text())
strings = catalog["strings"]
problems = []

# Leg 1 — every key has a German value, EXCEPT keys marked shouldTranslate: false
# (those carry no `localizations` block at all and are not defects).
for key, entry in strings.items():
    if entry.get("shouldTranslate") is False:
        continue
    de = entry.get("localizations", {}).get("de", {}).get("stringUnit", {}).get("value")
    if not de:
        problems.append(("leg1-missing-de", key))

# Leg 2 — format specifiers must match between en and de.
for key, entry in strings.items():
    locs = entry.get("localizations", {})
    en = locs.get("en", {}).get("stringUnit", {}).get("value") or key
    de = locs.get("de", {}).get("stringUnit", {}).get("value")
    if not de:
        continue
    if sorted(SPEC.findall(en)) != sorted(SPEC.findall(de)):
        problems.append(("leg2-specifier-mismatch", f"{key!r}: en={SPEC.findall(en)} de={SPEC.findall(de)}"))

# Leg 3 — diff Swift literals against catalog keys, BOTH directions. This is the only leg that
# detects a mis-key: a key no literal resolves to, or a literal with no key.
literals = set()
for path in SOURCES:
    text = path.read_text()
    literals.update(re.findall(r'"((?:[^"\\\n]|\\.)+)"', text))

for key in strings:
    if strings[key].get("shouldTranslate") is False:
        continue
    if key not in literals:
        problems.append(("leg3-orphaned-key", key))

for problem_kind, detail in problems:
    print(f"{problem_kind}\t{detail}")
print(f"\n{len(problems)} finding(s) across {len(strings)} keys, {len(SOURCES)} Swift files",
      file=sys.stderr)
```

Write it to `/tmp/xcstrings-check.py`. **Do not add it to `scripts/`** — this slice was not asked to add repo tooling. Promoting it is a follow-up for Task 9's report.

- [ ] **Step 2: Run it from the worktree root**

Run: `python3 /tmp/xcstrings-check.py`

- [ ] **Step 3: Triage, do not mass-fix**

Interpret the output:

- **`leg1-missing-de` or `leg2-specifier-mismatch` on a key this slice added or touched** (`More actions`) — a real defect. Fix it now.
- **`leg3-orphaned-key` for the dormancy key** — must be **absent**. If it still appears, Task 5 Step 5 did not remove it.
- **`leg3-orphaned-key` for pre-existing keys** — expect several, including dead `.inspector`-era keys (`Inspector`, `Provenance`, `Select a loose end`). **Report them; do not delete them.** Pre-existing dead keys are not this slice's to clean.
- **Leg 3 false positives are expected.** The literal regex cannot see multi-line literals or keys interpolated at runtime. Any leg-3 finding must be confirmed with `grep -rn` against `Sources/PensieveApp` before being called a defect.

- [ ] **Step 4: Commit — only if Step 3 found a real defect in a key this slice touched**

```bash
git add Sources/PensieveApp/Localizable.xcstrings
git commit -F - <<'EOF'
fix(l10n): correct a catalog entry this slice introduced

Found by the three-leg check. Legs 1 and 2 cannot detect a mis-key -- a
mis-keyed entry has a perfect German value and matched specifiers and is simply
never looked up -- so leg 3 diffs Swift literals against catalog keys in both
directions.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_012R4ySPo4ydYJGUiLrdvZtU
EOF
```

---

### Task 9: Whole-slice verification and the human-verify carry list

**Files:**
- Create: `docs/superpowers/verify/2026-08-12-macos26-floor-human-verify.md`

**Interfaces:**
- Consumes: everything above.
- Produces: the carry list the user walks against the installed app.

- [ ] **Step 1: Full headless sweep from a clean generate**

```bash
xcodegen generate
xcodebuild -project Pensieve.xcodeproj -scheme Pensieve -configuration Debug \
  -derivedDataPath ./.build-xcode build > /tmp/slice-b-final.log 2>&1; echo "exit=$?"
tail -5 /tmp/slice-b-final.log
swiftlint --strict
./scripts/test.sh
```

Expected: `exit=0`, `BUILD SUCCEEDED`, 0 lint violations, **589** tests. A test count other than 589 means PensieveKit was touched — stop and report.

- [ ] **Step 2: Prove the invariants that no eyeball can check**

```bash
# 1. Zero Kit changes.
git diff --name-only main...HEAD | grep -E '^(Sources/PensieveKit|Tests|Package.swift)' \
  && echo "FAIL: Kit touched" || echo "OK: app-target only"

# 2. Slice C's files untouched.
git diff --name-only main...HEAD \
  | grep -E 'LooseEndRow|TranscriptSegmentView|TranscriptMessageView' \
  && echo "FAIL: slice C file touched" || echo "OK: slice C untouched"

# 3. Prose.measure unchanged.
git diff main...HEAD -- Sources/PensieveApp/ProseStyle.swift | head -1 \
  && echo "(empty above = OK)"

# 4. No explicit glass anywhere.
grep -rn 'glassEffect\|buttonStyle(.glass\|glassProminent\|GlassEffectContainer' Sources/ \
  && echo "FAIL: glass present" || echo "OK: no glass"

# 5. DetailView additions only — no reindent.
git diff main...HEAD -- Sources/PensieveApp/DetailView.swift | grep '^-' | grep -v '^---' \
  && echo "FAIL: DetailView has deletions" || echo "OK: DetailView additions only"

# 6. All three binaries at 26.0.
APP=./.build-xcode/Build/Products/Debug/Pensieve.app
for BIN in "$APP/Contents/MacOS/Pensieve" "$APP/Contents/Helpers/pensieve" \
           "$APP/Contents/Library/Helpers/PensieveSyncAgent"; do
  echo -n "$(basename "$BIN"): "; otool -l "$BIN" | grep -A4 LC_BUILD_VERSION | grep minos
done
```

Every line must read OK / `minos 26.0`. Any FAIL is a blocking defect — report, do not paper over.

- [ ] **Step 3: Smoke launch against throwaway stores**

```bash
PENSIEVE_DB=/tmp/slice-b-smoke.sqlite PENSIEVE_CAPTURE_DB=/tmp/slice-b-smoke-capture.sqlite \
  ./.build-xcode/Build/Products/Debug/Pensieve.app/Contents/MacOS/Pensieve &
sleep 5; kill %1
ls -l ~/Library/Application\ Support/Pensieve/ | head   # live store must be untouched
```

- [ ] **Step 4: Write the human-verify carry file**

Create `docs/superpowers/verify/2026-08-12-macos26-floor-human-verify.md` containing exactly these checks, each with a blank outcome line for the user to fill in:

1. **The scroll edge is a comparison, not a look.** For each of the four columns (sidebar, content, detail, Briefing): toggle `.soft` ↔ `.hard` in the source, rebuild, and confirm the top band *visibly changes*. "Material is visible at the top" passes even when the modifier landed on the wrong view or never applied — the default is `.automatic`.
2. **Detail column with ⌘F open** — the scroll view's top meets the find bar, not the titlebar. Confirm it looks deliberate.
3. **A `RecallWindowView` (⌘⌥N)** — no toolbar at all for the scroll view to meet. Confirm it looks deliberate.
4. **Which column's top carries the search field** — settles the open question in the spec's section 2. `.searchable(placement: .sidebar)` is attached to `ContentListView`, but the note at `RootView.swift:35-38` suggests SwiftUI places that chrome in the sidebar.
5. **Popover in German** (`-AppleLanguages '(de)'`): `Pensieve öffnen` renders in full; the ellipsis menu holds Refresh and Quit; the secondary line reads as German recency (`vor 3 Std. · 12 offen`), not English, not `0T ruhend`.
6. **The whole popover row is hittable** — click in the gap between the name and the chevron. This is the defect being fixed.
7. **Popover freshness** — open the popover, note a row's recency; make a commit in another window; wait for the watcher; reopen the popover. The recency must be current, not stale from the last full refresh.
8. **The sidebar footer without its hairline** — does `.bar` still separate it from the scrolling rows? Expand the project tree so rows scroll beneath it.
9. **Light, dark, Increase Contrast, Reduce Transparency** on the sidebar foot and the popover.
10. **`open ./.build-xcode/…` launches the worktree's app, not main's** — confirm with `pgrep -lf Pensieve.app/Contents/MacOS/Pensieve` before concluding anything about a regression.

- [ ] **Step 5: Record what was deliberately left open**

Append a short "Deferred / follow-ups" section to the same file:

- Bump `Package.swift` to `.macOS(.v26)` **after** the translation branch merges, and delete PensieveKit's four `if #available` sites (`DefaultProvider.swift:52`, `FoundationModelsProbe.swift:15,26`, `ModelProviderFactory.swift:15`) plus the two `Translator.swift` adds.
- Promote `/tmp/xcstrings-check.py` into `scripts/` if the three-leg check proves worth keeping.
- Pre-existing dead catalog keys from the removed `.inspector` panel, reported by Task 8 and deliberately not cleaned here.
- The popover's larger composition (two `Divider()`s, the caption header, the undifferentiated `ForEach`) — this slice fixed a hit-testing defect, a truncating footer and the secondary line, not the composition.
- Full Keyboard Access tab order — app-wide, pre-existing, out of scope.

- [ ] **Step 6: Commit**

```bash
git add docs/superpowers/verify/2026-08-12-macos26-floor-human-verify.md
git commit -F - <<'EOF'
docs: human-verify carries for the macOS 26 floor slice

The scroll-edge check is a comparison rather than a look, deliberately: the
default is .automatic, so "material is visible at the top" passes even when the
modifier landed on the wrong view or never applied at all.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_012R4ySPo4ydYJGUiLrdvZtU
EOF
```

---

## Self-review — spec coverage

| Spec section | Task |
|---|---|
| §1 The floor (three binaries, no per-target override) | 1 |
| §2 The scroll edge (four sites, `body` not `normalContent`, FindBar/RecallWindow caveats, per-site fallback) | 2, 9 |
| §3 Sidebar footer (keep pin + `.bar`, drop `Divider`) | 3, 7 |
| §4 Popover (`NodeRowMeta` reuse, `refreshGlance`, `rowHitArea`, `.borderedProminent`, width 320) | 4, 5, 6 |
| §5 Appearance and accessibility (Reduce Transparency, Increase Contrast, Reduce Motion) | 7 |
| §6 Localization (no new keys except `More actions`, orphan removal, three-leg check) | 5, 6, 8 |
| Verification (build, lint, `otool` ×3, catalog, smoke, human carries) | 1, 9 |
| Risks (`DetailView` no-reindent, 589, no glass) | 2, 9 |

**Deviations from the spec, both deliberate:** the spec said "no new keys"; Task 6 adds exactly one (`More actions`) because the ellipsis `Menu` needs an accessible label — flagged rather than smuggled. And the spec's §2 table lists `DetailView.swift:32`; Task 2 permits attaching to the `ScrollViewReader` chain instead when brace pairing is ambiguous, because threading makes them equivalent and the no-reindent constraint outranks the exact line.
