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

    guard let session = ProvenanceQueries.parsedSession(for: event)
    else { return unavailable(passage: passage, event: event) }
    return window(session: session, passage: passage, event: event, radius: radius)
  }

  /// The pure half, so a caller holding an already-parsed transcript does not re-parse it — the same
  /// split `ProvenanceQueries` makes for `ProvenanceLoader`.
  ///
  /// `requireUserPrompt: false` is the ONE way this differs from loose-end provenance, for the
  /// reason in this type's doc comment. Everything else — resolving the stored index by identity,
  /// the containment check that detects a shifted transcript, and the ±radius slice — comes from
  /// the shared `TranscriptWindow.slice`.
  public static func window(session: ParsedSession, passage: Passage, event: Event,
                            radius: Int = 8) -> PassageWindow {
    guard let messages = TranscriptWindow.slice(session: session,
                                                messageIndex: passage.messageIndex,
                                                citedText: passage.text, requireUserPrompt: false,
                                                radius: radius)
    else { return unavailable(passage: passage, event: event) }
    return PassageWindow(passage: passage, sourceEvent: event, messages: messages,
                         transcriptAvailable: true)
  }

  /// The honest degrade, in one place — mirroring `ProvenanceQueries.unavailable`. Both guards
  /// above reach it, so "no window, but the stored text still stands" has a single spelling.
  private static func unavailable(passage: Passage, event: Event) -> PassageWindow {
    PassageWindow(passage: passage, sourceEvent: event, messages: [], transcriptAvailable: false)
  }
}

public enum PassageProvenanceError: Error {
  /// The anchor event is gone but the passage is not. The FK cascades, so this means canonical
  /// integrity was violated rather than that the session was simply deleted.
  case anchorEventMissing
}
