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
  // ISO8601DateFormatter isn't Sendable, but is safe to share for formatting.
  nonisolated(unsafe) private static let iso = ISO8601DateFormatter()

  public init(at url: URL) throws {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    self.dbQueue = try DatabaseQueue(path: url.path)
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
        arguments: [Self.iso.string(from: at), kind, payload])
    }
  }

  public func pending() throws -> [SpoolRow] {
    try dbQueue.read { db in
      try Row.fetchAll(db, sql: "SELECT id, ts, kind, payload FROM captures WHERE ingested = 0 ORDER BY id")
        .map { row in
          SpoolRow(
            id: row["id"],
            ts: Self.iso.date(from: row["ts"]) ?? Date(),
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
