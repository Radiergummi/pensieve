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
        let md = try PensieveMCP.whatsNextMarkdown()
        return .init(contents: [.text(md, uri: uri, mimeType: "text/markdown")])
      }
      if uri.hasPrefix("pensieve://node/"),
         let id = UUID(uuidString: String(uri.dropFirst("pensieve://node/".count))),
         let md = try await PensieveMCP.nodeMarkdown(id: id) {
        return .init(contents: [.text(md, uri: uri, mimeType: "text/markdown")])
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
                                    _ db: any DatabaseReader) async throws -> ProjectContextBundle? {
    let (builder, kind) = makeBuilderAndKind()
    let cache = NarrationCache(url: PensievePaths.narrationCacheURL())
    return try await SessionContextQueries.bundle(
      forPath: path, nodeID: nodeID, db, now: Date(),
      summaryBuilder: builder, providerKind: kind, cache: cache)
  }

  static func projectContextJSON(path: String?, nodeID: UUID?) async throws -> Data {
    guard let db = try? openCanonicalReadOnly() else {
      return try makeEncoder().encode(Optional<ProjectContextBundle>.none)   // "null"
    }
    let effectivePath = path ?? FileManager.default.currentDirectoryPath
    let bundle = try await resolveBundle(path: effectivePath, nodeID: nodeID, db)
    return try makeEncoder().encode(bundle)   // encodes `null` for an unbound path
  }

  static func nodeMarkdown(id: UUID) async throws -> String? {
    guard let db = try? openCanonicalReadOnly() else { return nil }
    guard let bundle = try await resolveBundle(path: nil, nodeID: id, db) else { return nil }
    return SessionContextRender.markdown(bundle)
  }

  static func whatsNextMarkdown() throws -> String {
    guard let db = try? openCanonicalReadOnly() else { return SessionContextRender.whatsNext([]) }
    let items = try SessionContextQueries.rankedContext(limit: 10, context: nil, db, now: Date())
    return SessionContextRender.whatsNext(items)
  }

  static func whatsNextJSON(limit: Int, context: String?) throws -> Data {
    guard let db = try? openCanonicalReadOnly() else {
      return try makeEncoder().encode([WhatsNextItem]())   // "[]"
    }
    let items = try SessionContextQueries.rankedContext(limit: limit, context: context, db, now: Date())
    return try makeEncoder().encode(items)
  }

  static func recallJSON(looseEndID: UUID, radius: Int) throws -> Data {
    guard let db = try? openCanonicalReadOnly() else {
      return try makeEncoder().encode(Optional<RecallBundle>.none)   // "null"
    }
    let bundle = try SessionContextQueries.recall(looseEndID: looseEndID, radius: radius, db)
    return try makeEncoder().encode(bundle)   // encodes `null` for an unknown id
  }

  /// A text tool result carrying the JSON payload + the result-size hint Claude Code honors.
  static func result(_ json: Data) -> CallTool.Result {
    let text = String(decoding: json, as: UTF8.self)
    return .init(content: [.text(text: text, annotations: nil, _meta: nil)],
                 _meta: Metadata(additionalFields: [maxResultSizeMeta: .int(500_000)]))
  }
}
