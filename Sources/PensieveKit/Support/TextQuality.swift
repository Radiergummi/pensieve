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

  /// Cleans a model-proposed label into a terse organizational name: strips a leading
  /// list/enumeration marker ("1. ", "2) ", "- ", "* ", "• "), wrapping quotes or backticks, and
  /// trailing sentence punctuation. Returns nil when nothing usable survives, so the caller keeps
  /// its own deterministic fallback. Deterministic — the namers sit outside the cited trust gate,
  /// but their output still shouldn't read like a numbered list item or a full sentence.
  ///
  /// Two callers: `Ingester` (auto-birthed strand + project names) and `NodeLabeler` (a user's
  /// typed description). It lived on `Ingester` until the second arrived; the shape recurs, so the
  /// gate is shared rather than copied.
  static func sanitizeLabel(_ raw: String) -> String? {
    // Collapse every interior whitespace run (newline, tab, mixed) to one space FIRST, so a label
    // that only looks fine because a line break hides in it can't reach the gate — and so the
    // length/sentence checks below measure the string as it will actually render on one line.
    var sanitized = raw.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    if let marker = sanitized.range(of: #"^(\d+[.)]|[-*•])\s+"#, options: .regularExpression) {
      sanitized.removeSubrange(marker)
    }
    sanitized = sanitized.trimmingCharacters(in: CharacterSet(charactersIn: "\"'`"))
    sanitized = sanitized.trimmingCharacters(in: CharacterSet(charactersIn: ".!?"))
    sanitized = sanitized.trimmingCharacters(in: .whitespaces)
    // Enforce the "terse label, not a sentence" contract. Observed failures: a 101-char name and
    // multi-sentence commit-message-shaped output sitting in the sidebar. nil → the caller keeps
    // its deterministic fallback.
    guard isTerseLabel(sanitized) else { return nil }
    assert(!sanitized.contains(where: \.isNewline), "sanitizeLabel must never return an embedded newline")
    return sanitized
  }

  /// A label built from the user's own words: the text itself when it already fits, otherwise as
  /// many whole words as fit within `cap`. Never cuts mid-word — a broken word reads as corruption
  /// — except for a single word longer than the cap, where there is no boundary to keep. Returns
  /// nil only for empty input.
  ///
  /// This is `NodeLabeler`'s non-English and provider-failure arm. It is not a consolation prize:
  /// most quick-add sentences already fit, so it usually returns them whole, in the user's own
  /// words, guaranteed correct. See `measurements/2026-08-13-slice5-label-quality/`.
  static func shorten(_ text: String, cap: Int = labelLengthCap) -> String? {
    // Collapse every interior whitespace run (newline, tab, mixed) to one space FIRST — otherwise a
    // string that only exceeds `cap` because of an embedded line break is measured wrong, and
    // `split(separator: " ")` below would fuse the words either side of a "\n" into one bogus word.
    let trimmed = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    guard !trimmed.isEmpty else { return nil }
    let result: String
    if trimmed.count <= cap {
      result = trimmed
    } else {
      var kept = ""
      for word in trimmed.split(separator: " ") {
        if kept.isEmpty {
          kept = String(word)
        } else if kept.count + 1 + word.count <= cap {
          kept += " " + word
        } else {
          break
        }
      }
      result = kept.count <= cap ? kept : String(kept.prefix(cap))
    }
    assert(!result.contains(where: \.isNewline), "shorten must never return an embedded newline")
    return result
  }
}
