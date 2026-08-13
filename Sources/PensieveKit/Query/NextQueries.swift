import Foundation
import SQLiteData

public struct NextItem: Sendable {
  public let project: Node
  public let openLooseEnds: Int
  public let closedLooseEnds: Int
  /// When this project last did anything. Not optional: `ranked` skips a project with no captured
  /// activity outright, so an item without a date is a state the query cannot produce.
  ///
  /// The same event that yields `daysDormant`, kept rather than discarded — the pattern `NodeRowFacts`
  /// already uses. Views render the `Date` (a real "vor 3 Tagen"), ranking reads the `Int`. Before
  /// this field existed the menu-bar popover had to buy its second line back with two whole-database
  /// aggregates, having thrown this one away.
  public let lastActivityAt: Date
  public let daysDormant: Int
  public let score: Double

  /// `lastActivityAt` is deliberately NOT defaulted. A default here would be a plausible-looking
  /// `Date()` silently standing in for "we don't know", at call sites nobody revisits — the failure
  /// mode `NodeFields.description` was just changed to avoid. There is one construction site.
  public init(project: Node, openLooseEnds: Int, closedLooseEnds: Int = 0,
              lastActivityAt: Date, daysDormant: Int, score: Double) {
    self.project = project
    self.openLooseEnds = openLooseEnds
    self.closedLooseEnds = closedLooseEnds
    self.lastActivityAt = lastActivityAt
    self.daysDormant = daysDormant
    self.score = score
  }
}

extension NextItem {
  /// Is there anything here to pick up? True when open work remains — and ALSO true when this node
  /// has never produced a loose end at all. Loose ends come only from Claude Code transcripts, and
  /// 123 of this store's 162 active nodes are git-only, so for them "no open ends" means "never
  /// measured", not "finished". Treating those as done empties the list without anyone finishing
  /// anything.
  ///
  /// Not actionable is therefore the narrow, earned case: it HAD open ends and they are all closed.
  ///
  /// The single definition, applied by the three surfaces that answer "what should I pick up next" —
  /// `SmartLists.whatsNext`, `SessionContextQueries.rankedContext` (MCP `whats_next`) and the CLI's
  /// `pensieve next`. Deliberately NOT applied inside `ranked`, which also feeds Dormant and Recently
  /// Active: those answer "what is quiet" and "what moved", and a finished project belongs in both.
  public var isActionable: Bool { openLooseEnds > 0 || closedLooseEnds == 0 }
}

/// The single grounded ranking score. Long dormancy can dominate by design — it's a strong
/// "you forgot this" signal for ADHD workflows. Shared by `NextQueries.ranked` and
/// `SessionContextQueries.bundle` so the two never silently diverge.
public func groundedScore(openLooseEnds: Int, daysDormant: Int) -> Double {
  Double(openLooseEnds) * 2 + Double(daysDormant)
}

public enum NextQueries {
  /// Deterministic ranking on grounded signals only. No model, no invented scores.
  public static func ranked(_ database: any DatabaseReader, now: Date) throws -> [NextItem] {
    try database.read { database in
      let projects = try Node.where { $0.state.eq(NodeState.active) }.fetchAll(database)
      var items: [NextItem] = []
      for project in projects {
        let latest = try Event.where { $0.nodeID.eq(project.id) }
          .order { $0.occurredAt.desc() }.limit(1).fetchOne(database)
        guard let latest else { continue }   // no captured activity → nothing grounded (matches BriefingQueries)
        let dormant = Calendar.current.dateComponents([.day], from: latest.occurredAt, to: now).day ?? 0
        let open = try LooseEnd.where { $0.nodeID.eq(project.id) && LooseEnd.isOpen($0) }.fetchCount(database)
        let closed = try LooseEnd.where { $0.nodeID.eq(project.id)
                                          && $0.status.neq(LooseEndStatus.open) }
          .fetchCount(database)
        let score = groundedScore(openLooseEnds: open, daysDormant: dormant)
        items.append(NextItem(project: project, openLooseEnds: open, closedLooseEnds: closed,
                              lastActivityAt: latest.occurredAt, daysDormant: dormant, score: score))
      }
      return items.sorted { $0.score > $1.score }
    }
  }
}
