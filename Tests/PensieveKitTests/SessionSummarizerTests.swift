import Foundation
import Testing
@testable import PensieveKit

private struct EchoLen: LLMProvider {
  func complete(prompt: String) async throws -> String { "SUMMARY(promptLen=\(prompt.count))" }
}
private struct ThrowingProvider: LLMProvider {
  func complete(prompt: String) async throws -> String { throw LLMError.providerFailed("boom") }
}
private struct FixedReply: LLMProvider {
  let reply: String
  func complete(prompt: String) async throws -> String { reply }
}

private func m(_ i: Int, _ role: String, _ text: String, user: Bool) -> TranscriptMessage {
  TranscriptMessage(index: i, role: role, text: text, timestamp: nil, isUserPrompt: user)
}

@Test func summarizerReturnsNilWhenNoRelevantMessages() async {
  // Only tool-result-ish / non-user, non-assistant content -> nothing to summarize.
  let msgs = [m(0, "tool", "some tool output", user: false)]
  let out = await SessionSummarizer(provider: EchoLen()).summarize(msgs)
  #expect(out == nil)
}

@Test func summarizerReturnsNilOnProviderFailure() async {
  let msgs = [m(0, "user", "let's build the parser", user: true)]
  let out = await SessionSummarizer(provider: ThrowingProvider()).summarize(msgs)
  #expect(out == nil)
}

@Test func summarizerCapsOutput() async {
  let long = String(repeating: "x", count: 5000)
  let msgs = [m(0, "assistant", "done", user: false)]
  let out = await SessionSummarizer(provider: FixedReply(reply: long)).summarize(msgs)
  #expect(out != nil)
  #expect(out!.count <= SessionSummarizer.outputCap)
}

@Test func summarizerIncludesUserAndAssistantOnly() {
  let msgs = [m(0, "user", "add auth", user: true),
              m(1, "assistant", "added auth", user: false),
              m(2, "user", "tool blob", user: false)]   // isUserPrompt false -> excluded
  let blob = SessionSummarizer.relevantBlob(msgs)
  #expect(blob.contains("add auth"))
  #expect(blob.contains("added auth"))
  #expect(!blob.contains("tool blob"))
}

@Test func summarizerReduceCallRunsAfterMapping() async {
  // Count map chunks precisely, then assert the reduce call ran (calls == chunks + 1).
  actor Counter { var n = 0; func bump() { n += 1 }; func value() -> Int { n } }
  struct Counting: LLMProvider {
    let counter: Counter
    func complete(prompt: String) async throws -> String { await counter.bump(); return "part" }
  }
  let counter = Counter()
  let big = String(repeating: "word ", count: SessionSummarizer.inputBudget)  // ~5x budget
  let msgs = [m(0, "assistant", big, user: false)]
  let expectedChunks = SessionSummarizer.chunk(SessionSummarizer.relevantBlob(msgs), budget: SessionSummarizer.inputBudget).count
  let out = await SessionSummarizer(provider: Counting(counter: counter)).summarize(msgs)
  #expect(out != nil)
  #expect(expectedChunks > 1)                                   // genuinely multi-chunk
  #expect(await counter.value() == expectedChunks + 1)          // every map chunk + exactly one reduce
}

@Test func summarizerReturnsNilWhenReduceCallFails() async {
  // A provider that succeeds for the map calls but fails on the reduce call must yield nil,
  // not a locally-stitched fallback (best-effort contract).
  actor Gate { var seen = 0; func next() -> Int { seen += 1; return seen } }
  struct MapOKReduceFails: LLMProvider {
    let gate: Gate
    let mapCalls: Int
    func complete(prompt: String) async throws -> String {
      if await gate.next() <= mapCalls { return "part" }
      throw LLMError.providerFailed("reduce boom")
    }
  }
  let big = String(repeating: "word ", count: SessionSummarizer.inputBudget)
  let msgs = [m(0, "assistant", big, user: false)]
  let chunks = SessionSummarizer.chunk(SessionSummarizer.relevantBlob(msgs), budget: SessionSummarizer.inputBudget).count
  let out = await SessionSummarizer(provider: MapOKReduceFails(gate: Gate(), mapCalls: chunks)).summarize(msgs)
  #expect(out == nil)
}
