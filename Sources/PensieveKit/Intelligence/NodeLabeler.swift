import Foundation
import NaturalLanguage

/// A node name derived from the user's own typed description. Best-effort, and **routed by
/// language**.
///
/// English input goes to the model, which produces a better sidebar label than the sentence it came
/// from (measured: 21/21 through the gate, 16/16 usable). **Every other language takes a
/// deterministic shortening instead**, because the on-device model translates non-English input —
/// once returning "Train Advertisement Claim" for a German delayed-train complaint, where a
/// *Reklamation* is a complaint — and an explicit "write it in the same language" instruction does
/// not fix it: the model either ignores it or emits broken German. The failure is also
/// non-deterministic, so it cannot be prompted away or caught reliably by a test.
///
/// Translating would additionally violate the project rule that node names are captured content and
/// are never localized.
///
/// Evidence and probes: `docs/superpowers/measurements/2026-08-13-slice5-label-quality/`.
///
/// Outside the cited trust gate, like strand naming and narration — the user reads and confirms the
/// name in the modal before anything is written.
public enum NodeLabeler {
  /// Whether `text`'s dominant language is English. Anything else — including text whose language
  /// cannot be determined — routes to the deterministic arm, so the safe path is the default.
  static func isEnglish(_ text: String) -> Bool {
    let recognizer = NLLanguageRecognizer()
    recognizer.processString(text)
    return recognizer.dominantLanguage == .english
  }

  /// Mirrors `Ingester`'s proven strand-naming prompt shape: one line, a word count, and an
  /// explicit "label only" so a conversational model doesn't wrap it in prose.
  static func prompt(for typed: String) -> String {
    """
    Below is a developer's own description of a piece of work they are about to start. In 3-6 \
    words, give it a human-readable name — a plain label for a sidebar, not numbered or bulleted, \
    no trailing period. Reply with the label only, nothing else. Do not invent facts beyond the \
    description.

    \(typed)
    """
  }

  /// A label for `typed`. Returns nil **only** for empty input: every other outcome — non-English,
  /// no provider, a throw, empty or gate-rejected model output — falls through to the deterministic
  /// shortening. That is what lets the modal always show a name, so `Save` is never stuck disabled.
  public static func label(for typed: String, provider: (any LLMProvider)?) async -> String? {
    let trimmed = typed.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let fallback = TextQuality.shorten(trimmed) else { return nil }
    guard isEnglish(trimmed), let provider else { return fallback }
    guard let raw = try? await provider.complete(prompt: prompt(for: trimmed)),
          let label = TextQuality.sanitizeLabel(raw) else { return fallback }
    return label
  }
}
