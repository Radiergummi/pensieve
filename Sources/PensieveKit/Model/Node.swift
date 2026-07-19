import Foundation
import SQLiteData

/// The `Node.kind` values. A real `RawRepresentable` enum (raw = the stored string) so a typo can't
/// silently create or fail to find a node, and a forgotten `switch` case fails to compile. Stored
/// verbatim in the STRICT text column via SQLiteData's `QueryBindable` (no migration).
public enum NodeKind: String, CaseIterable, Codable, Sendable, Equatable, QueryBindable {
  case domain, project, strand, concept, initiative, task, topic

  /// All declared kinds, in display order (for the app's Change Type / new-node menus). Declaration
  /// order already matches the old display order, so `allCases` is that order.
  public static let all: [NodeKind] = Array(allCases)
}

/// The `Node.state` values. Enum for the same reasons as `NodeKind`; raw = the stored string.
public enum NodeState: String, CaseIterable, Codable, Sendable, Equatable, QueryBindable {
  case active, archived, muted
}

@Table
public struct Node: Identifiable, Equatable, Sendable {
  public let id: UUID
  public var name: String
  public var state: NodeState
  public var createdAt: Date
  public var parentID: UUID?        // strict tree; nil = root
  public var kind: NodeKind
  public var description: String    // LLM- or user-authored
  public var metadataJSON: String   // YAGNI bag for non-queried extras
  public var branchKey: String?     // set only on kind == .strand
  public var icon: String           // "" = use kind default; else "sf:<symbol>" or "emoji:<grapheme>"
  public var colorTag: String       // "" = use kind default; else a palette color name
  public var context: String        // "" = unset (inherit from ancestor); else "work" | "personal"

  public init(id: UUID = UUID(), name: String, state: NodeState = .active, createdAt: Date = Date(),
              parentID: UUID? = nil, kind: NodeKind = .project, description: String = "",
              metadataJSON: String = "{}", branchKey: String? = nil,
              icon: String = "", colorTag: String = "", context: String = "") {
    self.id = id; self.name = name; self.state = state; self.createdAt = createdAt
    self.parentID = parentID; self.kind = kind; self.description = description
    self.metadataJSON = metadataJSON; self.branchKey = branchKey
    self.icon = icon; self.colorTag = colorTag; self.context = context
  }
}
