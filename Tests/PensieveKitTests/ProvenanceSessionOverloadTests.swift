import Foundation
import Testing
@testable import PensieveKit

private func message(_ index: Int, _ role: String, _ text: String, isUserPrompt: Bool) -> TranscriptMessage {
  TranscriptMessage(index: index, role: role, text: text, timestamp: nil, isUserPrompt: isUserPrompt)
}

private func session(_ messages: [TranscriptMessage]) -> ParsedSession {
  ParsedSession(sessionID: "s1", cwd: nil, startedAt: nil, endedAt: nil, userPromptCount: 0, messages: messages)
}

private func looseEnd(quote: String, messageIndex: Int) -> LooseEnd {
  LooseEnd(id: UUID(), nodeID: UUID(), sourceEventID: UUID(), text: "an end", quote: quote,
           status: "open", role: "typed", sourceMessageIndex: messageIndex,
           label: "", labelSuggestion: "", createdAt: Date())
}

private func event() -> Event {
  Event(id: UUID(), nodeID: UUID(), sourceID: UUID(), occurredAt: Date(), kind: "cc.session",
        summary: "a session", detailJSON: "{}")
}

@Test func slicesTheWindowAroundTheCitedMessage() {
  // Mutation this catches: a wrong lowerIndex/upperIndex bound, or slicing by array position
  // instead of by cited identity, would change which indices land in the window.
  let messages = (0..<10).map { message($0, $0 == 5 ? "user" : "assistant", "text \($0)",
                                        isUserPrompt: $0 == 5) }
  let context = ProvenanceQueries.context(session: session(messages),
                                          looseEnd: looseEnd(quote: "text 5", messageIndex: 5),
                                          event: event(), radius: 2)
  #expect(context.transcriptAvailable)
  #expect(context.messages.map(\.index) == [3, 4, 5, 6, 7])
  #expect(context.messages.first { $0.isCited }?.index == 5)
}

@Test func aCitedMessageThatIsNotAUserPromptDegradesHonestly() {
  // Mutation this catches: dropping the `isUserPrompt` half of the guard (or inverting it) would
  // let a non-user cited message through as available. Half of the two-part guard — shared with
  // the one-shot database-taking path, which is what pins the guard as one definition.
  let messages = [message(0, "assistant", "text 0", isUserPrompt: false)]
  let context = ProvenanceQueries.context(session: session(messages),
                                          looseEnd: looseEnd(quote: "text 0", messageIndex: 0),
                                          event: event())
  #expect(!context.transcriptAvailable)
  #expect(context.messages.isEmpty)
}

@Test func aQuoteThatNoLongerAppearsDegradesHonestly() {
  // Mutation this catches: dropping the `contains(quote)` half of the guard (or inverting it)
  // would let a stale/edited-away quote through as available.
  let messages = [message(0, "user", "the message changed", isUserPrompt: true)]
  let context = ProvenanceQueries.context(session: session(messages),
                                          looseEnd: looseEnd(quote: "a quote since edited away",
                                                             messageIndex: 0),
                                          event: event())
  #expect(!context.transcriptAvailable)
}

@Test func quoteWhitespaceIsNormalizedBeforeComparison() {
  // Mutation this catches: comparing raw (un-normalized) text against the quote would fail this
  // case, since the message's whitespace differs from the stored quote's.
  let messages = [message(0, "user", "we should  fix\nthe sync gap", isUserPrompt: true)]
  let context = ProvenanceQueries.context(session: session(messages),
                                          looseEnd: looseEnd(quote: "we should fix the sync gap",
                                                             messageIndex: 0),
                                          event: event())
  #expect(context.transcriptAvailable)
}

@Test func anUnknownMessageIndexDegradesHonestly() {
  // Mutation this catches: falling back to bare array position instead of resolving by cited
  // identity would silently resolve to some in-bounds message instead of degrading.
  let messages = [message(0, "user", "text", isUserPrompt: true)]
  let context = ProvenanceQueries.context(session: session(messages),
                                          looseEnd: looseEnd(quote: "text", messageIndex: 99),
                                          event: event())
  #expect(!context.transcriptAvailable)
}
