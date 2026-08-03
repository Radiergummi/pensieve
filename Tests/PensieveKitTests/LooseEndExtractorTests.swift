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

@Test func extractorConsumesStructuredProviderOutput() async throws {
  // A provider whose `complete` is unusable but whose structured methods return real values
  // (as the guided-generation Foundation Models provider does). If the pipeline still routed
  // through `complete`, both stages would collapse (garbage classify -> fail open is harmless,
  // but garbage extract -> zero candidates); getting the candidate proves it uses the seam.
  struct StructuredProvider: LLMProvider {
    func complete(prompt: String) async throws -> String { "GARBAGE, not JSON at all" }
    func classifyGenuineIndices(prompt: String) async throws -> [Int] { [0] }
    func extractCandidates(prompt: String) async throws -> [LooseEndCandidate] {
      [LooseEndCandidate(text: "add rate limiting", quote: "We still need to add rate limiting", messageIndex: 0)]
    }
  }
  let messages = [
    TranscriptMessage(index: 0, role: "user", text: "We still need to add rate limiting", timestamp: nil, isUserPrompt: true),
  ]
  let out = try await LooseEndExtractor(provider: StructuredProvider()).extract(from: messages)
  #expect(out.count == 1)
  #expect(out.first?.quote == "We still need to add rate limiting")
}

@Test func decodeCandidatesSkipsMalformedOutput() {
  #expect(LooseEndExtractor.decodeCandidates("no json here").isEmpty)
  let candidates = LooseEndExtractor.decodeCandidates(#"prefix [{"text":"t","quote":"qqqqqqqqqqqqqqqq","messageIndex":2}] suffix"#)
  #expect(candidates.first?.messageIndex == 2)
}

@Test func decodeCandidatesToleratesTrailingBracketInProse() {
  // Trailing model prose containing ']' must not truncate/break the parse (regression:
  // a first-'[' to last-']' slice would swallow the prose and fail to decode -> drop all).
  let raw = #"[{"text":"t","quote":"qqqqqqqqqqqqqqqq","messageIndex":3}] (only item [1] mattered])"#
  let out = LooseEndExtractor.decodeCandidates(raw)
  #expect(out.count == 1)
  #expect(out.first?.messageIndex == 3)
}

@Test func decodeCandidatesKeepsValidElementsAroundAMalformedOne() {
  // One well-formed element and one with the wrong type for messageIndex. The good one must
  // survive — a single bad element shouldn't drop the whole chunk's recall (matches the doc).
  let raw = #"[{"text":"a","quote":"qqqqqqqqqqqqqqqq","messageIndex":1},{"text":"b","quote":"x","messageIndex":"nope"}]"#
  let out = LooseEndExtractor.decodeCandidates(raw)
  #expect(out.count == 1)
  #expect(out.first?.messageIndex == 1)
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

@Test func extractDropsBriefMessagesBeforeMining() async throws {
  let brief = "You are implementing Task 4 of the plan. Return ONLY the diff. Do not deviate.\n## Files\n## Steps\n"
    + String(repeating: "Detailed surrounding context for the task at hand. ", count: 20)
  #expect(brief.count >= 800)
  let messages = [
    TranscriptMessage(index: 0, role: "user", text: brief, timestamp: nil, isUserPrompt: true),
    TranscriptMessage(index: 1, role: "user", text: "we still need to add rate limiting", timestamp: nil, isUserPrompt: true),
  ]
  let stub = StubProvider { prompt in
    #expect(!prompt.contains("You are implementing Task 4"))   // brief stripped before classify AND extract
    return #"[{"text":"add rate limiting","quote":"we still need to add rate limiting","messageIndex":1}]"#
  }
  let out = try await LooseEndExtractor(provider: stub).extract(from: messages)
  #expect(out.map(\.quote) == ["we still need to add rate limiting"])
}

@Test func buildPromptCarriesSalienceDefinition() {
  let prompt = LooseEndExtractor.buildPrompt([PromptFragment(index: 0, text: "we should migrate later")])
  #expect(prompt.lowercased().contains("deferred"))
  #expect(prompt.contains("read the spec"))          // an explicit DROP example
  #expect(prompt.contains("[0]"))                    // still tags message indices
  #expect(prompt.contains("we should migrate later")) // still includes the body
}

@Test func chunkingBreaksOnWhitespaceNotMidWord() {
  let text = "alpha bravo charlie delta echo foxtrot golf hotel"
  let words = Set(text.split(separator: " ").map(String.init))
  let msg = TranscriptMessage(index: 0, role: "user", text: text, timestamp: nil, isUserPrompt: true)
  let chunks = LooseEndExtractor.chunkFragments([msg], budget: 12)
  // Reconstruction is exact and no fragment contains a partial (mid-cut) word.
  let joined = chunks.flatMap { $0 }.map(\.text).joined()
  #expect(joined == text)
  for chunk in chunks {
    for fragment in chunk {
      for word in fragment.text.split(separator: " ") { #expect(words.contains(String(word))) }
      #expect(fragment.text.count <= 12)   // budget invariant preserved
    }
  }
}
