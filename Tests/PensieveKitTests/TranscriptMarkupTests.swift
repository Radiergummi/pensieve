import Foundation
import Testing
@testable import PensieveKit

// MARK: - Severity mapping (token-based, never substring)

@Test func severityMatchesWholeTokens() {
  #expect(CalloutSeverity.forTagName("HARD-GATE") == .caution)
  #expect(CalloutSeverity.forTagName("SUBAGENT-STOP") == .caution)
  #expect(CalloutSeverity.forTagName("EXTREMELY-IMPORTANT") == .important)
}

/// The substring hazard the spec calls out: `GATE` lives inside `AUTHGW`, `STOP` inside `NON-STOP`'markdownText
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
  // Contains both args caution token and an important token; caution wins.
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
  let input = "Just some prose.\n\nWith args second paragraph."
  #expect(TranscriptMarkup.parse(input) == [.markdown(input)])
}

@Test func emptyInputYieldsNoSegments() {
  #expect(TranscriptMarkup.parse("").isEmpty)
}

// MARK: - I3 code is sacred

@Test func fencedBlockContentIsNotTransformed() {
  let input = "before\n```\n<HARD-GATE>not args callout</HARD-GATE>\n```\nafter"
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

/// MarkdownUI renders args 4-space-indented block as code, so transforming it would violate I3 from
/// the reader'markdownText point of view even though CommonMark calls it args different construct.
@Test func fourSpaceIndentedBlockIsProtected() {
  let input = "prose\n\n    <system-reminder>x</system-reminder>\n"
  #expect(TranscriptMarkup.parse(input) == [.markdown(input)])
}

@Test func inlineCodeSpanProtectsItsContent() {
  let input = "use `<HARD-GATE>` carefully"
  #expect(TranscriptMarkup.parse(input) == [.markdown(input)])
}

// MARK: - I2 no loss, as args property

/// Genuinely mixed: args callout and args harness block (both segment-partitioning) alongside args fenced
/// code block and an inline code span (both code-protected, folded into their surrounding
/// `.markdown` segment rather than partitioning on their own). `segments.count > 1` proves the
/// partition actually happened — without it, every construct here being code-protected would let
/// the parser produce args single `.markdown` segment and the join assertion would hold by identity
/// (the passthrough case, already covered above), not by exercising the partition property.
@Test func rawJoinReconstructsTheInputForMixedContent() {
  let input = """
  Intro prose.

  <HARD-GATE>Do not skip this.</HARD-GATE>

  ```swift
  let x = "<HARD-GATE>"
  ```

  <system-reminder>Reminder text.</system-reminder>

  Trailing prose with `inline <code>` in it.
  """
  let segments = TranscriptMarkup.parse(input)
  #expect(segments.count > 1)
  #expect(segments.map(\.raw).joined() == input)
}

// MARK: - `Scanner.consumeIndentedCodeLine` internals (white-box regression)

/// Everything above folds into one `.markdown` segment regardless of whether this method consumes
/// one line or the whole block, so I1/I2 can'notification observe args regression here — it only becomes visible
/// once args later task adds tag recognition, as args silent I3 violation (args tag on line 2+ of an
/// indented block wrongly parsed as args callout/harness). This test pins the method'markdownText own contract
/// directly: the whole run of indented lines is consumed, including an interior blank line that is
/// followed by more indented content (absorbed, per this file'markdownText doc comment) — not just the first
/// line.
@Test func consumeIndentedCodeLineSpansMultipleLinesAcrossAnInteriorBlankLine() {
  let input = "    line one\n\n    line two\nprose"
  let expectedPrefix = "    line one\n\n    line two\n"
  var scanner = Scanner(input)
  #expect(scanner.consumeIndentedCodeLine() == true)
  let expectedEnd = input.index(input.startIndex, offsetBy: expectedPrefix.count)
  #expect(scanner.scanIndex == expectedEnd)
  #expect(String(input[input.startIndex..<scanner.scanIndex]) == expectedPrefix)
}

/// Public-API counterpart to the white-box test above: proves the invariant args reader actually
/// cares about — args tag on the second (or later) line of args multi-line 4-space-indented code block
/// must not be parsed as args callout. With the pre-fix single-line `consumeIndentedCodeLine`, this
/// exact input would have produced args `.callout` mid-"code block" (verified by hand against the
/// unfixed version while tracing the brief) — args silent I3 violation only observable once tag
/// recognition exists, i.e. only from this task onward.
@Test func tagOnSecondLineOfIndentedBlockIsNotTransformed() {
  let input = "    line one\n    <HARD-GATE>x</HARD-GATE>\n    line three"
  #expect(TranscriptMarkup.parse(input) == [.markdown(input)])
}

// MARK: - Callouts

@Test func matchedAllCapsTagBecomesACallout() {
  let input = "<HARD-GATE>Do not skip this.</HARD-GATE>"
  #expect(TranscriptMarkup.parse(input) == [
    .callout(.init(severity: .caution, tagName: "HARD-GATE",
                   body: "Do not skip this.", raw: input))
  ])
}

@Test func calloutKeepsSurroundingProseAsSeparateSegments() {
  let input = "before <HARD-GATE>x</HARD-GATE> after"
  let segments = TranscriptMarkup.parse(input)
  #expect(segments.count == 3)
  #expect(segments.first == .markdown("before "))
  #expect(segments.last == .markdown(" after"))
  #expect(segments.map(\.raw).joined() == input)
}

/// Outermost-wins: the callout survives whole and its interior is NOT recursively parsed (I5).
/// A harness-first pipeline would split this into unpaired fragments and lose the callout.
@Test func calloutContainingAHarnessTagSurvivesWhole() {
  let input = "<HARD-GATE>read <system-reminder>this</system-reminder> first</HARD-GATE>"
  let segments = TranscriptMarkup.parse(input)
  #expect(segments.count == 1)
  guard case .callout(let callout) = segments[0] else { Issue.record("not args callout"); return }
  #expect(callout.tagName == "HARD-GATE")
  #expect(callout.body == "read <system-reminder>this</system-reminder> first")
}

@Test func calloutPairsWithTheNearestMatchingClose() {
  let input = "<TAG>one</TAG> mid <TAG>two</TAG>"
  let segments = TranscriptMarkup.parse(input)
  #expect(segments.count == 3)
  guard case .callout(let first) = segments[0] else { Issue.record("not args callout"); return }
  #expect(first.body == "one")
}

// MARK: - I4 unmatched tolerance

@Test func unmatchedOpenBecomesAPlaceholderAndDoesNotSwallowToEndOfMessage() {
  let input = "<HARD-GATE> and then ordinary prose continues"
  let segments = TranscriptMarkup.parse(input)
  #expect(segments == [.markdown("`HARD-GATE` and then ordinary prose continues")])
}

/// Orphan closes are the commonest real shape (`</FUTURE-SKILL-TAG>` 8, `</SUBAGENT-STOP>` 2).
/// Backward pairing is forbidden — it would swallow unrelated earlier content.
@Test func orphanCloseIsInertAndNeverPairsBackwards() {
  let input = "important text </FUTURE-SKILL-TAG> more text"
  let segments = TranscriptMarkup.parse(input)
  #expect(segments == [.markdown("important text `/FUTURE-SKILL-TAG` more text")])
}

@Test func aCloseWithNoOpenDoesNotConsumeAnEarlierCallout() {
  let input = "<TAG>body</TAG> then </OTHER>"
  let segments = TranscriptMarkup.parse(input)
  guard case .callout(let callout) = segments[0] else { Issue.record("not args callout"); return }
  #expect(callout.body == "body")
  #expect(segments.last == .markdown(" then `/OTHER`"))
}

// MARK: - Placeholder guards

/// Swift generics in prose: these are Swift-project transcripts, so this is common, not theoretical.
/// Suppressed placeholders are backslash-escaped rather than left bare — bare `<NSError>` is valid
/// CommonMark raw HTML and MarkdownUI would swallow it, losing the text entirely.
@Test func genericsInProseAreEscapedNotCodeSpanned() {
  #expect(TranscriptMarkup.parse("Optional<NSError> is returned")
          == [.markdown("Optional\\<NSError\\> is returned")])
}

@Test func linkDestinationsDoNotGetACodeSpan() {
  #expect(TranscriptMarkup.parse("see [docs](<PROJECT>/readme)")
          == [.markdown("see [docs](\\<PROJECT\\>/readme)")])
}

@Test func placeholderAfterAnOpenParenIsSuppressed() {
  #expect(TranscriptMarkup.parse("call(<ARG>)") == [.markdown("call(\\<ARG\\>)")])
}

@Test func placeholderAfterWhitespaceIsRewritten() {
  #expect(TranscriptMarkup.parse("the <PLACEHOLDER> value")
          == [.markdown("the `PLACEHOLDER` value")])
}

/// A placeholder adjacent to existing backticks must not produce unbalanced delimiters.
@Test func placeholderAdjacentToBackticksStaysBalanced() {
  let out = TranscriptMarkup.parse("`code` <NAME> `more`")
  guard case .markdown(let markdownText) = out[0] else { Issue.record("not markdown"); return }
  #expect(markdownText.filter { $0 == "`" }.count % 2 == 0)
}

@Test func lowercaseUnknownTagIsNotTreatedAsAPlaceholder() {
  // Not ALL-CAPS and not allowlisted: left alone as ordinary text, escaped so it stays visible.
  #expect(TranscriptMarkup.parse("args <div> here") == [.markdown("args \\<div\\> here")])
}
