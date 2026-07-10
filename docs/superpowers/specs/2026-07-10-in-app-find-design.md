# In-app find (search captured content) — design

**Date:** 2026-07-10
**Status:** approved (brainstorm complete), ready for plan
**Track:** C (deeper Spotlight / semantic search), sub-project **1a**

## Context

Pensieve's job is to reload context on parallel projects. Today three "search-ish"
surfaces exist and none searches *captured content*:

- **Spotlight** (OS) indexes **nodes only** — `NodeEntity` exposes name + `description`
  (`Sources/PensieveApp/AppIntents/NodeEntity.swift`, `SpotlightIndexer.swift`).
- **⌘K palette** — navigation-only; jumps to a node/smart-list *by name*, no content search.
- **MCP feeds** (`project_context` / `whats_next`) — grounded context into Claude Code.

The standing loose end — *"I'd like to get both the remaining text in, and also investigate
using sqlite-vector to enable proper vector search"* — bundles a **findability quick win**
with a **semantic-recall research bet**. This spec is scoped to the first, delivered in-app.

### Decomposition (agreed during brainstorm)

Track C splits into two independently-specced/shipped features:

1. **Findability** — get captured text into a search surface.
   - **1a — in-app find (THIS SPEC).** A native `.searchable` field over the grounded core
     corpus, jumping to the hit.
   - **1b — Spotlight loose-end indexing (LATER).** Extend the OS index; its own spec.
2. **Semantic recall (LATER).** On-device embeddings + vector store (`sqlite-vec` /
   `NLContextualEmbedding` / Foundation Models) with the grounding caveat solved. Reuses this
   feature's corpus. Its own spec.

Live/background re-indexing — the third item originally lumped into Track C — **already ships**
via the debounced `ValueObservation` refresh (slice-3b liveness); no new work.

## Goal

A native in-app search that finds any node or open loose end by a phrase from its text or its
cited quote, and lands you on the exact item — honoring the active Focus filter and the
grounded-with-provenance north star.

## Non-goals

- FTS5 / `sqlite-vec` / embeddings / semantic matching (that is sub-project #2).
- Searching event `summary` / `workSummary` or the cached LLM narration (deferred to #2; noisier
  and — for narration — un-cited).
- Spotlight/OS-level indexing of loose-end text (sub-project 1b).
- Any new capture, schema, or migration. This is a **read-only query** over existing tables.

## UX decisions (locked in brainstorm)

- **Surface:** the first-party **`.searchable`** toolbar field on the three-pane
  `NavigationSplitView` — *not* a ⌘K-style overlay (a popover that competes with Spotlight is a
  non-native anti-pattern here).
- **⌘K fate:** repurpose the keyboard entry point. Wire **⌘F** to focus the search field (via
  `searchFocused`), and repoint the existing ⌘K binding at the same action, dropping the palette
  popover.
  - **CRITICAL scoping (do not over-delete).** "Dropping the palette" removes **only**:
    `AppModel.showPalette`, `PaletteView.swift`, `AppModel.matchingNodes(_:)` (sole caller is
    `PaletteView`), the `Go ▸ Quick Jump` command, and the `"Quick Jump…"` String Catalog key.
    **`PaletteDestination` (enum + `init(_ DeepLink)` + `.apply(to:)`) and `DeepLinkNavigation` /
    `applyDeepLink` are RETAINED UNTOUCHED** — despite the "quick-jump destination" name, they are
    the shared navigation-apply core for `pensieve://` deep links, App Intents `perform()`, and
    the menu-bar popover (`DeepLinkNavigation.swift`, `AppDelegate` → `pendingDeepLink` →
    `MenuBarView`). Deleting the enum breaks the entire live OS-integration surface.
- **Corpus (grounded core set):** node `name` + `description`, loose-end `text`, loose-end
  `quote`. Every hit traces to real captured text. (Activity/narration wait for #2.)
- **Results & landing:**
  - While a search is active, the **content (middle) column** shows grouped results in place of
    the focused-node's normal list: a **Projects** section (node hits — each row carries its kind
    badge, so a strand/topic/etc. reads correctly) and a **Loose ends** section, each row showing
    the node name + a **matched snippet with the query highlighted**. Clearing the field restores
    the normal list. Rows use per-row tap handlers, **not** a single `List(selection:)` — a node
    hit and a loose-end hit can share the same node id, which `List` selection can't disambiguate.
    (The `.searchable` field renders in the window-unified toolbar; only the *results list* is the
    content-column branch.)
  - Selecting a **node** result → sets `sidebarSelection = .node(id)` (so clearing search leaves a
    coherent middle list) and detail shows that node's recall.
  - Selecting a **loose-end** result → sets node selection **and** `expandedLooseEndID`; detail is
    forced to show the Loose Ends section (overriding the one-home rule — see §App) with that
    **row auto-expanded** and **scrolled into view** (`ScrollViewReader`), landing on the cited
    line.
  - Selecting a sidebar row (normal navigation) **clears `searchText`**, exiting search mode so
    stale results don't linger.
  - **Scope:** whole tree by default (true "find anything"), filtered to the active Focus
    context via `NodeContextResolver.visibleNodeIDs`.

## Architecture

One tested PensieveKit kernel + a thin app view. Mirrors `NextQueries` / `BriefingQueries`.

### Kit: `Sources/PensieveKit/Query/SearchQueries.swift`

```
public enum SearchQueries {
  // Takes `any DatabaseReader` and owns its `db.read {}` — matches every sibling kernel
  // (NextQueries/LooseEndQueries/ProvenanceQueries) and keeps the read runnable off-main on a
  // DatabasePool (concurrent async reads are the real enabler, not Sendability of a result).
  public static func search(query: String,
                            visibleNodeIDs: Set<UUID>,
                            _ db: any DatabaseReader) throws -> SearchResults
}

public struct SearchResults: Equatable, Sendable {
  public var nodes: [NodeHit]
  public var looseEnds: [LooseEndHit]
  public var totalNodeMatches: Int      // pre-cap count, for a "showing N of M" affordance
  public var totalLooseEndMatches: Int
}

public struct NodeHit: Identifiable, Equatable, Sendable {
  public let id: UUID          // node id
  public var name: String
  public var kind: String      // for the row's kind badge
  public var snippet: Snippet  // from name or description, whichever matched
}

public struct LooseEndHit: Identifiable, Equatable, Sendable {
  public let id: UUID          // loose-end id (the row to auto-expand)
  public var nodeID: UUID
  public var nodeName: String
  public var snippet: Snippet  // from text or quote, whichever matched
}
```

- **Read-only**, wraps `db.read { db in … }` internally → fully unit-testable, no SwiftUI/LLM.
- The off-main precedent is **`AppModel.provenance(for:)`** (a `db.read` off the main actor over
  the shared `DatabasePool`), **not** `SummaryBuilder.narrate` (which touches no DB).
- The caller supplies `visibleNodeIDs` (computed from the active context), so Focus filtering is
  correct by construction — the kernel never needs to know about Focus.
- Uses SQLiteData predicates (`.eq`/`.neq`, per repo convention). Loose ends are filtered by the
  shared `LooseEnd.isOpen` predicate (open + not user-labeled noise) so resolved/noise items
  never surface.

### Kit: `Sources/PensieveKit/Query/Snippet.swift` (pure helper)

```
public struct Snippet: Equatable, Sendable {
  public var leading: String   // text before the match (may start with "…" if windowed)
  public var match: String     // the matched substring, original case (empty if no match)
  public var trailing: String  // text after the match (may end with "…" if windowed)
}

public enum SnippetMaker {
  public static func make(from source: String, matching query: String,
                          window: Int = 80) -> Snippet
}
```

- A **`(leading, match, trailing)` triple**, not a `Range<String.Index>`. The view renders three
  `Text` runs (`Text(leading) + Text(match).bold()/.background + Text(trailing)`) with **zero**
  index conversion — sidestepping `String.Index`↔`AttributedString.Index` fragility and grapheme
  offset bugs, and making it trivially `Equatable`/`Sendable` and cheap to assert in tests.
- Case-insensitive first-occurrence match (`range(of:options:.caseInsensitive)`); **windows the
  source first, then splits** so the three parts always concatenate to the shown text and
  `match` is exactly the matched substring. Unicode/emoji-safe (splits on `String.Index`, never
  byte offsets). No match → `leading = source`, `match = ""`, `trailing = ""`.

### Matching & ranking (in `SearchQueries`)

- **Case-insensitive substring** match (`localizedCaseInsensitiveContains` / `range(of:options:
  .caseInsensitive)`), **not FTS5** — the corpus is single-user and small; loading candidate rows
  and matching in Swift is instant and needs no migration or sync triggers (Swift-side matching is
  also more correct for non-ASCII than SQL `LIKE`). FTS5/vectors belong to #2.
- **Minimum query length 2** measured in **graphemes** (`trimmed.count`, not `.utf16.count`, so a
  single emoji is correctly rejected); a blank/1-grapheme/whitespace-only query returns empty
  results (the view then shows the normal list).
- **Ranking (fully deterministic — every sort has a total final tiebreaker on `id.uuidString`,
  because Swift's `sorted(by:)` is not guaranteed stable and node names / batch `createdAt` values
  collide in practice):**
  - **Nodes** section first, then **Loose ends**.
  - Nodes: name-match before description-only match, then by `name`, then `id.uuidString`.
  - Loose ends: `text`-match before `quote`-only match, then most-recent `createdAt`, then
    `id.uuidString`.
- **Per-section cap** of 50 applied as `prefix(50)` **after** sorting (never truncates a high-rank
  hit); `totalNodeMatches`/`totalLooseEndMatches` carry the **pre-cap** counts for "showing N of M".

### App (thin): `Sources/PensieveApp/`

- `AppModel`:
  - `@Published var searchText: String` (bound to `.searchable`).
  - `@Published var searchResults: SearchResults` (empty by default).
  - `@Published var expandedLooseEndID: UUID?` — set when a loose-end hit is chosen; **cleared in
    the same setter path that changes `selectedNodeID`** (and on `searchText` → empty), so it never
    mis-seeds a row after navigating between hits. Today `LooseEndRow` owns its expand as local
    `@State private var expanded`; this feature passes `expandedLooseEndID` down and the row reacts
    via **`.onChange(of: expandedLooseEndID)`** (setting `expanded = true` when it equals `view.id`)
    — **not** an `onAppear` seed, which fires once and would miss a second hit on an already-mounted
    row in the same node. `LooseEndRow` gains the parameter with a **default** so its two unrelated
    call sites in `ContentListView` compile untouched.
  - **`runSearch()` funnel** — the single entry point for every search trigger (keystroke *and*
    liveness). It captures the shared `DatabaseWriter`/pool, cancels the prior search `Task`, and
    (trimmed grapheme length ≥ 2) spawns a `Task.detached`-style read `try await db.read { db in
    SearchQueries.search(query:visibleNodeIDs:db) }` off the main actor (mirrors
    `AppModel.provenance(for:)`), then assigns `searchResults` on the main actor **guarded by a
    monotonic token / `Task.isCancelled`** so a stale keystroke can't overwrite a newer result.
    `visibleNodeIDs` is recomputed from the in-model `allNodes` + active Focus context (same call
    `refresh()` already makes).
  - **Liveness:** the debounced `ValueObservation` refresh calls `runSearch()` (NOT an inline
    synchronous `SearchQueries.search` — `refresh()` is a synchronous `@MainActor` method and must
    not block on a DB scan). Both paths share the one cancel token, so they can't race; the
    `searchText` field is never mutated by `refresh()`, so no keystroke loss. Results may reorder
    mid-scan on heavy activity — acceptable; a tiny keystroke debounce is optional, not required.
  - Removes **only** `showPalette` + `matchingNodes(_:)`; **retains `PaletteDestination` /
    `applyDeepLink` / `DeepLinkNavigation`** (see the CRITICAL scoping note above).
- `ContentListView`: branches on `searchText` — non-empty → grouped results view (Projects / Loose
  ends, snippet triple, kind badges, native empty state); empty → the existing focused-node list.
  Per-row tap sets `selectedNodeID` + `sidebarSelection = .node(id)` (node hit) or additionally
  `expandedLooseEndID` (loose-end hit).
- `DetailView`: gains an override so a loose-end hit shows Loose Ends even when the one-home rule
  (`detailShowsLooseEnds == false`, i.e. the node is a focused childless leaf) would hide them —
  e.g. `showsLooseEnds: model.detailShowsLooseEnds || model.expandedLooseEndID != nil`. Wraps the
  loose-end list in a `ScrollViewReader` and scrolls to `expandedLooseEndID` on change.
- `RootView`: `.searchable(text: $model.searchText)` + `.searchFocused($isSearchFocused)`.
- Commands: a **Find** command bound to **⌘F** (`CommandGroup(after: .textEditing)`) that sets
  `isSearchFocused = true`; the old ⌘K binding repointed to the same action; `Go ▸ Quick Jump`
  removed. Verify at build there is no duplicate ⌘F binding from a system-provided Find.
- **Orphan cleanup** (per repo policy): delete `AppModel.matchingNodes(_:)` and the `"Quick Jump…"`
  String Catalog key alongside `PaletteView`.
- **German l10n** for the new chrome (section headers "Projects"/"Loose ends", "No results for
  '…'", the Find menu item). Node names, loose-end text, and quotes are **content — never
  localized**.

## Data flow

1. `.searchable(text: $model.searchText)` + `.searchFocused($isSearchFocused)` on `RootView`; the
   ⌘F Find command (and repointed ⌘K) set `isSearchFocused = true`.
2. `.onChange(of: model.searchText)` → `model.runSearch()` → cancel in-flight → (grapheme len ≥ 2)
   `try await db.read { SearchQueries.search(...) }` off-main → assign `searchResults` on main,
   token-guarded.
3. `ContentListView` renders grouped results while `searchText` non-empty; else the normal list.
4. Select node hit → `selectedNodeID` + `sidebarSelection = .node(id)`; select loose-end hit →
   the above + `expandedLooseEndID` (+ detail forces Loose Ends + scrolls to it).
5. Debounced liveness refresh calls the same `runSearch()` (shared cancel token; no main-actor
   block).
6. Focus filter: `visibleNodeIDs` recomputed from the active context → muted-context hits excluded.
7. Selecting a sidebar row clears `searchText` (exits search mode).

## Error handling / edge cases

- **DB read failure** → empty results, no crash (a search surface must never break the app — same
  posture as `SpotlightIndexer`).
- **No matches** → native empty state in the content column ("No results for '…'").
- **Detail column while searching with nothing selected** → retains existing `RootView`
  behavior (Briefing or "Select a project"); search results live in the content column, so no
  special-casing needed.
- **Loose-end hit on the focused childless leaf** (the one-home rule normally hides detail's Loose
  Ends) → the `expandedLooseEndID != nil` override forces the section on, so the hit always lands.
- **Second loose-end hit in the same node** → `.onChange(of: expandedLooseEndID)` re-expands the
  new row (an `onAppear` seed would not).
- **Loose-end hit whose node is Focus-muted** → excluded up front via the visible set.
- **Node deleted by a background drain mid-search** → the token-guarded `runSearch()` re-run drops
  it from results; a tap on an already-gone id resolves to no node and no-ops (existing lookup
  returns nil).
- **Select a loose-end hit then clear search** → selection persists on the node; normal list
  returns; `expandedLooseEndID` cleared when `searchText` empties / node changes.
- **Whitespace-only or 1-grapheme query** → treated as empty.

## Testing

PensieveKit unit tests (app target has none — all logic lives in Kit):

- `SearchQueries`:
  - node name match vs description-only match;
  - loose-end `text` match vs `quote`-only match;
  - open/non-noise filter (a resolved or noise loose end never appears);
  - Focus-visibility exclusion (a hit outside `visibleNodeIDs` is dropped);
  - ranking order (nodes-before-loose-ends; name-before-description; text-before-quote; recency);
  - **deterministic tiebreak** — two nodes with identical names, and two loose ends with identical
    `createdAt`, sort by `id.uuidString` in a fixed order across runs;
  - per-section cap = `prefix(50)` after sort, with `total*Matches` = pre-cap counts;
  - min-length short-circuit (0/1-grapheme/whitespace → empty), grapheme-counted (a 1-emoji query
    is rejected);
  - case-insensitivity;
  - empty-db → empty results.
- `SnippetMaker`: match at start / middle / end; first-of-multiple occurrences; no-match fallback
  (`leading == source`, `match == ""`); **`leading + match + trailing` round-trips** to the shown
  text and `match` equals the matched substring; long-source windowing (leading/trailing ellipsis)
  with the split still exact; unicode/emoji safety (a match adjacent to a multi-scalar grapheme
  splits on grapheme boundaries).

App verification (manual, per repo policy — build + non-blocking smoke-launch of the inner binary
with throwaway `PENSIEVE_DB`/`PENSIEVE_CAPTURE_DB`): type a phrase from a known loose end → it
appears under **Loose ends** → selecting it opens the node with that row expanded **and scrolled
into view** (incl. a second hit in the same node, and a hit on a childless-leaf node); a node-name
phrase appears under **Projects**; the Focus filter hides muted-context hits; clearing restores the
list and selecting a sidebar row exits search; ⌘F focuses the field (no double-bound Find); a
`pensieve://` deep link / menu-bar jump / Siri "Open Node" still navigates (regression check for
the retained `PaletteDestination`); German renders in situ (`-AppleLanguages '(de)'`) with content
un-translated.

## Out of scope / deferred

- FTS5, `sqlite-vec`, embeddings, semantic matching → **sub-project #2**.
- Event/narration corpus → **#2**.
- Spotlight loose-end indexing → **sub-project 1b** (own spec).
- Search-result highlighting inside the detail recap; saved searches; search scopes UI.

## Process

Design-first, subagent-driven per `CONTINUE.md`: writing-plans → isolated worktree → per-task
Sonnet impl + review → Opus whole-branch review → finish-branch merge. Kit logic tested; app views
thin and manually smoke-verified.
