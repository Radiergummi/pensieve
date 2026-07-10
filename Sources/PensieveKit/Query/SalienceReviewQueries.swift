import Foundation
import SQLiteData

/// The audit queue backing the app's "Review Suggestions" surface: open, unlabeled loose ends that
/// carry a machine `labelSuggestion`, ordered suggested-salient FIRST (harvest the scarce positives
/// — Haiku's high recall puts nearly all true positives in its salient bucket) then oldest source
/// first. Read-only; reuses `LooseEndView`.
public enum SalienceReviewQueries {
  public static func pending(_ db: any DatabaseReader, now: Date) throws -> [LooseEndView] {
    try db.read { db in
      let ends = try LooseEnd
        .where { $0.status.eq("open") && $0.label.eq("") && $0.labelSuggestion.neq("") }
        .fetchAll(db)
      var views: [LooseEndView] = []
      for le in ends {
        guard let event = try Event.where({ $0.id.eq(le.sourceEventID) }).fetchOne(db) else { continue }
        let days = Calendar.current.dateComponents([.day], from: event.occurredAt, to: now).day ?? 0
        views.append(LooseEndView(looseEnd: le, occurredAt: event.occurredAt, ageDays: days))
      }
      // Suggested-salient first (0 before 1), then oldest source first.
      return views.sorted { a, b in
        let aRank = a.looseEnd.labelSuggestion == LooseEndLabel.salient ? 0 : 1
        let bRank = b.looseEnd.labelSuggestion == LooseEndLabel.salient ? 0 : 1
        if aRank != bRank { return aRank < bRank }
        return a.occurredAt < b.occurredAt
      }
    }
  }

  public static func pendingCount(_ db: any DatabaseReader) throws -> Int {
    try db.read { db in
      try LooseEnd.where { $0.status.eq("open") && $0.label.eq("") && $0.labelSuggestion.neq("") }.fetchCount(db)
    }
  }
}
