// Sources/PensieveKit/Query/RelatedResolver.swift
import Foundation
import SQLiteData

/// Re-resolve one retrieval-index row against canonical — the last grounding defense, so a
/// between-sync stale row never surfaces a dead hit. Shared by BOTH retrieval engines
/// (`RelatedQueries` over BM25 and `SemanticQueries` over the vector index) so the two can never
/// drift on what is eligible: if the index widens to archived but this predicate does not, archived
/// rows pass retrieval and are then silently dropped here. Same predicate shape as `SearchQueries`
/// uses for exact search.
enum RelatedResolver {
  static func resolve(kind: String, itemID: UUID, score: Double,
                      includeArchived: Bool, query: String,
                      _ db: any DatabaseReader) throws -> SemanticHit? {
    func eligible(_ n: Node) -> Bool {
      n.state == .active || (includeArchived && n.state == .archived)
    }
    return try db.read { db in
      switch kind {
      case "node":
        guard let n = try Node.where { $0.id.eq(itemID) }.fetchOne(db), eligible(n) else { return nil }
        return SemanticHit(id: n.id, kind: kind, nodeID: n.id, nodeName: n.name, title: n.name,
                           snippet: SnippetMaker.make(from: n.description.isEmpty ? n.name : n.description, matching: query),
                           similarity: score, isArchived: n.state == .archived)
      case "loose_end":
        guard let le = try LooseEnd.where { $0.id.eq(itemID) && LooseEnd.isOpen($0) }.fetchOne(db),
              let n = try Node.where { $0.id.eq(le.nodeID) }.fetchOne(db), eligible(n) else { return nil }
        return SemanticHit(id: le.id, kind: kind, nodeID: le.nodeID, nodeName: n.name, title: le.text,
                           snippet: SnippetMaker.make(from: le.text, matching: query),
                           similarity: score, isArchived: n.state == .archived)
      case "event":
        guard let e = try Event.where { $0.id.eq(itemID) }.fetchOne(db),
              let n = try Node.where { $0.id.eq(e.nodeID) }.fetchOne(db), eligible(n) else { return nil }
        let body = (e.workSummary?.isEmpty == false ? e.workSummary! : e.summary)
        return SemanticHit(id: e.id, kind: kind, nodeID: e.nodeID, nodeName: n.name, title: body,
                           snippet: SnippetMaker.make(from: body, matching: query),
                           similarity: score, isArchived: n.state == .archived)
      default: return nil
      }
    }
  }
}
