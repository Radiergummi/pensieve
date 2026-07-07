# App chrome polish batch — spec + plan (2026-07-07)

Four small-to-medium **app-target-only** polish items from the backlog section
"App UX & IA polish carries — 2026-07-07" (items 1–4). **Explicitly out of scope:** item 5
(three-pane IA rework) and the Sharing pillar — both get their own brainstorm→spec.

These are cohesive "make the chrome feel Apple-native" changes with no shared correctness
surface, so they share one spec + one plan. **No PensieveKit changes** — all four are pure view
styling / wiring over existing `AppModel` methods and existing Kit `NodeCommands`. The app target
has no unit tests → each task is verified by `xcodebuild` **BUILD SUCCEEDED** + a non-blocking
smoke-launch of the inner binary; the visual results are human-verify carries.

Ordered smallest-first: **1 (typography) → 3 (indicator) → 2 (toolbar) → 4 (modal)**. (Backlog
numbering kept in headings; execution order is smallest-first.)

---

## Task 1 — Prose typography

**Problem.** Displayed prose (LLM "Last Work Done" narration, node descriptions, loose-end text +
quote, timeline summaries, Briefing latest-summary) renders at the default 13pt `.body`/`.callout`
with tight leading and no measure — lines run edge-to-edge on a wide window and read cramped.

**Design.** One new app-only file `Sources/PensieveApp/ProseStyle.swift`:

```swift
import SwiftUI

/// Shared reading-prose treatment for the app's content text (narration, descriptions,
/// loose-end text/quotes, activity summaries). App-only styling; no Kit involvement.
enum Prose {
  /// Max reading-column width. Caps line length on wide windows so prose stays readable.
  static let measure: CGFloat = 680
}

extension View {
  /// Body prose: a slightly larger size with generous leading. Apply to text runs, not headers.
  func prose() -> some View {
    self.font(.system(size: 14))
      .lineSpacing(4)
  }
}
```

**Apply `.prose()` to** (replacing the current `.font(.body)`/`.font(.callout)` on the prose run
only — headers, captions, labels, and metadata lines are unchanged):
- `DetailView`: the "Last Work Done" `Text(lastWorkDone)`; the node `Text(node.description)`; the
  loose-end `Text(view.looseEnd.text)`; the verbatim `Text(view.looseEnd.quote)` (keep `.italic()`).
- `DetailView` → `TimelineRow`: `Text(event.summary)` (currently `.callout`).
- `BriefingView`: `Text(c.latestSummary)` (currently `.callout`; keep `.lineLimit(1)` — it's a card
  teaser, so it gets the font bump but stays one line).

**Apply the measure cap** by adding `.frame(maxWidth: Prose.measure, alignment: .leading)` to the
content `VStack` in `DetailView.body` and `BriefingView.body`, *inside* the existing
`.frame(maxWidth: .infinity, alignment: .leading)` wrapper — i.e. wrap the inner `VStack` so the
column caps at 680pt but stays left-aligned in a wider `ScrollView`. Concretely: keep the outer
`.frame(maxWidth: .infinity, alignment: .leading)` and add the measure cap to the `VStack` before
it, so the text column is bounded but the scroll view fills the pane.

**No localization impact** (styling only). **Verify:** build + smoke; human eyeballs larger, airier
prose with a bounded column on a wide window.

---

## Task 3 — Native sidebar tracking indicator

**Problem.** `SidebarView`'s `StatusFooter` uses `.background(.bar)` — it fixed an earlier color
clash but reads as a bolted-on band, not the idiomatic macOS bottom status bar.

**Design.** Make it the standard Finder/Mail-style bottom status bar: a top hairline `Divider()`
above the existing content, over `.background(.bar)`. Minimal change to `StatusFooter.body`:

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

(Dot 8→7 and vertical padding 8→6 for a slightly more restrained bar; the hairline is what makes it
read native.) No new strings. **Verify:** build + smoke; human eyeballs a translucent bottom bar
under a hairline that no longer looks bolted-on.

---

## Task 2 — Window toolbar actions

**Problem.** `RootView.toolbar` has only the "+" New Node item; the common node actions live only in
the context menu.

**Design.** Extend `RootView.toolbar` with toolbar items wired to the **existing** `AppModel`
methods and gated exactly like `NodeContextMenu`. All reuse the sheets/dialogs already mounted in
`RootView` — no new navigation paths.

Structure (a computed `selectedNode` helper reads `model.selectedNodeID` → `model.node(id)`):

- **Primary (leading, kept):** New Node — `plus` → `model.presentNewNode(under: nil)`.
- **Node-ops group** (each `.disabled(model.selectedNodeID == nil)`):
  - Edit — `pencil` → `model.presentEditNode(node)`.
  - Move — `arrow.up.and.down.text.horizontal` → `model.movePickerNodeID = id`.
  - Merge — `arrow.triangle.merge` → `model.mergePickerNodeID = id`.
  - Delete — `trash` (`role: .destructive` where supported) → `model.pendingDeleteNodeID = id`;
    additionally `.disabled(selectedNodeID == nil || !model.canDelete(id))`.
- **Trailing:**
  - Refresh — `arrow.clockwise` → `Task { await model.refreshNow() }`.
  - Inspector — `sidebar.trailing` → `model.showInspector.toggle()`.

Each button gets `.help(...)` with a localized tooltip. Use `ToolbarItemGroup` for the node-ops
cluster; place Refresh/Inspector in a trailing `ToolbarItemGroup(placement: .primaryAction)` (or
`.automatic` trailing). Guard against re-entrancy: computing `canDelete` in the toolbar body calls a
Kit read per body eval — acceptable here (toolbar re-evals are infrequent vs. the inspector's known
in-body-query concern), but read `selectedNodeID` once and short-circuit `canDelete` only when a
node is selected.

**New strings (en + de) in `Localizable.xcstrings`** — the `.help(...)` tooltips (the button
labels reuse existing keys "New Node", "Edit…"→ use "Edit", "Move to…", "Merge into…", "Delete…",
"Refresh", "Inspector" where they already exist; add any missing). Tooltips to add:
- "New Node" (exists) · "Edit" · "Move to…" (exists) · "Merge into…" (exists) · "Delete" ·
  "Refresh" (exists) · "Inspector" (exists) — add German for any newly introduced key. Reconcile by
  hand (xcodebuild won't auto-populate).

**Verify:** build + smoke; human clicks each toolbar action against a real store and confirms the
same sheet/dialog opens as the context menu, and node-ops disable with no selection.

---

## Task 4 — New/Edit modal: Reminders-parity layout + popover pickers

**Problem.** `NodeEditor` stacks Name/Type, then a color grid, then an always-open segmented
Symbol|Emoji grid — the icon grid reads as a random block and the dialog is unbalanced.

**Design.** Rebalance into a two-zone `HStack`, matching macOS Reminders' "New List" dialog.

**Left zone (`VStack`, the form):**
- Name `TextField`.
- Type `Picker`.
- A compact **color row** — the existing palette `LazyVGrid` (keep as-is, or a single-row
  `LazyHGrid`; a 6-wide grid is fine).

**Right zone (`VStack`, centered):**
- A large **preview circle** (~72pt) showing the live color + chosen icon, built from the editor's
  `icon`/`colorTag` state (not a `Node`) via a small inline view:

  ```swift
  private var preview: some View {
    Circle().fill(AppearanceStyle.color(colorTag)).frame(width: 72, height: 72)
      .overlay {
        Group {
          switch AppearanceIcon.parse(icon) {
          case .sfSymbol(let n): Image(systemName: n).foregroundStyle(.white)
          case .emoji(let e):    Text(e)
          case nil:              Image(systemName: "questionmark").foregroundStyle(.white)
          }
        }.font(.system(size: 34))
      }
  }
  ```
- Two buttons **that open popovers** (replacing the inline segmented grid):
  - **Symbol** — opens a popover with a **search `TextField`** filtering an expanded SF-Symbol set
    (the existing `symbols` list, broadened) in a scrollable `LazyVGrid`; tapping a symbol sets
    `icon = "sf:<name>"` and dismisses. State: `@State private var showSymbolPopover = false`,
    `@State private var symbolQuery = ""`.
  - **Emoji** — opens the **system Character Viewer** (the user-chosen native path):
    `NSApp.orderFrontCharacterPalette(nil)`. To capture the chosen emoji, keep a hidden capture
    `TextField` bound to `@State private var emojiCapture = ""` that becomes first responder when
    the Emoji button is pressed (via `@FocusState`); on `.onChange(of: emojiCapture)` extract the
    last emoji grapheme (a `Character` whose `unicodeScalars.contains { $0.properties.isEmoji &&
    ($0.value > 0x238C || $0.properties.isEmojiPresentation) }`), set `icon = "emoji:<grapheme>"`,
    and clear `emojiCapture`. Non-emoji input is ignored.

    **Implementation note / fallback:** the capture-field approach is the genuinely-native path but
    is fiddly (first-responder timing; filtering). If, during implementation, reliable capture
    proves flaky in the smoke run, fall back to a curated-emoji **popover grid** (the existing
    `emojis` list) — same stored form, same look as the Symbol popover — and note it as a carry.
    Do **not** block the batch on Character-Viewer capture.

**Stored form unchanged.** `commit()` still calls `model.commitNewNode(...)` / `updateNode(...)`
with `icon` in `sf:<name>` / `emoji:<grapheme>` form and `colorTag`. `load()` unchanged. The
segmented `IconTab`/`iconGrid`/`cell` machinery is **removed** (replaced by the two popovers).

Dialog frame: widen slightly (~`width: 480`) to seat two zones; keep Cancel/Save footer.

**New strings (en + de):** "Symbol", "Emoji", and the symbol-popover search placeholder
"Search symbols" (or reuse "Search"). Add German by hand.

**Verify:** build + smoke; human creates/edits a node — picks a color, opens the Symbol popover and
searches + picks an SF Symbol, opens the Emoji button → system Character Viewer → picks an emoji →
preview + saved badge reflect it; `pensieve list` unaffected (names/kinds unchanged); German in situ.

---

## Execution plan (subagent-driven, isolated worktree)

Worktree: `git worktree add ../pensieve-chrome-polish -b feat/app-chrome-polish`. Fresh SDD ledger.
One implementer + one task-reviewer (Sonnet) per task, then an **Opus** whole-branch review, then
`finishing-a-development-branch`.

Per-task verification (all four): from the worktree,
`xcodegen generate && xcodebuild -project Pensieve.xcodeproj -scheme Pensieve -configuration Debug
-derivedDataPath ./.build-xcode build` → **BUILD SUCCEEDED**, then background-launch
`./.build-xcode/Build/Products/Debug/Pensieve.app/Contents/MacOS/Pensieve` with throwaway
`PENSIEVE_DB`/`PENSIEVE_CAPTURE_DB` (`/tmp` paths), confirm it stays up ~2s, then `kill`.

- **T1 — Typography.** Add `ProseStyle.swift`; apply `.prose()` + measure cap in `DetailView` /
  `BriefingView` (incl. `TimelineRow`). Build + smoke.
- **T3 — Sidebar indicator.** Rework `StatusFooter.body` (Divider + `.bar`). Build + smoke.
- **T2 — Toolbar.** Extend `RootView.toolbar`; add `selectedNode` helper + gating; add/reconcile
  `.help` strings (en+de). Build + smoke.
- **T4 — Modal.** Rebalance `NodeEditor` into two zones; add Symbol search popover + Emoji
  Character-Viewer capture (with the curated-grid fallback); remove the segmented inline grid; add
  strings (en+de). Build + smoke.

**Localization:** any new UI string gets en + de keys in `Localizable.xcstrings` by hand (chrome
only; node names/quotes/summaries stay un-localized). Verify a `de.lproj/Localizable.strings`
compiles after T2/T4.

**Human-verify carries (list at merge; can't be asserted headlessly):**
1. Prose reads larger/airier with a bounded reading column on a wide window (Detail + Briefing).
2. Sidebar bottom bar reads native (hairline + translucent), no longer a bolted-on band.
3. Each new toolbar action opens the same sheet/dialog as the context menu; node-ops disable with
   no selection; Delete disabled on activity-born nodes.
4. New/Edit modal: balanced two-zone layout; live preview circle; Symbol search popover picks an SF
   Symbol; Emoji button opens the system Character Viewer and the picked emoji lands in the badge;
   German renders in situ (`-AppleLanguages '(de)'`).

## Out of scope (own specs)
- Backlog item 5 — three-pane IA (middle pane shows children/loose ends). Genuine IA decision.
- Sharing pillar — export/share a node's grounded recall.
