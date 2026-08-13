import Foundation
import Testing
@testable import PensieveKit

/// The cache key must change when the fact-sheet rule changes, or prose produced under an older
/// rule keeps being served from cache and the rule change is invisible on every node whose events
/// have not moved since. The existing key already folds in `provider` for exactly this reason —
/// "a change in what produced the prose invalidates it". A change in what we FEED the model is the
/// same class of change.
@Test func cacheKeyCarriesTheFactSheetRule() {
  let event = Event(nodeID: UUID(), sourceID: UUID(), occurredAt: Date(),
                    kind: CaptureKind.gitCommit, summary: "fix: a thing", detailJSON: "{}")
  let key = NarrationCacheKey.make(events: [event], provider: "local")

  #expect(key.contains(NarrationCacheKey.factSheetRule))
  // The pre-rule format was exactly `ids|stamp|provider`. Pinning that it is no longer produced is
  // what proves every cache entry written before this change misses rather than being reused.
  #expect(key != "\(event.id.uuidString)|none|local")
}

@Test func cacheKeyStillDistinguishesEventSetsAndProviders() {
  let node = UUID(), source = UUID()
  func makeEvent(_ summary: String) -> Event {
    Event(nodeID: node, sourceID: source, occurredAt: Date(),
          kind: CaptureKind.gitCommit, summary: summary, detailJSON: "{}")
  }
  let first = makeEvent("one"), second = makeEvent("two")

  #expect(NarrationCacheKey.make(events: [first], provider: "local")
          != NarrationCacheKey.make(events: [first, second], provider: "local"))
  #expect(NarrationCacheKey.make(events: [first], provider: "local")
          != NarrationCacheKey.make(events: [first], provider: "cloud:anthropic:x"))
  // Order-independence is the property the doc comment calls out; the rule must not break it.
  #expect(NarrationCacheKey.make(events: [first, second], provider: "local")
          == NarrationCacheKey.make(events: [second, first], provider: "local"))
}
