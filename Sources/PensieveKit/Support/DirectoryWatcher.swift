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
    // `info` is Apple's parameter name in `FSEventStreamContext` and the callback signature — kept.
    var streamContext = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                             retain: nil, release: nil, copyDescription: nil)
    let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
      guard let info else { return }
      let watcher = Unmanaged<DirectoryWatcher>.fromOpaque(info).takeUnretainedValue()
      watcher.onChange()
    }
    // Both failures were discarded silently, which presents as a UI that has simply gone quiet —
    // indistinguishable from "no work has happened", the one reading this app must never give by
    // accident. Neither is recoverable here, so log and leave the watcher inert rather than pretend.
    guard let stream = FSEventStreamCreate(
      kCFAllocatorDefault, callback, &streamContext, paths as CFArray,
      FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency,
      FSEventStreamCreateFlags(kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagFileEvents)
    ) else {
      Log.sync.error("FSEventStreamCreate failed for \(paths.joined(separator: ", "), privacy: .public) — live updates are off")
      return
    }
    self.stream = stream
    FSEventStreamSetDispatchQueue(stream, DispatchQueue(label: "com.pensieve.fswatch"))
    guard FSEventStreamStart(stream) else {
      Log.sync.error("FSEventStreamStart failed for \(paths.joined(separator: ", "), privacy: .public) — live updates are off")
      return
    }
  }

  deinit {
    guard let stream else { return }
    FSEventStreamStop(stream)
    FSEventStreamInvalidate(stream)
    FSEventStreamRelease(stream)
  }
}
