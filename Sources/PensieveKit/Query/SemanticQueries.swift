// Sources/PensieveKit/Query/SemanticQueries.swift
import Foundation
import SQLiteData

public struct SemanticHit: Identifiable, Sendable, Equatable {
  public let id: UUID           // node id / loose-end id / event id
  public let kind: String       // "node" | "loose_end" | "event"
  public let nodeID: UUID
  public let nodeName: String
  public let title: String      // node name / loose-end text / event summary
  public let snippet: Snippet
  public let similarity: Double
  /// The owning node is archived — the view badges the row. Always false unless the caller
  /// opted into archived results.
  public let isArchived: Bool
}

/// Semantic ("find similar") recall over the sqlite-vec index, joined back to the live canonical
/// corpus. KNN alone is fixed-k and pre-filter — a fixed k could return only Focus-muted rows, so
/// this over-fetches from the store before applying `visibleNodeIDs`/`excludingIDs`/`floor`, then
/// re-resolves each survivor against canonical and re-applies the SAME "is this still part of the
/// live corpus" predicate the index itself uses (`isOpen` / active node) as a last line of
/// grounding defense — a between-sync stale index row never surfaces a dead hit. Best-effort:
/// an unavailable index or a nil query embedding yields `[]`, never throws/blocks.
/// Archived items are indexed but excluded by default: `includeArchived` widens BOTH the index
/// filter and this canonical re-check, in lockstep. `muted` is never returned.
public enum SemanticQueries {
  public static func search(query rawQuery: String,
                            visibleNodeIDs: Set<UUID>,
                            excludingIDs: Set<UUID>,
                            k: Int,
                            floor: Double,
                            includeArchived: Bool = false,
                            store: SemanticIndexStore,
                            embedder: any TextEmbedder,
                            _ db: any DatabaseReader) async -> [SemanticHit] {
    let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    guard query.count >= 2, store.isAvailable,
          // `.first` is doubly optional now (batch nil vs. this-item nil) — both mean "no query
          // vector", so flatten and bail either way.
          let qvec = await embedder.embed([query])?.first ?? nil else { return [] }

    // Over-fetch, and grow the fetch window if post-KNN filtering (Focus-muting) starved the
    // result below k. A floor-aware exit keeps ordinary sparse queries (few above-floor items) at
    // one fetch: similarity is monotonically non-increasing across `raw`, so once the farthest
    // fetched neighbor is below `floor`, no deeper neighbor can ever become a hit.
    var kFetch = max(k * 8, 50)
    let maxFetch = 2000
    while true {
      let raw = store.knn(query: qvec, k: kFetch, includeArchived: includeArchived)
      let hits = buildHits(raw, k: k, floor: floor, visibleNodeIDs: visibleNodeIDs,
                           excludingIDs: excludingIDs, includeArchived: includeArchived,
                           query: query, db)
      if hits.count >= k || raw.count < kFetch || kFetch >= maxFetch { return hits }
      if let last = raw.last, last.similarity < floor { return hits }
      kFetch = min(kFetch * 4, maxFetch)
    }
  }

  /// Filter one KNN page down to at most `k` grounded, visible, above-floor, non-excluded hits,
  /// re-resolving each survivor against canonical (the last grounding defense). Deterministic KNN
  /// ordering makes each larger fetch a superset prefix, so rebuilding from the top is correct.
  private static func buildHits(_ raw: [KNNResult], k: Int, floor: Double,
                                visibleNodeIDs: Set<UUID>, excludingIDs: Set<UUID>,
                                includeArchived: Bool,
                                query: String, _ db: any DatabaseReader) -> [SemanticHit] {
    var hits: [SemanticHit] = []
    for r in raw {
      guard r.similarity >= floor,
            let nodeID = UUID(uuidString: r.nodeID), visibleNodeIDs.contains(nodeID) else { continue }
      guard let itemID = UUID(uuidString: r.itemID), !excludingIDs.contains(itemID) else { continue }
      guard let hit = try? resolve(kind: r.kind, itemID: itemID, similarity: r.similarity,
                                   includeArchived: includeArchived, query: query, db) else { continue }
      hits.append(hit)
      if hits.count == k { break }
    }
    return hits
  }

  /// Re-resolve one index row against canonical — the last grounding defense, so a between-sync
  /// stale row never surfaces a dead hit. The state predicate MUST mirror the `knn` filter: if the
  /// index widens to archived but this does not, archived rows pass KNN and are then silently
  /// dropped here. Same predicate shape as `SearchQueries` uses for exact search.
  private static func resolve(kind: String, itemID: UUID, similarity: Double,
                              includeArchived: Bool, query: String,
                              _ db: any DatabaseReader) throws -> SemanticHit? {
    func eligible(_ n: Node) -> Bool {
      n.state == .active || (includeArchived && n.state == .archived)
    }
    return try db.read { db in
      switch kind {
      case "node":
        guard let n = try Node.where({ $0.id.eq(itemID) }).fetchOne(db), eligible(n) else { return nil }
        return SemanticHit(id: n.id, kind: kind, nodeID: n.id, nodeName: n.name, title: n.name,
                           snippet: SnippetMaker.make(from: n.description.isEmpty ? n.name : n.description, matching: query),
                           similarity: similarity, isArchived: n.state == .archived)
      case "loose_end":
        guard let le = try LooseEnd.where({ $0.id.eq(itemID) && LooseEnd.isOpen($0) }).fetchOne(db),
              let n = try Node.where({ $0.id.eq(le.nodeID) }).fetchOne(db), eligible(n) else { return nil }
        return SemanticHit(id: le.id, kind: kind, nodeID: le.nodeID, nodeName: n.name, title: le.text,
                           snippet: SnippetMaker.make(from: le.text, matching: query),
                           similarity: similarity, isArchived: n.state == .archived)
      case "event":
        guard let e = try Event.where({ $0.id.eq(itemID) }).fetchOne(db),
              let n = try Node.where({ $0.id.eq(e.nodeID) }).fetchOne(db), eligible(n) else { return nil }
        let body = (e.workSummary?.isEmpty == false ? e.workSummary! : e.summary)
        return SemanticHit(id: e.id, kind: kind, nodeID: e.nodeID, nodeName: n.name, title: body,
                           snippet: SnippetMaker.make(from: body, matching: query),
                           similarity: similarity, isArchived: n.state == .archived)
      default: return nil
      }
    }
  }
}
