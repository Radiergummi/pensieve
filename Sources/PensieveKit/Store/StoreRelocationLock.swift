import Foundation

/// An advisory whole-file lock coordinating a store relocation against concurrent canonical
/// writers, across processes.
///
/// The anchor is deliberately OUTSIDE the support directory. `flock` binds to an inode: if the
/// lockfile lived in the directory being relocated, a same-volume rename would preserve it and
/// everything would appear to work, while a cross-volume copy would hand the writer a *different*
/// inode of an identically-named file — the guard would evaporate in precisely the case it exists
/// for.
///
/// Non-blocking by design. A writer that cannot acquire does not wait; it reports "not now" and
/// exits so its next scheduled run picks the work up.
public final class StoreRelocationLock: @unchecked Sendable {
  private let descriptor: Int32

  /// `~/Library/Caches/me.mazetti.pensieve/relocation.lock` — a path that never relocates.
  ///
  /// Scoped off `PENSIEVE_DB`, exactly how `PensievePaths.indexURL(named:storeOverride:)` already
  /// scopes disposable indexes: an env-scoped store gets an env-scoped anchor. Without this, every
  /// `PENSIEVE_DB`-scoped run (every test, `PENSIEVE_DB=/tmp/x pensieve sync`, the app's own
  /// smoke-launch) contends for the REAL anchor even though it never touches the real store — which
  /// is how `make test` came to hold the developer's actual relocation lock SHARED for the whole
  /// test process (refusing a real relocation attempted mid-run) while a real relocation could make
  /// an unrelated `PENSIEVE_DB`-scoped test run fail.
  public static func anchorURL() -> URL {
    anchorURL(storeOverride: ProcessInfo.processInfo.environment["PENSIEVE_DB"])
  }

  /// The rule itself, separated from reading the environment so it is testable without mutating
  /// process-global state — `setenv` is process-global and Swift Testing runs suites in parallel,
  /// the same reason `PensievePaths.indexURL(named:storeOverride:support:)` was split out.
  static func anchorURL(storeOverride: String?) -> URL {
    guard let normalized = PensievePaths.normalizedStoreOverride(storeOverride) else {
      return PensievePaths.homeDirectory()
        .appendingPathComponent("Library/Caches/me.mazetti.pensieve", isDirectory: true)
        .appendingPathComponent("relocation.lock")
    }
    // The sidecar layout is shared with `PensievePaths.indexURL` rather than restated here; the two
    // had identical copies, and a layout change in one would have left the other pairing with a
    // file that no longer existed.
    return PensievePaths.sidecarBesideStore(normalized, named: "relocation.lock")
  }

  /// Acquires the lock, or returns nil if it is held incompatibly. Creating the anchor is
  /// best-effort: if the Caches directory cannot be made, this returns nil, which callers treat
  /// as "someone else is relocating" — the conservative direction (a writer declines to run
  /// rather than running unguarded).
  public init?(at url: URL = StoreRelocationLock.anchorURL(), exclusive: Bool) {
    try? FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let opened = open(url.path, O_RDWR | O_CREAT, 0o644)
    guard opened >= 0 else { return nil }
    let mode = (exclusive ? LOCK_EX : LOCK_SH) | LOCK_NB
    guard flock(opened, mode) == 0 else {
      close(opened)
      return nil
    }
    descriptor = opened
  }

  deinit {
    flock(descriptor, LOCK_UN)
    close(descriptor)
  }
}
