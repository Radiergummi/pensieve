import Foundation
import SQLiteData

@Table
public struct Event: Identifiable, Equatable, Sendable {
  public let id: UUID
  public var nodeID: UUID
  public var sourceID: UUID
  public var occurredAt: Date
  public var kind: String        // "git.commit" | "git.checkout" | "cc.session"
  public var summary: String     // short human-readable line
  public var detailJSON: String  // enriched payload as JSON
  public var fingerprint: String?   // source-agnostic idempotency key (unique per sourceID)
  public var branchKey: String?     // non-default git branch this event belongs to, if any
  public var extractedAt: Date?     // when loose-end extraction last processed this event
  public var extractedMessageCount: Int   // watermark: parsed messages already extracted
  public var extractedTranscriptSize: Int // transcript byte size at last extraction; -1 = never watermarked
  public var workSummary: String?   // best-effort on-device recap of what this session did; nil = un-enriched
  public var createdAt: Date
  public init(id: UUID = UUID(), nodeID: UUID, sourceID: UUID, occurredAt: Date,
              kind: String, summary: String, detailJSON: String,
              fingerprint: String? = nil, branchKey: String? = nil, extractedAt: Date? = nil,
              extractedMessageCount: Int = 0, extractedTranscriptSize: Int = -1,
              workSummary: String? = nil, createdAt: Date = Date()) {
    self.id = id; self.nodeID = nodeID; self.sourceID = sourceID; self.occurredAt = occurredAt
    self.kind = kind; self.summary = summary; self.detailJSON = detailJSON
    self.fingerprint = fingerprint; self.branchKey = branchKey; self.extractedAt = extractedAt
    self.extractedMessageCount = extractedMessageCount; self.extractedTranscriptSize = extractedTranscriptSize
    self.workSummary = workSummary; self.createdAt = createdAt
  }
}
