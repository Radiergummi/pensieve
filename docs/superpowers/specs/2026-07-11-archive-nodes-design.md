# Archive Nodes — Design

**Date:** 2026-07-11
**Status:** Approved (design)

## Goal

Let the user **archive** a node to move stale work out of sight without deleting it.
Archiving is the escape hatch for nodes that `delete` refuses (any node with a live
git/session source, which would resurrect on the next drain). Archived nodes live in a
new, **collapsed-by-default** "Archived" sidebar section and drop out of every normal
view. Archiving is **snooze-like**: new captured activity brings an archived node back.

Scope: **Archive only.** The `muted` state (sticky-hidden, immune to resurrection) is
acknowledged as the future counterpart but is **not** built here.

## Key finding: the model already supports this

`Node.state` already exists as a `String` documented `"active" | "archived" | "muted"`
(`Sources/PensieveKit/Model/Node.swift:23`). It predates the current migration set (came
from the original `v1-projects` CREATE TABLE; migrations are now at v11). **No migration
and no schema change are required** — archive reuses `state == "archived"`.

Several queries already filter `state == "active"` and so exclude archived nodes for free:
`NextQueries` (feeds Smart Lists), `BriefingQueries`, `NodeFacts.all` (feeds Spotlight),
`Digest`. The gap is the app's tree, which is built from the **unfiltered**
`ProjectQueries.all` (`ProjectQueries.swift:14`).

## Behavior

### Archiving a subtree

Archiving a node archives **it and all its descendants** (whole-subtree). In the Archived
section the subtree renders as a collapsed tree, preserving structure. Unarchiving from the
archived root restores the whole subtree to `active`.

There is **no** source/branchKey guard (unlike `delete`): archive is always permitted. That
is the point — it is precisely the nodes you cannot delete that you want to be able to hide.

### Resurrection on activity (snooze semantics)

When `Ingester.drain()` attributes a new event (git commit or Claude session) to a node
whose `state == "archived"`, that node **and its ancestor chain up to the root** flip back to
`"active"`, so the resurfaced node reappears **in place** in the active tree. Sibling
descendants stay archived. `muted` nodes are never resurfaced (that is their sticky purpose,
reserved for later).

Resurrecting the ancestor chain (not just the single attributed node) keeps the tree
coherent: a stray commit on one archived strand reactivates the strand's path back to root,
rather than orphaning an active node under a still-archived parent.

This logic lives in the **ingest** path (which is allowed to do work), never in the sacred,
fire-and-forget capture path.

## Components

### 1. Write path — `NodeCommands` (PensieveKit, tested)

Two new ops in `Sources/PensieveKit/Query/NodeCommands.swift`, mirroring `retype`/`delete`:

- `archive(_ db: any DatabaseWriter, nodeID: UUID) throws -> Bool`
  Sets `state = "archived"` for `nodeID` ∪ `NodeForest.descendantIDs(of:in:)`. Returns
  `false` if `nodeID` does not exist.
- `unarchive(_ db: any DatabaseWriter, nodeID: UUID) throws -> Bool`
  Sets `state = "active"` for `nodeID` ∪ descendants (setting an already-active descendant
  to active is a harmless no-op — this cleanly handles the resurrection edge where some
  descendants were individually reactivated).

`NodeCommands.update` deliberately leaves `state` untouched, so a dedicated command (as with
`retype`/`reparent`) is the idiomatic fit.

### 2. Resurrection — `Ingester` (PensieveKit, tested)

Add `resurfaceIfArchived(_ db: Database, nodeID: UUID) throws`: walk `nodeID` and its
ancestor chain (reuse the `ancestorIDs` helper pattern from `NodeCommands`); for each node
with `state == "archived"`, set it to `"active"`. Nodes with `state == "muted"` are skipped.

Call it in `Ingester.swift` immediately after an event is attributed, for **both** attributed
paths — the git-commit path (`attr.nodeID`, ~line 63–65) and the Claude-session path
(`attr.nodeID`, ~line 115–117). The in-progress git path attributes to `project.id`
(~line 80) — resurface that too.

### 3. Filtering (PensieveKit + thin `AppModel` wiring)

- **Active forest / middle list:** filter to `state == "active"` (excludes archived and any
  future muted). Applied in `AppModel.refresh()` alongside the existing
  `NodeContextResolver.visibleNodeIDs` Focus filter, so the two compose. `allNodes` stays the
  full set (as it already must for Focus filtering, `node(_:)` lookup, etc.).
- **Archived forest:** a published `archivedForest: [NodeForestNode]` built from
  `allNodes.filter { $0.state == "archived" }` (further narrowed by the same context filter
  for consistency). `NodeForest.build` already promotes parent-absent nodes to roots
  (`NodeForest.swift:22-23`), so a resurrected-parent / still-archived-child renders as a
  clean archived root.
- **Middle list children:** `AppModel.middleKind()` filters `children(of:)` to match the
  selected node's own `state` class — an archived node shows its archived children, an active
  node shows its active children. Deterministic and handles the resurrection edge.
- **`projectCount`** (content-column header): count active root projects only.
- Smart Lists, Briefing, NodeFacts/Spotlight, Digest need **no change** (already active-only);
  resurrection restores their membership automatically.

### 4. App UI (thin, `Sources/PensieveApp/`)

- **Sidebar "Archived" section** — `SidebarView.swift`: a new
  `Section("Archived", isExpanded: $archivedExpanded)` after the "Projects" section, backed by
  `@AppStorage("sidebar.archived.expanded") = false` (collapsed by default), containing an
  `OutlineGroup(model.archivedForest, children: \.childrenIfAny)` reusing the existing
  `nodeRow`. The section renders only when `archivedForest` is non-empty.
- **Context menu** — `NodeOrganizing.swift` `NodeContextMenu`: an **Archive** button when the
  node's `state == "active"`, an **Unarchive** button when `state == "archived"`. Applies to
  both sidebar-tree and middle-list rows (both already use `NodeContextMenu`).
- **`AppModel`** — `archive(_ nodeID:)` / `unarchive(_ nodeID:)` in the organizing-writes
  section, mirroring `move`: call the Kit op via `try?`, then explicit `refresh()` (a
  state-only write does not move the Event count the `ValueObservation` tracks). On archive,
  if the archived subtree contains the current selection, move selection to a safe fallback
  (e.g. `.briefing`), mirroring how `merge`/`delete` relocate selection.
- **Localization** — add the new UI strings ("Archived", "Archive", "Unarchive") to
  `Localizable.xcstrings` with German values (impersonal/infinitive), per project convention.

### 5. Out of scope

- CLI `archive` / `unarchive` subcommands. (`pensieve list` already prints `[archived]` via
  `NodeCommands.render`, so archived nodes remain inspectable from the CLI.) Deferrable.
- `muted` state UI (the sticky variant).
- MCP context / `pensieve prime` filtering of archived nodes.
- The New/Edit modal gaining a state control — archive is a menu action, not a form field.

## Testing

PensieveKit (tested):

- `archive` sets the whole subtree to `"archived"`; a non-existent id returns `false`.
- `unarchive` restores the whole subtree to `"active"`, including a subtree with a
  mixed-state (partially resurrected) set of descendants.
- Resurrection: draining new activity onto an archived node flips **that node and its
  ancestors** to `"active"`, leaves sibling descendants archived, and leaves a `muted` node
  untouched.
- Filtering: given a mix of active/archived nodes, the active forest excludes archived and the
  archived forest contains exactly the archived nodes, re-rooted correctly when a parent is
  active and a child archived.

App (untested per convention): verify via `xcodebuild` build + non-blocking smoke-launch of
the inner binary with throwaway `PENSIEVE_DB`/`PENSIEVE_CAPTURE_DB`.

Human-verify carries (need the built app + a real store): archive/unarchive from both
sidebar and middle-list context menus; the Archived section appears, is collapsed by default,
and shows the subtree; archiving the selected node relocates selection; a fresh commit on an
archived node resurfaces it in place after the next sync; German strings in situ.
