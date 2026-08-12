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
  /// The disposable, device-local, never-synced FTS5 search index (shared across app / CLI /
  /// daemon / MCP). Losing it costs only a re-index.
  public static func searchIndexURL() -> URL {
    indexURL(named: "search-index.sqlite")
  }
  /// Disposable, never synced, rebuildable by re-translating. Sibling of the narration cache and the
  /// search index. Must follow `PENSIEVE_DB` like `searchIndexURL()` does, so that disposable indexes
  /// belong to the store they were built from and are not clobbered by test/verification recipes.
  public static func translationCacheURL() -> URL {
    indexURL(named: "translation-cache.sqlite")
  }
  /// The search index belongs to the store it was built from, so it MUST follow `PENSIEVE_DB` wherever
  /// `openCanonical()` does. Without this, the project's own verification recipes — `PENSIEVE_DB=/tmp/x
  /// pensieve sync`, and the app smoke-launch — point at a throwaway store, find the real index's
  /// corpus hash stale against it, and `DELETE FROM documents` on the developer's LIVE index. The
  /// data is disposable, but until the next real sync every surface reports `index_state: ready` over
  /// an empty index: a silent, total retrieval outage after a routine test run.
  ///
  /// With no override the path is unchanged, so existing indexes are not orphaned. Under one, the
  /// index becomes a sibling of the overridden store prefixed by the store's base name, so two
  /// throwaway stores in the same directory do not share an index.
  private static func indexURL(named name: String) -> URL {
    indexURL(named: name, storeOverride: ProcessInfo.processInfo.environment["PENSIEVE_DB"])
  }

  /// The rule itself, separated from reading the environment so it is testable: `setenv` is
  /// process-global and Swift Testing runs suites in parallel, so a test that mutated `PENSIEVE_DB`
  /// to cover this could perturb every other test reading it.
  static func indexURL(named name: String, storeOverride: String?) -> URL {
    guard let storeOverride else { return supportDirectory().appendingPathComponent(name) }
    let store = URL(fileURLWithPath: storeOverride)
    let prefix = store.deletingPathExtension().lastPathComponent
    return store.deletingLastPathComponent().appendingPathComponent("\(prefix)-\(name)")
  }
  /// Working directory pinned onto Pensieve's own `claude -p` subprocesses. Inert and empty by
  /// design: the child would otherwise inherit our cwd (`/` under launchd), producing a captured
  /// session at the filesystem root that Pensieve then re-ingests as work. Created on demand;
  /// best-effort — a creation failure just leaves the child with the inherited cwd, which the
  /// ingester's degenerate-root guard still refuses.
  public static func llmScratchDirectory() -> URL {
    let url = supportDirectory().appendingPathComponent("llm-scratch", isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
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
