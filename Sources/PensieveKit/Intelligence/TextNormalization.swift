import Foundation

/// Trims and collapses every run of whitespace (incl. newlines) to a single space.
/// Used identically on both sides of the substring gate and for dedup.
public func normalizeWhitespace(_ string: String) -> String {
  string.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
}

/// Splits `text` into consecutive windows of at most `budget` characters, each ending on a
/// whitespace boundary so a word is never cut in half — a mid-word cut yields verbatim-but-truncated
/// quotes, which the trust gate then rejects. A single token longer than the budget is cut hard;
/// there is no boundary to keep. Empty text yields no windows; text within budget yields itself.
///
/// ONE implementation of the rule. Extraction (`LooseEndExtractor`'s prompt fragments) and
/// summarization (`SessionSummarizer`'s chunks) each carried a byte-identical copy of this loop, so
/// a fix to how the model's input is cut reached one path and not the other. `PassageChunker` is
/// deliberately NOT folded in: its windows *overlap*, which is a genuinely different rule.
func whitespaceBoundedWindows(_ text: String, budget: Int) -> [String] {
  guard budget > 0, text.count > budget else { return text.isEmpty ? [] : [text] }
  var windows: [String] = []
  var start = text.startIndex
  while start < text.endIndex {
    var end = text.index(start, offsetBy: budget, limitedBy: text.endIndex) ?? text.endIndex
    if end < text.endIndex, let whitespaceIndex = text[start..<end].lastIndex(where: { $0.isWhitespace }) {
      end = text.index(after: whitespaceIndex)
    }
    windows.append(String(text[start..<end]))
    start = end
  }
  return windows
}
