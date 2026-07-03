import Foundation
import Testing
@testable import PensieveKit

private struct StubProvider: LLMProvider {
  let reply: @Sendable (String) -> String
  func complete(prompt: String) async throws -> String { reply(prompt) }
}

@Test func extractorDecodesCandidatesFromModelOutput() async throws {
  let messages = [
    TranscriptMessage(index: 0, role: "user", text: "We still need to add rate limiting", timestamp: nil, isUserPrompt: true),
    TranscriptMessage(index: 1, role: "assistant", text: "sure", timestamp: nil, isUserPrompt: false),
  ]
  let stub = StubProvider { prompt in
    // The prompt must contain only user prose (index 0), not the assistant line.
    #expect(prompt.contains("rate limiting"))
    #expect(!prompt.contains("sure"))
    return """
    Here you go:
    [{"text":"add rate limiting","quote":"We still need to add rate limiting","messageIndex":0}]
    """
  }
  let out = try await LooseEndExtractor(provider: stub).extract(from: messages)
  #expect(out.count == 1)
  #expect(out.first?.messageIndex == 0)
  #expect(out.first?.quote == "We still need to add rate limiting")
}

@Test func decodeCandidatesSkipsMalformedOutput() {
  #expect(LooseEndExtractor.decodeCandidates("no json here").isEmpty)
  let ok = LooseEndExtractor.decodeCandidates(#"prefix [{"text":"t","quote":"qqqqqqqqqqqqqqqq","messageIndex":2}] suffix"#)
  #expect(ok.first?.messageIndex == 2)
}

@Test func chunkFragmentsSplitsOversizedMessageAndPreservesIndex() {
  let budget = 100
  let longText = String(repeating: "x", count: budget * 4 + 37) // ~4x budget
  let messages = [
    TranscriptMessage(index: 7, role: "user", text: longText, timestamp: nil, isUserPrompt: true),
  ]
  let chunks = LooseEndExtractor.chunkFragments(messages, budget: budget)
  #expect(chunks.count >= 4)
  for chunk in chunks {
    let combined = chunk.reduce(0) { $0 + $1.text.count }
    #expect(combined <= budget)
    for fragment in chunk {
      #expect(fragment.index == 7)
    }
  }
}

@Test func chunkFragmentsKeepsSmallMessageInOneChunk() {
  let messages = [
    TranscriptMessage(index: 0, role: "user", text: "short prompt", timestamp: nil, isUserPrompt: true),
  ]
  let chunks = LooseEndExtractor.chunkFragments(messages, budget: 2500)
  #expect(chunks.count == 1)
  #expect(chunks[0].count == 1)
}

@Test func splitChunkHalvesFragmentsThenText() {
  // Several fragments -> split by fragment.
  let many = [PromptFragment(index: 1, text: "aa"), PromptFragment(index: 1, text: "bb"),
              PromptFragment(index: 1, text: "cc"), PromptFragment(index: 1, text: "dd")]
  let byFragment = LooseEndExtractor.splitChunk(many)
  #expect(byFragment.count == 2)
  #expect(byFragment[0].count == 2 && byFragment[1].count == 2)
  // One fragment -> split its text, preserving index.
  let one = [PromptFragment(index: 5, text: "abcdefgh")]
  let byText = LooseEndExtractor.splitChunk(one)
  #expect(byText.count == 2)
  #expect(byText[0].first?.text == "abcd" && byText[1].first?.text == "efgh")
  #expect(byText.allSatisfy { $0.allSatisfy { $0.index == 5 } })
}

@Test func extractorRecoversFromContextOverflowBySplitting() async throws {
  // A provider that rejects any prompt over ~1500 chars as a context overflow, but
  // succeeds (returning one candidate) once the chunk is split small enough.
  struct OverflowStub: LLMProvider {
    func complete(prompt: String) async throws -> String {
      if prompt.count > 1500 {
        throw LLMError.providerFailed("FoundationModels: exceededContextWindowSize(...)")
      }
      return #"[{"text":"t","quote":"qqqqqqqqqqqqqqqqqqqq","messageIndex":9}]"#
    }
  }
  let big = TranscriptMessage(index: 9, role: "user",
    text: String(repeating: "word ", count: 600), timestamp: nil, isUserPrompt: true) // ~3000 chars
  let out = try await LooseEndExtractor(provider: OverflowStub()).extract(from: [big])
  #expect(!out.isEmpty)   // recovered instead of throwing
}
