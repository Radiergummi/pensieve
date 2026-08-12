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
  /// Languages offered. Narrow on purpose — each one added doubles a slice of the search index, which
  /// is a measured cost (see the plan's verification gate), not a free dropdown entry.
  public static let supported = ["de"]

  /// The persisted target, or `off` for unset, English, or anything not in `supported`. An
  /// unrecognised value degrades to off rather than reaching the framework, which would fail per call
  /// and log on every render.
  public static func resolved(defaults: UserDefaults = PensieveDefaults.shared()) -> String {
    let stored = defaults.string(forKey: PensieveDefaults.translationTargetKey) ?? off
    return supported.contains(stored) ? stored : off
  }
}
