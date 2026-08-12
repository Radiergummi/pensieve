import Testing
import Foundation
import SQLiteData
import GRDB
@testable import PensieveKit

@Suite struct SearchIndexerTests {
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
    let store = tempSearchStore()
    SearchIndexer(store: store).sync(database)
    #expect(store.state() == .ready)
    let hits = store.search(FTSQueryBuilder.build("background ")!, limit: 10, includeArchived: false)
    #expect(hits.map(\.itemID) == [node.id.uuidString])
  }

  @Test func unchangedCorpusSkipsTheRebuild() async throws {
    let database = try openCanonicalDatabase(at: tempURL("searchidx-guard"))
    let node = Node(name: "Alpha", kind: NodeKind.project)
    try await database.write { database in try Node.insert { node }.execute(database) }
    let store = tempSearchStore()
    let indexer = SearchIndexer(store: store)

    indexer.sync(database)
    #expect(store.search(FTSQueryBuilder.build("alpha ")!, limit: 10,
                         includeArchived: false).count == 1)

    // Poison the index out of band, but store the hash the LIVE corpus produces. A guarded sync
    // sees a matching hash and skips, leaving the index empty; an unguarded one rebuilds and
    // brings "Alpha" back. Asserting the emptiness survives is what actually pins the guard —
    // re-reading storedCorpusHash() cannot, since an unconditional rebuild rewrites the same value.
    let liveHash = SearchIndexer.corpusHash(try EmbeddableCorpus.gather(database))
    store.rebuild(items: [], corpusHash: liveHash)
    indexer.sync(database)
    #expect(store.search(FTSQueryBuilder.build("alpha ")!, limit: 10,
                         includeArchived: false).isEmpty)

    // …and a real corpus change still rebuilds, so the guard cannot be satisfied by never syncing.
    try await database.write { database in
      try Node.insert { Node(name: "Beta", kind: NodeKind.project) }.execute(database)
    }
    indexer.sync(database)
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
    let store = tempSearchStore()
    SearchIndexer(store: store).sync(database)
    #expect(store.search(FTSQueryBuilder.build("checkout ")!, limit: 10,
                         includeArchived: false).isEmpty)
  }

  /// Two documents share an `item_id` once a translation exists, and `corpusHash` sorts by `itemID`.
  /// Swift's sort is NOT stable, so without `language` in the sort key the hash depends on input
  /// order — and the rebuild guard (`hash != storedCorpusHash()`) would then fire on every sync,
  /// rebuilding the whole index forever.
  @Test func corpusHashIsOrderIndependentForItemsSharingAnItemID() {
    let english = EmbeddableItem(itemID: "a", kind: "node", nodeID: "n1", state: "active",
                                 text: "Background sync")
    let german = EmbeddableItem(itemID: "a", kind: "node", nodeID: "n1", state: "active",
                                text: "Hintergrund-Synchronisierung", language: "de")
    #expect(SearchIndexer.corpusHash([english, german])
            == SearchIndexer.corpusHash([german, english]))
  }

  @Test func corpusHashNoticesALanguageOnlyChange() {
    let untagged = EmbeddableItem(itemID: "a", kind: "node", nodeID: "n1", state: "active",
                                  text: "same text")
    let tagged = EmbeddableItem(itemID: "a", kind: "node", nodeID: "n1", state: "active",
                                text: "same text", language: "de")
    #expect(SearchIndexer.corpusHash([untagged]) != SearchIndexer.corpusHash([tagged]))
  }

  /// Two documents sharing an item_id are each independently searchable on their own text — this is
  /// what Task 7's dedup-by-item_id depends on, and it holds regardless of whether `language` is
  /// persisted (there is no uniqueness constraint on item_id in the `documents` table). It does NOT
  /// pin that the `language` column itself is written — see `rebuildPersistsLanguagePerDocument`.
  @Test func aTranslatedDocumentIsIndexedUnderTheOriginalItemID() {
    let store = tempSearchStore()
    let english = EmbeddableItem(itemID: "item-1", kind: "node", nodeID: "n1", state: "active",
                                 text: "Background sync agent")
    let german = EmbeddableItem(itemID: "item-1", kind: "node", nodeID: "n1", state: "active",
                                text: "Hintergrund-Synchronisierungsagent", language: "de")
    store.rebuild(items: [english, german], corpusHash: "hash-1")

    let germanHits = store.search(FTSQueryBuilder.build("Hintergrund ")!, limit: 10,
                                 includeArchived: false)
    #expect(germanHits.map(\.itemID) == ["item-1"])

    let englishHits = store.search(FTSQueryBuilder.build("background ")!, limit: 10,
                                  includeArchived: false)
    #expect(englishHits.map(\.itemID) == ["item-1"])
  }

  /// Same-version persistence, NOT a version-mismatch test (its previous name claimed the latter,
  /// with no assertion anywhere near a `schema_version` mismatch — see
  /// `aVersionMismatchDropsAndRecreatesTheSchema` below for the real thing). Reopening at the same
  /// version must NOT discard the index.
  @Test func aSameVersionReopenPreservesTheIndex() throws {
    let url = tempURL("searchidx-v3-reopen")
    let first = SearchIndexStore(url: url)
    first.rebuild(items: [EmbeddableItem(itemID: "a", kind: "node", nodeID: "n1",
                                         state: "active", text: "alpha")],
                  corpusHash: "hash-a")
    #expect(first.state() == .ready)
    let reopened = SearchIndexStore(url: url)
    #expect(reopened.storedCorpusHash() == "hash-a")
  }

  /// The real version-mismatch path (`SearchIndexStore.swift`'s `storedVersion != schemaVersion`
  /// branch): hand-build a v2 index using the OLD 5-column `documents` shape (no `language` column,
  /// the only new schema in Task 5) and a stale `schema_version`. Reopening through `SearchIndexStore`
  /// must drop and recreate the table with the current shape — proven by the `language` column now
  /// existing — and clear the stale hash, so the rebuild guard can't compare against a hash that
  /// predates a schema it never accounted for. Fails if the drop-and-recreate branch were removed:
  /// the legacy table would be reused as-is, with no `language` column and the v2 hash intact.
  @Test func aVersionMismatchDropsAndRecreatesTheSchema() throws {
    let url = tempURL("searchidx-v2-mismatch")
    var configuration = Configuration()
    configuration.busyMode = .timeout(5)
    let legacyPool = try DatabasePool(path: url.path, configuration: configuration)
    try legacyPool.write { database in
      try database.execute(sql: """
        CREATE VIRTUAL TABLE documents USING fts5(
          text, item_id UNINDEXED, kind UNINDEXED, node_id UNINDEXED, state UNINDEXED,
          tokenize = 'unicode61 remove_diacritics 2')
        """)
      try database.execute(sql: """
        CREATE TABLE meta(schema_version INT, corpus_hash TEXT, building INT NOT NULL DEFAULT 0)
        """)
      try database.execute(sql: """
        INSERT INTO meta(schema_version, corpus_hash, building) VALUES (2, 'stale-v2-hash', 0)
        """)
    }

    let reopened = SearchIndexStore(url: url)
    #expect(reopened.storedCorpusHash() == nil)

    var readOnlyConfiguration = Configuration()
    readOnlyConfiguration.readonly = true
    let reader = try DatabaseQueue(path: url.path, configuration: readOnlyConfiguration)
    let columns = try reader.read { database in
      try Row.fetchAll(database, sql: "PRAGMA table_info(documents)")
    }
    #expect(columns.contains { ($0["name"] as String?) == "language" })
  }

  /// `language` is load-bearing for Task 6 (translated documents) and Task 7 (dedup-by-item_id
  /// reasoning about pairs), yet no existing assertion reads it back — `SearchIndexStore`'s
  /// `database` is private, so this opens its own read-only connection to the same index file (the
  /// store's own `Configuration` uses a 5 s busy timeout precisely because several processes open
  /// this file, so a second reader is expected usage) and asserts the persisted values directly.
  @Test func rebuildPersistsLanguagePerDocument() throws {
    let url = tempURL("searchidx-language")
    let store = SearchIndexStore(url: url)
    let english = EmbeddableItem(itemID: "item-1", kind: "node", nodeID: "n1", state: "active",
                                 text: "Background sync agent")
    let german = EmbeddableItem(itemID: "item-1", kind: "node", nodeID: "n1", state: "active",
                                text: "Hintergrund-Synchronisierungsagent", language: "de")
    store.rebuild(items: [english, german], corpusHash: "hash-1")

    var readOnlyConfiguration = Configuration()
    readOnlyConfiguration.readonly = true
    let reader = try DatabaseQueue(path: url.path, configuration: readOnlyConfiguration)
    let languages = try reader.read { database in
      try String.fetchAll(database, sql: "SELECT language FROM documents ORDER BY language")
    }
    #expect(languages == ["", "de"])
    let distinctItemIDCount = try reader.read { database in
      try Int.fetchOne(database, sql: "SELECT COUNT(DISTINCT item_id) FROM documents")
    }
    #expect(distinctItemIDCount == 1)
  }
}
