import Testing
import Foundation
import SQLiteData
@testable import PensieveKit

/// Inserts a Source + Event under `node` so a LooseEnd's sourceEventID FK is satisfiable
/// (looseEnds.sourceEventID REFERENCES events(id), and GRDB enforces foreign keys by default).
private func makeEvent(_ database: any DatabaseWriter, node: Node, kind: String = CaptureKind.gitCommit,
                       summary: String = "did a thing", workSummary: String? = nil) throws -> Event {
  // Unique per call — sources.(key, kind) is UNIQUE, so several events under one node need several sources.
  let source = Source(nodeID: node.id, kind: SourceKind.gitRepo, key: "/p/\(node.id)/\(UUID())")
  let event = Event(nodeID: node.id, sourceID: source.id, occurredAt: Date(), kind: kind,
                    summary: summary, detailJSON: "{}", workSummary: workSummary)
  try database.write { database in
    try Source.insert { source }.execute(database)
    try Event.insert { event }.execute(database)
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
    let database = try openCanonicalDatabase(at: tempURL("semidx-add"))
    let n = Node(name: "Payments", kind: NodeKind.project)
    try await database.write { try Node.insert { n }.execute($0) }
    let event = try makeEvent(database, node: n, kind: CaptureKind.ccSession, workSummary: "wired up refunds")
    let looseEnd = LooseEnd(nodeID: n.id, sourceEventID: event.id, text: "wire up refunds", quote: "TODO refunds")
    try await database.write { try LooseEnd.insert { looseEnd }.execute($0) }

    let s = store()
    let idx = SemanticIndexer(store: s, embedder: StubEmbedder(dimension: 16))
    await idx.sync(database)

    let items = s.existingItems()
    #expect(items.keys.contains(n.id.uuidString))
    #expect(items.keys.contains(looseEnd.id.uuidString))
    #expect(items.keys.contains(event.id.uuidString))
  }

  @Test func skipsUnenrichedCCSessionEventWithoutWorkSummary() async throws {
    let database = try openCanonicalDatabase(at: tempURL("semidx-skip"))
    let n = Node(name: "N", kind: NodeKind.project)
    try await database.write { try Node.insert { n }.execute($0) }
    let event = try makeEvent(database, node: n, kind: CaptureKind.ccSession, workSummary: nil) // un-enriched

    let s = store()
    let idx = SemanticIndexer(store: s, embedder: StubEmbedder(dimension: 16))
    await idx.sync(database)

    #expect(!s.existingItems().keys.contains(event.id.uuidString))
  }

  /// Degenerate extraction output ("[]", "/") is not searchable content — it must never reach the
  /// index, or ⌘F "Related" surfaces empty-looking rows.
  @Test func skipsDegenerateEventText() async throws {
    let database = try openCanonicalDatabase(at: tempURL("semidx-degenerate"))
    let n = Node(name: "N", kind: NodeKind.project)
    try await database.write { try Node.insert { n }.execute($0) }
    let empty = try makeEvent(database, node: n, kind: CaptureKind.ccSession, workSummary: "[]")
    let slash = try makeEvent(database, node: n, kind: CaptureKind.ccSession, workSummary: "/")
    let good = try makeEvent(database, node: n, kind: CaptureKind.ccSession, workSummary: "wired up refunds")

    let s = store()
    let idx = SemanticIndexer(store: s, embedder: StubEmbedder(dimension: 16))
    await idx.sync(database)

    let items = s.existingItems()
    #expect(!items.keys.contains(empty.id.uuidString))
    #expect(!items.keys.contains(slash.id.uuidString))
    #expect(items.keys.contains(good.id.uuidString))
  }

  /// The degenerate-output gate must NOT touch human-authored text: "wip" and "fix ci" are real
  /// commit subjects, and dropping them would silently hole the semantic index.
  @Test func keepsShortHumanAuthoredCommitSubjects() async throws {
    let database = try openCanonicalDatabase(at: tempURL("semidx-shortcommit"))
    let n = Node(name: "N", kind: NodeKind.project)
    try await database.write { try Node.insert { n }.execute($0) }
    let wip = try makeEvent(database, node: n, kind: CaptureKind.gitCommit, summary: "wip")
    let ci = try makeEvent(database, node: n, kind: CaptureKind.gitCommit, summary: "fix ci")

    let s = store()
    let idx = SemanticIndexer(store: s, embedder: StubEmbedder(dimension: 16))
    await idx.sync(database)

    let items = s.existingItems()
    #expect(items.keys.contains(wip.id.uuidString))
    #expect(items.keys.contains(ci.id.uuidString))
  }

  /// One un-embeddable item must not starve its batch-mates. The embedder is called with the WHOLE
  /// pending set, so an all-or-nothing failure would leave every other new item unindexed — and,
  /// because a failed item never records its hash, it rejoins the next batch and blocks it again,
  /// indefinitely. The poisoned item itself stays absent and retryable (the existing contract).
  @Test func oneUnembeddableItemDoesNotStarveTheRestOfTheBatch() async throws {
    let database = try openCanonicalDatabase(at: tempURL("semidx-poison"))
    let poisoned = Node(name: "ПОИСК", kind: NodeKind.project)   // non-Latin → real embedder fails it
    let healthy = Node(name: "Payments", kind: NodeKind.project)
    let alsoHealthy = Node(name: "Billing", kind: NodeKind.project)
    try await database.write {
      try Node.insert { poisoned }.execute($0)
      try Node.insert { healthy }.execute($0)
      try Node.insert { alsoHealthy }.execute($0)
    }

    let s = store()
    let idx = SemanticIndexer(store: s, embedder: PoisonEmbedder(dimension: 16, poison: "ПОИСК"))
    await idx.sync(database)

    let items = s.existingItems()
    #expect(items.keys.contains(healthy.id.uuidString))
    #expect(items.keys.contains(alsoHealthy.id.uuidString))
    #expect(!items.keys.contains(poisoned.id.uuidString))   // absent → retried next sync, not starving others
  }

  @Test func noiseLabelPrunesLooseEnd() async throws {
    let database = try openCanonicalDatabase(at: tempURL("semidx-noise"))
    let n = Node(name: "N", kind: NodeKind.project)
    try await database.write { try Node.insert { n }.execute($0) }
    let event = try makeEvent(database, node: n)
    let looseEnd = LooseEnd(nodeID: n.id, sourceEventID: event.id, text: "t", quote: "q")
    try await database.write { try LooseEnd.insert { looseEnd }.execute($0) }

    let s = store()
    let idx = SemanticIndexer(store: s, embedder: StubEmbedder(dimension: 16))
    await idx.sync(database)
    #expect(s.existingItems().keys.contains(looseEnd.id.uuidString))

    try await database.write { database in
      try LooseEnd.where { $0.id.eq(looseEnd.id) }.update { $0.label = "noise" }.execute(database)
    }
    await idx.sync(database)                      // membership-driven prune (hash unchanged)
    #expect(!s.existingItems().keys.contains(looseEnd.id.uuidString))
  }

  @Test func resolvedLooseEndPrunesFromIndex() async throws {
    let database = try openCanonicalDatabase(at: tempURL("semidx-resolved"))
    let n = Node(name: "N", kind: NodeKind.project)
    try await database.write { try Node.insert { n }.execute($0) }
    let event = try makeEvent(database, node: n)
    let looseEnd = LooseEnd(nodeID: n.id, sourceEventID: event.id, text: "t", quote: "q")
    try await database.write { try LooseEnd.insert { looseEnd }.execute($0) }

    let s = store()
    let idx = SemanticIndexer(store: s, embedder: StubEmbedder(dimension: 16))
    await idx.sync(database)
    #expect(s.existingItems().keys.contains(looseEnd.id.uuidString))

    try await database.write { database in
      try LooseEnd.where { $0.id.eq(looseEnd.id) }.update { $0.status = "resolved" }.execute(database)
    }
    await idx.sync(database)
    #expect(!s.existingItems().keys.contains(looseEnd.id.uuidString))
  }

  /// Superseded contract: archiving used to prune a node's items from the index entirely. Task 1
  /// widens the corpus producer to include archived nodes (tagged with their real state), so
  /// archiving now re-tags instead of pruning — the items stay recallable, just no longer surfaced
  /// by an `includeArchived: false` query (knn's own scoping is untouched by this task; see Task 2/3).
  @Test func archivingNodeUpdatesItsItemsStateInsteadOfPruning() async throws {
    let database = try openCanonicalDatabase(at: tempURL("semidx-archive"))
    let n = Node(name: "N", kind: NodeKind.project)
    try await database.write { try Node.insert { n }.execute($0) }
    let event = try makeEvent(database, node: n)
    let looseEnd = LooseEnd(nodeID: n.id, sourceEventID: event.id, text: "t", quote: "q")
    try await database.write { try LooseEnd.insert { looseEnd }.execute($0) }

    let s = store()
    let idx = SemanticIndexer(store: s, embedder: StubEmbedder(dimension: 16))
    await idx.sync(database)
    #expect(s.existingItems().keys.contains(n.id.uuidString))
    #expect(s.existingItems().keys.contains(looseEnd.id.uuidString))
    #expect(s.existingItems().keys.contains(event.id.uuidString))

    try await database.write { database in
      try Node.where { $0.id.eq(n.id) }.update { $0.state = NodeState.archived }.execute(database)
    }
    await idx.sync(database)

    let items = s.existingItems()
    #expect(items.keys.contains(n.id.uuidString))
    #expect(items.keys.contains(looseEnd.id.uuidString))
    #expect(items.keys.contains(event.id.uuidString))

    let queryVec = await StubEmbedder(dimension: 16).embed(["t — q"])![0]!
    let activeHits = s.knn(query: queryVec, k: 5, includeArchived: false)
    #expect(!activeHits.contains { $0.itemID == looseEnd.id.uuidString })

    // The vector itself is still there, not destroyed — it's reachable under the wide filter.
    // This is what distinguishes "re-tagged" from "pruned-and-re-embedded" (both would satisfy
    // the assertions above; only this one pins the vector survived unpruned).
    let archivedHits = s.knn(query: queryVec, k: 5, includeArchived: true)
    #expect(archivedHits.contains { $0.itemID == looseEnd.id.uuidString })
  }

  @Test func unarchivingNodeRestoresItsItemsToDefaultScopeResults() async throws {
    let database = try openCanonicalDatabase(at: tempURL("semidx-unarchive"))
    let n = Node(name: "N", kind: NodeKind.project)
    try await database.write { try Node.insert { n }.execute($0) }
    let event = try makeEvent(database, node: n)
    let looseEnd = LooseEnd(nodeID: n.id, sourceEventID: event.id, text: "t", quote: "q")
    try await database.write { try LooseEnd.insert { looseEnd }.execute($0) }

    let s = store()
    let idx = SemanticIndexer(store: s, embedder: StubEmbedder(dimension: 16))
    await idx.sync(database)

    try await database.write { database in
      try Node.where { $0.id.eq(n.id) }.update { $0.state = NodeState.archived }.execute(database)
    }
    await idx.sync(database)

    let queryVec = await StubEmbedder(dimension: 16).embed(["t — q"])![0]!
    #expect(!s.knn(query: queryVec, k: 5, includeArchived: false).contains { $0.itemID == looseEnd.id.uuidString })

    try await database.write { database in
      try Node.where { $0.id.eq(n.id) }.update { $0.state = NodeState.active }.execute(database)
    }
    await idx.sync(database)

    let restoredHits = s.knn(query: queryVec, k: 5, includeArchived: false)
    #expect(restoredHits.contains { $0.itemID == looseEnd.id.uuidString })
  }

  @Test func repointUpdatesNodeWithoutChangingHash() async throws {
    let database = try openCanonicalDatabase(at: tempURL("semidx-repoint"))
    let a = Node(name: "A", kind: NodeKind.project)
    let b = Node(name: "B", kind: NodeKind.strand)
    try await database.write { database in
      try Node.insert { a }.execute(database)
      try Node.insert { b }.execute(database)
    }
    let event = try makeEvent(database, node: a)
    let looseEnd = LooseEnd(nodeID: a.id, sourceEventID: event.id, text: "t", quote: "q")
    try await database.write { try LooseEnd.insert { looseEnd }.execute($0) }

    let s = store()
    let idx = SemanticIndexer(store: s, embedder: StubEmbedder(dimension: 16))
    await idx.sync(database)
    let hashBefore = s.existingItems()[looseEnd.id.uuidString]

    try await database.write { database in
      try LooseEnd.where { $0.id.eq(looseEnd.id) }.update { $0.nodeID = b.id }.execute(database)
    }
    await idx.sync(database)

    // content_hash for the loose end is unchanged (repoint is metadata-only, not a re-embed).
    #expect(s.existingItems()[looseEnd.id.uuidString] == hashBefore)
    let queryVec = await StubEmbedder(dimension: 16).embed(["t — q"])![0]!
    let hits = s.knn(query: queryVec, k: 5, includeArchived: false)
    #expect(hits.first(where: { $0.itemID == looseEnd.id.uuidString })?.nodeID == b.id.uuidString)
  }

  @Test func changedTextReEmbedsWithNewContent() async throws {
    let database = try openCanonicalDatabase(at: tempURL("semidx-changehash"))
    let n = Node(name: "N", kind: NodeKind.project, description: "original description")
    try await database.write { try Node.insert { n }.execute($0) }

    let s = store()
    let idx = SemanticIndexer(store: s, embedder: StubEmbedder(dimension: 16))
    await idx.sync(database)
    let hashBefore = s.existingItems()[n.id.uuidString]

    try await database.write { database in
      try Node.where { $0.id.eq(n.id) }.update { $0.description = "changed description" }.execute(database)
    }
    await idx.sync(database)
    #expect(s.existingItems()[n.id.uuidString] != hashBefore)   // content_hash changed → re-embedded

    let newVec = await StubEmbedder(dimension: 16).embed(["N — changed description"])![0]!
    let hits = s.knn(query: newVec, k: 1, includeArchived: false)
    #expect(hits.first?.itemID == n.id.uuidString)
    #expect(hits.first!.similarity > 0.99)   // the stored vector IS the new content's embedding
  }

  @Test func failedEmbeddingIsRetriedOnNextSyncNotPermanentlySkipped() async throws {
    let database = try openCanonicalDatabase(at: tempURL("semidx-nilembed-retry"))
    let n = Node(name: "N", kind: NodeKind.project)
    try await database.write { try Node.insert { n }.execute($0) }
    let event = try makeEvent(database, node: n, kind: CaptureKind.ccSession, workSummary: "wired up refunds")
    let looseEnd = LooseEnd(nodeID: n.id, sourceEventID: event.id, text: "wire up refunds", quote: "TODO refunds")
    try await database.write { try LooseEnd.insert { looseEnd }.execute($0) }

    let s = store()

    // First sync: embedder fails entirely (e.g. model asset not yet downloaded). None of these
    // brand-new items may be marked done — otherwise they'd be permanently unsearchable.
    let failingIdx = SemanticIndexer(store: s, embedder: NilEmbedder(dimension: 16))
    await failingIdx.sync(database)
    #expect(s.existingItems().isEmpty)

    // Second sync: embedder recovers. The same items must be retried (not starved by a stale
    // "already handled" marker) and become searchable.
    let workingIdx = SemanticIndexer(store: s, embedder: StubEmbedder(dimension: 16))
    await workingIdx.sync(database)

    let items = s.existingItems()
    #expect(items.keys.contains(n.id.uuidString))
    #expect(items.keys.contains(looseEnd.id.uuidString))
    #expect(items.keys.contains(event.id.uuidString))

    let queryVec = await StubEmbedder(dimension: 16).embed(["wire up refunds — TODO refunds"])![0]!
    let hits = s.knn(query: queryVec, k: 5, includeArchived: false)
    #expect(hits.contains { $0.itemID == looseEnd.id.uuidString })
  }

  @Test func gatherIncludesArchivedNodesTaggedWithTheirState() async throws {
    let database = try openCanonicalDatabase(at: tempURL("corpus-archived"))
    let active = Node(name: "Payments", kind: NodeKind.project)
    let archived = Node(name: "Legacy billing", state: .archived, kind: NodeKind.project)
    try await database.write { database in
      try Node.insert { active }.execute(database)
      try Node.insert { archived }.execute(database)
    }
    let items = try EmbeddableCorpus.gather(database)

    let byID = Dictionary(items.map { ($0.itemID, $0) }, uniquingKeysWith: { a, _ in a })
    #expect(byID[active.id.uuidString]?.state == "active")
    #expect(byID[archived.id.uuidString]?.state == "archived")
  }

  @Test func gatherTagsLooseEndsAndEventsWithTheirOwningNodesState() async throws {
    let database = try openCanonicalDatabase(at: tempURL("corpus-archived-children"))
    let archived = Node(name: "Legacy billing", state: .archived, kind: NodeKind.project)
    try await database.write { try Node.insert { archived }.execute($0) }
    let event = try makeEvent(database, node: archived, kind: CaptureKind.ccSession,
                           workSummary: "migrated the old invoices")
    let looseEnd = LooseEnd(nodeID: archived.id, sourceEventID: event.id,
                      text: "drop the legacy invoice table", quote: "TODO drop invoices")
    try await database.write { try LooseEnd.insert { looseEnd }.execute($0) }

    let items = try EmbeddableCorpus.gather(database)
    let byID = Dictionary(items.map { ($0.itemID, $0) }, uniquingKeysWith: { a, _ in a })

    #expect(byID[looseEnd.id.uuidString]?.state == "archived")
    #expect(byID[event.id.uuidString]?.state == "archived")
  }

  @Test func gatherStillExcludesMutedNodesAndClosedLooseEnds() async throws {
    let database = try openCanonicalDatabase(at: tempURL("corpus-muted"))
    let muted = Node(name: "Muted work", state: .muted, kind: NodeKind.project)
    let archived = Node(name: "Archived work", state: .archived, kind: NodeKind.project)
    try await database.write { database in
      try Node.insert { muted }.execute(database)
      try Node.insert { archived }.execute(database)
    }
    let event = try makeEvent(database, node: archived)
    let closed = LooseEnd(nodeID: archived.id, sourceEventID: event.id,
                          text: "already handled", quote: "done", status: "closed")
    try await database.write { try LooseEnd.insert { closed }.execute($0) }

    let ids = Set(try EmbeddableCorpus.gather(database).map { $0.itemID })
    #expect(!ids.contains(muted.id.uuidString))
    #expect(!ids.contains(closed.id.uuidString))
  }
}
