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
