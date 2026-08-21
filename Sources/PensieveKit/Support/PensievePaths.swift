import Foundation

public enum PensievePaths {
  /// The shared defaults handle, constructed ONCE. `supportDirectory()` runs on every git-hook
  /// capture, and the capture path is sacred — a per-call `UserDefaults(suiteName:)` would put a
  /// domain construction on it for no reason. Reads from a cached cfprefsd domain are microseconds.
  /// `UserDefaults` is documented thread-safe, so `nonisolated(unsafe)` on this immutable handle is
  /// safe (same pattern as `DiagnosticsCollector.shared`).
  nonisolated(unsafe) private static let sharedDefaults = PensieveDefaults.shared()

  /// The un-overridable location. Kept separate so the resolver has something to fall back TO and
  /// so tests can name the fallback without restating the string.
  public static func defaultSupportDirectory() -> URL {
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    return base.appendingPathComponent("Pensieve", isDirectory: true)
  }

  /// The rule, pure and injectable. Separated from reading the world for the same reason
  /// `indexURL(named:storeOverride:)` is: the real source is process-global shared state, and
  /// Swift Testing runs suites in parallel.
  ///
  /// A blank or relative stored value is treated as absent rather than honoured. A relative root
  /// would resolve against the process's cwd — `/` under launchd — which is how a store ends up at
  /// the filesystem root.
  public static func supportDirectory(customRoot: String?) -> URL {
    guard let customRoot else { return defaultSupportDirectory() }
    let trimmed = customRoot.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, trimmed.hasPrefix("/") else { return defaultSupportDirectory() }
    return URL(fileURLWithPath: trimmed, isDirectory: true)
  }

  /// The one call site that reads the world. Never throws; a failed read yields the default.
  public static func supportDirectory() -> URL {
    supportDirectory(customRoot: sharedDefaults.string(forKey: PensieveDefaults.customSupportRootKey))
  }

  public static func canonicalURL(in support: URL) -> URL {
    support.appendingPathComponent("pensieve.sqlite")
  }
  public static func canonicalURL() -> URL { canonicalURL(in: supportDirectory()) }

  public static func captureURL(in support: URL) -> URL {
    support.appendingPathComponent("capture.sqlite")
  }
  public static func captureURL() -> URL { captureURL(in: supportDirectory()) }

  /// The disposable narration cache (shared across app / CLI / MCP). Not the canonical store,
  /// not the spool — losing it costs only a re-narrate.
  public static func narrationCacheURL(in support: URL) -> URL {
    support.appendingPathComponent("narration-cache.sqlite")
  }
  public static func narrationCacheURL() -> URL { narrationCacheURL(in: supportDirectory()) }
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
    indexURL(named: name,
             storeOverride: ProcessInfo.processInfo.environment["PENSIEVE_DB"],
             support: supportDirectory())
  }

  /// The rule itself, separated from reading the environment so it is testable: `setenv` is
  /// process-global and Swift Testing runs suites in parallel, so a test that mutated `PENSIEVE_DB`
  /// to cover this could perturb every other test reading it.
  static func indexURL(named name: String, storeOverride: String?, support: URL) -> URL {
    guard let storeOverride else { return support.appendingPathComponent(name) }
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

  /// The App Group. Team-ID-prefixed on purpose: an App Group is same-device, so a future iOS
  /// companion gets its own container regardless and a `group.`-prefixed name buys nothing here.
  public static let appGroupIdentifier = "TH593VRB6W.me.mazetti.pensieve"

  /// ONE resolution for every process. The sandboxed widget must ask the system; the sync agent and
  /// the CLI carry no entitlement and fall back to construction. Measured: for an unsandboxed
  /// process `containerURL` performs no entitlement check, so the two branches agree byte-for-byte.
  public static func groupContainerDirectory() -> URL {
    if let url = FileManager.default.containerURL(
      forSecurityApplicationGroupIdentifier: appGroupIdentifier) { return url }
    return homeDirectory()
      .appendingPathComponent("Library/Group Containers/\(appGroupIdentifier)", isDirectory: true)
  }

  /// The widget's read-only view of "what's next". A file, not a database: a WAL store cannot be
  /// opened read-only, and an extension must never hold write access to canonical data.
  public static func widgetDigestURL() -> URL {
    groupContainerDirectory().appendingPathComponent("widget-digest.json")
  }

  /// Ensures the parent directory of a database file exists before it's opened.
  public static func ensureParentDirectory(of url: URL) throws {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
  }
}
