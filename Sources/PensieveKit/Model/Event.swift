import Foundation
import SQLiteData

@Table
public struct Event: Identifiable, Equatable, Sendable {
  public let id: UUID
  public var projectID: UUID
  public var sourceID: UUID
  public var occurredAt: Date
  public var kind: String        // "git.commit" | "git.checkout" | "cc.session"
  public var summary: String     // short human-readable line
  public var detailJSON: String  // enriched payload as JSON
  public var fingerprint: String?   // source-agnostic idempotency key (unique per sourceID)
  public var extractedAt: Date?     // when loose-end extraction last processed this event
  public var createdAt: Date
  public init(id: UUID = UUID(), projectID: UUID, sourceID: UUID, occurredAt: Date,
              kind: String, summary: String, detailJSON: String,
              fingerprint: String? = nil, extractedAt: Date? = nil, createdAt: Date = Date()) {
    self.id = id; self.projectID = projectID; self.sourceID = sourceID; self.occurredAt = occurredAt
    self.kind = kind; self.summary = summary; self.detailJSON = detailJSON
    self.fingerprint = fingerprint; self.extractedAt = extractedAt; self.createdAt = createdAt
  }
}
