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

public enum BriefingQueries {
  /// Four grouped aggregates plus one loose-end pass for the WHOLE store, however many nodes there
  /// are. This used to fetch every `Event` row of every active node just to take `.first` and count
  /// (~3,110 materialized structs on the measured store), then open one more read transaction per
  /// node for its loose ends — 305 of them.
  ///
  /// `openLooseEnds` is the aggregate's COUNT rather than the length of the fetched feed, so it no
  /// longer drops an end whose source event has vanished. That is the same deliberate difference
  /// `LooseEndQueries.openCountAcrossNodes` already documents between a count and a feed, and the
  /// case is unreachable through the schema (`sourceEventID` is `NOT NULL REFERENCES events(id)`).
  public static func cards(_ database: any DatabaseReader, since: Date, now: Date) throws -> [BriefingCard] {
    let nodes = try database.read { database in
      try Node.where { $0.state.eq(NodeState.active) }.fetchAll(database)
    }
    let activity = try NodeFactsQueries.activity(database, since: since)
    let topLooseEnds = try LooseEndQueries.topOpen(database, now: now)

    var cards: [BriefingCard] = []
    for node in nodes {
      // No captured activity → nothing grounded, so skip the node. `BriefingCard.lastActivityAt` is
      // non-optional and documents this; the same reading of the one no-events rule as
      // `NextQueries.ranked`.
      guard let facts = activity[node.id], let lastActivityAt = facts.lastActivityAt else { continue }
      cards.append(BriefingCard(
        node: node, movedSince: facts.movedSince, latestSummary: facts.latestSummary,
        openLooseEnds: facts.openLooseEnds, topLooseEnd: topLooseEnds[node.id]?.looseEnd.text,
        daysDormant: dayCount(from: lastActivityAt, to: now), lastActivityAt: lastActivityAt))
    }
    // Moved-since-last-visit first (most movement first); then the quiet ones, least-dormant first.
    return cards.sorted {
      $0.movedSince != $1.movedSince ? $0.movedSince > $1.movedSince : $0.daysDormant < $1.daysDormant
    }
  }
}
