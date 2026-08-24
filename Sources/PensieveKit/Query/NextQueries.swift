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
  /// The single definition. Applied by `NextQueries.whatsNext`, which every surface answering "what
  /// should I pick up next" goes through — so a new surface gets the rule by construction rather than
  /// by remembering. `SmartLists` is the one direct caller, because it already holds `ranked` for
  /// Dormant / Recently Active and re-querying to reuse `whatsNext` would cost a second full scan.
  /// Deliberately NOT applied inside `ranked`, which also feeds Dormant and Recently Active: those
  /// answer "what is quiet" and "what moved", and a finished project belongs in both.
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
      // Three grouped aggregates for the whole store, replacing three queries PER node. The closed
      // count now goes through `LooseEnd.closedAndRealSQLPredicate`, so a 👎'd end no longer counts
      // as closed work — which is what silently made `isActionable` false forever.
      let activity = try NodeFactsQueries.activity(database, since: nil)
      var items: [NextItem] = []
      for project in projects {
        // No captured activity → nothing grounded, so skip the node. `NextItem.lastActivityAt` is
        // non-optional and documents this; the same reading of the one no-events rule as
        // `BriefingQueries.cards`.
        guard let facts = activity[project.id], let lastActivityAt = facts.lastActivityAt else { continue }
        let dormant = dayCount(from: lastActivityAt, to: now)
        items.append(NextItem(project: project, openLooseEnds: facts.openLooseEnds,
                              closedLooseEnds: facts.closedLooseEnds,
                              lastActivityAt: lastActivityAt, daysDormant: dormant,
                              score: groundedScore(openLooseEnds: facts.openLooseEnds,
                                                   daysDormant: dormant)))
      }
      return items.sorted { $0.score > $1.score }
    }
  }
}

extension NextQueries {
  /// The ranked queue narrowed to "what should I pick up next": actionable only, and — when a Focus
  /// context is active — only the nodes visible under it. An empty `context` means no Focus, which
  /// `NodeContextResolver` also treats as "everything"; the guard here only skips the node fetch.
  ///
  /// One function because four surfaces answer this same question — `SmartLists.whatsNext`, MCP
  /// `whats_next`, `pensieve next` and the widget digest — and each restated it. The widget shipped
  /// answering a *different* question by forgetting `isActionable`, which is what a rule kept alive
  /// by a hand-maintained list of remembering callers eventually costs.
  public static func whatsNext(_ database: any DatabaseReader, now: Date,
                               context: String = "") throws -> [NextItem] {
    let actionable = try ranked(database, now: now).filter(\.isActionable)
    guard !context.isEmpty else { return actionable }
    let visible = NodeContextResolver.visibleNodeIDs(for: context,
                                                     in: try ProjectQueries.all(database))
    return actionable.filter { visible.contains($0.project.id) }
  }
}
