# Semantic-recall hardening + include-archived search — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Four small, independent hardening changes to the shipped semantic-recall stack, plus one user-facing include-archived toggle in ⌘F exact search.

**Architecture:** Three of the four items are invisible robustness fixes local to `PensieveKit` (`SemanticQueries`, a regression test on `SemanticIndexStore`) and the `pensieve` CLI (`PensieveMCP` caching). The fourth adds a defaulted `includeArchived` parameter to `SearchQueries.search` (exact-search only — the semantic index holds no archived content) and wires an app-side `.searchScopes` toggle. The trust gate is untouched throughout — this is retrieval plumbing only.

**Tech Stack:** Swift 6, Swift Testing (`@Test`/`@Suite`/`#expect`), SQLiteData (GRDB-backed), sqlite-vec, SwiftUI (app target), XcodeGen/Xcode for the app + CLI bundles.

## Global Constraints

- **Swift only. No Python, ever.**
- **SQLiteData predicates use `.eq(x)`, NOT `== x`** (`==` is `unavailable`).
- **The trust gate is untouched** — no change to how loose ends are cited or how narration is gated.
- **Kit tests run with `./scripts/test.sh`** (thin `swift test` passthrough; `--filter <name>` to scope). Tests honor `PENSIEVE_DB` / `PENSIEVE_CAPTURE_DB` env overrides.
- **The app target (`Sources/PensieveApp/`) has NO unit tests** — verify app changes with an `xcodebuild` build + a **non-blocking** smoke-launch of the inner binary (`./.build-xcode/Build/Products/Debug/Pensieve.app/Contents/MacOS/Pensieve`, background + `kill`, throwaway `PENSIEVE_DB`/`PENSIEVE_CAPTURE_DB`).
- **The CLI is the Xcode `PensieveCLI` target** (`PRODUCT_NAME=pensieve`); build it via `xcodebuild -scheme PensieveCLI build`. `swift run pensieve` does not exist.
- **New parameters are DEFAULTED** so the change is additive (no broken existing call sites).
- **Localization is hand-authored** into `Sources/PensieveApp/Localizable.xcstrings` (`xcodebuild` does not auto-populate the source catalog); German is impersonal/infinitive; a mis-keyed `de` value silently falls back to English. **App chrome only** — node/loose-end content is never localized.
- **Commits:** end messages with the repo's `Co-Authored-By:` + `Claude-Session:` trailers; **never put backticks in `git commit -m`** (the shell executes them) — use `-F <file>` or single quotes.
- **Include-archived is EXACT-search only.** The semantic index (`EmbeddableCorpus.gather`) contains active nodes only; do NOT touch `SemanticQueries`/`knn` for archived. Semantic "Related" stays active-only.

**Spec:** `docs/superpowers/specs/2026-07-19-semantic-recall-hardening-design.md`

---

## File Structure

- `Tests/PensieveKitTests/SemanticIndexStoreTests.swift` — **modify** (add the same-version-reopen regression test; Task 1).
- `Sources/PensieveKit/Query/SearchQueries.swift` — **modify** (add defaulted `includeArchived`; Task 2).
- `Tests/PensieveKitTests/SearchQueriesTests.swift` — **modify** (add the include-archived test; Task 2).
- `Sources/PensieveKit/Query/SemanticQueries.swift` — **modify** (expand-and-retry loop + floor-aware exit + `buildHits` helper; Task 3).
- `Tests/PensieveKitTests/SemanticQueriesTests.swift` — **modify** (add the expand-and-retry test; Task 3).
- `Sources/pensieve/Commands/Mcp.swift` — **modify** (`PensieveMCP` static embedder/store cache; Task 4).
- `Sources/PensieveApp/AppModel.swift` — **modify** (`SearchScope` state + `runSearch` wiring; Task 5).
- `Sources/PensieveApp/RootView.swift` — **modify** (`.searchScopes` on the searchable `ContentListView`; Task 5).
- `Sources/PensieveApp/ContentListView.swift` — **modify** (fallback header Picker, only if the spike shows the scope bar doesn't render; Task 5).
- `Sources/PensieveApp/Localizable.xcstrings` — **modify** (one new key `"Include Archived"`; Task 5).

**Dependency order:** Task 2 (adds the `SearchQueries` param) must precede Task 5 (app consumes it). Tasks 1, 3, 4 are independent. Recommended order: 1 → 2 → 3 → 4 → 5.

---

### Task 1: Part B — regression test for the same-version rebuild invariant

Test-only. **No production code changes.** `SemanticIndexStore.open` already rebuilds only on a version/dimension mismatch (GRDB's `pool.write` uses `BEGIN IMMEDIATE`, so the check-and-rebuild is already race-safe — see the spec). `SemanticIndexStoreTests` already covers the mismatch-drops case (`versionMismatchRebuildsEmpty`); the missing invariant is that a **same-version** reopen *preserves* indexed data. This test pins it so a future refactor can't silently regress it.

**Files:**
- Test: `Tests/PensieveKitTests/SemanticIndexStoreTests.swift` (add one `@Test` inside the existing `@Suite struct SemanticIndexStoreTests`, alongside `versionMismatchRebuildsEmpty` at line 50).

**Interfaces:**
- Consumes: `SemanticIndexStore(url:dimension:embedderVersion:)`, `.upsert(row:embedding:)`, `.existingItems() -> [String: String]`, `.knn(query:k:activeOnly:) -> [KNNResult]`, `StubEmbedder(dimension:)`, the suite's private `tempURL()` helper (line 6).
- Produces: nothing (test).

- [ ] **Step 1: Write the failing test**

Add to `SemanticIndexStoreTests.swift` (mirror the style of `versionMismatchRebuildsEmpty`, which uses a `do { }` block to close the first store before reopening):

```swift
@Test func sameVersionReopenPreservesData() async {
  let url = tempURL()
  let e = StubEmbedder(dimension: 8)
  let v = await e.embed(["x"])![0]
  do {
    let s = SemanticIndexStore(url: url, dimension: 8, embedderVersion: "stub:8")
    s.upsert(row: .init(itemID: "a", kind: "node", nodeID: "n", state: "active",
                        contentHash: "h"), embedding: v)
  }
  // Reopen with the SAME version + dimension → must NOT drop; indexed data survives.
  let reopened = SemanticIndexStore(url: url, dimension: 8, embedderVersion: "stub:8")
  #expect(reopened.existingItems() == ["a": "h"])
  #expect(reopened.knn(query: v, k: 1, activeOnly: true).first?.itemID == "a")
}
```

- [ ] **Step 2: Run the test to verify it passes (invariant already holds)**

Run: `./scripts/test.sh --filter sameVersionReopenPreservesData`
Expected: PASS. (This is a regression guard for behavior that already ships — it should pass immediately. If it *fails*, that is a real, pre-existing bug in `open`'s rebuild guard; stop and report before proceeding.)

- [ ] **Step 3: Run the full store suite to confirm no interference**

Run: `./scripts/test.sh --filter SemanticIndexStoreTests`
Expected: all tests PASS.

- [ ] **Step 4: Commit**

```bash
git add Tests/PensieveKitTests/SemanticIndexStoreTests.swift
git commit -F <msg-file>   # "test: pin same-version reopen preserves the semantic index (Part B)"
```

---

### Task 2: Part A (Kit) — `includeArchived` on `SearchQueries.search`

Add a defaulted `includeArchived: Bool = false` so archived nodes + their open loose ends can opt into exact-search results. Additive — the 12 existing `SearchQueriesTests` call sites and the MCP site compile unchanged.

**Files:**
- Modify: `Sources/PensieveKit/Query/SearchQueries.swift:46-56` (signature + node filter; loose-end gating is unchanged because it already keys off the matched-node set).
- Test: `Tests/PensieveKitTests/SearchQueriesTests.swift` (add one `@Test`, mirror `searchExcludesArchivedNodesAndLooseEnds` at line 112).

**Interfaces:**
- Consumes: `NodeCommands.archive(_:nodeID:) -> Bool`, the file-private `seed(...)` + `allVisible(_:)` helpers, `NodeState.active`/`.archived`.
- Produces: `SearchQueries.search(query:visibleNodeIDs:includeArchived:_:)` — `includeArchived` defaults to `false`; positional trailing `_ db` unchanged so existing `search(query:visibleNodeIDs:db)` calls still resolve.

- [ ] **Step 1: Write the failing test**

Add to `SearchQueriesTests.swift`:

```swift
@Test func searchIncludesArchivedWhenFlagSet() throws {
  let db = try openCanonicalDatabase(at: tempURL("search-incl-archived"))
  let active = try seed(db, name: "Deploy pipeline", ends: [("deploy the release", "ship it", "todo")])
  let archived = try seed(db, name: "Deploy legacy", ends: [("deploy old thing", "legacy", "todo")])
  #expect(try NodeCommands.archive(db, nodeID: archived.id))

  // Flag OFF (default) → archived excluded (matches the existing exclusion test).
  let off = try SearchQueries.search(query: "deploy", visibleNodeIDs: allVisible(db), db)
  #expect(off.nodes.map(\.id) == [active.id])

  // Flag ON → both the active AND the archived node + their open loose ends surface.
  let on = try SearchQueries.search(query: "deploy", visibleNodeIDs: allVisible(db),
                                    includeArchived: true, db)
  #expect(Set(on.nodes.map(\.id)) == [active.id, archived.id])
  #expect(Set(on.looseEnds.map(\.nodeID)) == [active.id, archived.id])
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `./scripts/test.sh --filter searchIncludesArchivedWhenFlagSet`
Expected: FAIL — compile error (`extra argument 'includeArchived'`) or, once the signature exists but the filter isn't widened, the `on` assertions fail (archived still excluded).

- [ ] **Step 3: Add the parameter and widen the node filter**

In `Sources/PensieveKit/Query/SearchQueries.swift`, change the signature (around line 46):

```swift
  public static func search(query rawQuery: String,
                            visibleNodeIDs: Set<UUID>,
                            includeArchived: Bool = false,
                            _ db: any DatabaseReader) throws -> SearchResults {
```

Then widen the node filter (currently line 54-55) and rename the local for clarity:

```swift
      let nodes = try Node.order { $0.name }.fetchAll(db)
        .filter { visibleNodeIDs.contains($0.id)
                  && ($0.state == .active || (includeArchived && $0.state == .archived)) }
      let matchedNodeIDs = Set(nodes.map { $0.id })
```

Update the one downstream use of the old name (`activeVisibleIDs`, currently line 78) to `matchedNodeIDs`:

```swift
      let ends = try LooseEnd.where { LooseEnd.isOpen($0) }.fetchAll(db)
        .filter { matchedNodeIDs.contains($0.nodeID) }
```

(The `nameByID` dictionary at line 76 is built from `nodes`, so it already covers archived nodes — no change. `muted` is excluded because the filter admits only `.active`/`.archived`.)

- [ ] **Step 4: Run the test to verify it passes**

Run: `./scripts/test.sh --filter searchIncludesArchivedWhenFlagSet`
Expected: PASS.

- [ ] **Step 5: Run the full search suite (guard the 12 existing call sites + default behavior)**

Run: `./scripts/test.sh --filter SearchQueriesTests`
Expected: all PASS (including `searchExcludesArchivedNodesAndLooseEnds`, which calls without the new arg → default `false`).

- [ ] **Step 6: Commit**

```bash
git add Sources/PensieveKit/Query/SearchQueries.swift Tests/PensieveKitTests/SearchQueriesTests.swift
git commit -F <msg-file>   # "feat(search): opt-in include-archived for exact ⌘F search (Part A Kit)"
```

---

### Task 3: Part D — expand-and-retry with floor-aware exit in `SemanticQueries`

Under a Focus that mutes most of the corpus, the single `kPrime = max(k*8, 50)` over-fetch can return only muted rows → few/zero visible hits even though visible matches exist deeper. Wrap the fetch in a grow-`k` loop, with a floor-aware early exit so ordinary *sparse* queries (few above-floor items) still fetch once. No signature change; `knn` stays `activeOnly: true`.

**Files:**
- Modify: `Sources/PensieveKit/Query/SemanticQueries.swift:22-51` (refactor `search` into the loop + extract a `buildHits` helper from the existing per-`raw` loop body; `resolve` at line 53 is unchanged).
- Test: `Tests/PensieveKitTests/SemanticQueriesTests.swift` (add one `@Test` inside the existing `@Suite`, alongside `overFetchSurfacesVisibleHitRankedBelowMutedTop` at line 53).

**Interfaces:**
- Consumes: `SemanticIndexStore.knn(query:k:activeOnly:) -> [KNNResult]` (`KNNResult.similarity`), `StubEmbedder`, the suite's `store()` helper (line 22), `SemanticIndexer(store:embedder:).sync(_:)`, `Node(name:kind:context:)`.
- Produces: `SemanticQueries.search(...)` unchanged signature + behavior for the non-muted case; new private `buildHits`.

- [ ] **Step 1: Write the failing test**

Add to `SemanticQueriesTests.swift` (mirrors `overFetchSurfacesVisibleHitRankedBelowMutedTop`, but with **more** muted nodes than the initial `kPrime` of 50 so a single over-fetch can't reach the visible node):

```swift
/// 55 muted-context nodes whose name == the query embed to cosine ~1.0 (StubEmbedder is
/// deterministic), so they fill the entire initial kPrime=50 window. The one visible node has
/// different text (lower cosine) and ranks ~56th — only the expand-and-retry loop (kFetch grows
/// 50 → 200) reaches past the muted block to surface it. A single fetch would return [].
@Test func expandAndRetrySurfacesVisibleHitBeyondInitialOverFetch() async throws {
  let db = try openCanonicalDatabase(at: tempURL("semq-retry"))
  let query = "refunds pipeline overhaul"
  let visible = Node(name: "Something entirely different", kind: NodeKind.project)
  try await db.write { db in
    try Node.insert { visible }.execute(db)
    for _ in 0..<55 {
      try Node.insert { Node(name: query, kind: NodeKind.project, context: "personal") }.execute(db)
    }
  }
  let embedder = StubEmbedder(dimension: 16)
  let s = store()
  await SemanticIndexer(store: s, embedder: embedder).sync(db)

  let hits = await SemanticQueries.search(
    query: query, visibleNodeIDs: [visible.id], excludingIDs: [], k: 2, floor: -1.0,
    store: s, embedder: embedder, db)
  #expect(hits.contains { $0.nodeID == visible.id })
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `./scripts/test.sh --filter expandAndRetrySurfacesVisibleHitBeyondInitialOverFetch`
Expected: FAIL — with the current single-fetch `kPrime=50`, the visible node ranks beyond the window, so `hits` is empty and `#expect(hits.contains {...})` fails.

- [ ] **Step 3: Refactor `search` into the retry loop + extract `buildHits`**

Replace the body of `search` (lines 30-51) so it reads:

```swift
    let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    guard query.count >= 2, store.isAvailable,
          let qvec = await embedder.embed([query])?.first else { return [] }

    // Over-fetch, and grow the fetch window if post-KNN filtering (Focus-muting) starved the
    // result below k. A floor-aware exit keeps ordinary sparse queries (few above-floor items) at
    // one fetch: similarity is monotonically non-increasing across `raw`, so once the farthest
    // fetched neighbor is below `floor`, no deeper neighbor can ever become a hit.
    var kFetch = max(k * 8, 50)
    let maxFetch = 2000
    while true {
      let raw = store.knn(query: qvec, k: kFetch, activeOnly: true)
      let hits = buildHits(raw, k: k, floor: floor, visibleNodeIDs: visibleNodeIDs,
                           excludingIDs: excludingIDs, query: query, db)
      if hits.count >= k || raw.count < kFetch || kFetch >= maxFetch { return hits }
      if let last = raw.last, last.similarity < floor { return hits }
      kFetch = min(kFetch * 4, maxFetch)
    }
  }

  /// Filter one KNN page down to at most `k` grounded, visible, above-floor, non-excluded hits,
  /// re-resolving each survivor against canonical (the last grounding defense). Deterministic KNN
  /// ordering makes each larger fetch a superset prefix, so rebuilding from the top is correct.
  private static func buildHits(_ raw: [KNNResult], k: Int, floor: Double,
                                visibleNodeIDs: Set<UUID>, excludingIDs: Set<UUID>,
                                query: String, _ db: any DatabaseReader) -> [SemanticHit] {
    var hits: [SemanticHit] = []
    for r in raw {
      guard r.similarity >= floor,
            let nodeID = UUID(uuidString: r.nodeID), visibleNodeIDs.contains(nodeID) else { continue }
      guard let itemID = UUID(uuidString: r.itemID), !excludingIDs.contains(itemID) else { continue }
      guard let hit = try? resolve(kind: r.kind, itemID: itemID, similarity: r.similarity,
                                   query: query, db) else { continue }
      hits.append(hit)
      if hits.count == k { break }
    }
    return hits
  }
```

(Leave the `resolve(kind:itemID:similarity:query:_:)` method below it unchanged.)

- [ ] **Step 4: Run the new test to verify it passes**

Run: `./scripts/test.sh --filter expandAndRetrySurfacesVisibleHitBeyondInitialOverFetch`
Expected: PASS — kFetch grows 50 → 200, the second fetch includes the visible node, and it surfaces.

- [ ] **Step 5: Run the full semantic suite (guard existing behavior)**

Run: `./scripts/test.sh --filter SemanticQueriesTests`
Expected: all PASS — `focusMutingDoesNotZeroOutVisibleHits`, `overFetchSurfacesVisibleHitRankedBelowMutedTop`, `staleIndexRowDroppedByJoin`, `floorDropsWeakMatches`, `excludingIDsDedupesAgainstExactHits` unchanged. (The floor-aware exit is an optimization that cannot change results — it only stops fetching once everything remaining is below floor; the existing floor tests guard floor correctness.)

- [ ] **Step 6: Commit**

```bash
git add Sources/PensieveKit/Query/SemanticQueries.swift Tests/PensieveKitTests/SemanticQueriesTests.swift
git commit -F <msg-file>   # "feat(semantic): expand-and-retry under Focus-muting with floor-aware exit (Part D)"
```

---

### Task 4: Part C — cache the MCP embedder + store across calls

`PensieveMCP.searchJSON` builds a fresh `NLContextualEmbedder()` + `SemanticIndexStore(...)` on every call; the MCP server is long-lived. Hoist both into `private static let` (Swift initializes `static let` exactly once, thread-safely; both types are `Sendable`). CLI target → no unit test; verify by build. Behavior is guarded by the existing `SearchQueries`/`SemanticQueries` suites.

**Files:**
- Modify: `Sources/pensieve/Commands/Mcp.swift` — add two statics in `enum PensieveMCP` (near line 122), and replace the per-call construction in `searchJSON` (lines 200-204).

**Interfaces:**
- Consumes: `NLContextualEmbedder()`, `SemanticIndexStore(url:dimension:embedderVersion:)`, `PensievePaths.semanticIndexURL()`.
- Produces: `PensieveMCP.semanticEmbedder` / `PensieveMCP.semanticStore` (process-lifetime cached).

- [ ] **Step 1: Add the cached statics**

In `Sources/pensieve/Commands/Mcp.swift`, inside `enum PensieveMCP` (after `maxResultSizeMeta`, ~line 122), add:

```swift
  // Built once for the server's lifetime (the MCP process is long-lived): the NL asset load + the
  // index pool open are otherwise repeated on every `search` call. Both are Sendable. Caveat: a
  // version bump WHILE the server runs won't reopen the cached store — acceptable, the server is
  // session-scoped and the app/daemon own rebuilds.
  private static let semanticEmbedder = NLContextualEmbedder()
  private static let semanticStore = SemanticIndexStore(
    url: PensievePaths.semanticIndexURL(),
    dimension: semanticEmbedder.dimension, embedderVersion: semanticEmbedder.version)
```

- [ ] **Step 2: Use the statics in `searchJSON`**

Replace the per-call construction (lines 200-204) so the `if PensieveDefaults.semanticSearchEnabled()` branch reads:

```swift
    let related: [SemanticHit]
    if PensieveDefaults.semanticSearchEnabled() {
      related = await SemanticQueries.search(query: query, visibleNodeIDs: allActive, excludingIDs: exactIDs,
                                             k: limit, floor: 0.25, store: semanticStore,
                                             embedder: semanticEmbedder, db)
    } else {
      related = []
    }
```

(Delete the two now-orphaned local `let embedder = ...` / `let store = ...` lines.)

- [ ] **Step 3: Build the CLI to verify it compiles**

Run: `xcodebuild -scheme PensieveCLI -configuration Debug -derivedDataPath ./.build-xcode build`
Expected: `BUILD SUCCEEDED`. (If it dies with a SwiftSyntax/macro linker error, `rm -rf .build` and retry — a known intermittent issue.)

- [ ] **Step 4: Run the Kit suites that guard search behavior**

Run: `./scripts/test.sh --filter SemanticQueriesTests && ./scripts/test.sh --filter SearchQueriesTests`
Expected: all PASS (behavior unchanged; this task is a construction-site refactor).

- [ ] **Step 5: Commit**

```bash
git add Sources/pensieve/Commands/Mcp.swift
git commit -F <msg-file>   # "perf(mcp): cache embedder + semantic store across search calls (Part C)"
```

---

### Task 5: Part A (app) — `SearchScope` toggle via `.searchScopes` (spike + fallback)

Add the user-facing include-archived control to ⌘F. **Spike first:** confirm the `.searchScopes` bar renders under the app's `.sidebar` search placement; if it doesn't, use the pre-committed fallback (a segmented `Picker` in the results header). Either path consumes the same `AppModel.searchScope` state and passes `includeArchived` to `SearchQueries.search` only (semantic "Related" stays active-only). App target → verify by build + smoke.

**Files:**
- Modify: `Sources/PensieveApp/AppModel.swift` — add `SearchScope` + `searchScope` state (near the in-app-find block, line 252) and thread `includeArchived` through `runSearch` (lines 503-530).
- Modify: `Sources/PensieveApp/RootView.swift` — attach `.searchScopes` to the searchable `ContentListView` (line 34) + `.onChange` to re-run.
- Modify: `Sources/PensieveApp/ContentListView.swift` — fallback header `Picker` **only if** the spike shows the scope bar doesn't render.
- Modify: `Sources/PensieveApp/Localizable.xcstrings` — add `"Include Archived"`.

**Interfaces:**
- Consumes: `SearchQueries.search(query:visibleNodeIDs:includeArchived:_:)` (Task 2), existing `runSearch` machinery (`searchToken`, `Task.detached`, `NodeContextResolver.visibleNodeIDs`).
- Produces: `AppModel.SearchScope` (`.active`/`.all`), `AppModel.searchScope` (observable, `.active` default).

- [ ] **Step 1: Add `SearchScope` + state to `AppModel`**

In `Sources/PensieveApp/AppModel.swift`, add near the in-app-find block (after `var searchText` at line 253):

```swift
  /// ⌘F search scope. `.all` opts archived nodes into EXACT results (semantic "Related" stays
  /// active-only — the semantic index holds no archived content). Observable → drives the scope bar.
  enum SearchScope: Hashable { case active, all }
  var searchScope: SearchScope = .active
```

- [ ] **Step 2: Thread `includeArchived` through `runSearch`**

In `runSearch` (line 503), snapshot the scope into a pre-Task local (alongside `query`/`visible`) and pass it to the exact search only. Change the block at lines 512-518 to:

```swift
    let visible = NodeContextResolver.visibleNodeIDs(for: activeFocusContext, in: allNodes)
    let includeArchived = (searchScope == .all)   // pre-Task local: reading self.searchScope off-main is an isolation violation
    searchToken += 1
    let token = searchToken
    searchTask = Task { [weak self] in
      let results = try? await Task.detached {
        try SearchQueries.search(query: query, visibleNodeIDs: visible,
                                 includeArchived: includeArchived, db)
      }.value
```

(The `SemanticQueries.search` call at line 524 is left exactly as-is — active-only.)

- [ ] **Step 3: Attach `.searchScopes` in `RootView` (the spike)**

In `Sources/PensieveApp/RootView.swift`, chain `.searchScopes` directly onto the `ContentListView` that already carries `.searchable` (after line 34), plus a re-run on change:

```swift
      ContentListView(model: model)
        .navigationSplitViewColumnWidth(min: 240, ideal: 300, max: 420)
        .searchable(text: $model.searchText, placement: .sidebar, prompt: Text("Search"))
        .searchScopes($model.searchScope) {
          Text("Active").tag(AppModel.SearchScope.active)
          Text("Include Archived").tag(AppModel.SearchScope.all)
        }
        .searchFocused($isSearchFocused)
```

And add a scope-change handler among the existing `.onChange` modifiers (near line 55):

```swift
    .onChange(of: model.searchScope) { _, _ in
      if model.isSearching { model.runSearch() }
    }
```

- [ ] **Step 4: Add the localization key (hand-authored)**

In `Sources/PensieveApp/Localizable.xcstrings`, add a `"Include Archived"` entry (alphabetical order; mirror the `"Active"` block's shape at line 392). `"Active"` reuses the existing key — do NOT add it again.

```json
    "Include Archived" : {
      "extractionState" : "manual",
      "localizations" : {
        "de" : {
          "stringUnit" : {
            "state" : "translated",
            "value" : "Archivierte einschließen"
          }
        }
      }
    },
```

- [ ] **Step 5: Build the app**

Run: `xcodegen generate && xcodebuild -project Pensieve.xcodeproj -scheme Pensieve -configuration Debug -derivedDataPath ./.build-xcode build`
Expected: `BUILD SUCCEEDED`.

- [ ] **Step 6: Smoke-launch (non-blocking) + spike the scope bar**

Run (background-launch the inner binary with throwaway stores, then kill):

```bash
PENSIEVE_DB=$(mktemp -u).sqlite PENSIEVE_CAPTURE_DB=$(mktemp -u).sqlite \
  ./.build-xcode/Build/Products/Debug/Pensieve.app/Contents/MacOS/Pensieve &
PID=$!; sleep 4; kill $PID
```

Expected: launches + exits cleanly (no crash in the log).

**Spike decision (manual, needs a real interactive launch by the user):** type in ⌘F search and confirm the **Active / Include Archived** scope bar appears under the field and toggling it changes results.
- **If the scope bar renders:** done — remove any fallback scaffolding; proceed to Step 8.
- **If it does NOT render** (SwiftUI dropped it under `.sidebar` placement): apply the fallback in Step 7.

- [ ] **Step 7: Fallback (ONLY if the scope bar didn't render)**

Remove the `.searchScopes` modifier from `RootView` and instead render a segmented `Picker` bound to `model.searchScope` in the results header of `ContentListView.searchResultsList()` (line 44), above the `Projects` section:

```swift
      Picker("", selection: $model.searchScope) {
        Text("Active").tag(AppModel.SearchScope.active)
        Text("Include Archived").tag(AppModel.SearchScope.all)
      }
      .pickerStyle(.segmented)
      .labelsHidden()
```

(`ContentListView` will need `@Bindable var model` if it isn't already bindable — match the existing property-wrapper style in that file.) The `.onChange(of: model.searchScope)` in `RootView` (Step 3) stays and drives the re-run. Rebuild (Step 5) + smoke (Step 6) again to confirm the Picker toggles results.

- [ ] **Step 8: Commit**

```bash
git add Sources/PensieveApp/AppModel.swift Sources/PensieveApp/RootView.swift Sources/PensieveApp/Localizable.xcstrings
# add Sources/PensieveApp/ContentListView.swift too if the fallback was used
git commit -F <msg-file>   # "feat(app): include-archived scope toggle in ⌘F search (Part A app)"
```

---

## Human-verify carries (need the built app @ real store + plain `open`)

- The scope bar (or fallback Picker) toggles live: `Include Archived` surfaces archived nodes + their open loose ends in exact results; `Active` hides them again.
- Selecting an archived search hit lands on a coherent detail view (state badge shown), and clearing the field restores a coherent middle list.
- "Related" (semantic) results do **not** include archived items in either scope (documented asymmetry).
- German: forced-locale launch (`-AppleLanguages '(de)'`) shows `Archivierte einschließen`; `de.lproj/Localizable.strings` contains the key (`plutil -p`).

## Self-Review

**Spec coverage:**
- Part A (include-archived, exact-only) → Task 2 (Kit) + Task 5 (app). ✓
- Part B (rebuild invariant, test-only, no prod change) → Task 1. ✓
- Part C (MCP caching) → Task 4. ✓
- Part D (expand-and-retry + floor-aware exit) → Task 3. ✓
- `.searchScopes` spike-first + fallback → Task 5 Steps 6-7. ✓
- One localization key, hand-authored → Task 5 Step 4. ✓
- Defaulted parameter (additive) → Task 2 Step 3. ✓
- Semantic index has no archived content / semantic stays active-only → enforced by Global Constraints + Task 5 Step 2 leaving the semantic call untouched. ✓

**Placeholder scan:** no TBD/TODO; every code step shows complete code; every run step gives an exact command + expected output.

**Type consistency:** `AppModel.SearchScope` (`.active`/`.all`) used identically in Task 5 Steps 1, 3, 7. `includeArchived: Bool` defaulted in Task 2, consumed by name in Task 5 Step 2. `buildHits(_:k:floor:visibleNodeIDs:excludingIDs:query:_:)` defined and called with matching labels in Task 3 Step 3. `SemanticQueries.search` / `SearchQueries.search` signatures match their call sites in Tasks 3/4/5.
