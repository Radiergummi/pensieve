import Foundation

/// Order-independent invalidation key for a node's persisted narration. Derived from exactly
/// the events `SummaryBuilder.assembleFacts` narrates (the caller passes the same top-N set):
/// the sorted event IDs (membership + count) plus the latest `extractedAt` over that set (which
/// moves whenever a session's `workSummary` is re-enriched), plus the `provider` that produced
/// the prose — so switching the LLM provider invalidates cached narration and regenerates it.
/// NOT keyed on "the latest event id": `ProjectQueries.status` orders by `occurredAt` with no
/// tiebreaker, so tied timestamps make the top row nondeterministic and such a key would flip
/// run-to-run.
public enum NarrationCacheKey {
  /// Identifies the fact-sheet rule the cached prose was produced under. Bump this whenever
  /// `SummaryBuilder.narratableContent` or `assembleFacts` changes what the model is shown —
  /// otherwise prose generated under the old rule keeps being served on every node whose events
  /// have not moved, and the change is invisible exactly where it was most needed.
  ///
  /// `r2` = events contributing only a generated label (`"checkout <branch>"`,
  /// `"session (N prompts)"`) no longer enter the fact sheet.
  public static let factSheetRule = "r2"

  public static func make(events: [Event], provider: String = "") -> String {
    let ids = events.map { $0.id.uuidString }.sorted()
    let latestExtracted = events.compactMap { $0.extractedAt }.max()
    let stamp = latestExtracted.map { String($0.timeIntervalSince1970) } ?? "none"
    return "\(ids.joined(separator: ","))|\(stamp)|\(provider)|\(factSheetRule)"
  }
}
