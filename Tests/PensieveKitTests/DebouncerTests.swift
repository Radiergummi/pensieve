import Foundation
import Testing
@testable import PensieveKit

@Test func debouncerCoalescesRapidCallsIntoOneTrailingFire() async throws {
  actor Counter { var n = 0; func bump() { n += 1 }; func value() -> Int { n } }
  let counter = Counter()
  let d = Debouncer(interval: 0.1) { await counter.bump() }
  for _ in 0..<5 { await d.schedule() }          // 5 rapid calls within the window
  try await Task.sleep(nanoseconds: 300_000_000) // 0.3 s > interval
  #expect(await counter.value() == 1)             // coalesced to a single trailing fire
}

@Test func debouncerFiresAgainAfterQuietPeriod() async throws {
  actor Counter { var n = 0; func bump() { n += 1 }; func value() -> Int { n } }
  let counter = Counter()
  let d = Debouncer(interval: 0.1) { await counter.bump() }
  await d.schedule()
  try await Task.sleep(nanoseconds: 250_000_000)
  await d.schedule()
  try await Task.sleep(nanoseconds: 250_000_000)
  #expect(await counter.value() == 2)             // two separated bursts → two fires
}
