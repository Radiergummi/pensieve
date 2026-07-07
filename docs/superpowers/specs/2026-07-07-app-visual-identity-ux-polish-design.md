# App visual identity & UX polish — design

**Date:** 2026-07-07
**Status:** approved (brainstorm), pending spec review
**Scope:** Pensieve.app three-pane UI. Fixes seven UX issues that share one backbone — a
per-kind / per-source **visual-identity system** (localizable label + icon + color), plus a
user-chosen icon+color per node, a New/Edit modal, manual delete, and a GitHub-style timeline.

## Motivation (the seven issues)

1. The sidebar liveness footer (green dot + "capturing") clashes with / overlaps the project list.
2. Sidebar top-level sections ("Smart Lists", "Projects") should be collapsible.
3. New-node creation persists immediately and shows a useless empty node. Instead: a modal dialog
   (Reminders.app-style) with **name + color + icon/emoji** pickers. That icon+color then drives the
   middle-pane list (colored icon badge) and everywhere else the node appears. Kind defaults when
   the user hasn't chosen.
4. Manual node deletion should be possible.
5. Node kinds need a **localizable** label (reverses the old "kinds are English-only roles" note).
6. The detail header (`strand · active`) should show the localized **kind label** and turn the state
   into a **colored orb** status indicator, alongside the node's icon.
7. The "Recent Activity" list is bland. Source labels should be localized (`git.commit` → "Git
   Commit", `cc.session` → "Claude Code Session") with icon+color, and the list should render as a
   **GitHub-style vertical-rail timeline**.

## Design decisions (locked in brainstorm)

- **Node icon+color storage:** two new columns on `Node` (`icon`, `colorTag`), additive **migration
  v8** (the v4–v6 additive pattern; note `v7-incremental-extraction` already exists).
- **Icon picker:** both **emoji and SF Symbols** (Reminders-style segmented picker).
- **Delete:** **cascade with confirmation** — node + descendants + their events/loose ends/sources,
  behind a destructive dialog naming the counts.
- **Timeline:** **full GitHub-style rail** (day grouping, per-event dot, source icon+color+label).
- **Color palette:** a fixed ~12-color named set (Reminders-style); `colorTag` stores the name.
- **Modal replaces** inline-rename + "Change Type" submenu (both subsumed by the New/Edit modal).

## Architecture split (Kit vs App)

PensieveKit must stay **SwiftUI-free** (the CLI links it). So Kit holds **strings and logic only**;
the app resolves strings → `Color` / `Image` / localized `Text`. Localized display text lives in the
**app** String Catalog (localization is an app concern); Kit exposes stable keys / raw identifiers.

### PensieveKit (tested)

- **`Node` gains `icon: String` and `colorTag: String`** (both `TEXT NOT NULL DEFAULT ''`). Empty =
  "use the kind default". Update the `@Table struct Node` + its `init` (default `""`).
- **Migration v8** in `CanonicalStore.swift`, immediately after v7:
  ```swift
  migrator.registerMigration("v8-node-appearance") { db in
    try #sql(#"ALTER TABLE "nodes" ADD COLUMN "icon" TEXT NOT NULL DEFAULT ''"#).execute(db)
    try #sql(#"ALTER TABLE "nodes" ADD COLUMN "colorTag" TEXT NOT NULL DEFAULT ''"#).execute(db)
  }
  ```
  (Table name confirmed `nodes`, per the v4 rename migration. Note `nodes.parentID` has
  `ON DELETE SET NULL`, so delete must gather + remove descendants explicitly — see below.)
- **`NodeKindStyle`** (new file, e.g. `Sources/PensieveKit/Model/VisualIdentity.swift`): a pure
  table `kind → (iconName: String, colorTag: String)` giving each `NodeKind` a default SF-symbol name
  and palette color name. Test: every `NodeKind.all` has an entry.
- **`EventSourceStyle`**: `event.kind → (labelKey: String, iconName: String, colorTag: String)` for
  `git.commit`, `git.checkout`, `cc.session`, `cc.session.start`. `labelKey` is a stable string the
  app maps to a `LocalizedStringResource`. Test: every `CaptureKind` value has an entry + a fallback.
- **`NodeAppearance`**: resolves a node's *effective* icon + colorTag — its own `icon`/`colorTag`
  if non-empty, else the `NodeKindStyle` default for its kind. Icon strings use a scheme:
  `"sf:<symbol>"` or `"emoji:<grapheme>"`. A tiny tested parser (`AppearanceIcon.parse`) turns the
  stored string into `.sfSymbol(String)` / `.emoji(String)` (an enum in Kit; the app renders it).
  Tests: own-value wins; empty falls back to kind default; parser round-trips both schemes; malformed
  string degrades to the kind default.
- **`NodeCommands.delete(_ db:, nodeID:) -> (nodes: Int, events: Int)`** (new): in one transaction,
  gather `nodeID` + all descendants (reuse `NodeForest.descendantIDs` / the cycle-safe walk), then
  delete their loose ends, events, sources, and finally the nodes. Return the deleted node + event
  counts for the confirmation copy. Tests: cascade removes the subtree + its events/loose ends;
  sibling and unrelated subtrees are untouched; deleting a leaf works; return counts are correct.

### PensieveApp (thin views; human-verify visuals)

- **`AppearanceStyle` (app-side resolver)**: maps a `colorTag` name → `Color` (the fixed palette),
  and a Kit `AppearanceIcon` → a SwiftUI `Image` (SF Symbol) or `Text` (emoji). One place, reused by
  sidebar, middle list, detail header. Also maps `NodeKind` → `LocalizedStringResource` (kind
  labels), `EventSourceStyle.labelKey` → `LocalizedStringResource` (source labels), and node `state`
  → (localized label, orb `Color`).
- **`NodeEditor` sheet** (New + Edit): fields = name `TextField`, kind `Picker` (localized labels),
  color grid (fixed palette swatches, selected ring), and a segmented **emoji / SF-symbol** picker.
  - Backed by an `@Published var editingNode: NodeEditRequest?` on `AppModel` (`.new(parent:)` or
    `.edit(node:)`), mounted as a `.sheet` in `RootView`.
  - **New:** OK → `NodeCommands.add` with the chosen kind + a follow-up write of icon/colorTag (or
    extend `add` to accept them). Cancel writes nothing. Pre-selects `defaultKind(under:)`.
  - **Edit:** OK writes name, kind, icon, colorTag (one `AppModel.updateNode(...)` → refresh).
  - Replaces the current `createNode` inline-rename flow and the "Change Type" submenu. The
    `NodeNameField` inline-rename view is removed.
- **Context menu** (`NodeContextMenu`) becomes: **New Child…**, **Edit…**, — divider —,
  **Move to…**, **Merge into…**, — divider —, **Delete…** (destructive, confirmation naming the
  counts from `NodeCommands.delete`).
- **#1 footer:** `StatusFooter` gets a `.background(.bar)` so list rows scroll under it, no clash.
- **#2 collapsible:** "Smart Lists" and "Projects" become `Section(header:, isExpanded:)` bound to
  `@AppStorage` flags (default expanded). Briefing stays a standalone row.
- **#3 middle list (`ContentListView`):** each row shows a **colored rounded-rect icon badge**
  (effective icon + color) leading the name; subtitle = the **localized kind label** (replacing raw
  `node.kind`).
- **#6 detail header (`DetailView`):** icon badge + title; subtitle row = localized **kind label** +
  a **colored state orb** (active=green, muted=orange, archived=gray) with its localized state label.
- **Sidebar tree rows** use the same effective icon+color (identity is consistent everywhere).
- **#7 timeline (`DetailView` "Recent Activity"):** replace the flat rows with a vertical-rail
  timeline: events grouped by day (localized day header), a leading rail line with a colored dot per
  event, a source icon+color badge, the **localized source label**, and the summary. No avatars
  (single-user). Keep it a thin view over the same `recentEvents` already loaded in `.task`.

## Localization (German)

New keys in `Sources/PensieveApp/Localizable.xcstrings` (en base + de): 7 kind labels, ~4 source
labels, 3 state labels, and modal/menu chrome (New Node, Edit…, New Child…, Delete…, Name, Color,
Symbol, Emoji, OK, Cancel, delete-confirmation format string with counts). Content — node names,
loose-end quotes, event summaries, descriptions — stays un-localized. Per the l10n gotcha,
`xcodebuild` does **not** auto-populate the catalog; author/reconcile keys by hand against the Swift
literals (`%lld`/`%@`).

## Testing & verification

- **Kit unit tests** (in `Tests/PensieveKitTests/`): migration v8 round-trip (columns present,
  default `''`, existing rows readable); `NodeCommands.delete` cascade + counts + isolation;
  `NodeKindStyle`/`EventSourceStyle` completeness; `NodeAppearance` fallback + `AppearanceIcon`
  parser round-trip/malformed.
- **App**: `xcodegen generate` → `xcodebuild … build` + a non-blocking smoke-launch of the inner
  binary with throwaway `PENSIEVE_DB`/`PENSIEVE_CAPTURE_DB`.
- **Human-verify carries** (need the built app + real store + `open`): footer no longer clashes;
  sections collapse/expand and persist; New/Edit modal creates/edits with chosen color+icon; icon
  badges render in list/sidebar/header; state orb color; timeline rail renders with grouped days +
  source badges; delete confirmation names counts and removes the subtree; `pensieve list` still
  matches; German renders in situ (`-AppleLanguages '(de)'`).

## Implementation plans (two)

- **Plan A — Kit foundation:** `Node` columns + migration v8; `NodeKindStyle` / `EventSourceStyle` /
  `NodeAppearance` / `AppearanceIcon`; `NodeCommands.delete`; all Kit tests.
- **Plan B — App surfaces:** `AppearanceStyle` resolver; `NodeEditor` modal + `AppModel` wiring
  (create/edit/delete, remove inline-rename); footer material; collapsible sections; middle-list
  badge; detail header (kind label + orb); GitHub-style timeline; localization.

## Out of scope

Drag-and-drop reorder; icon/color on smart lists or the Briefing; per-source avatars; changing the
capture/ingest path or the trust gate; CLI changes (kind/source labels in the CLI stay as-is).
