import Foundation
import SQLiteData

/// A read-only "how is Pensieve configured and is it running?" snapshot for the Settings ▸ Advanced
/// tab. Like `MonitorSnapshot`, this is a pure gather kernel: it never throws, never writes, and
/// never creates a store — every field degrades to a sensible default rather than failing.
public struct SystemStatus: Sendable, Equatable {
  /// The RESOLVED concrete kind ("foundationModels" / "claudeCLI" / "cloud") — never a preference.
  public var providerKind: String
  public var foundationModelsAvailable: Bool
  /// The launchd LaunchAgent plist exists on disk.
  public var daemonInstalled: Bool
  /// mtime of sync.log. An honest "last daemon run": `pensieve sync` prints a summary line on EVERY
  /// run (even a no-op) and the LaunchAgent redirects stdout/stderr there, so the mtime always moves.
  public var lastSyncAt: Date?
  /// The most recent canonical `Event.occurredAt`. nil when the store is empty or unreadable.
  public var lastEventAt: Date?

  public init(providerKind: String, foundationModelsAvailable: Bool, daemonInstalled: Bool,
              lastSyncAt: Date?, lastEventAt: Date?) {
    self.providerKind = providerKind
    self.foundationModelsAvailable = foundationModelsAvailable
    self.daemonInstalled = daemonInstalled
    self.lastSyncAt = lastSyncAt
    self.lastEventAt = lastEventAt
  }
}

public enum SystemStatusGatherer {
  /// Everything is injected (db, defaults, cloud inputs, both file URLs) so this is deterministically
  /// testable against a temp store + temp files. No hidden globals, no `now:` — every field is
  /// present-or-absent, and relative-date formatting belongs to the view.
  ///
  /// `apiKey` is a `String?` (not a Bool) so we can call the SHARED `resolvedProviderKind` directly
  /// rather than reimplementing the "is cloud configured" test — one source of truth with the factory.
  public static func gather(db: (any DatabaseReader)?,
                           defaults: UserDefaults,
                           cloudConfig: CloudConfig?,
                           apiKey: String?,
                           launchAgentURL: URL,
                           syncLogURL: URL) -> SystemStatus {
    let kind = resolvedProviderKind(defaults: defaults, cloudConfig: cloudConfig, apiKey: apiKey)

    let daemonInstalled = FileManager.default.fileExists(atPath: launchAgentURL.path)

    let lastSyncAt = try? syncLogURL
      .resourceValues(forKeys: [.contentModificationDateKey])
      .contentModificationDate

    // Best-effort: an empty store, a read error, or a nil connection all degrade to nil.
    var lastEventAt: Date? = nil
    if let db {
      lastEventAt = try? db.read { db in
        try Event.order { $0.occurredAt.desc() }.limit(1).fetchOne(db)?.occurredAt
      }
    }

    return SystemStatus(providerKind: kind,
                        foundationModelsAvailable: FoundationModelsProbe.isAvailable(),
                        daemonInstalled: daemonInstalled,
                        lastSyncAt: lastSyncAt ?? nil,
                        lastEventAt: lastEventAt ?? nil)
  }
}
