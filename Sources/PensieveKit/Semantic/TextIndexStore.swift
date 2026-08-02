import Foundation
import SQLiteData   // re-exports GRDB
import GRDB

public struct BM25Result: Sendable {
  public let itemID: String, kind: String, nodeID: String
  /// Relevance in BM25's own units, **negated so higher is better**. Unbounded and scaled per
  /// query (it moves with query length and idf mass) — comparable only *within* one result set,
  /// never across queries and never against a cosine similarity.
  public let score: Double
}

/// The keyword retrieval index: one FTS5 table over the same `EmbeddableCorpus` items the vector
/// index used, ranked by SQLite's `bm25()` at its default k1=1.2 / b=0.75 — the configuration the
/// spec's measurements used. Deliberately NOT the canonical store and not the vector store:
/// losing the file costs one rebuild, and it must stay open even when sqlite-vec can't register.
///
/// Rebuild is whole-table and fingerprint-gated rather than incrementally reconciled: the corpus is
/// a couple of thousand short rows, a full rewrite is milliseconds and cannot drift, and the stored
/// fingerprint makes the (overwhelmingly common) unchanged case free.
public struct TextIndexStore: Sendable {
  private let db: (any DatabaseWriter)?
  public var isAvailable: Bool { db != nil }

  /// Opens (creating if needed) the index at `url`. Best-effort, mirroring `SemanticIndexStore`:
  /// on a corrupt/unopenable file it deletes and retries once; if that also fails the store is
  /// disabled (every op no-ops, `isAvailable == false`) and callers degrade to exact search alone.
  public init(url: URL) {
    if let opened = Self.open(url) {
      self.db = opened
    } else {
      try? FileManager.default.removeItem(at: url)
      self.db = Self.open(url)
      if self.db == nil {
        Log.semantic.error("TextIndexStore: failed to open index after delete-and-retry at \(url.path, privacy: .public)")
      }
    }
  }

  private static func open(_ url: URL) -> (any DatabaseWriter)? {
    do {
      try PensievePaths.ensureParentDirectory(of: url)
      var config = Configuration()
      config.busyMode = .timeout(5)   // cross-process writer contention (app / daemon / MCP), matching CanonicalStore
      let pool = try DatabasePool(path: url.path, configuration: config)
      try pool.write { db in
        // Only `text` is indexed; the rest are UNINDEXED metadata carried for filtering and for
        // handing the query layer enough to re-resolve each hit against canonical.
        try db.execute(sql: """
          CREATE VIRTUAL TABLE IF NOT EXISTS docs USING fts5(
            item_id UNINDEXED, kind UNINDEXED, node_id UNINDEXED, state UNINDEXED, text,
            tokenize = 'unicode61 remove_diacritics 2')
          """)
        try db.execute(sql: "CREATE TABLE IF NOT EXISTS meta(fingerprint TEXT)")
      }
      return pool
    } catch { return nil }
  }

  /// Rewrite the index from `items` unless its fingerprint is unchanged. Returns true when the
  /// table was actually rewritten. One `write` (implicitly BEGIN IMMEDIATE in GRDB), so a
  /// concurrent app/daemon rebuild serialises instead of interleaving a half-empty index.
  @discardableResult
  public func rebuild(items: [EmbeddableItem]) -> Bool {
    guard let db else { return false }
    let fp = Self.fingerprint(items)
    return (try? db.write { db -> Bool in
      if try String.fetchOne(db, sql: "SELECT fingerprint FROM meta") == fp { return false }
      try db.execute(sql: "DELETE FROM docs")
      for i in items {
        try db.execute(sql: """
          INSERT INTO docs(item_id, kind, node_id, state, text) VALUES (?, ?, ?, ?, ?)
          """, arguments: [i.itemID, i.kind, i.nodeID, i.state, i.text])
      }
      try db.execute(sql: "DELETE FROM meta")
      try db.execute(sql: "INSERT INTO meta(fingerprint) VALUES (?)", arguments: [fp])
      return true
    }) ?? false
  }

  /// Top-`k` BM25 matches, best first. `includeArchived: false` returns active items only; `true`
  /// widens to active + archived. The state filter is an allow-list, never a deny-list, so a future
  /// state can never leak in by omission — same shape as `SemanticIndexStore.knn`. The SQL fragment
  /// is chosen from a Bool (no interpolated caller input), so there is no injection surface; the
  /// user's text reaches SQLite only as a bound parameter.
  public func search(query: String, k: Int, includeArchived: Bool) -> [BM25Result] {
    guard let db, k > 0, let match = Self.matchExpression(for: query) else { return [] }
    let filter = includeArchived
      ? "AND state IN ('active','archived')"
      : "AND state = 'active'"
    return (try? db.read { db in
      try Row.fetchAll(db, sql: """
        SELECT item_id, kind, node_id, bm25(docs) AS rank_score FROM docs
        WHERE docs MATCH ? \(filter) ORDER BY bm25(docs) LIMIT ?
        """, arguments: [match, k]).map { r in
        // bm25() is negative with more-negative = better; negate so callers can treat the score
        // like every other relevance number in the codebase (higher is better). Bound to an
        // explicitly typed local — GRDB's Row subscript is generic, and an inline `as Double`
        // leaves the overload ambiguous.
        let raw: Double = r["rank_score"]
        return BM25Result(itemID: r["item_id"], kind: r["kind"], nodeID: r["node_id"], score: -raw)
      }
    }) ?? []
  }

  /// Fingerprint of the whole corpus: every field that lands in a row, sorted so gather order can
  /// never look like a change. Includes `state`/`node_id`/`kind` as well as the text hash — an
  /// archive flip or a strand repoint changes filter and attribution columns with identical text.
  /// FNV-1a, not `hashValue` (which is per-process salted and would rebuild on every launch).
  static func fingerprint(_ items: [EmbeddableItem]) -> String {
    var h: UInt64 = 1469598103934665603
    for s in items.map({ "\($0.itemID)|\($0.kind)|\($0.nodeID)|\($0.state)|\($0.contentHash)" }).sorted() {
      for b in s.utf8 { h = (h ^ UInt64(b)) &* 1099511628211 }
      h = (h ^ 0x0a) &* 1099511628211        // record separator: "ab"+"c" must not hash as "a"+"bc"
    }
    return String(h, radix: 16)
  }

  /// Build an FTS5 MATCH expression from raw user text. Tokenises the way the index's `unicode61`
  /// tokenizer does (letters and digits are word characters, everything else separates), drops
  /// 1-character tokens, de-dupes, and **quotes every term** so a user typing an FTS5 keyword
  /// (`AND`, `OR`, `NOT`, `NEAR`) or a bare `*` gets a literal match instead of an operator or a
  /// syntax error. Terms are OR-ed — a document scores on ANY query term and `bm25()` then ranks by
  /// how many and how rare — which is the configuration the spec measured (`rprobe2.swift:80`);
  /// switching to AND would invalidate that evidence. Capped at 32 terms so a pasted paragraph
  /// can't build an expression deep enough to trip SQLITE_MAX_EXPR_DEPTH. Returns nil when nothing
  /// usable survives, which the caller turns into an empty result (an empty MATCH is a syntax error).
  static func matchExpression(for raw: String) -> String? {
    var seen = Set<String>()
    let terms = raw.lowercased()
      .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
      .map(String.init)
      .filter { $0.count >= 2 && seen.insert($0).inserted }
      .prefix(32)
    guard !terms.isEmpty else { return nil }
    return terms
      .map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
      .joined(separator: " OR ")
  }
}
