import Foundation
import SQLiteData

/// Grounded facts for one open loose end — the searchable payload for the Spotlight `LooseEndEntity`
/// and its by-id tap resolution. Mirrors `NodeFacts`/`NodeFactsQueries`. Read-only (`DatabaseReader`).
public struct LooseEndFacts: Sendable {
  public let looseEndID: UUID
  public let nodeID: UUID
  public let nodeName: String
  public let text: String
  public let quote: String

  public init(looseEndID: UUID, nodeID: UUID, nodeName: String, text: String, quote: String) {
    self.looseEndID = looseEndID; self.nodeID = nodeID; self.nodeName = nodeName
    self.text = text; self.quote = quote
  }
}

public enum LooseEndFactsQueries {
  /// Every open loose end (`LooseEnd.isOpen`) whose node is `active`, joined to its node name.
  /// Focus scoping is applied by the app-side indexer against this set (Kit stays Focus-agnostic).
  public static func all(_ database: any DatabaseReader) throws -> [LooseEndFacts] {
    try database.read { database in
      let activeNodes = try Node.where { $0.state.eq(NodeState.active) }.fetchAll(database)
      let nameByID = Dictionary(activeNodes.map { ($0.id, $0.name) }, uniquingKeysWith: { existingValue, _ in existingValue })
      let ends = try LooseEnd.where { LooseEnd.isOpen($0) }.fetchAll(database)
      return ends.compactMap { looseEnd in
        guard let name = nameByID[looseEnd.nodeID] else { return nil }   // node not active → excluded
        return LooseEndFacts(looseEndID: looseEnd.id, nodeID: looseEnd.nodeID, nodeName: name,
                             text: looseEnd.text, quote: looseEnd.quote)
      }
    }
  }

  /// By-id resolution for a Spotlight tap — **any status/label/node-state**, so a since-closed or
  /// archived-node loose end still resolves (a tap opens its node). Unknown id → dropped.
  public static func facts(for ids: [UUID], _ database: any DatabaseReader) throws -> [LooseEndFacts] {
    try database.read { database in
      try ids.compactMap { id in
        guard let looseEnd = try LooseEnd.where({ $0.id.eq(id) }).fetchOne(database) else { return nil }
        let name = try Node.where({ $0.id.eq(looseEnd.nodeID) }).fetchOne(database)?.name ?? ""
        return LooseEndFacts(looseEndID: looseEnd.id, nodeID: looseEnd.nodeID, nodeName: name,
                             text: looseEnd.text, quote: looseEnd.quote)
      }
    }
  }
}
