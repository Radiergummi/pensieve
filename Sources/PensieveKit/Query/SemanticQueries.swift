// Sources/PensieveKit/Query/SemanticQueries.swift
import Foundation
import SQLiteData

/// The filter knobs a semantic search applies AFTER the KNN fetch: which nodes are visible under
/// the active Focus, which item ids are already covered by exact search, how many hits to keep,
/// the similarity floor, and whether archived content is eligible.
public struct SemanticSearchScope: Sendable {
  public var visibleNodeIDs: Set<UUID>
  public var excludingIDs: Set<UUID>
  public var limit: Int
  public var floor: Double
  public var includeArchived: Bool
  public init(visibleNodeIDs: Set<UUID>, excludingIDs: Set<UUID>, limit: Int, floor: Double,
              includeArchived: Bool = false) {
    self.visibleNodeIDs = visibleNodeIDs
    self.excludingIDs = excludingIDs
    self.limit = limit
    self.floor = floor
    self.includeArchived = includeArchived
  }
}

/// Semantic ("find similar") recall over the sqlite-vec index, joined back to the live canonical
/// corpus. KNN alone is fixed-limit and pre-filter — a fixed limit could return only Focus-muted rows, so
/// this over-fetches from the store before applying `visibleNodeIDs`/`excludingIDs`/`floor`, then
/// re-resolves each survivor against canonical and re-applies the SAME "is this still part of the
/// live corpus" predicate the index itself uses (`isOpen` / active node) as a last line of
/// grounding defense — a between-sync stale index row never surfaces a dead hit. Best-effort:
/// an unavailable index or a nil query embedding yields `[]`, never throws/blocks.
/// Archived items are indexed but excluded by default: `includeArchived` widens BOTH the index
/// filter and this canonical re-check, in lockstep. `muted` is never returned.
///
/// Returns the shared `SearchHit`, the same type BM25 returns — but the two scores are NEVER
/// comparable: this one is a cosine similarity in [-1, 1], BM25's is an unbounded relevance score.
/// Never blend or sort them together.
public enum SemanticQueries {
  public static func search(query rawQuery: String,
                            scope: SemanticSearchScope,
                            store: SemanticIndexStore,
                            embedder: any TextEmbedder,
                            _ database: any DatabaseReader) async -> [SearchHit] {
    let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    guard query.count >= 2, store.isAvailable,
          // `.first` is doubly optional now (batch nil vs. this-item nil) — both mean "no query
          // vector", so flatten and bail either way.
          let qvec = await embedder.embed([query])?.first ?? nil else { return [] }

    // Over-fetch, and grow the fetch window if post-KNN filtering (Focus-muting) starved the
    // result below limit. A floor-aware exit keeps ordinary sparse queries (few above-floor items) at
    // one fetch: similarity is monotonically non-increasing across `raw`, so once the farthest
    // fetched neighbor is below `floor`, no deeper neighbor can ever become a hit.
    var kFetch = max(scope.limit * 8, 50)
    let maxFetch = 2000
    while true {
      let raw = store.knn(query: qvec, limit: kFetch, includeArchived: scope.includeArchived)
      let hits = buildHits(raw, scope: scope, query: query, database)
      if hits.count >= scope.limit || raw.count < kFetch || kFetch >= maxFetch { return hits }
      if let last = raw.last, last.similarity < scope.floor { return hits }
      kFetch = min(kFetch * 4, maxFetch)
    }
  }

  /// Filter one KNN page down to at most `limit` grounded, visible, above-floor, non-excluded hits,
  /// resolving each survivor against canonical via the shared `SearchHitResolver` (the last
  /// grounding defense). Deterministic KNN ordering makes each larger fetch a superset prefix, so
  /// rebuilding from the top is correct. One read transaction for the whole page.
  private static func buildHits(_ raw: [KNNResult], scope: SemanticSearchScope,
                                query: String, _ database: any DatabaseReader) -> [SearchHit] {
    let resolver = SearchHitResolver(includeArchived: scope.includeArchived,
                                     highlight: { SnippetMaker.make(from: $0, matching: query) })
    // Logged, not silent, for the same reason as the exact path: this catch is a failure to OPEN a
    // canonical read, which is an app-wide condition rather than an absence of results.
    do {
      return try database.read { database in
        var hits: [SearchHit] = []
        for result in raw {
          guard result.similarity >= scope.floor,
                let kind = SearchHit.Kind(rawValue: result.kind),
                let nodeID = UUID(uuidString: result.nodeID),
                scope.visibleNodeIDs.contains(nodeID) else { continue }
          guard let itemID = UUID(uuidString: result.itemID),
                !scope.excludingIDs.contains(itemID) else { continue }
          guard let hit = try? resolver.resolve(kind: kind, itemID: itemID, score: result.similarity,
                                                database) else { continue }
          hits.append(hit)
          if hits.count == scope.limit { break }
        }
        return hits
      }
    } catch {
      Log.semantic.error("SemanticQueries: canonical read failed: \(error, privacy: .public)")
      return []
    }
  }
}
