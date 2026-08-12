// Tests/PensieveKitTests/TranslationStoreTests.swift
import Testing
import Foundation
@testable import PensieveKit

@Suite struct TranslationStoreTests {
  private func store(_ name: String) -> TranslationStore {
    TranslationStore(url: tempURL(name))
  }

  @Test func roundTripsATranslation() {
    let translationStore = store("translation-roundtrip")
    translationStore.put(field: .narration, sourceText: "Fixed the sync agent",
                         language: "de", text: "Den Sync-Agenten reparoiert")
    #expect(translationStore.translation(field: .narration, sourceText: "Fixed the sync agent",
                                         language: "de") == "Den Sync-Agenten reparoiert")
  }

  @Test func missesOnADifferentField() {
    let translationStore = store("translation-field-miss")
    translationStore.put(field: .narration, sourceText: "same text", language: "de", text: "gleich")
    #expect(translationStore.translation(field: .looseEndText, sourceText: "same text",
                                        language: "de") == nil)
  }

  @Test func missesOnADifferentLanguage() {
    let translationStore = store("translation-language-miss")
    translationStore.put(field: .nodeName, sourceText: "Background sync", language: "de",
                         text: "Hintergrund-Synchronisierung")
    #expect(translationStore.translation(field: .nodeName, sourceText: "Background sync",
                                        language: "fr") == nil)
  }

  /// The invalidation mechanism: the key is derived from the source text, so editing the source
  /// orphans the old row rather than returning it. No explicit staleness check anywhere.
  @Test func changedSourceTextMissesRatherThanReturningStaleText() {
    let translationStore = store("translation-stale")
    translationStore.put(field: .looseEndText, sourceText: "the original summary",
                         language: "de", text: "die ursprüngliche Zusammenfassung")
    #expect(translationStore.translation(field: .looseEndText, sourceText: "the edited summary",
                                        language: "de") == nil)
  }

  @Test func pruningDropsOrphansAndKeepsLiveRows() {
    let translationStore = store("translation-prune")
    translationStore.put(field: .nodeName, sourceText: "live", language: "de", text: "lebendig")
    translationStore.put(field: .nodeName, sourceText: "orphan", language: "de", text: "Waise")
    translationStore.pruneKeeping(sourceTexts: ["live"])
    #expect(translationStore.translation(field: .nodeName, sourceText: "live", language: "de") == "lebendig")
    #expect(translationStore.translation(field: .nodeName, sourceText: "orphan", language: "de") == nil)
  }

  /// Empty live set deletes everything — the destructive branch needs explicit coverage.
  @Test func pruningWithEmptyLiveSetDeletesEverything() {
    let translationStore = store("translation-prune-empty")
    translationStore.put(field: .nodeName, sourceText: "first", language: "de", text: "Erste")
    translationStore.put(field: .nodeDescription, sourceText: "second", language: "de", text: "Zweite")
    translationStore.pruneKeeping(sourceTexts: [])
    #expect(translationStore.translation(field: .nodeName, sourceText: "first", language: "de") == nil)
    #expect(translationStore.translation(field: .nodeDescription, sourceText: "second", language: "de") == nil)
  }

  /// The trust gate as a type: there is no case that could name a quote or a transcript message.
  @Test func fieldsAreExactlyTheFourTranslatableOnes() {
    #expect(Set(TranslationField.allCases.map(\.rawValue))
            == ["narration", "looseEndText", "nodeName", "nodeDescription"])
  }
}
