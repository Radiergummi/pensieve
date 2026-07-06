import Foundation
import CoreServices

/// Watches one or more directories for any filesystem change and invokes `onChange`. Path-based
/// (FSEvents), so it survives SQLite recreating `-wal`/`-shm` on checkpoint — more robust than a
/// per-file vnode source. Coalescing/latency is left to the caller's Debouncer. App-lifetime:
/// hold a strong reference for as long as you want events; deinit tears the stream down.
public final class DirectoryWatcher {
  private var stream: FSEventStreamRef?
  private let onChange: () -> Void

  /// - Parameter paths: directories to watch (e.g. the canonical store's and spool's parent dirs).
  public init(paths: [String], latency: TimeInterval = 0.05, onChange: @escaping () -> Void) {
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
