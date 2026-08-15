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
      // Both the event join and the ordering are `LooseEndQueries`' — this used to inline its own
      // copy of each, which is why the batching work had to fix both call sites or neither.
      return try LooseEndQueries.attachEvents(ends, database, now: now)
        .sorted(by: LooseEndQueries.suggestedSalientFirstThenOldest)
    }
  }

  public static func pendingCount(_ database: any DatabaseReader) throws -> Int {
    try database.read { database in
      try LooseEnd.where { $0.label.eq(LooseEndLabel.unlabeled) && $0.labelSuggestion.neq("") }.fetchCount(database)
    }
  }
}
