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

private struct DropIndices: LLMProvider {
  let drop: [Int]
  func complete(prompt: String) async throws -> String { "[]" }
  func classifyNonSalientIndices(prompt: String) async throws -> [Int] { drop }
}
private struct ThrowSalience: LLMProvider {
  func complete(prompt: String) async throws -> String { "[]" }
  func classifyNonSalientIndices(prompt: String) async throws -> [Int] { throw LLMError.providerFailed("boom") }
}

private func vle(_ quote: String, at index: Int) -> VerifiedLooseEnd {
  VerifiedLooseEnd(text: quote, quote: quote, role: "user", sourceMessageIndex: index)
}
private func um(_ i: Int, _ text: String) -> TranscriptMessage {
  TranscriptMessage(index: i, role: "user", text: text, timestamp: nil, isUserPrompt: true)
}

@Test func salienceDropsReturnedIndices() async {
  let ends = [vle("we should migrate the auth tables later", at: 0),
              vle("please read the spec now", at: 1)]
  let msgs = [um(0, "we should migrate the auth tables later"), um(1, "please read the spec now")]
  let kept = await SalienceClassifier(provider: DropIndices(drop: [1])).filter(ends, messages: msgs)
  #expect(kept.map(\.quote) == ["we should migrate the auth tables later"])
}

@Test func salienceKeepsAllOnEmptyDropSet() async {
  let ends = [vle("we should migrate the auth tables later", at: 0)]
  let msgs = [um(0, "we should migrate the auth tables later")]
  let kept = await SalienceClassifier(provider: DropIndices(drop: [])).filter(ends, messages: msgs)
  #expect(kept.count == 1)
}

@Test func salienceFailsOpenKeepingAllOnProviderError() async {
  let ends = [vle("a real deferred item to revisit", at: 0), vle("another to park for later", at: 1)]
  let msgs = [um(0, "a real deferred item to revisit"), um(1, "another to park for later")]
  let kept = await SalienceClassifier(provider: ThrowSalience()).filter(ends, messages: msgs)
  #expect(kept.count == 2)   // hard error -> keep all
}

@Test func salienceEmptyInputYieldsEmpty() async {
  let kept = await SalienceClassifier(provider: DropIndices(drop: [0])).filter([], messages: [])
  #expect(kept.isEmpty)
}
