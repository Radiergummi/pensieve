import Foundation
import Testing
@testable import PensieveKit

private func event(_ id: UUID, extracted: Date? = nil) -> Event {
  Event(id: id, nodeID: UUID(), sourceID: UUID(), occurredAt: Date(),
        kind: CaptureKind.ccSession, summary: "s", detailJSON: "{}", extractedAt: extracted)
}

@Test func keyIsOrderIndependent() {
  let a = event(UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)
  let b = event(UUID(uuidString: "00000000-0000-0000-0000-000000000002")!)
  #expect(NarrationCacheKey.make(events: [a, b]) == NarrationCacheKey.make(events: [b, a]))
}

@Test func keyChangesWhenEventAddedOrRemoved() {
  let a = event(UUID())
  let b = event(UUID())
  #expect(NarrationCacheKey.make(events: [a]) != NarrationCacheKey.make(events: [a, b]))
}

@Test func keyChangesWhenExtractedAtMoves() {
  let id = UUID()
  let before = NarrationCacheKey.make(events: [event(id, extracted: Date(timeIntervalSince1970: 100))])
  let after  = NarrationCacheKey.make(events: [event(id, extracted: Date(timeIntervalSince1970: 200))])
  #expect(before != after)   // a re-enriched workSummary moves extractedAt -> new key
}

@Test func keyStableWithAllNilExtractedAt() {
  let id = UUID()
  let k1 = NarrationCacheKey.make(events: [event(id)])
  let k2 = NarrationCacheKey.make(events: [event(id)])
  #expect(k1 == k2)   // git-only node (no extractedAt) is handled, not crashing/empty
  #expect(!k1.isEmpty)
}

@Test func keyChangesWhenProviderChanges() {
  let e = [event(UUID())]
  #expect(NarrationCacheKey.make(events: e, provider: "claudeCLI")
          != NarrationCacheKey.make(events: e, provider: "foundationModels"))
}
