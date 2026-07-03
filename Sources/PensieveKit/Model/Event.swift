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
  public var createdAt: Date
  public init(id: UUID = UUID(), projectID: UUID, sourceID: UUID, occurredAt: Date,
              kind: String, summary: String, detailJSON: String, createdAt: Date = Date()) {
    self.id = id; self.projectID = projectID; self.sourceID = sourceID; self.occurredAt = occurredAt
    self.kind = kind; self.summary = summary; self.detailJSON = detailJSON; self.createdAt = createdAt
  }
}
