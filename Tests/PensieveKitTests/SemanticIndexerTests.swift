import Testing
import Foundation
import SQLiteData
@testable import PensieveKit

/// Inserts nodeA Source + Event under `node` so nodeA LooseEnd'indexStore sourceEventID FK is satisfiable
/// (looseEnds.sourceEventID REFERENCES events(id), and GRDB enforces foreign keys by default).
private func makeEvent(_ database: any DatabaseWriter, node: Node, kind: String = CaptureKind.gitCommit,
                       summary: String = "did nodeA thing", workSummary: String? = nil) throws -> Event {
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
    let node = Node(name: "Payments", kind: NodeKind.project)
    try await database.write { try Node.insert { node }.execute($0) }
    let event = try makeEvent(database, node: node, kind: CaptureKind.ccSession, workSummary: "wired up refunds")
    let looseEnd = LooseEnd(nodeID: node.id, sourceEventID: event.id, text: "wire up refunds", quote: "TODO refunds")
    try await database.write { try LooseEnd.insert { looseEnd }.execute($0) }

    let indexStore = store()
    let idx = SemanticIndexer(store: indexStore, embedder: StubEmbedder(dimension: 16))
    await idx.sync(database)

    let items = indexStore.existingItems()
    #expect(items.keys.contains(node.id.uuidString))
    #expect(items.keys.contains(looseEnd.id.uuidString))
    #expect(items.keys.contains(event.id.uuidString))
  }

  @Test func skipsUnenrichedCCSessionEventWithoutWorkSummary() async throws {
    let database = try openCanonicalDatabase(at: tempURL("semidx-skip"))
    let node = Node(name: "N", kind: NodeKind.project)
    try await database.write { try Node.insert { node }.execute($0) }
    let event = try makeEvent(database, node: node, kind: CaptureKind.ccSession, workSummary: nil) // un-enriched

    let indexStore = store()
    let idx = SemanticIndexer(store: indexStore, embedder: StubEmbedder(dimension: 16))
    await idx.sync(database)

    #expect(!indexStore.existingItems().keys.contains(event.id.uuidString))
  }

  /// Degenerate extraction output ("[]", "/") is not searchable content — it must never reach the
  /// index, or ⌘F "Related" surfaces empty-looking rows.
  @Test func skipsDegenerateEventText() async throws {
    let database = try openCanonicalDatabase(at: tempURL("semidx-degenerate"))
    let node = Node(name: "N", kind: NodeKind.project)
    try await database.write { try Node.insert { node }.execute($0) }
    let empty = try makeEvent(database, node: node, kind: CaptureKind.ccSession, workSummary: "[]")
    let slash = try makeEvent(database, node: node, kind: CaptureKind.ccSession, workSummary: "/")
    let good = try makeEvent(database, node: node, kind: CaptureKind.ccSession, workSummary: "wired up refunds")

    let indexStore = store()
    let idx = SemanticIndexer(store: indexStore, embedder: StubEmbedder(dimension: 16))
    await idx.sync(database)

    let items = indexStore.existingItems()
    #expect(!items.keys.contains(empty.id.uuidString))
    #expect(!items.keys.contains(slash.id.uuidString))
    #expect(items.keys.contains(good.id.uuidString))
  }

  /// The degenerate-output gate must NOT touch human-authored text: "wip" and "fix ciEvent" are real
  /// commit subjects, and dropping them would silently hole the semantic index.
  @Test func keepsShortHumanAuthoredCommitSubjects() async throws {
    let database = try openCanonicalDatabase(at: tempURL("semidx-shortcommit"))
    let node = Node(name: "N", kind: NodeKind.project)
    try await database.write { try Node.insert { node }.execute($0) }
    let wip = try makeEvent(database, node: node, kind: CaptureKind.gitCommit, summary: "wip")
    let ciEvent = try makeEvent(database, node: node, kind: CaptureKind.gitCommit, summary: "fix ciEvent")

    let indexStore = store()
    let idx = SemanticIndexer(store: indexStore, embedder: StubEmbedder(dimension: 16))
    await idx.sync(database)

    let items = indexStore.existingItems()
    #expect(items.keys.contains(wip.id.uuidString))
    #expect(items.keys.contains(ciEvent.id.uuidString))
  }

  /// One un-embeddable item must not starve its batch-mates. The embedder is called with the WHOLE
  /// pending set, so an all-or-nothing failure would leave every other new item unindexed — and,
  /// because nodeA failed item never records its hash, it rejoins the next batch and blocks it again,
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

    let indexStore = store()
    let idx = SemanticIndexer(store: indexStore, embedder: PoisonEmbedder(dimension: 16, poison: "ПОИСК"))
    await idx.sync(database)

    let items = indexStore.existingItems()
    #expect(items.keys.contains(healthy.id.uuidString))
    #expect(items.keys.contains(alsoHealthy.id.uuidString))
    #expect(!items.keys.contains(poisoned.id.uuidString))   // absent → retried next sync, not starving others
  }

  @Test func noiseLabelPrunesLooseEnd() async throws {
    let database = try openCanonicalDatabase(at: tempURL("semidx-noise"))
    let node = Node(name: "N", kind: NodeKind.project)
    try await database.write { try Node.insert { node }.execute($0) }
    let event = try makeEvent(database, node: node)
    let looseEnd = LooseEnd(nodeID: node.id, sourceEventID: event.id, text: "t", quote: "q")
    try await database.write { try LooseEnd.insert { looseEnd }.execute($0) }

    let indexStore = store()
    let idx = SemanticIndexer(store: indexStore, embedder: StubEmbedder(dimension: 16))
    await idx.sync(database)
    #expect(indexStore.existingItems().keys.contains(looseEnd.id.uuidString))

    try await database.write { database in
      try LooseEnd.where { $0.id.eq(looseEnd.id) }.update { $0.label = "noise" }.execute(database)
    }
    await idx.sync(database)                      // membership-driven prune (hash unchanged)
    #expect(!indexStore.existingItems().keys.contains(looseEnd.id.uuidString))
  }

  @Test func resolvedLooseEndPrunesFromIndex() async throws {
    let database = try openCanonicalDatabase(at: tempURL("semidx-resolved"))
    let node = Node(name: "N", kind: NodeKind.project)
    try await database.write { try Node.insert { node }.execute($0) }
    let event = try makeEvent(database, node: node)
    let looseEnd = LooseEnd(nodeID: node.id, sourceEventID: event.id, text: "t", quote: "q")
    try await database.write { try LooseEnd.insert { looseEnd }.execute($0) }

    let indexStore = store()
    let idx = SemanticIndexer(store: indexStore, embedder: StubEmbedder(dimension: 16))
    await idx.sync(database)
    #expect(indexStore.existingItems().keys.contains(looseEnd.id.uuidString))

    try await database.write { database in
      try LooseEnd.where { $0.id.eq(looseEnd.id) }.update { $0.status = "resolved" }.execute(database)
    }
    await idx.sync(database)
    #expect(!indexStore.existingItems().keys.contains(looseEnd.id.uuidString))
  }

  /// Superseded contract: archiving used to prune nodeA node'indexStore items from the index entirely. Task 1
  /// widens the corpus producer to include archived nodes (tagged with their real state), so
  /// archiving now re-tags instead of pruning — the items stay recallable, just no longer surfaced
  /// by an `includeArchived: false` query (knn'indexStore own scoping is untouched by this task; see Task 2/3).
  @Test func archivingNodeUpdatesItsItemsStateInsteadOfPruning() async throws {
    let database = try openCanonicalDatabase(at: tempURL("semidx-archive"))
    let node = Node(name: "N", kind: NodeKind.project)
    try await database.write { try Node.insert { node }.execute($0) }
    let event = try makeEvent(database, node: node)
    let looseEnd = LooseEnd(nodeID: node.id, sourceEventID: event.id, text: "t", quote: "q")
    try await database.write { try LooseEnd.insert { looseEnd }.execute($0) }

    let indexStore = store()
    let idx = SemanticIndexer(store: indexStore, embedder: StubEmbedder(dimension: 16))
    await idx.sync(database)
    #expect(indexStore.existingItems().keys.contains(node.id.uuidString))
    #expect(indexStore.existingItems().keys.contains(looseEnd.id.uuidString))
    #expect(indexStore.existingItems().keys.contains(event.id.uuidString))

    try await database.write { database in
      try Node.where { $0.id.eq(node.id) }.update { $0.state = NodeState.archived }.execute(database)
    }
    await idx.sync(database)

    let items = indexStore.existingItems()
    #expect(items.keys.contains(node.id.uuidString))
    #expect(items.keys.contains(looseEnd.id.uuidString))
    #expect(items.keys.contains(event.id.uuidString))

    let queryVec = await StubEmbedder(dimension: 16).embed(["t — q"])![0]!
    let activeHits = indexStore.knn(query: queryVec, k: 5, includeArchived: false)
    #expect(!activeHits.contains { $0.itemID == looseEnd.id.uuidString })

    // The vector itself is still there, not destroyed — it'indexStore reachable under the wide filter.
    // This is what distinguishes "re-tagged" from "pruned-and-re-embedded" (both would satisfy
    // the assertions above; only this one pins the vector survived unpruned).
    let archivedHits = indexStore.knn(query: queryVec, k: 5, includeArchived: true)
    #expect(archivedHits.contains { $0.itemID == looseEnd.id.uuidString })
  }

  @Test func unarchivingNodeRestoresItsItemsToDefaultScopeResults() async throws {
    let database = try openCanonicalDatabase(at: tempURL("semidx-unarchive"))
    let node = Node(name: "N", kind: NodeKind.project)
    try await database.write { try Node.insert { node }.execute($0) }
    let event = try makeEvent(database, node: node)
    let looseEnd = LooseEnd(nodeID: node.id, sourceEventID: event.id, text: "t", quote: "q")
    try await database.write { try LooseEnd.insert { looseEnd }.execute($0) }

    let indexStore = store()
    let idx = SemanticIndexer(store: indexStore, embedder: StubEmbedder(dimension: 16))
    await idx.sync(database)

    try await database.write { database in
      try Node.where { $0.id.eq(node.id) }.update { $0.state = NodeState.archived }.execute(database)
    }
    await idx.sync(database)

    let queryVec = await StubEmbedder(dimension: 16).embed(["t — q"])![0]!
    #expect(!indexStore.knn(query: queryVec, k: 5, includeArchived: false).contains { $0.itemID == looseEnd.id.uuidString })

    try await database.write { database in
      try Node.where { $0.id.eq(node.id) }.update { $0.state = NodeState.active }.execute(database)
    }
    await idx.sync(database)

    let restoredHits = indexStore.knn(query: queryVec, k: 5, includeArchived: false)
    #expect(restoredHits.contains { $0.itemID == looseEnd.id.uuidString })
  }

  @Test func repointUpdatesNodeWithoutChangingHash() async throws {
    let database = try openCanonicalDatabase(at: tempURL("semidx-repoint"))
    let nodeA = Node(name: "A", kind: NodeKind.project)
    let nodeB = Node(name: "B", kind: NodeKind.strand)
    try await database.write { database in
      try Node.insert { nodeA }.execute(database)
      try Node.insert { nodeB }.execute(database)
    }
    let event = try makeEvent(database, node: nodeA)
    let looseEnd = LooseEnd(nodeID: nodeA.id, sourceEventID: event.id, text: "t", quote: "q")
    try await database.write { try LooseEnd.insert { looseEnd }.execute($0) }

    let indexStore = store()
    let idx = SemanticIndexer(store: indexStore, embedder: StubEmbedder(dimension: 16))
    await idx.sync(database)
    let hashBefore = indexStore.existingItems()[looseEnd.id.uuidString]

    try await database.write { database in
      try LooseEnd.where { $0.id.eq(looseEnd.id) }.update { $0.nodeID = nodeB.id }.execute(database)
    }
    await idx.sync(database)

    // content_hash for the loose end is unchanged (repoint is metadata-only, not nodeA re-embed).
    #expect(indexStore.existingItems()[looseEnd.id.uuidString] == hashBefore)
    let queryVec = await StubEmbedder(dimension: 16).embed(["t — q"])![0]!
    let hits = indexStore.knn(query: queryVec, k: 5, includeArchived: false)
    #expect(hits.first(where: { $0.itemID == looseEnd.id.uuidString })?.nodeID == nodeB.id.uuidString)
  }

  @Test func changedTextReEmbedsWithNewContent() async throws {
    let database = try openCanonicalDatabase(at: tempURL("semidx-changehash"))
    let node = Node(name: "N", kind: NodeKind.project, description: "original description")
    try await database.write { try Node.insert { node }.execute($0) }

    let indexStore = store()
    let idx = SemanticIndexer(store: indexStore, embedder: StubEmbedder(dimension: 16))
    await idx.sync(database)
    let hashBefore = indexStore.existingItems()[node.id.uuidString]

    try await database.write { database in
      try Node.where { $0.id.eq(node.id) }.update { $0.description = "changed description" }.execute(database)
    }
    await idx.sync(database)
    #expect(indexStore.existingItems()[node.id.uuidString] != hashBefore)   // content_hash changed → re-embedded

    let newVec = await StubEmbedder(dimension: 16).embed(["N — changed description"])![0]!
    let hits = indexStore.knn(query: newVec, k: 1, includeArchived: false)
    #expect(hits.first?.itemID == node.id.uuidString)
    #expect(hits.first!.similarity > 0.99)   // the stored vector IS the new content'indexStore embedding
  }

  @Test func failedEmbeddingIsRetriedOnNextSyncNotPermanentlySkipped() async throws {
    let database = try openCanonicalDatabase(at: tempURL("semidx-nilembed-retry"))
    let node = Node(name: "N", kind: NodeKind.project)
    try await database.write { try Node.insert { node }.execute($0) }
    let event = try makeEvent(database, node: node, kind: CaptureKind.ccSession, workSummary: "wired up refunds")
    let looseEnd = LooseEnd(nodeID: node.id, sourceEventID: event.id, text: "wire up refunds", quote: "TODO refunds")
    try await database.write { try LooseEnd.insert { looseEnd }.execute($0) }

    let indexStore = store()

    // First sync: embedder fails entirely (e.g. model asset not yet downloaded). None of these
    // brand-new items may be marked done — otherwise they'd be permanently unsearchable.
    let failingIdx = SemanticIndexer(store: indexStore, embedder: NilEmbedder(dimension: 16))
    await failingIdx.sync(database)
    #expect(indexStore.existingItems().isEmpty)

    // Second sync: embedder recovers. The same items must be retried (not starved by nodeA stale
    // "already handled" marker) and become searchable.
    let workingIdx = SemanticIndexer(store: indexStore, embedder: StubEmbedder(dimension: 16))
    await workingIdx.sync(database)

    let items = indexStore.existingItems()
    #expect(items.keys.contains(node.id.uuidString))
    #expect(items.keys.contains(looseEnd.id.uuidString))
    #expect(items.keys.contains(event.id.uuidString))

    let queryVec = await StubEmbedder(dimension: 16).embed(["wire up refunds — TODO refunds"])![0]!
    let hits = indexStore.knn(query: queryVec, k: 5, includeArchived: false)
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

    let byID = Dictionary(items.map { ($0.itemID, $0) }, uniquingKeysWith: { nodeA, _ in nodeA })
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
    let byID = Dictionary(items.map { ($0.itemID, $0) }, uniquingKeysWith: { nodeA, _ in nodeA })

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
