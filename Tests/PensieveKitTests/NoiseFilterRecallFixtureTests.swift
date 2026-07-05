// Tests/PensieveKitTests/NoiseFilterRecallFixtureTests.swift
import Foundation
import Testing
@testable import PensieveKit

/// Real loose ends that LOOK like noise. Every one MUST survive both filters. This is the
/// recall half of the guard — hand-authored raw cases, NOT sampled pipeline survivors, so
/// it certifies recall on the exact inputs the new drops are most likely to over-kill.

/// Whole messages a developer plausibly types that must NOT be dropped as "briefs".
private let recallMessages: [String] = [
  "You are absolutely right, let's fix the migration before the auth refactor.",
  "Your task is to wire up the webhook, forget the refactor.",
  "You are implementing #2 first, then stop.",
  "High-scrutiny review please — does the token exchange look right?",
  "Please also do these before merge:\n- [ ] fix the flaky auth test\n- [ ] bump the deploy tag\nand don't forget to update the changelog.",
]

/// Candidate quotes that must NOT be dropped by CandidateFilter.
private let recallQuotes: [String] = [
  "yes, let's fix 2 and 3 too",
  "approved, write up the spec",
  "can we fix this?",
  "still need to migrate the auth tables before launch",
  "are you done with the auth refactor and did you handle the migration?",
  "- [ ] fix the flaky auth test",
]

@Test func structuralFilterKeepsEveryAdversarialRecallMessage() {
  let msgs = recallMessages.map { TranscriptMessage(index: 0, role: "user", text: $0, timestamp: nil, isUserPrompt: true) }
  #expect(StructuralNoiseFilter.strip(msgs).count == msgs.count)
}

@Test func candidateFilterKeepsEveryAdversarialRecallQuote() {
  let cands = recallQuotes.map { LooseEndCandidate(text: "p", quote: $0, messageIndex: 0) }
  #expect(CandidateFilter.strip(cands).map(\.quote) == recallQuotes)
}
