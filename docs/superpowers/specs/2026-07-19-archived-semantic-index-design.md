# Archived content in the semantic index

**Date:** 2026-07-19
**Status:** design, approved
**Scope:** the remaining Track C fast-follow from the 2026-07-18 semantic/vector recall ship. Closes
the asymmetry the 2026-07-19 include-archived ⌘F toggle left behind.

## Problem

The `.searchScopes` "Include Archived" toggle (merged `3ece8b5`) widens **exact** ⌘F to archived
nodes and their open loose ends. Semantic "Related" cannot follow, because the semantic index holds
no archived content at all: `EmbeddableCorpus.gather` filters to `state == .active`
(`EmbeddableItem.swift:30`) and tags every loose end and event with a hardcoded `"active"`
(`:39`, `:52`).

So a user who archives a project loses semantic recall over it entirely — the exact-match half of
the same search box finds it, the "find without exact words" half does not. Archiving is meant to be
an escape hatch for stale work, not an eraser: the whole point of recall is reaching work you no
longer hold in your head.

## What ships

Archived nodes, their open loose ends, and their enriched events become part of the semantic corpus,
tagged with their real state. Two surfaces can opt into them:

- **⌘F "Related"** — gated on the existing "Include Archived" search scope, alongside exact results.
- **MCP `search`** — a new optional `include_archived` parameter, default `false`.

Archived hits carry a visible **Archived** badge in the app, in the Related section *and* in the two
exact sections (which today render archived rows indistinguishably from live work).

## Non-goals

- **Closed loose ends.** Out of the corpus everywhere else; indexing them is a different feature.
- **`muted` state.** Still deferred, still never indexed.
- **Transcript-passage chunking.** The next corpus increment, its own spec.
- **A rebuild or embedder-version bump.** See "Backfill" below — none is needed.

## Design

### Kit — corpus producer

`EmbeddableCorpus.gather` drops its active-only node filter. Every node is emitted with its own
`state`; loose ends and events are tagged with their **owning node's** state rather than a hardcoded
`"active"`. This requires keeping a `nodeID -> state` map where the code currently keeps an
`activeIDs: Set<UUID>` membership check.

Every other membership rule is unchanged and deliberately so:

- open loose ends only (`LooseEnd.isOpen`),
- the `isSearchable` / `TextQuality.isProse` gate on LLM-enriched `workSummary`,
- human-authored `summary` ungated (a short "fix ci" is real work).

One rule for all states; the state tag is the only thing that varies.

### Kit — store

`SemanticIndexStore.knn` replaces `activeOnly: Bool` with `includeArchived: Bool`, selecting
`state = 'active'` or `state IN ('active','archived')`. The SQL fragment is chosen from a bool, so
there is no injection surface and `muted` can never leak in through either branch.

### Kit — query

`SemanticQueries.search` gains a defaulted `includeArchived: Bool = false` — defaulted so every
existing call site keeps its exact current behaviour. It flows to two places:

1. `store.knn(..., includeArchived:)`, replacing today's `activeOnly: true`.
2. `resolve`'s canonical re-check, which becomes
   `state == .active || (includeArchived && state == .archived)` — the same predicate
   `SearchQueries.swift:58` already uses for exact search.

Point 2 is load-bearing: the canonical re-resolution is the grounding defense that stops a
between-sync stale index row surfacing a dead hit. It must widen in lockstep with the KNN filter, or
archived rows pass the index filter and get silently dropped on resolve.

Every other guard in `buildHits` — floor, `visibleNodeIDs`, `excludingIDs`, the canonical join — is
untouched, as is the expand-and-retry fetch loop.

`SemanticHit` gains `isArchived: Bool`, set from the state `resolve` already fetched, so the view
badges without a second lookup.

### Backfill and the archive/unarchive lifecycle

No migration, no embedder-version bump, no index rebuild. Archived items are simply new corpus
members: `SemanticIndexer.sync` sees `existing[itemID] == nil`, embeds them, upserts them. The cost
is a one-time on-device embedding pass over archived content, absorbed by the background sync agent.

The lifecycle also gets *cheaper*. Today an active→archived flip drops the item from the corpus, so
the indexer **prunes** the row and destroys the vector; unarchiving re-embeds from scratch. After
this change both directions are metadata-only state flips through the existing upsert path
(`SemanticIndexStore.swift:112-116`), which updates `node_id`/`state`/`kind` in place and keeps the
vector. Less churn than we have today, through a path that already ships and is already tested.

### App

`runSearch` already snapshots `includeArchived` into a pre-Task local for exact search; it is passed
to `SemanticQueries.search` as well. `allNodes` is genuinely every node (`ProjectQueries.all` has no
state filter), so the Focus-visible set already contains archived IDs — nothing to widen there.

`NodeHit` and `LooseEndHit` gain an `isArchived: Bool`, populated from the node state
`SearchQueries` already reads. The three row types — exact node, exact loose end, semantic Related —
render a small `.secondary` "Archived" badge when set. One new String Catalog key, hand-authored in
`en` and `de` (`xcodebuild` does not populate `.xcstrings`).

### MCP

The `search` tool gains an optional `include_archived` (default `false`). When set, `searchJSON`
widens its node set from active-only to active+archived and passes the flag to **both**
`SearchQueries` and `SemanticQueries` — so the tool's exact half gains the archived scope it does not
have today, keeping the two halves of one tool consistent.

## Trust gate

Untouched. Every surfaced item is still a real stored row, re-resolved against canonical, cited.
Vectors only rank; the embedder is on-device only; cloud is never involved. This widens *which live
rows are eligible*, and changes nothing about what may be said about them.

## Testing

Kit (`PensieveKitTests`), all deterministic:

- `gather` emits archived nodes, and tags their open loose ends and events with the owning node's
  state rather than `"active"`.
- `gather` still excludes closed loose ends and non-prose LLM output regardless of state.
- `knn` honors both filter modes; `muted` surfaces in neither.
- `SemanticQueries.search` default (no argument) excludes archived — the regression guard for every
  existing call site.
- `includeArchived: true` surfaces an archived hit, with `isArchived` set.
- An archive flip is metadata-only: the item's vector survives. Assert with an embedder stub that
  counts calls (or fails on the second) — sync, archive the node, sync again, then confirm the item
  is still returned by `knn(includeArchived: true)` with **no** re-embed. Content-hash equality is
  not sufficient evidence here: the hash covers text only, so it stays equal whether the vector
  survived or was dropped and rebuilt.
- Unarchive flips the state back and the item returns to default-scope results.

App and MCP stay thin per project convention: `xcodebuild` build plus a non-blocking smoke-launch of
the inner binary with throwaway `PENSIEVE_DB`/`PENSIEVE_CAPTURE_DB`.

**Human-verify carries** (need the built app at `/Applications` + the real store): archived work
appears under Related only with the scope toggle on; the Archived badge renders in all three row
types; German in-situ; `include_archived` through the registered `pensieve mcp`.

## Files touched

| File | Change |
|---|---|
| `Sources/PensieveKit/Semantic/EmbeddableItem.swift` | all-state corpus, per-node state tagging |
| `Sources/PensieveKit/Semantic/SemanticIndexStore.swift` | `knn(includeArchived:)` |
| `Sources/PensieveKit/Query/SemanticQueries.swift` | defaulted `includeArchived`, widened resolve predicate, `isArchived` on the hit |
| `Sources/PensieveKit/Query/SearchQueries.swift` | `isArchived` on `NodeHit` / `LooseEndHit` |
| `Sources/PensieveApp/AppModel.swift` | pass the scope through to the semantic call |
| `Sources/PensieveApp/ContentListView.swift` | Archived badge on the three row types |
| `Sources/PensieveApp/Localizable.xcstrings` | one key, `en` + `de` |
| `Sources/pensieve/Commands/Mcp.swift` | `include_archived` parameter |
| `Tests/PensieveKitTests/` | the cases above |
