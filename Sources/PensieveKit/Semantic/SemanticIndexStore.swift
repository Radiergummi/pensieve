import Foundation
import SQLiteData   // re-exports GRDB
import GRDB
import CSQLiteVec

public struct IndexRow: Sendable {
  public let itemID: String, kind: String, nodeID: String, state: String, contentHash: String
  public init(itemID: String, kind: String, nodeID: String, state: String, contentHash: String) {
    self.itemID = itemID; self.kind = kind; self.nodeID = nodeID
    self.state = state; self.contentHash = contentHash
  }
}
public struct KNNResult: Sendable {
  public let itemID: String, kind: String, nodeID: String, similarity: Double
}

/// A small, disposable, device-local semantic index over sqlite-vec (shared across app / CLI /
/// daemon / MCP). Deliberately NOT the canonical store — losing the file costs only a re-index.
/// Dropped + rebuilt whole when the embedder version or vector dimension changes.
public struct SemanticIndexStore: Sendable {
  private let db: (any DatabaseWriter)?
  public var isAvailable: Bool { db != nil }

  /// Opens (creating if needed) the index at `url`. Best-effort: on a corrupt/unopenable file,
  /// or one whose stored `meta.embedder_version`/dimension no longer matches, it drops and
  /// retries once; if that still fails (e.g. sqlite-vec couldn't register), the index is
  /// disabled (all ops no-op, `isAvailable == false`) and callers degrade gracefully.
  public init(url: URL, dimension: Int, embedderVersion: String) {
    if let opened = Self.open(url, dimension: dimension, version: embedderVersion) {
      self.db = opened
    } else {
      try? FileManager.default.removeItem(at: url)
      self.db = Self.open(url, dimension: dimension, version: embedderVersion)
      if self.db == nil {
        Log.semantic.error("SemanticIndexStore: failed to open index after delete-and-retry at \(url.path, privacy: .public)")
      }
    }
  }

  /// Apple's system libsqlite3 disables `sqlite3_auto_extension()` (process-global auto
  /// extensions aren't supported on Apple platforms; it fails at runtime with SQLITE_MISUSE).
  /// The working path is per-connection registration via GRDB's `Configuration.prepareDatabase`,
  /// calling the C shim with the raw sqlite3 handle for every connection the pool opens
  /// (readers + writer) — confirmed by the Task-0 spike (`SQLiteVecSpikeTests`).
  private static func open(_ url: URL, dimension: Int, version: String) -> (any DatabaseWriter)? {
    guard dimension > 0 else { return nil }
    do {
      try PensievePaths.ensureParentDirectory(of: url)
      var config = Configuration()
      config.busyMode = .timeout(5)   // wait out cross-process writer contention (app/daemon/⌘F), matching CanonicalStore
      config.prepareDatabase { db in
        let rc = pensieve_sqlite_vec_init_connection(UnsafeMutableRawPointer(db.sqliteConnection))
        if rc != 0 {
          Log.semantic.error("SemanticIndexStore: sqlite-vec registration failed, rc=\(rc, privacy: .public)")
          throw DatabaseError(resultCode: ResultCode(rawValue: rc))
        }
      }
      let pool = try DatabasePool(path: url.path, configuration: config)
      try pool.write { db in
        // Whole-index invalidation: drop everything if the embedder version/dimension changed.
        let stored = try? Row.fetchOne(db, sql: "SELECT embedder_version, dimension FROM meta")
        let mismatch = stored == nil
          || (stored!["embedder_version"] as String?) != version
          || (stored!["dimension"] as Int?) != dimension
        if mismatch {
          try db.execute(sql: "DROP TABLE IF EXISTS embeddings")
          try db.execute(sql: "DROP TABLE IF EXISTS items")
          try db.execute(sql: "DROP TABLE IF EXISTS meta")
        }
        try db.execute(sql: """
          CREATE VIRTUAL TABLE IF NOT EXISTS embeddings USING vec0(
            item_id TEXT PRIMARY KEY, node_id TEXT, state TEXT, kind TEXT,
            embedding float[\(dimension)])
          """)
        try db.execute(sql: """
          CREATE TABLE IF NOT EXISTS items(
            item_id TEXT PRIMARY KEY, kind TEXT, node_id TEXT, state TEXT, content_hash TEXT)
          """)
        try db.execute(sql: "CREATE TABLE IF NOT EXISTS meta(embedder_version TEXT, dimension INT)")
        if mismatch {
          try db.execute(sql: "INSERT INTO meta(embedder_version, dimension) VALUES (?, ?)",
                         arguments: [version, dimension])
        }
      }
      return pool
    } catch { return nil }
  }

  public func existingItems() -> [String: String] {
    guard let db else { return [:] }
    return (try? db.read { db in
      try Row.fetchAll(db, sql: "SELECT item_id, content_hash FROM items")
        .reduce(into: [String: String]()) { $0[$1["item_id"]] = $1["content_hash"] }
    }) ?? [:]
  }

  public func upsert(row: IndexRow, embedding: [Float]?) {
    guard let db else { return }
    try? db.write { db in
      try db.execute(sql: """
        INSERT INTO items(item_id, kind, node_id, state, content_hash) VALUES (?, ?, ?, ?, ?)
        ON CONFLICT(item_id) DO UPDATE SET kind=excluded.kind, node_id=excluded.node_id,
          state=excluded.state, content_hash=excluded.content_hash
        """, arguments: [row.itemID, row.kind, row.nodeID, row.state, row.contentHash])
      if let embedding {
        let json = "[" + embedding.map { String($0) }.joined(separator: ",") + "]"
        try db.execute(sql: "DELETE FROM embeddings WHERE item_id = ?", arguments: [row.itemID])
        try db.execute(sql: """
          INSERT INTO embeddings(item_id, node_id, state, kind, embedding) VALUES (?, ?, ?, ?, ?)
          """, arguments: [row.itemID, row.nodeID, row.state, row.kind, json])
      } else {
        // Metadata-only change (repoint / state flip): keep the vector, update the vec0
        // metadata columns in place (node_id/state/kind are plain — not partition-key —
        // columns, so vec0's xUpdate supports this; confirmed against the vendored source).
        try db.execute(sql: "UPDATE embeddings SET node_id = ?, state = ?, kind = ? WHERE item_id = ?",
                       arguments: [row.nodeID, row.state, row.kind, row.itemID])
      }
    }
  }

  public func delete(itemIDs: [String]) {
    guard let db, !itemIDs.isEmpty else { return }
    let marks = Array(repeating: "?", count: itemIDs.count).joined(separator: ",")
    let args = StatementArguments(itemIDs)
    try? db.write { db in
      try db.execute(sql: "DELETE FROM embeddings WHERE item_id IN (\(marks))", arguments: args)
      try db.execute(sql: "DELETE FROM items WHERE item_id IN (\(marks))", arguments: args)
    }
  }

  public func knn(query: [Float], k: Int, activeOnly: Bool) -> [KNNResult] {
    guard let db else { return [] }
    let json = "[" + query.map { String($0) }.joined(separator: ",") + "]"
    let filter = activeOnly ? "AND state = 'active'" : ""
    return (try? db.read { db in
      try Row.fetchAll(db, sql: """
        SELECT item_id, kind, node_id, distance FROM embeddings
        WHERE embedding MATCH ? AND k = ? \(filter) ORDER BY distance
        """, arguments: [json, k]).map { r in
        KNNResult(itemID: r["item_id"], kind: r["kind"], nodeID: r["node_id"],
                  similarity: EmbeddingMath.cosine(fromL2: r["distance"]))
      }
    }) ?? []
  }
}
