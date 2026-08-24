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

/// A long design brief the developer writes HIMSELF — the message most likely to contain loose ends,
/// and the one the old two-signals-flat rule dropped. It has no generated-brief opener, but it does
/// have a meta-instruction ("Do not ") and bold section labels, which was already two signals.
private let humanDesignMessage = """
Okay, here is where I want to take the sync agent, thinking out loud.

**Goal:** the agent should stop being a cron job that happens to call the ingester, and become the \
one place that knows whether a pass is healthy. Right now a hung pass looks exactly like a pass \
that never ran, and I only notice days later when the sidebar is stale.

**Constraints:** Do not add a second database for this — the spool is already the queue and I am \
not introducing another store just to track liveness. Whatever we log has to be readable with \
tail -f, because that is how I actually watch it.

We should also revisit the 300 second interval later; I picked it out of the air and never measured \
whether a shorter one costs anything. And let's go with a deadline in the agent rather than a \
launchd watchdog, since the watchdog cannot tell us WHERE it hung.

One more thing I keep forgetting: the log should say which store it opened, so a run against a \
relocated store is obvious from the log alone rather than from me guessing.
"""

@Test func keepsALongHumanDesignMessageThatMerelyReadsLikeATemplate() {
  // Regression: "Do not " + two bold labels + >=800 chars described a design brief exactly, so the
  // filter dropped the developer's own thinking-out-loud message before any loose end was mined.
  #expect(humanDesignMessage.count >= 800)
  #expect(StructuralNoiseFilter.templateSignals(in: humanDesignMessage) == 2)   // meta + headers
  #expect(!StructuralNoiseFilter.isBrief(humanDesignMessage))
  #expect(StructuralNoiseFilter.strip([msg(humanDesignMessage)]).count == 1)
}

@Test func stillStripsABriefWithNoOpenerWhenAllOtherSignalsAreThere() {
  // Without an opener the bar is three signals, not two — but a genuinely generated brief clears it.
  let generated = """
  ## Scope
  Task 3 of the organization plan.

  **Deliverable:** the migration and its test.
  Return ONLY the final diff.
  """ + String(repeating: "Context line describing the surrounding system in detail. ", count: 15)
  #expect(generated.count >= 800)
  #expect(!StructuralNoiseFilter.hasOpener(generated))
  #expect(StructuralNoiseFilter.templateSignals(in: generated) >= 3)
  #expect(StructuralNoiseFilter.strip([msg(generated)]).isEmpty)
}

@Test func keepsRealAskWrappedAroundAChecklist() {
  // Checklists are handled at candidate level, NOT here (old M4 bug).
  let message = msg("Please also do these before merge:\n- [ ] fix the flaky auth test\n- [ ] bump the deploy tag\n" +
                    "and don't forget to update the changelog.")
  #expect(StructuralNoiseFilter.strip([message]).count == 1)
}
