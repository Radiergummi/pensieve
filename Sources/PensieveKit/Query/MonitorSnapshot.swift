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
  public static func gather(canonicalURL: URL, spoolURL: URL,
                            now: Date = Date(),
                            activeWithin: TimeInterval = 15 * 60) -> MonitorSnapshot {
    // Spool: the real-time capture heartbeat. Only touch it if it already exists.
    var lastCapture: Date? = nil
    var pending = 0
    if FileManager.default.fileExists(atPath: spoolURL.path),
       let stats = try? CaptureSpool.readOnlyStats(at: spoolURL) {
      lastCapture = stats.lastCaptureAt
      pending = stats.pending
    }

    // Canonical store: ingested state. Only open an existing store (read-only, no migrator run).
    var events = 0
    var loose = 0
    if FileManager.default.fileExists(atPath: canonicalURL.path),
       let db = try? openCanonicalDatabaseReadOnly(at: canonicalURL) {
      events = (try? db.read { db in try Event.all.fetchAll(db).count }) ?? 0
      loose = (try? db.read { db in
        try LooseEnd.where { $0.status.eq("open") }.fetchAll(db).count
      }) ?? 0
    }

    let status: Status
    if lastCapture == nil && pending == 0 && events == 0 {
      status = .notSetUp
    } else if let lastCapture, now.timeIntervalSince(lastCapture) <= activeWithin {
      status = .active
    } else {
      status = .idle
    }

    return MonitorSnapshot(status: status, lastCaptureAt: lastCapture,
                           spoolPending: pending, eventCount: events, looseEndCount: loose)
  }
}
