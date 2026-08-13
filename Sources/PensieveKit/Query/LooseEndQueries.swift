import Foundation
import SQLiteData
import GRDB

public struct LooseEndView: Sendable {
  public let looseEnd: LooseEnd
  public let occurredAt: Date
  public let ageDays: Int
}

public enum LooseEndQueries {
  public static func open(_ database: any DatabaseReader, nodeID: UUID?, now: Date) throws -> [LooseEndView] {
    try database.read { database in
      let ends: [LooseEnd]
      if let nodeID {
        ends = try LooseEnd.where { $0.nodeID.eq(nodeID) && LooseEnd.isOpen($0) }.fetchAll(database)
      } else {
        ends = try LooseEnd.where { LooseEnd.isOpen($0) }.fetchAll(database)
      }
      return try attachEvents(ends, database, now: now)
        .sorted { $0.occurredAt < $1.occurredAt }   // oldest source first
    }
  }

  /// The burn-down triage feed: every open loose end in an ACTIVE, Focus-visible node, ordered
  /// SUGGESTED-SALIENT FIRST, then oldest source — the ordering `SalienceReviewQueries` already uses.
  ///
  /// Not pure oldest-first, and the reason is measured: every loose end in this store is 0–2 months
  /// old, and the first 200 in oldest-first order come from 13 nodes with 149 of them from three
  /// projects. "Oldest" is not "stalest" on this corpus — it is "grind through three repos". Leading
  /// with what a machine already thinks is a real loose end brings the scarce positives forward and
  /// spreads the queue across projects.
  ///
  /// Scoping lives here rather than at the caller because this is a cross-node feed: `open(nodeID:)`
  /// is already scoped by the node the user picked, but a global list that quietly included archived
  /// or Focus-muted work would contradict every other list in the app.
  public static func openAcrossNodes(_ database: any DatabaseReader, visibleNodeIDs: Set<UUID>,
                                     now: Date) throws -> [LooseEndView] {
    try openViews(database, visibleNodeIDs: visibleNodeIDs, now: now)
      .sorted { left, right in
        let leftRank = left.looseEnd.labelSuggestion == LooseEndLabel.salient ? 0 : 1
        let rightRank = right.looseEnd.labelSuggestion == LooseEndLabel.salient ? 0 : 1
        if leftRank != rightRank { return leftRank < rightRank }
        return left.occurredAt < right.occurredAt
      }
  }

  /// The Completed feed: closed loose ends in ACTIVE, Focus-visible nodes, most recently resolved
  /// first. Ordered by `resolvedAt` (not the source event) because this answers "what did I finish
  /// lately", and a loose end mined from a two-year-old session can be closed today.
  /// 👎-labelled ends are excluded, here and in `closed(nodeID:)`: an item the user declared was
  /// never a loose end has no place in a list they read as a record of their own work, and 98 rows
  /// carry that label today. (Search excludes them for a different reason — they are not in the
  /// corpus at all — so the two exclusions are independent, not one rule applied twice.)
  public static func closedAcrossNodes(_ database: any DatabaseReader, visibleNodeIDs: Set<UUID>,
                                       now: Date) throws -> [LooseEndView] {
    try closedViews(database, visibleNodeIDs: visibleNodeIDs, now: now)
      .sorted { ($0.looseEnd.resolvedAt ?? .distantPast) > ($1.looseEnd.resolvedAt ?? .distantPast) }
  }

  /// One node's closed loose ends, most recently resolved first — the detail pane's collapsed record.
  /// Deliberately NOT node-state-scoped: the caller already has this node open, so filtering it out
  /// by state would render an empty section on a node whose ends plainly exist.
  public static func closed(_ database: any DatabaseReader, nodeID: UUID,
                            now: Date) throws -> [LooseEndView] {
    try database.read { database in
      let ends = try LooseEnd
        .where { $0.nodeID.eq(nodeID) && $0.status.neq(LooseEndStatus.open)
                 && $0.label.neq(LooseEndLabel.noise) }
        .fetchAll(database)
      return try attachEvents(ends, database, now: now)
        .sorted { ($0.looseEnd.resolvedAt ?? .distantPast) > ($1.looseEnd.resolvedAt ?? .distantPast) }
    }
  }

  /// The two cross-node feeds' shared body, written as two small functions rather than one taking a
  /// predicate closure. `(LooseEnd.TableColumns) -> some QueryExpression<Bool>` is NOT expressible:
  /// `some` is allowed in a parameter's own position (SE-0341) but not in the RESULT position of a
  /// function-typed parameter, which would be a reverse-generic. Making it generic over the predicate
  /// would work, but two four-line functions are plainer than one generic one, and only the filter +
  /// event join genuinely need sharing.
  private static func openViews(_ database: any DatabaseReader, visibleNodeIDs: Set<UUID>,
                                now: Date) throws -> [LooseEndView] {
    try database.read { database in
      let ends = try LooseEnd.where { LooseEnd.isOpen($0) }.fetchAll(database)
      return try attachEvents(scoped(ends, visibleNodeIDs: visibleNodeIDs, database),
                              database, now: now)
    }
  }

  private static func closedViews(_ database: any DatabaseReader, visibleNodeIDs: Set<UUID>,
                                  now: Date) throws -> [LooseEndView] {
    try database.read { database in
      let ends = try LooseEnd
        .where { $0.status.neq(LooseEndStatus.open) && $0.label.neq(LooseEndLabel.noise) }
        .fetchAll(database)
      return try attachEvents(scoped(ends, visibleNodeIDs: visibleNodeIDs, database),
                              database, now: now)
    }
  }

  /// Keep only ends whose node is ACTIVE and Focus-visible. Node state is read from the store rather
  /// than trusted from `visibleNodeIDs`, which carries Focus visibility only.
  private static func scoped(_ ends: [LooseEnd], visibleNodeIDs: Set<UUID>,
                             _ database: Database) throws -> [LooseEnd] {
    let activeNodeIDs = Set(try Node.where { $0.state.eq(NodeState.active) }
      .fetchAll(database).map(\.id))
    return ends.filter { activeNodeIDs.contains($0.nodeID) && visibleNodeIDs.contains($0.nodeID) }
  }

  /// Pairs each loose end with its source event's date, dropping any whose event has vanished —
  /// the same rule `open` already applies, kept in one place so the four feeds cannot disagree.
  private static func attachEvents(_ ends: [LooseEnd], _ database: Database,
                                   now: Date) throws -> [LooseEndView] {
    var views: [LooseEndView] = []
    for looseEnd in ends {
      guard let event = try Event.where({ $0.id.eq(looseEnd.sourceEventID) }).fetchOne(database)
      else { continue }
      let days = Calendar.current.dateComponents([.day], from: event.occurredAt, to: now).day ?? 0
      views.append(LooseEndView(looseEnd: looseEnd, occurredAt: event.occurredAt, ageDays: days))
    }
    return views
  }
}
