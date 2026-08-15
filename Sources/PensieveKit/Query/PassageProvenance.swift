import Foundation
import SQLiteData

/// A passage plus the conversation around it.
public struct PassageWindow: Sendable {
  public let passage: Passage
  public let sourceEvent: Event
  /// Empty when `transcriptAvailable == false`. The passage's own `text` is then the whole citation.
  public let messages: [ProvenanceMessage]
  public let transcriptAvailable: Bool
}

/// Resolves a passage to the surrounding transcript conversation, degrading honestly.
///
/// **The guard here is deliberately ONE part, not the two `ProvenanceQueries` uses for loose ends.**
/// That guard requires the cited message to be `isUserPrompt` AND to still contain the quote, which
/// is right for a loose end — every one cites a human turn, so a non-prompt at the stored index
/// proves the index is stale. A passage legitimately cites assistant prose, so requiring
/// `isUserPrompt` would withhold the window from every `.reply` passage: half the corpus, silently.
/// Containment alone is the check that means the same thing here — the stored text must still be at
/// the stored index.
public enum PassageProvenance {
  public static func window(_ database: any DatabaseReader, passage: Passage,
                            radius: Int = 8) throws -> PassageWindow {
    guard let event = try database.read({ database in
      try Event.where { $0.id.eq(passage.eventID) }.fetchOne(database)
    }) else { throw PassageProvenanceError.anchorEventMissing }

    guard let path = ProvenanceQueries.transcriptPath(in: event),
          FileManager.default.fileExists(atPath: path) else {
      return PassageWindow(passage: passage, sourceEvent: event, messages: [],
                           transcriptAvailable: false)
    }
    let session = TranscriptParser.parse(fileURL: URL(fileURLWithPath: path))
    return window(session: session, passage: passage, event: event, radius: radius)
  }

  /// The pure half, so a caller holding an already-parsed transcript does not re-parse it — the same
  /// split `ProvenanceQueries` makes for `ProvenanceLoader`.
  public static func window(session: ParsedSession, passage: Passage, event: Event,
                            radius: Int = 8) -> PassageWindow {
    // The one-part guard. `messageIndex` addresses `ParsedSession.messages`, which only holds
    // non-empty messages, so a compacted transcript can shift it — containment is what detects that.
    guard let cited = session.messages.first(where: { $0.index == passage.messageIndex }),
          cited.text.contains(passage.text) else {
      return PassageWindow(passage: passage, sourceEvent: event, messages: [],
                           transcriptAvailable: false)
    }
    let lower = max(0, passage.messageIndex - radius)
    let upper = passage.messageIndex + radius
    let messages = session.messages
      .filter { $0.index >= lower && $0.index <= upper }
      .map { ProvenanceMessage(index: $0.index, role: $0.role, text: $0.text,
                               isCited: $0.index == passage.messageIndex,
                               isUserPrompt: $0.isUserPrompt) }
    return PassageWindow(passage: passage, sourceEvent: event, messages: messages,
                         transcriptAvailable: true)
  }
}

public enum PassageProvenanceError: Error {
  /// The anchor event is gone but the passage is not. The FK cascades, so this means canonical
  /// integrity was violated rather than that the session was simply deleted.
  case anchorEventMissing
}
