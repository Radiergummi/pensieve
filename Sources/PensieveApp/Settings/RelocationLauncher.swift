import AppKit
import Foundation
import PensieveKit

/// Requesting a relocation writes an instruction and restarts the app; the NEW instance performs
/// the move during startup, before `AppModel.start()` opens anything.
///
/// This ordering is the whole point. Relocating inside a running session would mean tearing down
/// `AppModel`'s `lazy var searchStore` (which cannot be reset), two app-lifetime `FSEventStream`
/// watches bound to the old directories, and a live `ValueObservation` task — and missing any one
/// strong reference to the pool leaves the app unable to release its own shared lock, failing its
/// own relocation forever. The relaunch was already required, so this reorders it rather than
/// adding one.
enum RelocationLauncher {
  @MainActor
  static func requestRelocation(to destination: URL) {
    UserDefaults.standard.set(destination.path, forKey: AppDefaults.pendingRelocationDestinationKey)
    relaunch()
  }

  static func pendingDestination() -> URL? {
    guard let path = UserDefaults.standard.string(
      forKey: AppDefaults.pendingRelocationDestinationKey), !path.isEmpty else { return nil }
    return URL(fileURLWithPath: path, isDirectory: true)
  }

  static func clearPending() {
    UserDefaults.standard.removeObject(forKey: AppDefaults.pendingRelocationDestinationKey)
  }

  /// Waits for THIS process to exit before reopening the bundle — two instances of the same app
  /// racing over the same store is the one thing worse than the race we are removing.
  ///
  /// Main-actor isolated because it ends with `NSApp.terminate`, and both `NSApp` and `terminate`
  /// are main-actor isolated. Every caller is already on the main actor (a SwiftUI button action),
  /// so this states the isolation the code always had rather than adding a hop.
  @MainActor
  static func relaunch() {
    let bundlePath = Bundle.main.bundlePath
    let processIdentifier = ProcessInfo.processInfo.processIdentifier
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/bin/sh")
    task.arguments = ["-c",
      "while /bin/kill -0 \(processIdentifier) 2>/dev/null; do /bin/sleep 0.1; done; "
      + "/usr/bin/open \"\(bundlePath)\""]
    try? task.run()
    NSApp.terminate(nil)
  }
}
