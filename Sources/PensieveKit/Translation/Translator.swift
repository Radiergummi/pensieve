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
  public init() {}

  public func translate(_ text: String, from source: String, to target: String) async -> String? {
    guard !text.isEmpty, !source.isEmpty, !target.isEmpty, source != target else { return nil }
    let sourceLanguage = Locale.Language(identifier: source)
    let targetLanguage = Locale.Language(identifier: target)
    guard await LanguageAvailability().status(from: sourceLanguage, to: targetLanguage) == .installed
    else { return nil }
    let session = TranslationSession(installedSource: sourceLanguage, target: targetLanguage)
    do {
      return try await session.translate(text).targetText
    } catch {
      Log.llm.debug("SystemTranslator: \(source, privacy: .public)→\(target, privacy: .public) failed: \(error, privacy: .public)")
      return nil
    }
  }
}

/// The translator this machine can actually run, or nil below macOS 26. Callers that get nil skip
/// translation entirely and show the English original — the same shape as an unavailable LLM provider.
public func makeDefaultTranslator() -> Translator? {
  if #available(macOS 26, *) { return SystemTranslator() }
  return nil
}
