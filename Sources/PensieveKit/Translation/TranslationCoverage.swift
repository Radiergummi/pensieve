import Foundation

/// How much of the translatable corpus is actually translated, and what is left.
///
/// Exists because the feature is otherwise indistinguishable from a broken one: on 2026-08-14 the live
/// store held 2 translations against 1,294 translatable texts, and nothing said so. Two of the three
/// fields the corpus looks up had no writer at all.
///
/// Counted by DISTINCT source text, because that is how `TranslationStore` is keyed — see
/// `TranslatableCorpus`.
public struct TranslationCoverage: Sendable {
  /// The language this was measured FOR, carried ON the measurement rather than beside it. A re-measure
  /// after a language switch takes a full corpus gather, and during that window a caller holding the
  /// previous result must be able to tell that it belongs to the previous language — otherwise the
  /// backfill translates language A's missing list into language B. The same stale-async-write shape
  /// slice 3a's narration window and `DetailView`'s `loadedNodeID == node.id` gate already fixed.
  public let language: String
  /// Every unit the corpus can look up, translated or not.
  public let total: Int
  /// The units with no stored translation, in corpus order — the backfill's work list. Deliberately the
  /// ONLY count kept: `translated` is derived from it, so the number shown and the work done cannot
  /// disagree.
  public let missing: [TranslatableUnit]

  public var translated: Int { total - missing.count }

  public init(language: String, total: Int, missing: [TranslatableUnit]) {
    self.language = language
    self.total = total
    self.missing = missing
  }

  /// One store read per unit. `language == off` returns an empty coverage WITHOUT reading, so a
  /// disabled feature opens no file — the same "off means off" rule the lazy stores in `AppModel`
  /// follow.
  public static func measure(units: [TranslatableUnit], store: TranslationStore,
                             language: String) -> TranslationCoverage {
    guard !language.isEmpty else { return TranslationCoverage(language: language, total: 0, missing: []) }
    let missing = units.filter {
      store.translation(field: $0.field, sourceText: $0.sourceText, language: language) == nil
    }
    return TranslationCoverage(language: language, total: units.count, missing: missing)
  }
}
