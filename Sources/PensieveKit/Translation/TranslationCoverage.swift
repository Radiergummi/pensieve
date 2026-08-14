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
  public struct Field: Sendable, Hashable {
    public let field: TranslationField
    public let translated: Int
    public let total: Int
    public init(field: TranslationField, translated: Int, total: Int) {
      self.field = field
      self.translated = translated
      self.total = total
    }
  }

  /// Only fields with at least one unit. A "0 of 0" row reads as a failure in a list.
  public let fields: [Field]
  /// The units with no stored translation, in corpus order — the backfill's work list. The same list
  /// the count above is derived from, so the readout and the work can never disagree.
  public let missing: [TranslatableUnit]

  public var translated: Int { fields.reduce(0) { $0 + $1.translated } }
  public var total: Int { fields.reduce(0) { $0 + $1.total } }

  public init(fields: [Field], missing: [TranslatableUnit]) {
    self.fields = fields
    self.missing = missing
  }

  /// One store read per unit. `language == off` returns an empty coverage WITHOUT reading, so a
  /// disabled feature opens no file — the same "off means off" rule the lazy stores in `AppModel`
  /// follow.
  public static func measure(units: [TranslatableUnit], store: TranslationStore,
                             language: String) -> TranslationCoverage {
    guard !language.isEmpty else { return TranslationCoverage(fields: [], missing: []) }
    var totals: [TranslationField: Int] = [:]
    var translatedCounts: [TranslationField: Int] = [:]
    var missing: [TranslatableUnit] = []
    for unit in units {
      totals[unit.field, default: 0] += 1
      if store.translation(field: unit.field, sourceText: unit.sourceText, language: language) != nil {
        translatedCounts[unit.field, default: 0] += 1
      } else {
        missing.append(unit)
      }
    }
    // `allCases` order, so the readout is stable across runs rather than dictionary order.
    let fields = TranslationField.allCases.compactMap { field -> Field? in
      guard let total = totals[field] else { return nil }
      return Field(field: field, translated: translatedCounts[field] ?? 0, total: total)
    }
    return TranslationCoverage(fields: fields, missing: missing)
  }
}
