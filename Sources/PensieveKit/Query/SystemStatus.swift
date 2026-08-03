import Foundation
import SQLiteData

/// A read-only "how is Pensieve configured and is it running?" snapshot for the Settings ▸ Advanced
/// tab. Like `MonitorSnapshot`, this is a pure gather kernel: it never throws, never writes, and
/// never creates a store — every field degrades to a sensible default rather than failing.
public struct SystemStatus: Sendable, Equatable {
  /// The RESOLVED concrete kind ("foundationModels" / "claudeCLI" / "cloud") — never a preference.
  public var providerKind: String
  public var foundationModelsAvailable: Bool
  /// The SMAppService background agent is registered + enabled.
  public var backgroundSyncEnabled: Bool
  /// mtime of sync.log. An honest "last sync run": every sync writes a summary line on EVERY run
  /// (even a no-op) — the bundled agent's helper appends it directly — so the mtime always moves.
  public var lastSyncAt: Date?
  /// The most recent canonical `Event.occurredAt`. nil when the store is empty or unreadable.
  public var lastEventAt: Date?

  public init(providerKind: String, foundationModelsAvailable: Bool, backgroundSyncEnabled: Bool,
              lastSyncAt: Date?, lastEventAt: Date?) {
    self.providerKind = providerKind
    self.foundationModelsAvailable = foundationModelsAvailable
    self.backgroundSyncEnabled = backgroundSyncEnabled
    self.lastSyncAt = lastSyncAt
    self.lastEventAt = lastEventAt
  }
}

public enum SystemStatusGatherer {
  /// Everything is injected (database, defaults, cloud inputs, both file URLs) so this is deterministically
  /// testable against a temp store + temp files. No hidden globals, no `now:` — every field is
  /// present-or-absent, and relative-date formatting belongs to the view.
  ///
  /// `apiKey` is a `String?` (not a Bool) so we can call the SHARED `resolvedProviderKind` directly
  /// rather than reimplementing the "is cloud configured" test — one source of truth with the factory.
  public static func gather(database: (any DatabaseReader)?,
                           defaults: UserDefaults,
                           cloudConfig: CloudConfig?,
                           apiKey: String?,
                           backgroundSyncEnabled: Bool,
                           syncLogURL: URL) -> SystemStatus {
    let kind = resolvedProviderKind(defaults: defaults, cloudConfig: cloudConfig, apiKey: apiKey)

    let lastSyncAt = try? syncLogURL
      .resourceValues(forKeys: [.contentModificationDateKey])
      .contentModificationDate

    // Best-effort: an empty store, a read error, or a nil connection all degrade to nil.
    var lastEventAt: Date?
    if let database {
      lastEventAt = try? database.read { database in
        try Event.order { $0.occurredAt.desc() }.limit(1).fetchOne(database)?.occurredAt
      }
    }

    return SystemStatus(providerKind: kind,
                        foundationModelsAvailable: FoundationModelsProbe.isAvailable(),
                        backgroundSyncEnabled: backgroundSyncEnabled,
                        lastSyncAt: lastSyncAt ?? nil,
                        lastEventAt: lastEventAt ?? nil)
  }
}
