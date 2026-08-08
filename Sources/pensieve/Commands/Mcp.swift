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

    await server.withMethodHandler(ListTools.self) { _ in .init(tools: Self.toolList) }

    await server.withMethodHandler(CallTool.self) { params in
      try await Self.handleCallTool(params: params, server: server)
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
    await server.withMethodHandler(ReadResource.self) { params in try await Self.handleReadResource(params: params) }

    try await server.start(transport: StdioTransport())
    await server.waitUntilCompleted()
  }

  private static var toolList: [Tool] {
    [
      Tool(name: "project_context",
           description: "Reload where a project stands: facts, cited open loose ends, recent activity, prose recap. "
             + "Defaults to the current workspace.",
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
           description: "Recall the surrounding transcript conversation around a loose end — reconstruct how a discussion went "
             + "and how it resolved. Pass a loose_end_id from project_context.",
           inputSchema: .object(["type": .string("object"), "properties": .object([
             "loose_end_id": .object(["type": .string("string"), "description": .string("UUID of a loose end from project_context")]),
             "radius": .object(["type": .string("number"), "description": .string("messages of context each side (default 8)")]),
           ]), "required": .array([.string("loose_end_id")])]),
           annotations: .init(readOnlyHint: true, openWorldHint: false)),
      Tool(name: "search",
           description: "Find across all your work — by keyword, by phrase, or by the files a commit touched. "
             + "Every result is a real, cited item.",
           inputSchema: .object(["type": .string("object"), "properties": .object([
             "query": .object(["type": .string("string"), "description": .string("what to find")]),
             "file": .object(["type": .string("string"),
                              "description": .string("restrict to work that touched this file path (or any part of one)")]),
             "limit": .object(["type": .string("number"), "description": .string("max results (default 8)")]),
             "include_archived": .object(["type": .string("boolean"),
                                          "description": .string("also search archived projects (default false)")]),
           ]), "required": .array([.string("query")])]),
           annotations: .init(readOnlyHint: true, openWorldHint: false)),
    ]
  }

  private static func handleCallTool(params: CallTool.Parameters, server: Server) async throws -> CallTool.Result {
    switch params.name {
    case "project_context":
      return try await handleProjectContext(params: params, server: server)
    case "whats_next":
      return try handleWhatsNext(params: params)
    case "recall":
      return try handleRecall(params: params)
    case "search":
      return try await handleSearch(params: params)
    default:
      return .init(content: [.text(text: "unknown tool", annotations: nil, _meta: nil)], isError: true)
    }
  }

  private static func handleProjectContext(params: CallTool.Parameters, server: Server) async throws -> CallTool.Result {
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
  }

  private static func handleWhatsNext(params: CallTool.Parameters) throws -> CallTool.Result {
    let limit = params.arguments?["limit"]?.intValue ?? 5
    let context = params.arguments?["context"]?.stringValue
    let json = try PensieveMCP.whatsNextJSON(limit: limit, context: context)
    return PensieveMCP.result(json)
  }

  private static func handleRecall(params: CallTool.Parameters) throws -> CallTool.Result {
    guard let idStr = params.arguments?["loose_end_id"]?.stringValue,
          let id = UUID(uuidString: idStr) else {
      return .init(content: [.text(text: "recall requires a valid loose_end_id (UUID)", annotations: nil, _meta: nil)], isError: true)
    }
    let radius = params.arguments?["radius"]?.intValue ?? 8
    let json = try PensieveMCP.recallJSON(looseEndID: id, radius: radius)
    return PensieveMCP.result(json)
  }

  private static func handleSearch(params: CallTool.Parameters) async throws -> CallTool.Result {
    guard let query = params.arguments?["query"]?.stringValue, !query.isEmpty else {
      return .init(content: [.text(text: "search requires a non-empty query", annotations: nil, _meta: nil)], isError: true)
    }
    let file = params.arguments?["file"]?.stringValue
    let limit = params.arguments?["limit"]?.intValue ?? 8
    let includeArchived = params.arguments?["include_archived"]?.boolValue ?? false
    let json = try await PensieveMCP.searchJSON(query: query, file: file, limit: limit,
                                                includeArchived: includeArchived)
    return PensieveMCP.result(json)
  }

  private static func handleReadResource(params: ReadResource.Parameters) async throws -> ReadResource.Result {
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
  private static let searchStore = SearchIndexStore(url: PensievePaths.searchIndexURL())

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
      narration: NarrationOptions(summaryBuilder: builder, providerKind: kind, cache: cache))
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

  /// Unified "find across my work": BM25 over the on-device FTS5 index, plus — only when the
  /// experimental vector toggle is on — semantically related items below it, excluding anything
  /// BM25 already returned. Scope is all active nodes (MCP has no Focus context), widened by
  /// `include_archived`. `index_state` distinguishes "nothing matched" from "the index isn't built",
  /// which since BM25 became the only retrieval path would otherwise read identically. Cloud is
  /// never used here; the embedder + both indexes are on-device only.
  static func searchJSON(query: String, file: String?, limit: Int,
                         includeArchived: Bool = false) async throws -> Data {
    guard let database = try? openCanonicalReadOnly() else {
      return try makeEncoder().encode(SearchPayload(items: [], indexState: .absent))
    }
    // The visible set must widen with the flag: it gates BOTH halves, so leaving it active-only
    // would filter archived hits back out after the query layer allowed them through.
    let visible = try await database.read { database -> Set<UUID> in
      let nodes = try Node.all.fetchAll(database)
      return Set(nodes.filter {
        $0.state == .active || (includeArchived && $0.state == .archived)
      }.map { $0.id })
    }
    let scope = SearchScope(visibleNodeIDs: visible, limit: limit, includeArchived: includeArchived)
    let ranked = SearchQueries.search(query: query, file: file, scope: scope,
                                      store: searchStore, database)

    var items = ranked.map { SearchItem(hit: $0, engine: "bm25") }
    if PensieveDefaults.semanticSearchEnabled() {
      let related = await SemanticQueries.search(
        query: query,
        scope: SemanticSearchScope(visibleNodeIDs: visible, excludingIDs: Set(ranked.map { $0.id }),
                                   limit: limit, floor: 0.25, includeArchived: includeArchived),
        store: semanticStore, embedder: semanticEmbedder, database)
      items += related.map { SearchItem(hit: $0, engine: "vector") }
    }
    return try makeEncoder().encode(
      SearchPayload(items: Array(items.prefix(limit * 2)), indexState: searchStore.state()))
  }

  /// A text tool result carrying the JSON payload + the result-size hint Claude Code honors.
  static func result(_ json: Data) -> CallTool.Result {
    // `json` always comes from `JSONEncoder`, which always emits valid UTF-8, so this fallback
    // is unreachable in practice — it exists only to avoid a force-unwrap of the failable initializer.
    let text = String(data: json, encoding: .utf8) ?? "<invalid utf8>"
    return .init(content: [.text(text: text, annotations: nil, _meta: nil)],
                 _meta: Metadata(additionalFields: [maxResultSizeMeta: .int(500_000)]))
  }
}

/// The `search` tool's response shape. One ranked `items` array (the two-array exact/related shape
/// retired with the substring matcher), plus the index state so an unbuilt index is distinguishable
/// from a genuine miss.
private struct SearchPayload: Encodable {
  var items: [SearchItem]
  var indexState: SearchIndexState
  private enum CodingKeys: String, CodingKey {
    case items
    case indexState = "index_state"
  }
}

private struct SearchItem: Encodable {
  var id: String
  var kind: String
  var nodeID: String
  var nodeName: String
  var title: String
  var snippet: String
  /// Ranking score in the PRODUCING engine's units — a BM25 score and a cosine similarity are
  /// never comparable, which is what `engine` is here to make explicit.
  var score: Double?
  var engine: String
  var archived: Bool

  init(hit: SearchHit, engine: String) {
    id = hit.id.uuidString
    kind = hit.kind
    nodeID = hit.nodeID.uuidString
    nodeName = hit.nodeName
    title = hit.title
    snippet = hit.snippet.leading + hit.snippet.match + hit.snippet.trailing
    score = hit.score
    self.engine = engine
    archived = hit.isArchived
  }

  private enum CodingKeys: String, CodingKey {
    case id, kind, title, snippet, score, engine, archived
    case nodeID = "node_id"
    case nodeName = "node_name"
  }
}
