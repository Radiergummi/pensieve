import Foundation

public enum PensievePaths {
  public static func supportDirectory() -> URL {
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    return base.appendingPathComponent("Pensieve", isDirectory: true)
  }
  public static func canonicalURL() -> URL {
    supportDirectory().appendingPathComponent("pensieve.sqlite")
  }
  public static func captureURL() -> URL {
    supportDirectory().appendingPathComponent("capture.sqlite")
  }
  /// The disposable narration cache (shared across app / CLI / MCP). Not the canonical store,
  /// not the spool — losing it costs only a re-narrate.
  public static func narrationCacheURL() -> URL {
    supportDirectory().appendingPathComponent("narration-cache.sqlite")
  }
  /// The current user's home, resolved via `getpwuid` (correct even when launchd does not
  /// export HOME) rather than the HOME environment variable.
  public static func homeDirectory() -> URL {
    FileManager.default.homeDirectoryForCurrentUser
  }
  /// `~/.claude/projects` — where Claude Code writes session transcripts.
  public static func claudeProjectsURL() -> URL {
    homeDirectory().appendingPathComponent(".claude/projects", isDirectory: true)
  }
  /// `~/Library/Logs/Pensieve` — the daemon's log directory (launchd will not create it).
  public static func logsDirectory() -> URL {
    homeDirectory().appendingPathComponent("Library/Logs/Pensieve", isDirectory: true)
  }
  public static func syncLogURL() -> URL {
    logsDirectory().appendingPathComponent("sync.log")
  }
  /// `~/Library/LaunchAgents/com.pensieve.sync.plist`.
  public static func launchAgentURL() -> URL {
    homeDirectory().appendingPathComponent("Library/LaunchAgents/com.pensieve.sync.plist")
  }
  /// The stable installed CLI path baked into the daemon plist (never a `.build` path).
  public static func installedBinaryURL() -> URL {
    homeDirectory().appendingPathComponent(".local/bin/pensieve")
  }

  /// Ensures the parent directory of a database file exists before it's opened.
  public static func ensureParentDirectory(of url: URL) throws {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
  }
}
