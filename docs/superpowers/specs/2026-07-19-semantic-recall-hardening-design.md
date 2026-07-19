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

- **A — Include-archived toggle (⌘F), exact-search only** — *user-facing.* (Semantic "Related" stays
  active-only: the semantic index contains no archived content — see the Part A scope note.)
- **B — Rebuild robustness** (rescoped after review: the concurrency mechanism already works, so this
  is a regression test for the version-bump invariant only — no production code change) — *invisible.*
- **C — MCP embedder/store caching** across calls — *invisible.*
- **D — Expand-and-retry under heavy Focus-muting** (with a floor-aware exit) — *invisible.*

> **Review note.** This spec was revised after two independent adversarial reviews **and** a
> plan-time code check. Material changes:
> - **Part B's original premise was false** — GRDB's `pool.write` already begins an immediate
>   transaction, so the proposed guard was a no-op; dropped in favor of the invariant test only.
> - **Include-archived is exact-search only** — the semantic index contains no archived content
>   (`EmbeddableCorpus.gather` is active-only), so a KNN state relaxation would match nothing.
>   Semantic archived recall is deferred (needs a corpus-producer change). This removed the
>   `SemanticQueries`/`knn` signature changes and the `muted`-pushdown item entirely.
> - Folded-in fixes: default the new `SearchQueries` parameter (additive, no broken call sites); a
>   floor-aware exit in Part D (avoid pointless `k` escalation on sparse queries); one localization
>   key, not two; spike the `.searchScopes` bar under `.sidebar` placement first, with a fallback.

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

**Scope (decided): exact-search only.** The semantic index contains **no archived content** —
`EmbeddableCorpus.gather` (`EmbeddableItem.swift:23,30,35`) indexes only active nodes and their
items (loose-end/event rows even hardcode `state: "active"`), and the `SemanticIndexer` prunes an
item once it leaves the active corpus (so archiving a node *deletes* its vectors). Relaxing a KNN
state filter would therefore match rows that don't exist. Indexing archived content (changing the
corpus producer + pruner + re-embedding) is a larger, separate effort (deferred). So the toggle
reaches **exact `⌘F` search only**; semantic "Related" stays active-only.

**Kit.** Add `includeArchived: Bool = false` to **`SearchQueries.search`** only — **defaulted**,
placed just before the trailing `_ db`, so it is fully additive: the 12 existing `SearchQueriesTests`
call sites and the MCP site compile untouched, and only the app opts in. `SemanticQueries.search` is
**not** changed for archived (it only gains Part D).

- `SearchQueries.search(query:visibleNodeIDs:includeArchived:_:)`
  - Node filter widens from `state == .active` to
    `state == .active || (includeArchived && state == .archived)`.
  - Loose-end node-gating widens identically. `LooseEnd.isOpen($0)` **stays** — we still surface
    only *open* loose ends, just also those under archived nodes.
  - `muted` stays excluded. Ranking, snippets, caps unchanged.

**App.** `AppModel` gains a `searchScope` enum (`.active` / `.all`).

- **Spike-first (the only user-visible deliverable is hostage to a platform assumption).** `.searchable`
  is attached to `ContentListView` in the **content** column with `placement: .sidebar`
  (`RootView.swift:34`). Whether a `.searchScopes` scope bar actually *renders* under `.sidebar`
  placement inside a `NavigationSplitView` is macOS-version/placement-dependent and SwiftUI can
  silently drop it. **First implementation task = spike the scope bar with the real `.sidebar`
  placement.** `.searchScopes` must chain **directly onto the `ContentListView` that carries
  `.searchable`**, not onto `RootView`/`NavigationSplitView`.
- **Pre-committed fallback** if the scope bar doesn't render: a segmented `Picker` in the search-results
  header (the reviewer-2 "Toggle in results header" layout), or switch `.searchable` to `.automatic`
  placement. Either keeps the feature shipping regardless of the scope-bar outcome.
- Scope change re-runs the search through the existing debounce/`searchToken` machinery (already
  cancels the prior task and gates assignment on a monotonic token, so a scope-change re-run can't be
  raced by a stale in-flight query). `runSearch` captures the flag as a **pre-Task local**
  (`let includeArchived = (searchScope == .all)`), mirroring how `query`/`visible` are snapshotted
  before the off-main `Task` — reading `self.searchScope` inside the async closure would be a
  main-actor-isolation violation. The flag is passed to **`SearchQueries.search` only**; the semantic
  `SemanticQueries.search` call is left active-only (the "Related" section does not include archived —
  see the scope note). This is a deliberate, documented asymmetry.
- **Localization: exactly one new key** — `"Include Archived"` (hand-authored into
  `Localizable.xcstrings` with its German + `state: "translated"`, per the project gotcha that
  `xcodebuild` does not auto-populate the source catalog). The `"Active"` label **reuses the existing
  key** (already `"Aktiv"`). Node/loose-end **content is never localized** (unchanged rule).

**Why no forest/selection plumbing:** archived nodes are already in `allNodes` (the FULL set) and
therefore in the Focus-visible set (`NodeContextResolver` filters by *context*, not *state*). The
state guard inside the query kernels is the only gate. Search hits drive the detail pane directly
(the briefing-card pattern in `selectSearchNode`/`selectSearchLooseEnd`), which already renders
archived nodes, so navigation to an archived hit works without new wiring.

**MCP stays active-only** — its `SearchQueries.search` call keeps the defaulted `includeArchived`
(false), and its `visibleNodeIDs` set (`allActive`) is active-only by construction anyway. Exposing an
`include_archived` param on the MCP `search` tool is a non-goal (see below).

## Part B — Rebuild robustness (rescoped after review)

**The original premise was wrong.** The spec first proposed wrapping the `meta` check + rebuild in
`BEGIN IMMEDIATE` to close a TOCTOU. Adversarial review (verified against the vendored GRDB source)
established that GRDB's `pool.write` **already** begins an immediate transaction on a writable
connection — `Database.inTransaction(nil)` resolves to `.immediate` for exactly this reason
(`Database.swift:1732`, comment cites the read-then-upgrade `SQLITE_BUSY` hazard and issue 1483). So
today's `open`:

- already takes the write lock **before** the `meta` SELECT → no read-snapshot-then-upgrade → no
  `SQLITE_BUSY_SNAPSHOT`;
- a second concurrent opener blocks on `BEGIN IMMEDIATE`, which `busyMode = .timeout(5)` waits out
  (ordinary `SQLITE_BUSY`, unlike a snapshot conflict, *is* retried by the busy handler);
- the loser then reads the committed, updated `meta`, sees `mismatch == false`, and no-ops.

**That is already the desired behavior.** The proposed transaction change would be a literal no-op
refactor. It is dropped.

**What Part B delivers (test-only, per user decision):**

**A regression test that locks in the invariant** — the sole deliverable. Open the store, index
items; reopen with the **same** version/dimension → indexed data survives, no drop. Reopen with a
**bumped** version → tables dropped, index empty, `meta` reinserted. This pins the "rebuild only on
mismatch, idempotent on match" contract so a future refactor can't silently regress it.

**Not included (decided against, YAGNI).** Hardening `open`'s blanket `catch { return nil }`
(`SemanticIndexStore.swift:86`) — which turns *any* thrown error into `init`'s `removeItem` and could,
in principle, delete a freshly-built index if a rebuild ever exceeded the 5 s busy timeout — is a
*near-impossible* scenario (an empty-table DROP/CREATE is sub-millisecond) and is deliberately left
alone. No production code changes in Part B; the upsert and open paths are untouched.

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

**Implementation note (review).** Caching snapshots `semanticEmbedder.dimension` at first access. The
per-call code self-heals if the NL asset isn't ready (a later call reconstructs with a nonzero
dimension); a cached store constructed while `dimension == 0` would hit `SemanticIndexStore`'s
`guard dimension > 0` and stay `isAvailable == false` for the whole session. Confirm
`NLContextualEmbedding(script:).dimension` is asset-**independent** (model-revision metadata,
almost certainly nonzero immediately — which is why the shipped per-call code works). If that can't
be confirmed, construct `semanticStore` lazily on the first *successful* embed instead of eagerly at
type init. The cached embedder itself is fine either way — `embed` re-checks `hasAvailableAssets`
each call, so it starts returning vectors once assets land.

## Part D — Expand-and-retry under Focus-muting

**Problem.** Focus context is applied post-KNN (`visibleNodeIDs`), not pushed into the vec0 query
(only `state` is an index column). Under a Focus that mutes most of the corpus, the top-`kPrime`
neighbors can all be muted → few/zero visible hits, even though visible matches exist deeper in the
ranking.

**Fix.** Wrap the existing over-fetch in a grow-`k` loop with a **floor-aware** early exit:

```swift
var kFetch = max(k * 8, 50)
let maxFetch = 2000
while true {
  let raw = store.knn(query: qvec, k: kFetch, activeOnly: true)   // unchanged signature
  let hits = buildHits(raw, upTo: k)               // existing filter+resolve+floor, capped at k
  if hits.count >= k || raw.count < kFetch || kFetch >= maxFetch { return hits }
  if let last = raw.last, last.similarity < floor { return hits }   // below-floor boundary reached
  kFetch = min(kFetch * 4, maxFetch)
}
```

The **floor-aware exit is load-bearing** (review finding): similarity is monotonically non-increasing
across `raw` (KNN is `ORDER BY distance` ascending; `cosine(fromL2:)` is monotonically decreasing in
distance). So once the farthest fetched neighbor is below `floor`, every deeper neighbor is too —
growing `kFetch` could only fetch strictly-below-floor items that can never become hits. Without this
exit, an ordinary *sparse* query (few genuinely-similar items — common, not just muted) would escalate
50 → 200 → 800 → 2000 pointlessly, adding latency to the common case. With it, the loop grows **only**
when the shortfall is caused by Focus-muting (above-floor neighbors exist but are muted), and the
common/sparse case still fetches once.

KNN ordering is deterministic, so each larger fetch is a superset prefix; re-resolving from the top is
simple and correct (and cheap — `floor`/`visibleNodeIDs`/`excludingIDs` are applied *before* the
per-hit `resolve` DB read, so few candidates reach it). The loop also terminates on `k` hits, index
exhaustion (`raw.count < kFetch`), or the `maxFetch` cap (returns what it found — honest, best-effort).

**`maxFetch = 2000` — revisit with chunking.** Fine for today's single-user corpus (hundreds–low
thousands). When transcript-passage chunking lands (the next corpus increment), the index may exceed
2000 and a heavily-muted Focus could have visible matches ranked beyond the cap that never surface —
bump/reconsider the cap at that point.

## Cross-cutting

- **Signature growth (additive).** `includeArchived: Bool = false` is **defaulted** on
  `SearchQueries.search` only, so the only site that changes is the app (1 call site). The 12 existing
  `SearchQueriesTests` call sites and the MCP site compile unchanged. `SemanticQueries.search` and
  `SemanticIndexStore.knn` keep their current signatures (Part D is internal to `SemanticQueries`).
- **Testing (Kit, TDD).**
  - Include-archived (exact): with the flag set, archived nodes + their open loose ends surface;
    default (active-only) behavior unchanged; `muted` never surfaces. Mirror the existing
    `searchExcludesArchivedNodesAndLooseEnds` fixture (uses `NodeCommands.archive`).
  - Expand-and-retry: (a) a fixture where most nodes are in a muted Focus context and the visible
    matches rank beyond the initial `kPrime` — assert the visible ones surface (they would not with a
    single fetch); (b) a sparse fixture where only a couple of items are above `floor` — assert the
    loop exits after **one** fetch (no pointless escalation), guarding the floor-aware exit.
  - Rebuild invariant: same-version reopen preserves indexed data; bumped-version reopen drops + resets
    `meta`. (The cross-process serialization is already provided by GRDB's immediate write transaction —
    see Part B — so this test pins the *invariant*, not a new mechanism.)
  - MCP caching + the app toggle: no MCP/app unit tests — behavior is guarded by the existing search
    tests; verified by manual smoke.
- **Verification.** `./scripts/test.sh` for Kit; `xcodebuild` build + non-blocking inner-binary
  smoke-launch for the app (throwaway `PENSIEVE_DB`/`PENSIEVE_CAPTURE_DB`). Interactive checks
  (the scope bar toggling live results incl. an archived hit; German scope labels) are human-verify
  carries.

## Non-goals

- **Archived content in semantic "Related" / the semantic index** — deferred. Needs
  `EmbeddableCorpus.gather` to index active+archived with correct per-item state, the `SemanticIndexer`
  pruner to stop dropping archived, and archived content re-embedded. Its own effort.
- **Transcript-passage chunking** — the next corpus increment; its own spec.
- **`include_archived` on the MCP `search` tool** — MCP stays active-only. Trivial to add later if
  wanted.
- **`muted` state** — remains deferred everywhere.

## Execution note

Four small items ≈ one plan of ~4–5 TDD tasks. Given the size, this is a candidate for a lighter
single-worktree run rather than the full one-implementer-plus-reviewer-per-task ceremony — to be
decided at plan time.
