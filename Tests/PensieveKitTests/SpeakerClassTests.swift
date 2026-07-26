import Foundation
import Testing
@testable import PensieveKit

private func message(role: String, text: String = "hello", isCited: Bool = false,
                     isUserPrompt: Bool) -> ProvenanceMessage {
  ProvenanceMessage(index: 0, role: role, text: text, isCited: isCited, isUserPrompt: isUserPrompt)
}

@Test func userPromptWithProseIsYou() {
  let msg = message(role: "user", isUserPrompt: true)
  #expect(SpeakerClass.of(msg, segments: [.markdown("hello")]) == .you)
}

@Test func assistantRoleIsClaude() {
  let msg = message(role: "assistant", isUserPrompt: false)
  #expect(SpeakerClass.of(msg, segments: [.markdown("hello")]) == .claude)
}

/// `role` falls back to `type` in `TranscriptParser`, so it is not a closed set — an unrecognised
/// role must degrade to `.system`, not crash or misclassify.
@Test func unrecognisedRoleIsSystem() {
  let msg = message(role: "tool_result", isUserPrompt: false)
  #expect(SpeakerClass.of(msg, segments: [.markdown("hello")]) == .system)
}

/// The load-bearing case (309 genuine `type:"user"` records in this project's own transcripts):
/// `isUserPrompt` is false merely because the message contains an envelope marker, but the segments
/// still carry real human prose. The conjunctive rule must still classify this as `.you`.
@Test func userRoleWithHumanContentIsYouEvenWhenNotFlaggedAsUserPrompt() {
  let msg = message(role: "user", isUserPrompt: false)
  #expect(SpeakerClass.of(msg, segments: [.markdown("real prose from the user")]) == .you)
}

@Test func notUserPromptWithOnlyHarnessSegmentsIsSystem() {
  let msg = message(role: "user", isUserPrompt: false)
  let block = HarnessBlock(kind: .interrupted, raw: "[Request interrupted]")
  #expect(SpeakerClass.of(msg, segments: [.harness(block)]) == .system)
}

/// Whitespace-only markdown is not human content.
@Test func notUserPromptWithWhitespaceOnlyMarkdownIsSystem() {
  let msg = message(role: "user", isUserPrompt: false)
  #expect(SpeakerClass.of(msg, segments: [.markdown("   \n\t  ")]) == .system)
}

/// A callout counts as human content even when `isUserPrompt` is false.
@Test func notUserPromptWithCalloutIsYou() {
  let msg = message(role: "user", isUserPrompt: false)
  let callout = TranscriptCallout(severity: .caution, tagName: "HARD-GATE", body: "body", raw: "<HARD-GATE>body</HARD-GATE>")
  #expect(SpeakerClass.of(msg, segments: [.callout(callout)]) == .you)
}
