import Foundation
import Testing
@testable import PensieveKit

private func msg(_ text: String) -> TranscriptMessage {
  TranscriptMessage(index: 0, role: "user", text: text, timestamp: nil, isUserPrompt: true)
}

/// An 800+ char generated SDD brief: opener + meta-instruction + "Task N" + headers.
private let brief = """
You are implementing Task 4 of the "Organization Foundation" plan. Read the spec first.

## Files
- Create: Sources/Foo/Bar.swift

## Steps
Do not deviate from the steps. Return ONLY the final diff.
Acceptance criteria: all tests pass.
""" + String(repeating: "Context line explaining the surrounding system in detail. ", count: 15)

@Test func stripsLongTemplateStructuredBrief() {
  #expect(brief.count >= 800)
  #expect(StructuralNoiseFilter.strip([msg(brief)]).isEmpty)
}

@Test func keepsShortDirectivesThatOpenLikeABrief() {
  // The Critical carve-out: imperative instruction to Claude IS genuine intent.
  let kept = [
    "You are absolutely right, let's fix the migration before the auth refactor.",
    "Your task is to wire up the webhook, forget the refactor.",
    "You are implementing #2 first, then stop.",
    "High-scrutiny review please — does the token exchange look right?",
  ].map(msg)
  #expect(StructuralNoiseFilter.strip(kept).count == kept.count)
}

@Test func keepsLongHumanProseWithoutTemplateStructure() {
  // Long but only ONE signal (no meta/Task/headers) → not a brief.
  let longProse = "You are reviewing " + String(repeating: "my reasoning about the caching layer and whether it is sound. ", count: 20)
  #expect(longProse.count >= 800)
  #expect(StructuralNoiseFilter.strip([msg(longProse)]).count == 1)
}

@Test func keepsRealAskWrappedAroundAChecklist() {
  // Checklists are handled at candidate level, NOT here (old M4 bug).
  let message = msg("Please also do these before merge:\n- [ ] fix the flaky auth test\n- [ ] bump the deploy tag\n" +
                    "and don't forget to update the changelog.")
  #expect(StructuralNoiseFilter.strip([message]).count == 1)
}
