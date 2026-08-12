import Testing
import Foundation
import SQLiteData
@testable import PensieveKit

@Suite struct TranslatedCorpusTests {
  @Test func gatherEmitsATranslatedDocumentBesideTheOriginal() async throws {
    let database = try openCanonicalDatabase(at: tempURL("corpus-translated"))
    let node = Node(name: "Background sync", kind: NodeKind.project)
    try await database.write { database in try Node.insert { node }.execute(database) }

    let translations = TranslationStore(url: tempURL("corpus-translated-cache"))
    // gather indexes a node as "name — description"; with an empty description that is just the name.
    translations.put(field: .nodeName, sourceText: "Background sync", language: "de",
                     text: "Hintergrund-Synchronisierung")

    let items = try EmbeddableCorpus.gather(database, translations: translations, language: "de")
    let forNode = items.filter { $0.itemID == node.id.uuidString }
    #expect(forNode.count == 2)
    #expect(forNode.contains { $0.language == "" && $0.text == "Background sync" })
    #expect(forNode.contains { $0.language == "de" && $0.text == "Hintergrund-Synchronisierung" })
  }

  /// The trust gate, tested: the translated loose-end document carries the summary only. `gather`
  /// indexes the original as "text — quote"; the translation must NOT re-append the English quote,
  /// which would both translate-adjacent a verbatim citation and manufacture a duplicate hit.
  @Test func theTranslatedLooseEndDocumentExcludesTheQuote() async throws {
    let database = try openCanonicalDatabase(at: tempURL("corpus-translated-quote"))
    let node = Node(name: "Project", kind: NodeKind.project)
    let source = Source(nodeID: node.id, kind: SourceKind.gitRepo, key: "/p/\(node.id)")
    let event = Event(nodeID: node.id, sourceID: source.id, occurredAt: Date(),
                      kind: CaptureKind.ccSession, summary: "a session",
                      detailJSON: "{}", fingerprint: "session-1")
    let looseEnd = LooseEnd(nodeID: node.id, sourceEventID: event.id, text: "Ship the sync agent",
                            quote: "we should ship the sync agent this week")
    try await database.write { database in
      try Node.insert { node }.execute(database)
      try Source.insert { source }.execute(database)
      try Event.insert { event }.execute(database)
      try LooseEnd.insert { looseEnd }.execute(database)
    }
    let translations = TranslationStore(url: tempURL("corpus-translated-quote-cache"))
    translations.put(field: .looseEndText, sourceText: "Ship the sync agent", language: "de",
                     text: "Den Sync-Agenten ausliefern")

    let items = try EmbeddableCorpus.gather(database, translations: translations, language: "de")
    let translated = items.filter { $0.itemID == looseEnd.id.uuidString && $0.language == "de" }
    #expect(translated.count == 1)
    #expect(translated[0].text == "Den Sync-Agenten ausliefern")
    #expect(!translated[0].text.contains("this week"))
  }

  /// Off means off: no translated rows, and no reason for the corpus hash to move.
  @Test func gatherEmitsNoTranslationsWhenTheTargetIsOff() async throws {
    let database = try openCanonicalDatabase(at: tempURL("corpus-translated-off"))
    let node = Node(name: "Background sync", kind: NodeKind.project)
    try await database.write { database in try Node.insert { node }.execute(database) }
    let translations = TranslationStore(url: tempURL("corpus-translated-off-cache"))
    translations.put(field: .nodeName, sourceText: "Background sync", language: "de",
                     text: "Hintergrund-Synchronisierung")

    let items = try EmbeddableCorpus.gather(database, translations: translations,
                                           language: TranslationTarget.off)
    #expect(items.allSatisfy { $0.language.isEmpty })
  }

  /// An untranslated item yields exactly one document. Sparse translation is the expected steady
  /// state — the on-demand action translates what the user reads, not the whole corpus.
  @Test func anUntranslatedItemYieldsOneDocument() async throws {
    let database = try openCanonicalDatabase(at: tempURL("corpus-translated-sparse"))
    let node = Node(name: "Never translated", kind: NodeKind.project)
    try await database.write { database in try Node.insert { node }.execute(database) }
    let items = try EmbeddableCorpus.gather(database,
                                           translations: TranslationStore(url: tempURL("corpus-sparse-cache")),
                                           language: "de")
    #expect(items.filter { $0.itemID == node.id.uuidString }.count == 1)
  }
}
