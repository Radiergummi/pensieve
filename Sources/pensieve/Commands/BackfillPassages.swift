import ArgumentParser
import Foundation
import PensieveKit
import SQLiteData

/// One-time backfill of passages for already-ingested sessions whose transcripts still exist.
///
/// Idempotent: it rewrites each event's passages wholesale, exactly like the ingest path, so running
/// it twice is harmless and a partial run can simply be re-run. Reports what it could NOT do, because
/// a transcript that has aged out is unrecoverable and the count is the honest measure of what this
/// feature can still reach.
struct BackfillPassages: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "backfill-passages",
    abstract: "Extract passages from already-captured sessions whose transcripts still exist.")

  @Flag(name: .long, help: "Report what would be written without writing anything.")
  var dryRun = false

  func run() throws {
    let database = try openCanonical()
    let events = try database.read { database in
      try Event.where { $0.kind.eq(CaptureKind.ccSession) }
        .order { ($0.occurredAt, $0.id) }
        .fetchAll(database)
    }
    var written = 0, transcriptsGone = 0, alreadyHad = 0
    // Split from a single counter: a live transcript that yields no passages is not a failure — a
    // two-message session legitimately has nothing recallable — so conflating "file exists" with
    // "extraction produced something" made a healthy run look like 20 sessions were missing.
    var liveTranscripts = 0
    var sessionsWithPassages = 0

    for event in events {
      guard let session = ProvenanceQueries.parsedSession(for: event) else {
        transcriptsGone += 1
        continue
      }
      liveTranscripts += 1
      let existing = try database.read { database in
        try Passage.where { $0.eventID.eq(event.id) }.fetchCount(database)
      }
      let passages = PassageExtractor.passages(from: session, nodeID: event.nodeID,
                                               eventID: event.id,
                                               fallbackDate: event.occurredAt)
      guard !passages.isEmpty else { continue }
      if existing > 0 { alreadyHad += 1 }
      sessionsWithPassages += 1
      written += passages.count
      guard !dryRun else { continue }
      // The ingest path's own write, not a second copy of it: guard-before-delete and
      // wholesale-replace are one durability rule, and the only surviving copy of a passage may be
      // the one already stored.
      try database.write { database in
        try Ingester.replacePassages(database, eventID: event.id, with: passages)
      }
    }

    print("sessions with a live transcript: \(liveTranscripts) (\(liveTranscripts - sessionsWithPassages) yielded no passages)")
    print("transcripts gone, unrecoverable:  \(transcriptsGone)")
    print("sessions contributing passages:   \(sessionsWithPassages) (\(alreadyHad) already had them)")
    print("passages \(dryRun ? "that would be written" : "written"): \(written)")
    if !dryRun {
      // The index is derived; rebuild it once at the end rather than per session.
      SearchIndexer.production().syncPassages(database)
      print("passage index rebuilt")
    }
  }
}
