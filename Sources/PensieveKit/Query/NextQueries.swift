import Foundation
import SQLiteData

public struct NextItem: Sendable {
  public let project: Project
  public let openLooseEnds: Int
  public let daysDormant: Int
  public let score: Double
}

public enum NextQueries {
  /// Deterministic ranking on grounded signals only. No model, no invented scores.
  public static func ranked(_ db: any DatabaseWriter, now: Date) throws -> [NextItem] {
    try db.read { db in
      let projects = try Project.where { $0.state.eq("active") }.fetchAll(db)
      var items: [NextItem] = []
      for p in projects {
        let latest = try Event.where { $0.projectID.eq(p.id) }
          .order { $0.occurredAt.desc() }.limit(1).fetchOne(db)
        let dormant = latest.map {
          Calendar.current.dateComponents([.day], from: $0.occurredAt, to: now).day ?? 0
        } ?? 0
        let open = try LooseEnd.where { $0.projectID.eq(p.id) && $0.status.eq("open") }.fetchAll(db).count
        // Long dormancy can dominate by design — it's a strong "you forgot this" signal for ADHD workflows
        let score = Double(open) * 2 + Double(dormant)
        items.append(NextItem(project: p, openLooseEnds: open, daysDormant: dormant, score: score))
      }
      return items.sorted { $0.score > $1.score }
    }
  }
}
