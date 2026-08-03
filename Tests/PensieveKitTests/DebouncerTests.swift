import Foundation
import Testing
@testable import PensieveKit

private actor Counter {
  private(set) var count = 0
  func bump() { count += 1 }
  func value() -> Int { count }
}

/// A deterministic stand-in for the Debouncer's sleep. `started` counts sleep() entries
/// monotonically: because the increment and the continuation registration both happen in one
/// actor-atomic segment (before the suspension), observing `started >= k` guarantees the k-th
/// task has registered its waiter — so releaseAll() after that can never park the survivor.
/// Cancelled (superseded) sleeps resume cleanly via the cancellation handler; no leaked
/// continuations, no wall-clock timing, so these tests can't flake under a loaded pool.
private actor Gate {
  private var waiters: [(UInt64, CheckedContinuation<Void, Never>)] = []
  private var nextID: UInt64 = 0
  private(set) var started = 0

  func sleep() async {
    let id = nextID; nextID &+= 1
    started += 1
    await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in waiters.append((id, continuation)) }
    } onCancel: {
      Task { await self.cancel(id) }
    }
  }
  func releaseAll() {
    let current = waiters; waiters.removeAll()
    for (_, continuation) in current { continuation.resume() }
  }
  private func cancel(_ id: UInt64) {
    guard let index = waiters.firstIndex(where: { $0.0 == id }) else { return }
    let (_, continuation) = waiters.remove(at: index); continuation.resume()
  }
}

/// Poll a condition with a generous cap. Waits on the CONDITION (not a fixed deadline), so a slow
/// test pool only makes it take longer — it never false-fails.
private func pollUntil(_ condition: @Sendable () async -> Bool) async throws {
  for _ in 0..<2000 {                     // 2000 * 5ms = 10s cap
    if await condition() { return }
    try await Task.sleep(nanoseconds: 5_000_000)
  }
  Issue.record("pollUntil: condition never became true")
}

@Test func debouncerCoalescesRapidSchedulesIntoOneFire() async throws {
  let counter = Counter()
  let gate = Gate()
  let debouncer = Debouncer(interval: 1, sleep: { _ in await gate.sleep() }, action: { await counter.bump() })

  // Each schedule cancels the previous task; wait until the iteration-th task has actually entered its
  // sleep (started >= iteration) before issuing the next, so only the last task survives uncancelled.
  for iteration in 1...3 {
    await debouncer.schedule()
    try await pollUntil { await gate.started >= iteration }
  }
  await gate.releaseAll()                 // resumes the live task (+ any not-yet-removed cancelled ones)
  try await pollUntil { await counter.value() == 1 }
  #expect(await counter.value() == 1)     // coalesced: three schedules → one fire
}

@Test func debouncerFiresAgainAfterEachQuietPeriod() async throws {
  let counter = Counter()
  let gate = Gate()
  let debouncer = Debouncer(interval: 1, sleep: { _ in await gate.sleep() }, action: { await counter.bump() })

  await debouncer.schedule()
  try await pollUntil { await gate.started >= 1 }
  await gate.releaseAll()
  try await pollUntil { await counter.value() == 1 }

  await debouncer.schedule()
  try await pollUntil { await gate.started >= 2 }
  await gate.releaseAll()
  try await pollUntil { await counter.value() == 2 }
  #expect(await counter.value() == 2)     // two separated bursts → two fires
}
