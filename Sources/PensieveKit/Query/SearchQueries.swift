// Sources/PensieveKit/Query/SearchQueries.swift
import Foundation
import SQLiteData

/// The filters a search applies AFTER the index returns candidates: which nodes are visible under
/// the active Focus, which item ids the caller already surfaced, how many hits to keep, and whether
/// archived content is eligible.
public struct SearchScope: Sendable {
  public var visibleNodeIDs: Set<UUID>
  public var excludingIDs: Set<UUID>
  public var limit: Int
  public var includeArchived: Bool
  public init(visibleNodeIDs: Set<UUID>, excludingIDs: Set<UUID> = [],
              limit: Int = SearchQueries.resultCap, includeArchived: Bool = false) {
    self.visibleNodeIDs = visibleNodeIDs
    self.excludingIDs = excludingIDs
    self.limit = limit
    self.includeArchived = includeArchived
  }
}

/// Find across the grounded corpus: BM25 over the FTS5 index, joined back to the live canonical
/// store. This is the single retrieval path — the substring matcher it replaced could not see
/// events at all (64% of the corpus) and could not answer a multi-word query.
///
/// The index only decides which rows are ELIGIBLE. Every candidate is re-resolved against
/// canonical and re-checked against the same "is this still part of the live corpus" predicate the
/// index itself uses, so a between-sync stale row can never surface a dead hit. Best-effort: an
/// unavailable index or an untypeable query yields `[]`, never a throw.
///
/// There is no relevance floor. BM25 scores are unbounded and per-query-scaled, so a fixed cutoff
/// would be meaningless — relevance is bounded by rank plus the requirement that a document
/// actually contain the query's terms. **A rank cap is not a relevance threshold**; earning one is
/// what the paraphrase eval harness (spec P3) exists to decide.
public enum SearchQueries {
  public static let minQueryLength = 2
  public static let resultCap = 50
  private static let maxFetch = 2000

  public static func search(query rawQuery: String,
                            file: String? = nil,
                            scope: SearchScope,
                            store: SearchIndexStore,
                            _ database: any DatabaseReader) -> [SearchHit] {
    let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    guard store.isAvailable,
          let ftsQuery = FTSQueryBuilder.build(rawQuery, file: file) else { return [] }
    // A one-character query is noise on its own, but not when a path directive anchors it — and the
    // shape already tells us whether one is present, so there is no need to re-inspect `file` here.
    if case .textWithPathProbe = ftsQuery.shape, query.count < minQueryLength { return [] }

    // Over-fetch, and grow the window if post-index filtering (Focus-muting, exclusions, a stale
    // row) starved the result below `limit`. With no floor there is no early exit to be had: the
    // honest termination is "the index has no more rows" or the hard cap.
    var fetchCount = max(scope.limit * 8, 50)
    while true {
      let candidates = store.search(ftsQuery, limit: fetchCount,
                                    includeArchived: scope.includeArchived)
      let hits = buildHits(candidates, terms: ftsQuery.terms, scope: scope, database)
      if hits.count >= scope.limit || candidates.count < fetchCount || fetchCount >= maxFetch {
        return hits
      }
      fetchCount = min(fetchCount * 4, maxFetch)
    }
  }

  /// The node the user is most likely navigating to, selected by scanning the VISIBLE node set —
  /// never the returned hits. A node crowded out of the result cap by events is equally absent
  /// from any function of those hits, and that happens exactly on the common-term queries where
  /// navigation matters most. Callers pass their already-Focus-filtered, already-scoped nodes, so
  /// a muted node can never be pinned above a list that excludes it.
  public static func topHit(query rawQuery: String, in nodes: [Node]) -> SearchHit? {
    let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    guard query.count >= minQueryLength else { return nil }
    let match = nodes
      .filter { hasWordPrefix($0.name, prefix: query) }
      .min { ($0.name, $0.id.uuidString) < ($1.name, $1.id.uuidString) }
    guard let match else { return nil }
    return SearchHit(id: match.id, kind: .node, nodeID: match.id, nodeName: match.name,
                     title: match.name,
                     snippet: SnippetMaker.make(from: match.name, matching: query),
                     score: nil, isArchived: match.state == .archived)
  }

  /// True when `prefix` starts the name or starts any word inside it, case- and
  /// diacritic-insensitively. Mid-word matches do not count — "racker" is not navigation intent.
  private static func hasWordPrefix(_ name: String, prefix: String) -> Bool {
    let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive, .anchored]
    if name.range(of: prefix, options: options) != nil { return true }
    return name.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
      .contains { $0.range(of: prefix, options: options) != nil }
  }

  /// Filter one index page down to at most `limit` grounded, visible, non-excluded hits, resolving
  /// each survivor against canonical via the shared `SearchHitResolver`. One read transaction for
  /// the whole page rather than one per candidate.
  private static func buildHits(_ candidates: [SearchIndexHit], terms: [String],
                                scope: SearchScope, _ database: any DatabaseReader) -> [SearchHit] {
    let resolver = SearchHitResolver(includeArchived: scope.includeArchived,
                                     highlight: { SnippetMaker.make(from: $0, matchingAny: terms) })
    // A failure here is failing to OPEN a canonical read — an app-wide condition, not a search
    // result — so it degrades to empty like every other read, but it is logged rather than mistaken
    // for "nothing matched". Per-candidate resolve failures stay silent and skip individually.
    do {
      return try database.read { database in
        var hits: [SearchHit] = []
        for candidate in candidates {
          guard let kind = SearchHit.Kind(rawValue: candidate.kind),
                let nodeID = UUID(uuidString: candidate.nodeID),
                scope.visibleNodeIDs.contains(nodeID) else { continue }
          guard let itemID = UUID(uuidString: candidate.itemID),
                !scope.excludingIDs.contains(itemID) else { continue }
          guard let hit = try? resolver.resolve(kind: kind, itemID: itemID, score: candidate.score,
                                                database) else { continue }
          hits.append(hit)
          if hits.count == scope.limit { break }
        }
        return hits
      }
    } catch {
      Log.search.error("SearchQueries: canonical read failed: \(error, privacy: .public)")
      return []
    }
  }
}
