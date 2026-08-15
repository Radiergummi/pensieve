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
    try Passage.where { $0.eventID.eq(eventID) }.delete().execute(database)
    for passage in passages { try Passage.insert { passage }.execute(database) }
  }
}
