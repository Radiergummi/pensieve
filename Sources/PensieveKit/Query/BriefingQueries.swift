import Foundation
import SQLiteData

/// One active project's line in the Briefing home: what moved since the last visit, plus its
/// single most-outstanding open loose end. Deterministic; grounded in captured rows.
public struct BriefingCard: Sendable, Identifiable {
  public let node: Node
  public let movedSince: Int        // events with occurredAt > since
  public let latestSummary: String  // most-recent event's summary ("" if none — never happens for a card)
  public let openLooseEnds: Int
  public let topLooseEnd: String?   // oldest-sourced open loose end's text
  public let daysDormant: Int
  /// The latest event's `occurredAt`. NON-optional: `cards` skips nodes with no events, so a card
  /// always has one. Carried alongside `daysDormant`, never instead of it — see `NodeFacts`.
  public let lastActivityAt: Date
  public var id: UUID { node.id }

  public init(node: Node, movedSince: Int, latestSummary: String,
              openLooseEnds: Int, topLooseEnd: String?, daysDormant: Int, lastActivityAt: Date) {
    self.node = node; self.movedSince = movedSince; self.latestSummary = latestSummary
    self.openLooseEnds = openLooseEnds; self.topLooseEnd = topLooseEnd; self.daysDormant = daysDormant
    self.lastActivityAt = lastActivityAt
  }
}

private struct NodeActivity {
  let node: Node
  let movedSince: Int
  let latestSummary: String
  let daysDormant: Int
  let lastActivityAt: Date
}

public enum BriefingQueries {
  public static func cards(_ database: any DatabaseReader, since: Date, now: Date) throws -> [BriefingCard] {
    // Collect per-node activity inside one `database.read`, then fetch loose ends afterward — `LooseEndQueries.open`
    // opens its own `database.read`, which can't be called with the `Database` handed to a closure already
    // inside a read transaction.
    let activity: [NodeActivity] = try database.read { database in
      let actives = try Node.where { $0.state.eq(NodeState.active) }.fetchAll(database)
      var result: [NodeActivity] = []
      for node in actives {
        let events = try Event.where { $0.nodeID.eq(node.id) }
          .order { $0.occurredAt.desc() }.fetchAll(database)
        guard let latest = events.first else { continue }   // no captured activity → nothing grounded
        let moved = events.filter { $0.occurredAt > since }.count
        let dormant = Calendar.current.dateComponents([.day], from: latest.occurredAt, to: now).day ?? 0
        result.append(NodeActivity(node: node, movedSince: moved, latestSummary: latest.summary,
                                   daysDormant: dormant, lastActivityAt: latest.occurredAt))
      }
      return result
    }
    var cards: [BriefingCard] = []
    for nodeActivity in activity {
      let ends = try LooseEndQueries.open(database, nodeID: nodeActivity.node.id, now: now)
      cards.append(BriefingCard(
        node: nodeActivity.node, movedSince: nodeActivity.movedSince, latestSummary: nodeActivity.latestSummary,
        openLooseEnds: ends.count, topLooseEnd: ends.first?.looseEnd.text,
        daysDormant: nodeActivity.daysDormant, lastActivityAt: nodeActivity.lastActivityAt))
    }
    // Moved-since-last-visit first (most movement first); then the quiet ones, least-dormant first.
    return cards.sorted {
      $0.movedSince != $1.movedSince ? $0.movedSince > $1.movedSince : $0.daysDormant < $1.daysDormant
    }
  }
}
