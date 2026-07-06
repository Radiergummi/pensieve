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
  public static func context(_ db: any DatabaseReader, looseEnd: LooseEnd, radius: Int = 4) throws -> ProvenanceContext {
    let event = try db.read { db in
      try Event.where { $0.id.eq(looseEnd.sourceEventID) }.fetchOne(db)
    }
    guard let event else { throw ProvenanceError.missingSourceEvent }

    func unavailable() -> ProvenanceContext {
      ProvenanceContext(looseEnd: looseEnd, sourceEvent: event, messages: [], transcriptAvailable: false)
    }

    // transcriptPath lives in the cc.session detailJSON (see Ingester); decode as [String: String].
    guard let path = (try? JSONDecoder().decode([String: String].self, from: Data(event.detailJSON.utf8)))?["transcriptPath"],
          FileManager.default.fileExists(atPath: path)
    else { return unavailable() }

    let session = TranscriptParser.parse(fileURL: URL(fileURLWithPath: path))
    // Resolve by identity (index), not bare position — robust to parser-version drift.
    guard let citedPos = session.messages.firstIndex(where: { $0.index == looseEnd.sourceMessageIndex })
    else { return unavailable() }

    // Two-part guard so "never a wrong highlight" holds: the cited message must be a user prompt
    // AND still contain the stored quote. Either fails → honest fallback.
    let citedMessage = session.messages[citedPos]
    guard citedMessage.isUserPrompt, citedMessage.text.contains(looseEnd.quote) else { return unavailable() }

    let lo = max(0, citedPos - radius)
    let hi = min(session.messages.count - 1, citedPos + radius)
    let window = session.messages[lo...hi].map {
      ProvenanceMessage(index: $0.index, role: $0.role, text: $0.text,
                        isCited: $0.index == looseEnd.sourceMessageIndex, isUserPrompt: $0.isUserPrompt)
    }
    return ProvenanceContext(looseEnd: looseEnd, sourceEvent: event, messages: window, transcriptAvailable: true)
  }
}

public enum ProvenanceError: Error { case missingSourceEvent }
