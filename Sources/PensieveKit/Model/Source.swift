import Foundation
import SQLiteData

@Table
public struct Source: Identifiable, Equatable, Sendable {
  public let id: UUID
  public var projectID: UUID
  public var kind: String        // "gitRepo" | "claudeCode"
  public var key: String         // absolute directory/repo path
  public var createdAt: Date
  public init(id: UUID = UUID(), projectID: UUID, kind: String, key: String, createdAt: Date = Date()) {
    self.id = id; self.projectID = projectID; self.kind = kind; self.key = key; self.createdAt = createdAt
  }
}
