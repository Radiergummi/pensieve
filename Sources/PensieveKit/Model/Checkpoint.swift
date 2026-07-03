import Foundation
import SQLiteData

@Table
public struct Checkpoint: Identifiable, Equatable, Sendable {
  public let id: UUID
  public var projectID: UUID
  public var note: String
  public var createdAt: Date
  public init(id: UUID = UUID(), projectID: UUID, note: String, createdAt: Date = Date()) {
    self.id = id; self.projectID = projectID; self.note = note; self.createdAt = createdAt
  }
}
