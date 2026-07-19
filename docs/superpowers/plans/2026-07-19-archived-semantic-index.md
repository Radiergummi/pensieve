# Archived Content in the Semantic Index — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Index archived nodes, their open loose ends, and their events into the semantic index, so ⌘F "Related" (behind the existing Include Archived scope) and the MCP `search` tool (behind a new `include_archived` parameter) can surface archived work.

**Architecture:** The index schema already carries a `state` metadata column per row and `knn` already takes a state filter — nothing structural is missing. The change is three widenings that must land in lockstep: the corpus producer stops filtering to active and tags each item with its owning node's real state; `knn`'s filter becomes a two-state choice; and `SemanticQueries`' canonical re-resolve predicate widens to match. A defaulted `includeArchived: Bool = false` keeps every existing call site behaviourally identical.

**Tech Stack:** Swift 6, SwiftPM (PensieveKit + tests), Xcode/XcodeGen (app + CLI targets), SQLiteData/GRDB, sqlite-vec, Swift Testing.

**Spec:** `docs/superpowers/specs/2026-07-19-archived-semantic-index-design.md`

## Global Constraints

- **Run tests with `./scripts/test.sh`** (thin `swift test` passthrough), optionally `--filter <name>`. Baseline before you start: **448 tests passing**.
- **SQLiteData predicates use `.eq(x)`, NOT `== x`** — `==` is `unavailable` and will not compile.
- **Never hardcode state/kind strings.** Use `NodeState.active` / `NodeState.archived` and the `CaptureKind` / `SourceKind` constants.
- **`muted` is never indexed and never returned** — in either filter mode, in every task.
- **The trust gate is untouched.** No task changes what may be *said* about an item; only which live rows are eligible to be returned.
- **The app (`Sources/PensieveApp/`) has no unit tests.** Derivation logic belongs in tested PensieveKit; app views stay thin. App verification = `xcodebuild` build + non-blocking smoke-launch.
- **Do NOT set `PENSIEVE_DB` / `PENSIEVE_CAPTURE_DB` against the live store.** Smoke launches MUST set them to throwaway `/tmp` paths.
- **Commit messages:** backticks inside a double-quoted `git commit -m "..."` get shell-executed. Use `git commit -F -` with a quoted-`EOF` heredoc. Keep the `Co-Authored-By:` and `Claude-Session:` trailers used elsewhere in this repo's history.
- **String Catalog keys are hand-authored.** `xcodebuild` does not populate `Localizable.xcstrings`; add both the key and its `de` value by hand, with `"extractionState" : "manual"`.

## File Structure

| File | Responsibility | Task |
|---|---|---|
| `Sources/PensieveKit/Semantic/EmbeddableItem.swift` | Corpus producer: all states, per-node state tagging | 1 |
| `Sources/PensieveKit/Semantic/SemanticIndexStore.swift` | `knn(includeArchived:)` state filter | 2 |
| `Sources/PensieveKit/Query/SemanticQueries.swift` | Defaulted `includeArchived`, widened resolve, `isArchived` on the hit | 3 |
| `Sources/PensieveKit/Query/SearchQueries.swift` | `isArchived` on `NodeHit` / `LooseEndHit` | 4 |
| `Sources/PensieveApp/AppModel.swift` | Pass the search scope to the semantic call | 5 |
| `Sources/PensieveApp/ContentListView.swift` | Archived badge on the three row types | 5 |
| `Sources/PensieveApp/Localizable.xcstrings` | One key, `en` + `de` | 5 |
| `Sources/pensieve/Commands/Mcp.swift` | `include_archived` tool parameter | 6 |

Tasks 1→3 must land in order (each is a coherent intermediate state; see each task's note). Tasks 4, 5, 6 depend on 3.

---

### Task 1: Corpus producer indexes all states

**Files:**
- Modify: `Sources/PensieveKit/Semantic/EmbeddableItem.swift:27-57`
- Test: `Tests/PensieveKitTests/SemanticIndexerTests.swift`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: `EmbeddableCorpus.gather(_ db:) throws -> [EmbeddableItem]` — unchanged signature; now emits items for archived nodes too, with `EmbeddableItem.state` carrying the owning node's `NodeState.rawValue` (`"active"` or `"archived"`) instead of a hardcoded `"active"`. `muted` nodes and their items are never emitted.

**Note on the intermediate state:** after this task the index *contains* archived rows, but `knn` still filters `activeOnly` and `SemanticQueries` still rejects them on resolve, so no user-visible behaviour changes. That is intentional and correct — the widening lands query-side in Tasks 2 and 3.

- [ ] **Step 1: Write the failing tests**

Add to `Tests/PensieveKitTests/SemanticIndexerTests.swift`, inside `@Suite struct SemanticIndexerTests`:

```swift
  @Test func gatherIncludesArchivedNodesTaggedWithTheirState() async throws {
    let db = try openCanonicalDatabase(at: tempURL("corpus-archived"))
    let active = Node(name: "Payments", kind: NodeKind.project)
    let archived = Node(name: "Legacy billing", state: .archived, kind: NodeKind.project)
    try await db.write { db in
      try Node.insert { active }.execute(db)
      try Node.insert { archived }.execute(db)
    }
    let items = try EmbeddableCorpus.gather(db)

    let byID = Dictionary(items.map { ($0.itemID, $0) }, uniquingKeysWith: { a, _ in a })
    #expect(byID[active.id.uuidString]?.state == "active")
    #expect(byID[archived.id.uuidString]?.state == "archived")
  }

  @Test func gatherTagsLooseEndsAndEventsWithTheirOwningNodesState() async throws {
    let db = try openCanonicalDatabase(at: tempURL("corpus-archived-children"))
    let archived = Node(name: "Legacy billing", state: .archived, kind: NodeKind.project)
    try await db.write { try Node.insert { archived }.execute($0) }
    let ev = try makeEvent(db, node: archived, kind: CaptureKind.ccSession,
                           workSummary: "migrated the old invoices")
    let le = LooseEnd(nodeID: archived.id, sourceEventID: ev.id,
                      text: "drop the legacy invoice table", quote: "TODO drop invoices")
    try await db.write { try LooseEnd.insert { le }.execute($0) }

    let items = try EmbeddableCorpus.gather(db)
    let byID = Dictionary(items.map { ($0.itemID, $0) }, uniquingKeysWith: { a, _ in a })

    #expect(byID[le.id.uuidString]?.state == "archived")
    #expect(byID[ev.id.uuidString]?.state == "archived")
  }

  @Test func gatherStillExcludesMutedNodesAndClosedLooseEnds() async throws {
    let db = try openCanonicalDatabase(at: tempURL("corpus-muted"))
    let muted = Node(name: "Muted work", state: .muted, kind: NodeKind.project)
    let archived = Node(name: "Archived work", state: .archived, kind: NodeKind.project)
    try await db.write { db in
      try Node.insert { muted }.execute(db)
      try Node.insert { archived }.execute(db)
    }
    let ev = try makeEvent(db, node: archived)
    let closed = LooseEnd(nodeID: archived.id, sourceEventID: ev.id,
                          text: "already handled", quote: "done", status: "closed")
    try await db.write { try LooseEnd.insert { closed }.execute($0) }

    let ids = Set(try EmbeddableCorpus.gather(db).map { $0.itemID })
    #expect(!ids.contains(muted.id.uuidString))
    #expect(!ids.contains(closed.id.uuidString))
  }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `./scripts/test.sh --filter SemanticIndexerTests`

Expected: the three new tests FAIL. `gatherIncludesArchivedNodesTaggedWithTheirState` and `gatherTagsLooseEndsAndEventsWithTheirOwningNodesState` fail because the archived node is filtered out entirely (`byID[...]` is `nil`, so the optional comparison is `false`). `gatherStillExcludesMutedNodesAndClosedLooseEnds` should already PASS — it is the regression guard for what must NOT change. Every pre-existing test in the suite must still pass.

- [ ] **Step 3: Rewrite `gather`**

Replace the body of `EmbeddableCorpus.gather` in `Sources/PensieveKit/Semantic/EmbeddableItem.swift` (lines 27-57) with:

```swift
  public static func gather(_ db: any DatabaseReader) throws -> [EmbeddableItem] {
    try db.read { db in
      var out: [EmbeddableItem] = []
      // Active AND archived: archiving hides work from the normal views, it does not make the work
      // unrecallable. `muted` stays out of the corpus entirely. Each item carries its owning node's
      // real state, which is what lets the query layer scope results per search scope.
      let nodes = try Node.all.fetchAll(db)
        .filter { $0.state == .active || $0.state == .archived }
      let stateByNodeID = Dictionary(nodes.map { ($0.id, $0.state.rawValue) },
                                     uniquingKeysWith: { a, _ in a })
      for n in nodes {
        out.append(.init(itemID: n.id.uuidString, kind: "node", nodeID: n.id.uuidString,
                         state: n.state.rawValue, text: [n.name, n.description].filter { !$0.isEmpty }.joined(separator: " — ")))
      }
      let ends = try LooseEnd.where { LooseEnd.isOpen($0) }.fetchAll(db)
      for le in ends {
        guard let state = stateByNodeID[le.nodeID] else { continue }
        out.append(.init(itemID: le.id.uuidString, kind: "loose_end", nodeID: le.nodeID.uuidString,
                         state: state, text: [le.text, le.quote].filter { !$0.isEmpty }.joined(separator: " — ")))
      }
      let events = try Event.all.fetchAll(db)
      for e in events {
        guard let state = stateByNodeID[e.nodeID] else { continue }
        let text: String?
        switch e.kind {
        // LLM-enriched prose — gate it: degenerate model output ("[]", a bare "/") is not content.
        case CaptureKind.ccSession: text = e.workSummary.flatMap { isSearchable($0) ? $0 : nil }
        // Human-authored (a git commit subject). NOT gated — "wip" and "fix ci" are real, short work.
        default: text = e.summary.isEmpty ? nil : e.summary
        }
        if let text {
          out.append(.init(itemID: e.id.uuidString, kind: "event", nodeID: e.nodeID.uuidString,
                           state: state, text: text))
        }
      }
      return out
    }
  }
```

Then update the doc comment above `public enum EmbeddableCorpus` (line 17-18) from:

```swift
/// v1 producer of the semantic corpus: active nodes + open loose ends + enriched events.
/// The seam future producers (transcript chunks, etc.) extend.
```

to:

```swift
/// v1 producer of the semantic corpus: active AND archived nodes + their open loose ends +
/// their enriched events, each tagged with its owning node's state (the query layer scopes on it).
/// `muted` is never indexed. The seam future producers (transcript chunks, etc.) extend.
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `./scripts/test.sh --filter SemanticIndexerTests`
Expected: PASS, including every pre-existing test in the suite (notably the prune/repoint tests — the indexer's reconciliation logic is untouched).

- [ ] **Step 5: Run the full suite**

Run: `./scripts/test.sh`
Expected: 451 tests passing (448 baseline + 3).

- [ ] **Step 6: Commit**

```bash
git add Sources/PensieveKit/Semantic/EmbeddableItem.swift Tests/PensieveKitTests/SemanticIndexerTests.swift
git commit -F - <<'EOF'
feat(semantic): index archived content with per-node state tagging

The corpus producer no longer filters to active nodes. Loose ends and
events carry their owning node's real state instead of a hardcoded
"active", which is what lets the query layer scope per search scope.
muted stays out of the corpus entirely.

No user-visible change yet: knn still filters activeOnly and the query
layer still rejects archived on resolve. Both widen next.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_0158f2aPXJBVpcfa36bE9o2d
EOF
```

---

### Task 2: `knn` state filter becomes a two-state choice

**Files:**
- Modify: `Sources/PensieveKit/Semantic/SemanticIndexStore.swift:131-144`
- Modify: `Sources/PensieveKit/Query/SemanticQueries.swift:44` (call-site rename only — behaviour unchanged)
- Test: `Tests/PensieveKitTests/SemanticIndexStoreTests.swift`

**Interfaces:**
- Consumes: `EmbeddableCorpus.gather` from Task 1 (archived rows now reach the store).
- Produces: `SemanticIndexStore.knn(query: [Float], k: Int, includeArchived: Bool) -> [KNNResult]` — replaces `activeOnly: Bool`. `includeArchived: false` selects `state = 'active'` (identical to today's `activeOnly: true`); `includeArchived: true` selects `state IN ('active','archived')`. `muted` is excluded in both modes.

**Note on the intermediate state:** `SemanticQueries` calls this with `includeArchived: false` at the end of this task, so behaviour is still unchanged end-to-end. Task 3 threads the real flag through.

- [ ] **Step 1: Write the failing tests**

Add to `Tests/PensieveKitTests/SemanticIndexStoreTests.swift`, inside the existing `@Suite`. If the suite has no `store()` helper, mirror the one in `SemanticQueriesTests.swift`:

```swift
  @Test func knnExcludesArchivedByDefaultAndIncludesItWhenAsked() async throws {
    let s = store()
    let embedder = StubEmbedder(dimension: 16)
    guard let vecs = await embedder.embed(["active work", "archived work", "muted work"]),
          let activeVec = vecs[0], let archivedVec = vecs[1], let mutedVec = vecs[2] else {
      Issue.record("stub embedder returned no vectors"); return
    }
    s.upsert(row: .init(itemID: "a", kind: "node", nodeID: "n1",
                        state: NodeState.active.rawValue, contentHash: "h1"), embedding: activeVec)
    s.upsert(row: .init(itemID: "b", kind: "node", nodeID: "n2",
                        state: NodeState.archived.rawValue, contentHash: "h2"), embedding: archivedVec)
    s.upsert(row: .init(itemID: "c", kind: "node", nodeID: "n3",
                        state: NodeState.muted.rawValue, contentHash: "h3"), embedding: mutedVec)

    let narrow = Set(s.knn(query: activeVec, k: 10, includeArchived: false).map { $0.itemID })
    #expect(narrow == ["a"])

    let wide = Set(s.knn(query: activeVec, k: 10, includeArchived: true).map { $0.itemID })
    #expect(wide == ["a", "b"])            // archived in, muted still out
    #expect(!wide.contains("c"))
  }

  @Test func archiveFlipIsMetadataOnlyAndPreservesTheVector() async throws {
    let s = store()
    let embedder = StubEmbedder(dimension: 16)
    guard let vecs = await embedder.embed(["legacy billing"]), let vec = vecs[0] else {
      Issue.record("stub embedder returned no vectors"); return
    }
    // Indexed while active, with a vector.
    s.upsert(row: .init(itemID: "x", kind: "node", nodeID: "n1",
                        state: NodeState.active.rawValue, contentHash: "h"), embedding: vec)
    // The node is archived: same content hash, so the indexer upserts metadata with NO embedding.
    s.upsert(row: .init(itemID: "x", kind: "node", nodeID: "n1",
                        state: NodeState.archived.rawValue, contentHash: "h"), embedding: nil)

    // The vector survived the flip: the row is still KNN-reachable, now under the wide filter.
    #expect(s.knn(query: vec, k: 10, includeArchived: false).isEmpty)
    #expect(s.knn(query: vec, k: 10, includeArchived: true).map { $0.itemID } == ["x"])

    // And it flips back symmetrically, still without ever being re-embedded.
    s.upsert(row: .init(itemID: "x", kind: "node", nodeID: "n1",
                        state: NodeState.active.rawValue, contentHash: "h"), embedding: nil)
    #expect(s.knn(query: vec, k: 10, includeArchived: false).map { $0.itemID } == ["x"])
  }
```

Note on why this proves vector survival: both flips pass `embedding: nil`, so the only vector ever written was the first one. If the metadata-only path dropped or failed to preserve it, the row would be absent from `embeddings` and no `knn` call could return it.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `./scripts/test.sh --filter SemanticIndexStoreTests`
Expected: COMPILE FAILURE — `incorrect argument label in call (have 'query:k:includeArchived:', expected 'query:k:activeOnly:')`. That is the expected failure for this step.

- [ ] **Step 3: Change the `knn` signature and filter**

In `Sources/PensieveKit/Semantic/SemanticIndexStore.swift`, replace lines 131-134:

```swift
  public func knn(query: [Float], k: Int, activeOnly: Bool) -> [KNNResult] {
    guard let db else { return [] }
    let json = "[" + query.map { String($0) }.joined(separator: ",") + "]"
    let filter = activeOnly ? "AND state = 'active'" : ""
```

with:

```swift
  /// `includeArchived: false` returns active items only; `true` widens to active + archived.
  /// `muted` is excluded in BOTH modes — the filter is an allow-list, never a deny-list, so a
  /// future state can never leak in by omission. The SQL fragment is chosen from a Bool (no
  /// interpolated caller input), so there is no injection surface.
  public func knn(query: [Float], k: Int, includeArchived: Bool) -> [KNNResult] {
    guard let db else { return [] }
    let json = "[" + query.map { String($0) }.joined(separator: ",") + "]"
    let filter = includeArchived
      ? "AND state IN ('active','archived')"
      : "AND state = 'active'"
```

Leave the rest of the method (the `Row.fetchAll` and the `KNNResult` mapping) exactly as it is.

- [ ] **Step 4: Update the one call site**

In `Sources/PensieveKit/Query/SemanticQueries.swift` line 44, change:

```swift
      let raw = store.knn(query: qvec, k: kFetch, activeOnly: true)
```

to:

```swift
      let raw = store.knn(query: qvec, k: kFetch, includeArchived: false)
```

This is a pure rename — behaviour is byte-for-byte identical. Task 3 replaces the literal with the threaded parameter.

- [ ] **Step 5: Run the tests to verify they pass**

Run: `./scripts/test.sh --filter Semantic`
Expected: PASS — `SemanticIndexStoreTests`, `SemanticIndexerTests`, and `SemanticQueriesTests` all green. `SemanticQueriesTests` passing unchanged is the proof that Step 4 was behaviour-preserving.

- [ ] **Step 6: Run the full suite and commit**

Run: `./scripts/test.sh`
Expected: 453 tests passing (451 + 2).

```bash
git add Sources/PensieveKit/Semantic/SemanticIndexStore.swift Sources/PensieveKit/Query/SemanticQueries.swift Tests/PensieveKitTests/SemanticIndexStoreTests.swift
git commit -F - <<'EOF'
feat(semantic): knn takes includeArchived instead of activeOnly

An allow-list filter over state: false selects active only (identical to
the old activeOnly: true), true widens to active + archived. muted is
excluded in both modes by construction.

Also pins that an archive flip is metadata-only: both flips upsert with a
nil embedding, so the row staying KNN-reachable proves the original
vector survived rather than being dropped and rebuilt.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_0158f2aPXJBVpcfa36bE9o2d
EOF
```

---

### Task 3: `SemanticQueries.search(includeArchived:)` end to end

**Files:**
- Modify: `Sources/PensieveKit/Query/SemanticQueries.swift` (the `SemanticHit` struct, `search`, `buildHits`, `resolve`)
- Test: `Tests/PensieveKitTests/SemanticQueriesTests.swift`

**Interfaces:**
- Consumes: `SemanticIndexStore.knn(query:k:includeArchived:)` from Task 2; the archived corpus from Task 1.
- Produces:
  - `SemanticHit` gains `public let isArchived: Bool` as its **last** stored property (memberwise init order: `id, kind, nodeID, nodeName, title, snippet, similarity, isArchived`).
  - `SemanticQueries.search(query:visibleNodeIDs:excludingIDs:k:floor:includeArchived:store:embedder:_ db:)` — `includeArchived: Bool = false`, positioned after `floor:` and before `store:`. Defaulted so every existing call site compiles and behaves identically.

**Why the resolve predicate must widen in lockstep:** `resolve` re-checks each survivor against canonical — the grounding defense that stops a stale index row surfacing a dead hit. If `knn` widens and `resolve` does not, archived rows pass the index filter and are then silently dropped, which reads as a broken feature rather than a loud failure.

- [ ] **Step 1: Write the failing tests**

Add to `Tests/PensieveKitTests/SemanticQueriesTests.swift`, inside `@Suite struct SemanticQueriesTests`:

```swift
  /// Indexes one active + one archived node whose names are near-identical, so both are plausible
  /// KNN neighbours of the same query and only the state filter can separate them.
  private func archivedFixture() async throws -> (db: any DatabaseWriter, store: SemanticIndexStore,
                                                  embedder: StubEmbedder, active: Node, archived: Node) {
    let db = try openCanonicalDatabase(at: tempURL("semq-archived"))
    let active = Node(name: "Refund handling", kind: NodeKind.project)
    let archived = Node(name: "Refund handling legacy", state: .archived, kind: NodeKind.project)
    try await db.write { db in
      try Node.insert { active }.execute(db)
      try Node.insert { archived }.execute(db)
    }
    let embedder = StubEmbedder(dimension: 16)
    let s = store()
    await SemanticIndexer(store: s, embedder: embedder).sync(db)
    return (db, s, embedder, active, archived)
  }

  @Test func searchExcludesArchivedByDefault() async throws {
    let f = try await archivedFixture()
    let visible: Set<UUID> = [f.active.id, f.archived.id]

    // No includeArchived argument at all — the defaulted-parameter regression guard for every
    // existing call site.
    let hits = await SemanticQueries.search(
      query: "Refund handling legacy", visibleNodeIDs: visible, excludingIDs: [],
      k: 8, floor: -1.0, store: f.store, embedder: f.embedder, f.db)

    #expect(!hits.contains { $0.id == f.archived.id })
    #expect(hits.allSatisfy { !$0.isArchived })
  }

  @Test func searchSurfacesArchivedWhenAsked() async throws {
    let f = try await archivedFixture()
    let visible: Set<UUID> = [f.active.id, f.archived.id]

    let hits = await SemanticQueries.search(
      query: "Refund handling legacy", visibleNodeIDs: visible, excludingIDs: [],
      k: 8, floor: -1.0, includeArchived: true, store: f.store, embedder: f.embedder, f.db)

    let archivedHit = hits.first { $0.id == f.archived.id }
    #expect(archivedHit != nil)
    #expect(archivedHit?.isArchived == true)
    #expect(hits.first { $0.id == f.active.id }?.isArchived == false)
  }

  @Test func archivedLooseEndsAndEventsAlsoResolveWhenAsked() async throws {
    let db = try openCanonicalDatabase(at: tempURL("semq-archived-children"))
    let archived = Node(name: "Legacy billing", state: .archived, kind: NodeKind.project)
    try await db.write { try Node.insert { archived }.execute($0) }
    let ev = try makeEvent(db, node: archived, kind: CaptureKind.ccSession,
                           workSummary: "migrated the old invoices")
    let le = LooseEnd(nodeID: archived.id, sourceEventID: ev.id,
                      text: "drop the legacy invoice table", quote: "TODO drop invoices")
    try await db.write { try LooseEnd.insert { le }.execute($0) }

    let embedder = StubEmbedder(dimension: 16)
    let s = store()
    await SemanticIndexer(store: s, embedder: embedder).sync(db)

    let hits = await SemanticQueries.search(
      query: "drop the legacy invoice table", visibleNodeIDs: [archived.id], excludingIDs: [],
      k: 8, floor: -1.0, includeArchived: true, store: s, embedder: embedder, db)

    // All three item kinds under an archived node resolve, and every one is flagged archived.
    #expect(hits.contains { $0.id == le.id && $0.kind == "loose_end" })
    #expect(hits.contains { $0.id == ev.id && $0.kind == "event" })
    #expect(hits.contains { $0.id == archived.id && $0.kind == "node" })
    #expect(hits.allSatisfy { $0.isArchived })
  }
```

`floor: -1.0` admits every neighbour regardless of similarity — the stub embedder's vectors are pseudo-random, so a realistic floor would make these tests depend on hash luck. Membership and the `isArchived` flag are what is under test here, not ranking.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `./scripts/test.sh --filter SemanticQueriesTests`
Expected: COMPILE FAILURE — no `includeArchived:` parameter on `search`, and no `isArchived` member on `SemanticHit`.

- [ ] **Step 3: Add `isArchived` to `SemanticHit`**

In `Sources/PensieveKit/Query/SemanticQueries.swift`, replace the struct:

```swift
public struct SemanticHit: Identifiable, Sendable, Equatable {
  public let id: UUID           // node id / loose-end id / event id
  public let kind: String       // "node" | "loose_end" | "event"
  public let nodeID: UUID
  public let nodeName: String
  public let title: String      // node name / loose-end text / event summary
  public let snippet: Snippet
  public let similarity: Double
}
```

with:

```swift
public struct SemanticHit: Identifiable, Sendable, Equatable {
  public let id: UUID           // node id / loose-end id / event id
  public let kind: String       // "node" | "loose_end" | "event"
  public let nodeID: UUID
  public let nodeName: String
  public let title: String      // node name / loose-end text / event summary
  public let snippet: Snippet
  public let similarity: Double
  /// The owning node is archived — the view badges the row. Always false unless the caller
  /// opted into archived results.
  public let isArchived: Bool
}
```

- [ ] **Step 4: Thread `includeArchived` through `search` and `buildHits`**

In the same file, change the `search` signature and its `knn` + `buildHits` calls:

```swift
  public static func search(query rawQuery: String,
                            visibleNodeIDs: Set<UUID>,
                            excludingIDs: Set<UUID>,
                            k: Int,
                            floor: Double,
                            includeArchived: Bool = false,
                            store: SemanticIndexStore,
                            embedder: any TextEmbedder,
                            _ db: any DatabaseReader) async -> [SemanticHit] {
```

Inside the fetch loop, replace:

```swift
      let raw = store.knn(query: qvec, k: kFetch, includeArchived: false)
      let hits = buildHits(raw, k: k, floor: floor, visibleNodeIDs: visibleNodeIDs,
                           excludingIDs: excludingIDs, query: query, db)
```

with:

```swift
      let raw = store.knn(query: qvec, k: kFetch, includeArchived: includeArchived)
      let hits = buildHits(raw, k: k, floor: floor, visibleNodeIDs: visibleNodeIDs,
                           excludingIDs: excludingIDs, includeArchived: includeArchived,
                           query: query, db)
```

Then change `buildHits`' signature and its `resolve` call:

```swift
  private static func buildHits(_ raw: [KNNResult], k: Int, floor: Double,
                                visibleNodeIDs: Set<UUID>, excludingIDs: Set<UUID>,
                                includeArchived: Bool,
                                query: String, _ db: any DatabaseReader) -> [SemanticHit] {
```

and inside its loop:

```swift
      guard let hit = try? resolve(kind: r.kind, itemID: itemID, similarity: r.similarity,
                                   includeArchived: includeArchived, query: query, db) else { continue }
```

- [ ] **Step 5: Widen the resolve predicate**

Replace the whole `resolve` method with:

```swift
  /// Re-resolve one index row against canonical — the last grounding defense, so a between-sync
  /// stale row never surfaces a dead hit. The state predicate MUST mirror the `knn` filter: if the
  /// index widens to archived but this does not, archived rows pass KNN and are then silently
  /// dropped here. Same predicate shape as `SearchQueries` uses for exact search.
  private static func resolve(kind: String, itemID: UUID, similarity: Double,
                              includeArchived: Bool, query: String,
                              _ db: any DatabaseReader) throws -> SemanticHit? {
    func eligible(_ n: Node) -> Bool {
      n.state == .active || (includeArchived && n.state == .archived)
    }
    return try db.read { db in
      switch kind {
      case "node":
        guard let n = try Node.where { $0.id.eq(itemID) }.fetchOne(db), eligible(n) else { return nil }
        return SemanticHit(id: n.id, kind: kind, nodeID: n.id, nodeName: n.name, title: n.name,
                           snippet: SnippetMaker.make(from: n.description.isEmpty ? n.name : n.description, matching: query),
                           similarity: similarity, isArchived: n.state == .archived)
      case "loose_end":
        guard let le = try LooseEnd.where { $0.id.eq(itemID) && LooseEnd.isOpen($0) }.fetchOne(db),
              let n = try Node.where { $0.id.eq(le.nodeID) }.fetchOne(db), eligible(n) else { return nil }
        return SemanticHit(id: le.id, kind: kind, nodeID: le.nodeID, nodeName: n.name, title: le.text,
                           snippet: SnippetMaker.make(from: le.text, matching: query),
                           similarity: similarity, isArchived: n.state == .archived)
      case "event":
        guard let e = try Event.where { $0.id.eq(itemID) }.fetchOne(db),
              let n = try Node.where { $0.id.eq(e.nodeID) }.fetchOne(db), eligible(n) else { return nil }
        let body = (e.workSummary?.isEmpty == false ? e.workSummary! : e.summary)
        return SemanticHit(id: e.id, kind: kind, nodeID: e.nodeID, nodeName: n.name, title: body,
                           snippet: SnippetMaker.make(from: body, matching: query),
                           similarity: similarity, isArchived: n.state == .archived)
      default: return nil
      }
    }
  }
```

Finally, update the `public enum SemanticQueries` doc comment — after the sentence ending `…as a last line of grounding defense`, append:

```swift
/// Archived items are indexed but excluded by default: `includeArchived` widens BOTH the index
/// filter and this canonical re-check, in lockstep. `muted` is never returned.
```

- [ ] **Step 6: Run the tests to verify they pass**

Run: `./scripts/test.sh --filter SemanticQueriesTests`
Expected: PASS, including every pre-existing test (they call `search` without the new argument — the defaulted-parameter guard).

- [ ] **Step 7: Run the full suite and commit**

Run: `./scripts/test.sh`
Expected: 456 tests passing (453 + 3).

```bash
git add Sources/PensieveKit/Query/SemanticQueries.swift Tests/PensieveKitTests/SemanticQueriesTests.swift
git commit -F - <<'EOF'
feat(semantic): includeArchived on SemanticQueries.search

Widens the index filter and the canonical re-resolve predicate in
lockstep -- if only the former widened, archived rows would pass KNN and
be silently dropped on resolve. Defaulted false, so every existing call
site keeps its exact behaviour.

SemanticHit gains isArchived, taken from the state resolve already
fetched, so the view can badge without a second lookup.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_0158f2aPXJBVpcfa36bE9o2d
EOF
```

---

### Task 4: `isArchived` on the exact-search hits

**Files:**
- Modify: `Sources/PensieveKit/Query/SearchQueries.swift` (`NodeHit`, `LooseEndHit`, and the two hit-construction sites)
- Test: `Tests/PensieveKitTests/SearchQueriesTests.swift`

**Interfaces:**
- Consumes: nothing from Tasks 1-3 (independent of the semantic path).
- Produces: `NodeHit` gains `public var isArchived: Bool` as its **last** stored property (memberwise order: `id, name, kind, matchedField, snippet, isArchived`). `LooseEndHit` gains `public var isArchived: Bool` last (memberwise order: `id, nodeID, nodeName, snippet, isArchived`). Both are `false` unless the owning node's state is `.archived`.

**Why:** exact ⌘F has surfaced archived rows since the Include Archived toggle shipped, rendering them indistinguishably from live work. Task 5 badges all three row types; this supplies the two exact ones with the fact.

- [ ] **Step 1: Write the failing test**

Add to `Tests/PensieveKitTests/SearchQueriesTests.swift`, inside the existing `@Suite`:

```swift
  @Test func hitsCarryTheOwningNodesArchivedFlag() async throws {
    let db = try openCanonicalDatabase(at: tempURL("search-archived-flag"))
    let active = Node(name: "Refund handling", kind: NodeKind.project)
    let archived = Node(name: "Refund handling legacy", state: .archived, kind: NodeKind.project)
    try await db.write { db in
      try Node.insert { active }.execute(db)
      try Node.insert { archived }.execute(db)
    }
    let ev = try makeEvent(db, node: archived)
    let le = LooseEnd(nodeID: archived.id, sourceEventID: ev.id,
                      text: "refund the last batch", quote: "TODO refund")
    try await db.write { try LooseEnd.insert { le }.execute($0) }

    let r = try SearchQueries.search(query: "refund", visibleNodeIDs: [active.id, archived.id],
                                     includeArchived: true, db)

    #expect(r.nodes.first { $0.id == active.id }?.isArchived == false)
    #expect(r.nodes.first { $0.id == archived.id }?.isArchived == true)
    #expect(r.looseEnds.first { $0.id == le.id }?.isArchived == true)
  }
```

If `SearchQueriesTests.swift` has no `makeEvent` helper at file scope, copy the one from the top of `SemanticQueriesTests.swift` verbatim into this file (it is already duplicated across suites in this codebase — follow that existing pattern rather than introducing a shared helper).

- [ ] **Step 2: Run the test to verify it fails**

Run: `./scripts/test.sh --filter SearchQueriesTests`
Expected: COMPILE FAILURE — `value of type 'NodeHit' has no member 'isArchived'`.

- [ ] **Step 3: Add the fields**

In `Sources/PensieveKit/Query/SearchQueries.swift`, add to `NodeHit` after `snippet`:

```swift
  public var snippet: Snippet
  /// The node is archived — the view badges the row (archived hits surface only when the caller
  /// passed `includeArchived`).
  public var isArchived: Bool
```

and to `LooseEndHit` after `snippet`:

```swift
  public var snippet: Snippet
  /// The owning node is archived — the view badges the row.
  public var isArchived: Bool
```

- [ ] **Step 4: Populate them at the two construction sites**

In the NODES block, replace:

```swift
        return NodeHit(id: e.node.id, name: e.node.name, kind: e.node.kind,
                       matchedField: e.rank == 0 ? .name : .description,
                       snippet: SnippetMaker.make(from: src, matching: query))
```

with:

```swift
        return NodeHit(id: e.node.id, name: e.node.name, kind: e.node.kind,
                       matchedField: e.rank == 0 ? .name : .description,
                       snippet: SnippetMaker.make(from: src, matching: query),
                       isArchived: e.node.state == .archived)
```

In the LOOSE ENDS block, the hit is built from `nameByID` and has no node in hand, so add a state lookup next to it. Replace:

```swift
      let nameByID = Dictionary(nodes.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
```

with:

```swift
      let nameByID = Dictionary(nodes.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
      let archivedNodeIDs = Set(nodes.filter { $0.state == .archived }.map { $0.id })
```

and replace:

```swift
        return LooseEndHit(id: e.le.id, nodeID: e.le.nodeID,
                           nodeName: nameByID[e.le.nodeID] ?? "",
                           snippet: SnippetMaker.make(from: src, matching: query))
```

with:

```swift
        return LooseEndHit(id: e.le.id, nodeID: e.le.nodeID,
                           nodeName: nameByID[e.le.nodeID] ?? "",
                           snippet: SnippetMaker.make(from: src, matching: query),
                           isArchived: archivedNodeIDs.contains(e.le.nodeID))
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `./scripts/test.sh --filter SearchQueriesTests`
Expected: PASS. If any pre-existing test constructs a `NodeHit`/`LooseEndHit` literal, it will now fail to compile — add `isArchived: false` to those literals.

- [ ] **Step 6: Run the full suite and commit**

Run: `./scripts/test.sh`
Expected: 457 tests passing (456 + 1).

```bash
git add Sources/PensieveKit/Query/SearchQueries.swift Tests/PensieveKitTests/SearchQueriesTests.swift
git commit -F - <<'EOF'
feat(search): carry the owning node's archived flag on exact hits

Exact search has surfaced archived rows since the Include Archived
toggle shipped, rendering them indistinguishably from live work. The
hits now carry the fact so the view can badge them.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_0158f2aPXJBVpcfa36bE9o2d
EOF
```

---

### Task 5: App — scope-aware Related + the Archived badge

**Files:**
- Modify: `Sources/PensieveApp/AppModel.swift:530-532` (the `SemanticQueries.search` call)
- Modify: `Sources/PensieveApp/ContentListView.swift:55-109` (three row types)
- Modify: `Sources/PensieveApp/Localizable.xcstrings`
- No tests (app target has no unit tests — see Global Constraints)

**Interfaces:**
- Consumes: `SemanticQueries.search(…includeArchived:…)` and `SemanticHit.isArchived` (Task 3); `NodeHit.isArchived` / `LooseEndHit.isArchived` (Task 4).
- Produces: nothing later tasks depend on.

- [ ] **Step 1: Pass the scope to the semantic call**

In `Sources/PensieveApp/AppModel.swift`, inside `runSearch`, replace:

```swift
      let sem = await SemanticQueries.search(
        query: query, visibleNodeIDs: visible, excludingIDs: exact, k: 8, floor: 0.25,
        store: self.semanticStore, embedder: self.embedder, db)
```

with:

```swift
      let sem = await SemanticQueries.search(
        query: query, visibleNodeIDs: visible, excludingIDs: exact, k: 8, floor: 0.25,
        includeArchived: includeArchived,
        store: self.semanticStore, embedder: self.embedder, db)
```

`includeArchived` is the existing pre-Task local (already captured above for the exact call), so nothing new needs snapshotting — reading `self.searchScope` off-main here would be an isolation violation.

- [ ] **Step 2: Add the badge view**

Add to `Sources/PensieveApp/ContentListView.swift`, at file scope below the existing view struct:

```swift
/// A small trailing marker on a search row whose owning node is archived, so archived work is never
/// mistaken for live work. Rendered only when the Include Archived scope surfaced the row.
private struct ArchivedBadge: View {
  var body: some View {
    Text("Archived")
      .font(.caption2)
      .padding(.horizontal, 5)
      .padding(.vertical, 1)
      .background(.quaternary, in: Capsule())
      .foregroundStyle(.secondary)
  }
}
```

- [ ] **Step 3: Render it on the three row types**

In the "Projects" section, wrap the row content so the badge sits trailing. Replace:

```swift
              HStack(spacing: 10) {
                if let n = model.node(hit.id) { NodeBadge(node: n, size: 22) }
                VStack(alignment: .leading, spacing: 2) {
```

with:

```swift
              HStack(spacing: 10) {
                if let n = model.node(hit.id) { NodeBadge(node: n, size: 22) }
                VStack(alignment: .leading, spacing: 2) {
```

(unchanged), and then, immediately after the closing brace of that inner `VStack` and before `}` of the `HStack`, insert:

```swift
                }
                if hit.isArchived { Spacer(); ArchivedBadge() }
              }
```

so the `HStack` ends `… } if hit.isArchived { Spacer(); ArchivedBadge() } }`.

In the "Loose Ends" section, replace:

```swift
              VStack(alignment: .leading, spacing: 2) {
                Text(hit.nodeName).font(.caption).foregroundStyle(.secondary)
                SnippetText(snippet: hit.snippet)
              }
              .rowHitArea()
```

with:

```swift
              VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                  Text(hit.nodeName).font(.caption).foregroundStyle(.secondary)
                  if hit.isArchived { ArchivedBadge() }
                }
                SnippetText(snippet: hit.snippet)
              }
              .rowHitArea()
```

In the "Related" section, replace:

```swift
              VStack(alignment: .leading, spacing: 2) {
                Text(hit.nodeName).font(.caption).foregroundStyle(.secondary)
                Text(hit.title).lineLimit(2)
              }
              .rowHitArea()
```

with:

```swift
              VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                  Text(hit.nodeName).font(.caption).foregroundStyle(.secondary)
                  if hit.isArchived { ArchivedBadge() }
                }
                Text(hit.title).lineLimit(2)
              }
              .rowHitArea()
```

- [ ] **Step 4: Add the String Catalog key**

In `Sources/PensieveApp/Localizable.xcstrings`, add a key `"Archived"` in the same shape as the existing `"Include Archived"` entry (keys are alphabetically ordered — place it accordingly):

```json
    "Archived" : {
      "extractionState" : "manual",
      "localizations" : {
        "de" : {
          "stringUnit" : {
            "state" : "translated",
            "value" : "Archiviert"
          }
        }
      }
    },
```

Check first whether an `"Archived"` key already exists (the sidebar has an Archived section) — if it does, reuse it and add nothing.

- [ ] **Step 5: Build and smoke-launch**

```bash
xcodegen generate
xcodebuild -project Pensieve.xcodeproj -scheme Pensieve -configuration Debug -derivedDataPath ./.build-xcode build 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`.

```bash
PENSIEVE_DB=/tmp/smoke-arch.sqlite PENSIEVE_CAPTURE_DB=/tmp/smoke-arch-capture.sqlite \
  ./.build-xcode/Build/Products/Debug/Pensieve.app/Contents/MacOS/Pensieve &
sleep 5; kill %1
```

Expected: launches and stays up for the 5 s without crashing. Discard any transient `Package.resolved` churn the xcodebuild introduces (`git checkout -- Package.resolved` if it appears — the MarkdownUI dep is xcodebuild-only by design).

- [ ] **Step 6: Verify the `de` string actually landed in the bundle**

```bash
plutil -p ./.build-xcode/Build/Products/Debug/Pensieve.app/Contents/Resources/de.lproj/Localizable.strings | grep -i archiv
```

Expected: a line containing `"Archived" => "Archiviert"`. A mis-keyed `de` value silently falls back to English, which is why this check exists.

- [ ] **Step 7: Commit**

```bash
git add Sources/PensieveApp/AppModel.swift Sources/PensieveApp/ContentListView.swift Sources/PensieveApp/Localizable.xcstrings
git commit -F - <<'EOF'
feat(app): scope-aware Related results + an Archived badge

The Include Archived search scope now drives the semantic half of the
search box as well as the exact half. All three row types badge rows
whose owning node is archived, so archived work is never mistaken for
live work.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_0158f2aPXJBVpcfa36bE9o2d
EOF
```

---

### Task 6: MCP `include_archived` parameter

**Files:**
- Modify: `Sources/pensieve/Commands/Mcp.swift:39-45` (tool schema), `:74-81` (handler), `:197-218` (`searchJSON`)
- No tests (the MCP command layer is thin over tested Kit kernels; verify by build + a live tool call)

**Interfaces:**
- Consumes: `SearchQueries.search(…includeArchived:…)` and `SemanticQueries.search(…includeArchived:…)`.
- Produces: `PensieveMCP.searchJSON(query:limit:includeArchived:) async throws -> Data`.

- [ ] **Step 1: Declare the parameter in the tool schema**

In `Sources/pensieve/Commands/Mcp.swift`, replace the `search` tool's `properties` object:

```swift
             inputSchema: .object(["type": .string("object"), "properties": .object([
               "query": .object(["type": .string("string"), "description": .string("what to find")]),
               "limit": .object(["type": .string("number"), "description": .string("max results per group (default 8)")]),
             ]), "required": .array([.string("query")])]),
```

with:

```swift
             inputSchema: .object(["type": .string("object"), "properties": .object([
               "query": .object(["type": .string("string"), "description": .string("what to find")]),
               "limit": .object(["type": .string("number"), "description": .string("max results per group (default 8)")]),
               "include_archived": .object(["type": .string("boolean"), "description": .string("also search archived projects (default false)")]),
             ]), "required": .array([.string("query")])]),
```

- [ ] **Step 2: Read it in the handler**

Replace:

```swift
        let limit = params.arguments?["limit"]?.intValue ?? 8
        let json = try await PensieveMCP.searchJSON(query: query, limit: limit)
```

with:

```swift
        let limit = params.arguments?["limit"]?.intValue ?? 8
        let includeArchived = params.arguments?["include_archived"]?.boolValue ?? false
        let json = try await PensieveMCP.searchJSON(query: query, limit: limit,
                                                    includeArchived: includeArchived)
```

- [ ] **Step 3: Thread it through `searchJSON`**

Replace the signature and the node-set/query calls:

```swift
  static func searchJSON(query: String, limit: Int) async throws -> Data {
    guard let db = try? openCanonicalReadOnly() else {
      return try makeEncoder().encode(SearchPayload(exact: [], related: []))
    }
    let allActive = try await db.read { db in
      Set(try Node.where { $0.state.eq(NodeState.active) }.fetchAll(db).map { $0.id })
    }
    let exact = try SearchQueries.search(query: query, visibleNodeIDs: allActive, db)
    let exactIDs = Set(exact.nodes.map { $0.id } + exact.looseEnds.map { $0.id })

    let related: [SemanticHit]
    if PensieveDefaults.semanticSearchEnabled() {
      related = await SemanticQueries.search(query: query, visibleNodeIDs: allActive, excludingIDs: exactIDs,
                                             k: limit, floor: 0.25, store: semanticStore,
                                             embedder: semanticEmbedder, db)
    } else {
      related = []
    }
```

with:

```swift
  static func searchJSON(query: String, limit: Int, includeArchived: Bool = false) async throws -> Data {
    guard let db = try? openCanonicalReadOnly() else {
      return try makeEncoder().encode(SearchPayload(exact: [], related: []))
    }
    // The visible set must widen with the flag: it gates BOTH halves, so leaving it active-only
    // would filter archived hits back out after the query layer allowed them through.
    let visible = try await db.read { db -> Set<UUID> in
      let nodes = try Node.all.fetchAll(db)
      return Set(nodes.filter {
        $0.state == .active || (includeArchived && $0.state == .archived)
      }.map { $0.id })
    }
    let exact = try SearchQueries.search(query: query, visibleNodeIDs: visible,
                                         includeArchived: includeArchived, db)
    let exactIDs = Set(exact.nodes.map { $0.id } + exact.looseEnds.map { $0.id })

    let related: [SemanticHit]
    if PensieveDefaults.semanticSearchEnabled() {
      related = await SemanticQueries.search(query: query, visibleNodeIDs: visible, excludingIDs: exactIDs,
                                             k: limit, floor: 0.25, includeArchived: includeArchived,
                                             store: semanticStore, embedder: semanticEmbedder, db)
    } else {
      related = []
    }
```

Then update the doc comment above `searchJSON` — replace `Scope is all active nodes (MCP has no Focus context).` with:

```swift
  /// Scope is all active nodes (MCP has no Focus context), widened to archived by `include_archived`,
  /// which gates the exact and semantic halves alike.
```

- [ ] **Step 4: Build the CLI**

```bash
xcodebuild -project Pensieve.xcodeproj -scheme PensieveCLI -configuration Debug -derivedDataPath ./.build-xcode build 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Verify the tool responds over stdio**

```bash
printf '%s\n' \
  '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"t","version":"1"}}}' \
  '{"jsonrpc":"2.0","method":"notifications/initialized"}' \
  '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}' \
  | ./.build-xcode/Build/Products/Debug/pensieve mcp 2>/dev/null | grep -o 'include_archived'
```

Expected: prints `include_archived`, confirming the parameter is advertised in the tool schema. This reads the real store read-only, which is safe — do NOT set `PENSIEVE_DB` here, and do not use a write path.

- [ ] **Step 6: Run the full suite and commit**

Run: `./scripts/test.sh`
Expected: 457 tests passing (unchanged from Task 4 — this task adds no Kit tests).

```bash
git add Sources/pensieve/Commands/Mcp.swift
git commit -F - <<'EOF'
feat(mcp): include_archived on the search tool

Widens the visible node set and both query halves together -- leaving the
visible set active-only would filter archived hits back out after the
query layer allowed them through. Default false, so agent-facing context
stays focused on live work unless asked.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_0158f2aPXJBVpcfa36bE9o2d
EOF
```

---

## Done criteria

- `./scripts/test.sh` → **457 tests passing** (448 baseline + 9).
- `xcodebuild` succeeds for both the `Pensieve` and `PensieveCLI` schemes; the app smoke-launches.
- Default behaviour is provably unchanged: every pre-existing `SemanticQueries.search` / `SearchQueries.search` call site compiles untouched and its tests pass.
- `muted` appears in no result set, in either filter mode.

## Post-merge carries

- **Rebuild + reinstall to `/Applications`** so the bundled `pensieve mcp` advertises `include_archived` and the app shows the badge.
- **First sync after the merge does a one-time embedding pass** over all archived content (on-device, via the background agent). Watch `tail -f ~/Library/Logs/Pensieve/sync.log` if it seems slow on the first run.

## Human-verify carries

Need the built app at `/Applications`, the real store, and a plain `open`:

- Archived work appears under "Related" only when the Include Archived scope is on.
- The Archived badge renders in all three row types and is legible in light and dark.
- German in-situ: the badge reads "Archiviert".
- `include_archived` through the registered `pensieve mcp` returns archived hits; the default call does not.
- Archive a node with indexed content, wait for a sync, unarchive it — it returns to default-scope Related results (the metadata-only flip path, exercised against the real embedder rather than the stub).
