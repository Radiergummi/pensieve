import Foundation
import SQLiteData

@Table
public struct LooseEnd: Identifiable, Equatable, Sendable {
  public let id: UUID
  public var projectID: UUID
  public var sourceEventID: UUID
  public var text: String        // the open item
  public var quote: String       // verbatim provenance from captured text
  public var status: String      // "open" | "resolved"
  public var role: String            // role of the cited message (e.g. "user")
  public var sourceMessageIndex: Int // index of the cited message within the transcript
  public var createdAt: Date
  public init(id: UUID = UUID(), projectID: UUID, sourceEventID: UUID, text: String,
              quote: String, status: String = "open", role: String = "",
              sourceMessageIndex: Int = 0, createdAt: Date = Date()) {
    self.id = id; self.projectID = projectID; self.sourceEventID = sourceEventID
    self.text = text; self.quote = quote; self.status = status
    self.role = role; self.sourceMessageIndex = sourceMessageIndex; self.createdAt = createdAt
  }
}
