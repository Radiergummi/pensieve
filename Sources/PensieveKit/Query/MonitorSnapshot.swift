import Foundation
import SQLiteData

/// A read-only snapshot of "is Pensieve alive and collecting?" — the heartbeat kernel shared by
/// the app window and (later) the `pensieved` daemon. Never writes; never creates a store.
public struct MonitorSnapshot: Equatable, Sendable {
  public enum Status: String, Equatable, Sendable { case active, idle, notSetUp }

  public let status: Status
  public let lastCaptureAt: Date?      // newest spool row ts (any kind, incl. ingested); nil if none
  public let spoolPending: Int         // captures with ingested = 0
  public let eventCount: Int           // canonical events
  public let looseEndCount: Int        // canonical loose ends with status == "open"

  public init(status: Status, lastCaptureAt: Date?, spoolPending: Int,
              eventCount: Int, looseEndCount: Int) {
    self.status = status; self.lastCaptureAt = lastCaptureAt
    self.spoolPending = spoolPending; self.eventCount = eventCount; self.looseEndCount = looseEndCount
  }

  /// Reads both stores read-only and computes the heartbeat. Never throws to the caller: an
  /// absent/unreachable store degrades that store's fields to zero/nil. Existence is checked
  /// before opening so this never *creates* a store. Status is spool-driven (capture is the
  /// real-time signal), so it reads `.active` even before the first ingest.
  ///
  /// Opens short-lived connections — appropriate for the CLI/daemon (short-lived processes). A
  /// long-running observer that refreshes repeatedly (the app) must use the connection-REUSING
  /// overload below instead: opening a fresh connection touches the store's `-shm`/`-wal` sidecars,
  /// and if the observer also watches that directory for changes, the churn re-fires the watch into
  /// a busy-loop.
  public static func gather(canonicalURL: URL, spoolURL: URL,
                            now: Date = Date(),
                            activeWithin: TimeInterval = 15 * 60) -> MonitorSnapshot {
    // Spool: the real-time capture heartbeat. Only touch it if it already exists.
    var totals = Totals()
    if FileManager.default.fileExists(atPath: spoolURL.path),
       let stats = try? CaptureSpool.readOnlyStats(at: spoolURL) {
      totals.lastCapture = stats.lastCaptureAt
      totals.pending = stats.pending
    }

    // Canonical store: ingested state. Only open an existing store (read-only, no migrator run).
    if FileManager.default.fileExists(atPath: canonicalURL.path),
       let database = try? openCanonicalDatabaseReadOnly(at: canonicalURL) {
      totals.events = (try? database.read { database in try Event.fetchCount(database) }) ?? 0
      totals.loose = (try? database.read { database in
        try LooseEnd.where { LooseEnd.isOpen($0) }.fetchCount(database)
      }) ?? 0
    }

    return classify(totals, now: now, activeWithin: activeWithin)
  }

  /// The same heartbeat computed from ALREADY-OPEN connections — opens nothing. The app must use
  /// this: its FSEvents watch on the store directory would otherwise be re-fired by the `-shm`/`-wal`
  /// churn of opening a fresh connection on every refresh, spinning a busy-loop. Pass `nil` for a
  /// store whose connection isn't open yet; that store's fields degrade to zero/nil, exactly like
  /// the URL overload treats an absent store.
  public static func gather(canonical: (any DatabaseReader)?, spool: CaptureSpool?,
                            now: Date = Date(),
                            activeWithin: TimeInterval = 15 * 60) -> MonitorSnapshot {
    var totals = Totals()
    if let spool {
      totals.lastCapture = try? spool.lastCaptureAt()
      totals.pending = (try? spool.pendingCount()) ?? 0
    }
    if let canonical {
      totals.events = (try? canonical.read { database in try Event.fetchCount(database) }) ?? 0
      totals.loose = (try? canonical.read { database in
        try LooseEnd.where { LooseEnd.isOpen($0) }.fetchCount(database)
      }) ?? 0
    }
    return classify(totals, now: now, activeWithin: activeWithin)
  }

  /// The raw measurements both `gather` overloads collect, before they are classified into a
  /// `Status`. An absent store leaves its own fields at the zero/nil defaults.
  private struct Totals {
    var lastCapture: Date?
    var pending = 0
    var events = 0
    var loose = 0
  }

  private static func classify(_ totals: Totals, now: Date, activeWithin: TimeInterval) -> MonitorSnapshot {
    let status: Status
    if totals.lastCapture == nil && totals.pending == 0 && totals.events == 0 {
      status = .notSetUp
    } else if let lastCapture = totals.lastCapture, now.timeIntervalSince(lastCapture) <= activeWithin {
      status = .active
    } else {
      status = .idle
    }
    return MonitorSnapshot(status: status, lastCaptureAt: totals.lastCapture,
                           spoolPending: totals.pending, eventCount: totals.events,
                           looseEndCount: totals.loose)
  }
}
