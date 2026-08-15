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
  public static func anchorURL() -> URL {
    PensievePaths.homeDirectory()
      .appendingPathComponent("Library/Caches/me.mazetti.pensieve", isDirectory: true)
      .appendingPathComponent("relocation.lock")
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
