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
public enum SemanticQueries {
  public static func search(query rawQuery: String,
                            scope: SemanticSearchScope,
                            store: SemanticIndexStore,
                            embedder: any TextEmbedder,
                            _ database: any DatabaseReader) async -> [SemanticHit] {
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
  /// re-resolving each survivor against canonical (the last grounding defense). Deterministic KNN
  /// ordering makes each larger fetch a superset prefix, so rebuilding from the top is correct.
  private static func buildHits(_ raw: [KNNResult], scope: SemanticSearchScope,
                                query: String, _ database: any DatabaseReader) -> [SemanticHit] {
    var hits: [SemanticHit] = []
    for result in raw {
      guard result.similarity >= scope.floor,
            let nodeID = UUID(uuidString: result.nodeID), scope.visibleNodeIDs.contains(nodeID) else { continue }
      guard let itemID = UUID(uuidString: result.itemID), !scope.excludingIDs.contains(itemID) else { continue }
      guard let hit = try? resolve(result, itemID: itemID, includeArchived: scope.includeArchived,
                                   query: query, database) else { continue }
      hits.append(hit)
      if hits.count == scope.limit { break }
    }
    return hits
  }

  /// Re-resolve one index row against canonical — the last grounding defense, so a between-sync
  /// stale row never surfaces a dead hit. The state predicate MUST mirror the `knn` filter: if the
  /// index widens to archived but this does not, archived rows pass KNN and are then silently
  /// dropped here. Same predicate shape as `SearchQueries` uses for exact search.
  private static func resolve(_ result: KNNResult, itemID: UUID, includeArchived: Bool, query: String,
                              _ database: any DatabaseReader) throws -> SemanticHit? {
    let kind = result.kind
    let similarity = result.similarity
    func eligible(_ node: Node) -> Bool {
      node.state == .active || (includeArchived && node.state == .archived)
    }
    return try database.read { database in
      switch kind {
      case "node":
        guard let node = try Node.where({ $0.id.eq(itemID) }).fetchOne(database), eligible(node) else { return nil }
        return SemanticHit(id: node.id, kind: kind, nodeID: node.id, nodeName: node.name, title: node.name,
                           snippet: SnippetMaker.make(from: node.description.isEmpty ? node.name : node.description, matching: query),
                           similarity: similarity, isArchived: node.state == .archived)
      case "loose_end":
        guard let looseEnd = try LooseEnd.where({ $0.id.eq(itemID) && LooseEnd.isOpen($0) }).fetchOne(database),
              let node = try Node.where({ $0.id.eq(looseEnd.nodeID) }).fetchOne(database), eligible(node) else { return nil }
        return SemanticHit(id: looseEnd.id, kind: kind, nodeID: looseEnd.nodeID, nodeName: node.name, title: looseEnd.text,
                           snippet: SnippetMaker.make(from: looseEnd.text, matching: query),
                           similarity: similarity, isArchived: node.state == .archived)
      case "event":
        guard let event = try Event.where({ $0.id.eq(itemID) }).fetchOne(database),
              let node = try Node.where({ $0.id.eq(event.nodeID) }).fetchOne(database), eligible(node) else { return nil }
        let body = (event.workSummary?.isEmpty == false ? event.workSummary! : event.summary)
        return SemanticHit(id: event.id, kind: kind, nodeID: event.nodeID, nodeName: node.name, title: body,
                           snippet: SnippetMaker.make(from: body, matching: query),
                           similarity: similarity, isArchived: node.state == .archived)
      default: return nil
      }
    }
  }
}
