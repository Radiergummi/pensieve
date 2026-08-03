import Foundation
import Testing
@testable import PensieveKit

private func msg(_ index: Int, _ role: String, _ text: String, userPrompt: Bool) -> TranscriptMessage {
  TranscriptMessage(index: index, role: role, text: text, timestamp: nil, isUserPrompt: userPrompt)
}

private let corpus: [TranscriptMessage] = [
  msg(0, "user", "We still need to add rate limiting before launch", userPrompt: true),
  msg(1, "assistant", "You should also add pagination and retries.", userPrompt: false),
  msg(2, "user", "ok", userPrompt: true),
]

@Test func verifierAcceptsVerbatimUserQuote() {
  let candidate = LooseEndCandidate(text: "add rate limiting",
                            quote: "we still need to add rate limiting before launch", messageIndex: 0)
  // whitespace-normalized, case-insensitive? NO — verbatim; test uses exact case below.
  let exact = LooseEndCandidate(text: "add rate limiting",
                                quote: "We still need to add rate limiting before launch", messageIndex: 0)
  #expect(LooseEndVerifier.verify(exact, messages: corpus) != nil)
  #expect(LooseEndVerifier.verify(candidate, messages: corpus) == nil) // wrong case is not verbatim
}

@Test func verifierRejectsAssistantQuote() {
  let candidate = LooseEndCandidate(text: "add pagination",
                            quote: "You should also add pagination and retries.", messageIndex: 1)
  #expect(LooseEndVerifier.verify(candidate, messages: corpus) == nil)  // not a user prompt
}

@Test func verifierRejectsFabricatedQuote() {
  let candidate = LooseEndCandidate(text: "deploy to prod",
                            quote: "remember to deploy to prod on Friday", messageIndex: 0)
  #expect(LooseEndVerifier.verify(candidate, messages: corpus) == nil)  // not present in message 0
}

@Test func verifierRejectsTooShortQuote() {
  let candidate = LooseEndCandidate(text: "ok", quote: "ok", messageIndex: 2)
  #expect(LooseEndVerifier.verify(candidate, messages: corpus) == nil)  // below minQuoteLength
}

@Test func verifierRejectsOutOfRangeIndex() {
  let candidate = LooseEndCandidate(text: "x", quote: "whatever text here padded", messageIndex: 99)
  #expect(LooseEndVerifier.verify(candidate, messages: corpus) == nil)
}

@Test func verifierToleratesWhitespaceDifferences() {
  let spaced = [msg(0, "user", "add   rate\n limiting  soon and more words", userPrompt: true)]
  let candidate = LooseEndCandidate(text: "rate limiting",
                            quote: "add rate limiting soon and more words", messageIndex: 0)
  #expect(LooseEndVerifier.verify(candidate, messages: spaced) != nil)
}

@Test func verifierRejectsNormalizedQuoteAt14Chars() {
  // Quote normalizes to exactly 14 chars — below threshold.
  let msgs = [msg(0, "user", "this is a test query", userPrompt: true)]
  let candidate = LooseEndCandidate(text: "test",
                            quote: "this is a test", messageIndex: 0)  // "this is a test" → 14 chars when normalized
  #expect(LooseEndVerifier.verify(candidate, messages: msgs) == nil)
}

@Test func verifierAcceptsNormalizedQuoteAt15Chars() {
  // Quote normalizes to exactly 15 chars — meets threshold.
  let msgs = [msg(0, "user", "this is a test query", userPrompt: true)]
  let candidate = LooseEndCandidate(text: "test",
                            quote: "this is a test q", messageIndex: 0)  // "this is a test q" → 15 chars when normalized
  #expect(LooseEndVerifier.verify(candidate, messages: msgs) != nil)
}

@Test func verifierRejectsAllWhitespaceQuote() {
  // Quote is >= 15 whitespace chars but normalizes to empty.
  let msgs = [msg(0, "user", "some content here", userPrompt: true)]
  let candidate = LooseEndCandidate(text: "x",
                            quote: "               ", messageIndex: 0)  // 15 spaces
  #expect(LooseEndVerifier.verify(candidate, messages: msgs) == nil)
}
