import Foundation
import SQLiteData   // re-exports GRDB
import GRDB

/// One index row that matched. Deliberately carries no `state`: the index's copy is only ever used
/// to decide eligibility inside the SQL allow-list, and handing callers a stale duplicate of a
/// canonical field invites filtering on it instead of on the live `Node`.
public struct SearchIndexHit: Sendable {
  public let itemID: String, kind: String, nodeID: String, score: Double
}

/// A small, disposable, device-local FTS5 index over the corpus `EmbeddableCorpus.gather` produces
/// (shared across app / CLI / daemon / MCP). Deliberately NOT the canonical store — losing the
/// file costs only a rebuild, which is milliseconds for the whole corpus.
///
/// FTS5 is reached through raw SQL: it ships in the system SQLite (verified on 3.51.0), so it needs
/// no vendored C target and no per-connection extension registration. GRDB's Swift-level
/// FTS5 API is conditionally compiled and deliberately unused.
public struct SearchIndexStore: Sendable {
  private static let schemaVersion = 5
  /// Ranking always comes from the TEXT table. Paths never contribute a score to a text query —
  /// `.textRestrictedByPath` uses them to narrow the candidate set, and `.textWithPathProbe`
  /// surfaces rows the text index could not find at all, ranked by their own path relevance in a
  /// separate list appended BELOW the text hits.
  private static let ranking = "bm25(documents)"
  /// The FTS5 tokenizer every table here is built with. One definition: three tables spelling it out
  /// separately was three chances to change one and leave the others behind. **Coupled to
  /// `FindMatcher.options`**, which must keep folding diacritics for as long as this says
  /// `remove_diacritics 2` — retrieval matches `losung` against `Lösung`, and a case-only in-node
  /// find would hand back a real hit it then highlights nothing in. Change both together.
  private static let tokenizer = "tokenize = 'unicode61 remove_diacritics 2'"

  private let database: (any DatabaseWriter)?
  public var isAvailable: Bool { database != nil }

  /// Best-effort: on a corrupt/unopenable file, or one from an older schema, it drops and retries
  /// once; if that still fails the index disables itself (all operations no-op) and callers
  /// degrade to `state() == .absent` rather than to a silent empty result.
  public init(url: URL) {
    if let opened = Self.open(url) {
      self.database = opened
    } else {
      Self.removeIndexFiles(at: url)
      self.database = Self.open(url)
      if self.database == nil {
        Log.search.error("SearchIndexStore: failed to open index after delete-and-retry at \(url.path, privacy: .public)")
      }
    }
  }

  /// The whole index, sidecars included — a WAL-mode SQLite database is THREE files, and deleting
  /// only the main one orphaned the `-wal`/`-shm` pair beside the recreated database.
  /// `StoreRelocator.canonicalStoreFileNames` enumerates the same three names for the canonical
  /// store; this is that rule for the index. Absent sidecars are normal, hence best-effort `try?`.
  /// Measured: SQLite does NOT resurrect the orphans — it validates the WAL header against the
  /// freshly created database and discards a mismatched one, so delete-and-retry produced a working
  /// index either way. Hygiene with a matching precedent, then, not a fix for a reachable failure,
  /// which is why this is internal: the enumeration can be pinned, the behaviour cannot.
  static func removeIndexFiles(at url: URL) {
    let manager = FileManager.default
    for path in [url.path, url.path + "-wal", url.path + "-shm"] {
      try? manager.removeItem(atPath: path)
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
          try database.execute(sql: "DROP TABLE IF EXISTS document_passages")
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
            language UNINDEXED, item_status UNINDEXED,
            \(tokenizer))
          """)
        try database.execute(sql: """
          CREATE VIRTUAL TABLE IF NOT EXISTS document_files USING fts5(
            files,
            item_id UNINDEXED, kind UNINDEXED, node_id UNINDEXED, state UNINDEXED,
            \(tokenizer))
          """)
        // A THIRD table, for the same measured reason `document_files` is separate: FTS5 normalises
        // bm25() by a row's TOTAL token count, so putting 1,500-character passages beside 40-character
        // node names would discount every existing hit. Sharing one table regressed P@1 0.395 → 0.378
        // (McNemar p = 0.017, n = 1500) when this was tried with file paths. Passage scores are
        // therefore NOT comparable to text scores, which is why passage results are a separate,
        // appended list rather than merged into the ranked one.
        //
        // No `item_status`: a passage has no lifecycle of its own. If a future producer gives one to
        // a passage, add the filter here AND in the canonical re-check, in the same commit.
        try database.execute(sql: """
          CREATE VIRTUAL TABLE IF NOT EXISTS document_passages USING fts5(
            text,
            item_id UNINDEXED, kind UNINDEXED, node_id UNINDEXED, state UNINDEXED,
            \(tokenizer))
          """)
        try database.execute(sql: """
          CREATE TABLE IF NOT EXISTS meta(
            schema_version INT, corpus_hash TEXT, building INT NOT NULL DEFAULT 0,
            passages_hash TEXT)
          """)
        if storedVersion != schemaVersion {
          try database.execute(sql: """
            INSERT INTO meta(schema_version, corpus_hash, building, passages_hash)
            VALUES (?, NULL, 0, NULL)
            """, arguments: [schemaVersion])
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

  public func storedPassagesHash() -> String? {
    guard let database else { return nil }
    return try? database.read { database in
      try String.fetchOne(database, sql: "SELECT passages_hash FROM meta")
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
          INSERT INTO documents(text, item_id, kind, node_id, state, language, item_status)
          VALUES (?, ?, ?, ?, ?, ?, ?)
          """)
        let fileInsert = try database.cachedStatement(sql: """
          INSERT INTO document_files(files, item_id, kind, node_id, state) VALUES (?, ?, ?, ?, ?)
          """)
        for item in items {
          // Symmetric with the `files` guard below, same reason: an empty row is dead weight that
          // also drags the table's average document length, which bm25 normalises by. The producer
          // relies on it — a repeated event text is emitted as a paths-only item so its files stay
          // searchable (see `EmbeddableCorpus.appendEventDocuments`).
          if !item.text.isEmpty {
            try documentInsert.execute(
              arguments: [item.text, item.itemID, item.kind, item.nodeID, item.state, item.language,
                          item.status])
          }
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

  /// Whole-rebuild of the passage table ONLY. Deliberately does not touch `documents`,
  /// `document_files`, `corpus_hash`, or the `building` flag: the two indexes rebuild on their own
  /// hashes, so a new commit does not rewrite tens of thousands of unchanged passage rows.
  ///
  /// `building` is not reused here because it describes the text index's state, which `state()`
  /// reports to the UI. A passage rebuild in flight must not make ⌥⌘F claim the whole index is
  /// building.
  public func rebuildPassages(items: [EmbeddableItem], passagesHash: String) {
    guard let database else { return }
    do {
      try database.write { database in
        try database.execute(sql: "DELETE FROM document_passages")
        let insert = try database.cachedStatement(sql: """
          INSERT INTO document_passages(text, item_id, kind, node_id, state)
          VALUES (?, ?, ?, ?, ?)
          """)
        for item in items {
          try insert.execute(arguments: [item.text, item.itemID, item.kind, item.nodeID, item.state])
        }
        try database.execute(sql: "UPDATE meta SET passages_hash = ?", arguments: [passagesHash])
      }
    } catch {
      Log.search.error("SearchIndexStore: passage rebuild failed: \(error, privacy: .public)")
    }
  }

  /// `includeArchived: false` returns active items only; `true` widens to active + archived.
  /// The state fragment is derived from a Bool and `NodeState`'s raw values (no interpolated caller
  /// input) and every MATCH expression comes from `FTSQueryBuilder`, so there is no injection
  /// surface.
  ///
  /// The query shape is decided by `FTSQueryBuilder`, never by inspecting strings here — this
  /// switches on it exhaustively, so adding a shape cannot silently fall through.
  public func search(_ query: FTSQuery, limit: Int, includeArchived: Bool,
                     includeClosed: Bool = false) -> [SearchIndexHit] {
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
              AND \(Self.statusFilter(alias: "d.", includeClosed: includeClosed))
        ORDER BY \(Self.ranking) LIMIT ?
        """, arguments: [text, path, limit])

    case .textWithPathProbe(let text):
      let textHits = fetch(sql: """
        SELECT item_id, kind, node_id, -\(Self.ranking) AS score
        FROM documents
        WHERE documents MATCH ? AND \(Self.stateFilter(includeArchived: includeArchived))
              AND \(Self.statusFilter(includeClosed: includeClosed))
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

  /// Passage candidates for a text query — but ONLY for a query carrying no path restriction.
  ///
  /// A passage has no file paths of its own: it comes from a conversation, not from a commit, so it
  /// can never satisfy a path clause. Both restricted shapes therefore return nothing rather than a
  /// list of prose matches that quietly ignore the narrowing the user asked for. `.pathOnly` is
  /// obvious; `.textRestrictedByPath` is the one that matters, because dropping its path half and
  /// matching the text alone is exactly how a `files:` directive (typed, or passed as MCP `search`'s
  /// structured `file` parameter) ends up returning passages from work that never touched the file,
  /// in the same array as ranked hits that were correctly restricted.
  public func searchPassages(_ query: FTSQuery, limit: Int,
                             includeArchived: Bool) -> [SearchIndexHit] {
    guard database != nil else { return [] }
    let match: String
    switch query.shape {
    case .pathOnly, .textRestrictedByPath: return []
    case .textWithPathProbe(let text): match = text
    }
    return rankedHits(in: "document_passages", matching: match, limit: limit,
                      includeArchived: includeArchived)
  }

  /// Rows the PATH index matched, ranked by path relevance. Shared by the explicit `files:`
  /// directive and the opportunistic probe — the two differ only in where the expression came from,
  /// never in how paths are queried or scored.
  private func pathHits(matching match: String, limit: Int,
                        includeArchived: Bool) -> [SearchIndexHit] {
    rankedHits(in: "document_files", matching: match, limit: limit,
               includeArchived: includeArchived)
  }

  /// One satellite table's own BM25-ranked candidates. `document_files` and `document_passages`
  /// differ only in which table they read — same projection, same state allow-list, same ordering —
  /// so they share one body rather than two SQL strings that must be kept in step. Only the two
  /// single-table shapes come here; `documents` is not one of them, because its queries also carry
  /// the status filter and the join that `.textRestrictedByPath` needs.
  ///
  /// `table` is a compile-time literal from the two call sites below, never caller input, so
  /// interpolating it into the SQL adds no injection surface (`stateFilter` is likewise derived
  /// from `NodeState`'s own raw values, and the MATCH expression comes from `FTSQueryBuilder`).
  private func rankedHits(in table: String, matching match: String, limit: Int,
                          includeArchived: Bool) -> [SearchIndexHit] {
    fetch(sql: """
      SELECT item_id, kind, node_id, -bm25(\(table)) AS score
      FROM \(table)
      WHERE \(table) MATCH ? AND \(Self.stateFilter(includeArchived: includeArchived))
      ORDER BY bm25(\(table)) LIMIT ?
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

  /// The SQL rendering of `LooseEndStatus.searchable(includeClosed:)` — the same allow-list the
  /// canonical re-check applies, built from the enum's own raw values for the same reason
  /// `stateFilter` is: a hand-written `'open'` here would reintroduce the mistyped-literal hazard
  /// this codebase converted the enums to kill.
  ///
  /// Applied only to `documents`. `document_files` holds event rows exclusively — events are not
  /// closable, and `onlyEventRowsEverCarryFilePaths` pins that — so a status filter there would be
  /// dead SQL. A future producer that puts paths on a closable item must add one.
  private static func statusFilter(alias: String = "", includeClosed: Bool) -> String {
    let allowed = LooseEndStatus.searchable(includeClosed: includeClosed)
    return "\(alias)item_status IN (\(allowed.map { "'\($0.rawValue)'" }.joined(separator: ",")))"
  }

  /// Update one document's status in place — cheap next to `rebuild`, which drops and reinserts the
  /// entire corpus. (Not free: an `UPDATE` on an fts5 table is internally a delete + reinsert of the
  /// row, term index included, even though `item_status` is UNINDEXED.) Updates every document sharing
  /// the item id, so a translated document tracks its original — leaving one behind would put a German
  /// row in a scope its English original is not in.
  ///
  /// The load-bearing direction is REOPEN, not close. A stale `done` makes the SQL filter exclude a
  /// row that is live work, and the resolver cannot rescue it — it never sees the candidate, so the
  /// end is simply unfindable (`aReopenedEndBecomesFindableAgainWithoutAFullRebuild`). A stale `open`
  /// after a close is merely wasteful: `SearchQueries.search` over-fetches and grows `k`, so it
  /// backfills around the row the resolver drops and still returns a correct, full page. An earlier
  /// version of this comment claimed a stale index shrinks the result page; two tests written to prove
  /// that passed with this method gutted, which is how the claim was found to be false.
  ///
  /// Deliberately does NOT touch `corpus_hash`: the stored hash stays stale, so the next daemon or
  /// launch sync performs exactly ONE honest full rebuild instead of nine hundred.
  public func updateStatus(itemID: String, status: String) {
    guard let database else { return }
    do {
      try database.write { database in
        try database.execute(sql: "UPDATE documents SET item_status = ? WHERE item_id = ?",
                             arguments: [status, itemID])
      }
    } catch {
      Log.search.error("SearchIndexStore: status update failed: \(error, privacy: .public)")
    }
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
