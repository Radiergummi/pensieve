// Sources/PensieveKit/Query/SearchQueries.swift
import Foundation
import SQLiteData

public struct NodeHit: Identifiable, Equatable, Sendable {
  /// Which field produced the match — drives the row layout (name-match shows the name as the
  /// primary line; description-only match shows the node name primary + the description snippet).
  public enum MatchedField: Sendable, Equatable { case name, description }
  public let id: UUID
  public var name: String
  public var kind: String
  public var matchedField: MatchedField
  public var snippet: Snippet
}

public struct LooseEndHit: Identifiable, Equatable, Sendable {
  public let id: UUID          // loose-end id (the row to auto-expand)
  public var nodeID: UUID
  public var nodeName: String
  public var snippet: Snippet
}

public struct SearchResults: Equatable, Sendable {
  public var nodes: [NodeHit]
  public var looseEnds: [LooseEndHit]
  public var totalNodeMatches: Int
  public var totalLooseEndMatches: Int
  public init(nodes: [NodeHit] = [], looseEnds: [LooseEndHit] = [],
              totalNodeMatches: Int = 0, totalLooseEndMatches: Int = 0) {
    self.nodes = nodes; self.looseEnds = looseEnds
    self.totalNodeMatches = totalNodeMatches; self.totalLooseEndMatches = totalLooseEndMatches
  }
  public var isEmpty: Bool { nodes.isEmpty && looseEnds.isEmpty }
}

/// Read-only find over the grounded core corpus (node name/description, open loose-end text/quote),
/// scoped to `visibleNodeIDs` (the caller passes the Focus-visible set → Focus filtering is correct
/// by construction) AND to active-state nodes only (archived/muted nodes and their loose ends never
/// surface in search, matching every other normal-view surface). Case-insensitive substring match in
/// Swift (correct for non-ASCII; the corpus is small and single-user). Deterministic ranking with an
/// `id.uuidString` final tiebreaker.
public enum SearchQueries {
  public static let minQueryLength = 2
  private static let cap = 50

  public static func search(query rawQuery: String,
                            visibleNodeIDs: Set<UUID>,
                            _ db: any DatabaseReader) throws -> SearchResults {
    let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    guard query.count >= minQueryLength else { return SearchResults() }
    func hit(_ s: String) -> Bool { s.range(of: query, options: .caseInsensitive) != nil }

    return try db.read { db in
      let nodes = try Node.order { $0.name }.fetchAll(db)
        .filter { visibleNodeIDs.contains($0.id) && $0.state == "active" }
      let activeVisibleIDs = Set(nodes.map { $0.id })

      // NODES — rank 0 = name match, rank 1 = description-only match.
      var nodeScored: [(rank: Int, node: Node)] = []
      for n in nodes {
        let nameHit = hit(n.name)
        if nameHit { nodeScored.append((0, n)) }
        else if hit(n.description) { nodeScored.append((1, n)) }
      }
      let sortedNodes = nodeScored.sorted {
        ($0.rank, $0.node.name, $0.node.id.uuidString) < ($1.rank, $1.node.name, $1.node.id.uuidString)
      }
      let nodeHits = sortedNodes.prefix(cap).map { e -> NodeHit in
        let src = e.rank == 0 ? e.node.name : e.node.description
        return NodeHit(id: e.node.id, name: e.node.name, kind: e.node.kind,
                       matchedField: e.rank == 0 ? .name : .description,
                       snippet: SnippetMaker.make(from: src, matching: query))
      }

      // LOOSE ENDS — open + not-noise, visible nodes only. rank 0 = text match, 1 = quote-only.
      let nameByID = Dictionary(nodes.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
      let ends = try LooseEnd.where { LooseEnd.isOpen($0) }.fetchAll(db)
        .filter { activeVisibleIDs.contains($0.nodeID) }
      var leScored: [(rank: Int, le: LooseEnd)] = []
      for le in ends {
        let textHit = hit(le.text)
        if textHit { leScored.append((0, le)) }
        else if hit(le.quote) { leScored.append((1, le)) }
      }
      let sortedEnds = leScored.sorted { a, b in
        if a.rank != b.rank { return a.rank < b.rank }
        if a.le.createdAt != b.le.createdAt { return a.le.createdAt > b.le.createdAt }
        return a.le.id.uuidString < b.le.id.uuidString
      }
      let leHits = sortedEnds.prefix(cap).map { e -> LooseEndHit in
        let src = e.rank == 0 ? e.le.text : e.le.quote
        return LooseEndHit(id: e.le.id, nodeID: e.le.nodeID,
                           nodeName: nameByID[e.le.nodeID] ?? "",
                           snippet: SnippetMaker.make(from: src, matching: query))
      }

      return SearchResults(nodes: Array(nodeHits), looseEnds: Array(leHits),
                           totalNodeMatches: sortedNodes.count,
                           totalLooseEndMatches: sortedEnds.count)
    }
  }
}
