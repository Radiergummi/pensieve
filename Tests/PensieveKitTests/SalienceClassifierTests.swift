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

@Test func salienceMapsDropIndicesPerBatchNotGlobally() async {
  // Force one-end-per-batch with a tiny budget, and drop based on quote content so the
  // stub's [0] drop applies to the RIGHT batch-local end each time. If filter mis-mapped
  // batch-local indices to global positions, the wrong ends would survive.
  let ends = [
    vle("we should migrate the auth tables later", at: 0),   // KEEP (deferred)
    vle("please read the spec right now", at: 1),             // DROP (in-the-moment)
    vle("let's park the canvas idea for now", at: 2),         // KEEP (parked)
    vle("run the tests immediately", at: 3),                  // DROP (in-the-moment)
  ]
  let msgs = [um(0, "we should migrate the auth tables later"),
              um(1, "please read the spec right now"),
              um(2, "let's park the canvas idea for now"),
              um(3, "run the tests immediately")]
  // Per-batch stub: within each single-end batch, drop [0] iff that batch's OWN quote (the
  // "QUOTE: " line, not a neighbor pulled into CONTEXT) is an in-the-moment request. buildPrompt
  // tags the sole end as [0], so returning [0] drops it.
  struct PerBatchDrop: LLMProvider {
    func complete(prompt: String) async throws -> String { "[]" }
    func classifyNonSalientIndices(prompt: String) async throws -> [Int] {
      let dropIt = prompt.contains("QUOTE: please read the spec right now")
        || prompt.contains("QUOTE: run the tests immediately")
      return dropIt ? [0] : []
    }
  }
  // batchCharBudget small enough that each end (quote + context) is its own batch.
  let kept = await SalienceClassifier(provider: PerBatchDrop(), batchCharBudget: 1)
    .filter(ends, messages: msgs)
  #expect(kept.map(\.quote) == ["we should migrate the auth tables later",
                                "let's park the canvas idea for now"])
}
