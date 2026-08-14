import Foundation

/// Splits one message's text into the units BM25 scores.
///
/// Chunking exists because FTS5 normalises `bm25()` by a document's total token count: a 6,000-word
/// reply matching one term would be ranked far below a short commit subject matching the same term,
/// so a whole long message is the wrong document. Sizes carry over from the 2026-07-19 design
/// unchanged — the reason for overlap survives the switch from embeddings to BM25, because a phrase
/// straddling a boundary matches neither side otherwise.
public enum PassageChunker {
  /// At or under this, the text is one passage. Matches the extractor's `truncate` budget.
  public static let singleChunkLimit = 2000
  public static let windowLength = 1500
  public static let overlapLength = 200

  /// Ordered chunks covering `text`. Empty for empty or whitespace-only input.
  ///
  /// Consecutive chunks share `overlapLength` characters of context. A window ends at the last
  /// whitespace inside it and the next window opens `overlapLength` characters back from that end
  /// (backed off, not stridden), then snapped FORWARD to the next whitespace so chunks start and
  /// end at word boundaries; a window with no whitespace in reach is cut at its hard length so a
  /// pathological no-whitespace input still terminates.
  public static func chunk(_ text: String) -> [String] {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return [] }
    guard trimmed.count > singleChunkLimit else { return [trimmed] }

    var chunks: [String] = []
    var windowStart = trimmed.startIndex

    while windowStart < trimmed.endIndex {
      let hardEnd = trimmed.index(windowStart, offsetBy: windowLength,
                                  limitedBy: trimmed.endIndex) ?? trimmed.endIndex
      // Prefer a whitespace boundary inside the window. Only when one exists AND leaves a
      // non-trivial chunk — a window whose only space sits at position 3 should not produce a
      // 3-character chunk and then re-scan almost the same text.
      var windowEnd = hardEnd
      if hardEnd < trimmed.endIndex,
         let lastSpace = trimmed[windowStart..<hardEnd]
           .lastIndex(where: { $0.isWhitespace }),
         trimmed.distance(from: windowStart, to: lastSpace) > overlapLength {
        windowEnd = lastSpace
      }
      let chunk = trimmed[windowStart..<windowEnd].trimmingCharacters(in: .whitespacesAndNewlines)
      if !chunk.isEmpty { chunks.append(chunk) }
      if windowEnd >= trimmed.endIndex { break }
      windowStart = nextWindowStart(in: trimmed, windowEnd: windowEnd)
    }
    return chunks
  }

  /// Where the next window begins. Backing off from where this chunk actually ENDED, rather than
  /// striding blindly from where it began, is what makes the overlap real at every boundary. A
  /// window whose only whitespace sat just past `overlapLength` ends far short of a full stride,
  /// and a stride would either skip the text in between (losing it) or land exactly on `windowEnd`
  /// (losing the overlap) — a phrase straddling that boundary would then appear in neither chunk,
  /// which is the failure overlap exists to prevent. Progress is still guaranteed: a window is only
  /// cut short when its whitespace lies more than `overlapLength` in, so `start` is always past
  /// `windowStart`.
  /// Then snap FORWARD to the next whitespace so a window never opens mid-word — a fragment like
  /// "comprehensibilities" is a token the user never wrote, and BM25 matches it happily. Searching
  /// only up to `windowEnd` keeps the snap inside the overlap it is allowed to consume.
  private static func nextWindowStart(in text: String,
                                      windowEnd: String.Index) -> String.Index {
    let start = text.index(windowEnd, offsetBy: -overlapLength, limitedBy: text.startIndex)
      ?? text.startIndex
    guard start < windowEnd else { return start }
    return text[start..<windowEnd].firstIndex(where: { $0.isWhitespace }) ?? start
  }
}
