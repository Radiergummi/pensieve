import Foundation
import SQLiteData

/// One conversation that matched — a whole turn, not a chunk.
///
/// A dedicated type rather than a `SearchHit.Kind.passage` case, decided at plan time against the
/// code. `SearchQueries.buildHits` constructs `SearchHit.Kind(rawValue:)` from rows in the
/// `documents` table; a `.passage` case there would make it ACCEPT a passage row that a producer bug
/// wrote into the wrong table, resolve it, and surface it in the wrong ranked list. Disjoint enums
/// make that unrepresentable. It also keeps `role` off `SearchHit`, where it would be structurally
/// always-default for the other three kinds.
public struct PassageHit: Identifiable, Sendable, Equatable {
  public let id: UUID
  public let nodeID: UUID
  public let nodeName: String
  public let role: PassageRole
  public let occurredAt: Date
  public let snippet: Snippet
  /// Higher is better (`-bm25(document_passages)`). **Not comparable to `SearchHit.score`** — a
  /// different table with a different average document length. This is why passage results are a
  /// separate appended list and never merged into the ranked one.
  public let score: Double
  public let isArchived: Bool
}

/// Find across stored conversation passages. BM25 over `document_passages`, re-resolved against the
/// canonical `passages` table so a stale index row can never surface a dead hit — the same
/// index-decides-eligibility / canonical-decides-truth split every other retrieval path uses.
///
/// Best-effort: an unavailable index or an untypeable query yields `[]`, never a throw.
public enum PassageQueries {
  /// `file` is threaded through rather than pinned to nil so a caller's structured path restriction
  /// reaches the query SHAPE. It can only ever narrow this list to nothing — a passage carries no
  /// paths — but "nothing, because you restricted to a file" is the honest answer, and hardcoding
  /// nil here produced the opposite: passages that ignored the restriction, appended to ranked hits
  /// that honoured it. (A `files:` directive typed into the query string reached the shape either
  /// way, so this was never only about the structured parameter.)
  public static func search(query rawQuery: String, file: String? = nil, scope: SearchScope,
                            store: SearchIndexStore,
                            _ database: any DatabaseReader) -> [PassageHit] {
    let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    guard store.isAvailable, query.count >= SearchQueries.minQueryLength,
          let ftsQuery = FTSQueryBuilder.build(rawQuery, file: file) else { return [] }

    // Over-fetch, and grow the window if post-index filtering starved the result below `limit` —
    // Focus-muting, exclusions and stale rows all drop candidates after the index, and passages have
    // one more reason the text path does not: several chunks of one turn collapse into a single hit,
    // so the candidate:hit ratio is structurally worse than 1:1. Termination is the sibling's: enough
    // hits, the index has no more rows, or the hard cap.
    var fetchCount = max(scope.limit * 8, 50)
    // Carried ACROSS grow iterations. Each iteration re-resolves the whole page from candidate 0
    // rather than only the newly-arrived tail — the index re-runs `ORDER BY bm25 LIMIT k`, whose
    // ordering of tied scores is not guaranteed stable across `k`, so skipping a prefix could skip
    // a row. Re-resolving is therefore correct but re-READS every candidate from canonical, and
    // that is the expensive half: this table is an order of magnitude larger than the text one, so
    // it is also the first corpus where the loop actually grows. The caches make a grown fetch cost
    // only the rows it added; both are bounded by `SearchQueries.maxFetch`.
    var caches = ResolveCaches()
    while true {
      let candidates = store.searchPassages(ftsQuery, limit: fetchCount,
                                            includeArchived: scope.includeArchived)
      guard !candidates.isEmpty else { return [] }

      let hits: [PassageHit]
      do {
        hits = try database.read { database in
          try resolve(candidates, terms: ftsQuery.terms, scope: scope, caches: &caches, database)
        }
      } catch {
        Log.search.error("PassageQueries: canonical read failed: \(error, privacy: .public)")
        return []
      }

      if hits.count >= scope.limit || candidates.count < fetchCount
          || fetchCount >= SearchQueries.maxFetch {
        return hits
      }
      fetchCount = min(fetchCount * 4, SearchQueries.maxFetch)
    }
  }

  /// `search`, plus one retry in English when the literal query found nothing — the same policy the
  /// ranked path applies, from the same definition (`SearchQueries.englishRetryQuery`).
  ///
  /// Passages need this at least as much as the ranked list does, and arguably more: transcripts are
  /// overwhelmingly English even when the query is not, so a German phrase is likelier to miss here
  /// than against node names and commit subjects. Shipping the wrapper on one path and not the other
  /// meant the section most likely to benefit was the one section that never got it.
  public static func searchTranslatingOnEmpty(query rawQuery: String, file: String? = nil,
                                              scope: SearchScope, store: SearchIndexStore,
                                              language: String = TranslationTarget.off,
                                              translator: Translator? = nil,
                                              _ database: any DatabaseReader) async -> [PassageHit] {
    let hits = search(query: rawQuery, file: file, scope: scope, store: store, database)
    guard hits.isEmpty,
          let english = await SearchQueries.englishRetryQuery(for: rawQuery, language: language,
                                                             translator: translator)
    else { return hits }
    return search(query: english, file: file, scope: scope, store: store, database)
  }

  /// Re-resolve candidates against canonical, collapse chunks of one turn, and keep at most
  /// `scope.limit`. Ordering is the index's — candidates arrive BM25-descending, so the first
  /// surviving chunk of a turn is also its best-scoring one, and dedupe keeps that one.
  private static func resolve(_ candidates: [SearchIndexHit], terms: [String], scope: SearchScope,
                              caches: inout ResolveCaches,
                              _ database: Database) throws -> [PassageHit] {
    var hits: [PassageHit] = []
    var seenTurns = Set<TurnKey>()

    for candidate in candidates {
      guard candidate.kind == Passage.searchKind,
            let passageID = UUID(uuidString: candidate.itemID),
            let nodeID = UUID(uuidString: candidate.nodeID),
            scope.visibleNodeIDs.contains(nodeID),
            !scope.excludingIDs.contains(passageID) else { continue }
      // Re-read from canonical: the index only decided eligibility.
      let passage: Passage
      if let cached = caches.passages[passageID] {
        passage = cached
      } else {
        guard let fetched = try Passage.where({ $0.id.eq(passageID) }).fetchOne(database)
        else { continue }
        caches.passages[passageID] = fetched
        passage = fetched
      }
      let node: Node
      if let cached = caches.nodes[passage.nodeID] {
        node = cached
      } else {
        guard let fetched = try Node.where({ $0.id.eq(passage.nodeID) }).fetchOne(database)
        else { continue }
        caches.nodes[passage.nodeID] = fetched
        node = fetched
      }
      // The same allow-list the SQL filter renders, applied again here so the two cannot disagree.
      guard node.state.isSearchable(includeArchived: scope.includeArchived) else { continue }
      guard seenTurns.insert(TurnKey(eventID: passage.eventID,
                                     turnIndex: passage.turnIndex)).inserted else { continue }

      hits.append(PassageHit(id: passage.id, nodeID: passage.nodeID, nodeName: node.name,
                             role: passage.role, occurredAt: passage.occurredAt,
                             snippet: SnippetMaker.make(from: passage.text, matchingAny: terms),
                             score: candidate.score, isArchived: node.state == .archived))
      if hits.count == scope.limit { break }
    }
    return hits
  }

  /// The canonical rows `resolve` has already read, held across the grow loop's iterations. Deduped
  /// hits are NOT cached here: `seenTurns` is per-iteration on purpose, because a grown page is
  /// resolved from the start and must be free to pick the same turn's best chunk again.
  private struct ResolveCaches {
    var passages: [UUID: Passage] = [:]
    var nodes: [UUID: Node] = [:]
  }

  /// One conversation turn. `eventID` is part of the key because `turnIndex` restarts at 0 in every
  /// session — keying on the index alone would collapse turn 0 of every session into one row.
  private struct TurnKey: Hashable {
    let eventID: UUID
    let turnIndex: Int
  }
}
