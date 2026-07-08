# Three-pane IA rework — design

**Date:** 2026-07-08
**Status:** Approved (brainstorm complete; ready for a plan)
**Scope:** `Sources/PensieveApp/` (app target) + one tiny tested PensieveKit helper. No trust-gate, capture-path, ingest, or schema changes.
**Backlog item:** "App UX & IA polish carries — 2026-07-07", item 5 (the three-pane IA rework), flagged there as its own brainstorm→spec.

## Problem

Selecting a node in the sidebar tree today sets **both** `sidebarSelection = .node(id)` **and**
`selectedNodeID = id` (`SidebarView.swift:17`). That drives:

- **Middle** (`AppModel.nodesForSelection()`, `.node` case, `AppModel.swift:287–289`): returns
  `[selected] + directChildren` — the node **plus** its children.
- **Detail** (`RootView.detailColumn`): the same node's recall.

So a strand-less project appears **three times** — sidebar row → middle row → detail recall — and even a
project *with* strands is redundantly the first middle row. Loose ends live only in the detail's
"Loose Ends" section, so a leaf project's real content (its loose ends) is buried on the right while the
middle column just repeats the node.

A reality check from the 1B-org design informs the fix: when strands auto-birth, events **and their loose
ends** repoint to the strand. So a project *with* strands typically holds few/no direct loose ends (they've
moved into the strands), while a **leaf** project holds its own. The "children *or* loose ends" split below
therefore matches real data — it is not a false either/or.

## Goals

1. Kill the sidebar→middle→detail self-duplication: the middle lists a node's **children**, never the node
   itself.
2. Give a **leaf** node a useful middle column: its **loose ends** (its real content) as a worklist.
3. Keep every node presenting **identically** however you reached it, and keep the loose-end→provenance
   interaction **identical** wherever a loose end is listed.
4. Preserve the fast top-to-bottom **triage** of the Smart Lists / Briefing (do not replace those lists on
   click).

## Non-goals

- No change to Briefing / Smart List **content** or ranking (they already show a flat project list with no
  duplication). Only the *tree-node* middle behavior changes.
- No new provenance surface: the existing ⌘⌥I inspector stays as the single home for surrounding-transcript
  provenance.
- No PensieveKit query restructuring; no `BriefingQueries`/`SmartLists`/`LooseEndQueries` changes beyond
  consuming them from the new middle. No trust-gate / capture-path involvement.

## The model — a "focused node" for tree navigation; entry-point lists unchanged

The middle pane's content is driven by `sidebarSelection`; the detail pane always shows the recall of
`selectedNodeID` (or the Briefing world-map / a hint when nothing is selected). Provenance lives in the
inspector, so the detail pane is *never* swapped to provenance — which means no new `detailTarget` state is
needed; `selectedNodeID` remains "the node the detail shows."

| `sidebarSelection` | Middle pane | Detail pane (default) |
|---|---|---|
| `.briefing` | Briefing cards (unchanged) | Briefing world-map (unchanged) |
| `.smartList(k)` | That list's projects (unchanged) | Hint → clicked project's **full recall** |
| `.node(id)` (focused) | Its **children** if any, else its **loose ends** | The focused node's recall |

## Interactions

- **Select a tree node** (sidebar) → focus it: middle = its contents, detail = its recall.
- **Click a child node in the middle** (tree mode) → **drill**: it becomes the focused node
  (`sidebarSelection` **and** `selectedNodeID` both move to it), so the middle re-populates with *its*
  contents and the detail shows *its* recall. The sidebar highlight follows (if the row is visible; a
  collapsed `OutlineGroup` parent is not force-expanded — accepted, see Edge cases).
- **Click a project in a Smart List / Briefing card** → detail = its **full recall**; the middle list
  **stays** (Goal 4). Only `selectedNodeID` changes; `sidebarSelection` is untouched.
- **Click a loose end anywhere** — in the middle worklist (tree-leaf) *or* in the detail recall's Loose Ends
  section (smart-list / parent / recall-window paths) — updates the inspector's target
  (`inspectedLooseEndID`); ⌘⌥I reveals the surrounding transcript. **Identical everywhere.** The loose-end
  row's inline disclosure (verbatim quote + role + age) is unchanged; the inspector shows the transcript.

To return from a drilled child to its siblings, click the parent in the sidebar (always visible). Trees are
typically two levels (project → strands), so drilling is shallow.

## The one-home rule (no loose-end duplication)

The detail recall shows its **Loose Ends** section **except** when the detail node *is* the focused leaf —
i.e. when the middle is already showing that same node's loose ends. Concretely, in `RootView`:

```
showsLooseEnds = !(sidebarSelection == .node(fid)
                   && selectedNodeID == fid
                   && children(of: fid).isEmpty)
```

- Focused **leaf** → loose ends in the middle; detail recall omits them. No duplication.
- Focused **parent** (has children) → middle shows children; detail keeps its Loose Ends section. This also
  surfaces the edge case of a parent with *its own* direct loose ends (rare post-strand-birth) — they show in
  the detail, with no duplication.
- **Smart-list / Briefing detail** and **recall windows** (⌘⌥N) always pass `showsLooseEnds = true` (no
  middle pane to move loose ends to).

## State & component changes

All in `Sources/PensieveApp/` unless noted.

**`AppModel`**
- **Keep** `selectedNodeID`, `sidebarSelection`, and all inspector state (`showInspector`,
  `inspectedLooseEndID`, and the `selectedNodeID.didSet` that clears `inspectedLooseEndID`). The inspector is
  **not** retired.
- **Add** `func middleContent() -> MiddleContent` where
  `enum MiddleContent { case nodes([Node]); case looseEnds([LooseEndView]) }`:
  - `.briefing` → `.nodes(briefingCards.map(\.node))`
  - `.smartList(k)` → `.nodes(lists[keyPath: k.itemsKeyPath].map(\.project))`
  - `.node(id)` → children (via the new Kit helper) if non-empty → `.nodes(children)`, else
    `.looseEnds(looseEnds(forNode: id))` — reusing the existing `looseEnds(forNode:) -> [LooseEndView]`
    method (`AppModel.swift:313`, backed by `LooseEndQueries.open`).
  - `nil` → `.nodes([])`
- **Add** `func selectMiddleNode(_ id: UUID)`: if `sidebarSelection` is `.node` → drill
  (`sidebarSelection = .node(id); selectedNodeID = id`); else detail-only (`selectedNodeID = id`).
- **Add** `func selectMiddleLooseEnd(_ id: UUID)`: `inspectedLooseEndID = id` (inspector visibility stays
  user-controlled via ⌘⌥I, matching today's detail-row behavior — clicking selects, ⌘⌥I reveals).
- **Remove/replace** the old `nodesForSelection()` (superseded by `middleContent()`).
- `children(of:)` convenience wrapping the Kit helper over `allNodes` (for `middleContent` + the
  `showsLooseEnds` computation).

**`ContentListView`** — switch on `model.middleContent()`:
- `.nodes(items)` → today's node rows (badge + name + kind), tap → `model.selectMiddleNode(id)`, context menu
  unchanged. Empty → `ContentUnavailableView`.
- `.looseEnds(views)` → a loose-end list reusing a **shared row view** extracted from `DetailView.looseEndRow`
  (inline disclosure: text → quote + role + age), tap → `model.selectMiddleLooseEnd(id)`. Empty → "None open."
- Middle title: in tree mode, the focused node's name + a subtitle count ("N strands" / "N loose ends");
  smart-list/briefing keep their existing titles.

**`DetailView`** — add `var showsLooseEnds: Bool = true`; render the Loose Ends section only when true. Extract
`looseEndRow` into a shared `LooseEndRow` view (used by both `DetailView` and `ContentListView`) so the row
looks and behaves identically in both columns and both keep writing `inspectedLooseEndID` through the model.

**`RootView`** — compute `showsLooseEnds` per the one-home rule and pass it to the main-window `DetailView`.
The `.inspector`, the Go ▸ Inspector command, and the toolbar Inspector button all stay.

**`SidebarView`** — unchanged selection logic (it already sets both `sidebarSelection` and `selectedNodeID`
for a tree node). No change required beyond confirming the drill path composes with it.

**`RecallWindowView`** — pass `showsLooseEnds: true` (standalone recall, no middle pane).

**PensieveKit (tested)** — add one pure helper mirroring `descendantIDs`:

```swift
/// Direct children of `id` within `nodes`, name-sorted. Pure, deterministic.
public static func children(of id: UUID, in nodes: [Node]) -> [Node] {
  nodes.filter { $0.parentID == id }.sorted { $0.name < $1.name }
}
```

Everything else reuses existing tested queries (`LooseEndQueries.open`, `ProvenanceQueries.context`,
`SmartLists`, `BriefingQueries`).

## Edge cases

- **Leaf with zero loose ends** → middle shows the "None open." empty state; detail = recall without a Loose
  Ends section.
- **Parent with its own direct loose ends** → middle shows children; those loose ends appear in the detail's
  Loose Ends section (one-home rule).
- **Drilled child under a collapsed sidebar parent** → the sidebar highlight may not auto-reveal
  (`OutlineGroup` can't be force-expanded — a known constraint from slice 4). Harmless: the middle + detail
  are correct; the sidebar simply doesn't scroll/expand to it. Accepted.
- **Smart-list / Briefing before any click** → `selectedNodeID == nil` → detail shows the existing hint /
  Briefing world-map. Unchanged.
- **`merge`/`delete`/`move` selection fix-ups** — existing `AppModel` write handlers already move
  `selectedNodeID`/`sidebarSelection` off a deleted/merged node; they compose unchanged (still valid under the
  new middle, which reads from `sidebarSelection`).

## Testing & verification

- **PensieveKit:** unit tests for `NodeForest.children(of:in:)` — children returned name-sorted; only *direct*
  children (not descendants); empty for a leaf and for an unknown id; ignores a child whose parent is absent
  from the set.
- **App target (no unit tests, per project convention):** `xcodebuild` build, then a **non-blocking**
  smoke-launch of the inner binary with throwaway `PENSIEVE_DB`/`PENSIEVE_CAPTURE_DB`, then human eyeball of
  the flows below (needs the built app + real store + plain `open`):
  - A strand-less project selected in the sidebar → it does **not** appear in the middle; middle shows its
    loose ends; detail shows its recall without a duplicated Loose Ends section.
  - A project with strands → middle lists the strands (not the project); detail shows the project recall;
    clicking a strand **drills** (middle → its loose ends, detail → its recall).
  - What's Next / Briefing → clicking a project shows its recall in the detail and the **list stays**.
  - Clicking a loose end in the middle worklist and clicking one in a smart-list detail recall both drive the
    **same** ⌘⌥I inspector transcript.
  - ⌘⌥N recall window still shows a node's loose ends (no middle pane).
  - `pensieve list` still matches the tree after any organizing write.
  - German renders in situ (`-AppleLanguages '(de)'`) for the new middle title/subtitle + "N strands"/
    "N loose ends" counts.

Build: `xcodegen generate && xcodebuild -project Pensieve.xcodeproj -scheme Pensieve -configuration Debug
-derivedDataPath ./.build-xcode build`, then `open ./.build-xcode/Build/Products/Debug/Pensieve.app`.

## Localization

New chrome strings (middle title/subtitle, "%lld strands", "%lld loose ends") go through
`String(localized:)`/`LocalizedStringResource` and are added to `Localizable.xcstrings` (English base + German
`de`) **by hand** — `xcodebuild` does not auto-populate the catalog. Node names, loose-end text, quotes, and
transcript content are **never** localized (captured content).

## Out of scope / deferred

- The "shared per-node latest-event + days-dormant + open-loose-end-count helper" carry (recurs in
  `NextQueries`/`MonitorSnapshot`/`BriefingQueries`) — not required here; revisit on its own trigger.
- `AppModel` → `@Observable` migration (broad, untested-target rewrite) — deferred per the 2026-07-07
  code-quality carries.
- Any breadcrumb / explicit "up" control in the middle beyond the focused-node title — sidebar navigation
  suffices for the shallow trees in practice; revisit if trees deepen.
