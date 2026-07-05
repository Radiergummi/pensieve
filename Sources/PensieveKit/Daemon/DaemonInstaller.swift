import Foundation

public enum DaemonInstallError: Error, CustomStringConvertible {
  case runningFromBuild(String)
  public var description: String {
    switch self {
    case .runningFromBuild(let p):
      return "Refusing to install the daemon from a .build path (\(p)). Install the release binary to ~/.local/bin/pensieve and run install-daemon from there."
    }
  }
}

/// Installs/uninstalls the `com.pensieve.sync` LaunchAgent. The plist-writing half is pure and
/// tested; the `launchctl` half is a side effect (smoke-verified by hand).
public enum DaemonInstaller {
  /// The stable path baked into the plist — NOT `Bundle.main.executablePath` (which resolves into
  /// `.build/…` under `swift run`; a routine `rm -rf .build` would then silently kill the daemon).
  public static func stablePensievePath(home: URL) -> String {
    home.appendingPathComponent(".local/bin/pensieve").path
  }

  /// Refuse to install when the running binary is under `.build`.
  public static func ensureStable(runningExecutable: String) throws {
    if runningExecutable.contains("/.build/") {
      throw DaemonInstallError.runningFromBuild(runningExecutable)
    }
  }

  /// Guard + create the log dir + write the plist. No `launchctl`. `home` roots all paths.
  public static func writePlist(home: URL, runningExecutable: String, plistURL: URL) throws {
    try ensureStable(runningExecutable: runningExecutable)
    let logsDir = home.appendingPathComponent("Library/Logs/Pensieve", isDirectory: true)
    try FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)
    try PensievePaths.ensureParentDirectory(of: plistURL)
    let data = try LaunchAgentPlist.data(pensievePath: stablePensievePath(home: home), home: home)
    try data.write(to: plistURL, options: .atomic)
  }

  /// Reload-always: bootout (ignore "not loaded") then bootstrap (retry the teardown race).
  public static func load(plistURL: URL, uid: String) {
    _ = launchctl(["bootout", "gui/\(uid)", plistURL.path])
    for _ in 0..<3 {
      if launchctl(["bootstrap", "gui/\(uid)", plistURL.path]) == 0 { return }
      Thread.sleep(forTimeInterval: 0.3)   // bootout returns before teardown completes
    }
  }

  public static func unload(plistURL: URL, uid: String) {
    _ = launchctl(["bootout", "gui/\(uid)", plistURL.path])
    try? FileManager.default.removeItem(at: plistURL)
  }

  @discardableResult
  private static func launchctl(_ args: [String]) -> Int32 {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
    p.arguments = args
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { return -1 }
    p.waitUntilExit()
    return p.terminationStatus
  }
}
