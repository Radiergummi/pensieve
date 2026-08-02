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

  public static func gather(_ db: any DatabaseReader) throws -> [EmbeddableItem] {
    try db.read { db in
      var out: [EmbeddableItem] = []
      // Active AND archived: archiving hides work from the normal views, it does not make the work
      // unrecallable. `muted` stays out of the corpus entirely. Each item carries its owning node's
      // real state, which is what lets the query layer scope results per search scope.
      let nodes = try Node.all.fetchAll(db)
        .filter { $0.state == .active || $0.state == .archived }
      let stateByNodeID = Dictionary(nodes.map { ($0.id, $0.state.rawValue) },
                                     uniquingKeysWith: { a, _ in a })
      for n in nodes {
        out.append(.init(itemID: n.id.uuidString, kind: "node", nodeID: n.id.uuidString,
                         state: n.state.rawValue, text: [n.name, n.description].filter { !$0.isEmpty }.joined(separator: " — ")))
      }
      let ends = try LooseEnd.where { LooseEnd.isOpen($0) }.fetchAll(db)
      for le in ends {
        guard let state = stateByNodeID[le.nodeID] else { continue }
        out.append(.init(itemID: le.id.uuidString, kind: "loose_end", nodeID: le.nodeID.uuidString,
                         state: state, text: [le.text, le.quote].filter { !$0.isEmpty }.joined(separator: " — ")))
      }
      let events = try Event.all.fetchAll(db)
      for e in events {
        guard let state = stateByNodeID[e.nodeID] else { continue }
        // `git.checkout` carries no work content: on the real store 261 of 1,686 events were bare
        // `checkout <branch>` strings (84 literally `checkout HEAD`, 72 `checkout main`). They
        // occupy top-k slots in every retrieval strategy and were the actual source of the
        // "gibberish matches everything" symptom the semantic defect report opened on.
        guard e.kind != CaptureKind.gitCheckout else { continue }
        let text: String?
        switch e.kind {
        // LLM-enriched prose — gate it: degenerate model output ("[]", a bare "/") is not content.
        case CaptureKind.ccSession: text = e.workSummary.flatMap { isSearchable($0) ? $0 : nil }
        // Human-authored (a git commit subject). NOT gated — "wip" and "fix ci" are real, short work.
        default: text = e.summary.isEmpty ? nil : e.summary
        }
        if let text {
          out.append(.init(itemID: e.id.uuidString, kind: "event", nodeID: e.nodeID.uuidString,
                           state: state, text: text))
        }
      }
      return dedupedByText(out)
    }
  }

  /// Drop any item whose text is identical (after trimming) to one already kept — 400 of 2,630 rows
  /// on the real store were exact duplicates across 111 groups, and a single string could occupy up
  /// to 84 top-k slots. First-wins over `gather`'s order (nodes → loose ends → events), so a node is
  /// never dropped in favour of an event repeating its text; losing a node would make that node
  /// permanently unfindable. Trimmed but NOT case-folded, matching the measurement
  /// (`measurements/2026-07-28-retrieval-recall/rprobe4.swift:104-111`).
  static func dedupedByText(_ items: [EmbeddableItem]) -> [EmbeddableItem] {
    var seen = Set<String>()
    return items.filter {
      seen.insert($0.text.trimmingCharacters(in: .whitespacesAndNewlines)).inserted
    }
  }
}
