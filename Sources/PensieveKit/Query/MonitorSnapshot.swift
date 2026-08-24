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
    let stats = FileManager.default.fileExists(atPath: spoolURL.path)
      ? try? CaptureSpool.readOnlyStats(at: spoolURL)
      : nil

    // Canonical store: ingested state. Only open an existing store (read-only, no migrator run).
    // A store that exists but will not OPEN is not the same thing as no store — see `Totals.canonicalUnreadable`.
    let canonicalExists = FileManager.default.fileExists(atPath: canonicalURL.path)
    let database = canonicalExists ? try? openCanonicalDatabaseReadOnly(at: canonicalURL) : nil
    if canonicalExists && database == nil {
      Log.sync.error("MonitorSnapshot: canonical store exists but would not open at \(canonicalURL.path, privacy: .public)")
    }

    let totals = collect(canonical: database, canonicalUnreadable: canonicalExists && database == nil,
                         lastCapture: stats?.lastCaptureAt, pending: stats?.pending ?? 0)
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
    let totals = collect(canonical: canonical, canonicalUnreadable: false,
                         lastCapture: try? spool?.lastCaptureAt(),
                         pending: (try? spool?.pendingCount()) ?? 0)
    return classify(totals, now: now, activeWithin: activeWithin)
  }

  /// The canonical-store half of the heartbeat, in ONE place. Both `gather` overloads read the same
  /// two counts off a reader they resolved differently (one opens it from a URL, one is handed a
  /// live connection), and each used to spell the reads out itself.
  private static func collect(canonical: (any DatabaseReader)?, canonicalUnreadable: Bool,
                              lastCapture: Date?, pending: Int) -> Totals {
    var totals = Totals()
    totals.lastCapture = lastCapture
    totals.pending = pending
    totals.canonicalUnreadable = canonicalUnreadable
    guard let canonical else { return totals }
    do {
      totals.events = try canonical.read { database in try Event.fetchCount(database) }
      totals.openLooseEnds = try canonical.read { database in
        try LooseEnd.where { LooseEnd.isOpen($0) }.fetchCount(database)
      }
    } catch {
      // A store that is present but will not answer is the third state: not absent, not empty. The
      // counts stay at zero (there is no honest number) but the state is recorded, so `classify`
      // cannot call it "not set up".
      totals.canonicalUnreadable = true
      Log.sync.error("MonitorSnapshot: canonical read failed: \(error, privacy: .public)")
    }
    return totals
  }

  /// The raw measurements both `gather` overloads collect, before they are classified into a
  /// `Status`. An absent store leaves its own fields at the zero/nil defaults.
  private struct Totals {
    var lastCapture: Date?
    var pending = 0
    var events = 0
    var openLooseEnds = 0
    /// A canonical store is present but its counts could not be obtained — it would not open, or a
    /// read threw. Distinct from absent: the connection overload's nil reader means "not open yet",
    /// which its doc equates to no store, and leaves this false.
    var canonicalUnreadable = false
  }

  private static func classify(_ totals: Totals, now: Date, activeWithin: TimeInterval) -> MonitorSnapshot {
    let status: Status
    if let lastCapture = totals.lastCapture, now.timeIntervalSince(lastCapture) <= activeWithin {
      status = .active
    } else if totals.lastCapture == nil && totals.pending == 0 && totals.events == 0
                && !totals.canonicalUnreadable {
      // "Not set up" is a claim about the machine, so it must not be reachable by a store that IS
      // set up and merely unreadable — a corrupt or permission-denied store rendered as a fresh
      // install, which is the one reading that tells the user to do nothing. An unreadable store
      // falls through to `.idle`: something is here, it just isn't moving.
      status = .notSetUp
    } else {
      status = .idle
    }
    return MonitorSnapshot(status: status, lastCaptureAt: totals.lastCapture,
                           spoolPending: totals.pending, eventCount: totals.events,
                           looseEndCount: totals.openLooseEnds)
  }
}
