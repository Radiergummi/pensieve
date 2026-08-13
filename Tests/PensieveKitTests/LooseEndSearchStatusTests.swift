import Foundation
import Testing
import SQLiteData
@testable import PensieveKit

/// Seeds one node + source + event + loose end, and returns the loose end's id. File-private for the
/// same reason the twin in `LooseEndResolutionTests` is: the name is already taken twice elsewhere.
@discardableResult
private func seedLooseEnd(_ database: any DatabaseWriter, text: String = "t", quote: String = "q",
                          status: LooseEndStatus = .open, label: String = "") throws -> UUID {
  let node = Node(name: "N")
  let source = Source(nodeID: node.id, kind: SourceKind.claudeCode, key: "/src/\(UUID().uuidString)")
  let event = Event(nodeID: node.id, sourceID: source.id, occurredAt: Date(),
                    kind: CaptureKind.ccSession, summary: "s", detailJSON: "{}")
  let looseEnd = LooseEnd(nodeID: node.id, sourceEventID: event.id, text: text, quote: quote,
                          status: status, label: label)
  try database.write { database in
    try Node.insert { node }.execute(database)
    try Source.insert { source }.execute(database)
    try Event.insert { event }.execute(database)
    try LooseEnd.insert { looseEnd }.execute(database)
  }
  return looseEnd.id
}

@Test func searchableIsAnAllowListNotADenyList() {
  #expect(LooseEndStatus.searchable(includeClosed: false) == [.open])
  #expect(Set(LooseEndStatus.searchable(includeClosed: true)) == [.open, .done, .dropped])
  #expect(LooseEndStatus.done.isSearchable(includeClosed: false) == false)
  #expect(LooseEndStatus.done.isSearchable(includeClosed: true))
  #expect(LooseEndStatus.open.isSearchable(includeClosed: false))
}

/// The whole point of schema v4: the index must be able to exclude a closed row in SQL. If it
/// cannot, the resolver drops it afterwards and the page silently shrinks.
@Test func theIndexExcludesClosedRowsUnlessAskedForThem() throws {
  let store = SearchIndexStore(url: tempURL("idx-status"))
  let nodeID = UUID().uuidString
  let openItem = EmbeddableItem(itemID: UUID().uuidString, kind: "loose_end", nodeID: nodeID,
                                state: NodeState.active.rawValue, text: "kestrel migration notes",
                                status: LooseEndStatus.open.rawValue)
  let closedItem = EmbeddableItem(itemID: UUID().uuidString, kind: "loose_end", nodeID: nodeID,
                                  state: NodeState.active.rawValue, text: "kestrel migration notes",
                                  status: LooseEndStatus.done.rawValue)
  store.rebuild(items: [openItem, closedItem], corpusHash: "h1")

  let query = FTSQueryBuilder.build("kestrel", file: nil)!
  let narrow = store.search(query, limit: 10, includeArchived: false, includeClosed: false)
  #expect(narrow.map(\.itemID) == [openItem.itemID])
  let wide = store.search(query, limit: 10, includeArchived: false, includeClosed: true)
  #expect(Set(wide.map(\.itemID)) == [openItem.itemID, closedItem.itemID])
}

/// Closing a loose end changes only its status. If the corpus hash ignores status, the rebuild guard
/// skips the rebuild, the index keeps calling the row open, and a closed end keeps surfacing in the
/// default scope forever.
@Test func corpusHashChangesWhenOnlyAStatusChanges() {
  let itemID = UUID().uuidString, nodeID = UUID().uuidString
  let asOpen = EmbeddableItem(itemID: itemID, kind: "loose_end", nodeID: nodeID,
                              state: NodeState.active.rawValue, text: "same text",
                              status: LooseEndStatus.open.rawValue)
  let asDone = EmbeddableItem(itemID: itemID, kind: "loose_end", nodeID: nodeID,
                              state: NodeState.active.rawValue, text: "same text",
                              status: LooseEndStatus.done.rawValue)
  #expect(SearchIndexer.corpusHash([asOpen]) != SearchIndexer.corpusHash([asDone]))
}

/// The path table holds only event rows, which are never closable — so it carries no status filter.
/// Pinned so a future producer that puts files on a closable item is forced to revisit this.
@Test func onlyEventRowsEverCarryFilePaths() throws {
  let database = try openCanonicalDatabase(at: tempURL("idx-files-kind"))
  try seedLooseEnd(database, quote: "an end")
  let corpus = try EmbeddableCorpus.gather(database)
  #expect(corpus.allSatisfy { $0.files.isEmpty || $0.kind == "event" })
}

@Test func gatherIndexesClosedEndsTaggedWithTheirStatus() throws {
  let database = try openCanonicalDatabase(at: tempURL("corpus-closed"))
  let openID = try seedLooseEnd(database, quote: "open work")
  let doneID = try seedLooseEnd(database, quote: "finished work", status: .done)
  let droppedID = try seedLooseEnd(database, quote: "abandoned work", status: .dropped)

  let corpus = try EmbeddableCorpus.gather(database)
  let byID = Dictionary(corpus.filter { $0.kind == "loose_end" }.map { ($0.itemID, $0.status) },
                        uniquingKeysWith: { first, _ in first })
  #expect(byID[openID.uuidString] == LooseEndStatus.open.rawValue)
  #expect(byID[doneID.uuidString] == LooseEndStatus.done.rawValue)
  #expect(byID[droppedID.uuidString] == LooseEndStatus.dropped.rawValue)
}

/// A thumbs-down asserts the text was never real content, so indexing it would pollute retrieval.
/// A closed end WAS real work. The two axes stay apart in the corpus exactly as they do in the model.
@Test func gatherStillExcludesNoiseLabelledEnds() throws {
  let database = try openCanonicalDatabase(at: tempURL("corpus-noise"))
  let noisy = try seedLooseEnd(database, quote: "not a loose end", label: LooseEndLabel.noise)
  let noisyAndClosed = try seedLooseEnd(database, quote: "noisy and closed",
                                        status: .done, label: LooseEndLabel.noise)
  let corpus = try EmbeddableCorpus.gather(database)
  let ids = Set(corpus.map(\.itemID))
  #expect(!ids.contains(noisy.uuidString))
  #expect(!ids.contains(noisyAndClosed.uuidString))
}

/// A translated document must agree with its original about eligibility. `EmbeddableItem.status`
/// defaults to "open", so a helper that inherited the default would put a German row for a closed
/// loose end into the default scope its English original is not in.
@Test func aTranslatedClosedEndCarriesTheClosedStatusOnBothDocuments() throws {
  let database = try openCanonicalDatabase(at: tempURL("corpus-translated-closed"))
  let closedID = try seedLooseEnd(database, text: "Ship the sync agent", quote: "ship it",
                                  status: .done)
  let translations = TranslationStore(url: tempURL("corpus-translated-closed-cache"))
  translations.put(field: .looseEndText, sourceText: "Ship the sync agent", language: "de",
                   text: "Den Sync-Agenten ausliefern")

  let corpus = try EmbeddableCorpus.gather(database, translations: translations, language: "de")
  let documents = corpus.filter { $0.itemID == closedID.uuidString }
  #expect(documents.count == 2)
  #expect(documents.allSatisfy { $0.status == LooseEndStatus.done.rawValue })
}

/// The index filter and the canonical re-check must agree for every scope. If they disagree, rows
/// pass the SQL query and are then dropped by the resolver — the page shrinks and nothing fails.
/// Asserted end-to-end through the real query path rather than by comparing the two rules by eye.
@Test func indexAndResolverAgreeAboutClosedEndsInEveryScope() throws {
  let database = try openCanonicalDatabase(at: tempURL("agree-closed"))
  let openID = try seedLooseEnd(database, text: "kestrel migration", quote: "kestrel migration")
  let doneID = try seedLooseEnd(database, text: "kestrel rollout", quote: "kestrel rollout",
                                status: .done)
  let store = SearchIndexStore(url: tempURL("agree-closed-index"))
  let corpus = try EmbeddableCorpus.gather(database)
  store.rebuild(items: corpus, corpusHash: SearchIndexer.corpusHash(corpus))
  let visible = Set(try database.read { try Node.all.fetchAll($0) }.map(\.id))

  let narrow = SearchQueries.search(
    query: "kestrel",
    scope: SearchScope(visibleNodeIDs: visible, includeArchived: false, includeClosed: false),
    store: store, database)
  #expect(narrow.map(\.id).contains(openID))
  #expect(!narrow.map(\.id).contains(doneID))

  let wide = SearchQueries.search(
    query: "kestrel",
    scope: SearchScope(visibleNodeIDs: visible, includeArchived: false, includeClosed: true),
    store: store, database)
  #expect(Set(wide.map(\.id)) == [openID, doneID])
  #expect(wide.first { $0.id == doneID }?.status == .done)
  #expect(wide.first { $0.id == openID }?.status == .open)
}

/// The same agreement, reached through the TRANSLATION path — the only route by which a closed end
/// can enter the index tagged open (`EmbeddableItem.status` defaults to "open"). A German query
/// matches the translated document; the resolver re-reads English canonical and must still apply the
/// allow-list, so the closed end is absent in the narrow scope and present in the wide one.
@Test func aTranslatedClosedEndObeysTheScopeThroughTheQueryPath() throws {
  let database = try openCanonicalDatabase(at: tempURL("agree-translated"))
  let closedID = try seedLooseEnd(database, text: "Ship the sync agent", quote: "ship it",
                                  status: .done)
  let translations = TranslationStore(url: tempURL("agree-translated-cache"))
  translations.put(field: .looseEndText, sourceText: "Ship the sync agent", language: "de",
                   text: "Den Sync-Agenten ausliefern")
  let store = SearchIndexStore(url: tempURL("agree-translated-index"))
  let corpus = try EmbeddableCorpus.gather(database, translations: translations, language: "de")
  store.rebuild(items: corpus, corpusHash: SearchIndexer.corpusHash(corpus))
  let visible = Set(try database.read { try Node.all.fetchAll($0) }.map(\.id))

  let narrow = SearchQueries.search(query: "Sync-Agenten",
                                    scope: SearchScope(visibleNodeIDs: visible),
                                    store: store, translations: translations, language: "de",
                                    database)
  #expect(!narrow.map(\.id).contains(closedID))

  let wide = SearchQueries.search(query: "Sync-Agenten",
                                  scope: SearchScope(visibleNodeIDs: visible, includeClosed: true),
                                  store: store, translations: translations, language: "de",
                                  database)
  #expect(wide.map(\.id) == [closedID])
  #expect(wide.first?.status == .done)
}

/// `updateStatus` must make the INDEX stop returning a closed row, not merely rely on the resolver to
/// drop it afterwards. Asserted against the store directly, which is the only layer where this is
/// observable: `SearchQueries.search` over-fetches (`max(limit * 8, 50)`) and grows `k` on a shortfall,
/// so it backfills around a stale row and returns a correct, full page either way.
///
/// That over-fetch is why the first two versions of this test were VACUOUS — both passed with
/// `updateStatus` commented out (verified by running the mutation, not by reasoning about it). The
/// spec's "the result page silently shrinks" framing does not survive contact with the retry loop; what
/// staleness actually costs is wasted top-k slots here, and a false NEGATIVE in the sibling test below.
@Test func updateStatusStopsTheIndexReturningAClosedRow() throws {
  let database = try openCanonicalDatabase(at: tempURL("stale-close"))
  let keptID = try seedLooseEnd(database, text: "kestrel alpha", quote: "kestrel alpha")
  let closedID = try seedLooseEnd(database, text: "kestrel beta", quote: "kestrel beta")
  let store = SearchIndexStore(url: tempURL("stale-close-index"))
  let corpus = try EmbeddableCorpus.gather(database)
  store.rebuild(items: corpus, corpusHash: SearchIndexer.corpusHash(corpus))

  #expect(try LooseEndCommands.resolve(database, id: closedID, status: .done))
  store.updateStatus(itemID: closedID.uuidString, status: LooseEndStatus.done.rawValue)

  let query = FTSQueryBuilder.build("kestrel", file: nil)!
  let candidates = store.search(query, limit: 50, includeArchived: false, includeClosed: false)
  #expect(!candidates.map(\.itemID).contains(closedID.uuidString))
  #expect(candidates.map(\.itemID).contains(keptID.uuidString))
  // And the widened scope still reaches it — the row was updated, not deleted.
  let wide = store.search(query, limit: 50, includeArchived: false, includeClosed: true)
  #expect(wide.map(\.itemID).contains(closedID.uuidString))
}

/// The REOPEN direction is the one where a stale index is a correctness bug rather than wasted work:
/// the index says `done`, so the SQL filter excludes the row in the default scope, and live work
/// becomes unfindable. The resolver cannot rescue this — it never sees a candidate to admit.
/// Mutation-verified: removing the `updateStatus` call below turns this red (0 hits).
@Test func aReopenedEndBecomesFindableAgainWithoutAFullRebuild() throws {
  let database = try openCanonicalDatabase(at: tempURL("stale-reopen"))
  let id = try seedLooseEnd(database, text: "kestrel rollout", quote: "kestrel rollout",
                            status: .done)
  let store = SearchIndexStore(url: tempURL("stale-reopen-index"))
  let corpus = try EmbeddableCorpus.gather(database)
  store.rebuild(items: corpus, corpusHash: SearchIndexer.corpusHash(corpus))

  #expect(try LooseEndCommands.resolve(database, id: id, status: .open))
  store.updateStatus(itemID: id.uuidString, status: LooseEndStatus.open.rawValue)

  let visible = Set(try database.read { try Node.all.fetchAll($0) }.map(\.id))
  let hits = SearchQueries.search(query: "kestrel",
                                  scope: SearchScope(visibleNodeIDs: visible),
                                  store: store, database)
  #expect(hits.map(\.id) == [id])
}
