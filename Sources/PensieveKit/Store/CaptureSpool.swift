import Foundation
import SQLiteData   // for GRDB's DatabaseQueue / Row APIs
import GRDB

public struct SpoolRow: Sendable {
  public let id: Int64
  public let ts: Date
  public let kind: String
  public let payload: String
}

public final class CaptureSpool {
  private let dbQueue: DatabaseQueue

  public init(at url: URL) throws {
    try PensievePaths.ensureParentDirectory(of: url)
    var config = Configuration()
    config.busyMode = .timeout(5)
    self.dbQueue = try DatabaseQueue(path: url.path, configuration: config)
    try dbQueue.write { db in
      try db.execute(sql: """
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

  public func append(kind: String, payload: String, at: Date = Date()) throws {
    try dbQueue.write { db in
      try db.execute(
        sql: "INSERT INTO captures(ts, kind, payload) VALUES(?, ?, ?)",
        arguments: [at.ISO8601Format(), kind, payload])
    }
  }

  public func pending() throws -> [SpoolRow] {
    try dbQueue.read { db in
      try Row.fetchAll(db, sql: "SELECT id, ts, kind, payload FROM captures WHERE ingested = 0 ORDER BY id")
        .map { row in
          SpoolRow(
            id: row["id"],
            ts: (try? Date(row["ts"] as String, strategy: .iso8601)) ?? Date(),
            kind: row["kind"],
            payload: row["payload"])
        }
    }
  }

  public func markIngested(_ ids: [Int64]) throws {
    guard !ids.isEmpty else { return }
    try dbQueue.write { db in
      let placeholders = ids.map { _ in "?" }.joined(separator: ",")
      try db.execute(
        sql: "UPDATE captures SET ingested = 1 WHERE id IN (\(placeholders))",
        arguments: StatementArguments(ids))
    }
  }
}
