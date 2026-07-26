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

/// Genuinely mixed: a callout and a harness block (both segment-partitioning) alongside a fenced
/// code block and an inline code span (both code-protected, folded into their surrounding
/// `.markdown` segment rather than partitioning on their own). `segments.count > 1` proves the
/// partition actually happened — without it, every construct here being code-protected would let
/// the parser produce a single `.markdown` segment and the join assertion would hold by identity
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
/// one line or the whole block, so I1/I2 can't observe a regression here — it only becomes visible
/// once a later task adds tag recognition, as a silent I3 violation (a tag on line 2+ of an
/// indented block wrongly parsed as a callout/harness). This test pins the method's own contract
/// directly: the whole run of indented lines is consumed, including an interior blank line that is
/// followed by more indented content (absorbed, per this file's doc comment) — not just the first
/// line.
@Test func consumeIndentedCodeLineSpansMultipleLinesAcrossAnInteriorBlankLine() {
  let input = "    line one\n\n    line two\nprose"
  let expectedPrefix = "    line one\n\n    line two\n"
  var scanner = Scanner(input)
  #expect(scanner.consumeIndentedCodeLine() == true)
  let expectedEnd = input.index(input.startIndex, offsetBy: expectedPrefix.count)
  #expect(scanner.i == expectedEnd)
  #expect(String(input[input.startIndex..<scanner.i]) == expectedPrefix)
}

/// Public-API counterpart to the white-box test above: proves the invariant a reader actually
/// cares about — a tag on the second (or later) line of a multi-line 4-space-indented code block
/// must not be parsed as a callout. With the pre-fix single-line `consumeIndentedCodeLine`, this
/// exact input would have produced a `.callout` mid-"code block" (verified by hand against the
/// unfixed version while tracing the brief) — a silent I3 violation only observable once tag
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
  guard case .callout(let c) = segments[0] else { Issue.record("not a callout"); return }
  #expect(c.tagName == "HARD-GATE")
  #expect(c.body == "read <system-reminder>this</system-reminder> first")
}

@Test func calloutPairsWithTheNearestMatchingClose() {
  let input = "<TAG>one</TAG> mid <TAG>two</TAG>"
  let segments = TranscriptMarkup.parse(input)
  #expect(segments.count == 3)
  guard case .callout(let first) = segments[0] else { Issue.record("not a callout"); return }
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
  guard case .callout(let c) = segments[0] else { Issue.record("not a callout"); return }
  #expect(c.body == "body")
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
  guard case .markdown(let s) = out[0] else { Issue.record("not markdown"); return }
  #expect(s.filter { $0 == "`" }.count % 2 == 0)
}

@Test func lowercaseUnknownTagIsNotTreatedAsAPlaceholder() {
  // Not ALL-CAPS and not allowlisted: left alone as ordinary text, escaped so it stays visible.
  #expect(TranscriptMarkup.parse("a <div> here") == [.markdown("a \\<div\\> here")])
}

// MARK: - Harness blocks

@Test func systemReminderBecomesAHarnessBlock() {
  let input = "<system-reminder>Do the thing.</system-reminder>"
  #expect(TranscriptMarkup.parse(input) == [
    .harness(.init(kind: .systemReminder("Do the thing."), raw: input))
  ])
}

@Test func theCommandTrioCollapsesIntoOneBlock() {
  let input = "<command-name>/clear</command-name>"
    + "<command-message>clear</command-message><command-args></command-args>"
  let segments = TranscriptMarkup.parse(input)
  #expect(segments.count == 1)
  guard case .harness(let h) = segments[0],
        case .command(let name, let message, let args) = h.kind
  else { Issue.record("not a command block"); return }
  #expect(name == "/clear")
  #expect(message == "clear")
  #expect(args == "")
  #expect(h.raw == input)
}

/// Trailing content + a `raw` assertion, so a wrong `end` (over- or under-consuming into what
/// follows) actually shows up — a bare `<command-name>…</command-name>` with nothing after it
/// cannot distinguish "end computed correctly" from "correct by coincidence".
@Test func commandNameAloneStillFormsACommandBlock() {
  let input = "<command-name>/commit</command-name> after"
  let segments = TranscriptMarkup.parse(input)
  guard case .harness(let h) = segments[0], case .command(let name, let m, let a) = h.kind
  else { Issue.record("not a command block"); return }
  #expect(name == "/commit")
  #expect(m == nil)
  #expect(a == nil)
  #expect(h.raw == "<command-name>/commit</command-name>")
  #expect(segments.map(\.raw).joined() == input)
}

/// Sibling absorption (the command trio) with content BEFORE and AFTER the block, so a wrong
/// `end` index — over-consuming into the trailing prose, or under-consuming and leaving a sibling
/// tag unabsorbed — is visible in the round trip, unlike `theCommandTrioCollapsesIntoOneBlock`
/// above (whose input is exactly the tag span, with nothing trailing).
@Test func commandTrioAbsorptionRoundTripsWithSurroundingProse() {
  let input = "pre <command-name>/clear</command-name>"
    + "<command-message>clear</command-message><command-args></command-args> post"
  let segments = TranscriptMarkup.parse(input)
  #expect(segments.count == 3)
  #expect(segments.map(\.raw).joined() == input)
  guard case .harness(let h) = segments[1], case .command(let name, let message, let args) = h.kind
  else { Issue.record("not a command block"); return }
  #expect(name == "/clear")
  #expect(message == "clear")
  #expect(args == "")
}

/// Same discrimination for the other sibling-absorbing pair, `bash-input`/`bash-stdout`.
@Test func bashIOAbsorptionRoundTripsWithSurroundingProse() {
  let input = "x <bash-input>ls</bash-input><bash-stdout>a.txt</bash-stdout> y"
  let segments = TranscriptMarkup.parse(input)
  #expect(segments.map(\.raw).joined() == input)
  guard case .harness(let h) = segments[1], case .bashIO(let inp, let outp) = h.kind
  else { Issue.record("not a bashIO block"); return }
  #expect(inp == "ls")
  #expect(outp == "a.txt")
}

/// The orphaned-sibling branches (`TranscriptMarkup.swift` `case "command-message", "command-args"`
/// and `case "bash-stdout"`): a sibling tag with no preceding opener still forms a harness block,
/// name/input unknown, and — with trailing content present — `raw` proves `end` didn't over-consume.
@Test func orphanedCommandMessageFormsACommandBlockWithUnknownName() {
  let input = "<command-message>only</command-message> after"
  let segments = TranscriptMarkup.parse(input)
  guard case .harness(let h) = segments[0], case .command(let name, let message, let args) = h.kind
  else { Issue.record("not a command block"); return }
  #expect(name == "")
  #expect(message == "only")
  #expect(args == nil)
  #expect(h.raw == "<command-message>only</command-message>")
  #expect(segments.map(\.raw).joined() == input)
}

@Test func orphanedCommandArgsFormsACommandBlockWithUnknownName() {
  let input = "<command-args>--flag</command-args> after"
  let segments = TranscriptMarkup.parse(input)
  guard case .harness(let h) = segments[0], case .command(let name, let message, let args) = h.kind
  else { Issue.record("not a command block"); return }
  #expect(name == "")
  #expect(message == nil)
  #expect(args == "--flag")
  #expect(h.raw == "<command-args>--flag</command-args>")
  #expect(segments.map(\.raw).joined() == input)
}

@Test func orphanedBashStdoutFormsABashIOBlockWithNoInput() {
  let input = "<bash-stdout>a.txt</bash-stdout> after"
  let segments = TranscriptMarkup.parse(input)
  guard case .harness(let h) = segments[0], case .bashIO(let inp, let outp) = h.kind
  else { Issue.record("not a bashIO block"); return }
  #expect(inp == nil)
  #expect(outp == "a.txt")
  #expect(h.raw == "<bash-stdout>a.txt</bash-stdout>")
  #expect(segments.map(\.raw).joined() == input)
}

@Test func taskNotificationChildrenAreParsed() {
  let input = "<task-notification><task-id>abc</task-id><status>done</status>"
    + "<summary>Finished the work</summary></task-notification>"
  let segments = TranscriptMarkup.parse(input)
  guard case .harness(let h) = segments[0], case .taskNotification(let t) = h.kind
  else { Issue.record("not a task notification"); return }
  #expect(t.taskID == "abc")
  #expect(t.status == "done")
  #expect(t.summary == "Finished the work")
  #expect(t.unrecognisedChildren.isEmpty)
}

@Test func unrecognisedTaskNotificationChildrenArePreservedNotDropped() {
  let input = "<task-notification><status>ok</status>"
    + "<duration_ms>1200</duration_ms></task-notification>"
  let segments = TranscriptMarkup.parse(input)
  guard case .harness(let h) = segments[0], case .taskNotification(let t) = h.kind
  else { Issue.record("not a task notification"); return }
  #expect(t.unrecognisedChildren["duration_ms"] == "1200")
}

/// `<summary>` (958) is near-1:1 with task-notification (969), i.e. overwhelmingly a child.
/// At top level it is ordinary HTML and must not be hijacked.
@Test func summaryAtTopLevelIsNotTreatedAsATaskNotificationChild() {
  let segments = TranscriptMarkup.parse("<summary>standalone</summary>")
  for segment in segments {
    if case .harness = segment { Issue.record("top-level summary became a harness block") }
  }
}

@Test func bashInputAndOutputCollapseIntoOneBlock() {
  let input = "<bash-input>ls</bash-input><bash-stdout>a.txt</bash-stdout>"
  let segments = TranscriptMarkup.parse(input)
  guard case .harness(let h) = segments[0], case .bashIO(let inp, let outp) = h.kind
  else { Issue.record("not a bashIO block"); return }
  #expect(inp == "ls")
  #expect(outp == "a.txt")
}

@Test func commandCaveatIsRecognisedInBothTagAndProseForm() {
  let tagged = TranscriptMarkup.parse("<local-command-caveat>note</local-command-caveat>")
  guard case .harness(let h) = tagged[0], case .commandCaveat = h.kind
  else { Issue.record("tag form not recognised"); return }

  let prose = TranscriptMarkup.parse(
    "Caveat: The messages below were generated by the user while running local commands")
  guard case .harness(let p) = prose[0], case .commandCaveat = p.kind
  else { Issue.record("prose form not recognised"); return }
}

@Test func interruptionNoticeIsRecognised() {
  let segments = TranscriptMarkup.parse("[Request interrupted by user]")
  guard case .harness(let h) = segments[0], case .interrupted = h.kind
  else { Issue.record("not an interruption"); return }
}

/// Anchored with `hasPrefix`, not `contains` — a mid-message mention is prose, not a preamble.
@Test func skillPreambleIsAnchoredToTheStartOfTheMessage() {
  let atStart = TranscriptMarkup.parse("Base directory for this skill: /path/to/skill")
  guard case .harness(let h) = atStart[0], case .skillPreamble(let path) = h.kind
  else { Issue.record("not a skill preamble"); return }
  #expect(path == "/path/to/skill")

  let midMessage = TranscriptMarkup.parse("I said: Base directory for this skill: /x")
  for segment in midMessage {
    if case .harness(let m) = segment, case .skillPreamble = m.kind {
      Issue.record("mid-message occurrence wrongly treated as a preamble")
    }
  }
}

@Test func harnessBlocksPreserveTheNoLossPropertyAlongsideProse() {
  let input = "before <system-reminder>x</system-reminder> after"
  #expect(TranscriptMarkup.parse(input).map(\.raw).joined() == input)
}

@Test func aTagOnlyMessageYieldsExactlyOneSegment() {
  #expect(TranscriptMarkup.parse("<system-reminder>x</system-reminder>").count == 1)
}
