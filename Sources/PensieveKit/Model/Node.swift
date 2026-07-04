import Foundation
import SQLiteData

@Table
public struct Node: Identifiable, Equatable, Sendable {
  public let id: UUID
  public var name: String
  public var state: String          // "active" | "archived" | "muted"
  public var createdAt: Date
  public var parentID: UUID?        // strict tree; nil = root
  public var kind: String           // open string: domain|project|strand|concept|initiative|task|topic
  public var description: String    // LLM- or user-authored
  public var metadataJSON: String   // YAGNI bag for non-queried extras
  public var branchKey: String?     // set only on kind == "strand"

  public init(id: UUID = UUID(), name: String, state: String = "active", createdAt: Date = Date(),
              parentID: UUID? = nil, kind: String = "project", description: String = "",
              metadataJSON: String = "{}", branchKey: String? = nil) {
    self.id = id; self.name = name; self.state = state; self.createdAt = createdAt
    self.parentID = parentID; self.kind = kind; self.description = description
    self.metadataJSON = metadataJSON; self.branchKey = branchKey
  }
}
