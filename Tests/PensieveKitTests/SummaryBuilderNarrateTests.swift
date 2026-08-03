import Foundation
import Testing
@testable import PensieveKit

private struct FixedProvider: LLMProvider {
  let text: String
  func complete(prompt: String) async throws -> String { text }
}
private struct ThrowingProvider: LLMProvider {
  func complete(prompt: String) async throws -> String { throw LLMError.providerFailed("nope") }
}

private func sampleEvents(_ numberOfEvents: Int) -> [Event] {
  let node = UUID(), src = UUID()
  return (0..<numberOfEvents).map { index in
    Event(nodeID: node, sourceID: src, occurredAt: Date(), kind: CaptureKind.gitCommit,
          summary: "commit \(index)", detailJSON: "{}", fingerprint: "f\(index)")
  }
}

@Test func narrateReturnsTrimmedProseOnSuccess() async {
  let out = await SummaryBuilder(provider: FixedProvider(text: "  Did the auth work.\n"))
    .narrate(project: Node(name: "colibri"), events: sampleEvents(2))
  #expect(out == "Did the auth work.")   // whitespace trimmed
}

@Test func narrateReturnsNilWhenProviderThrows() async {
  let out = await SummaryBuilder(provider: ThrowingProvider())
    .narrate(project: Node(name: "colibri"), events: sampleEvents(2))
  #expect(out == nil)   // NO raw-facts substitution
}

@Test func narrateReturnsNilOnEmptyOrWhitespaceSuccess() async {
  let out = await SummaryBuilder(provider: FixedProvider(text: "   \n  "))
    .narrate(project: Node(name: "colibri"), events: sampleEvents(2))
  #expect(out == nil)   // empty header would be a fact-dump-as-prose failure
}

@Test func narrateReturnsNilForNoEvents() async {
  let out = await SummaryBuilder(provider: FixedProvider(text: "should not be used"))
    .narrate(project: Node(name: "colibri"), events: [])
  #expect(out == nil)
}
