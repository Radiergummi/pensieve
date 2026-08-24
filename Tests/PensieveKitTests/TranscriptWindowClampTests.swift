import Foundation
import Testing
@testable import PensieveKit

private func message(_ index: Int, isUserPrompt: Bool) -> TranscriptMessage {
  TranscriptMessage(index: index, role: isUserPrompt ? "user" : "assistant",
                    text: "text \(index)", timestamp: nil, isUserPrompt: isUserPrompt)
}

private func session(_ count: Int, promptAt: Int) -> ParsedSession {
  ParsedSession(sessionID: "s1", cwd: nil, startedAt: nil, endedAt: nil, userPromptCount: 1,
                messages: (0..<count).map { message($0, isUserPrompt: $0 == promptAt) })
}

/// A negative radius must not trap.
///
/// This is not a hypothetical: `radius` arrives from an MCP argument, `recall` did not clamp it (its
/// two sibling tools do, and say why), and for ANY negative value `lower` lands above `upper`, so
/// the `messages[lower...upper]` range expression hit its precondition and aborted the process.
/// Because `pensieve mcp` is a long-lived stdio server, that took Pensieve away from the client's
/// whole session over one malformed argument — not just that one call.
///
/// Clamping lives here rather than at the MCP boundary because this is where the trap is, so every
/// caller is covered. -1 and a large negative are both exercised: a `max(0,·)` on the wrong operand
/// would still pass for -1 in some spellings.
@Test func negativeRadiusYieldsTheCitedMessageAloneInsteadOfTrapping() {
  for radius in [-1, -8, Int.min + 1] {
    let window = TranscriptWindow.slice(session: session(10, promptAt: 5), messageIndex: 5,
                                        citedText: "text 5", requireUserPrompt: true, radius: radius)
    #expect(window?.map(\.index) == [5], "radius \(radius)")
    #expect(window?.first?.isCited == true, "radius \(radius)")
  }
}

/// The clamp must not have cost the real behaviour: zero still means "the cited message alone",
/// a positive radius still widens, and the window is still clipped at both array ends rather than
/// wrapping or over-running.
@Test func clampLeavesNonNegativeRadiiUnchanged() {
  let parsed = session(10, promptAt: 5)
  #expect(TranscriptWindow.slice(session: parsed, messageIndex: 5, citedText: "text 5",
                                 requireUserPrompt: true, radius: 0)?.map(\.index) == [5])
  #expect(TranscriptWindow.slice(session: parsed, messageIndex: 5, citedText: "text 5",
                                 requireUserPrompt: true, radius: 2)?.map(\.index) == [3, 4, 5, 6, 7])
  // Clipped at the ends, not wrapped: a radius wider than the transcript yields all of it.
  #expect(TranscriptWindow.slice(session: parsed, messageIndex: 5, citedText: "text 5",
                                 requireUserPrompt: true, radius: 99)?.map(\.index) == Array(0..<10))
  // A citation that no longer holds still refuses, clamp or no clamp.
  #expect(TranscriptWindow.slice(session: parsed, messageIndex: 5, citedText: "gone",
                                 requireUserPrompt: true, radius: -1) == nil)
}
