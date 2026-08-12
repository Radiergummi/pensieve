import Foundation
import GRDB

/// Translations of model-generated text, keyed by `(field, source-text hash, language)`.
///
/// Disposable and never synced, like `narration-cache.sqlite` and `search-index.sqlite`. Losing the
/// file costs re-translation, nothing more — which is exactly why it is NOT in the canonical store:
/// `pensieve.sqlite` is the only store that will ever sync, and derived regenerable data does not
/// belong in CloudKit's future surface.
///
/// Invalidation is structural rather than swept: the key is derived from the source text, so
/// re-extraction changes the text, changes the hash, and orphans the stale row. Nothing ever reads a
/// translation of text that is no longer there. `pruneKeeping` only reclaims disk.
///
/// Hashing lives here so no caller ever handles a hash — `translation(field:sourceText:language:)`
/// and `put` both take the source text itself, which makes it impossible for a reader and a writer to
/// disagree about how the key was derived.
public struct TranslationStore: Sendable {
  private let database: (any DatabaseWriter)?

  public init(url: URL) {
    database = Self.open(url)
  }

  public var isAvailable: Bool { database != nil }

  private static func open(_ url: URL) -> (any DatabaseWriter)? {
    do {
      try PensievePaths.ensureParentDirectory(of: url)
      var configuration = Configuration()
      configuration.busyMode = .timeout(5)   // app and CLI/daemon both open this file
      let pool = try DatabasePool(path: url.path, configuration: configuration)
      try pool.write { database in
        try database.execute(sql: """
          CREATE TABLE IF NOT EXISTS translation (
            field TEXT NOT NULL, source_hash TEXT NOT NULL, language TEXT NOT NULL,
            text TEXT NOT NULL,
            PRIMARY KEY (field, source_hash, language))
          """)
      }
      return pool
    } catch {
      Log.search.error("TranslationStore: failed to open at \(url.path, privacy: .public): \(error, privacy: .public)")
      return nil
    }
  }

  /// Stable across processes and runs — `String.hashValue` is per-process salted and must never be
  /// used here. Same `StableHash` primitive `EmbeddableItem.contentHash` uses.
  static func sourceHash(_ text: String) -> String {
    var hash = StableHash()
    hash.absorb(text)
    return hash.hexValue
  }

  public func translation(field: TranslationField, sourceText: String, language: String) -> String? {
    guard let database, !language.isEmpty, !sourceText.isEmpty else { return nil }
    return try? database.read { database in
      try String.fetchOne(database, sql: """
        SELECT text FROM translation WHERE field = ? AND source_hash = ? AND language = ?
        """, arguments: [field.rawValue, Self.sourceHash(sourceText), language])
    }
  }

  public func put(field: TranslationField, sourceText: String, language: String, text: String) {
    guard let database, !language.isEmpty, !sourceText.isEmpty, !text.isEmpty else { return }
    do {
      try database.write { database in
        try database.execute(sql: """
          INSERT OR REPLACE INTO translation(field, source_hash, language, text) VALUES (?, ?, ?, ?)
          """, arguments: [field.rawValue, Self.sourceHash(sourceText), language, text])
      }
    } catch {
      Log.search.error("TranslationStore: put failed: \(error, privacy: .public)")
    }
  }

  /// Reclaim rows whose source text is no longer live. Purely disk hygiene — an orphan is already
  /// unreachable, because a lookup derives its key from text that no longer exists.
  public func pruneKeeping(sourceTexts: Set<String>) {
    guard let database else { return }
    let liveHashes = sourceTexts.map { Self.sourceHash($0) }
    do {
      try database.write { database in
        guard !liveHashes.isEmpty else {
          try database.execute(sql: "DELETE FROM translation")
          return
        }
        let placeholders = Array(repeating: "?", count: liveHashes.count).joined(separator: ",")
        try database.execute(sql: "DELETE FROM translation WHERE source_hash NOT IN (\(placeholders))",
                             arguments: StatementArguments(liveHashes))
      }
    } catch {
      Log.search.error("TranslationStore: prune failed: \(error, privacy: .public)")
    }
  }
}
