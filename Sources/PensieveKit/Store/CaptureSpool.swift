import Foundation
import SQLiteData   // for GRDB's DatabaseQueue / Row APIs
import GRDB

public struct SpoolRow: Sendable {
  public let id: Int64
  public let timestamp: Date
  public let kind: String
  public let payload: String
}

public final class CaptureSpool: Sendable {
  private let dbQueue: DatabaseQueue

  public init(at url: URL) throws {
    try PensievePaths.ensureParentDirectory(of: url)
    var config = Configuration()
    config.busyMode = .timeout(5)
    config.prepareDatabase { database in try database.execute(sql: "PRAGMA journal_mode = WAL") }
    self.dbQueue = try DatabaseQueue(path: url.path, configuration: config)
    // Read before writing. This runs on **every** capture, and the capture path is sacred: a write
    // transaction — behind a 5 s busy timeout, while the ingester may hold the write lock — is a way
    // for a git hook to be delayed that a read simply is not. `CREATE TABLE IF NOT EXISTS` is cheap
    // only once you already hold the write lock, and after the very first capture the answer is
    // always "it exists".
    let tableExists = try dbQueue.read { database in
      try Bool.fetchOne(
        database,
        sql: "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'captures'") ?? false
    }
    guard !tableExists else { return }
    try dbQueue.write { database in
      try database.execute(sql: """
        CREATE TABLE IF NOT EXISTS captures(
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          ts TEXT NOT NULL,
          kind TEXT NOT NULL,
          payload TEXT NOT NULL,
          ingested INTEGER NOT NULL DEFAULT 0
        )
        """)
    }
  }

  /// The two heartbeat queries, named once. `lastCaptureAt()`/`pendingCount()` and the read-only
  /// `readOnlyStats(at:)` each spelled them out, and `readOnlyStats`' only test compares the two
  /// paths to each other — so an edit to one spelling would have been reported as agreement.
  private static let newestTimestampSQL = "SELECT max(ts) FROM captures"
  private static let pendingCountSQL = "SELECT count(*) FROM captures WHERE ingested = 0"

  public func append(kind: String, payload: String, at timestamp: Date = Date()) throws {
    try dbQueue.write { database in
      try database.execute(
        sql: "INSERT INTO captures(ts, kind, payload) VALUES(?, ?, ?)",
        arguments: [timestamp.ISO8601Format(), kind, payload])
    }
  }

  public func pending() throws -> [SpoolRow] {
    try dbQueue.read { database in
      try Row.fetchAll(database, sql: "SELECT id, ts, kind, payload FROM captures WHERE ingested = 0 ORDER BY id")
        .map { row in
          let rawTimestamp = row["ts"] as String
          let parsed = try? Date(rawTimestamp, strategy: .iso8601)
          if parsed == nil {
            // `Date()` is retained deliberately: this value becomes an event's `occurredAt`, so a
            // sentinel like `.distantPast` would misdate the work and also fail the absent-transcript
            // grace check, silently dropping the row. But the substitution was invisible, and it does
            // make an unparseable row look like it just happened — so at minimum it is now on the
            // record. See the quality backlog: what such a row SHOULD do is a design question.
            let rowID = row["id"] as Int64
            Log.ingest.error("""
              Spool row \(rowID, privacy: .public) has an unparseable timestamp \
              \(rawTimestamp, privacy: .public) — substituting now
              """)
          }
          return SpoolRow(
            id: row["id"],
            timestamp: parsed ?? Date(),
            kind: row["kind"],
            payload: row["payload"])
        }
    }
  }

  public func markIngested(_ ids: [Int64]) throws {
    guard !ids.isEmpty else { return }
    try dbQueue.write { database in
      let placeholders = ids.map { _ in "?" }.joined(separator: ",")
      try database.execute(
        sql: "UPDATE captures SET ingested = 1 WHERE id IN (\(placeholders))",
        arguments: StatementArguments(ids))
    }
  }

  /// Explicitly checkpoints and closes the underlying connection. Not needed on the ordinary
  /// capture path — a `CaptureSpool` that goes out of scope closes on deinit too, and GRDB
  /// documents that as sufficient for most callers — but `StoreRelocator` copies this file at the
  /// filesystem level immediately after opening a spool in WAL mode, and that copy's correctness
  /// depends on the WAL being folded back into the main file first, which deinit timing alone does
  /// not promise.
  func close() throws { try dbQueue.close() }

  /// Newest capture timestamp across ALL rows (including already-ingested), or nil if empty.
  /// This is the real-time "last capture" heartbeat and must survive ingestion.
  public func lastCaptureAt() throws -> Date? {
    try dbQueue.read { database in
      guard let iso = try String.fetchOne(database, sql: Self.newestTimestampSQL) else { return nil }
      return try? Date(iso, strategy: .iso8601)
    }
  }

  /// Count of un-ingested rows (ingested = 0) without materializing them.
  public func pendingCount() throws -> Int {
    try dbQueue.read { database in
      try Int.fetchOne(database, sql: Self.pendingCountSQL) ?? 0
    }
  }

  /// Opens an EXISTING spool file strictly read-only (no WAL pragma, no CREATE TABLE, no
  /// possibility of writing) and returns the same two heartbeat facts as
  /// `lastCaptureAt()`/`pendingCount()`. For read-only observers (e.g. `MonitorSnapshot`) that must
  /// never contend with the sacred capture path.
  public static func readOnlyStats(at url: URL) throws -> (lastCaptureAt: Date?, pending: Int) {
    var config = Configuration()
    config.readonly = true
    config.busyMode = .timeout(5)
    let dbQueue = try DatabaseQueue(path: url.path, configuration: config)
    return try dbQueue.read { database in
      let lastCaptureAt: Date?
      if let iso = try String.fetchOne(database, sql: Self.newestTimestampSQL) {
        lastCaptureAt = try? Date(iso, strategy: .iso8601)
      } else {
        lastCaptureAt = nil
      }
      let pending = try Int.fetchOne(database, sql: Self.pendingCountSQL) ?? 0
      return (lastCaptureAt, pending)
    }
  }
}
