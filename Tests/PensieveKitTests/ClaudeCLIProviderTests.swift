import Foundation
import Testing
@testable import PensieveKit

@Test func claudeProviderUsesInjectedRunner() async throws {
  let provider = ClaudeCLIProvider(run: { prompt in "echo: \(prompt)" })
  let out = try await provider.complete(prompt: "hello")
  #expect(out == "echo: hello")
}

@Test func claudeProviderPropagatesRunnerError() async throws {
  let provider = ClaudeCLIProvider(run: { _ in throw LLMError.providerFailed("boom") })
  await #expect(throws: LLMError.self) {
    try await provider.complete(prompt: "hello")
  }
}

// MARK: - Cancellation reaches the child

@Test func theSlotTerminatesAnAdoptedChildAndRefusesOneSpawnedAfterCancellation() throws {
  // `narrateWithin(3.0)` returning after 3 s used to leave `claude -p` running to its 120 s cap:
  // cancelling a Swift Task does nothing to a Process. The slot is the handle that closes that gap,
  // including the race where cancellation lands while the child is still being spawned.
  let slot = ChildProcessSlot()
  let child = Process()
  child.executableURL = URL(fileURLWithPath: "/bin/sh")
  child.arguments = ["-c", "sleep 30"]
  try child.run()
  #expect(slot.adopt(child))
  #expect(!slot.wasCancelled)

  slot.cancel()
  // BOUNDED wait, deliberately: a terminated child is gone in milliseconds, while an un-terminated
  // one runs its full 30 s — which is the bug itself. An unbounded `waitUntilExit()` here would pass
  // either way (mutation-checked: it did, in 30 s instead of 0.03 s), so it must be a deadline.
  let deadline = Date().addingTimeInterval(3)
  while child.isRunning, Date() < deadline { usleep(20_000) }
  #expect(!child.isRunning)
  #expect(slot.wasCancelled)
  if child.isRunning { child.terminate() }   // never leave a stray child behind on failure

  // Cancelled first ⇒ a child spawned afterwards is refused, so the caller kills it immediately
  // rather than running a call nobody is waiting for.
  let cancelledFirst = ChildProcessSlot()
  cancelledFirst.cancel()
  #expect(!cancelledFirst.adopt(Process()))
}

@Test func cancellingTheTaskSurfacesCancellationRatherThanARunnerResult() async {
  // The provider's own cancellation check: a Task already cancelled must not spawn at all.
  let provider = ClaudeCLIProvider(run: { _ in "should never run" })
  let task = Task {
    while !Task.isCancelled { await Task.yield() }
    return try await provider.complete(prompt: "hello")
  }
  task.cancel()
  await #expect(throws: CancellationError.self) { try await task.value }
}
