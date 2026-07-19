import Foundation
import SQLiteData

public struct EmbeddableItem: Sendable {
  public let itemID: String, kind: String, nodeID: String, state: String, text: String
  public init(itemID: String, kind: String, nodeID: String, state: String, text: String) {
    self.itemID = itemID; self.kind = kind; self.nodeID = nodeID; self.state = state; self.text = text
  }
  /// Stable across processes/runs (String.hashValue is per-process salted — do NOT use it here).
  public var contentHash: String {
    var h: UInt64 = 1469598103934665603            // FNV-1a
    for b in text.utf8 { h = (h ^ UInt64(b)) &* 1099511628211 }
    return String(h, radix: 16)
  }
}

/// v1 producer of the semantic corpus: active nodes + open loose ends + enriched events.
/// The seam future producers (transcript chunks, etc.) extend.
public enum EmbeddableCorpus {
  public static func gather(_ db: any DatabaseReader) throws -> [EmbeddableItem] {
    try db.read { db in
      var out: [EmbeddableItem] = []
      let nodes = try Node.where { $0.state.eq(NodeState.active) }.fetchAll(db)
      let activeIDs = Set(nodes.map { $0.id })
      for n in nodes {
        out.append(.init(itemID: n.id.uuidString, kind: "node", nodeID: n.id.uuidString,
                         state: n.state.rawValue, text: [n.name, n.description].filter { !$0.isEmpty }.joined(separator: " — ")))
      }
      let ends = try LooseEnd.where { LooseEnd.isOpen($0) }.fetchAll(db)
      for le in ends where activeIDs.contains(le.nodeID) {
        out.append(.init(itemID: le.id.uuidString, kind: "loose_end", nodeID: le.nodeID.uuidString,
                         state: "active", text: [le.text, le.quote].filter { !$0.isEmpty }.joined(separator: " — ")))
      }
      let events = try Event.all.fetchAll(db)
      for e in events where activeIDs.contains(e.nodeID) {
        let text: String?
        switch e.kind {
        case CaptureKind.ccSession: text = e.workSummary   // nil = skip terse placeholder
        default: text = e.summary.isEmpty ? nil : e.summary
        }
        if let text {
          out.append(.init(itemID: e.id.uuidString, kind: "event", nodeID: e.nodeID.uuidString,
                           state: "active", text: text))
        }
      }
      return out
    }
  }
}
