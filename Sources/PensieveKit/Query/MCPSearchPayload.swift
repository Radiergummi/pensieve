import Foundation

/// The MCP `search` tool's response shape. One ranked `items` array (the two-array exact/related
/// shape retired with the substring matcher), plus the index state so an unbuilt index is
/// distinguishable from a genuine miss.
///
/// Lived in the CLI target until the 2026-08-24 sweep, where `PensieveKitTests` could not reach it —
/// so the passage budget and the item mapping below had no test at all.
struct MCPSearchPayload: Encodable {
  var items: [MCPSearchItem]
  var indexState: SearchIndexState

  private enum CodingKeys: String, CodingKey {
    case items
    case indexState = "index_state"
  }
}

struct MCPSearchItem: Encodable {
  var id: String
  var kind: String
  var nodeID: String
  var nodeName: String
  var title: String
  var snippet: String
  /// BM25 relevance. NOT reliably comparable between items: hits found by file path come from a
  /// different FTS5 table with a different average document length than text hits, and can score
  /// higher while being less relevant. Array order is the contract — re-sorting by `score` would
  /// reconstruct exactly the ranking the verification gate rejected on measured evidence.
  var score: Double?
  var archived: Bool
  /// The loose end is done or dropped. Always false for node and event items. A widened scope whose
  /// items cannot say WHICH rows the widening admitted is a half-finished change.
  var closed: Bool

  init(hit: SearchHit) {
    id = hit.id.uuidString
    kind = hit.kind.rawValue   // the wire format is the raw string, unchanged by the typed boundary
    nodeID = hit.nodeID.uuidString
    nodeName = hit.nodeName
    title = hit.title
    snippet = hit.snippet.joined
    score = hit.score
    archived = hit.isArchived
    closed = hit.status.isClosed
  }

  /// A passage item. `kind` is `"passage"` and `id` is the passage UUID, which `recall`'s
  /// `passage_id` accepts — so a model that finds a conversation can read it back in one more call.
  init(passage: PassageHit) {
    id = passage.id.uuidString
    kind = "passage"
    nodeID = passage.nodeID.uuidString
    nodeName = passage.nodeName
    title = passage.role.recallTitle
    snippet = passage.snippet.joined
    score = passage.score
    archived = passage.isArchived
    closed = false   // a passage has no lifecycle of its own
  }

  private enum CodingKeys: String, CodingKey {
    case id, kind, title, snippet, score, archived, closed
    case nodeID = "node_id"
    case nodeName = "node_name"
  }
}
