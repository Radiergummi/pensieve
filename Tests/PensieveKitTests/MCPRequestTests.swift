import Foundation
import Testing
@testable import PensieveKit

/// The MCP request boundary: the wire keys, the arguments that must be REJECTED rather than
/// quietly reinterpreted, and the clamps.
///
/// These types moved the ten `params.arguments?["node_id"]` subscripts out of the CLI target, where
/// `PensieveKitTests` could not reach them and where each key was spelled once in the advertised
/// schema and again, independently, in the handler.
@Suite struct MCPRequestTests {
  private func decode<Request: Decodable>(_ type: Request.Type, _ json: String) throws -> Request {
    try JSONDecoder().decode(Request.self, from: Data(json.utf8))
  }

  // MARK: - wire keys

  /// The `snake_case` wire spelling is the ONLY one accepted; the Swift property name is not a key.
  /// If these ever swap, an MCP client's arguments silently stop arriving.
  @Test func requestsDecodeTheSnakeCaseWireKeys() throws {
    let id = UUID()
    let context = try decode(MCPProjectContextRequest.self, #"{"node_id":"\#(id.uuidString)"}"#)
    #expect(context.nodeID == id)
    #expect(try decode(MCPProjectContextRequest.self, #"{"nodeID":"\#(id.uuidString)"}"#).nodeID == nil,
            "the camelCase property name is not a wire key")

    let recall = try decode(MCPRecallRequest.self, #"{"loose_end_id":"\#(id.uuidString)"}"#)
    #expect(recall.looseEndID == id)
    let passage = try decode(MCPRecallRequest.self, #"{"passage_id":"\#(id.uuidString)"}"#)
    #expect(passage.passageID == id)

    let search = try decode(MCPSearchRequest.self, #"{"query":"x","include_archived":true}"#)
    #expect(search.includeArchived)
    #expect(try !decode(MCPSearchRequest.self, #"{"query":"x","includeArchived":true}"#).includeArchived)
  }

  // MARK: - rejected arguments

  /// A typo'd `node_id` used to be dropped by `flatMap { UUID(uuidString: $0) }` and the call then
  /// fell through to "resolve the cwd instead" — confident, well-formed context for a DIFFERENT
  /// project. A bad argument must fail the call.
  @Test func aMalformedNodeIDIsRejectedRatherThanIgnored() throws {
    #expect(throws: MCPFailure.malformedUUID(key: "node_id", value: "not-a-uuid")) {
      try decode(MCPProjectContextRequest.self, #"{"node_id":"not-a-uuid"}"#)
    }
    // An ABSENT id is still fine — that is the "reload wherever I am" call.
    #expect(try decode(MCPProjectContextRequest.self, #"{}"#).nodeID == nil)
  }

  @Test func aMalformedRecallIDIsRejectedRatherThanIgnored() throws {
    #expect(throws: MCPFailure.malformedUUID(key: "loose_end_id", value: "nope")) {
      try decode(MCPRecallRequest.self, #"{"loose_end_id":"nope"}"#)
    }
  }

  /// An unknown `context` is not inert: `NodeContextResolver.visibleNodeIDs` matches it against
  /// every node's resolved context, so a typo left only the context-less nodes visible and silently
  /// shrank the queue.
  @Test func anUnknownContextIsRejectedRatherThanSilentlyShrinkingTheQueue() throws {
    #expect(throws: MCPFailure.unknownContext("wrok")) {
      try decode(MCPWhatsNextRequest.self, #"{"context":"wrok"}"#)
    }
    #expect(try decode(MCPWhatsNextRequest.self, #"{"context":"work"}"#).context == NodeContext.work)
    #expect(try decode(MCPWhatsNextRequest.self, #"{"context":"personal"}"#).context == NodeContext.personal)
    // Absent and blank both mean "no filter", which is not the same as an unknown one.
    #expect(try decode(MCPWhatsNextRequest.self, #"{}"#).context == nil)
    #expect(try decode(MCPWhatsNextRequest.self, #"{"context":"  "}"#).context == nil)
  }

  @Test func searchRequiresAQueryOrAFile() throws {
    #expect(throws: MCPFailure.missingSearchArgument) { try decode(MCPSearchRequest.self, #"{}"#) }
    // All-whitespace is not an argument: `FTSQueryBuilder` trims too, so without this the call
    // returned an empty SUCCESS payload rather than a rejected request.
    #expect(throws: MCPFailure.missingSearchArgument) {
      try decode(MCPSearchRequest.self, #"{"query":"   ","file":"  "}"#)
    }
    // Either half ALONE is a real query — a bare `file` means "everything that touched this path".
    #expect(try decode(MCPSearchRequest.self, #"{"file":"Sources/Foo.swift"}"#).query.isEmpty)
    #expect(try decode(MCPSearchRequest.self, #"{"query":"launchd"}"#).file == nil)
  }

  @Test func recallRequiresOneOfItsTwoIDs() throws {
    #expect(throws: MCPFailure.missingRecallArgument) { try decode(MCPRecallRequest.self, #"{"radius":4}"#) }
  }

  // MARK: - clamps and defaults

  /// Both limits reach a `prefix(limit)`, which TRAPS on a negative — one malformed argument would
  /// take the whole long-lived server down.
  @Test func negativeLimitsAreClampedToOne() throws {
    #expect(try decode(MCPWhatsNextRequest.self, #"{"limit":-3}"#).limit == 1)
    #expect(try decode(MCPSearchRequest.self, #"{"query":"x","limit":-3}"#).limit == 1)
    #expect(try decode(MCPSearchRequest.self, #"{"query":"x","limit":0}"#).limit == 1)
  }

  @Test func defaultsMatchTheAdvertisedSchema() throws {
    #expect(try decode(MCPWhatsNextRequest.self, #"{}"#).limit == 5)
    #expect(try decode(MCPSearchRequest.self, #"{"query":"x"}"#).limit == 8)
    #expect(try decode(MCPRecallRequest.self, #"{"passage_id":"\#(UUID().uuidString)"}"#).radius == 8)
  }

  /// `radius` is clamped in Kit, by `TranscriptWindow.slice`. Re-clamping it here as well is how one
  /// of two copies of a rule eventually stops matching the other, so this pins that it is NOT.
  @Test func radiusIsPassedThroughUnclamped() throws {
    let request = try decode(MCPRecallRequest.self,
                             #"{"passage_id":"\#(UUID().uuidString)","radius":-5}"#)
    #expect(request.radius == -5)
  }
}
