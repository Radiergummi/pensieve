import Foundation
import SQLiteData

public struct ProjectStatus: Sendable {
  public let project: Node
  public let recentEvents: [Event]

  public init(project: Node, recentEvents: [Event]) {
    self.project = project; self.recentEvents = recentEvents
  }
}

public enum ProjectQueries {
  public static func all(_ database: any DatabaseReader) throws -> [Node] {
    try database.read { database in try Node.order { $0.name }.fetchAll(database) }
  }

  public static func status(_ database: any DatabaseReader, name: String, limit: Int) throws -> ProjectStatus? {
    try database.read { database -> ProjectStatus? in
      guard let project = try Node.where({ $0.name.eq(name) }).fetchOne(database) else { return nil }
      return try recentEvents(database, project: project, limit: limit)
    }
  }

  /// Status for a node the caller already holds. Prefer this over the name-based lookup when
  /// you have the node: node names aren't unique (two distinct repos can share a basename),
  /// so `status(name:)` would `fetchOne` an arbitrary one of them.
  public static func status(_ database: any DatabaseReader, node: Node, limit: Int) throws -> ProjectStatus {
    try database.read { database in try recentEvents(database, project: node, limit: limit) }
  }

  private static func recentEvents(_ database: Database, project: Node, limit: Int) throws -> ProjectStatus {
    let events = try Event.where { $0.nodeID.eq(project.id) }
      .order { $0.occurredAt.desc() }
      .limit(limit)
      .fetchAll(database)
    return ProjectStatus(project: project, recentEvents: events)
  }
}
