import Foundation
import SQLiteData
import os

/// Opens the spool at the resolved location (override for tests via PENSIEVE_CAPTURE_DB).
/// Takes NO lock: this is the capture path, and it must never block or gain a way to fail.
public func openSpool() throws -> CaptureSpool {
  try CaptureSpool(at: resolvedSpoolURL())
}

public enum StoreError: Error, Equatable {
  /// A store relocation holds the anchor. Not a failure — callers should report "not now" and
  /// exit 0 so their next scheduled run picks the work up.
  case relocationInProgress
}

/// Admits canonical writers past an in-progress relocation, once per process.
///
/// `CanonicalWriterGate.shared` acquires a SHARED `StoreRelocationLock` on the first canonical-
/// writer open and holds it — not just checks it — for the rest of the process's lifetime. Process
/// lifetime is the correct granularity because every canonical writer here is short-lived:
/// `pensieve sync` and the launchd helper each run one cycle and terminate. The app is the one
/// long-lived writer and never conflicts with itself, because it performs relocation *before*
/// opening any store. A killed process releases the lock automatically when the kernel closes its
/// descriptors.
///
/// Holding for process lifetime (rather than acquire-check-release around each open) matters
/// because a relocation must not be able to start the instant after a writer's admission check
/// passes — the writer's held descriptor is what keeps blocking a concurrent exclusive lock for as
/// long as the writer's process is alive.
final class CanonicalWriterGate: @unchecked Sendable {
  static let shared = CanonicalWriterGate()
  private let held = OSAllocatedUnfairLock<StoreRelocationLock?>(initialState: nil)

  /// Throws `StoreError.relocationInProgress` if a relocation holds the anchor and this gate has
  /// not already admitted a writer. Idempotent: once admitted, later calls on the same instance
  /// reuse the held lock rather than re-acquiring.
  ///
  /// A nil `StoreRelocationLock` init means EITHER genuine contention (a relocation holds the
  /// anchor exclusively) OR a non-contention failure such as an unwritable Caches directory — both
  /// are surfaced identically here because a writer declining to run is the conservative
  /// direction; it does not mean a relocation is truly in progress.
  func admit(anchor: URL = StoreRelocationLock.anchorURL()) throws {
    try held.withLock { lock in
      guard lock == nil else { return }
      guard let acquired = StoreRelocationLock(at: anchor, exclusive: false) else {
        throw StoreError.relocationInProgress
      }
      lock = acquired
    }
  }
}

/// Opens the canonical store for WRITING at the resolved location (override for tests via
/// PENSIEVE_DB). Refuses while a relocation is in progress.
public func openCanonical() throws -> any DatabaseWriter {
  try CanonicalWriterGate.shared.admit()
  return try openCanonicalDatabase(at: resolvedCanonicalURL())
}

/// The resolved spool path: PENSIEVE_CAPTURE_DB > custom support root > default.
public func resolvedSpoolURL() -> URL {
  if let override = ProcessInfo.processInfo.environment["PENSIEVE_CAPTURE_DB"] {
    return URL(fileURLWithPath: override)
  }
  return PensievePaths.captureURL()
}

/// The resolved canonical path: PENSIEVE_DB > custom support root > default.
public func resolvedCanonicalURL() -> URL {
  if let override = ProcessInfo.processInfo.environment["PENSIEVE_DB"] {
    return URL(fileURLWithPath: override)
  }
  return PensievePaths.canonicalURL()
}
