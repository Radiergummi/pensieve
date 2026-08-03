import Foundation
import SQLiteData   // re-exports GRDB
import GRDB

public struct SearchIndexHit: Sendable {
  public let itemID: String, kind: String, nodeID: String, state: String, score: Double
}

/// A small, disposable, device-local FTS5 index over the same corpus the semantic index uses
/// (shared across app / CLI / daemon / MCP). Deliberately NOT the canonical store — losing the
/// file costs only a rebuild, which is milliseconds for the whole corpus.
///
/// FTS5 is reached through raw SQL: it ships in the system SQLite (verified on 3.51.0), so unlike
/// sqlite-vec it needs no vendored C target and no per-connection registration. GRDB's Swift-level
/// FTS5 API is conditionally compiled and deliberately unused.
public struct SearchIndexStore: Sendable {
  private static let schemaVersion = 1
  /// Column order fixes the bm25 weights: text 1.0, files 0.1. UNINDEXED columns are still stored
  /// and filterable; their positional weights default to 1.0 and are inert (they never match).
  private static let ranking = "bm25(documents, 1.0, 0.1)"

  private let database: (any DatabaseWriter)?
  public var isAvailable: Bool { database != nil }

  /// Best-effort: on a corrupt/unopenable file, or one from an older schema, it drops and retries
  /// once; if that still fails the index disables itself (all operations no-op) and callers
  /// degrade to `state() == .absent` rather than to a silent empty result.
  public init(url: URL) {
    if let opened = Self.open(url) {
      self.database = opened
    } else {
      try? FileManager.default.removeItem(at: url)
      self.database = Self.open(url)
      if self.database == nil {
        Log.semantic.error("SearchIndexStore: failed to open index after delete-and-retry at \(url.path, privacy: .public)")
      }
    }
  }

  private static func open(_ url: URL) -> (any DatabaseWriter)? {
    do {
      try PensievePaths.ensureParentDirectory(of: url)
      var configuration = Configuration()
      configuration.busyMode = .timeout(5)   // app / daemon / CLI / MCP all open this file
      let pool = try DatabasePool(path: url.path, configuration: configuration)
      try pool.write { database in
        let storedVersion = try? Int.fetchOne(database, sql: "SELECT schema_version FROM meta")
        if storedVersion != schemaVersion {
          try database.execute(sql: "DROP TABLE IF EXISTS documents")
          try database.execute(sql: "DROP TABLE IF EXISTS meta")
        }
        try database.execute(sql: """
          CREATE VIRTUAL TABLE IF NOT EXISTS documents USING fts5(
            text, files,
            item_id UNINDEXED, kind UNINDEXED, node_id UNINDEXED, state UNINDEXED,
            tokenize = 'unicode61 remove_diacritics 2')
          """)
        try database.execute(sql: """
          CREATE TABLE IF NOT EXISTS meta(
            schema_version INT, corpus_hash TEXT, building INT NOT NULL DEFAULT 0)
          """)
        if storedVersion != schemaVersion {
          try database.execute(sql: "INSERT INTO meta(schema_version, corpus_hash, building) VALUES (?, NULL, 0)",
                               arguments: [schemaVersion])
        }
      }
      return pool
    } catch { return nil }
  }

  public func state() -> SearchIndexState {
    guard let database else { return .absent }
    // `try?` over a fetchOne makes this doubly optional (read failed vs no row) — both mean
    // "cannot answer", so flatten and treat either as absent.
    let fetched = try? database.read { database in
      try Row.fetchOne(database, sql: "SELECT corpus_hash, building FROM meta")
    }
    guard let row = fetched ?? nil else { return .absent }
    if (row["building"] as Int?) == 1 { return .building }
    return (row["corpus_hash"] as String?) == nil ? .absent : .ready
  }

  public func storedCorpusHash() -> String? {
    guard let database else { return nil }
    let fetched = try? database.read { database in
      try String.fetchOne(database, sql: "SELECT corpus_hash FROM meta")
    }
    return fetched ?? nil
  }

  /// Drop and reinsert everything in one transaction. Whole-rebuild rather than reconciliation:
  /// FTS5 insertion is cheap (the whole corpus is milliseconds), and a rebuild has no staleness
  /// bugs to reimplement. The `building` flag makes an interrupted rebuild observable instead of
  /// leaving a half-filled index that reads as `ready`.
  public func rebuild(items: [EmbeddableItem], corpusHash: String) {
    guard let database else { return }
    try? database.write { database in
      try database.execute(sql: "UPDATE meta SET building = 1")
    }
    do {
      try database.write { database in
        try database.execute(sql: "DELETE FROM documents")
        for item in items {
          try database.execute(sql: """
            INSERT INTO documents(text, files, item_id, kind, node_id, state)
            VALUES (?, ?, ?, ?, ?, ?)
            """, arguments: [item.text, item.files, item.itemID, item.kind, item.nodeID, item.state])
        }
        try database.execute(sql: "UPDATE meta SET corpus_hash = ?, building = 0",
                             arguments: [corpusHash])
      }
    } catch {
      Log.semantic.error("SearchIndexStore: rebuild failed: \(error, privacy: .public)")
      try? database.write { database in try database.execute(sql: "UPDATE meta SET building = 0") }
    }
  }

  /// `includeArchived: false` returns active items only; `true` widens to active + archived.
  /// `muted` is excluded in BOTH modes — an allow-list, never a deny-list, so a future state can
  /// never leak in by omission. The SQL fragment is chosen from a Bool (no interpolated caller
  /// input) and the MATCH expression comes from `FTSQueryBuilder`, so there is no injection surface.
  public func search(_ query: FTSQuery, limit: Int, includeArchived: Bool) -> [SearchIndexHit] {
    guard let database else { return [] }
    let stateFilter = includeArchived
      ? "AND state IN ('active','archived')"
      : "AND state = 'active'"
    return (try? database.read { database in
      try Row.fetchAll(database, sql: """
        SELECT item_id, kind, node_id, state, -\(Self.ranking) AS score
        FROM documents
        WHERE documents MATCH ? \(stateFilter)
        ORDER BY \(Self.ranking)
        LIMIT ?
        """, arguments: [query.match, limit]).map { row in
        SearchIndexHit(itemID: row["item_id"], kind: row["kind"], nodeID: row["node_id"],
                       state: row["state"], score: row["score"])
      }
    }) ?? []
  }
}
