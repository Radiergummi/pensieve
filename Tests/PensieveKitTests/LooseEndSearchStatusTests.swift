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

/// After a close, the default-scope page must not silently shrink. The agreement test builds index
/// and canonical together and so cannot catch a write path that updates only one of them.
@Test func aClosedEndLeavesTheDefaultScopeWithoutShrinkingThePage() throws {
  let database = try openCanonicalDatabase(at: tempURL("stale-close"))
  let keptID = try seedLooseEnd(database, text: "kestrel alpha", quote: "kestrel alpha")
  let closedID = try seedLooseEnd(database, text: "kestrel beta", quote: "kestrel beta")
  let store = SearchIndexStore(url: tempURL("stale-close-index"))
  let corpus = try EmbeddableCorpus.gather(database)
  store.rebuild(items: corpus, corpusHash: SearchIndexer.corpusHash(corpus))

  #expect(try LooseEndCommands.resolve(database, id: closedID, status: .done))
  store.updateStatus(itemID: closedID.uuidString, status: LooseEndStatus.done.rawValue)

  let visible = Set(try database.read { try Node.all.fetchAll($0) }.map(\.id))
  let hits = SearchQueries.search(query: "kestrel",
                                  scope: SearchScope(visibleNodeIDs: visible),
                                  store: store, database)
  #expect(hits.map(\.id) == [keptID])
}
