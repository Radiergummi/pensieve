import Foundation
import Testing
@testable import PensieveKit

@Test func markdownSegmentIsFindableAsItsText() {
  #expect(TranscriptSegment.markdown("fix the sync gap").findableText == "fix the sync gap")
}

@Test func calloutIsFindableByBodyNotByItsTagName() {
  // The tag name renders as chrome beside a localized severity label, not as prose.
  let callout = TranscriptCallout(severity: .caution, tagName: "HARD-GATE",
                                  body: "do not skip the gate", raw: "<HARD-GATE>…</HARD-GATE>")
  #expect(TranscriptSegment.callout(callout).findableText == "do not skip the gate")
}

@Test func harnessIsFindableByItsDisplayedBody() {
  let block = HarnessBlock(kind: .systemReminder("the store moved"), raw: "<system-reminder>…")
  #expect(TranscriptSegment.harness(block).findableText == "the store moved")
}

@Test func interruptedHarnessContributesNoFindableText() {
  let block = HarnessBlock(kind: .interrupted, raw: "[Request interrupted")
  #expect(TranscriptSegment.harness(block).findableText == nil)
}

@Test func findableTextNeverExposesRawMarkup() {
  // `raw` is the exact source substring (the no-loss invariant), so indexing it would match tag
  // markup the app never displays and inflate the match count.
  let block = HarnessBlock(kind: .systemReminder("body only"),
                           raw: "<system-reminder>body only</system-reminder>")
  let findable = TranscriptSegment.harness(block).findableText
  #expect(findable == "body only")
  #expect(!(findable ?? "").contains("system-reminder"))
}

@Test func taskNotificationIsFindableBySummaryAndStatus() {
  let notification = TaskNotificationBlock(taskID: "t1", toolUseID: "u1", outputFile: "out.txt",
                                           status: "completed", summary: "reviewed the spec",
                                           note: "a note", unrecognisedChildren: ["extra": "x"])
  let findable = TranscriptSegment.harness(
    HarnessBlock(kind: .taskNotification(notification), raw: "<task-notification>…")).findableText
  #expect(findable == "reviewed the spec · completed")
  // Unmodelled children are lossless in the PARSE but never rendered, so never findable.
  #expect(!(findable ?? "").contains("x"))
}
