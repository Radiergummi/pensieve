import Foundation

/// Trailing-edge coalescer: rapid `schedule()` calls collapse into a single `action` run, fired
/// `interval` seconds after the last call. Used to coalesce the liveness signals (ValueObservation
/// + two FSEvents watches) into one refresh. Actor-isolated; the action runs on a detached Task.
public actor Debouncer {
  private let interval: TimeInterval
  private let action: @Sendable () async -> Void
  private var task: Task<Void, Never>?

  public init(interval: TimeInterval, action: @escaping @Sendable () async -> Void) {
    self.interval = interval
    self.action = action
  }

  public func schedule() {
    task?.cancel()
    task = Task { [interval, action] in
      try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
      guard !Task.isCancelled else { return }
      await action()
    }
  }
}
