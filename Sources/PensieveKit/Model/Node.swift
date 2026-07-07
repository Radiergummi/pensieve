import Foundation
import SQLiteData

/// The `Node.kind` string values. Centralized like `CaptureKind`/`SourceKind` so a typo can't
/// silently create or fail to find a node — the column stays an open `String` (no migration).
public enum NodeKind {
  public static let domain = "domain"
  public static let project = "project"
  public static let strand = "strand"
  public static let concept = "concept"
  public static let initiative = "initiative"
  public static let task = "task"
  public static let topic = "topic"

  /// All declared kinds, in display order (for the app's Change Type / new-node menus).
  public static let all = [domain, project, strand, concept, initiative, task, topic]
}

@Table
public struct Node: Identifiable, Equatable, Sendable {
  public let id: UUID
  public var name: String
  public var state: String          // "active" | "archived" | "muted"
  public var createdAt: Date
  public var parentID: UUID?        // strict tree; nil = root
  public var kind: String           // one of NodeKind (open string: domain|project|strand|concept|initiative|task|topic)
  public var description: String    // LLM- or user-authored
  public var metadataJSON: String   // YAGNI bag for non-queried extras
  public var branchKey: String?     // set only on kind == NodeKind.strand
  public var icon: String           // "" = use kind default; else "sf:<symbol>" or "emoji:<grapheme>"
  public var colorTag: String       // "" = use kind default; else a palette color name
  public var context: String        // "" = unset (inherit from ancestor); else "work" | "personal"

  public init(id: UUID = UUID(), name: String, state: String = "active", createdAt: Date = Date(),
              parentID: UUID? = nil, kind: String = NodeKind.project, description: String = "",
              metadataJSON: String = "{}", branchKey: String? = nil,
              icon: String = "", colorTag: String = "", context: String = "") {
    self.id = id; self.name = name; self.state = state; self.createdAt = createdAt
    self.parentID = parentID; self.kind = kind; self.description = description
    self.metadataJSON = metadataJSON; self.branchKey = branchKey
    self.icon = icon; self.colorTag = colorTag; self.context = context
  }
}
