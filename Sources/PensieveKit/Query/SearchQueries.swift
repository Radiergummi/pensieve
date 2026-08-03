// Sources/PensieveKit/Query/SearchQueries.swift
import Foundation
import SQLiteData

public struct NodeHit: Identifiable, Equatable, Sendable {
  /// Which field produced the match — drives the row layout (name-match shows the name as the
  /// primary line; description-only match shows the node name primary + the description snippet).
  public enum MatchedField: Sendable, Equatable { case name, description }
  public let id: UUID
  public var name: String
  public var kind: NodeKind
  public var matchedField: MatchedField
  public var snippet: Snippet
  /// The node is archived — the view badges the row (archived hits surface only when the caller
  /// passed `includeArchived`).
  public var isArchived: Bool
}

public struct LooseEndHit: Identifiable, Equatable, Sendable {
  public let id: UUID          // loose-end id (the row to auto-expand)
  public var nodeID: UUID
  public var nodeName: String
  public var snippet: Snippet
  /// The owning node is archived — the view badges the row.
  public var isArchived: Bool
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
/// by construction) AND to active-state nodes only by default (archived nodes and their open loose
/// ends surface only when `includeArchived` is set; `muted` is never included). Case-insensitive
/// substring match in Swift (correct for non-ASCII; the corpus is small and single-user).
/// Deterministic ranking with an `id.uuidString` final tiebreaker.
public enum SearchQueries {
  public static let minQueryLength = 2
  private static let cap = 50

  public static func search(query rawQuery: String,
                            visibleNodeIDs: Set<UUID>,
                            includeArchived: Bool = false,
                            _ database: any DatabaseReader) throws -> SearchResults {
    let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    guard query.count >= minQueryLength else { return SearchResults() }
    func hit(_ text: String) -> Bool { text.range(of: query, options: .caseInsensitive) != nil }

    return try database.read { database in
      let nodes = try Node.order { $0.name }.fetchAll(database)
        .filter { node -> Bool in
          guard visibleNodeIDs.contains(node.id) else { return false }
          return node.state == .active || (includeArchived && node.state == .archived)
        }
      let matchedNodeIDs = Set(nodes.map { $0.id })

      // NODES — rank 0 = name match, rank 1 = description-only match.
      var nodeScored: [(rank: Int, node: Node)] = []
      for node in nodes {
        let nameHit = hit(node.name)
        if nameHit { nodeScored.append((0, node)) } else if hit(node.description) { nodeScored.append((1, node)) }
      }
      let sortedNodes = nodeScored.sorted {
        ($0.rank, $0.node.name, $0.node.id.uuidString) < ($1.rank, $1.node.name, $1.node.id.uuidString)
      }
      let nodeHits = sortedNodes.prefix(cap).map { entry -> NodeHit in
        let src = entry.rank == 0 ? entry.node.name : entry.node.description
        return NodeHit(id: entry.node.id, name: entry.node.name, kind: entry.node.kind,
                       matchedField: entry.rank == 0 ? .name : .description,
                       snippet: SnippetMaker.make(from: src, matching: query),
                       isArchived: entry.node.state == .archived)
      }

      // LOOSE ENDS — open + not-noise, visible nodes only. rank 0 = text match, 1 = quote-only.
      let nameByID = Dictionary(nodes.map { ($0.id, $0.name) }, uniquingKeysWith: { lhs, _ in lhs })
      let archivedNodeIDs = Set(nodes.filter { $0.state == .archived }.map { $0.id })
      let ends = try LooseEnd.where { LooseEnd.isOpen($0) }.fetchAll(database)
        .filter { matchedNodeIDs.contains($0.nodeID) }
      var leScored: [(rank: Int, looseEnd: LooseEnd)] = []
      for looseEnd in ends {
        let textHit = hit(looseEnd.text)
        if textHit { leScored.append((0, looseEnd)) } else if hit(looseEnd.quote) { leScored.append((1, looseEnd)) }
      }
      let sortedEnds = leScored.sorted { lhs, rhs in
        if lhs.rank != rhs.rank { return lhs.rank < rhs.rank }
        if lhs.looseEnd.createdAt != rhs.looseEnd.createdAt { return lhs.looseEnd.createdAt > rhs.looseEnd.createdAt }
        return lhs.looseEnd.id.uuidString < rhs.looseEnd.id.uuidString
      }
      let leHits = sortedEnds.prefix(cap).map { entry -> LooseEndHit in
        let src = entry.rank == 0 ? entry.looseEnd.text : entry.looseEnd.quote
        return LooseEndHit(id: entry.looseEnd.id, nodeID: entry.looseEnd.nodeID,
                           nodeName: nameByID[entry.looseEnd.nodeID] ?? "",
                           snippet: SnippetMaker.make(from: src, matching: query),
                           isArchived: archivedNodeIDs.contains(entry.looseEnd.nodeID))
      }

      return SearchResults(nodes: Array(nodeHits), looseEnds: Array(leHits),
                           totalNodeMatches: sortedNodes.count,
                           totalLooseEndMatches: sortedEnds.count)
    }
  }
}
