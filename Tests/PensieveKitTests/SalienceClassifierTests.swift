import Foundation
import Testing
@testable import PensieveKit

private struct RawReply: LLMProvider {
  let reply: String
  func complete(prompt: String) async throws -> String { reply }
}

@Test func nonSalientDefaultExtensionParsesIntArray() async throws {
  let idx = try await RawReply(reply: "drop: [1, 2]").classifyNonSalientIndices(prompt: "x")
  #expect(Set(idx) == Set([1, 2]))
}

@Test func nonSalientDefaultExtensionThrowsOnUnparseable() async {
  await #expect(throws: LLMError.self) {
    _ = try await RawReply(reply: "no array here").classifyNonSalientIndices(prompt: "x")
  }
}
