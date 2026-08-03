import Testing
import Foundation
import SQLiteData
@testable import PensieveKit

@Suite struct SearchIndexerTests {
  private func tempStore() -> SearchIndexStore {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("searchidx-\(UUID().uuidString).sqlite")
    return SearchIndexStore(url: url)
  }

  private func item(_ itemID: String, text: String, files: String = "",
                    state: String = "active") -> EmbeddableItem {
    EmbeddableItem(itemID: itemID, kind: "event", nodeID: "n1", state: state,
                   text: text, files: files)
  }

  @Test func corpusHashIsStableAndOrderIndependent() {
    let first = item("a", text: "alpha")
    let second = item("b", text: "beta")
    #expect(SearchIndexer.corpusHash([first, second]) == SearchIndexer.corpusHash([second, first]))
    #expect(SearchIndexer.corpusHash([first]) != SearchIndexer.corpusHash([second]))
  }

  @Test func corpusHashNoticesAFilesOnlyChange() {
    let without = item("a", text: "alpha")
    let with = item("a", text: "alpha", files: "Sources/A.swift")
    #expect(SearchIndexer.corpusHash([without]) != SearchIndexer.corpusHash([with]))
  }

  @Test func corpusHashNoticesAStateChange() {
    #expect(SearchIndexer.corpusHash([item("a", text: "alpha")])
            != SearchIndexer.corpusHash([item("a", text: "alpha", state: "archived")]))
  }

  @Test func syncBuildsTheIndexFromTheLiveCorpus() async throws {
    let database = try openCanonicalDatabase(at: tempURL("searchidx-build"))
    let node = Node(name: "Background sync agent", kind: NodeKind.project)
    try await database.write { database in try Node.insert { node }.execute(database) }
    let store = tempStore()
    SearchIndexer(store: store).sync(database)
    #expect(store.state() == .ready)
    let hits = store.search(FTSQueryBuilder.build("background ")!, limit: 10, includeArchived: false)
    #expect(hits.map(\.itemID) == [node.id.uuidString])
  }

  @Test func unchangedCorpusSkipsTheRebuild() async throws {
    let database = try openCanonicalDatabase(at: tempURL("searchidx-guard"))
    let node = Node(name: "Alpha", kind: NodeKind.project)
    try await database.write { database in try Node.insert { node }.execute(database) }
    let store = tempStore()
    let indexer = SearchIndexer(store: store)
    indexer.sync(database)
    let firstHash = store.storedCorpusHash()

    indexer.sync(database)   // nothing changed
    #expect(store.storedCorpusHash() == firstHash)

    try await database.write { database in
      try Node.insert { Node(name: "Beta", kind: NodeKind.project) }.execute(database)
    }
    indexer.sync(database)
    #expect(store.storedCorpusHash() != firstHash)
    #expect(store.search(FTSQueryBuilder.build("beta ")!, limit: 10, includeArchived: false).count == 1)
  }

  @Test func hygieneAppliesToTheSearchIndexToo() async throws {
    let database = try openCanonicalDatabase(at: tempURL("searchidx-hygiene"))
    let node = Node(name: "Pensieve", kind: NodeKind.project)
    let source = Source(nodeID: node.id, kind: SourceKind.gitRepo, key: "/p/\(node.id)")
    try await database.write { database in
      try Node.insert { node }.execute(database)
      try Source.insert { source }.execute(database)
      try Event.insert {
        Event(nodeID: node.id, sourceID: source.id, occurredAt: Date(),
              kind: CaptureKind.gitCheckout, summary: "checkout main",
              detailJSON: "{}", fingerprint: "co")
      }.execute(database)
    }
    let store = tempStore()
    SearchIndexer(store: store).sync(database)
    #expect(store.search(FTSQueryBuilder.build("checkout ")!, limit: 10,
                         includeArchived: false).isEmpty)
  }
}
