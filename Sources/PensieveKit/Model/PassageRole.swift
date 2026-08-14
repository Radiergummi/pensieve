import Foundation
import SQLiteData

/// Who produced a passage. A real enum rather than raw strings, like `LooseEndStatus` /
/// `NodeKind` / `NodeState` — this codebase converted those precisely to kill the
/// mistyped-literal hazard, and `role` is compared wherever a passage renders.
///
/// Deliberately NOT reusing `LooseEnd.role`, which is a bare `String` holding the transcript's own
/// role value ("user"). That field records what the transcript said; this one records which side of
/// a turn Pensieve stored, and the two must be free to diverge — a transcript role is not a closed
/// set, and `SpeakerClass.of` already falls back to `.system` for unknown ones.
public enum PassageRole: String, QueryBindable, Sendable {
  /// A human turn — a message `TranscriptParser` flagged `isUserPrompt`.
  case prompt
  /// Assistant prose. Tool calls never reach this: `extractText` reads only `text` blocks, so a
  /// tool-use-only message has empty text and never enters `ParsedSession.messages` at all.
  case reply
}
