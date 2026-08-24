import Foundation
import SQLiteData
import GRDB

/// Split out of `Ingester.swift` purely to stay under SwiftLint's 400-line file cap (mirrors why
/// `AppModel+Organizing.swift` exists) — these helpers are only ever called from `Ingester`.
extension Ingester {
  /// The existing event for this (sourceID, fingerprint), or nil — the ingest dedup predicate, in
  /// its one definition. `eventExists` is derived from this rather than spelling the same `where`
  /// clause a second time: the dedup key is the load-bearing rule of the whole ingest path, and the
  /// re-ingest path needs the row itself (its id and node) to rewrite passages.
  func existingEvent(_ database: Database, sourceID: UUID,
                     fingerprint: String?) throws -> Event? {
    try Event.where { $0.sourceID.eq(sourceID) && $0.fingerprint.eq(fingerprint) }
      .fetchOne(database)
  }

  /// Delete-then-insert, never append. Idempotent by construction: re-ingesting a grown transcript
  /// replaces this event's passages with the full current set, so the same turn can never be stored
  /// twice and a turn edited by compaction cannot leave a stale copy behind.
  ///
  /// Best-effort in spirit but NOT swallowed: this runs inside the session's own write transaction,
  /// so a throw rolls the event back too. That is deliberate — an event whose passages failed to
  /// write would look ingested and be silently unrecallable.
  ///
  /// The guard runs BEFORE the delete: extraction yielding nothing is a NORMAL outcome (a
  /// compacted, rewritten, or truncated transcript can legitimately parse to zero passages), not a
  /// reason to discard the durable copy already stored — which may be the only copy left, since the
  /// transcript it came from may no longer exist.
  func writePassages(_ database: Database, session: ParsedSession, nodeID: UUID,
                     eventID: UUID, fallbackDate: Date) throws {
    try Ingester.replacePassages(
      database, eventID: eventID,
      with: PassageExtractor.passages(from: session, nodeID: nodeID, eventID: eventID,
                                      fallbackDate: fallbackDate))
  }

  /// The durability rule above, as one function two call sites share: the ingest path here and
  /// `pensieve backfill-passages`, which extracts separately (it needs the count for `--dry-run`)
  /// but must write by exactly the same rule. Public because the CLI is a thin shell over Kit —
  /// a second delete-then-insert over there is how the guard-before-delete invariant would drift.
  public static func replacePassages(_ database: Database, eventID: UUID,
                                     with passages: [Passage]) throws {
    guard !passages.isEmpty else { return }
    // Skip the rewrite entirely when the stored set is already exactly this set. The `SessionEnd`
    // hook re-spools a session as it grows, so once an event exists EVERY drain re-ingests it and
    // re-derives its passages — and a session that has not grown since the last pass would
    // otherwise pay a full delete plus up to 464 inserts every cycle, forever, to arrive at the
    // rows it already had.
    //
    // The comparison is exact rather than a count or byte-size heuristic on purpose: compaction can
    // rewrite a transcript's content without changing how many passages it yields, and skipping
    // THAT would leave a stale verbatim copy standing as provenance.
    let stored = try Passage.where { $0.eventID.eq(eventID) }.fetchAll(database)
    guard stored.map(contentKey).sorted() != passages.map(contentKey).sorted() else { return }

    try Passage.where { $0.eventID.eq(eventID) }.delete().execute(database)
    // One multi-row INSERT per chunk instead of one statement per row. Chunked because every column
    // of every row is a bound parameter, and SQLite caps those per statement
    // (`SQLITE_LIMIT_VARIABLE_NUMBER`); a chunk of 200 rows is ~1.8k parameters, comfortably inside
    // the limit no matter how long the session was.
    for chunk in stride(from: 0, to: passages.count, by: passageInsertChunk) {
      let batch = Array(passages[chunk..<min(chunk + passageInsertChunk, passages.count)])
      try Passage.insert { batch }.execute(database)
    }
  }

  private static let passageInsertChunk = 200

  /// The identity of a passage's CONTENT — everything except `id` and `createdAt`, which every
  /// extraction mints afresh and which therefore always differ even when the text is identical.
  /// Used only to decide whether a rewrite would be a no-op.
  private static func contentKey(_ passage: Passage) -> String {
    """
    \(passage.nodeID)|\(passage.turnIndex)|\(passage.messageIndex)|\(passage.role.rawValue)|\
    \(passage.occurredAt.timeIntervalSince1970)|\(passage.text)
    """
  }
}
