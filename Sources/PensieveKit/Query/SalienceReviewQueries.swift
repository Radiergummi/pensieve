import Foundation
import SQLiteData

/// Deliberately NOT filtered by `status`: a closed loose end is still labellable. Triage is about to
/// become the default surface, and 846 of 968 items are unlabeled — filtering on status would mean
/// every item burned down destroys a training example that was never collected. "Was the extractor
/// right" stays a meaningful question after "is this handled" has been answered.
///
/// The audit queue backing the app's "Review Suggestions" surface: unlabeled loose ends that
/// carry a machine `labelSuggestion`, ordered suggested-salient FIRST (harvest the scarce positives
/// — Haiku's high recall puts nearly all true positives in its salient bucket) then oldest source
/// first. Read-only; reuses `LooseEndView`.
public enum SalienceReviewQueries {
  public static func pending(_ database: any DatabaseReader, now: Date) throws -> [LooseEndView] {
    try database.read { database in
      let ends = try LooseEnd
        .where { $0.label.eq(LooseEndLabel.unlabeled) && $0.labelSuggestion.neq("") }
        .fetchAll(database)
      var views: [LooseEndView] = []
      for looseEnd in ends {
        guard let event = try Event.where({ $0.id.eq(looseEnd.sourceEventID) }).fetchOne(database) else { continue }
        let days = Calendar.current.dateComponents([.day], from: event.occurredAt, to: now).day ?? 0
        views.append(LooseEndView(looseEnd: looseEnd, occurredAt: event.occurredAt, ageDays: days))
      }
      // Suggested-salient first (0 before 1), then oldest source first.
      return views.sorted { left, right in
        let leftRank = left.looseEnd.labelSuggestion == LooseEndLabel.salient ? 0 : 1
        let rightRank = right.looseEnd.labelSuggestion == LooseEndLabel.salient ? 0 : 1
        if leftRank != rightRank { return leftRank < rightRank }
        return left.occurredAt < right.occurredAt
      }
    }
  }

  public static func pendingCount(_ database: any DatabaseReader) throws -> Int {
    try database.read { database in
      try LooseEnd.where { $0.label.eq(LooseEndLabel.unlabeled) && $0.labelSuggestion.neq("") }.fetchCount(database)
    }
  }
}
