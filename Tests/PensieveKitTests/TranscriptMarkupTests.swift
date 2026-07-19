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

// MARK: - I1 passthrough

@Test func plainProseRoundTripsByteIdentical() {
  let input = "Just some prose.\n\nWith a second paragraph."
  #expect(TranscriptMarkup.parse(input) == [.markdown(input)])
}

@Test func emptyInputYieldsNoSegments() {
  #expect(TranscriptMarkup.parse("").isEmpty)
}

// MARK: - I3 code is sacred

@Test func fencedBlockContentIsNotTransformed() {
  let input = "before\n```\n<HARD-GATE>not a callout</HARD-GATE>\n```\nafter"
  #expect(TranscriptMarkup.parse(input) == [.markdown(input)])
}

@Test func fourBacktickFenceIsNotClosedByThreeBackticks() {
  let input = "````\n```\n<system-reminder>x</system-reminder>\n````"
  #expect(TranscriptMarkup.parse(input) == [.markdown(input)])
}

@Test func tildeFenceProtectsItsContent() {
  let input = "~~~\n<task-notification>x</task-notification>\n~~~"
  #expect(TranscriptMarkup.parse(input) == [.markdown(input)])
}

@Test func fenceIndentedUpToThreeSpacesStillOpens() {
  let input = "   ```\n<HARD-GATE>x</HARD-GATE>\n   ```"
  #expect(TranscriptMarkup.parse(input) == [.markdown(input)])
}

@Test func unterminatedFenceRunsToEndOfMessage() {
  let input = "text\n```\n<HARD-GATE>x</HARD-GATE>\nstill in the fence"
  #expect(TranscriptMarkup.parse(input) == [.markdown(input)])
}

/// MarkdownUI renders a 4-space-indented block as code, so transforming it would violate I3 from
/// the reader's point of view even though CommonMark calls it a different construct.
@Test func fourSpaceIndentedBlockIsProtected() {
  let input = "prose\n\n    <system-reminder>x</system-reminder>\n"
  #expect(TranscriptMarkup.parse(input) == [.markdown(input)])
}

@Test func inlineCodeSpanProtectsItsContent() {
  let input = "use `<HARD-GATE>` carefully"
  #expect(TranscriptMarkup.parse(input) == [.markdown(input)])
}

// MARK: - I2 no loss, as a property

@Test func rawJoinReconstructsTheInputForMixedContent() {
  let input = """
  Intro prose.

  ```swift
  let x = "<HARD-GATE>"
  ```

  Trailing prose with `inline <code>` in it.
  """
  let segments = TranscriptMarkup.parse(input)
  #expect(segments.map(\.raw).joined() == input)
}
