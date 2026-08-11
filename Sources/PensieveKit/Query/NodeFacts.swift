import Foundation
import SQLiteData

/// Grounded per-node facts for glance surfaces (Spotlight subtitle, rankings). Mirrors the dormancy +
/// open-loose-end logic in `NextQueries.ranked`; kept as a shared helper. Read-only (`DatabaseReader`).
public struct NodeFacts: Sendable {
  public let node: Node
  public let openLooseEnds: Int
  public let daysDormant: Int   // days since latest Event; 0 if the node has no events
  /// The latest `Event.occurredAt`, or nil when the node has no captured events.
  ///
  /// Carried ALONGSIDE `daysDormant`, never instead of it: `daysDormant` is an input to
  /// `groundedScore` and to the `SmartLists` thresholds, so replacing it would silently re-rank
  /// What's Next. Views read this `Date` (it formats itself, in locale); ranking reads the `Int`.
  /// Both derive from the same event and cannot disagree.
  public let lastActivityAt: Date?

  public init(node: Node, openLooseEnds: Int, daysDormant: Int, lastActivityAt: Date?) {
    self.node = node; self.openLooseEnds = openLooseEnds; self.daysDormant = daysDormant
    self.lastActivityAt = lastActivityAt
  }
}

public enum NodeFactsQueries {
  /// Active nodes with their grounded facts (the same live set `NextQueries` surfaces).
  public static func all(_ database: any DatabaseReader, now: Date) throws -> [NodeFacts] {
    try database.read { database in
      try Node.where { $0.state.eq(NodeState.active) }.fetchAll(database).map { try facts(for: $0, database, now: now) }
    }
  }

  /// Facts for specific node ids, **any state** (so a Spotlight tap on a since-archived node resolves).
  public static func facts(for ids: [UUID], _ database: any DatabaseReader, now: Date) throws -> [NodeFacts] {
    try database.read { database in
      try ids.compactMap { id in
        guard let node = try Node.where({ $0.id.eq(id) }).fetchOne(database) else { return nil }
        return try facts(for: node, database, now: now)
      }
    }
  }

  private static func facts(for node: Node, _ database: Database, now: Date) throws -> NodeFacts {
    let latest = try Event.where { $0.nodeID.eq(node.id) }
      .order { $0.occurredAt.desc() }.limit(1).fetchOne(database)
    let dormant = latest.map {
      Calendar.current.dateComponents([.day], from: $0.occurredAt, to: now).day ?? 0
    } ?? 0
    let open = try LooseEnd.where { $0.nodeID.eq(node.id) && LooseEnd.isOpen($0) }.fetchCount(database)
    return NodeFacts(node: node, openLooseEnds: open, daysDormant: dormant,
                     lastActivityAt: latest?.occurredAt)
  }
}
