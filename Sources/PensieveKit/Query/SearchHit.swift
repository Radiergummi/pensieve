import Foundation

/// Whether the search index can answer at all. Distinct from "no matches" — after BM25 became the
/// single retrieval path, an unbuilt index and a genuinely empty result set would otherwise render
/// identically, and the user would read a broken index as "you never worked on that".
public enum SearchIndexState: String, Sendable, Equatable, Codable {
  case absent     // never built, or the store could not be opened
  case building   // a rebuild is in flight
  case ready
}

/// One search result. Both engines return this: BM25 (the shipped path) and the vector index
/// (default-off, experimental). The name deliberately does not claim an engine — `score` is
/// whatever the producing engine ranks by, and is NEVER comparable across engines.
public struct SearchHit: Identifiable, Sendable, Equatable {
  /// What the hit points at. An enum rather than the raw index string: `kind` is compared against
  /// literals at every call site that renders or routes a hit, and this codebase turned
  /// `NodeKind`/`NodeState` into enums precisely to kill that mistyped-literal hazard. The raw
  /// values are the strings the indexes store, so the boundary is typed without changing any file.
  public enum Kind: String, Sendable, Equatable {
    case node
    case looseEnd = "loose_end"
    case event
  }

  public let id: UUID           // node id / loose-end id / event id
  public let kind: Kind
  public let nodeID: UUID
  public let nodeName: String
  public let title: String      // node name / loose-end text / event summary
  public let snippet: Snippet
  /// Higher is better. BM25 hits carry `-bm25(...)`; a pinned Top Hit carries nil (it did not come
  /// from the ranking, and a comparable-looking number would invite exactly the cross-scale
  /// confusion the spec removes).
  public let score: Double?
  /// The owning node is archived — the view badges the row. Always false unless the caller opted in.
  public let isArchived: Bool

  public init(id: UUID, kind: Kind, nodeID: UUID, nodeName: String, title: String,
              snippet: Snippet, score: Double?, isArchived: Bool) {
    self.id = id; self.kind = kind; self.nodeID = nodeID; self.nodeName = nodeName
    self.title = title; self.snippet = snippet; self.score = score; self.isArchived = isArchived
  }
}
