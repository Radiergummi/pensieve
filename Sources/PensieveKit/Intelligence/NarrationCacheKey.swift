import Foundation

/// Order-independent invalidation key for a node's persisted narration. Derived from exactly
/// the events `SummaryBuilder.assembleFacts` narrates (the caller passes the same top-N set):
/// the sorted event IDs (membership + count) plus the latest `extractedAt` over that set (which
/// moves whenever a session's `workSummary` is re-enriched). NOT keyed on "the latest event id":
/// `ProjectQueries.status` orders by `occurredAt` with no tiebreaker, so tied timestamps make the
/// top row nondeterministic and such a key would flip run-to-run.
public enum NarrationCacheKey {
  public static func make(events: [Event]) -> String {
    let ids = events.map { $0.id.uuidString }.sorted()
    let latestExtracted = events.compactMap { $0.extractedAt }.max()
    let stamp = latestExtracted.map { String($0.timeIntervalSince1970) } ?? "none"
    return "\(ids.joined(separator: ","))|\(stamp)"
  }
}
