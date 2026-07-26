import Foundation

/// Who is talking. Machine envelopes are a third visual class, not a user bubble.
public enum SpeakerClass: Equatable, Sendable {
  case you, claude, system

  /// **Conjunctive, deliberately.** `isUserPrompt` is false for any message merely *containing* an
  /// envelope marker (`isInjectedOrCommand` is a bare `contains`), and 309 genuine `type:"user"`
  /// records in this project's own transcripts trip that — debugging this feature means pasting
  /// envelopes into chat. A disjunctive rule would render those as "not a person talking", i.e. the
  /// app asserting the user did not write something they did write.
  ///
  /// Unknown roles classify as `.system`: `role` falls back to `type` in `TranscriptParser`, so it
  /// is not a closed set, and we cannot assert a person wrote something whose role we can't identify.
  public static func of(_ message: ProvenanceMessage, segments: [TranscriptSegment]) -> SpeakerClass {
    let hasHumanContent = segments.contains { segment in
      switch segment {
      case .markdown(let text): return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      case .callout: return true
      case .harness: return false
      }
    }
    if !message.isUserPrompt && !hasHumanContent { return .system }
    switch message.role {
    case "user": return .you
    case "assistant": return .claude
    default: return .system
    }
  }
}
