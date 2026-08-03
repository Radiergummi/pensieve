import Foundation

/// Shape checks for best-effort model output that gets STORED (session recaps, index corpus text).
///
/// These paths sit outside the cited trust gate, so nothing validates them against a source — which
/// means a model that answers the wrong question writes its answer straight into the store. That
/// happened: 139 session recaps were JSON index arrays (a different prompt's structured output),
/// bare or ```-fenced. They render as empty-looking rows and embed to noise.
///
/// This is deliberately a SHAPE check, not a quality judgement: it rejects things that are
/// self-evidently not prose, and lets everything else through.
enum TextQuality {
  /// Real prose: has some length and contains letters. Rejects "[]", "/", "...", "42".
  static func isProse(_ text: String) -> Bool {
    let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmedText.count >= 8 && trimmedText.contains { $0.isLetter }
  }

  /// `isProse`, plus a reject for structured output wearing a prose costume: a JSON array/object,
  /// either bare or inside a code fence. Use for text a model was asked to write as prose.
  static func isProseNotStructured(_ text: String) -> Bool {
    var trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmedText.hasPrefix("```") {
      // Strip the fence (and any language tag) so `["```json\n[1,2]\n```"]` is judged on its body.
      trimmedText = trimmedText.replacingOccurrences(of: #"^```[a-zA-Z]*"#, with: "", options: .regularExpression)
      trimmedText = trimmedText.replacingOccurrences(of: "```", with: "")
      trimmedText = trimmedText.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    guard !trimmedText.hasPrefix("["), !trimmedText.hasPrefix("{") else { return false }
    return isProse(trimmedText)
  }

  /// A terse organizational label — a sidebar name, not a sentence or a paragraph. Rejects
  /// over-long output and multi-sentence output (". " followed by a capital), while allowing
  /// internal dots that aren't sentence boundaries ("v3.1 migration", "Fix auth.middleware").
  static let labelLengthCap = 60
  static func isTerseLabel(_ text: String) -> Bool {
    let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedText.isEmpty, trimmedText.count <= labelLengthCap else { return false }
    return trimmedText.range(of: #"[.!?]\s+\p{Lu}"#, options: .regularExpression) == nil
  }
}
