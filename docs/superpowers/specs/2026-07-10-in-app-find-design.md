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
- **⌘K fate:** repurpose the keyboard entry point. Wire the native **⌘F** to focus the search
  field, and repoint the existing ⌘K binding at the same action, dropping the palette popover +
  its `AppModel` state.
- **Corpus (grounded core set):** node `name` + `description`, loose-end `text`, loose-end
  `quote`. Every hit traces to real captured text. (Activity/narration wait for #2.)
- **Results & landing:**
  - While a search is active, the **content (middle) column** shows grouped results in place of
    the focused-node's normal list: a **Nodes** section and a **Loose ends** section, each row
    showing the node name + a **matched snippet with the query highlighted**. Clearing the field
    restores the normal list.
  - Selecting a **node** result → detail shows that node's recall.
  - Selecting a **loose-end** result → detail shows its node's recall with that **loose-end row
    auto-expanded** (the existing inline provenance box), landing on the cited line.
  - **Scope:** whole tree by default (true "find anything"), filtered to the active Focus
    context via `NodeContextResolver.visibleNodeIDs`.

## Architecture

One tested PensieveKit kernel + a thin app view. Mirrors `NextQueries` / `BriefingQueries`.

### Kit: `Sources/PensieveKit/Query/SearchQueries.swift`

```
public enum SearchQueries {
  public static func search(query: String,
                            visibleNodeIDs: Set<UUID>,
                            _ db: Database) throws -> SearchResults
}

public struct SearchResults: Equatable, Sendable {
  public var nodes: [NodeHit]
  public var looseEnds: [LooseEndHit]
}

public struct NodeHit: Identifiable, Equatable, Sendable {
  public let id: UUID          // node id
  public var name: String
  public var snippet: Snippet  // from name or description, whichever matched
}

public struct LooseEndHit: Identifiable, Equatable, Sendable {
  public let id: UUID          // loose-end id (the row to auto-expand)
  public var nodeID: UUID
  public var nodeName: String
  public var snippet: Snippet  // from text or quote, whichever matched
}
```

- **Read-only**, pure over its inputs → fully unit-testable, no SwiftUI/LLM.
- The caller supplies `visibleNodeIDs` (computed from the active context), so Focus filtering is
  correct by construction — the kernel never needs to know about Focus.
- Uses SQLiteData predicates (`.eq`/`.neq`, per repo convention). Loose ends are filtered by the
  shared `LooseEnd.isOpen` predicate (open + not user-labeled noise) so resolved/noise items
  never surface.

### Kit: `Sources/PensieveKit/Query/Snippet.swift` (pure helper)

```
public struct Snippet: Equatable, Sendable {
  public var text: String         // possibly windowed around the match
  public var highlight: Range<String.Index>?  // range of the match within `text`
}

public enum SnippetMaker {
  public static func make(from source: String, matching query: String,
                          window: Int = 80) -> Snippet
}
```

- Case-insensitive first-occurrence match; windows a long source around the match so rows stay
  compact; returns the highlight range for the view to style. Unicode/emoji-safe (operates on
  `String.Index`, never byte offsets).

### Matching & ranking (in `SearchQueries`)

- **Case-insensitive substring** match (`range(of:options:.caseInsensitive)`), **not FTS5** — the
  corpus is single-user and small; an in-memory scan / `LIKE` is instant and needs no migration or
  sync triggers. FTS5/vectors belong to #2.
- **Minimum query length 2**; a blank/1-char (or whitespace-only) query returns empty results
  (the view then shows the normal list).
- **Ranking:**
  - **Nodes** section first, then **Loose ends**.
  - Nodes: name-match before description-only match, then by `name`.
  - Loose ends: `text`-match before `quote`-only match, then most-recent `createdAt`.
- **Per-section cap** of 50, with the total match count available for a "showing N of M" affordance.

### App (thin): `Sources/PensieveApp/`

- `AppModel`:
  - `@Published var searchText: String` (bound to `.searchable`).
  - `@Published var searchResults: SearchResults` (empty by default).
  - `@Published var expandedLooseEndID: UUID?` (set when a loose-end hit is chosen; cleared on
    node change). Today `LooseEndRow` owns its expand as local `@State private var expanded`, so
    this feature threads `expandedLooseEndID` through `DetailView` into `LooseEndRow`, which seeds
    `expanded = (view.id == expandedLooseEndID)` on appear. Minimal change: the row keeps its own
    toggle; it just starts open when it's the selected hit.
  - On `searchText` change: cancel any in-flight search `Task`; if the trimmed length ≥ 2, spawn a
    `Task` that awaits `SearchQueries.search(...)` **off-main** (the kernel is `Sendable`; same
    off-main discipline as `SummaryBuilder.narrate`), then assigns `searchResults` on the main
    actor **guarded by a token / `Task.isCancelled`** so a slow query for a stale keystroke can't
    overwrite a newer result.
  - Recomputes on the debounced `ValueObservation` refresh too (a background drain that resolves a
    loose end updates a live search).
  - Removes the ⌘K palette state (`showPalette` / quick-jump destination) and its command.
- `ContentListView`: branches on `searchText` — non-empty → grouped results view (Nodes / Loose
  ends, snippet + highlight, empty state); empty → the existing focused-node list. Selecting a
  result sets `selectedNodeID` (+ `expandedLooseEndID` for a loose-end hit).
- Commands: a **Find** command (`⌘F`) focusing the search field; the old ⌘K binding repointed to
  the same action; `Go ▸ Quick Jump` removed/renamed to `Edit ▸ Find` (⌘F) per macOS convention.
- **German l10n** for the new chrome (section headers "Nodes"/"Loose ends", "No results for '…'",
  the Find menu item). Node names, loose-end text, and quotes are **content — never localized**.

## Data flow

1. `.searchable(text: $model.searchText)` on the content column; ⌘F / repointed-⌘K focus it.
2. `searchText` change → cancel in-flight → (len ≥ 2) run `SearchQueries.search` off-main → assign
   `searchResults` on main, stale-guarded.
3. `ContentListView` renders grouped results while `searchText` non-empty; else the normal list.
4. Select node hit → `selectedNodeID`; select loose-end hit → `selectedNodeID` + `expandedLooseEndID`.
5. Debounced liveness refresh re-runs the active search (cheap in-memory scan).
6. Focus filter: `visibleNodeIDs` recomputed from the active context → muted-context hits excluded.

## Error handling / edge cases

- **DB read failure** → empty results, no crash (a search surface must never break the app — same
  posture as `SpotlightIndexer`).
- **No matches** → native empty state in the content column ("No results for '…'").
- **Loose-end hit whose node is Focus-muted** → excluded up front via the visible set.
- **Select a loose-end hit then clear search** → selection persists on the node; normal list
  returns; `expandedLooseEndID` cleared on node change.
- **Whitespace-only query** → treated as empty.

## Testing

PensieveKit unit tests (app target has none — all logic lives in Kit):

- `SearchQueries`:
  - node name match vs description-only match;
  - loose-end `text` match vs `quote`-only match;
  - open/non-noise filter (a resolved or noise loose end never appears);
  - Focus-visibility exclusion (a hit outside `visibleNodeIDs` is dropped);
  - ranking order (nodes-before-loose-ends; name-before-description; text-before-quote; recency);
  - per-section cap;
  - min-length short-circuit (0/1/whitespace → empty);
  - case-insensitivity;
  - empty-db → empty results.
- `SnippetMaker`: match at start / middle / end; first-of-multiple occurrences; no-match fallback
  (returns source, nil highlight); highlight-range correctness; long-source windowing;
  unicode/emoji offset safety.

App verification (manual, per repo policy — build + non-blocking smoke-launch of the inner binary
with throwaway `PENSIEVE_DB`/`PENSIEVE_CAPTURE_DB`): type a phrase from a known loose end → it
appears under **Loose ends** → selecting it opens the node with that row expanded; a node-name
phrase appears under **Nodes**; the Focus filter hides muted-context hits; clearing restores the
list; ⌘F focuses the field; German renders in situ (`-AppleLanguages '(de)'`) with content
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
