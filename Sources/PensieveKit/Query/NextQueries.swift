import Foundation
import SQLiteData

public struct NextItem: Sendable {
  public let project: Node
  public let openLooseEnds: Int
  public let daysDormant: Int
  public let score: Double
}

/// The single grounded ranking score. Long dormancy can dominate by design — it's a strong
/// "you forgot this" signal for ADHD workflows. Shared by `NextQueries.ranked` and
/// `SessionContextQueries.bundle` so the two never silently diverge.
public func groundedScore(openLooseEnds: Int, daysDormant: Int) -> Double {
  Double(openLooseEnds) * 2 + Double(daysDormant)
}

public enum NextQueries {
  /// Deterministic ranking on grounded signals only. No model, no invented scores.
  public static func ranked(_ db: any DatabaseReader, now: Date) throws -> [NextItem] {
    try db.read { db in
      let projects = try Node.where { $0.state.eq("active") }.fetchAll(db)
      var items: [NextItem] = []
      for p in projects {
        let latest = try Event.where { $0.nodeID.eq(p.id) }
          .order { $0.occurredAt.desc() }.limit(1).fetchOne(db)
        guard let latest else { continue }   // no captured activity → nothing grounded (matches BriefingQueries)
        let dormant = Calendar.current.dateComponents([.day], from: latest.occurredAt, to: now).day ?? 0
        let open = try LooseEnd.where { $0.nodeID.eq(p.id) && LooseEnd.isOpen($0) }.fetchCount(db)
        let score = groundedScore(openLooseEnds: open, daysDormant: dormant)
        items.append(NextItem(project: p, openLooseEnds: open, daysDormant: dormant, score: score))
      }
      return items.sorted { $0.score > $1.score }
    }
  }
}
