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
}
