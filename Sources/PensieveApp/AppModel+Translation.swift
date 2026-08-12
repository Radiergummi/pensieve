// Sources/PensieveApp/AppModel+Translation.swift
import Foundation
import PensieveKit

extension AppModel {
  /// Translate one generated field on demand, store it, and make it findable.
  ///
  /// The write lands in `translation-cache.sqlite`, NOT the canonical store, so it cannot trip the
  /// canonical `ValueObservation` — the same shape as slice 4's Node-only writes, which needed an
  /// explicit refresh. Reindexing is therefore explicit, and debounced: translating eight loose ends
  /// in a row must not cause eight whole-corpus rebuilds.
  func translate(field: TranslationField, sourceText: String) async {
    let language = TranslationTarget.resolved()
    guard !language.isEmpty, !sourceText.isEmpty, let translator else { return }
    guard translationStore.translation(field: field, sourceText: sourceText,
                                       language: language) == nil else { return }
    guard let translated = await translator.translate(sourceText,
                                                      from: TranslationTarget.sourceLanguage,
                                                      to: language) else { return }
    translationStore.put(field: field, sourceText: sourceText, language: language, text: translated)
    await translationDebouncer.schedule()
  }

  /// The stored translation of `sourceText`, or `sourceText` itself. Never generates.
  func displayed(field: TranslationField, sourceText: String) -> String {
    let language = TranslationTarget.resolved()
    guard !language.isEmpty else { return sourceText }
    return translationStore.translation(field: field, sourceText: sourceText,
                                        language: language) ?? sourceText
  }
}
