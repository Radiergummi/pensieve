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
  private static let schemaVersion = 2
  /// Ranking always comes from the TEXT table. Paths never contribute a score — they restrict
  /// (`filesFilter`) or they surface a row the text index could not (`filesProbe`), and in the
  /// latter case the row is ranked by its own path relevance in a separate result list that is
  /// merged BELOW the text hits.
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
    // `try?` over a fetchOne already flattens to a single optional since SE-0230 (the `?? nil`
    // below is a harmless no-op, kept so a future Optional-returning change here stays safe) —
    // read failed and no row both surface as nil, and both mean "cannot answer", so treat nil as
    // absent either way.
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
        try database.execute(sql: "DELETE FROM document_files")
        for item in items {
          try database.execute(sql: """
            INSERT INTO documents(text, item_id, kind, node_id, state)
            VALUES (?, ?, ?, ?, ?)
            """, arguments: [item.text, item.itemID, item.kind, item.nodeID, item.state])
          // Only rows that actually carry paths — an empty row would be dead weight in the path
          // index and would skew its own average document length.
          guard !item.files.isEmpty else { continue }
          try database.execute(sql: """
            INSERT INTO document_files(files, item_id, kind, node_id, state)
            VALUES (?, ?, ?, ?, ?)
            """, arguments: [item.files, item.itemID, item.kind, item.nodeID, item.state])
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
  /// input) and every MATCH expression comes from `FTSQueryBuilder`, so there is no injection
  /// surface.
  ///
  /// Three shapes, decided by the builder, never by string inspection here:
  ///  - text only → rank by text relevance;
  ///  - text AND an explicit path restriction → join the two tables, still ranked by TEXT relevance
  ///    (the path restricts the candidate set and contributes no score);
  ///  - text with an opportunistic path probe → two queries, path hits appended BELOW the text hits
  ///    so typing a bare filename finds its commits without a path match ever outranking a real
  ///    text match.
  public func search(_ query: FTSQuery, limit: Int, includeArchived: Bool) -> [SearchIndexHit] {
    guard let database else { return [] }
    let stateFilter = includeArchived
      ? "state IN ('active','archived')"
      : "state = 'active'"

    if let filesFilter = query.filesFilter {
      guard !query.match.isEmpty else {
        return fetch(sql: """
          SELECT item_id, kind, node_id, state, -\(Self.filesRanking) AS score
          FROM document_files
          WHERE document_files MATCH ? AND \(stateFilter)
          ORDER BY \(Self.filesRanking) LIMIT ?
          """, arguments: [filesFilter, limit])
      }
      return fetch(sql: """
        SELECT d.item_id AS item_id, d.kind AS kind, d.node_id AS node_id, d.state AS state,
               -\(Self.ranking) AS score
        FROM documents d
        JOIN document_files f ON f.item_id = d.item_id
        WHERE documents MATCH ? AND document_files MATCH ? AND d.\(stateFilter)
        ORDER BY \(Self.ranking) LIMIT ?
        """, arguments: [query.match, filesFilter, limit])
    }

    let textHits = fetch(sql: """
      SELECT item_id, kind, node_id, state, -\(Self.ranking) AS score
      FROM documents
      WHERE documents MATCH ? AND \(stateFilter)
      ORDER BY \(Self.ranking) LIMIT ?
      """, arguments: [query.match, limit])

    guard let filesProbe = query.filesProbe, textHits.count < limit else { return textHits }
    let pathHits = fetch(sql: """
      SELECT item_id, kind, node_id, state, -\(Self.filesRanking) AS score
      FROM document_files
      WHERE document_files MATCH ? AND \(stateFilter)
      ORDER BY \(Self.filesRanking) LIMIT ?
      """, arguments: [filesProbe, limit])

    // Append, never interleave: the two scores come from different tables with different average
    // document lengths and are not comparable, so the only honest ordering is "everything the text
    // index found, then what only the path index found".
    var seen = Set(textHits.map(\.itemID))
    var merged = textHits
    for hit in pathHits where seen.insert(hit.itemID).inserted {
      merged.append(hit)
      if merged.count == limit { break }
    }
    return merged
  }

  private func fetch(sql: String, arguments: StatementArguments) -> [SearchIndexHit] {
    guard let database else { return [] }
    return (try? database.read { database in
      try Row.fetchAll(database, sql: sql, arguments: arguments).map { row in
        SearchIndexHit(itemID: row["item_id"], kind: row["kind"], nodeID: row["node_id"],
                       state: row["state"], score: row["score"])
      }
    }) ?? []
  }
}
