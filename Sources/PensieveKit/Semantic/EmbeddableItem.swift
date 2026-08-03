import Foundation
import SQLiteData

public struct EmbeddableItem: Sendable {
  public let itemID: String, kind: String, nodeID: String, state: String, text: String
  public init(itemID: String, kind: String, nodeID: String, state: String, text: String) {
    self.itemID = itemID; self.kind = kind; self.nodeID = nodeID; self.state = state; self.text = text
  }
  /// Stable across processes/runs (String.hashValue is per-process salted — do NOT use it here).
  public var contentHash: String {
    var hashAccumulator: UInt64 = 1469598103934665603            // FNV-1a
    for byte in text.utf8 { hashAccumulator = (hashAccumulator ^ UInt64(byte)) &* 1099511628211 }
    return String(hashAccumulator, radix: 16)
  }
}

/// v1 producer of the semantic corpus: active AND archived nodes + their open loose ends +
/// their enriched events, each tagged with its owning node's state (the query layer scopes on it).
/// `muted` is never indexed. The seam future producers (transcript chunks, etc.) extend.
public enum EmbeddableCorpus {
  /// Degenerate LLM output ("[]", "/", stray punctuation) is not searchable content — it embeds to
  /// noise and renders as an empty-looking "Related" row. Applies ONLY to model-generated text;
  /// human-authored text (a git commit subject) is legitimately short. Kept as a second line of
  /// defense: `SessionSummarizer` now refuses to store such output in the first place, but the
  /// store already holds historical rows written before that guard existed.
  static func isSearchable(_ text: String) -> Bool { TextQuality.isProse(text) }

  public static func gather(_ database: any DatabaseReader) throws -> [EmbeddableItem] {
    try database.read { database in
      var out: [EmbeddableItem] = []
      // Active AND archived: archiving hides work from the normal views, it does not make the work
      // unrecallable. `muted` stays out of the corpus entirely. Each item carries its owning node's
      // real state, which is what lets the query layer scope results per search scope.
      let nodes = try Node.all.fetchAll(database)
        .filter { $0.state == .active || $0.state == .archived }
      let stateByNodeID = Dictionary(nodes.map { ($0.id, $0.state.rawValue) },
                                     uniquingKeysWith: { firstState, _ in firstState })
      for node in nodes {
        out.append(.init(itemID: node.id.uuidString, kind: "node", nodeID: node.id.uuidString,
                         state: node.state.rawValue, text: [node.name, node.description].filter { !$0.isEmpty }.joined(separator: " — ")))
      }
      let ends = try LooseEnd.where { LooseEnd.isOpen($0) }.fetchAll(database)
      for looseEnd in ends {
        guard let state = stateByNodeID[looseEnd.nodeID] else { continue }
        out.append(.init(itemID: looseEnd.id.uuidString, kind: "loose_end", nodeID: looseEnd.nodeID.uuidString,
                         state: state, text: [looseEnd.text, looseEnd.quote].filter { !$0.isEmpty }.joined(separator: " — ")))
      }
      let events = try Event.all.fetchAll(database)
      for event in events {
        guard let state = stateByNodeID[event.nodeID] else { continue }
        let text: String?
        switch event.kind {
        // LLM-enriched prose — gate it: degenerate model output ("[]", a bare "/") is not content.
        case CaptureKind.ccSession: text = event.workSummary.flatMap { isSearchable($0) ? $0 : nil }
        // Human-authored (a git commit subject). NOT gated — "wip" and "fix ci" are real, short work.
        default: text = event.summary.isEmpty ? nil : event.summary
        }
        if let text {
          out.append(.init(itemID: event.id.uuidString, kind: "event", nodeID: event.nodeID.uuidString,
                           state: state, text: text))
        }
      }
      return out
    }
  }
}
