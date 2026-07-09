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
  public static func setLabel(_ db: any DatabaseWriter, id: UUID, label: String) throws -> Bool {
    try db.write { db in
      guard try LooseEnd.where({ $0.id.eq(id) }).fetchOne(db) != nil else { return false }
      try LooseEnd.where { $0.id.eq(id) }.update { $0.label = label }.execute(db)
      return true
    }
  }

  /// Record a machine suggestion. Never touches the confirmed `label`. Returns false if unknown.
  @discardableResult
  public static func suggest(_ db: any DatabaseWriter, id: UUID, label: String) throws -> Bool {
    try db.write { db in
      guard try LooseEnd.where({ $0.id.eq(id) }).fetchOne(db) != nil else { return false }
      try LooseEnd.where { $0.id.eq(id) }.update { $0.labelSuggestion = label }.execute(db)
      return true
    }
  }

  /// The confirmed training corpus: every loose end the user has labeled (`label != ""`).
  /// `labelSuggestion` is deliberately NOT read — unaudited machine guesses never enter the corpus.
  public static func corpus(_ db: any DatabaseReader) throws -> [(quote: String, label: String)] {
    try db.read { db in
      try LooseEnd.where { $0.label.neq("") }.fetchAll(db).map { ($0.quote, $0.label) }
    }
  }
}
