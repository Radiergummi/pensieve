import Foundation

/// Which language generated text is translated into, read from UserDefaults so the app, the CLI and
/// the launchd agent all agree — they must, because the agent builds the search index and therefore
/// decides which translated documents it contains.
///
/// Deliberately NOT the app's runtime locale. Tying the two would make the feature inert unless the
/// whole UI were switched, and would let a locale the user never chose (system French, app falling
/// back to English) silently select a translation target. A setting also decouples reading language
/// from UI language, which is the likelier want: German summaries with English chrome.
public enum TranslationTarget {
  /// Translation disabled. Off means off: no store file, no index rows, no model asset loaded.
  public static let off = ""
  /// Generated text is written in English; that is the source of every display translation and the
  /// target of the query backstop.
  public static let sourceLanguage = "en"

  /// Hoisted into a `Set` because `resolved()` is on a per-row render path (`AppModel.displayed`, once
  /// per rendered loose end). `Locale.LanguageCode.isoLanguageCodes` re-materializes its 620 entries on
  /// every access, so reading it inline cost 9.9 µs per call against 0.7 µs here — measured, ~1 ms per
  /// 100 rows on the main actor.
  private static let isoLanguageCodes = Set(Locale.LanguageCode.isoLanguageCodes)

  /// The persisted target, or `off` for unset, English, or a malformed identifier.
  ///
  /// There is deliberately NO allow-list of languages. The original `supported = ["de"]` existed on
  /// the argument that each language "doubles a slice of the search index, which is a measured cost" —
  /// and that argument was retired by its own measurement: the pre-registered ranking gate shipped as
  /// built with English P@1 statistically indistinguishable from baseline (McNemar p = 1.000,
  /// `measurements/2026-08-12-translation-ranking/`). Only one target is active at a time, so the
  /// doubling is bounded at exactly the case that gate cleared.
  ///
  /// The check is SHAPE, not membership, and the framework is where unsupported languages degrade:
  /// `SystemTranslator.translate` verifies `status(from:to:) == .installed` before constructing a
  /// session, and `AppModel.displayed(field:sourceText:)` is a pure store lookup that never reaches
  /// the framework at all. So an exotic-but-valid code costs one availability check and shows English;
  /// it cannot fail per render. (The previous comment here claimed otherwise; it was written when
  /// nothing downstream guarded.)
  public static func resolved(defaults: UserDefaults = PensieveDefaults.shared()) -> String {
    let stored = defaults.string(forKey: PensieveDefaults.translationTargetKey) ?? off
    guard !stored.isEmpty, stored != sourceLanguage,
          let code = Locale.Language(identifier: stored).languageCode,
          isoLanguageCodes.contains(code)
    else { return off }
    return stored
  }

  /// The language's name in its own language — "Deutsch", "Deutsch (Schweiz)", "中文（香港）".
  ///
  /// `forIdentifier:`, NOT `forLanguageCode:`: the latter drops the region/script qualifier, which
  /// renders `zh`, `zh-HK` and `zh-TW` as three identical rows labelled "中文". Falls back to the
  /// identifier so a row is never blank.
  public static func displayName(for language: String) -> String {
    Locale(identifier: language).localizedString(forIdentifier: language) ?? language
  }
}
