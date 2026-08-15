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
  public static func search(query rawQuery: String, scope: SearchScope, store: SearchIndexStore,
                            _ database: any DatabaseReader) -> [PassageHit] {
    let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    guard store.isAvailable, query.count >= SearchQueries.minQueryLength,
          let ftsQuery = FTSQueryBuilder.build(rawQuery, file: nil) else { return [] }

    // Over-fetch for the same reasons the text path does — Focus-muting, exclusions and stale rows
    // all drop candidates after the index — plus one specific to passages: several chunks of one
    // turn collapse into a single hit, so the candidate:hit ratio is structurally worse than 1:1.
    let candidates = store.searchPassages(ftsQuery, limit: max(scope.limit * 8, 50),
                                          includeArchived: scope.includeArchived)
    guard !candidates.isEmpty else { return [] }

    do {
      return try database.read { database in
        try resolve(candidates, terms: ftsQuery.terms, scope: scope, database)
      }
    } catch {
      Log.search.error("PassageQueries: canonical read failed: \(error, privacy: .public)")
      return []
    }
  }

  /// Re-resolve candidates against canonical, collapse chunks of one turn, and keep at most
  /// `scope.limit`. Ordering is the index's — candidates arrive BM25-descending, so the first
  /// surviving chunk of a turn is also its best-scoring one, and dedupe keeps that one.
  private static func resolve(_ candidates: [SearchIndexHit], terms: [String], scope: SearchScope,
                              _ database: Database) throws -> [PassageHit] {
    var hits: [PassageHit] = []
    var seenTurns = Set<TurnKey>()
    var nodeCache: [UUID: Node] = [:]

    for candidate in candidates {
      guard candidate.kind == "passage",
            let passageID = UUID(uuidString: candidate.itemID),
            let nodeID = UUID(uuidString: candidate.nodeID),
            scope.visibleNodeIDs.contains(nodeID),
            !scope.excludingIDs.contains(passageID) else { continue }
      // Re-read from canonical: the index only decided eligibility.
      guard let passage = try Passage.where({ $0.id.eq(passageID) }).fetchOne(database)
      else { continue }
      let node: Node
      if let cached = nodeCache[passage.nodeID] {
        node = cached
      } else {
        guard let fetched = try Node.where({ $0.id.eq(passage.nodeID) }).fetchOne(database)
        else { continue }
        nodeCache[passage.nodeID] = fetched
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

  /// One conversation turn. `eventID` is part of the key because `turnIndex` restarts at 0 in every
  /// session — keying on the index alone would collapse turn 0 of every session into one row.
  private struct TurnKey: Hashable {
    let eventID: UUID
    let turnIndex: Int
  }
}
