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
           description: "Recall the surrounding transcript conversation around a loose end or a stored "
             + "passage — reconstruct how a discussion went and how it resolved. Pass a loose_end_id "
             + "from project_context, or a passage_id from search.",
           inputSchema: .object(["type": .string("object"), "properties": .object([
             "loose_end_id": .object(["type": .string("string"), "description": .string("UUID of a loose end from project_context")]),
             "passage_id": .object(["type": .string("string"), "description": .string("UUID of a passage item from search")]),
             "radius": .object(["type": .string("number"), "description": .string("messages of context each side (default 8)")]),
           ])]),
           annotations: .init(readOnlyHint: true, openWorldHint: false)),
      Tool(name: "search",
           description: "Find across all your work — by keyword, by phrase, or by the files a commit touched. "
             + "Every result is a real, cited item. `items` is ranked results FIRST, ALREADY in "
             + "relevance order — read it top-down and do not re-sort or threshold it by `score`, "
             + "which is not comparable between items — followed by stored conversation passages "
             + "APPENDED as their own list, because their scores come from a different table and are "
             + "not comparable to the ranked ones either. Pass a passage item's id to `recall` to read "
             + "the surrounding discussion. `index_state` distinguishes an unbuilt index from a "
             + "genuine miss.",
           inputSchema: .object(["type": .string("object"), "properties": .object([
             "query": .object(["type": .string("string"),
                               "description": .string("what to find; may be empty when `file` is given")]),
             "file": .object(["type": .string("string"),
                              "description": .string("NARROWS to work that touched this file path (or any part of "
                                + "one) — combined with `query` it means both must match. To find everything that "
                                + "touched a file, pass the filename as `query` on its own.")]),
             "limit": .object(["type": .string("number"), "minimum": .int(1),
                               "description": .string("max ranked results (default 8); conversation passages are "
                                 + "appended as a separate list of up to half that many")]),
             "include_archived": .object(["type": .string("boolean"),
                                          "description": .string("also search archived projects and closed loose ends (default false)")]),
           ]), "required": .array([])]),
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
    // Clamped for the same reason as `search`: this reaches a `prefix(limit)`, which traps on a
    // negative and would take the whole server down over one malformed argument.
    let limit = max(1, params.arguments?["limit"]?.intValue ?? 5)
    let context = params.arguments?["context"]?.stringValue
    let json = try PensieveMCP.whatsNextJSON(limit: limit, context: context)
    return PensieveMCP.result(json)
  }

  private static func handleRecall(params: CallTool.Parameters) throws -> CallTool.Result {
    let radius = params.arguments?["radius"]?.intValue ?? 8
    if let raw = params.arguments?["loose_end_id"]?.stringValue, let id = UUID(uuidString: raw) {
      return PensieveMCP.result(try PensieveMCP.recallJSON(looseEndID: id, radius: radius))
    }
    if let raw = params.arguments?["passage_id"]?.stringValue, let id = UUID(uuidString: raw) {
      return PensieveMCP.result(try PensieveMCP.recallJSON(passageID: id, radius: radius))
    }
    return .init(content: [.text(text: "recall requires a valid loose_end_id or passage_id (UUID)",
                                 annotations: nil, _meta: nil)], isError: true)
  }

  private static func handleSearch(params: CallTool.Parameters) async throws -> CallTool.Result {
    let query = params.arguments?["query"]?.stringValue ?? ""
    let file = params.arguments?["file"]?.stringValue
    // Either half alone is a real query — a bare `file` means "everything that touched this path",
    // which previously needed a dummy `query` to reach the path-only shape. Trimmed to match
    // `FTSQueryBuilder`, which trims too: an all-whitespace `file` is not an argument, and without
    // this it would produce an empty SUCCESS payload rather than the error below.
    let trimmedFile = (file ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !trimmedFile.isEmpty else {
      return .init(content: [.text(text: "search requires a query or a file", annotations: nil, _meta: nil)],
                   isError: true)
    }
    // Clamped, not trusted: `prefix` traps on a negative length, which would take the whole server
    // down mid-session over one malformed argument.
    let limit = max(1, params.arguments?["limit"]?.intValue ?? 8)
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

  // Built once for the server's lifetime (the MCP process is long-lived): the index pool open is
  // otherwise repeated on every `search` call. Sendable. The server is session-scoped and the
  // app/daemon own rebuilds.
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

  static func recallJSON(passageID: UUID, radius: Int) throws -> Data {
    guard let database = try? openCanonicalReadOnly() else {
      return try makeEncoder().encode(Optional<RecallBundle>.none)
    }
    let bundle = try SessionContextQueries.recall(passageID: passageID, radius: radius, database)
    return try makeEncoder().encode(bundle)
  }

  /// Unified "find across my work": BM25 over the on-device FTS5 index, the only retrieval path.
  /// Scope is all active nodes (MCP has no Focus context), widened by `include_archived`.
  /// `index_state` distinguishes "nothing matched" from "the index isn't built", which would
  /// otherwise read identically. Cloud is never used here; the index is on-device only.
  static func searchJSON(query: String, file: String?, limit: Int,
                         includeArchived: Bool = false) async throws -> Data {
    guard let database = try? openCanonicalReadOnly() else {
      return try makeEncoder().encode(SearchPayload(items: [], indexState: .absent))
    }
    // The visible set must widen with the flag: it gates BOTH halves, so leaving it active-only
    // would filter archived hits back out after the query layer allowed them through.
    let visible = try await database.read { database -> Set<UUID> in
      let nodes = try Node.all.fetchAll(database)
      return Set(nodes.filter { $0.state.isSearchable(includeArchived: includeArchived) }
                      .map { $0.id })
    }
    // One control, two dimensions: `include_archived` widens BOTH node state and loose-end status,
    // matching the app's single scope bar. The kernel keeps them separate; conflating them is the
    // caller's choice, and this is the caller.
    let scope = SearchScope(visibleNodeIDs: visible, limit: limit,
                            includeArchived: includeArchived, includeClosed: includeArchived)
    let ranked = SearchQueries.search(query: query, file: file, scope: scope,
                                      store: searchStore, database)

    // `limit` is honoured by SearchQueries itself; there is no second engine to make room for, so
    // the payload no longer over-allocates and then truncates.
    let items = ranked.map { SearchItem(hit: $0) }
    // Appended, never interleaved: passage scores come from a different FTS5 table with a different
    // average document length, exactly like path hits. The array order is the contract the tool
    // description states, and this preserves it.
    //
    // Passages get their own, smaller budget rather than sharing `limit`. Two lists in one array
    // cannot both mean "at most `limit`" — and capping the concatenation instead would delete the
    // passage list entirely whenever the ranked list is already full, which is the common case.
    // Half, floored at two, keeps the conversation list present without letting it dominate the
    // page. Derived from `scope` (not the raw parameters) so the two cannot drift apart.
    let passageScope = SearchScope(visibleNodeIDs: scope.visibleNodeIDs, limit: max(2, limit / 2),
                                   includeArchived: scope.includeArchived,
                                   includeClosed: scope.includeClosed)
    let passages = PassageQueries.search(query: query, scope: passageScope, store: searchStore,
                                         database)
    return try makeEncoder().encode(
      SearchPayload(items: items + passages.map { SearchItem(passage: $0) },
                    indexState: searchStore.state()))
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
    snippet = hit.snippet.leading + hit.snippet.match + hit.snippet.trailing
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
    title = passage.role == .prompt ? "You asked" : "Claude answered"
    snippet = passage.snippet.leading + passage.snippet.match + passage.snippet.trailing
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
