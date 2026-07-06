import Foundation

/// Trailing-edge coalescer: rapid `schedule()` calls collapse into a single `action` run, fired
/// `interval` seconds after the last call. Used to coalesce the liveness signals (ValueObservation
/// + two FSEvents watches) into one refresh. Actor-isolated; the action runs on a detached Task.
///
/// `sleep` is injectable purely so tests can drive coalescing deterministically without racing the
/// wall clock; production uses the default (a cancellation-aware `Task.sleep`).
public actor Debouncer {
  private let interval: TimeInterval
  private let action: @Sendable () async -> Void
  private let sleep: @Sendable (TimeInterval) async -> Void
  private var task: Task<Void, Never>?

  public init(interval: TimeInterval,
              sleep: @escaping @Sendable (TimeInterval) async -> Void = { seconds in
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
              },
              action: @escaping @Sendable () async -> Void) {
    self.interval = interval
    self.sleep = sleep
    self.action = action
  }

  public func schedule() {
    task?.cancel()
    task = Task { [interval, action, sleep] in
      await sleep(interval)
      guard !Task.isCancelled else { return }
      await action()
    }
  }
}
