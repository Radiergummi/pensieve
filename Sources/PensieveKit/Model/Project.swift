import Foundation
import SQLiteData

@Table
public struct Project: Identifiable, Equatable, Sendable {
  public let id: UUID
  public var name: String
  public var state: String        // "active" | "archived" | "muted"
  public var createdAt: Date

  public init(id: UUID = UUID(), name: String, state: String = "active", createdAt: Date = Date()) {
    self.id = id; self.name = name; self.state = state; self.createdAt = createdAt
  }
}
