// Tests/PensieveKitTests/TranslatedSearchTests.swift
import Testing
import Foundation
import SQLiteData
@testable import PensieveKit

@Suite struct TranslatedSearchTests {
  private struct Fixture {
    let database: any DatabaseReader
    let store: SearchIndexStore
    let translations: TranslationStore
    let node: Node
    let scope: SearchScope
  }

  private func fixture(_ name: String) async throws -> Fixture {
    let database = try openCanonicalDatabase(at: tempURL("\(name)-canonical"))
    let node = Node(name: "Background sync", kind: NodeKind.project)
    try await database.write { database in try Node.insert { node }.execute(database) }
    let translations = TranslationStore(url: tempURL("\(name)-translations"))
    translations.put(field: .nodeName, sourceText: "Background sync", language: "de",
                     text: "Hintergrund-Synchronisierung")
    let store = tempSearchStore()
    SearchIndexer(store: store, translations: translations, language: "de").sync(database)
    return Fixture(database: database, store: store, translations: translations, node: node,
                   scope: SearchScope(visibleNodeIDs: [node.id]))
  }

  @Test func aGermanQueryFindsTheNodeThroughItsTranslation() async throws {
    let fixture = try await fixture("german-query")
    let hits = SearchQueries.search(query: "Hintergrund", scope: fixture.scope,
                                    store: fixture.store, translations: fixture.translations,
                                    language: "de", fixture.database)
    #expect(hits.map(\.nodeID) == [fixture.node.id])
  }

  /// Correction 2. A hit the user cannot see the reason for is a bug, not a cosmetic issue: the
  /// resolver highlights against canonical ENGLISH text, so without the translated body as a
  /// candidate this row renders with an empty match.
  @Test func aGermanOnlyMatchIsHighlighted() async throws {
    let fixture = try await fixture("german-highlight")
    let hits = SearchQueries.search(query: "Hintergrund", scope: fixture.scope,
                                    store: fixture.store, translations: fixture.translations,
                                    language: "de", fixture.database)
    #expect(hits.count == 1)
    #expect(!hits[0].snippet.match.isEmpty)
  }

  /// Both language documents match "sync" as a prefix — the English document's own token, and the
  /// leading four characters of the German compound's second token ("Synchronisierung") — so the same
  /// node must not appear twice. The query is asserted to actually reach the index with two raw
  /// candidates sharing the node's `itemID` FIRST, so this test cannot go quiet the way its
  /// predecessor did: querying the full word "Synchronisierung" turns into a 16-character FTS5 prefix
  /// match that only the German document's token can satisfy, so the English document never became a
  /// second candidate and the dedup guard was never exercised.
  @Test func aTermMatchingBothLanguagesYieldsOneHit() async throws {
    let fixture = try await fixture("dedup")
    let ftsQuery = FTSQueryBuilder.build("sync")!
    let rawCandidates = fixture.store.search(ftsQuery, limit: 50, includeArchived: false)
    #expect(rawCandidates.filter { $0.itemID == fixture.node.id.uuidString }.count >= 2)

    let hits = SearchQueries.search(query: "sync", scope: fixture.scope,
                                    store: fixture.store, translations: fixture.translations,
                                    language: "de", fixture.database)
    #expect(hits.filter { $0.nodeID == fixture.node.id }.count == 1)
  }

  /// The English path must be unaffected — same hit, same highlight, translations present or not.
  @Test func theEnglishPathIsUnchangedByThePresenceOfATranslation() async throws {
    let fixture = try await fixture("english-unchanged")
    let hits = SearchQueries.search(query: "background", scope: fixture.scope,
                                    store: fixture.store, translations: fixture.translations,
                                    language: "de", fixture.database)
    #expect(hits.count == 1)
    #expect(hits[0].snippet.match.lowercased() == "background")
  }

  /// Task 6 tags a translated loose-end document `kind: "loose_end"`, which is only verified by
  /// inspection today. If that tag were ever wrong (e.g. "node"), `buildHits` would map the hit to
  /// `.node` and resolve it against the Node table using a loose-end id — the row would exist in the
  /// index and never surface in results. Only a behavioral test over a real loose end catches that.
  @Test func aGermanQueryFindsALooseEndThroughItsTranslation() async throws {
    let database = try openCanonicalDatabase(at: tempURL("german-looseend-canonical"))
    let node = Node(name: "Background sync", kind: NodeKind.project)
    try await database.write { database in try Node.insert { node }.execute(database) }
    let source = Source(nodeID: node.id, kind: SourceKind.gitRepo, key: "/p/\(node.id)-\(UUID())")
    let event = Event(nodeID: node.id, sourceID: source.id, occurredAt: Date(),
                      kind: CaptureKind.gitCommit, summary: "groundwork", detailJSON: "{}",
                      fingerprint: UUID().uuidString)
    try await database.write { database in
      try Source.insert { source }.execute(database)
      try Event.insert { event }.execute(database)
    }
    let looseEnd = LooseEnd(nodeID: node.id, sourceEventID: event.id,
                            text: "Decide the retry policy",
                            quote: "we should decide the retry policy for sync")
    try await database.write { database in try LooseEnd.insert { looseEnd }.execute(database) }
    let translations = TranslationStore(url: tempURL("german-looseend-translations"))
    translations.put(field: .looseEndText, sourceText: looseEnd.text, language: "de",
                     text: "Entscheide die Wiederholungsrichtlinie")
    let store = tempSearchStore()
    SearchIndexer(store: store, translations: translations, language: "de").sync(database)
    let scope = SearchScope(visibleNodeIDs: [node.id])
    let hits = SearchQueries.search(query: "Wiederholungsrichtlinie", scope: scope, store: store,
                                    translations: translations, language: "de", database)
    #expect(hits.count == 1)
    #expect(hits.first?.kind == .looseEnd)
    #expect(hits.first?.id == looseEnd.id)
    #expect(!(hits.first?.snippet.match.isEmpty ?? true))
  }
}
