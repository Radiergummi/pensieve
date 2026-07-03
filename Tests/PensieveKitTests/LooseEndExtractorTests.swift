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
