import Foundation
import Testing
@testable import PensieveKit

private func ev(_ id: UUID, extracted: Date? = nil) -> Event {
  Event(id: id, nodeID: UUID(), sourceID: UUID(), occurredAt: Date(),
        kind: CaptureKind.ccSession, summary: "s", detailJSON: "{}", extractedAt: extracted)
}

@Test func keyIsOrderIndependent() {
  let a = ev(UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)
  let b = ev(UUID(uuidString: "00000000-0000-0000-0000-000000000002")!)
  #expect(NarrationCacheKey.make(events: [a, b]) == NarrationCacheKey.make(events: [b, a]))
}

@Test func keyChangesWhenEventAddedOrRemoved() {
  let a = ev(UUID())
  let b = ev(UUID())
  #expect(NarrationCacheKey.make(events: [a]) != NarrationCacheKey.make(events: [a, b]))
}

@Test func keyChangesWhenExtractedAtMoves() {
  let id = UUID()
  let before = NarrationCacheKey.make(events: [ev(id, extracted: Date(timeIntervalSince1970: 100))])
  let after  = NarrationCacheKey.make(events: [ev(id, extracted: Date(timeIntervalSince1970: 200))])
  #expect(before != after)   // a re-enriched workSummary moves extractedAt -> new key
}

@Test func keyStableWithAllNilExtractedAt() {
  let id = UUID()
  let k1 = NarrationCacheKey.make(events: [ev(id)])
  let k2 = NarrationCacheKey.make(events: [ev(id)])
  #expect(k1 == k2)   // git-only node (no extractedAt) is handled, not crashing/empty
  #expect(!k1.isEmpty)
}
