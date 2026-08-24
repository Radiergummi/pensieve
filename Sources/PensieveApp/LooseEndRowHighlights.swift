// Sources/PensieveApp/LooseEndRowHighlights.swift
import SwiftUI
import PensieveKit

extension LooseEndRow {
  /// Highlight runs per segment ordinal — only for the segments that actually match. The ordinal is
  /// the position in the FULL segment array, the same number the document's anchors carry.
  ///
  /// Split out of `LooseEndRow.swift` when the merge of the transcript reading pass and the quality
  /// sweep pushed that file past the 400-line cap. This helper moves and its siblings do not,
  /// because it reads only `view` and `find` — both plain properties — whereas `segments(for:)`
  /// reads `@State private var context` / `parsed`, which could only cross a file boundary by
  /// widening view state. Extracting the provenance box is the real fix and is already planned as a
  /// prerequisite for the C2/C3 transcript work; this keeps lint green without pre-empting it.
  func highlights(for message: ProvenanceMessage,
                  segments: [TranscriptSegment]) -> [Int: SegmentHighlight] {
    guard let find, !find.query.isEmpty else { return [:] }
    var result: [Int: SegmentHighlight] = [:]
    for (ordinal, segment) in segments.enumerated() {
      guard let text = segment.findableText else { continue }
      let anchor = FindAnchor.transcriptSegment(looseEndID: view.looseEnd.id,
                                               messageIndex: message.index, segment: ordinal)
      let runs = find.runs(for: anchor, text: text)
      guard !runs.isEmpty else { continue }
      result[ordinal] = SegmentHighlight(runs: runs, currentOffset: find.currentOffset(in: anchor))
    }
    return result
  }
}
