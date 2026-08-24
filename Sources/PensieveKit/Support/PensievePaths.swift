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
    guard let normalized = normalizedStoreOverride(customRoot) else { return defaultSupportDirectory() }
    return URL(fileURLWithPath: normalized, isDirectory: true)
  }

  /// **The one rule for reading a store-path override**: a blank or relative value is treated as
  /// ABSENT, never honoured.
  ///
  /// It was enforced on exactly one of the four paths that read such an override — this file's
  /// support root — while `resolvedCanonicalURL()`, `resolvedSpoolURL()`, `indexURL(named:)` and
  /// `StoreRelocationLock.anchorURL()` each honoured `""` and relative values. Verified
  /// experimentally: `URL(fileURLWithPath: "")` is the process's cwd, and a relative value stays
  /// cwd-relative — which under launchd is `/`. So a blank `PENSIEVE_DB` pointed the canonical store
  /// at the filesystem root rather than falling back to the real one.
  ///
  /// Applied inside the pure resolvers rather than at each environment read, so the rule holds for
  /// every caller including tests, and there is nowhere left to forget it.
  static func normalizedStoreOverride(_ raw: String?) -> String? {
    guard let raw else { return nil }
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, trimmed.hasPrefix("/") else { return nil }
    return trimmed
  }

  /// A store path from an override that may be absent, blank or relative, under the rule above.
  public static func resolvedStoreURL(override raw: String?, fallback: URL) -> URL {
    guard let normalized = normalizedStoreOverride(raw) else { return fallback }
    return URL(fileURLWithPath: normalized)
  }

  /// The "sibling of the overridden store, prefixed by its base name" rule, shared by every sidecar
  /// that follows an override. `indexURL` and `StoreRelocationLock.anchorURL` each spelled this out
  /// verbatim; one of them changing its layout would have silently stopped the other from finding
  /// the file it was pairing with.
  static func sidecarBesideStore(_ storeOverride: String, named name: String) -> URL {
    let store = URL(fileURLWithPath: storeOverride)
    let prefix = store.deletingPathExtension().lastPathComponent
    return store.deletingLastPathComponent().appendingPathComponent("\(prefix)-\(name)")
  }

  /// The one call site that reads the world. Never throws; a failed read yields the default.
  public static func supportDirectory() -> URL {
    supportDirectory(customRoot: sharedDefaults.string(forKey: PensieveDefaults.customSupportRootKey))
  }

  /// The canonical store's file name. Named here because `StoreRelocator` restated it in its
  /// `canonicalStoreFileNames` list — so renaming the store file would have left relocation
  /// silently failing to carry (and clean up) the very files it exists to move.
  public static let canonicalStoreFileName = "pensieve.sqlite"
  /// The spool's file name, for symmetry with the above.
  public static let captureStoreFileName = "capture.sqlite"

  public static func canonicalURL(in support: URL) -> URL {
    support.appendingPathComponent(canonicalStoreFileName)
  }
  public static func canonicalURL() -> URL { canonicalURL(in: supportDirectory()) }

  public static func captureURL(in support: URL) -> URL {
    support.appendingPathComponent(captureStoreFileName)
  }
  public static func captureURL() -> URL { captureURL(in: supportDirectory()) }

  /// The disposable narration cache (shared across app / CLI / MCP). Not the canonical store,
  /// not the spool — losing it costs only a re-narrate.
  ///
  /// Follows `PENSIEVE_DB` for the same reason `searchIndexURL()` and `translationCacheURL()` do —
  /// it was the one sidecar that did not, and it is the one whose `init` DELETES the file it cannot
  /// open (`NarrationCache`). So `PENSIEVE_DB=/tmp/fixture pensieve prime` read, wrote, and could
  /// destroy the developer's live narration cache. It produced no wrong answers only because
  /// `NarrationCacheKey` is built from random event UUIDs that cannot collide across stores — an
  /// accident, not a design.
  public static func narrationCacheURL() -> URL {
    narrationCacheURL(storeOverride: ProcessInfo.processInfo.environment["PENSIEVE_DB"],
                      support: supportDirectory())
  }
  /// The rule, separated from reading the environment for the same reason
  /// `indexURL(named:storeOverride:support:)` is — and so that "the narration cache follows the
  /// override" is assertable at all. Asserting it against `indexURL` under the ambient environment
  /// cannot fail on a machine with no `PENSIEVE_DB` set, which is every developer machine.
  static func narrationCacheURL(storeOverride: String?, support: URL) -> URL {
    indexURL(named: "narration-cache.sqlite", storeOverride: storeOverride, support: support)
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
    indexURL(named: name,
             storeOverride: ProcessInfo.processInfo.environment["PENSIEVE_DB"],
             support: supportDirectory())
  }

  /// The rule itself, separated from reading the environment so it is testable: `setenv` is
  /// process-global and Swift Testing runs suites in parallel, so a test that mutated `PENSIEVE_DB`
  /// to cover this could perturb every other test reading it.
  static func indexURL(named name: String, storeOverride: String?, support: URL) -> URL {
    guard let normalized = normalizedStoreOverride(storeOverride)
    else { return support.appendingPathComponent(name) }
    return sidecarBesideStore(normalized, named: name)
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

  /// The App Group. The `group.` prefix is not cosmetic: it is the only form Apple's Developer
  /// portal accepts when registering an App Group, and that registration is what lets Xcode mint the
  /// Mac Development provisioning profile. Without a profile `secd` ignores the entitlement outright,
  /// which costs nothing here (unsandboxed, writes the path directly) but leaves the sandboxed widget
  /// with no container at all. Team-ID-prefixed forms work only for signing that needs no profile.
  public static let appGroupIdentifier = "group.me.mazetti.pensieve"

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
