import ArgumentParser
import Foundation
import MCP
import PensieveKit
import SQLiteData   // for `any DatabaseReader` (the shared read handle passed to resolveBundle)

struct Mcp: AsyncParsableCommand {
  static let configuration = CommandConfiguration(commandName: "mcp",
    abstract: "Long-lived stdio MCP server exposing grounded Pensieve context (read-only).")

  func run() async throws {
    let server = Server(
      name: "pensieve", version: "0.1.0",
      capabilities: .init(resources: .init(), tools: .init(listChanged: false)))

    await server.withMethodHandler(ListTools.self) { _ in
      .init(tools: [
        Tool(name: "project_context",
             description: "Reload where a project stands: facts, cited open loose ends, recent activity, prose recap. Defaults to the current workspace.",
             inputSchema: .object(["type": .string("object"), "properties": .object([
               "path": .object(["type": .string("string"), "description": .string("directory to resolve; defaults to the workspace")]),
               "node_id": .object(["type": .string("string"), "description": .string("resolve a specific node by UUID")]),
             ])]),
             annotations: .init(readOnlyHint: true, openWorldHint: false)),
        Tool(name: "whats_next",
             description: "Ranked queue of what to pick up across all projects, on grounded signals (open loose ends, dormancy).",
             inputSchema: .object(["type": .string("object"), "properties": .object([
               "limit": .object(["type": .string("number"), "description": .string("max rows (default 5)")]),
               "context": .object(["type": .string("string"), "description": .string("filter: work | personal")]),
             ])]),
             annotations: .init(readOnlyHint: true, openWorldHint: false)),
        Tool(name: "recall",
             description: "Recall the surrounding transcript conversation around a loose end — reconstruct how a discussion went and how it resolved. Pass a loose_end_id from project_context.",
             inputSchema: .object(["type": .string("object"), "properties": .object([
               "loose_end_id": .object(["type": .string("string"), "description": .string("UUID of a loose end from project_context")]),
               "radius": .object(["type": .string("number"), "description": .string("messages of context each side (default 8)")]),
             ]), "required": .array([.string("loose_end_id")])]),
             annotations: .init(readOnlyHint: true, openWorldHint: false)),
        Tool(name: "search",
             description: "Find across all your work by keyword AND meaning — exact first, related below; each result is a real, cited item.",
             inputSchema: .object(["type": .string("object"), "properties": .object([
               "query": .object(["type": .string("string"), "description": .string("what to find")]),
               "limit": .object(["type": .string("number"), "description": .string("max results per group (default 8)")]),
               "include_archived": .object(["type": .string("boolean"), "description": .string("also search archived projects (default false)")]),
             ]), "required": .array([.string("query")])]),
             annotations: .init(readOnlyHint: true, openWorldHint: false)),
      ])
    }

    await server.withMethodHandler(CallTool.self) { params in
      switch params.name {
      case "project_context":
        var path = params.arguments?["path"]?.stringValue
        let nodeID = (params.arguments?["node_id"]?.stringValue).flatMap { UUID(uuidString: $0) }
        if path == nil, nodeID == nil {
          // Zero-arg "reload wherever I am": ask the client for its workspace roots.
          if let roots = try? await server.listRoots(), let first = roots.first {
            path = URL(string: first.uri)?.path   // file:// → filesystem path
          }
        }
        let json = try await PensieveMCP.projectContextJSON(path: path, nodeID: nodeID)
        return PensieveMCP.result(json)
      case "whats_next":
        let limit = params.arguments?["limit"]?.intValue ?? 5
        let context = params.arguments?["context"]?.stringValue
        let json = try PensieveMCP.whatsNextJSON(limit: limit, context: context)
        return PensieveMCP.result(json)
      case "recall":
        guard let idStr = params.arguments?["loose_end_id"]?.stringValue,
              let id = UUID(uuidString: idStr) else {
          return .init(content: [.text(text: "recall requires a valid loose_end_id (UUID)", annotations: nil, _meta: nil)], isError: true)
        }
        let radius = params.arguments?["radius"]?.intValue ?? 8
        let json = try PensieveMCP.recallJSON(looseEndID: id, radius: radius)
        return PensieveMCP.result(json)
      case "search":
        guard let query = params.arguments?["query"]?.stringValue, !query.isEmpty else {
          return .init(content: [.text(text: "search requires a non-empty query", annotations: nil, _meta: nil)], isError: true)
        }
        let limit = params.arguments?["limit"]?.intValue ?? 8
        let includeArchived = params.arguments?["include_archived"]?.boolValue ?? false
        let json = try await PensieveMCP.searchJSON(query: query, limit: limit,
                                                    includeArchived: includeArchived)
        return PensieveMCP.result(json)
      default:
        return .init(content: [.text(text: "unknown tool", annotations: nil, _meta: nil)], isError: true)
      }
    }

    await server.withMethodHandler(ListResources.self) { _ in
      .init(resources: [
        Resource(name: "What's Next", uri: "pensieve://smartlist/whats-next",
                 description: "Ranked queue across all projects", mimeType: "text/markdown"),
      ])
    }
    await server.withMethodHandler(ListResourceTemplates.self) { _ in
      .init(templates: [
        Resource.Template(uriTemplate: "pensieve://node/{id}", name: "Project context",
                          description: "One project's grounded context", mimeType: "text/markdown"),
      ])
    }
    await server.withMethodHandler(ReadResource.self) { params in
      let uri = params.uri
      if uri == "pensieve://smartlist/whats-next" {
        let markdown = try PensieveMCP.whatsNextMarkdown()
        return .init(contents: [.text(markdown, uri: uri, mimeType: "text/markdown")])
      }
      if uri.hasPrefix("pensieve://node/"),
         let id = UUID(uuidString: String(uri.dropFirst("pensieve://node/".count))),
         let markdown = try await PensieveMCP.nodeMarkdown(id: id) {
        return .init(contents: [.text(markdown, uri: uri, mimeType: "text/markdown")])
      }
      throw MCPError.invalidParams("unknown resource: \(uri)")
    }

    try await server.start(transport: StdioTransport())
    await server.waitUntilCompleted()
  }
}

/// Bridges the tested Kit kernel to MCP results. Opens the store read-only per call so the server
/// binds lazily once the canonical store exists (a single pool's per-read transactions would already
/// see the latest committed drain). The prose builder is on-device by default.
enum PensieveMCP {
  static let maxResultSizeMeta = "anthropic/maxResultSizeChars"

  // Built once for the server's lifetime (the MCP process is long-lived): the NL asset load + the
  // index pool open are otherwise repeated on every `search` call. Both are Sendable. Caveat: a
  // version bump WHILE the server runs won't reopen the cached store — acceptable, the server is
  // session-scoped and the app/daemon own rebuilds.
  private static let semanticEmbedder = NLContextualEmbedder()
  private static let semanticStore = SemanticIndexStore(
    url: PensievePaths.semanticIndexURL(),
    dimension: semanticEmbedder.dimension, embedderVersion: semanticEmbedder.version)

  private static func makeBuilderAndKind() -> (SummaryBuilder, String) {
    let defaults = PensieveDefaults.shared()
    let provider = makeDefaultLLMProvider(defaults: defaults)
    let kind = resolvedProviderKind(defaults: defaults, cloudConfig: nil, apiKey: nil)
    return (SummaryBuilder(provider: provider), kind)
  }

  private static func makeEncoder() -> JSONEncoder {
    let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
    return encoder
  }

  /// Resolve one node's grounded bundle against an already-open read handle (on-device narration,
  /// write-through cache). Shared by the `project_context` tool and the `pensieve://node/{id}` resource.
  private static func resolveBundle(path: String?, nodeID: UUID?,
                                    _ database: any DatabaseReader) async throws -> ProjectContextBundle? {
    let (builder, kind) = makeBuilderAndKind()
    let cache = NarrationCache(url: PensievePaths.narrationCacheURL())
    return try await SessionContextQueries.bundle(
      forPath: path, nodeID: nodeID, database, now: Date(),
      summaryBuilder: builder, providerKind: kind, cache: cache)
  }

  static func projectContextJSON(path: String?, nodeID: UUID?) async throws -> Data {
    guard let database = try? openCanonicalReadOnly() else {
      return try makeEncoder().encode(Optional<ProjectContextBundle>.none)   // "null"
    }
    let effectivePath = path ?? FileManager.default.currentDirectoryPath
    let bundle = try await resolveBundle(path: effectivePath, nodeID: nodeID, database)
    return try makeEncoder().encode(bundle)   // encodes `null` for an unbound path
  }

  static func nodeMarkdown(id: UUID) async throws -> String? {
    guard let database = try? openCanonicalReadOnly() else { return nil }
    guard let bundle = try await resolveBundle(path: nil, nodeID: id, database) else { return nil }
    return SessionContextRender.markdown(bundle)
  }

  static func whatsNextMarkdown() throws -> String {
    guard let database = try? openCanonicalReadOnly() else { return SessionContextRender.whatsNext([]) }
    let items = try SessionContextQueries.rankedContext(limit: 10, context: nil, database, now: Date())
    return SessionContextRender.whatsNext(items)
  }

  static func whatsNextJSON(limit: Int, context: String?) throws -> Data {
    guard let database = try? openCanonicalReadOnly() else {
      return try makeEncoder().encode([WhatsNextItem]())   // "[]"
    }
    let items = try SessionContextQueries.rankedContext(limit: limit, context: context, database, now: Date())
    return try makeEncoder().encode(items)
  }

  static func recallJSON(looseEndID: UUID, radius: Int) throws -> Data {
    guard let database = try? openCanonicalReadOnly() else {
      return try makeEncoder().encode(Optional<RecallBundle>.none)   // "null"
    }
    let bundle = try SessionContextQueries.recall(looseEndID: looseEndID, radius: radius, database)
    return try makeEncoder().encode(bundle)   // encodes `null` for an unknown id
  }

  /// Unified "find across my work" tool: exact substring match (`SearchQueries`) plus, when the
  /// semantic-search toggle is on, semantically related items (`SemanticQueries`) over the on-device
  /// index — excluding anything already surfaced as an exact hit. Scope is all active nodes (MCP has
  /// no Focus context), widened to archived by `include_archived`, which gates the exact and semantic
  /// halves alike. Cloud is never used here; the embedder + index are on-device only.
  static func searchJSON(query: String, limit: Int, includeArchived: Bool = false) async throws -> Data {
    guard let database = try? openCanonicalReadOnly() else {
      return try makeEncoder().encode(SearchPayload(exact: [], related: []))
    }
    // The visible set must widen with the flag: it gates BOTH halves, so leaving it active-only
    // would filter archived hits back out after the query layer allowed them through.
    let visible = try await database.read { database -> Set<UUID> in
      let nodes = try Node.all.fetchAll(database)
      return Set(nodes.filter {
        $0.state == .active || (includeArchived && $0.state == .archived)
      }.map { $0.id })
    }
    let exact = try SearchQueries.search(query: query, visibleNodeIDs: visible,
                                         includeArchived: includeArchived, database)
    let exactIDs = Set(exact.nodes.map { $0.id } + exact.looseEnds.map { $0.id })

    let related: [SemanticHit]
    if PensieveDefaults.semanticSearchEnabled() {
      related = await SemanticQueries.search(query: query, visibleNodeIDs: visible, excludingIDs: exactIDs,
                                             limit: limit, floor: 0.25, includeArchived: includeArchived,
                                             store: semanticStore, embedder: semanticEmbedder, database)
    } else {
      related = []
    }

    let exactItems = exact.nodes.map(SearchItem.init(node:)) + exact.looseEnds.map(SearchItem.init(looseEnd:))
    let relatedItems = related.map(SearchItem.init(semantic:))
    let payload = SearchPayload(exact: Array(exactItems.prefix(limit)), related: Array(relatedItems.prefix(limit)))
    return try makeEncoder().encode(payload)
  }

  /// A text tool result carrying the JSON payload + the result-size hint Claude Code honors.
  static func result(_ json: Data) -> CallTool.Result {
    let text = String(decoding: json, as: UTF8.self)
    return .init(content: [.text(text: text, annotations: nil, _meta: nil)],
                 _meta: Metadata(additionalFields: [maxResultSizeMeta: .int(500_000)]))
  }
}

/// The `search` tool's response shape: `{ "exact": [...], "related": [...] }`. `similarity` is
/// present only on related (semantic) items — `encode(to:)` omits it (not `null`) for exact items,
/// since exact matches have no similarity score.
private struct SearchPayload: Encodable {
  var exact: [SearchItem]
  var related: [SearchItem]
}

private struct SearchItem: Encodable {
  var id: String
  var kind: String
  var node_id: String
  var node_name: String
  var title: String
  var snippet: String
  var similarity: Double?
  var archived: Bool

  init(node hit: NodeHit) {
    id = hit.id.uuidString
    kind = "node"
    node_id = hit.id.uuidString
    node_name = hit.name
    title = hit.name
    snippet = Self.text(hit.snippet)
    similarity = nil
    archived = hit.isArchived
  }

  init(looseEnd hit: LooseEndHit) {
    id = hit.id.uuidString
    kind = "loose_end"
    node_id = hit.nodeID.uuidString
    node_name = hit.nodeName
    let snippetText = Self.text(hit.snippet)
    title = snippetText
    snippet = snippetText
    similarity = nil
    archived = hit.isArchived
  }

  init(semantic hit: SemanticHit) {
    id = hit.id.uuidString
    kind = hit.kind
    node_id = hit.nodeID.uuidString
    node_name = hit.nodeName
    title = hit.title
    snippet = Self.text(hit.snippet)
    similarity = hit.similarity
    archived = hit.isArchived
  }

  private static func text(_ s: Snippet) -> String { s.leading + s.match + s.trailing }

  private enum CodingKeys: String, CodingKey {
    case id, kind, node_id, node_name, title, snippet, similarity, archived
  }

  func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(id, forKey: .id)
    try c.encode(kind, forKey: .kind)
    try c.encode(node_id, forKey: .node_id)
    try c.encode(node_name, forKey: .node_name)
    try c.encode(title, forKey: .title)
    try c.encode(snippet, forKey: .snippet)
    try c.encodeIfPresent(similarity, forKey: .similarity)
    try c.encode(archived, forKey: .archived)
  }
}
