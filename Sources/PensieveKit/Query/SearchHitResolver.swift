// Sources/PensieveKit/Query/SearchHitResolver.swift
import Foundation
import SQLiteData
import GRDB

extension NodeState {
  /// The node states a search may surface: `active` always, `archived` only when the caller opted
  /// in. An allow-list, never a deny-list — `muted` is excluded in both modes, and a future state
  /// can never leak in by omission.
  ///
  /// The single source for this rule. It is applied twice per query on purpose — once in SQL so the
  /// index returns only eligible rows, once again here when each candidate is re-resolved against
  /// canonical — and those two applications MUST agree, or rows pass the query and are then silently
  /// dropped. Sharing one definition is what makes them agree.
  public static func searchable(includeArchived: Bool) -> [NodeState] {
    includeArchived ? [.active, .archived] : [.active]
  }

  public func isSearchable(includeArchived: Bool) -> Bool {
    Self.searchable(includeArchived: includeArchived).contains(self)
  }
}

/// Turns one index row into a grounded `SearchHit` by re-reading the item from the canonical store —
/// the last line of grounding defense, so a between-sync stale index row can never surface a dead
/// hit. Shared by both retrieval engines: BM25 and the vector index differ only in how they pick
/// candidates and how they highlight them, never in what a hit is allowed to be.
///
/// Takes an open `Database` rather than a `DatabaseReader` so the caller can resolve a whole
/// candidate page inside ONE read transaction instead of one per hit.
///
/// The two per-query knobs are properties rather than per-candidate arguments: they are fixed for a
/// whole result page, so the caller builds one resolver and walks its candidates with it.
struct SearchHitResolver {
  let includeArchived: Bool
  /// Receives the body text this hit displays and returns its snippet — the one place the two
  /// engines diverge (BM25 highlights the query's unstemmed terms, the vector index the raw query
  /// string).
  let highlight: (String) -> Snippet

  func resolve(kind: SearchHit.Kind, itemID: UUID, score: Double,
               _ database: Database) throws -> SearchHit? {
    func eligible(_ node: Node) -> Bool { node.state.isSearchable(includeArchived: includeArchived) }

    switch kind {
    case .node:
      guard let node = try Node.where({ $0.id.eq(itemID) }).fetchOne(database),
            eligible(node) else { return nil }
      let body = node.description.isEmpty ? node.name : node.description
      return SearchHit(id: node.id, kind: .node, nodeID: node.id, nodeName: node.name,
                       title: node.name, snippet: highlight(body),
                       score: score, isArchived: node.state == .archived)
    case .looseEnd:
      guard let looseEnd = try LooseEnd.where({ $0.id.eq(itemID) && LooseEnd.isOpen($0) })
              .fetchOne(database),
            let node = try Node.where({ $0.id.eq(looseEnd.nodeID) }).fetchOne(database),
            eligible(node) else { return nil }
      return SearchHit(id: looseEnd.id, kind: .looseEnd, nodeID: looseEnd.nodeID,
                       nodeName: node.name, title: looseEnd.text,
                       snippet: highlight(looseEnd.text),
                       score: score, isArchived: node.state == .archived)
    case .event:
      guard let event = try Event.where({ $0.id.eq(itemID) }).fetchOne(database),
            let node = try Node.where({ $0.id.eq(event.nodeID) }).fetchOne(database),
            eligible(node) else { return nil }
      let workSummary = event.workSummary ?? ""
      let body = workSummary.isEmpty ? event.summary : workSummary
      return SearchHit(id: event.id, kind: .event, nodeID: event.nodeID, nodeName: node.name,
                       title: body, snippet: highlight(body),
                       score: score, isArchived: node.state == .archived)
    }
  }
}
