import Foundation
import SQLiteData

@Table
public struct Source: Identifiable, Equatable, Sendable {
  public let id: UUID
  public var nodeID: UUID
  public var kind: String        // "gitRepo" | "claudeCode"
  public var key: String         // absolute directory/repo path
  public var createdAt: Date
  public init(id: UUID = UUID(), nodeID: UUID, kind: String, key: String, createdAt: Date = Date()) {
    self.id = id; self.nodeID = nodeID; self.kind = kind; self.key = key; self.createdAt = createdAt
  }
}
