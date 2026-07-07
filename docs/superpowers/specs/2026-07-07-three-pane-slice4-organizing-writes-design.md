# Pensieve.app three-pane — slice 4: in-app organizing writes (design)

**Date:** 2026-07-07
**Status:** approved (brainstormed → this spec)
**Builds on:** `docs/superpowers/specs/2026-07-05-pensieve-app-three-pane-design.md` (slice 4 in the build
sequence), slices 1–3b (all merged to `main`).

## Goal

Let me reorganize the typed node tree **from inside the app** — create, rename, change type, move, and
merge nodes — using the same PensieveKit organizing operations the CLI already exposes, surfaced through
native context menus + in-place rename. Reorganizing in the UI must match the CLI's effect exactly, and
**no user action may create a tree cycle**.

This is the product-spine slice that turns the app from read-only recall into a place I can actually
tidy my world map. It is deliberately **metadata-only**: it never touches event ingestion (the
single-writer principle governs the spool→canonical drain, not organizing edits — see the three-pane
design's "Data & write path").

## The five operations

Surfaced on **both** the sidebar tree rows and the middle content-list rows, via `.contextMenu`:

1. **New Child** — create a child node under the right-clicked node.
2. **Rename** — in-place `TextField` edit of the node's name.
3. **Change Type ▸** — a submenu of all seven kinds (`domain` / `project` / `strand` / `concept` /
   `initiative` / `task` / `topic`), a checkmark on the current one.
4. **Move to…** — reparent the node under another node (or to top level), via a picker.
5. **Merge into…** — **destructive**: merge this node into a target (the target absorbs its sources,
   events, loose ends, checkpoints, and children; this node is deleted). Confirmation required.

Plus a **toolbar "+"** and **File ▸ New Node (⌘N)** for creating a top-level node.

### Explicit non-goals (YAGNI, this slice)

- **No standalone delete, and no archive/mute.** Deletion happens **only** through Merge. The `Node.state`
  field (`active`/`archived`/`muted`) stays CLI-only for now.
- **No Undo/`UndoManager` integration.** The Merge confirmation dialog is the safety net; the
  non-destructive ops (rename / retype / move / create) are trivially reversible by hand.
- **No Talk-to-system** (describe→create a strand) — that is slice 5.

## PensieveKit changes (the load-bearing, tested part)

All app writes route through PensieveKit ops (never raw SQL). Three changes, each with tests.

### a. Unified guarded reparent path — fixes the missing cycle guard on `nest`

`NodeCommands.nest` currently sets `parentID` with **no cycle check** — nesting a node under its own
descendant would corrupt the tree the whole app renders (the read-side `NodeForest.build` has a cycle
guard, so it wouldn't infinite-loop, but the data would be wrong).

Extract the guarded core:

```swift
// Returns false if nodeID/newParentID is unknown, or if the move would create a cycle
// (newParentID is nodeID itself, or nodeID is an ancestor of newParentID). nil = move to root.
@discardableResult
public static func reparent(_ db: any DatabaseWriter, nodeID: UUID, newParentID: UUID?) throws -> Bool
```

- Walks from `newParentID` up the `parentID` chain; refuses (returns `false`, no write) if it reaches
  `nodeID`, or if `newParentID == nodeID`. `nil` (root) is always safe.
- `nest(child:under:)` (String-keyed, used by the CLI) becomes a thin wrapper: resolve both names →
  call `reparent`. **CLI behavior is unchanged** except that a would-be-cyclic `nest` now returns
  `false` instead of corrupting the tree.
- The app calls `reparent` directly with the UUIDs it already holds (Move to…, including move-to-root).

### b. Fix the latent `ProjectResolver.group` self-cycle

When merging `other` into `primary`, `group` reparents *every* child of `other` to `primary` — **including
`primary` itself** when `primary` is a child of `other` (merging a parent into its own child), leaving the
child pointing at itself.

Fix: before/while reparenting `other`'s children —
- if `primary.parentID == other`, first set `primary.parentID = other.parentID` (promote `primary` to
  `other`'s parent — grandparent, or root if `other` was a root), **and**
- exclude `primary` from the "reparent children of `other`" update (belt-and-suspenders).

### c. Pure descendant helper (for the UI-level picker guard)

```swift
// All transitive descendants of `id` within `nodes` (excludes `id` itself). Read-only, deterministic.
public static func descendantIDs(of id: UUID, in nodes: [Node]) -> Set<UUID>
```

Lives on `NodeForest` (alongside `build`). The Move/Merge pickers use it to filter out **self + all
descendants** so the UI never even offers a cyclic target — a UI guard layered atop the write guard in (a).

### Tests (PensieveKit)

- `reparent` refuses nesting a node under its own descendant (and under itself); tree unchanged; returns
  `false`. A legal reparent succeeds and updates `parentID`. `nil` moves to root.
- `nest` (String wrapper) still works for the legal case and now returns `false` (no corruption) for the
  cyclic case.
- `group` merging a parent into its own child re-roots the child at the grandparent (or root), never at
  itself; the standard merge (unrelated nodes) still repoints sources/events/loose-ends/checkpoints/children
  and deletes the merged node.
- `descendantIDs` returns the correct transitive set (nested strands), excludes the node itself, and is
  empty for a leaf.

## App changes (thin — no unit tests; verified by build + smoke-launch)

### `AppModel` write methods

Each method calls the PensieveKit op, then `refresh()` **explicitly** (Node-only writes don't change the
`Event` count, so the liveness `ValueObservation` won't fire for them):

- `createNode(under parentID: UUID?)` — `NodeCommands.add(name: "New Node", kind: defaultKind(under:), parent: parentID)`
  → `refresh()` → select the new node → set `renamingNodeID = new.id` (enter rename).
- `rename(_ nodeID: UUID, to newName: String)` — trims; ignores empty (cancel); `NodeCommands.rename` → `refresh()`.
- `retype(_ nodeID: UUID, to kind: String)` — `NodeCommands.retype` → `refresh()`.
- `move(_ nodeID: UUID, under newParentID: UUID?)` — `NodeCommands.reparent` → `refresh()`.
- `merge(_ sourceID: UUID, into targetID: UUID)` — `ProjectResolver(db:).group(targetID, into: [sourceID])`
  → clear selection if it pointed at `sourceID` → `refresh()`.
- New `@Published var renamingNodeID: UUID?` drives the in-place `TextField`.

**Default kind for a new node** (`defaultKind(under:)`): top-level (`nil` parent) → `project`; New Child
under a `project` or `domain` → `strand`; otherwise → `project`. Immediately adjustable via Change Type.

### The rename-visibility wrinkle (SwiftUI/macOS)

`OutlineGroup` manages its **own** expansion state — we cannot programmatically expand a collapsed parent
to reveal a freshly-created child without rewriting the sidebar tree as manual `DisclosureGroup`s (out of
scope). So:

- **Creation renames in the middle content list.** `ContentListView` already shows `[selected node] + its
  direct children`. New Child selects the *parent* → the new child appears in that flat list → inline-rename
  happens there, where the row is guaranteed visible. Top-level New Node selects the new root → it shows in
  the middle list → rename there.
- **Existing-node Rename** triggered from a visible tree/list row edits in place on that row (the row you
  right-clicked is by definition visible).

The in-place row (both surfaces) renders a focused `TextField` when `model.renamingNodeID == node.id`:
commit on Enter/blur (`rename`), cancel on Esc (clear `renamingNodeID`, no write). `@FocusState` drives
focus.

### Pickers & confirmation

- **Move to… / Merge into…** present a picker (sheet) of candidate target nodes, the list filtered by
  `NodeForest.descendantIDs` to exclude self + descendants. Move also offers a **"Top level"** row
  (`reparent(nil)`). Keep the picker view thin over the tested filter.
- **Merge** shows a `.confirmationDialog` with a destructive-role confirm button:
  *"Merge '<source>' into '<target>'? Its sources, activity, and loose ends move to '<target>', and
  '<source>' is deleted. This can't be undone."*

### Minor UI

- Extend the sidebar's `symbol(for kind:)` to map all seven kinds to SF Symbols (used by the tree and the
  Change Type submenu); the four currently-inert kinds get sensible icons.
- All new chrome strings use `String(localized:)` / `LocalizedStringKey` and are added to
  `Localizable.xcstrings` (English base + German `de`), per the localization ledger — **chrome only**,
  never node names / descriptions / quotes.

## Verification

- **PensieveKit:** `./scripts/test.sh` — the new tests above pass; existing 173 still pass.
- **App:** `xcodegen generate` → `xcodebuild … build`; non-blocking smoke-launch of the inner binary with
  throwaway `PENSIEVE_DB`/`PENSIEVE_CAPTURE_DB` (never the live store) confirms it launches.
- **Human-verify carries** (need the built app, can't be asserted headlessly): create a top-level node and
  a child, rename each in place (Enter commits, Esc cancels), change a node's type (icon updates), move a
  node under another and to top level, and confirm **Move to…/Merge into… never list the node or its
  descendants**; merge two nodes and confirm the confirmation copy + that the merged node's activity now
  shows under the target; confirm the CLI (`pensieve list`) reflects the same tree after each op.

## Process

Subagent-driven per the house loop: worktree → per-task implementer (Sonnet) + task-reviewer (Sonnet) →
Opus whole-branch review → fixes → `finishing-a-development-branch`. PensieveKit tasks are TDD (tests
first). App tasks are thin and verified by build + smoke-launch (the app target has no unit tests).
