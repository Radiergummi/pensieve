import Foundation

/// Why an MCP call cannot be answered — a rejected argument, or a canonical store that exists and
/// will not open. One error type so the transport layer has one thing to catch and one string to
/// hand back.
///
/// Every message is written for the MODEL that reads it, which is why `canonicalStoreUnreadable`
/// spells out that this is not an empty store: the whole point of distinguishing the two is that a
/// broken store used to be answered as "you have never used Pensieve".
public enum MCPFailure: Error, CustomStringConvertible, Equatable {
  /// A UUID-shaped argument that will not parse. Rejected rather than dropped — see
  /// `MCPArgument.uuid`.
  case malformedUUID(key: String, value: String)
  /// A `context` filter Pensieve does not know. Rejected rather than applied, because an unknown
  /// context matches only the nodes with NO context and so silently shrinks the queue.
  case unknownContext(String)
  case missingSearchArgument
  case missingRecallArgument
  case canonicalStoreUnreadable(path: String)

  public var description: String {
    switch self {
    case .malformedUUID(let key, let value):
      return "\(key) must be a UUID; got '\(value)'. Pass an id returned by project_context or "
        + "search, or omit the argument."
    case .unknownContext(let value):
      return "context must be '\(NodeContext.work)' or '\(NodeContext.personal)'; got '\(value)'."
    case .missingSearchArgument:
      return "search requires a query or a file"
    case .missingRecallArgument:
      return "recall requires a valid loose_end_id or passage_id (UUID)"
    case .canonicalStoreUnreadable(let path):
      return "the Pensieve store at \(path) exists but will not open — it may be corrupt, locked or "
        + "unreadable. This is NOT an empty store: do not report that no work has been captured."
    }
  }
}

/// Argument decoding shared by the request types below, so each rule is applied identically to
/// every key that needs it.
enum MCPArgument {
  /// A UUID argument — **rejected** rather than dropped when it will not parse.
  ///
  /// Dropping is what `UUID(uuidString:)` behind a `flatMap` did, and for `node_id` that meant a
  /// typo'd id fell through to "resolve the cwd instead" and returned confident, well-formed
  /// context for a *different* project. A rejected argument is a bad request; a silently different
  /// answer is a wrong one.
  static func uuid<Key: CodingKey>(_ container: KeyedDecodingContainer<Key>,
                                   _ key: Key) throws -> UUID? {
    guard let raw = try container.decodeIfPresent(String.self, forKey: key) else { return nil }
    guard let uuid = UUID(uuidString: raw) else {
      throw MCPFailure.malformedUUID(key: key.stringValue, value: raw)
    }
    return uuid
  }

  /// A trimmed string argument, or nil when absent or all whitespace. All-whitespace is not an
  /// argument: `FTSQueryBuilder` trims too, so without this an all-space `file` produced an empty
  /// SUCCESS payload rather than a rejected request.
  static func trimmed<Key: CodingKey>(_ container: KeyedDecodingContainer<Key>,
                                      _ key: Key) throws -> String? {
    let raw = try container.decodeIfPresent(String.self, forKey: key)?
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return (raw?.isEmpty ?? true) ? nil : raw
  }
}

/// `project_context`'s arguments.
///
/// The wire keys live in `CodingKeys` and NOWHERE else — the tool schema the server advertises is
/// built from these same raw values. Before this type each of the ten MCP argument names was spelled
/// twice, in the schema and again in a `params.arguments?["node_id"]` subscript, with nothing linking
/// them; the response types have always done it this way.
public struct MCPProjectContextRequest: Decodable, Sendable {
  public var path: String?
  public var nodeID: UUID?

  public enum CodingKeys: String, CodingKey {
    case path
    case nodeID = "node_id"
  }

  public init(path: String? = nil, nodeID: UUID? = nil) {
    self.path = path
    self.nodeID = nodeID
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    path = try container.decodeIfPresent(String.self, forKey: .path)
    nodeID = try MCPArgument.uuid(container, .nodeID)
  }
}

/// `whats_next`'s arguments.
public struct MCPWhatsNextRequest: Decodable, Sendable {
  public static let defaultLimit = 5

  public var limit: Int
  /// A validated `NodeContext` value, or nil for "no filter".
  public var context: String?

  public enum CodingKeys: String, CodingKey {
    case limit, context
  }

  public init(limit: Int = MCPWhatsNextRequest.defaultLimit, context: String? = nil) {
    self.limit = max(1, limit)
    self.context = context
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    // Clamped here rather than at the transport: this reaches a `prefix(limit)`, which traps on a
    // negative and would take the whole long-lived server down over one malformed argument.
    limit = max(1, try container.decodeIfPresent(Int.self, forKey: .limit) ?? Self.defaultLimit)
    guard let raw = try MCPArgument.trimmed(container, .context) else {
      context = nil
      return
    }
    // Validated against the one switch that enumerates the contexts Pensieve knows. An unrecognized
    // value is not inert: `NodeContextResolver.visibleNodeIDs` matches it against every node's
    // resolved context, so a typo left only the context-less nodes visible and silently shrank the
    // queue instead of failing.
    guard NodeContext.displayKey(raw) != nil else { throw MCPFailure.unknownContext(raw) }
    context = raw
  }
}

/// `recall`'s arguments. At least one of the two ids is required.
public struct MCPRecallRequest: Decodable, Sendable {
  public static let defaultRadius = 8

  public var looseEndID: UUID?
  public var passageID: UUID?
  /// Deliberately NOT clamped here: `TranscriptWindow.slice` clamps a negative radius in Kit, and
  /// re-clamping at every caller is how one of the two copies eventually stops matching.
  public var radius: Int

  public enum CodingKeys: String, CodingKey {
    case radius
    case looseEndID = "loose_end_id"
    case passageID = "passage_id"
  }

  public init(looseEndID: UUID? = nil, passageID: UUID? = nil,
              radius: Int = MCPRecallRequest.defaultRadius) {
    self.looseEndID = looseEndID
    self.passageID = passageID
    self.radius = radius
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    looseEndID = try MCPArgument.uuid(container, .looseEndID)
    passageID = try MCPArgument.uuid(container, .passageID)
    radius = try container.decodeIfPresent(Int.self, forKey: .radius) ?? Self.defaultRadius
    guard looseEndID != nil || passageID != nil else { throw MCPFailure.missingRecallArgument }
  }
}

/// `search`'s arguments. Either half of (`query`, `file`) alone is a real query — a bare `file`
/// means "everything that touched this path".
public struct MCPSearchRequest: Decodable, Sendable {
  public static let defaultLimit = 8

  public var query: String
  public var file: String?
  public var limit: Int
  public var includeArchived: Bool

  public enum CodingKeys: String, CodingKey {
    case query, file, limit
    case includeArchived = "include_archived"
  }

  public init(query: String = "", file: String? = nil,
              limit: Int = MCPSearchRequest.defaultLimit, includeArchived: Bool = false) {
    self.query = query
    self.file = file
    self.limit = max(1, limit)
    self.includeArchived = includeArchived
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    query = try MCPArgument.trimmed(container, .query) ?? ""
    file = try MCPArgument.trimmed(container, .file)
    // Clamped for `whats_next`'s reason: `prefix` traps on a negative length.
    limit = max(1, try container.decodeIfPresent(Int.self, forKey: .limit) ?? Self.defaultLimit)
    includeArchived = try container.decodeIfPresent(Bool.self, forKey: .includeArchived) ?? false
    guard !query.isEmpty || file != nil else { throw MCPFailure.missingSearchArgument }
  }
}
