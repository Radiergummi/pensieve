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

    guard let session = parsedSession(for: event)
    else { return unavailable(looseEnd: looseEnd, event: event) }
    return context(session: session, looseEnd: looseEnd, event: event, radius: radius)
  }

  /// The batch path: slice a window out of an ALREADY-PARSED session. A later batch loader parses
  /// each transcript once and calls this per loose end.
  ///
  /// The two-part guard ("never a wrong highlight": the cited message must be a user prompt AND
  /// still contain the stored quote) lives in `TranscriptWindow.slice`, which passage provenance
  /// shares — `requireUserPrompt` is the only thing the two callers disagree about, and a second
  /// copy of the rest is how a wrong-provenance highlight would get shipped.
  public static func context(session: ParsedSession, looseEnd: LooseEnd, event: Event, radius: Int = 4) -> ProvenanceContext {
    guard let window = TranscriptWindow.slice(session: session,
                                              messageIndex: looseEnd.sourceMessageIndex,
                                              citedText: looseEnd.quote, requireUserPrompt: true,
                                              radius: radius)
    else { return unavailable(looseEnd: looseEnd, event: event) }
    return ProvenanceContext(looseEnd: looseEnd, sourceEvent: event, messages: window, transcriptAvailable: true)
  }

  /// transcriptPath lives in the cc.session detailJSON (see Ingester); decoded as [String: String].
  public static func transcriptPath(in event: Event) -> String? {
    (try? JSONDecoder().decode([String: String].self, from: Data(event.detailJSON.utf8)))?["transcriptPath"]
  }

  /// This event's transcript, parsed — or nil when it has aged out of Claude Code's retention
  /// window. The single definition of "is this transcript still readable", shared by loose-end
  /// provenance, passage provenance and `pensieve backfill-passages`; a per-caller copy of the
  /// path-decode + existence-check pair is how the three would drift on what counts as gone.
  public static func parsedSession(for event: Event) -> ParsedSession? {
    guard let path = transcriptPath(in: event),
          FileManager.default.fileExists(atPath: path) else { return nil }
    return TranscriptParser.parse(fileURL: URL(fileURLWithPath: path))
  }

  private static func unavailable(looseEnd: LooseEnd, event: Event) -> ProvenanceContext {
    ProvenanceContext(looseEnd: looseEnd, sourceEvent: event, messages: [], transcriptAvailable: false)
  }
}

public enum ProvenanceError: Error { case missingSourceEvent }
