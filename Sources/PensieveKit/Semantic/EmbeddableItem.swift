import Foundation
import SQLiteData

public struct EmbeddableItem: Sendable {
  public let itemID: String, kind: String, nodeID: String, state: String, text: String
  /// Newline-joined changed-file paths. Events only; "" everywhere else. Indexed into the FTS5
  /// search index's SEPARATE `document_files` table, never beside the text — the SEMANTIC path
  /// ignores this field entirely, because file paths must not enter embedded text.
  public let files: String
  public init(itemID: String, kind: String, nodeID: String, state: String, text: String,
              files: String = "") {
    self.itemID = itemID; self.kind = kind; self.nodeID = nodeID
    self.state = state; self.text = text; self.files = files
  }
  /// Stable across processes/runs (String.hashValue is per-process salted — do NOT use it here).
  /// Hashes `text` ONLY: `files` is deliberately excluded so adding path indexing does not
  /// invalidate every embedding. The search index tracks paths through its own corpus hash.
  public var contentHash: String {
    var hash = StableHash()
    hash.absorb(text)
    return hash.hexValue
  }
}

/// v1 producer of the semantic corpus: active AND archived nodes + their open loose ends +
/// their enriched events, each tagged with its owning node's state (the query layer scopes on it).
/// `muted` is never indexed. The seam future producers (transcript chunks, etc.) extend.
/// Event hygiene (spec P1): `git.checkout` events are dropped (no work content), and identical
/// event texts within a node are de-duplicated, keeping the earliest by (occurredAt, id).
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
      // Hygiene (spec P1). Two rules, both bounded to events:
      //  1. `git.checkout` carries no work content — 261 of 1,686 rows were bare "checkout <branch>",
      //     84 of them literally "checkout HEAD". They only ever occupied top-k slots.
      //  2. De-duplicate identical texts WITHIN a node, keeping the earliest by (occurredAt, id).
      //     Deliberately not global: collapsing "fix ci" across three projects would silently pick
      //     which project owns the only findable copy — a grounding call, not hygiene. Ordering is
      //     explicit because `Event.all` has none, so "the first occurrence" would otherwise be
      //     whatever SQLite happened to return, and could differ between rebuilds.
      let events = try Event.order { ($0.occurredAt, $0.id) }.fetchAll(database)
      var seenTextsByNode: [UUID: Set<String>] = [:]
      for event in events where event.kind != CaptureKind.gitCheckout {
        guard let state = stateByNodeID[event.nodeID] else { continue }
        let text: String?
        switch event.kind {
        // LLM-enriched prose — gate it: degenerate model output ("[]", a bare "/") is not content.
        case CaptureKind.ccSession: text = event.workSummary.flatMap { isSearchable($0) ? $0 : nil }
        // Human-authored (a git commit subject). NOT gated — "wip" and "fix ci" are real, short work.
        default: text = event.summary.isEmpty ? nil : event.summary
        }
        guard let text else { continue }
        guard seenTextsByNode[event.nodeID, default: []].insert(text).inserted else { continue }
        out.append(.init(itemID: event.id.uuidString, kind: "event", nodeID: event.nodeID.uuidString,
                         state: state, text: text, files: Self.changedFiles(in: event.detailJSON)))
      }
      return out
    }
  }

  /// The ingester writes {"hash","branch","files"} for a commit, with `files` newline-joined.
  /// Anything else (a session's detail, malformed JSON, an absent key) yields "".
  static func changedFiles(in detailJSON: String) -> String {
    let detail = (try? JSONDecoder().decode([String: String].self,
                                            from: Data(detailJSON.utf8))) ?? [:]
    return detail["files"] ?? ""
  }
}
