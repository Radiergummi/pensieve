import Foundation
import SQLiteData
import GRDB

/// The `LooseEnd.label` / `.labelSuggestion` string values. Centralized like `NodeContext` /
/// `CaptureKind` so a typo can't silently misfile a label. `""` = unlabeled (the default).
public enum LooseEndLabel {
  public static let unlabeled = ""
  public static let salient = "salient"
  public static let noise = "noise"
}

/// The only writer of `LooseEnd.label` / `.labelSuggestion`. `Ingester.drain()` stays the only
/// writer of the rest of a loose end. `label` is set by the user (👍/👎); `labelSuggestion` by a
/// machine (the one-off script now, the trained classifier in Phase 2). The corpus reads confirmed
/// labels only.
public enum LooseEndCommands {
  /// Confirm the user's label. `label == ""` clears it. Returns false (writing nothing) if unknown.
  @discardableResult
  public static func setLabel(_ database: any DatabaseWriter, id: UUID, label: String) throws -> Bool {
    try database.write { database in
      guard try LooseEnd.where({ $0.id.eq(id) }).fetchOne(database) != nil else { return false }
      try LooseEnd.where { $0.id.eq(id) }.update { $0.label = label }.execute(database)
      return true
    }
  }

  /// Record a machine suggestion. Never touches the confirmed `label`. Returns false if unknown.
  @discardableResult
  public static func suggest(_ database: any DatabaseWriter, id: UUID, label: String) throws -> Bool {
    try database.write { database in
      guard try LooseEnd.where({ $0.id.eq(id) }).fetchOne(database) != nil else { return false }
      try LooseEnd.where { $0.id.eq(id) }.update { $0.labelSuggestion = label }.execute(database)
      return true
    }
  }

  /// The confirmed training corpus: every loose end the user has labeled (`label != ""`).
  /// `labelSuggestion` is deliberately NOT read — unaudited machine guesses never enter the corpus.
  public static func corpus(_ database: any DatabaseReader) throws -> [(quote: String, label: String)] {
    try database.read { database in
      try LooseEnd.where { $0.label.neq("") }.fetchAll(database).map { ($0.quote, $0.label) }
    }
  }

  /// Fold externally hand-adjudicated labels into the human `label` by verbatim (whitespace-
  /// normalized) quote match. Skips entries matching no stored loose end. Idempotent. This writes
  /// the CORPUS `label` (not a suggestion) because the entries are prior human adjudication.
  public static func importLabels(_ database: any DatabaseWriter,
                                  _ entries: [(quote: String, label: String)]) throws -> (matched: Int, skipped: Int) {
    // Build a normalized-quote -> [id] index once (a quote may recur across nodes; label them all).
    let index: [String: [UUID]] = try database.read { database in
      var map: [String: [UUID]] = [:]
      for le in try LooseEnd.all.fetchAll(database) {
        map[normalizeWhitespace(le.quote), default: []].append(le.id)
      }
      return map
    }
    var matched = 0, skipped = 0
    for entry in entries {
      guard let ids = index[normalizeWhitespace(entry.quote)], !ids.isEmpty else { skipped += 1; continue }
      for id in ids { _ = try setLabel(database, id: id, label: entry.label) }
      matched += 1
    }
    return (matched, skipped)
  }
}
