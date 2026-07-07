import Foundation
import CoreServices

/// Watches one or more directories for any filesystem change and invokes `onChange`. Path-based
/// (FSEvents), so it survives SQLite recreating `-wal`/`-shm` on checkpoint — more robust than a
/// per-file vnode source. Coalescing/latency is left to the caller's Debouncer.
///
/// `onChange` is invoked on a private serial dispatch queue, so it must be `@Sendable`.
/// App-lifetime by contract: hold a strong reference for as long as you want events. The stream
/// context is `passUnretained` (so deinit runs and the watcher never leaks on drop); the tradeoff
/// is a narrow teardown window if the owning object is deallocated concurrently with an in-flight
/// callback. Keeping the watcher alive for the app's lifetime (as `AppModel` does) sidesteps it.
public final class DirectoryWatcher {
  private var stream: FSEventStreamRef?
  private let onChange: @Sendable () -> Void

  /// - Parameter paths: directories to watch (e.g. the canonical store's and spool's parent dirs).
  public init(paths: [String], latency: TimeInterval = 0.05, onChange: @escaping @Sendable () -> Void) {
    self.onChange = onChange
    var ctx = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                   retain: nil, release: nil, copyDescription: nil)
    let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
      guard let info else { return }
      let watcher = Unmanaged<DirectoryWatcher>.fromOpaque(info).takeUnretainedValue()
      watcher.onChange()
    }
    guard let stream = FSEventStreamCreate(
      kCFAllocatorDefault, callback, &ctx, paths as CFArray,
      FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency,
      FSEventStreamCreateFlags(kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagFileEvents)
    ) else { return }
    self.stream = stream
    FSEventStreamSetDispatchQueue(stream, DispatchQueue(label: "com.pensieve.fswatch"))
    FSEventStreamStart(stream)
  }

  deinit {
    guard let stream else { return }
    FSEventStreamStop(stream)
    FSEventStreamInvalidate(stream)
    FSEventStreamRelease(stream)
  }
}
