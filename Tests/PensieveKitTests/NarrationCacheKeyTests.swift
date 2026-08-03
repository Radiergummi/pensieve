import Foundation
import Testing
@testable import PensieveKit

private func event(_ id: UUID, extracted: Date? = nil) -> Event {
  Event(id: id, nodeID: UUID(), sourceID: UUID(), occurredAt: Date(),
        kind: CaptureKind.ccSession, summary: "s", detailJSON: "{}", extractedAt: extracted)
}

@Test func keyIsOrderIndependent() {
  let eventFirst = event(UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)
  let eventSecond = event(UUID(uuidString: "00000000-0000-0000-0000-000000000002")!)
  #expect(NarrationCacheKey.make(events: [eventFirst, eventSecond]) == NarrationCacheKey.make(events: [eventSecond, eventFirst]))
}

@Test func keyChangesWhenEventAddedOrRemoved() {
  let eventFirst = event(UUID())
  let eventSecond = event(UUID())
  #expect(NarrationCacheKey.make(events: [eventFirst]) != NarrationCacheKey.make(events: [eventFirst, eventSecond]))
}

@Test func keyChangesWhenExtractedAtMoves() {
  let id = UUID()
  let before = NarrationCacheKey.make(events: [event(id, extracted: Date(timeIntervalSince1970: 100))])
  let after  = NarrationCacheKey.make(events: [event(id, extracted: Date(timeIntervalSince1970: 200))])
  #expect(before != after)   // a re-enriched workSummary moves extractedAt -> new key
}

@Test func keyStableWithAllNilExtractedAt() {
  let id = UUID()
  let keyFirst = NarrationCacheKey.make(events: [event(id)])
  let keySecond = NarrationCacheKey.make(events: [event(id)])
  #expect(keyFirst == keySecond)   // git-only node (no extractedAt) is handled, not crashing/empty
  #expect(!keyFirst.isEmpty)
}

@Test func keyChangesWhenProviderChanges() {
  let events = [event(UUID())]
  #expect(NarrationCacheKey.make(events: events, provider: "claudeCLI")
          != NarrationCacheKey.make(events: events, provider: "foundationModels"))
}
