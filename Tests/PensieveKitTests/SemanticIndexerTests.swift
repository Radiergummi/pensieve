import Testing
import Foundation
import SQLiteData
@testable import PensieveKit

/// Inserts a Source + Event under `node` so a LooseEnd's sourceEventID FK is satisfiable
/// (looseEnds.sourceEventID REFERENCES events(id), and GRDB enforces foreign keys by default).
private func makeEvent(_ db: any DatabaseWriter, node: Node, kind: String = CaptureKind.gitCommit,
                       summary: String = "did a thing", workSummary: String? = nil) throws -> Event {
  // Unique per call — sources.(key, kind) is UNIQUE, so several events under one node need several sources.
  let source = Source(nodeID: node.id, kind: SourceKind.gitRepo, key: "/p/\(node.id)/\(UUID())")
  let event = Event(nodeID: node.id, sourceID: source.id, occurredAt: Date(), kind: kind,
                    summary: summary, detailJSON: "{}", workSummary: workSummary)
  try db.write { db in
    try Source.insert { source }.execute(db)
    try Event.insert { event }.execute(db)
  }
  return event
}

@Suite struct SemanticIndexerTests {
  private func store() -> SemanticIndexStore {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("semidx-\(UUID().uuidString).sqlite")
    return SemanticIndexStore(url: url, dimension: 16, embedderVersion: "stub:16")
  }

  @Test func indexesActiveNodesOpenLooseEndsAndEnrichedEvents() async throws {
    let db = try openCanonicalDatabase(at: tempURL("semidx-add"))
    let n = Node(name: "Payments", kind: NodeKind.project)
    try await db.write { try Node.insert { n }.execute($0) }
    let ev = try makeEvent(db, node: n, kind: CaptureKind.ccSession, workSummary: "wired up refunds")
    let le = LooseEnd(nodeID: n.id, sourceEventID: ev.id, text: "wire up refunds", quote: "TODO refunds")
    try await db.write { try LooseEnd.insert { le }.execute($0) }

    let s = store()
    let idx = SemanticIndexer(store: s, embedder: StubEmbedder(dimension: 16))
    await idx.sync(db)

    let items = s.existingItems()
    #expect(items.keys.contains(n.id.uuidString))
    #expect(items.keys.contains(le.id.uuidString))
    #expect(items.keys.contains(ev.id.uuidString))
  }

  @Test func skipsUnenrichedCCSessionEventWithoutWorkSummary() async throws {
    let db = try openCanonicalDatabase(at: tempURL("semidx-skip"))
    let n = Node(name: "N", kind: NodeKind.project)
    try await db.write { try Node.insert { n }.execute($0) }
    let ev = try makeEvent(db, node: n, kind: CaptureKind.ccSession, workSummary: nil) // un-enriched

    let s = store()
    let idx = SemanticIndexer(store: s, embedder: StubEmbedder(dimension: 16))
    await idx.sync(db)

    #expect(!s.existingItems().keys.contains(ev.id.uuidString))
  }

  /// Degenerate extraction output ("[]", "/") is not searchable content — it must never reach the
  /// index, or ⌘F "Related" surfaces empty-looking rows.
  @Test func skipsDegenerateEventText() async throws {
    let db = try openCanonicalDatabase(at: tempURL("semidx-degenerate"))
    let n = Node(name: "N", kind: NodeKind.project)
    try await db.write { try Node.insert { n }.execute($0) }
    let empty = try makeEvent(db, node: n, kind: CaptureKind.ccSession, workSummary: "[]")
    let slash = try makeEvent(db, node: n, kind: CaptureKind.ccSession, workSummary: "/")
    let good = try makeEvent(db, node: n, kind: CaptureKind.ccSession, workSummary: "wired up refunds")

    let s = store()
    let idx = SemanticIndexer(store: s, embedder: StubEmbedder(dimension: 16))
    await idx.sync(db)

    let items = s.existingItems()
    #expect(!items.keys.contains(empty.id.uuidString))
    #expect(!items.keys.contains(slash.id.uuidString))
    #expect(items.keys.contains(good.id.uuidString))
  }

  /// The degenerate-output gate must NOT touch human-authored text: "wip" and "fix ci" are real
  /// commit subjects, and dropping them would silently hole the semantic index.
  @Test func keepsShortHumanAuthoredCommitSubjects() async throws {
    let db = try openCanonicalDatabase(at: tempURL("semidx-shortcommit"))
    let n = Node(name: "N", kind: NodeKind.project)
    try await db.write { try Node.insert { n }.execute($0) }
    let wip = try makeEvent(db, node: n, kind: CaptureKind.gitCommit, summary: "wip")
    let ci = try makeEvent(db, node: n, kind: CaptureKind.gitCommit, summary: "fix ci")

    let s = store()
    let idx = SemanticIndexer(store: s, embedder: StubEmbedder(dimension: 16))
    await idx.sync(db)

    let items = s.existingItems()
    #expect(items.keys.contains(wip.id.uuidString))
    #expect(items.keys.contains(ci.id.uuidString))
  }

  /// One un-embeddable item must not starve its batch-mates. The embedder is called with the WHOLE
  /// pending set, so an all-or-nothing failure would leave every other new item unindexed — and,
  /// because a failed item never records its hash, it rejoins the next batch and blocks it again,
  /// indefinitely. The poisoned item itself stays absent and retryable (the existing contract).
  @Test func oneUnembeddableItemDoesNotStarveTheRestOfTheBatch() async throws {
    let db = try openCanonicalDatabase(at: tempURL("semidx-poison"))
    let poisoned = Node(name: "ПОИСК", kind: NodeKind.project)   // non-Latin → real embedder fails it
    let healthy = Node(name: "Payments", kind: NodeKind.project)
    let alsoHealthy = Node(name: "Billing", kind: NodeKind.project)
    try await db.write {
      try Node.insert { poisoned }.execute($0)
      try Node.insert { healthy }.execute($0)
      try Node.insert { alsoHealthy }.execute($0)
    }

    let s = store()
    let idx = SemanticIndexer(store: s, embedder: PoisonEmbedder(dimension: 16, poison: "ПОИСК"))
    await idx.sync(db)

    let items = s.existingItems()
    #expect(items.keys.contains(healthy.id.uuidString))
    #expect(items.keys.contains(alsoHealthy.id.uuidString))
    #expect(!items.keys.contains(poisoned.id.uuidString))   // absent → retried next sync, not starving others
  }

  @Test func noiseLabelPrunesLooseEnd() async throws {
    let db = try openCanonicalDatabase(at: tempURL("semidx-noise"))
    let n = Node(name: "N", kind: NodeKind.project)
    try await db.write { try Node.insert { n }.execute($0) }
    let ev = try makeEvent(db, node: n)
    let le = LooseEnd(nodeID: n.id, sourceEventID: ev.id, text: "t", quote: "q")
    try await db.write { try LooseEnd.insert { le }.execute($0) }

    let s = store()
    let idx = SemanticIndexer(store: s, embedder: StubEmbedder(dimension: 16))
    await idx.sync(db)
    #expect(s.existingItems().keys.contains(le.id.uuidString))

    try await db.write { db in
      try LooseEnd.where { $0.id.eq(le.id) }.update { $0.label = "noise" }.execute(db)
    }
    await idx.sync(db)                      // membership-driven prune (hash unchanged)
    #expect(!s.existingItems().keys.contains(le.id.uuidString))
  }

  @Test func resolvedLooseEndPrunesFromIndex() async throws {
    let db = try openCanonicalDatabase(at: tempURL("semidx-resolved"))
    let n = Node(name: "N", kind: NodeKind.project)
    try await db.write { try Node.insert { n }.execute($0) }
    let ev = try makeEvent(db, node: n)
    let le = LooseEnd(nodeID: n.id, sourceEventID: ev.id, text: "t", quote: "q")
    try await db.write { try LooseEnd.insert { le }.execute($0) }

    let s = store()
    let idx = SemanticIndexer(store: s, embedder: StubEmbedder(dimension: 16))
    await idx.sync(db)
    #expect(s.existingItems().keys.contains(le.id.uuidString))

    try await db.write { db in
      try LooseEnd.where { $0.id.eq(le.id) }.update { $0.status = "resolved" }.execute(db)
    }
    await idx.sync(db)
    #expect(!s.existingItems().keys.contains(le.id.uuidString))
  }

  @Test func archivingNodePrunesItsItems() async throws {
    let db = try openCanonicalDatabase(at: tempURL("semidx-archive"))
    let n = Node(name: "N", kind: NodeKind.project)
    try await db.write { try Node.insert { n }.execute($0) }
    let ev = try makeEvent(db, node: n)
    let le = LooseEnd(nodeID: n.id, sourceEventID: ev.id, text: "t", quote: "q")
    try await db.write { try LooseEnd.insert { le }.execute($0) }

    let s = store()
    let idx = SemanticIndexer(store: s, embedder: StubEmbedder(dimension: 16))
    await idx.sync(db)
    #expect(s.existingItems().keys.contains(n.id.uuidString))
    #expect(s.existingItems().keys.contains(le.id.uuidString))
    #expect(s.existingItems().keys.contains(ev.id.uuidString))

    try await db.write { db in
      try Node.where { $0.id.eq(n.id) }.update { $0.state = NodeState.archived }.execute(db)
    }
    await idx.sync(db)
    let items = s.existingItems()
    #expect(!items.keys.contains(n.id.uuidString))
    #expect(!items.keys.contains(le.id.uuidString))
    #expect(!items.keys.contains(ev.id.uuidString))
  }

  @Test func repointUpdatesNodeWithoutChangingHash() async throws {
    let db = try openCanonicalDatabase(at: tempURL("semidx-repoint"))
    let a = Node(name: "A", kind: NodeKind.project)
    let b = Node(name: "B", kind: NodeKind.strand)
    try await db.write { db in
      try Node.insert { a }.execute(db)
      try Node.insert { b }.execute(db)
    }
    let ev = try makeEvent(db, node: a)
    let le = LooseEnd(nodeID: a.id, sourceEventID: ev.id, text: "t", quote: "q")
    try await db.write { try LooseEnd.insert { le }.execute($0) }

    let s = store()
    let idx = SemanticIndexer(store: s, embedder: StubEmbedder(dimension: 16))
    await idx.sync(db)
    let hashBefore = s.existingItems()[le.id.uuidString]

    try await db.write { db in
      try LooseEnd.where { $0.id.eq(le.id) }.update { $0.nodeID = b.id }.execute(db)
    }
    await idx.sync(db)

    // content_hash for the loose end is unchanged (repoint is metadata-only, not a re-embed).
    #expect(s.existingItems()[le.id.uuidString] == hashBefore)
    let queryVec = await StubEmbedder(dimension: 16).embed(["t — q"])![0]!
    let hits = s.knn(query: queryVec, k: 5, activeOnly: true)
    #expect(hits.first(where: { $0.itemID == le.id.uuidString })?.nodeID == b.id.uuidString)
  }

  @Test func changedTextReEmbedsWithNewContent() async throws {
    let db = try openCanonicalDatabase(at: tempURL("semidx-changehash"))
    let n = Node(name: "N", kind: NodeKind.project, description: "original description")
    try await db.write { try Node.insert { n }.execute($0) }

    let s = store()
    let idx = SemanticIndexer(store: s, embedder: StubEmbedder(dimension: 16))
    await idx.sync(db)
    let hashBefore = s.existingItems()[n.id.uuidString]

    try await db.write { db in
      try Node.where { $0.id.eq(n.id) }.update { $0.description = "changed description" }.execute(db)
    }
    await idx.sync(db)
    #expect(s.existingItems()[n.id.uuidString] != hashBefore)   // content_hash changed → re-embedded

    let newVec = await StubEmbedder(dimension: 16).embed(["N — changed description"])![0]!
    let hits = s.knn(query: newVec, k: 1, activeOnly: true)
    #expect(hits.first?.itemID == n.id.uuidString)
    #expect(hits.first!.similarity > 0.99)   // the stored vector IS the new content's embedding
  }

  @Test func failedEmbeddingIsRetriedOnNextSyncNotPermanentlySkipped() async throws {
    let db = try openCanonicalDatabase(at: tempURL("semidx-nilembed-retry"))
    let n = Node(name: "N", kind: NodeKind.project)
    try await db.write { try Node.insert { n }.execute($0) }
    let ev = try makeEvent(db, node: n, kind: CaptureKind.ccSession, workSummary: "wired up refunds")
    let le = LooseEnd(nodeID: n.id, sourceEventID: ev.id, text: "wire up refunds", quote: "TODO refunds")
    try await db.write { try LooseEnd.insert { le }.execute($0) }

    let s = store()

    // First sync: embedder fails entirely (e.g. model asset not yet downloaded). None of these
    // brand-new items may be marked done — otherwise they'd be permanently unsearchable.
    let failingIdx = SemanticIndexer(store: s, embedder: NilEmbedder(dimension: 16))
    await failingIdx.sync(db)
    #expect(s.existingItems().isEmpty)

    // Second sync: embedder recovers. The same items must be retried (not starved by a stale
    // "already handled" marker) and become searchable.
    let workingIdx = SemanticIndexer(store: s, embedder: StubEmbedder(dimension: 16))
    await workingIdx.sync(db)

    let items = s.existingItems()
    #expect(items.keys.contains(n.id.uuidString))
    #expect(items.keys.contains(le.id.uuidString))
    #expect(items.keys.contains(ev.id.uuidString))

    let queryVec = await StubEmbedder(dimension: 16).embed(["wire up refunds — TODO refunds"])![0]!
    let hits = s.knn(query: queryVec, k: 5, activeOnly: true)
    #expect(hits.contains { $0.itemID == le.id.uuidString })
  }
}
