import Foundation
import SQLiteData

public struct ProjectStatus: Sendable {
  public let project: Node
  public let recentEvents: [Event]
}

public enum ProjectQueries {
  public static func all(_ db: any DatabaseWriter) throws -> [Node] {
    try db.read { db in try Node.order { $0.name }.fetchAll(db) }
  }

  public static func status(_ db: any DatabaseWriter, name: String, limit: Int) throws -> ProjectStatus? {
    try db.read { db -> ProjectStatus? in
      guard let project = try Node.where({ $0.name.eq(name) }).fetchOne(db) else { return nil }
      let events = try Event.where { $0.nodeID.eq(project.id) }
        .order { $0.occurredAt.desc() }
        .limit(limit)
        .fetchAll(db)
      return ProjectStatus(project: project, recentEvents: events)
    }
  }
}
