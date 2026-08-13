import Foundation
import Testing
@testable import PensieveKit

/// Counts its calls so a test can assert the provider was never reached. The whole point of
/// filtering the fact sheet on the INPUT side is that a node with nothing to narrate costs no
/// model call at all — so that claim is asserted, not assumed.
private final class CountingProvider: LLMProvider, @unchecked Sendable {
  private(set) var callCount = 0
  func complete(prompt: String) async throws -> String {
    callCount += 1
    return "some prose"
  }
}

private let node = UUID(), source = UUID()

private func event(kind: String, summary: String, workSummary: String? = nil) -> Event {
  Event(nodeID: node, sourceID: source, occurredAt: Date(), kind: kind,
        summary: summary, detailJSON: "{}", fingerprint: UUID().uuidString,
        workSummary: workSummary)
}

// MARK: - narratableContent: the single definition of what may enter a fact sheet

@Test func gitCommitSummaryIsNarratableBecauseItIsTheCommitSubject() {
  let commit = event(kind: CaptureKind.gitCommit, summary: "fix: the drain no longer stalls")
  #expect(SummaryBuilder.narratableContent(for: commit) == "fix: the drain no longer stalls")
}

@Test func sessionWithWorkSummaryIsNarratable() {
  let session = event(kind: CaptureKind.ccSession, summary: "session (11 prompts)",
                      workSummary: "Reworked the ingest dedup path.")
  #expect(SummaryBuilder.narratableContent(for: session) == "Reworked the ingest dedup path.")
}

@Test func sessionWithoutWorkSummaryIsNotNarratable() {
  // `Ingester.swift:168` always writes "session (N prompts)" — a count Pensieve generated, not a
  // fact about the work. Narrating it produced the "included 41, 54, 107 ... and 1 prompts" recap.
  let session = event(kind: CaptureKind.ccSession, summary: "session (11 prompts)")
  #expect(SummaryBuilder.narratableContent(for: session) == nil)
}

@Test func checkoutIsNeverNarratable() {
  // `Ingester.swift:121` always writes "checkout <branch>". `EmbeddableCorpus.gather` already
  // drops these as corpus hygiene; the narrator's fact sheet did not.
  let checkout = event(kind: CaptureKind.gitCheckout, summary: "checkout HEAD")
  #expect(SummaryBuilder.narratableContent(for: checkout) == nil)
}

@Test func emptyWorkSummaryFallsThroughRatherThanNarratingBlank() {
  let session = event(kind: CaptureKind.ccSession, summary: "session (3 prompts)", workSummary: "")
  #expect(SummaryBuilder.narratableContent(for: session) == nil)
}

@Test func checkoutWithAWorkSummaryIsNarratable() {
  // No such row exists today (364 of 364 checkouts lack one), but the rule is "has real content",
  // not "is a commit" — a future enricher must not be silently ignored.
  let checkout = event(kind: CaptureKind.gitCheckout, summary: "checkout main",
                       workSummary: "Switched to main to cut the release.")
  #expect(SummaryBuilder.narratableContent(for: checkout) == "Switched to main to cut the release.")
}

// MARK: - assembleFacts drops the noise and keeps the rest

@Test func assembleFactsOmitsNonNarratableEvents() {
  let events = [
    event(kind: CaptureKind.gitCheckout, summary: "checkout HEAD"),
    event(kind: CaptureKind.gitCommit, summary: "feat: add the burn-down queue"),
    event(kind: CaptureKind.ccSession, summary: "session (41 prompts)"),
  ]
  let facts = SummaryBuilder.assembleFacts(project: Node(name: "pensieve"), events: events)
  #expect(facts.contains("feat: add the burn-down queue"))
  #expect(!facts.contains("checkout HEAD"))
  #expect(!facts.contains("41 prompts"))
}

@Test func assembleFactsKeepsTheProjectNameEvenWithNothingToNarrate() {
  let facts = SummaryBuilder.assembleFacts(
    project: Node(name: "pensieve"),
    events: [event(kind: CaptureKind.gitCheckout, summary: "checkout HEAD")])
  #expect(facts.contains("pensieve"))
}

@Test func filteredEventsDoNotConsumeTheCharBudget() {
  // Fourteen fat checkout lines inside the 15-event window sum well past the 1800-char budget, so
  // the old code broke out of the loop before reaching the commit — the noise starved the signal.
  // Filtered lines must not compete for the budget at all.
  let fatBranch = String(repeating: "a", count: 200)
  var events = (0..<14).map { _ in
    event(kind: CaptureKind.gitCheckout, summary: "checkout \(fatBranch)")
  }
  events.append(event(kind: CaptureKind.gitCommit, summary: "fix: the one line that matters"))
  #expect(events.count == 15)   // entirely inside the recency window; only the budget is at stake
  let facts = SummaryBuilder.assembleFacts(project: Node(name: "pensieve"), events: events)
  #expect(facts.contains("fix: the one line that matters"))
}

// MARK: - narrate skips the provider entirely when there is nothing to say

@Test func narrateReturnsNilAndSpendsNoModelCallWhenNoEventIsNarratable() async {
  let provider = CountingProvider()
  let out = await SummaryBuilder(provider: provider).narrate(
    project: Node(name: "pensieve"),
    events: [
      event(kind: CaptureKind.gitCheckout, summary: "checkout HEAD"),
      event(kind: CaptureKind.ccSession, summary: "session (41 prompts)"),
    ])
  #expect(out == nil)
  #expect(provider.callCount == 0)   // the cost claim, asserted
}

@Test func narrateStillNarratesWhenOnlySomeEventsAreNarratable() async {
  let provider = CountingProvider()
  let out = await SummaryBuilder(provider: provider).narrate(
    project: Node(name: "pensieve"),
    events: [
      event(kind: CaptureKind.gitCheckout, summary: "checkout HEAD"),
      event(kind: CaptureKind.gitCommit, summary: "feat: real work"),
    ])
  #expect(out == "some prose")
  #expect(provider.callCount == 1)
}
