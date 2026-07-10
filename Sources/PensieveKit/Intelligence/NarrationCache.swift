import Foundation
import SQLiteData   // re-exports GRDB (DatabasePool, etc.)

/// A small, disposable, cross-process cache of node narration prose, keyed by
/// `NarrationCacheKey.make(events:provider:)`. Deliberately NOT the canonical store (whose
/// only writer stays `Ingester.drain()`) and NOT the capture spool — losing the file costs
/// only a re-narrate. Read by `pensieve prime` (cache-only) and written through by `pensieve mcp`.
public struct NarrationCache: Sendable {
  private let db: (any DatabaseWriter)?

  /// Opens (creating if needed) the cache at `url`. Best-effort: on a corrupt/unopenable file
  /// it deletes and retries once; if that still fails, the cache is disabled (all ops no-op).
  public init(url: URL) {
    if let opened = Self.open(url) {
      self.db = opened
    } else {
      try? FileManager.default.removeItem(at: url)
      self.db = Self.open(url)
    }
  }

  private static func open(_ url: URL) -> (any DatabaseWriter)? {
    do {
      try PensievePaths.ensureParentDirectory(of: url)
      let pool = try DatabasePool(path: url.path)
      try pool.write { db in
        try db.execute(sql: "CREATE TABLE IF NOT EXISTS narration (key TEXT PRIMARY KEY, prose TEXT NOT NULL)")
      }
      return pool
    } catch {
      return nil
    }
  }

  public func get(_ key: String) -> String? {
    guard let db else { return nil }
    let result = try? db.read { db -> String? in
      try String.fetchOne(db, sql: "SELECT prose FROM narration WHERE key = ?", arguments: [key])
    }
    return result ?? nil
  }

  public func put(_ key: String, prose: String) {
    guard let db else { return }
    try? db.write { db in
      try db.execute(sql: "INSERT OR REPLACE INTO narration (key, prose) VALUES (?, ?)", arguments: [key, prose])
    }
  }
}
