import Foundation
import Testing
import SQLiteData
@testable import PensieveKit

@Test func narrationCacheRoundTrips() {
  let cache = NarrationCache(url: tempURL("narr"))
  cache.put("k1", prose: "the recap")
  #expect(cache.get("k1") == "the recap")
  #expect(cache.get("missing") == nil)
}

@Test func narrationCacheMissesOnChangedKey() {
  // Two different event sets / providers → different keys → the old prose does not leak.
  let e1 = Event(nodeID: UUID(), sourceID: UUID(), occurredAt: Date(), kind: CaptureKind.ccSession,
                 summary: "s", detailJSON: "{}")
  let e2 = Event(nodeID: UUID(), sourceID: UUID(), occurredAt: Date(), kind: CaptureKind.ccSession,
                 summary: "s", detailJSON: "{}")
  let kOne = NarrationCacheKey.make(events: [e1], provider: "fm")
  let kTwo = NarrationCacheKey.make(events: [e1, e2], provider: "fm")
  let kProv = NarrationCacheKey.make(events: [e1], provider: "cloud")
  let cache = NarrationCache(url: tempURL("narr"))
  cache.put(kOne, prose: "one")
  #expect(cache.get(kOne) == "one")
  #expect(cache.get(kTwo) == nil)   // event set changed → auto-invalidated
  #expect(cache.get(kProv) == nil)  // provider changed → auto-invalidated
}

@Test func narrationCacheToleratesCorruptFile() throws {
  let url = tempURL("narr")
  try "not a database".write(to: url, atomically: true, encoding: .utf8)
  let cache = NarrationCache(url: url)   // must delete + recreate, not crash
  cache.put("k", prose: "v")
  #expect(cache.get("k") == "v")
}
