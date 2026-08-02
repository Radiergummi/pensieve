// Sources/PensieveKit/Query/RelatedQueries.swift
import Foundation
import SQLiteData

/// Keyword ("find related work") recall over the BM25 index, joined back to the live canonical
/// corpus. Retrieval is fixed-k and pre-filter, so a fixed fetch could return only Focus-muted rows:
/// this over-fetches from the store, applies `visibleNodeIDs`/`excludingIDs`, then re-resolves each
/// survivor against canonical through the shared `RelatedResolver` — the same "is this still part of
/// the live corpus" predicate the index itself uses — as the last line of grounding defense.
/// Best-effort: an unavailable index or an unusable query yields `[]`, never throws.
///
/// **There is no relevance floor, by design.** BM25 scores are unbounded and scaled per query, so a
/// fixed cutoff would be meaningless (the vector path's `floor: 0.25` was measured inert). Relevance
/// here is bounded by rank (`k`) plus the requirement that a document actually contain query terms —
/// which, unlike an anisotropic cosine, is a real signal. **A rank cap is not a relevance threshold:**
/// for a single common term this will still return `k` weak matches. Earning a real threshold is
/// exactly what the P3 harness exists to do.
///
/// Synchronous on purpose (no embedding step, so nothing to await) — a `@MainActor` caller must
/// offload it, e.g. `await Task.detached { RelatedQueries.search(…) }.value`.
public enum RelatedQueries {
  public static func search(query rawQuery: String,
                            visibleNodeIDs: Set<UUID>,
                            excludingIDs: Set<UUID>,
                            k: Int,
                            includeArchived: Bool = false,
                            store: TextIndexStore,
                            _ db: any DatabaseReader) -> [SemanticHit] {
    let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    guard query.count >= SearchQueries.minQueryLength, k > 0, store.isAvailable else { return [] }

    // Grow the fetch window when post-retrieval filtering (Focus-muting, exclusions, stale rows)
    // starves the result below k. BM25 ordering is deterministic and score-descending, so each
    // larger fetch is a superset prefix and rebuilding from the top is correct. Exits as soon as
    // the store is exhausted (`raw.count < kFetch`) so an ordinary sparse query costs one fetch.
    var kFetch = max(k * 8, 50)
    let maxFetch = 2000
    while true {
      let raw = store.search(query: query, k: kFetch, includeArchived: includeArchived)
      let hits = buildHits(raw, k: k, visibleNodeIDs: visibleNodeIDs, excludingIDs: excludingIDs,
                           includeArchived: includeArchived, query: query, db)
      if hits.count >= k || raw.count < kFetch || kFetch >= maxFetch { return hits }
      kFetch = min(kFetch * 4, maxFetch)
    }
  }

  /// Filter one BM25 page down to at most `k` grounded, visible, non-excluded hits.
  private static func buildHits(_ raw: [BM25Result], k: Int,
                                visibleNodeIDs: Set<UUID>, excludingIDs: Set<UUID>,
                                includeArchived: Bool,
                                query: String, _ db: any DatabaseReader) -> [SemanticHit] {
    var hits: [SemanticHit] = []
    for r in raw {
      guard let nodeID = UUID(uuidString: r.nodeID), visibleNodeIDs.contains(nodeID) else { continue }
      guard let itemID = UUID(uuidString: r.itemID), !excludingIDs.contains(itemID) else { continue }
      guard let hit = try? RelatedResolver.resolve(kind: r.kind, itemID: itemID, score: r.score,
                                                   includeArchived: includeArchived, query: query, db) else { continue }
      hits.append(hit)
      if hits.count == k { break }
    }
    return hits
  }
}
