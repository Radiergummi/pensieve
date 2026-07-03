import Foundation
import Testing
@testable import PensieveKit

private func msg(_ i: Int, _ role: String, _ text: String, userPrompt: Bool) -> TranscriptMessage {
  TranscriptMessage(index: i, role: role, text: text, timestamp: nil, isUserPrompt: userPrompt)
}

private let corpus: [TranscriptMessage] = [
  msg(0, "user", "We still need to add rate limiting before launch", userPrompt: true),
  msg(1, "assistant", "You should also add pagination and retries.", userPrompt: false),
  msg(2, "user", "ok", userPrompt: true),
]

@Test func verifierAcceptsVerbatimUserQuote() {
  let c = LooseEndCandidate(text: "add rate limiting",
                            quote: "we still need to add rate limiting before launch", messageIndex: 0)
  // whitespace-normalized, case-insensitive? NO — verbatim; test uses exact case below.
  let exact = LooseEndCandidate(text: "add rate limiting",
                                quote: "We still need to add rate limiting before launch", messageIndex: 0)
  #expect(LooseEndVerifier.verify(exact, messages: corpus) != nil)
  #expect(LooseEndVerifier.verify(c, messages: corpus) == nil) // wrong case is not verbatim
}

@Test func verifierRejectsAssistantQuote() {
  let c = LooseEndCandidate(text: "add pagination",
                            quote: "You should also add pagination and retries.", messageIndex: 1)
  #expect(LooseEndVerifier.verify(c, messages: corpus) == nil)  // not a user prompt
}

@Test func verifierRejectsFabricatedQuote() {
  let c = LooseEndCandidate(text: "deploy to prod",
                            quote: "remember to deploy to prod on Friday", messageIndex: 0)
  #expect(LooseEndVerifier.verify(c, messages: corpus) == nil)  // not present in message 0
}

@Test func verifierRejectsTooShortQuote() {
  let c = LooseEndCandidate(text: "ok", quote: "ok", messageIndex: 2)
  #expect(LooseEndVerifier.verify(c, messages: corpus) == nil)  // below minQuoteLength
}

@Test func verifierRejectsOutOfRangeIndex() {
  let c = LooseEndCandidate(text: "x", quote: "whatever text here padded", messageIndex: 99)
  #expect(LooseEndVerifier.verify(c, messages: corpus) == nil)
}

@Test func verifierToleratesWhitespaceDifferences() {
  let spaced = [msg(0, "user", "add   rate\n limiting  soon and more words", userPrompt: true)]
  let c = LooseEndCandidate(text: "rate limiting",
                            quote: "add rate limiting soon and more words", messageIndex: 0)
  #expect(LooseEndVerifier.verify(c, messages: spaced) != nil)
}
