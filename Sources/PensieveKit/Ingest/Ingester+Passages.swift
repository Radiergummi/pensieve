import Foundation
import SQLiteData
import GRDB

/// Split out of `Ingester.swift` purely to stay under SwiftLint's 400-line file cap (mirrors why
/// `AppModel+Organizing.swift` exists) — these helpers are only ever called from `Ingester`.
extension Ingester {
  /// The existing event for this fingerprint, or nil. A sibling of `eventExists` that returns the
  /// row rather than a Bool, because the re-ingest path needs its id and node to rewrite passages.
  func existingEvent(_ database: Database, sourceID: UUID,
                     fingerprint: String) throws -> Event? {
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
  func writePassages(_ database: Database, session: ParsedSession, nodeID: UUID,
                     eventID: UUID, fallbackDate: Date) throws {
    try Passage.where { $0.eventID.eq(eventID) }.delete().execute(database)
    let passages = PassageExtractor.passages(from: session, nodeID: nodeID, eventID: eventID,
                                             fallbackDate: fallbackDate)
    guard !passages.isEmpty else { return }
    for passage in passages { try Passage.insert { passage }.execute(database) }
  }
}
