import Foundation
import Testing
@testable import PensieveKit

// MARK: - Severity mapping (token-based, never substring)

@Test func severityMatchesWholeTokens() {
  #expect(CalloutSeverity.forTagName("HARD-GATE") == .caution)
  #expect(CalloutSeverity.forTagName("SUBAGENT-STOP") == .caution)
  #expect(CalloutSeverity.forTagName("EXTREMELY-IMPORTANT") == .important)
}

/// The substring hazard the spec calls out: `GATE` lives inside `AUTHGW`, `STOP` inside `NON-STOP`'s
/// neighbours. Whole-token matching must not fire on either.
@Test func severityDoesNotFireOnSubstrings() {
  #expect(CalloutSeverity.forTagName("AUTHGW_RESOLVE_KEY_URL") == .neutral)
  #expect(CalloutSeverity.forTagName("NONSTOP") == .neutral)
  #expect(CalloutSeverity.forTagName("UNIMPORTANTLY") == .neutral)
}

@Test func severityTreatsDashAndUnderscoreAlike() {
  #expect(CalloutSeverity.forTagName("EXTREMELY_IMPORTANT") == .important)
  #expect(CalloutSeverity.forTagName("HARD_GATE") == .caution)
}

@Test func severityPrecedenceIsTableOrderCautionBeforeImportant() {
  // Contains both a caution token and an important token; caution wins.
  #expect(CalloutSeverity.forTagName("CRITICAL-MUST") == .caution)
}

@Test func severityFallsBackToNeutralForUnknownTags() {
  #expect(CalloutSeverity.forTagName("FUTURE-SKILL-TAG") == .neutral)
  #expect(CalloutSeverity.forTagName("") == .neutral)
}

// MARK: - `raw` reaches every case (the basis of I2)

@Test func rawRoundTripsForEverySegmentCase() {
  #expect(TranscriptSegment.markdown("hello").raw == "hello")

  let callout = TranscriptSegment.callout(
    .init(severity: .caution, tagName: "HARD-GATE", body: "stop", raw: "<HARD-GATE>stop</HARD-GATE>"))
  #expect(callout.raw == "<HARD-GATE>stop</HARD-GATE>")

  let harness = TranscriptSegment.harness(
    .init(kind: .systemReminder("note"), raw: "<system-reminder>note</system-reminder>"))
  #expect(harness.raw == "<system-reminder>note</system-reminder>")
}
