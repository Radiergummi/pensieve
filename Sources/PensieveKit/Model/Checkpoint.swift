import Foundation
import SQLiteData

@Table
public struct Checkpoint: Identifiable, Equatable, Sendable {
  public let id: UUID
  public var nodeID: UUID
  public var note: String
  public var createdAt: Date
  public init(id: UUID = UUID(), nodeID: UUID, note: String, createdAt: Date = Date()) {
    self.id = id; self.nodeID = nodeID; self.note = note; self.createdAt = createdAt
  }
}
