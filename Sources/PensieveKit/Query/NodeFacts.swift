import Foundation
import SQLiteData

/// Grounded per-node facts for glance surfaces (Spotlight subtitle, rankings). Mirrors the dormancy +
/// open-loose-end logic in `NextQueries.ranked`; kept as a shared helper. Read-only (`DatabaseReader`).
public struct NodeFacts: Sendable {
  public let node: Node
  public let openLooseEnds: Int
  public let daysDormant: Int   // days since latest Event; 0 if the node has no events

  public init(node: Node, openLooseEnds: Int, daysDormant: Int) {
    self.node = node; self.openLooseEnds = openLooseEnds; self.daysDormant = daysDormant
  }
}

public enum NodeFactsQueries {
  /// Active nodes with their grounded facts (the same live set `NextQueries` surfaces).
  public static func all(_ db: any DatabaseReader, now: Date) throws -> [NodeFacts] {
    try db.read { db in
      try Node.where { $0.state.eq(NodeState.active) }.fetchAll(db).map { try facts(for: $0, db, now: now) }
    }
  }

  /// Facts for specific node ids, **any state** (so a Spotlight tap on a since-archived node resolves).
  public static func facts(for ids: [UUID], _ db: any DatabaseReader, now: Date) throws -> [NodeFacts] {
    try db.read { db in
      try ids.compactMap { id in
        guard let node = try Node.where({ $0.id.eq(id) }).fetchOne(db) else { return nil }
        return try facts(for: node, db, now: now)
      }
    }
  }

  private static func facts(for node: Node, _ db: Database, now: Date) throws -> NodeFacts {
    let latest = try Event.where { $0.nodeID.eq(node.id) }
      .order { $0.occurredAt.desc() }.limit(1).fetchOne(db)
    let dormant = latest.map {
      Calendar.current.dateComponents([.day], from: $0.occurredAt, to: now).day ?? 0
    } ?? 0
    let open = try LooseEnd.where { $0.nodeID.eq(node.id) && LooseEnd.isOpen($0) }.fetchCount(db)
    return NodeFacts(node: node, openLooseEnds: open, daysDormant: dormant)
  }
}
