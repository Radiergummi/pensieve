import Foundation

/// Boots out + removes the LEGACY hand-installed `com.pensieve.sync` LaunchAgent. Retained after the
/// SMAppService migration purely to retire the old agent on first launch of the new app.
public enum DaemonInstaller {
  public static func unload(plistURL: URL, uid: String) {
    _ = launchctl(["bootout", "gui/\(uid)", plistURL.path])
    try? FileManager.default.removeItem(at: plistURL)
  }

  @discardableResult
  private static func launchctl(_ args: [String]) -> Int32 {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
    process.arguments = args
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    do { try process.run() } catch { return -1 }
    process.waitUntilExit()
    return process.terminationStatus
  }
}
