import Foundation
#if canImport(Translation)
import Translation
#endif

/// Translates model-generated text. Mirrors `LLMProvider`: Kit declares the seam, the system-backed
/// implementation is availability-gated, and every caller treats nil as "show the original".
///
/// Languages are BCP-47 codes ("en", "de") rather than `Locale.Language` so the seam matches what is
/// persisted in UserDefaults and stays trivially stubbable in tests.
public protocol Translator: Sendable {
  /// Returns nil on any failure — unsupported pair, uninstalled language pack, cancellation,
  /// pre-macOS 26. Never throws: a translation is best-effort by definition.
  func translate(_ text: String, from source: String, to target: String) async -> String?
}

/// The `Translation` framework, on-device.
///
/// Uses the headless `TranslationSession(installedSource:target:)` added in macOS 26 — macOS 15
/// offered only the SwiftUI-attached `.translationTask`, which could not have served a query path.
/// `installedSource` means the language pack must already exist; a headless session cannot prompt for
/// a download, which is why Settings hosts one `.translationTask` view for first-run acquisition.
@available(macOS 26, *)
public struct SystemTranslator: Translator {
  /// Language pairs already confirmed installed, so the probe runs once per pair rather than once per
  /// call.
  ///
  /// The per-call probe was proportionate for the on-demand caller, which translates one string at a
  /// time. `TranslationBackfill` is the first BULK caller, and it turned per-call setup into per-unit
  /// setup: `status(from:to:)` measured at ~4.8 ms warm (see `TranslationLanguageCatalog`) times 1,294
  /// units is ~6 s spent re-asking a question whose answer had not changed.
  ///
  /// The `TranslationSession` itself is deliberately NOT cached alongside this. It is a non-`Sendable`
  /// class, and an actor does not serialise around an `await` — a held session would be reachable from
  /// two concurrent `translate` calls (the backfill and an on-demand translation overlap by design),
  /// which is exactly what non-`Sendable` means it must not be. Constructing one per call keeps each
  /// call's session its own, and construction was never the measured cost.
  private let installedPairs = InstalledPairCache()

  public init() {}

  public func translate(_ text: String, from source: String, to target: String) async -> String? {
    guard !text.isEmpty, !source.isEmpty, !target.isEmpty, source != target else { return nil }
    let sourceLanguage = Locale.Language(identifier: source)
    let targetLanguage = Locale.Language(identifier: target)
    guard await installedPairs.isInstalled(from: sourceLanguage, to: targetLanguage) else { return nil }
    let session = TranslationSession(installedSource: sourceLanguage, target: targetLanguage)
    do {
      return try await session.translate(text).targetText
    } catch {
      Log.llm.debug("SystemTranslator: \(source, privacy: .public)→\(target, privacy: .public) failed: \(error, privacy: .public)")
      return nil
    }
  }
}

/// Remembers which language pairs this Mac reported as installed.
///
/// Only the POSITIVE answer is remembered. A pair that is not installed is re-probed every time,
/// because that answer genuinely changes — the user can install the pack from Settings mid-session,
/// and a cached "no" would make the feature stay broken until relaunch. A cached "yes" going stale
/// (the pack deleted out from under a run) only means the session's `translate` throws, which the
/// caller already turns into the same nil the probe would have produced.
@available(macOS 26, *)
private actor InstalledPairCache {
  private var installed: Set<String> = []

  func isInstalled(from source: Locale.Language, to target: Locale.Language) async -> Bool {
    let key = "\(source.minimalIdentifier)→\(target.minimalIdentifier)"
    if installed.contains(key) { return true }
    guard await LanguageAvailability().status(from: source, to: target) == .installed else { return false }
    installed.insert(key)
    return true
  }
}

/// The translator this machine can actually run, or nil below macOS 26. Callers that get nil skip
/// translation entirely and show the English original — the same shape as an unavailable LLM provider.
public func makeDefaultTranslator() -> Translator? {
  if #available(macOS 26, *) { return SystemTranslator() }
  return nil
}
