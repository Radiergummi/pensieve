import ArgumentParser
import Foundation
import MCP
import PensieveKit

/// Protocol plumbing only: the advertised schemas, argument decoding, and wrapping a Kit-produced
/// JSON payload in a `CallTool.Result`. Every line of derivation lives in `MCPQueries`, where the
/// test suite can reach it.
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
        // Built through `DeepLink`, not spelled out: MCP used to advertise
        // `pensieve://smartlist/whats-next`, which `DeepLink.init?(url:)` — the only parser any
        // surface uses — rejects, so a client handing the published URI back got nothing.
        Resource(name: "What's Next", uri: DeepLink.smartList(.whatsNext).url.absoluteString,
                 description: "Ranked queue across all projects", mimeType: "text/markdown"),
      ])
    }
    await server.withMethodHandler(ListResourceTemplates.self) { _ in
      .init(templates: [
        // `{id}` is a URI-template placeholder, not a URL, so `DeepLink` cannot build this one —
        // it builds concrete links. The scheme still comes from `DeepLink`.
        Resource.Template(uriTemplate: "\(DeepLink.scheme)://node/{id}", name: "Project context",
                          description: "One project's grounded context", mimeType: "text/markdown"),
      ])
    }
    await server.withMethodHandler(ReadResource.self) { params in try await Self.handleReadResource(params: params) }

    try await server.start(transport: StdioTransport())
    await server.waitUntilCompleted()
  }

  // MARK: - Advertised schemas

  // The wire keys come from the request types' `CodingKeys`, so the schema and the handler cannot
  // spell one differently — the failure the response types have always been immune to.
  private typealias ProjectContextKey = MCPProjectContextRequest.CodingKeys
  private typealias WhatsNextKey = MCPWhatsNextRequest.CodingKeys
  private typealias RecallKey = MCPRecallRequest.CodingKeys
  private typealias SearchKey = MCPSearchRequest.CodingKeys

  private static var toolList: [Tool] {
    [
      Tool(name: "project_context",
           description: "Reload where a project stands: facts, cited open loose ends, recent activity, prose recap. "
             + "Defaults to the current workspace.",
           inputSchema: .object(["type": .string("object"), "properties": .object([
             ProjectContextKey.path.rawValue:
               .object(["type": .string("string"), "description": .string("directory to resolve; defaults to the workspace")]),
             ProjectContextKey.nodeID.rawValue:
               .object(["type": .string("string"), "description": .string("resolve a specific node by UUID")]),
           ])]),
           annotations: .init(readOnlyHint: true, openWorldHint: false)),
      Tool(name: "whats_next",
           description: "Ranked queue of what to pick up across all projects, on grounded signals (open loose ends, dormancy).",
           inputSchema: .object(["type": .string("object"), "properties": .object([
             WhatsNextKey.limit.rawValue:
               .object(["type": .string("number"),
                        "description": .string("max rows (default \(MCPWhatsNextRequest.defaultLimit))")]),
             WhatsNextKey.context.rawValue:
               .object(["type": .string("string"),
                        "description": .string("filter: \(NodeContext.work) | \(NodeContext.personal)")]),
           ])]),
           annotations: .init(readOnlyHint: true, openWorldHint: false)),
      Tool(name: "recall",
           description: "Recall the surrounding transcript conversation around a loose end or a stored "
             + "passage — reconstruct how a discussion went and how it resolved. Pass a loose_end_id "
             + "from project_context, or a passage_id from search.",
           inputSchema: .object(["type": .string("object"), "properties": .object([
             RecallKey.looseEndID.rawValue:
               .object(["type": .string("string"), "description": .string("UUID of a loose end from project_context")]),
             RecallKey.passageID.rawValue:
               .object(["type": .string("string"), "description": .string("UUID of a passage item from search")]),
             RecallKey.radius.rawValue:
               .object(["type": .string("number"),
                        "description": .string("messages of context each side (default \(MCPRecallRequest.defaultRadius))")]),
           ])]),
           annotations: .init(readOnlyHint: true, openWorldHint: false)),
      Tool(name: "search", description: Self.searchToolDescription,
           inputSchema: .object(["type": .string("object"), "properties": .object([
             SearchKey.query.rawValue:
               .object(["type": .string("string"),
                        "description": .string("what to find; may be empty when `file` is given")]),
             SearchKey.file.rawValue:
               .object(["type": .string("string"),
                        "description": .string("NARROWS to work that touched this file path (or any part of "
                          + "one) — combined with `query` it means both must match. To find everything that "
                          + "touched a file, pass the filename as `query` on its own.")]),
             SearchKey.limit.rawValue:
               .object(["type": .string("number"), "minimum": .int(1),
                        "description": .string("max ranked results (default \(MCPSearchRequest.defaultLimit)); "
                          + "conversation passages are appended as a separate list of up to half that many")]),
             SearchKey.includeArchived.rawValue:
               .object(["type": .string("boolean"),
                        "description": .string("also search archived projects and closed loose ends (default false)")]),
           ]), "required": .array([])]),
           annotations: .init(readOnlyHint: true, openWorldHint: false)),
    ]
  }

  private static let searchToolDescription =
    "Find across all your work — by keyword, by phrase, or by the files a commit touched. "
    + "Every result is a real, cited item. `items` is ranked results FIRST, ALREADY in "
    + "relevance order — read it top-down and do not re-sort or threshold it by `score`, "
    + "which is not comparable between items — followed by stored conversation passages "
    + "APPENDED as their own list, because their scores come from a different table and are "
    + "not comparable to the ranked ones either. Pass a passage item's id to `recall` to read "
    + "the surrounding discussion. `index_state` distinguishes an unbuilt index from a "
    + "genuine miss."

  // MARK: - Tool dispatch

  private static func handleCallTool(params: CallTool.Parameters, server: Server) async throws -> CallTool.Result {
    do {
      switch params.name {
      case "project_context":
        return PensieveMCP.result(try await MCPQueries.projectContextJSON(
          try request(MCPProjectContextRequest.self, params, defaultingPathTo: server),
          narration: cliNarrationOptions(narrating: true)))
      case "whats_next":
        return PensieveMCP.result(try MCPQueries.whatsNextJSON(try request(MCPWhatsNextRequest.self, params)))
      case "recall":
        return PensieveMCP.result(try MCPQueries.recallJSON(try request(MCPRecallRequest.self, params)))
      case "search":
        return PensieveMCP.result(try MCPQueries.searchJSON(try request(MCPSearchRequest.self, params)))
      default:
        return PensieveMCP.errorResult("unknown tool")
      }
    } catch let failure as MCPFailure {
      // A rejected argument or an unreadable store: a message the model can act on, not a transport
      // fault. Everything else propagates and the SDK reports it.
      return PensieveMCP.errorResult(failure.description)
    }
  }

  /// Decodes a call's arguments into its typed request. Goes through JSON because the wire keys live
  /// in the request type's `CodingKeys` and nowhere else — a hand-written subscript per key is the
  /// double-spelling this replaced.
  private static func request<Request: Decodable>(_ type: Request.Type,
                                                  _ params: CallTool.Parameters) throws -> Request {
    let json = try JSONEncoder().encode(params.arguments ?? [:])
    return try JSONDecoder().decode(Request.self, from: json)
  }

  /// `project_context` only: with neither `path` nor `node_id`, ask the client for its workspace
  /// roots — "reload wherever I am".
  private static func request(_ type: MCPProjectContextRequest.Type, _ params: CallTool.Parameters,
                              defaultingPathTo server: Server) async throws -> MCPProjectContextRequest {
    var decoded = try request(MCPProjectContextRequest.self, params)
    guard decoded.path == nil, decoded.nodeID == nil else { return decoded }
    decoded.path = await workspaceRootPath(from: server)
    return decoded
  }

  /// How long the server waits for the CLIENT to answer `roots/list`.
  private static let listRootsTimeout: Duration = .seconds(2)

  /// Asks the client for its workspace root, giving up after `listRootsTimeout`.
  ///
  /// Bounded because this is a request in the *other* direction: a client that declares roots
  /// support and then never answers leaves `project_context` awaiting forever, and this handler is
  /// what a session's first grounded question runs through. Falling back to the cwd — which is what
  /// `MCPQueries` does with a nil path, and which for a stdio server the client spawned is normally
  /// the workspace anyway — is a good answer; hanging is not.
  ///
  /// Deliberately NOT a `withTaskGroup` race, which is the obvious shape and does not work here: a
  /// task group awaits ALL its children before returning, and `Server.listRoots` suspends on a
  /// `withCheckedThrowingContinuation` that cancellation cannot resume — so the group hangs on the
  /// losing child for exactly as long as the unbounded await did. Verified by driving the built
  /// server with a client that advertises roots and never answers. An `AsyncStream` lets the winner
  /// be read and the loser abandoned.
  private static func workspaceRootPath(from server: Server) async -> String? {
    let answers = AsyncStream<String?> { continuation in
      let roots = Task {
        let roots = try? await server.listRoots()
        // file:// → filesystem path
        continuation.yield(roots?.first.flatMap { URL(string: $0.uri)?.path })
      }
      let timeout = Task {
        try? await Task.sleep(for: listRootsTimeout)
        continuation.yield(nil)
      }
      continuation.onTermination = { _ in roots.cancel(); timeout.cancel() }
    }
    var iterator = answers.makeAsyncIterator()
    return await iterator.next() ?? nil
  }

  // MARK: - Resources

  private static func handleReadResource(params: ReadResource.Parameters) async throws -> ReadResource.Result {
    let uri = params.uri
    // Parsed by `DeepLink`, the one `pensieve://` grammar. The hand-rolled `hasPrefix`/`dropFirst`
    // this replaced is how MCP came to publish a URI its own scheme could not parse.
    guard let url = URL(string: uri), let link = DeepLink(url: url) else {
      throw MCPError.invalidParams("unknown resource: \(uri)")
    }
    switch link {
    case .smartList(.whatsNext):
      return .init(contents: [.text(try MCPQueries.whatsNextMarkdown(), uri: uri, mimeType: "text/markdown")])
    case .node(let id):
      guard let markdown = try await MCPQueries.nodeMarkdown(id: id,
                                                             narration: cliNarrationOptions(narrating: true)) else {
        throw MCPError.invalidParams("unknown resource: \(uri)")
      }
      return .init(contents: [.text(markdown, uri: uri, mimeType: "text/markdown")])
    case .briefing, .looseEnd, .smartList:
      throw MCPError.invalidParams("unknown resource: \(uri)")
    }
  }
}

/// The MCP transport's two result shapes. Everything else that used to live here moved to
/// `PensieveKit`'s `MCPQueries`.
enum PensieveMCP {
  static let maxResultSizeMeta = "anthropic/maxResultSizeChars"

  /// A text tool result carrying the JSON payload + the result-size hint Claude Code honors.
  static func result(_ json: Data) -> CallTool.Result {
    // `json` always comes from `JSONEncoder`, which always emits valid UTF-8, so this fallback
    // is unreachable in practice — it exists only to avoid a force-unwrap of the failable initializer.
    let text = String(data: json, encoding: .utf8) ?? "<invalid utf8>"
    return .init(content: [.text(text: text, annotations: nil, _meta: nil)],
                 _meta: Metadata(additionalFields: [maxResultSizeMeta: .int(500_000)]))
  }

  static func errorResult(_ message: String) -> CallTool.Result {
    .init(content: [.text(text: message, annotations: nil, _meta: nil)], isError: true)
  }
}
