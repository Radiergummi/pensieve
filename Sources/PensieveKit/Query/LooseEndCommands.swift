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

/// The only writer of `LooseEnd.label` / `.labelSuggestion` / `.status` / `.resolvedAt`.
/// `Ingester.drain()` stays the only writer of the rest of a loose end. `label` is set by the user
/// (👍/👎) and answers "was the extractor right"; `status` is set by the user and answers "is this
/// handled" — two orthogonal axes that must not be conflated, because `label` feeds the salience
/// training corpus and `status` does not. `labelSuggestion` is set by a machine (the one-off script
/// now, the trained classifier in Phase 2). The corpus reads confirmed labels only.
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

  /// Resolve (or reopen) a loose end. Stamps `resolvedAt` when closing and clears it when reopening,
  /// so a reopened end is indistinguishable from one never closed. Returns false, writing nothing,
  /// if the id is unknown — the caller surfaces that as a refusal (stale state), not a failure.
  ///
  /// `restoringResolvedAt` exists for undo, and only for undo: an undo must restore the previous
  /// `(status, resolvedAt)` PAIR, not just the status. Without it, undoing a done→dropped flip left
  /// the item stamped `now`, permanently moving work finished weeks ago to the top of the Completed
  /// feed (which orders on `resolvedAt`). Ignored when reopening, where nil is the only honest value.
  @discardableResult
  public static func resolve(_ database: any DatabaseWriter, id: UUID,
                             status: LooseEndStatus, now: Date = Date(),
                             restoringResolvedAt: Date? = nil) throws -> Bool {
    try database.write { database in
      guard try LooseEnd.where({ $0.id.eq(id) }).fetchOne(database) != nil else { return false }
      let stamp: Date? = status.isClosed ? (restoringResolvedAt ?? now) : nil
      try LooseEnd.where { $0.id.eq(id) }.update {
        $0.status = #bind(status)
        $0.resolvedAt = #bind(stamp)
      }.execute(database)
      return true
    }
  }

  /// Close every OPEN loose end on one node, returning the ids it changed so the caller can register
  /// a single undo that reopens exactly that set. Already-closed ends are left alone — re-stamping
  /// their `resolvedAt` would move work you finished weeks ago to the top of the Completed feed.
  ///
  /// Scoped by `isOpen`, NOT by `status` alone — so it closes exactly what the node's open feed shows
  /// and exactly what the confirmation dialog counted (both go through `isOpen`/`openSQLPredicate`).
  /// An earlier version filtered on `status` only, and its doc comment argued that including
  /// 👎-labelled ends kept the dialog honest; it did the opposite. On a node with 1 unlabeled and 3
  /// 👎 open ends the dialog said "Close 1" and closed 4 — and since both closed feeds exclude
  /// `label = noise`, those three then appeared on no surface at all and could be reopened only by
  /// ⌘Z. Two independent reviews caught it.
  @discardableResult
  public static func resolveAllOpen(_ database: any DatabaseWriter, nodeID: UUID,
                                    status: LooseEndStatus, now: Date = Date()) throws -> [UUID] {
    try database.write { database in
      let open = try LooseEnd.where { $0.nodeID.eq(nodeID) && LooseEnd.isOpen($0) }
        .fetchAll(database)
      guard !open.isEmpty else { return [] }
      let stamp: Date? = status.isClosed ? now : nil
      try LooseEnd.where { $0.nodeID.eq(nodeID) && LooseEnd.isOpen($0) }.update {
        $0.status = #bind(status)
        $0.resolvedAt = #bind(stamp)
      }.execute(database)
      return open.map(\.id)
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
      for looseEnd in try LooseEnd.all.fetchAll(database) {
        map[normalizeWhitespace(looseEnd.quote), default: []].append(looseEnd.id)
      }
      return map
    }
    var matched = 0, skipped = 0
    // ONE write transaction for the batch, not one per entry: this is the bootstrap path over the
    // whole backlog. `setLabel`'s existence check is not needed here — every id came out of the
    // index built from the rows themselves — so the update goes straight out, one statement per
    // entry rather than one per matched row.
    try database.write { database in
      for entry in entries {
        guard let ids = index[normalizeWhitespace(entry.quote)], !ids.isEmpty else { skipped += 1; continue }
        try LooseEnd.where { $0.id.in(ids) }.update { $0.label = entry.label }.execute(database)
        matched += 1
      }
    }
    return (matched, skipped)
  }
}
