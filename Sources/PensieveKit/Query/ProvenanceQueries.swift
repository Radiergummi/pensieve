import Foundation
import SQLiteData

public struct ProvenanceMessage: Sendable, Equatable {
  public let index: Int
  public let role: String
  public let text: String
  public let isCited: Bool
  public let isUserPrompt: Bool
}

public struct ProvenanceContext: Sendable {
  public let looseEnd: LooseEnd
  public let sourceEvent: Event
  public let messages: [ProvenanceMessage]
  public let transcriptAvailable: Bool
}

/// Read-only resolution of a loose end's surrounding transcript context — the ⌘⌥I inspector's
/// data. Shows real captured text or degrades to `transcriptAvailable == false` (UI then shows the
/// stored verbatim quote + an honest "gone" note). Never fabricates; never highlights a wrong
/// message (two-part guard: the cited message must be a user prompt AND still contain the quote).
public enum ProvenanceQueries {
  /// The one-shot path: resolve the event, read the transcript, then slice. Unchanged behavior.
  public static func context(_ database: any DatabaseReader, looseEnd: LooseEnd, radius: Int = 4) throws -> ProvenanceContext {
    let event = try database.read { database in
      try Event.where { $0.id.eq(looseEnd.sourceEventID) }.fetchOne(database)
    }
    guard let event else { throw ProvenanceError.missingSourceEvent }

    // transcriptPath lives in the cc.session detailJSON (see Ingester); decode as [String: String].
    guard let path = transcriptPath(in: event), FileManager.default.fileExists(atPath: path)
    else { return unavailable(looseEnd: looseEnd, event: event) }

    let session = TranscriptParser.parse(fileURL: URL(fileURLWithPath: path))
    return context(session: session, looseEnd: looseEnd, event: event, radius: radius)
  }

  /// The batch path: slice a window out of an ALREADY-PARSED session. A later batch loader parses
  /// each transcript once and calls this per loose end, so the two-part guard below has exactly one
  /// definition — a second copy is how a wrong-provenance highlight would get shipped.
  public static func context(session: ParsedSession, looseEnd: LooseEnd, event: Event, radius: Int = 4) -> ProvenanceContext {
    // Resolve by identity (index), not bare position — robust to parser-version drift.
    guard let citedPosition = session.messages.firstIndex(where: { $0.index == looseEnd.sourceMessageIndex })
    else { return unavailable(looseEnd: looseEnd, event: event) }

    // Two-part guard so "never a wrong highlight" holds: the cited message must be a user prompt
    // AND still contain the stored quote. Either fails → honest fallback. Normalize both sides the
    // same way LooseEndVerifier did when it accepted the quote (it stores the raw model quote but
    // verifies against whitespace-normalized text) — else a quote whose whitespace the model
    // collapsed fails a raw `contains` and the inspector falsely reports the transcript as gone.
    let citedMessage = session.messages[citedPosition]
    guard citedMessage.isUserPrompt,
          normalizeWhitespace(citedMessage.text).contains(normalizeWhitespace(looseEnd.quote))
    else { return unavailable(looseEnd: looseEnd, event: event) }

    let lowerIndex = max(0, citedPosition - radius)
    let upperIndex = min(session.messages.count - 1, citedPosition + radius)
    let window = session.messages[lowerIndex...upperIndex].map {
      ProvenanceMessage(index: $0.index, role: $0.role, text: $0.text,
                        isCited: $0.index == looseEnd.sourceMessageIndex, isUserPrompt: $0.isUserPrompt)
    }
    return ProvenanceContext(looseEnd: looseEnd, sourceEvent: event, messages: window, transcriptAvailable: true)
  }

  /// transcriptPath lives in the cc.session detailJSON (see Ingester); decoded as [String: String].
  static func transcriptPath(in event: Event) -> String? {
    (try? JSONDecoder().decode([String: String].self, from: Data(event.detailJSON.utf8)))?["transcriptPath"]
  }

  private static func unavailable(looseEnd: LooseEnd, event: Event) -> ProvenanceContext {
    ProvenanceContext(looseEnd: looseEnd, sourceEvent: event, messages: [], transcriptAvailable: false)
  }
}

public enum ProvenanceError: Error { case missingSourceEvent }
