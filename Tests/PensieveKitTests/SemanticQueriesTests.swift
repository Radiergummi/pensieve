import Testing
import Foundation
import SQLiteData
@testable import PensieveKit

/// Inserts a Source + Event under `node` so a LooseEnd's sourceEventID FK is satisfiable
/// (looseEnds.sourceEventID REFERENCES events(id), and GRDB enforces foreign keys by default).
/// Mirrors the helper in SemanticIndexerTests.swift.
private func makeEvent(_ db: any DatabaseWriter, node: Node, kind: String = CaptureKind.gitCommit,
                       summary: String = "did a thing", workSummary: String? = nil) throws -> Event {
  let source = Source(nodeID: node.id, kind: SourceKind.gitRepo, key: "/p/\(node.id)")
  let event = Event(nodeID: node.id, sourceID: source.id, occurredAt: Date(), kind: kind,
                    summary: summary, detailJSON: "{}", workSummary: workSummary)
  try db.write { db in
    try Source.insert { source }.execute(db)
    try Event.insert { event }.execute(db)
  }
  return event
}

@Suite struct SemanticQueriesTests {
  private func store() -> SemanticIndexStore {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("semq-\(UUID().uuidString).sqlite")
    return SemanticIndexStore(url: url, dimension: 16, embedderVersion: "stub:16")
  }

  @Test func focusMutingDoesNotZeroOutVisibleHits() async throws {
    let db = try openCanonicalDatabase(at: tempURL("semq-mute"))
    let visible = Node(name: "Visible refunds work", kind: NodeKind.project)
    let muted = Node(name: "Muted refunds work", kind: NodeKind.project, context: "personal")
    try await db.write { db in
      try Node.insert { visible }.execute(db)
      try Node.insert { muted }.execute(db)
    }
    let embedder = StubEmbedder(dimension: 16)
    let s = store()
    await SemanticIndexer(store: s, embedder: embedder).sync(db)

    let hits = await SemanticQueries.search(
      query: "refunds", visibleNodeIDs: [visible.id], excludingIDs: [], k: 5, floor: -1.0,
      store: s, embedder: embedder, db)
    #expect(hits.contains { $0.nodeID == visible.id })
    #expect(!hits.contains { $0.nodeID == muted.id })    // muted node filtered out post-KNN
  }

  /// Regression guard for the over-fetch itself: builds a corpus where MORE muted-context items
  /// outrank the one visible item than `k`, so a NON-over-fetched (`kPrime == k`) KNN would
  /// exclude the visible node before the Focus filter ever runs. Exploits StubEmbedder's
  /// determinism — an item whose embeddable text is IDENTICAL to the query embeds to the SAME
  /// vector (cosine ~1.0), guaranteeing it ranks above the visible node's (different-text, lower
  /// cosine) hit for any k <= the muted count.
  @Test func overFetchSurfacesVisibleHitRankedBelowMutedTop() async throws {
    let db = try openCanonicalDatabase(at: tempURL("semq-overfetch"))
    let query = "refunds pipeline overhaul"
    let visible = Node(name: "Something entirely different", kind: NodeKind.project)
    let mutedA = Node(name: query, kind: NodeKind.project, context: "personal")
    let mutedB = Node(name: query, kind: NodeKind.project, context: "personal")
    let mutedC = Node(name: query, kind: NodeKind.project, context: "personal")
    try await db.write { db in
      try Node.insert { visible }.execute(db)
      try Node.insert { mutedA }.execute(db)
      try Node.insert { mutedB }.execute(db)
      try Node.insert { mutedC }.execute(db)
    }
    let embedder = StubEmbedder(dimension: 16)
    let s = store()
    await SemanticIndexer(store: s, embedder: embedder).sync(db)

    // 3 muted nodes tie at cosine 1.0, outranking the visible node for k=2 — only the over-fetch
    // (kPrime = max(k*8, 50)) reaches past them to find it.
    let hits = await SemanticQueries.search(
      query: query, visibleNodeIDs: [visible.id], excludingIDs: [], k: 2, floor: -1.0,
      store: s, embedder: embedder, db)
    #expect(hits.contains { $0.nodeID == visible.id })
  }

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

  @Test func staleIndexRowDroppedByJoin() async throws {
    let db = try openCanonicalDatabase(at: tempURL("semq-stale"))
    let n = Node(name: "N", kind: NodeKind.project)
    try await db.write { try Node.insert { n }.execute($0) }
    let ev = try makeEvent(db, node: n)
    let le = LooseEnd(nodeID: n.id, sourceEventID: ev.id, text: "refund flow", quote: "q")
    try await db.write { try LooseEnd.insert { le }.execute($0) }

    let embedder = StubEmbedder(dimension: 16)
    let s = store()
    await SemanticIndexer(store: s, embedder: embedder).sync(db)

    // Simulate between-sync drift: noise-label the loose end in canonical WITHOUT re-syncing the index.
    try await db.write { db in
      try LooseEnd.where { $0.id.eq(le.id) }.update { $0.label = "noise" }.execute(db)
    }

    let hits = await SemanticQueries.search(
      query: "refund flow", visibleNodeIDs: [n.id], excludingIDs: [], k: 5, floor: -1.0,
      store: s, embedder: embedder, db)
    #expect(!hits.contains { $0.id == le.id })           // join re-applies isOpen → dropped
  }

  @Test func floorDropsWeakMatches() async throws {
    let db = try openCanonicalDatabase(at: tempURL("semq-floor"))
    let n = Node(name: "Refunds pipeline work", kind: NodeKind.project)
    try await db.write { try Node.insert { n }.execute($0) }
    let embedder = StubEmbedder(dimension: 16)
    let s = store()
    await SemanticIndexer(store: s, embedder: embedder).sync(db)

    // An impossibly high floor (above the max cosine similarity of 1.0) must drop everything.
    let hits = await SemanticQueries.search(
      query: "refunds", visibleNodeIDs: [n.id], excludingIDs: [], k: 5, floor: 1.01,
      store: s, embedder: embedder, db)
    #expect(hits.isEmpty)
  }

  @Test func excludingIDsDedupesAgainstExactHits() async throws {
    let db = try openCanonicalDatabase(at: tempURL("semq-exclude"))
    let n = Node(name: "Refunds pipeline work", kind: NodeKind.project)
    try await db.write { try Node.insert { n }.execute($0) }
    let embedder = StubEmbedder(dimension: 16)
    let s = store()
    await SemanticIndexer(store: s, embedder: embedder).sync(db)

    let hits = await SemanticQueries.search(
      query: "refunds", visibleNodeIDs: [n.id], excludingIDs: [n.id], k: 5, floor: -1.0,
      store: s, embedder: embedder, db)
    #expect(!hits.contains { $0.id == n.id })
  }

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
}
