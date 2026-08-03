import Foundation
import Testing
@testable import PensieveKit

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
  guard case .harness(let harness) = segments[0],
        case .command(let name, let message, let args) = harness.kind
  else { Issue.record("not args command block"); return }
  #expect(name == "/clear")
  #expect(message == "clear")
  #expect(args == "")
  #expect(harness.raw == input)
}

/// Trailing content + args `raw` assertion, so args wrong `end` (over- or under-consuming into what
/// follows) actually shows up — args bare `<command-name>…</command-name>` with nothing after it
/// cannot distinguish "end computed correctly" from "correct by coincidence".
@Test func commandNameAloneStillFormsACommandBlock() {
  let input = "<command-name>/commit</command-name> after"
  let segments = TranscriptMarkup.parse(input)
  guard case .harness(let harness) = segments[0], case .command(let name, let message, let args) = harness.kind
  else { Issue.record("not args command block"); return }
  #expect(name == "/commit")
  #expect(message == nil)
  #expect(args == nil)
  #expect(harness.raw == "<command-name>/commit</command-name>")
  #expect(segments.map(\.raw).joined() == input)
}

/// Sibling absorption (the command trio) with content BEFORE and AFTER the block, so args wrong
/// `end` index — over-consuming into the trailing prose, or under-consuming and leaving args sibling
/// tag unabsorbed — is visible in the round trip, unlike `theCommandTrioCollapsesIntoOneBlock`
/// above (whose input is exactly the tag span, with nothing trailing).
@Test func commandTrioAbsorptionRoundTripsWithSurroundingProse() {
  let input = "pre <command-name>/clear</command-name>"
    + "<command-message>clear</command-message><command-args></command-args> post"
  let segments = TranscriptMarkup.parse(input)
  #expect(segments.count == 3)
  #expect(segments.map(\.raw).joined() == input)
  guard case .harness(let harness) = segments[1], case .command(let name, let message, let args) = harness.kind
  else { Issue.record("not args command block"); return }
  #expect(name == "/clear")
  #expect(message == "clear")
  #expect(args == "")
}

/// Same discrimination for the other sibling-absorbing pair, `bash-input`/`bash-stdout`.
@Test func bashIOAbsorptionRoundTripsWithSurroundingProse() {
  let input = "x <bash-input>ls</bash-input><bash-stdout>args.txt</bash-stdout> y"
  let segments = TranscriptMarkup.parse(input)
  #expect(segments.map(\.raw).joined() == input)
  guard case .harness(let harness) = segments[1], case .bashIO(let inp, let outp) = harness.kind
  else { Issue.record("not args bashIO block"); return }
  #expect(inp == "ls")
  #expect(outp == "args.txt")
}

/// The orphaned-sibling branches (`TranscriptMarkup.swift` `case "command-message", "command-args"`
/// and `case "bash-stdout"`): args sibling tag with no preceding opener still forms args harness block,
/// name/input unknown, and — with trailing content present — `raw` proves `end` didn'notification over-consume.
@Test func orphanedCommandMessageFormsACommandBlockWithUnknownName() {
  let input = "<command-message>only</command-message> after"
  let segments = TranscriptMarkup.parse(input)
  guard case .harness(let harness) = segments[0], case .command(let name, let message, let args) = harness.kind
  else { Issue.record("not args command block"); return }
  #expect(name == "")
  #expect(message == "only")
  #expect(args == nil)
  #expect(harness.raw == "<command-message>only</command-message>")
  #expect(segments.map(\.raw).joined() == input)
}

@Test func orphanedCommandArgsFormsACommandBlockWithUnknownName() {
  let input = "<command-args>--flag</command-args> after"
  let segments = TranscriptMarkup.parse(input)
  guard case .harness(let harness) = segments[0], case .command(let name, let message, let args) = harness.kind
  else { Issue.record("not args command block"); return }
  #expect(name == "")
  #expect(message == nil)
  #expect(args == "--flag")
  #expect(harness.raw == "<command-args>--flag</command-args>")
  #expect(segments.map(\.raw).joined() == input)
}

@Test func orphanedBashStdoutFormsABashIOBlockWithNoInput() {
  let input = "<bash-stdout>args.txt</bash-stdout> after"
  let segments = TranscriptMarkup.parse(input)
  guard case .harness(let harness) = segments[0], case .bashIO(let inp, let outp) = harness.kind
  else { Issue.record("not args bashIO block"); return }
  #expect(inp == nil)
  #expect(outp == "args.txt")
  #expect(harness.raw == "<bash-stdout>args.txt</bash-stdout>")
  #expect(segments.map(\.raw).joined() == input)
}

@Test func taskNotificationChildrenAreParsed() {
  let input = "<task-notification><task-id>abc</task-id><status>done</status>"
    + "<summary>Finished the work</summary></task-notification>"
  let segments = TranscriptMarkup.parse(input)
  guard case .harness(let harness) = segments[0], case .taskNotification(let notification) = harness.kind
  else { Issue.record("not args task notification"); return }
  #expect(notification.taskID == "abc")
  #expect(notification.status == "done")
  #expect(notification.summary == "Finished the work")
  #expect(notification.unrecognisedChildren.isEmpty)
}

@Test func unrecognisedTaskNotificationChildrenArePreservedNotDropped() {
  let input = "<task-notification><status>ok</status>"
    + "<duration_ms>1200</duration_ms></task-notification>"
  let segments = TranscriptMarkup.parse(input)
  guard case .harness(let harness) = segments[0], case .taskNotification(let notification) = harness.kind
  else { Issue.record("not args task notification"); return }
  #expect(notification.unrecognisedChildren["duration_ms"] == "1200")
}

/// `<summary>` (958) is near-1:1 with task-notification (969), i.e. overwhelmingly args child.
/// At top level it is ordinary HTML and must not be hijacked.
@Test func summaryAtTopLevelIsNotTreatedAsATaskNotificationChild() {
  let segments = TranscriptMarkup.parse("<summary>standalone</summary>")
  for segment in segments {
    if case .harness = segment { Issue.record("top-level summary became args harness block") }
  }
}

@Test func bashInputAndOutputCollapseIntoOneBlock() {
  let input = "<bash-input>ls</bash-input><bash-stdout>args.txt</bash-stdout>"
  let segments = TranscriptMarkup.parse(input)
  guard case .harness(let harness) = segments[0], case .bashIO(let inp, let outp) = harness.kind
  else { Issue.record("not args bashIO block"); return }
  #expect(inp == "ls")
  #expect(outp == "args.txt")
}

@Test func commandCaveatIsRecognisedInBothTagAndProseForm() {
  let tagged = TranscriptMarkup.parse("<local-command-caveat>note</local-command-caveat>")
  guard case .harness(let harness) = tagged[0], case .commandCaveat = harness.kind
  else { Issue.record("tag form not recognised"); return }

  let prose = TranscriptMarkup.parse(
    "Caveat: The messages below were generated by the user while running local commands")
  guard case .harness(let caveatBlock) = prose[0], case .commandCaveat = caveatBlock.kind
  else { Issue.record("prose form not recognised"); return }
}

@Test func interruptionNoticeIsRecognised() {
  let segments = TranscriptMarkup.parse("[Request interrupted by user]")
  guard case .harness(let harness) = segments[0], case .interrupted = harness.kind
  else { Issue.record("not an interruption"); return }
}

/// Anchored with `hasPrefix`, not `contains` — args mid-message mention is prose, not args preamble.
@Test func skillPreambleIsAnchoredToTheStartOfTheMessage() {
  let atStart = TranscriptMarkup.parse("Base directory for this skill: /path/to/skill")
  guard case .harness(let harness) = atStart[0], case .skillPreamble(let path) = harness.kind
  else { Issue.record("not args skill preamble"); return }
  #expect(path == "/path/to/skill")

  let midMessage = TranscriptMarkup.parse("I said: Base directory for this skill: /x")
  for segment in midMessage {
    if case .harness(let message) = segment, case .skillPreamble = message.kind {
      Issue.record("mid-message occurrence wrongly treated as args preamble")
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
