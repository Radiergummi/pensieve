# Semantic-recall hardening + include-archived search — Design

**Date:** 2026-07-19
**Track:** C (findability / OS-integration) — deferred fast-follows
**Status:** approved, ready for plan

## Summary

Four small, independent changes to the shipped semantic-recall stack (merged `e640645`,
2026-07-18): three invisible robustness fixes plus one user-facing search-scope toggle. No new
subsystems. All changes land in `SemanticQueries`, `SemanticIndexStore`, `SearchQueries`, one MCP
hoist, and one app toggle. **The trust gate is untouched** — this is all retrieval plumbing; the
corpus, grounding predicates, and on-device-only rule are unchanged.

The four items were selected from the semantic-recall whole-branch-review deferred ledger + the
in-app-find deferred siblings:

- **A — Include-archived toggle (⌘F)** — *user-facing.*
- **B — Idempotent rebuild guard** on embedder-version/dimension bump — *invisible.*
- **C — MCP embedder/store caching** across calls — *invisible.*
- **D — Expand-and-retry under heavy Focus-muting** — *invisible.*

## Current state (as built)

- `SearchQueries.search(query:visibleNodeIDs:_:)` — exact substring find over the grounded corpus
  (node name/description, open loose-end text/quote). Hard-filters nodes to `state == .active` and
  loose ends to active-visible node membership.
- `SemanticQueries.search(query:visibleNodeIDs:excludingIDs:k:floor:store:embedder:_:)` — KNN over
  the sqlite-vec index joined back to canonical. Over-fetches `kPrime = max(k*8, 50)` once, then
  filters by `visibleNodeIDs` (Focus), `excludingIDs`, `floor`, and a per-hit join-survival guard
  (`resolve` requires `n.state == .active`). Calls `store.knn(query:k:activeOnly: true)`.
- `SemanticIndexStore.open(_:dimension:version:)` — opens the pool, then in a single `pool.write`
  reads `meta`, and on a version/dimension mismatch DROPs `embeddings`/`items`/`meta`, recreates
  them, and reinserts `meta`. `init` deletes the file and retries once if `open` returns nil.
- `PensieveMCP.searchJSON(query:limit:)` (in `Sources/pensieve/Commands/Mcp.swift`) — constructs a
  fresh `NLContextualEmbedder()` + `SemanticIndexStore(...)` **on every call**. The MCP server is a
  long-lived stdio process. The app already caches its embedder+store as lazy `AppModel` properties.

## Part A — Include-archived toggle (⌘F)

**Goal:** archived nodes (currently reachable only via the collapsed Archived sidebar section) can
be opted into ⌘F results, exact and semantic.

**Kit.** Add `includeArchived: Bool` to both query kernels:

- `SearchQueries.search(query:visibleNodeIDs:includeArchived:_:)`
  - Node filter widens from `state == .active` to
    `state == .active || (includeArchived && state == .archived)`.
  - Loose-end node-gating widens identically. `LooseEnd.isOpen($0)` **stays** — we still surface
    only *open* loose ends, just also those under archived nodes.
  - Ranking, snippets, caps unchanged.
- `SemanticQueries.search(query:visibleNodeIDs:excludingIDs:k:floor:store:embedder:includeArchived:_:)`
  - Passes `activeOnly: !includeArchived` to `store.knn`.
  - The join-survival guard in `resolve` widens from `n.state == .active` to also admit `.archived`
    when the flag is set (for `node`, and for the node joined by `loose_end`/`event`).
  - `muted` state stays excluded in both.

**App.** `AppModel` gains a `searchScope` enum (`.active` / `.all`). `RootView` attaches
`.searchScopes($appModel.searchScope)` with two `Text` labels; `.onChange(of:)` re-runs the search;
`runSearch` reads it and passes `includeArchived: (searchScope == .all)` to both Kit calls. The
scope bar renders under the `.searchable` field only while searching (native behavior). Two new
German strings for the scope labels ("Active" / "Include Archived"); node/loose-end **content is
never localized** (unchanged rule).

**Why no forest/selection plumbing:** archived nodes are already in `allNodes` (the FULL set) and
therefore in the Focus-visible set (`NodeContextResolver` filters by *context*, not *state*). The
state guard inside the query kernels is the only gate. Search hits drive the detail pane directly
(the briefing-card pattern in `selectSearchNode`/`selectSearchLooseEnd`), which already renders
archived nodes, so navigation to an archived hit works without new wiring.

**MCP stays active-only** (`includeArchived: false`) — exposing an `include_archived` param on the
MCP `search` tool is a non-goal (see below).

## Part B — Idempotent rebuild guard

**Problem (TOCTOU).** `open` reads `meta` and then conditionally rebuilds inside one `pool.write`.
GRDB's default write transaction is deferred: the `meta` SELECT takes only a shared lock. With app +
daemon + MCP all opening the store, on a version bump two processes can both read stale `meta`
(mismatch = true), then both try to upgrade to a write lock to DROP. In WAL mode the loser gets
`SQLITE_BUSY_SNAPSHOT` (not resolved by the busy handler) → `open` throws → returns nil → `init`'s
delete-and-retry **removes the file the winner just rebuilt** → churn, and a brief window where the
index is empty.

**Fix.** Wrap the `meta` check + drop/create/insert-meta in an explicit **`BEGIN IMMEDIATE`**
transaction so the write lock is acquired *before* the `meta` read:

```swift
try pool.writeWithoutTransaction { db in
  try db.inTransaction(.immediate) {
    // ... existing meta read + mismatch DROP/CREATE/INSERT ...
    return .commit
  }
}
```

Now the second opener blocks on `BEGIN IMMEDIATE` (busyMode `.timeout(5)` waits it out), then reads
the **committed, updated** `meta`, sees mismatch = false, and no-ops the rebuild. The delete-and-retry
in `init` stays as the genuine-corruption fallback but no longer fires on the race (a contending
opener now waits rather than throwing). The upsert path is **unchanged** — only `open`'s schema work
becomes immediate.

## Part C — MCP embedder/store caching

**Fix.** Hoist the per-call construction in `PensieveMCP` into two `private static let`:

```swift
private static let semanticEmbedder = NLContextualEmbedder()
private static let semanticStore = SemanticIndexStore(
  url: PensievePaths.semanticIndexURL(),
  dimension: semanticEmbedder.dimension, embedderVersion: semanticEmbedder.version)
```

`searchJSON` reuses them. Swift guarantees `static let` is initialized exactly once, thread-safely;
both types are `Sendable`. Saves the ML-asset load + pool open on every `search` call in the
long-lived server.

**Caveat (documented):** a version bump *while the MCP server is running* won't reopen the cached
store — acceptable, since the server is session-scoped and the app/daemon own rebuilds. A server that
predates a bump simply serves the prior index until the session ends.

## Part D — Expand-and-retry under Focus-muting

**Problem.** Focus context is applied post-KNN (`visibleNodeIDs`), not pushed into the vec0 query
(only `state` is an index column). Under a Focus that mutes most of the corpus, the top-`kPrime`
neighbors can all be muted → few/zero visible hits, even though visible matches exist deeper in the
ranking.

**Fix.** Wrap the existing over-fetch in a grow-`k` loop:

```swift
var kFetch = max(k * 8, 50)
let maxFetch = 2000
while true {
  let raw = store.knn(query: qvec, k: kFetch, activeOnly: !includeArchived)
  let hits = buildHits(raw, upTo: k)               // existing filter+resolve, capped at k
  if hits.count >= k || raw.count < kFetch || kFetch >= maxFetch { return hits }
  kFetch = min(kFetch * 4, maxFetch)
}
```

KNN ordering is deterministic, so each larger fetch is a superset prefix; re-resolving from the top
is simple and correct. The loop terminates when we have `k` hits, the index is exhausted
(`raw.count < kFetch`), or we hit the `maxFetch` cap (returns what it found — honest, best-effort).
Only triggers under heavy muting; the common case fetches once as today.

## Cross-cutting

- **Signature growth.** `includeArchived` is added to both query kernels — 2 call sites each (app +
  MCP). MCP passes `false`; the app passes the scope.
- **Testing (Kit, TDD).**
  - Include-archived: exact + semantic each return archived hits iff the flag is set; default
    (active-only) behavior unchanged.
  - Expand-and-retry: a fixture where most nodes are in a muted Focus context and the visible matches
    rank beyond the initial `kPrime` — assert the visible ones surface (they would not with a single
    fetch).
  - Rebuild guard: same-version reopen preserves indexed data (regression invariant); bumped-version
    reopen drops. The cross-process concurrency guarantee is structural (immediate transaction) and
    documented rather than unit-tested (true concurrency is not deterministically reproducible in a
    unit test).
  - MCP caching + the app toggle: no MCP/app unit tests — behavior is guarded by the existing search
    tests; verified by manual smoke.
- **Verification.** `./scripts/test.sh` for Kit; `xcodebuild` build + non-blocking inner-binary
  smoke-launch for the app (throwaway `PENSIEVE_DB`/`PENSIEVE_CAPTURE_DB`). Interactive checks
  (the scope bar toggling live results incl. an archived hit; German scope labels) are human-verify
  carries.

## Non-goals

- **Transcript-passage chunking** — the next corpus increment; its own spec.
- **`include_archived` on the MCP `search` tool** — MCP stays active-only. Trivial to add later if
  wanted.
- **`muted` state** — remains deferred everywhere.

## Execution note

Four small items ≈ one plan of ~4–5 TDD tasks. Given the size, this is a candidate for a lighter
single-worktree run rather than the full one-implementer-plus-reviewer-per-task ceremony — to be
decided at plan time.
