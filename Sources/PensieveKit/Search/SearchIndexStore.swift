import Foundation
import SQLiteData   // re-exports GRDB
import GRDB

/// One index row that matched. Deliberately carries no `state`: the index's copy is only ever used
/// to decide eligibility inside the SQL allow-list, and handing callers a stale duplicate of a
/// canonical field invites filtering on it instead of on the live `Node`.
public struct SearchIndexHit: Sendable {
  public let itemID: String, kind: String, nodeID: String, score: Double
}

/// A small, disposable, device-local FTS5 index over the same corpus the semantic index uses
/// (shared across app / CLI / daemon / MCP). Deliberately NOT the canonical store — losing the
/// file costs only a rebuild, which is milliseconds for the whole corpus.
///
/// FTS5 is reached through raw SQL: it ships in the system SQLite (verified on 3.51.0), so unlike
/// sqlite-vec it needs no vendored C target and no per-connection registration. GRDB's Swift-level
/// FTS5 API is conditionally compiled and deliberately unused.
public struct SearchIndexStore: Sendable {
  private static let schemaVersion = 2
  /// Ranking always comes from the TEXT table. Paths never contribute a score to a text query —
  /// `.textRestrictedByPath` uses them to narrow the candidate set, and `.textWithPathProbe`
  /// surfaces rows the text index could not find at all, ranked by their own path relevance in a
  /// separate list appended BELOW the text hits.
  private static let ranking = "bm25(documents)"
  private static let filesRanking = "bm25(document_files)"

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
        Log.search.error("SearchIndexStore: failed to open index after delete-and-retry at \(url.path, privacy: .public)")
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
          try database.execute(sql: "DROP TABLE IF EXISTS document_files")
          try database.execute(sql: "DROP TABLE IF EXISTS meta")
        }
        // Two tables, not one table with two columns. FTS5 normalises bm25 by the row's TOTAL token
        // count across all columns, so carrying paths beside the text discounted every commit's text
        // matches against nodes and loose ends — measurably (P@1 0.395 → 0.378, McNemar p = 0.017,
        // n = 1500). A per-column weight cannot fix that; it bounds what a path MATCH scores, not
        // what a path's PRESENCE costs. Splitting the tables restores the text ranking exactly.
        try database.execute(sql: """
          CREATE VIRTUAL TABLE IF NOT EXISTS documents USING fts5(
            text,
            item_id UNINDEXED, kind UNINDEXED, node_id UNINDEXED, state UNINDEXED,
            tokenize = 'unicode61 remove_diacritics 2')
          """)
        try database.execute(sql: """
          CREATE VIRTUAL TABLE IF NOT EXISTS document_files USING fts5(
            files,
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
    // A failed read and a missing row both flatten to nil, and both mean "cannot answer" — which is
    // exactly `.absent`, so neither needs distinguishing.
    let row = try? database.read { database in
      try Row.fetchOne(database, sql: "SELECT corpus_hash, building FROM meta")
    }
    guard let row else { return .absent }
    if (row["building"] as Int?) == 1 { return .building }
    return (row["corpus_hash"] as String?) == nil ? .absent : .ready
  }

  public func storedCorpusHash() -> String? {
    guard let database else { return nil }
    return try? database.read { database in
      try String.fetchOne(database, sql: "SELECT corpus_hash FROM meta")
    }
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
        try database.execute(sql: "DELETE FROM document_files")
        // Prepared once, not per row: `execute(sql:)` re-compiles its statement on every call, and
        // a whole-corpus rebuild is thousands of identical inserts.
        let documentInsert = try database.cachedStatement(sql: """
          INSERT INTO documents(text, item_id, kind, node_id, state) VALUES (?, ?, ?, ?, ?)
          """)
        let fileInsert = try database.cachedStatement(sql: """
          INSERT INTO document_files(files, item_id, kind, node_id, state) VALUES (?, ?, ?, ?, ?)
          """)
        for item in items {
          try documentInsert.execute(
            arguments: [item.text, item.itemID, item.kind, item.nodeID, item.state])
          // Only rows that actually carry paths — an empty row would be dead weight in the path
          // index and would skew its own average document length.
          guard !item.files.isEmpty else { continue }
          try fileInsert.execute(
            arguments: [item.files, item.itemID, item.kind, item.nodeID, item.state])
        }
        try database.execute(sql: "UPDATE meta SET corpus_hash = ?, building = 0",
                             arguments: [corpusHash])
      }
    } catch {
      Log.search.error("SearchIndexStore: rebuild failed: \(error, privacy: .public)")
      try? database.write { database in try database.execute(sql: "UPDATE meta SET building = 0") }
    }
  }

  /// `includeArchived: false` returns active items only; `true` widens to active + archived.
  /// The state fragment is derived from a Bool and `NodeState`'s raw values (no interpolated caller
  /// input) and every MATCH expression comes from `FTSQueryBuilder`, so there is no injection
  /// surface.
  ///
  /// The query shape is decided by `FTSQueryBuilder`, never by inspecting strings here — this
  /// switches on it exhaustively, so adding a shape cannot silently fall through.
  public func search(_ query: FTSQuery, limit: Int, includeArchived: Bool) -> [SearchIndexHit] {
    guard database != nil else { return [] }
    switch query.shape {
    case .pathOnly(let path):
      return pathHits(matching: path, limit: limit, includeArchived: includeArchived)

    case .textRestrictedByPath(let text, let path):
      return fetch(sql: """
        SELECT d.item_id AS item_id, d.kind AS kind, d.node_id AS node_id,
               -\(Self.ranking) AS score
        FROM documents d
        JOIN document_files f ON f.item_id = d.item_id
        WHERE documents MATCH ? AND document_files MATCH ?
              AND \(Self.stateFilter(alias: "d.", includeArchived: includeArchived))
        ORDER BY \(Self.ranking) LIMIT ?
        """, arguments: [text, path, limit])

    case .textWithPathProbe(let text):
      let textHits = fetch(sql: """
        SELECT item_id, kind, node_id, -\(Self.ranking) AS score
        FROM documents
        WHERE documents MATCH ? AND \(Self.stateFilter(includeArchived: includeArchived))
        ORDER BY \(Self.ranking) LIMIT ?
        """, arguments: [text, limit])
      guard textHits.count < limit else { return textHits }

      // Append, never interleave: the two scores come from different tables with different average
      // document lengths and are not comparable, so the only honest ordering is "everything the text
      // index found, then what only the path index found".
      var seen = Set(textHits.map(\.itemID))
      var merged = textHits
      for hit in pathHits(matching: text, limit: limit, includeArchived: includeArchived)
      where seen.insert(hit.itemID).inserted {
        merged.append(hit)
        if merged.count == limit { break }
      }
      return merged
    }
  }

  /// Rows the PATH index matched, ranked by path relevance. Shared by the explicit `files:`
  /// directive and the opportunistic probe — the two differ only in where the expression came from,
  /// never in how paths are queried or scored.
  private func pathHits(matching match: String, limit: Int,
                        includeArchived: Bool) -> [SearchIndexHit] {
    fetch(sql: """
      SELECT item_id, kind, node_id, -\(Self.filesRanking) AS score
      FROM document_files
      WHERE document_files MATCH ? AND \(Self.stateFilter(includeArchived: includeArchived))
      ORDER BY \(Self.filesRanking) LIMIT ?
      """, arguments: [match, limit])
  }

  /// The SQL rendering of `NodeState.searchable(includeArchived:)` — the same allow-list the
  /// canonical re-check applies, so the two can never disagree. Built from `NodeState`'s own raw
  /// values rather than SQL string literals: this codebase turned `NodeState` into an enum precisely
  /// to kill mistyped-literal hazards, and a hand-written `'active'` here would reintroduce one the
  /// compiler cannot see.
  ///
  /// `alias` is explicit rather than left to the caller to prepend: the fragment starts with the
  /// column name, so `"d.\(fragment)"` only happens to produce valid SQL, and a shape whose first
  /// clause was not the column would break silently.
  private static func stateFilter(alias: String = "", includeArchived: Bool) -> String {
    let allowed = NodeState.searchable(includeArchived: includeArchived)
    return "\(alias)state IN (\(allowed.map { "'\($0.rawValue)'" }.joined(separator: ",")))"
  }

  /// Logs rather than swallowing silently: every plausible regression in this file — a shape routed
  /// to the wrong table, a `files :` clause reaching the text table (a hard `no such column`), schema
  /// drift — surfaces as a hard SQLite error, and without this line it would be indistinguishable
  /// from "nothing matched" while `state()` still reported `.ready`.
  private func fetch(sql: String, arguments: StatementArguments) -> [SearchIndexHit] {
    guard let database else { return [] }
    do {
      return try database.read { database in
        try Row.fetchAll(database, sql: sql, arguments: arguments).map { row in
          SearchIndexHit(itemID: row["item_id"], kind: row["kind"], nodeID: row["node_id"],
                         score: row["score"])
        }
      }
    } catch {
      Log.search.error("SearchIndexStore: query failed: \(error, privacy: .public)")
      return []
    }
  }
}
