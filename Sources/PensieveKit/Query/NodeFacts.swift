import Foundation
import GRDB
import SQLiteData

/// Grounded per-node facts for glance surfaces (Spotlight subtitle, rankings). Read-only
/// (`DatabaseReader`). Derived from `NodeFactsQueries.activity`, the single batched derivation every
/// "latest event + loose-end counts" surface now shares.
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
      let nodes = try Node.where { $0.state.eq(NodeState.active) }.fetchAll(database)
      let activity = try activity(database, since: nil)
      return nodes.map { facts(for: $0, activity[$0.id], now: now) }
    }
  }

  /// Facts for specific node ids, **any state** (so a Spotlight tap on a since-archived node resolves).
  public static func facts(for ids: [UUID], _ database: any DatabaseReader, now: Date) throws -> [NodeFacts] {
    try database.read { database in
      let activity = try activity(database, since: nil)
      return try ids.compactMap { id in
        guard let node = try Node.where({ $0.id.eq(id) }).fetchOne(database) else { return nil }
        return facts(for: node, activity[id], now: now)
      }
    }
  }

  /// Projects one node's slice of the shared aggregate into `NodeFacts`. A node with no events keeps
  /// its long-standing rendering — `lastActivityAt: nil` and `daysDormant: 0` — which is this
  /// surface's reading of the one no-events rule stated on `NodeActivityFacts.lastActivityAt`.
  private static func facts(for node: Node, _ activity: NodeActivityFacts?, now: Date) -> NodeFacts {
    NodeFacts(node: node,
              openLooseEnds: activity?.openLooseEnds ?? 0,
              daysDormant: activity?.lastActivityAt.map { dayCount(from: $0, to: now) } ?? 0,
              lastActivityAt: activity?.lastActivityAt)
  }
}

/// Recency + open-count for many nodes at once — the list-row shape, without the node itself.
public struct NodeRowFacts: Sendable, Equatable {
  public let lastActivityAt: Date?
  public let openLooseEnds: Int

  public init(lastActivityAt: Date?, openLooseEnds: Int) {
    self.lastActivityAt = lastActivityAt
    self.openLooseEnds = openLooseEnds
  }
}

/// Every per-node activity fact the glance surfaces read, for all nodes in one pass.
///
/// **The single derivation of "latest event + loose-end counts per node".** It was four, three of
/// them N+1, all reachable from one `AppModel.refresh()`: `NextQueries.ranked` (3 queries per node),
/// `BriefingQueries.cards` (which fetched *every event row* per node to take `.first` and count),
/// `NodeFactsQueries.facts` (2 per node) and `rowFacts` (batched — this one). Measured on the live
/// store that was ~917 table scans and 3,110 materialized `Event` structs per refresh, for numbers
/// three grouped aggregates produce.
public struct NodeActivityFacts: Sendable, Equatable {
  /// The newest `Event.occurredAt` for this node, or nil when it has no captured events.
  ///
  /// **The one no-events rule, stated once.** Absence of activity is `lastActivityAt == nil`, and a
  /// node missing from the aggregate entirely has neither events nor loose ends. Each surface's own
  /// handling is then a visible one-liner over this fact rather than a fourth derivation:
  /// `NextQueries.ranked` and `BriefingQueries.cards` skip such a node (both their result types
  /// declare `lastActivityAt` non-optional and say so), `NodeFacts` reports `daysDormant: 0`, and
  /// `rowFacts` omits the key.
  public let lastActivityAt: Date?
  /// The newest event's `summary`; "" when the node has no events.
  public let latestSummary: String
  public let openLooseEnds: Int
  /// Resolved-and-not-👎 count. Goes through `LooseEnd.closedAndRealSQLPredicate` — `NextItem`'s
  /// `isActionable` reads it, and a closed-count that forgot the 👎 exclusion dropped nodes from
  /// What's Next permanently.
  public let closedLooseEnds: Int
  /// Events newer than the `since:` handed to `activity`; 0 when no `since` was given.
  public let movedSince: Int

  public init(lastActivityAt: Date?, latestSummary: String, openLooseEnds: Int,
              closedLooseEnds: Int, movedSince: Int) {
    self.lastActivityAt = lastActivityAt
    self.latestSummary = latestSummary
    self.openLooseEnds = openLooseEnds
    self.closedLooseEnds = closedLooseEnds
    self.movedSince = movedSince
  }
}

extension NodeFactsQueries {
  /// The shared aggregate, for every node in the store at once. `since` opts into `movedSince`.
  public static func activity(_ database: any DatabaseReader,
                              since: Date? = nil) throws -> [UUID: NodeActivityFacts] {
    try database.read { database in try activity(database, since: since) }
  }

  /// Whole-store by design: three grouped aggregates over indexed columns, rather than a per-node
  /// restriction. `idx_events_project` covers `(nodeID, occurredAt)` and `idx_looseends_node` covers
  /// `(nodeID, status)`, so each of these is one index scan producing one row per node — cheaper than
  /// the per-node loops it replaces even when the caller wants a single node's slice.
  static func activity(_ database: Database, since: Date?) throws -> [UUID: NodeActivityFacts] {
    // Latest event AND its summary in one aggregate. The bare `summary` column is SQLite's
    // documented "bare columns in an aggregate query" rule: with a single MAX(), the bare columns
    // come from the row that produced the maximum. Ties pick an arbitrary row among them — exactly
    // what the `ORDER BY occurredAt DESC` + `.first` this replaces also did.
    var latest: [UUID: (occurredAt: Date, summary: String)] = [:]
    let latestRows = try Row.fetchAll(database, sql: """
      SELECT "nodeID", MAX("occurredAt") AS "lastActivityAt", "summary" FROM "events" GROUP BY "nodeID"
      """)
    for row in latestRows {
      guard let nodeID = Self.nodeID(in: row), let occurredAt: Date = row["lastActivityAt"] else { continue }
      latest[nodeID] = (occurredAt, row["summary"] ?? "")
    }

    var moved: [UUID: Int] = [:]
    if let since {
      let movedRows = try Row.fetchAll(database, sql: """
        SELECT "nodeID", COUNT(*) AS "movedCount" FROM "events"
        WHERE "occurredAt" > ? GROUP BY "nodeID"
        """, arguments: [since])
      for row in movedRows {
        guard let nodeID = Self.nodeID(in: row), let count: Int = row["movedCount"] else { continue }
        moved[nodeID] = count
      }
    }

    let open = try looseEndCounts(database, predicate: LooseEnd.openSQLPredicate)
    let closed = try looseEndCounts(database, predicate: LooseEnd.closedAndRealSQLPredicate)

    var result: [UUID: NodeActivityFacts] = [:]
    for nodeID in Set(latest.keys).union(open.keys).union(closed.keys) {
      result[nodeID] = NodeActivityFacts(
        lastActivityAt: latest[nodeID]?.occurredAt,
        latestSummary: latest[nodeID]?.summary ?? "",
        openLooseEnds: open[nodeID] ?? 0,
        closedLooseEnds: closed[nodeID] ?? 0,
        movedSince: moved[nodeID] ?? 0)
    }
    return result
  }

  /// One grouped loose-end count. `predicate` is a `LooseEnd` SQL predicate constant, interpolated
  /// into a SQL literal — it carries no user input and needs no binding.
  private static func looseEndCounts(_ database: Database, predicate: String) throws -> [UUID: Int] {
    var counts: [UUID: Int] = [:]
    let rows = try Row.fetchAll(database, sql: """
      SELECT "nodeID", COUNT(*) AS "endCount" FROM "looseEnds" WHERE \(predicate) GROUP BY "nodeID"
      """)
    for row in rows {
      guard let nodeID = Self.nodeID(in: row), let count: Int = row["endCount"] else { continue }
      counts[nodeID] = count
    }
    return counts
  }

  private static func nodeID(in row: Row) -> UUID? {
    guard let identifier: String = row["nodeID"] else { return nil }
    return UUID(uuidString: identifier)
  }

  /// Facts for every node at once, in the list-row shape.
  ///
  /// A node with no captured activity at all is absent from the result, and callers treat a miss as
  /// "no activity, zero open" — the same thing an entry reading `(nil, 0)` says, which is what a
  /// node holding only *closed* loose ends now yields. The two are indistinguishable to every caller
  /// by construction, so the shared aggregate does not have to decide between them.
  public static func rowFacts(_ database: any DatabaseReader) throws -> [UUID: NodeRowFacts] {
    try activity(database).mapValues {
      NodeRowFacts(lastActivityAt: $0.lastActivityAt, openLooseEnds: $0.openLooseEnds)
    }
  }
}
