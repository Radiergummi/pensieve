import ArgumentParser
import Foundation
import MCP
import PensieveKit
import SQLiteData

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
      ])
    }

    await server.withMethodHandler(CallTool.self) { params in
      switch params.name {
      case "project_context":
        let path = params.arguments?["path"]?.stringValue
        let nodeID = (params.arguments?["node_id"]?.stringValue).flatMap { UUID(uuidString: $0) }
        let json = try await PensieveMCP.projectContextJSON(path: path, nodeID: nodeID)
        return PensieveMCP.result(json)
      case "whats_next":
        let limit = params.arguments?["limit"]?.intValue ?? 5
        let context = params.arguments?["context"]?.stringValue
        let json = try PensieveMCP.whatsNextJSON(limit: limit, context: context)
        return PensieveMCP.result(json)
      default:
        return .init(content: [.text(text: "unknown tool", annotations: nil, _meta: nil)], isError: true)
      }
    }

    try await server.start(transport: StdioTransport())
    await server.waitUntilCompleted()
  }
}

/// Bridges the tested Kit kernel to MCP results. Opens the store read-only per call (fresh read
/// transaction sees the latest committed drain). The prose builder is on-device by default.
enum PensieveMCP {
  static let maxResultSizeMeta = "anthropic/maxResultSizeChars"

  private static func makeBuilderAndKind() -> (SummaryBuilder, String) {
    let defaults = PensieveDefaults.shared()
    let provider = makeDefaultLLMProvider(defaults: defaults)
    let kind = resolvedProviderKind(defaults: defaults, cloudConfig: nil, apiKey: nil)
    return (SummaryBuilder(provider: provider), kind)
  }

  static func projectContextJSON(path: String?, nodeID: UUID?) async throws -> Data {
    let db = try openCanonicalReadOnly()
    let (builder, kind) = makeBuilderAndKind()
    let cache = NarrationCache(url: PensievePaths.narrationCacheURL())
    let effectivePath = path ?? FileManager.default.currentDirectoryPath
    let bundle = try await SessionContextQueries.bundle(
      forPath: effectivePath, nodeID: nodeID, db, now: Date(),
      summaryBuilder: builder, providerKind: kind, cache: cache)
    let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
    return try encoder.encode(bundle)   // encodes `null` for an unbound path
  }

  static func whatsNextJSON(limit: Int, context: String?) throws -> Data {
    let db = try openCanonicalReadOnly()
    let items = try SessionContextQueries.rankedContext(limit: limit, context: context, db, now: Date())
    let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
    return try encoder.encode(items)
  }

  /// A text tool result carrying the JSON payload + the result-size hint Claude Code honors.
  static func result(_ json: Data) -> CallTool.Result {
    let text = String(decoding: json, as: UTF8.self)
    return .init(content: [.text(text: text, annotations: nil, _meta: nil)],
                 _meta: Metadata(additionalFields: [maxResultSizeMeta: .int(500_000)]))
  }
}
