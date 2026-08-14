import Foundation
import SQLiteData

/// One durable, verbatim slice of a captured conversation.
///
/// **Why this lives in the canonical store and not in the search index.** Claude Code deletes
/// transcripts on a retention window: measured 2026-08-14, only 393 of 1,096 captured session
/// transcripts still existed. The FTS5 index is disposable and whole-rebuilds from the corpus
/// whenever its hash moves, so text living only there would be deleted permanently by the first
/// rebuild after its transcript aged out — a cache acting as the system of record. Storing it here
/// is the same choice `LooseEnd.quote` already makes: a stored verbatim copy that can be cited
/// after the source file is gone.
///
/// Written ONLY by `Ingester`, like every other canonical row.
@Table
public struct Passage: Identifiable, Equatable, Sendable {
  public let id: UUID
  public var nodeID: UUID
  /// The `cc.session` event whose `detailJSON` carries `transcriptPath`. `ON DELETE CASCADE`, so
  /// re-ingesting a session cannot orphan passages.
  public var eventID: UUID
  /// Groups a prompt with the replies that answered it. Assigned by `PassageExtractor` in
  /// transcript order, starting at 0.
  public var turnIndex: Int
  /// `TranscriptMessage.index` of the message this came from — the key the surrounding-window
  /// lookup uses. Several chunks of one long message share it.
  public var messageIndex: Int
  public var role: PassageRole
  /// Verbatim. Never generated, never translated: translation deliberately excludes captured
  /// content, and a translated provenance quote is a broken citation.
  public var text: String
  /// The message's own timestamp, so a passage dates without joining its event.
  public var occurredAt: Date
  public var createdAt: Date
  public init(id: UUID = UUID(), nodeID: UUID, eventID: UUID, turnIndex: Int, messageIndex: Int,
              role: PassageRole, text: String, occurredAt: Date, createdAt: Date = Date()) {
    self.id = id; self.nodeID = nodeID; self.eventID = eventID
    self.turnIndex = turnIndex; self.messageIndex = messageIndex
    self.role = role; self.text = text
    self.occurredAt = occurredAt; self.createdAt = createdAt
  }
}
