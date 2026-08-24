import Foundation
import Testing
import SQLiteData
@testable import PensieveKit

@Test func gatherMissingStoresIsNotSetUp() {
  let snap = MonitorSnapshot.gather(canonicalURL: tempURL("absent-canon"),
                                    spoolURL: tempURL("absent-spool"), now: Date())
  #expect(snap.status == .notSetUp)
  #expect(snap.lastCaptureAt == nil)
  #expect(snap.eventCount == 0 && snap.spoolPending == 0 && snap.looseEndCount == 0)
}

@Test func gatherRecentSpoolCaptureIsActiveEvenWithoutCanonical() throws {
  let spoolURL = tempURL("spool")
  let spool = try CaptureSpool(at: spoolURL)
  let now = Date(timeIntervalSince1970: 3_000_000)
  try spool.append(kind: CaptureKind.gitCommit, payload: "{}", at: now.addingTimeInterval(-60)) // 1 min ago
  let snap = MonitorSnapshot.gather(canonicalURL: tempURL("absent-canon"), spoolURL: spoolURL,
                                    now: now, activeWithin: 15 * 60)
  #expect(snap.status == .active)          // capture alive before the first ingest
  #expect(snap.spoolPending == 1)
}

@Test func gatherOldSpoolCaptureIsIdle() throws {
  let spoolURL = tempURL("spool")
  let spool = try CaptureSpool(at: spoolURL)
  let now = Date(timeIntervalSince1970: 3_000_000)
  try spool.append(kind: CaptureKind.gitCommit, payload: "{}", at: now.addingTimeInterval(-30 * 60)) // 30 min
  let snap = MonitorSnapshot.gather(canonicalURL: tempURL("absent-canon"), spoolURL: spoolURL,
                                    now: now, activeWithin: 15 * 60)
  #expect(snap.status == .idle)
}

@Test func gatherCountsCanonicalEventsAndOpenLooseEnds() throws {
  let canonURL = tempURL("canon")
  let database = try openCanonicalDatabase(at: canonURL)
  let node = Node(name: "app")
  let src = Source(nodeID: node.id, kind: SourceKind.gitRepo, key: "/p/app/.git")
  let event = Event(nodeID: node.id, sourceID: src.id, occurredAt: Date(),
                 kind: CaptureKind.gitCommit, summary: "x", detailJSON: "{}",
                 fingerprint: Fingerprint.commit(hash: "abc"))
  try database.write { database in
    try Node.insert { node }.execute(database)
    try Source.insert { src }.execute(database)
    try Event.insert { event }.execute(database)
    try LooseEnd.insert {
      LooseEnd(nodeID: node.id, sourceEventID: event.id, text: "t1", quote: "q1", status: .open)
    }.execute(database)
    try LooseEnd.insert {
      LooseEnd(nodeID: node.id, sourceEventID: event.id, text: "t2", quote: "q2", status: .done)
    }.execute(database)
  }
  let snap = MonitorSnapshot.gather(canonicalURL: canonURL, spoolURL: tempURL("absent-spool"), now: Date())
  #expect(snap.eventCount == 1)
  #expect(snap.looseEndCount == 1)         // only the open one is counted
}

@Test func gatherOnAbsentStoresCreatesNoFiles() {
  let canonURL = tempURL("absent-canon-noop")
  let spoolURL = tempURL("absent-spool-noop")
  let snap = MonitorSnapshot.gather(canonicalURL: canonURL, spoolURL: spoolURL, now: Date())
  #expect(snap.status == .notSetUp)
  #expect(!FileManager.default.fileExists(atPath: canonURL.path))
  #expect(!FileManager.default.fileExists(atPath: spoolURL.path))
}

/// Proves the read-only accessors `gather` now uses actually read a REAL, existing WAL-mode
/// store on this machine, and produce the same facts the write-path methods do.
@Test func readOnlyAccessorsMatchWritePathOnRealStores() throws {
  // Spool: write via the normal (WAL) path, then read the same file read-only.
  let spoolURL = tempURL("spool-ro")
  let spool = try CaptureSpool(at: spoolURL)
  let timestamp = Date(timeIntervalSince1970: 4_000_000)
  try spool.append(kind: CaptureKind.gitCommit, payload: "{}", at: timestamp)
  try spool.append(kind: CaptureKind.ccSession, payload: "{}", at: timestamp.addingTimeInterval(60))

  // Mark the NEWEST row ingested, which is what makes this fixture able to tell the two spellings
  // apart at all. With both rows pending, `pending` equalled the total, so the `WHERE ingested = 0`
  // clause was unobservable — deleting it from `readOnlyStats` left the whole suite green
  // (mutation-proven during the 2026-08-24 sweep). Ingesting the newest row also pins the other half
  // of the contract: `lastCaptureAt` is documented as "across ALL rows … must survive ingestion", so
  // it must still report the ingested one.
  let newestID = try #require(try spool.pending().last?.id)
  try spool.markIngested([newestID])

  let writePathLast = try spool.lastCaptureAt()
  let writePathPending = try spool.pendingCount()
  let (roLast, roPending) = try CaptureSpool.readOnlyStats(at: spoolURL)

  // Absolute values, not just agreement between the two paths: two implementations of the same
  // mistake agree with each other perfectly.
  #expect(writePathPending == 1)                                    // one of two rows is ingested
  #expect(roPending == writePathPending)
  #expect(roLast != nil && writePathLast != nil)
  #expect(abs(roLast!.timeIntervalSince(timestamp.addingTimeInterval(60))) < 1)   // the INGESTED row
  #expect(abs(roLast!.timeIntervalSince(writePathLast!)) < 1)

  // A genuinely read-only connection to the same file must refuse to write.
  var roConfig = Configuration()
  roConfig.readonly = true
  let roQueue = try DatabaseQueue(path: spoolURL.path, configuration: roConfig)
  #expect(throws: (any Error).self) {
    try roQueue.write { database in
      try database.execute(sql: "INSERT INTO captures(ts, kind, payload) VALUES(?, ?, ?)",
                      arguments: ["x", "y", "z"])
    }
  }

  // Canonical store: migrate via the normal path, then read the same file read-only.
  let canonURL = tempURL("canon-ro")
  let database = try openCanonicalDatabase(at: canonURL)
  let node = Node(name: "app")
  let src = Source(nodeID: node.id, kind: SourceKind.gitRepo, key: "/p/app-ro/.git")
  let event = Event(nodeID: node.id, sourceID: src.id, occurredAt: Date(),
                 kind: CaptureKind.gitCommit, summary: "x", detailJSON: "{}",
                 fingerprint: Fingerprint.commit(hash: "ro-abc"))
  try database.write { database in
    try Node.insert { node }.execute(database)
    try Source.insert { src }.execute(database)
    try Event.insert { event }.execute(database)
  }
  let roDB = try openCanonicalDatabaseReadOnly(at: canonURL)
  let roEventCount = try roDB.read { database in try Event.all.fetchAll(database).count }
  #expect(roEventCount == 1)

  let snap = MonitorSnapshot.gather(canonicalURL: canonURL, spoolURL: spoolURL, now: timestamp.addingTimeInterval(120))
  #expect(snap.eventCount == 1)
  // 1, not 2: one of the two spool rows above is marked ingested, which is what lets this fixture
  // distinguish "pending" from "all rows". `gather` must report the un-ingested count, so this
  // assertion now also covers the clause it used to be blind to.
  #expect(snap.spoolPending == 1)
}

@Test func gatherExcludesConfirmedNoiseFromOpenLooseEndCount() throws {
  let canonURL = tempURL("canon-noise")
  let database = try openCanonicalDatabase(at: canonURL)
  let node = Node(name: "app")
  let src = Source(nodeID: node.id, kind: SourceKind.gitRepo, key: "/p/noise/.git")
  let event = Event(nodeID: node.id, sourceID: src.id, occurredAt: Date(),
                 kind: CaptureKind.gitCommit, summary: "x", detailJSON: "{}",
                 fingerprint: Fingerprint.commit(hash: "noise-abc"))
  try database.write { database in
    try Node.insert { node }.execute(database)
    try Source.insert { src }.execute(database)
    try Event.insert { event }.execute(database)
    try LooseEnd.insert {
      LooseEnd(nodeID: node.id, sourceEventID: event.id, text: "t1", quote: "unlabeled item")
    }.execute(database)
    try LooseEnd.insert {
      LooseEnd(nodeID: node.id, sourceEventID: event.id, text: "t2", quote: "confirmed noise",
               label: LooseEndLabel.noise)
    }.execute(database)
    try LooseEnd.insert {
      LooseEnd(nodeID: node.id, sourceEventID: event.id, text: "t3", quote: "only suggested noise",
               labelSuggestion: LooseEndLabel.noise)
    }.execute(database)
  }
  let snap = MonitorSnapshot.gather(canonicalURL: canonURL, spoolURL: tempURL("absent-spool-noise"), now: Date())
  #expect(snap.looseEndCount == 2)   // confirmed-noise excluded; unlabeled + suggestion-only-noise kept
}

/// The connection-reusing overload the app uses (to avoid re-firing its store-dir watch) must
/// produce exactly the same heartbeat as the URL overload for the same stores.
@Test func gatherFromOpenConnectionsMatchesURLPath() throws {
  let spoolURL = tempURL("spool-open")
  let spool = try CaptureSpool(at: spoolURL)
  let now = Date(timeIntervalSince1970: 5_000_000)
  try spool.append(kind: CaptureKind.gitCommit, payload: "{}", at: now.addingTimeInterval(-60))

  let canonURL = tempURL("canon-open")
  let database = try openCanonicalDatabase(at: canonURL)
  let node = Node(name: "app")
  let src = Source(nodeID: node.id, kind: SourceKind.gitRepo, key: "/p/app-open/.git")
  let event = Event(nodeID: node.id, sourceID: src.id, occurredAt: now,
                 kind: CaptureKind.gitCommit, summary: "x", detailJSON: "{}",
                 fingerprint: Fingerprint.commit(hash: "open-abc"))
  try database.write { database in
    try Node.insert { node }.execute(database)
    try Source.insert { src }.execute(database)
    try Event.insert { event }.execute(database)
    try LooseEnd.insert {
      LooseEnd(nodeID: node.id, sourceEventID: event.id, text: "t", quote: "q", status: .open)
    }.execute(database)
  }

  let viaURL = MonitorSnapshot.gather(canonicalURL: canonURL, spoolURL: spoolURL, now: now)
  let viaOpen = MonitorSnapshot.gather(canonical: database, spool: spool, now: now)
  #expect(viaOpen == viaURL)
  #expect(viaOpen.status == .active)
  #expect(viaOpen.eventCount == 1 && viaOpen.looseEndCount == 1 && viaOpen.spoolPending == 1)
}

/// Nil connections (store not open yet) degrade to `.notSetUp`, matching the absent-store URL path.
@Test func gatherFromNilConnectionsIsNotSetUp() {
  let snap = MonitorSnapshot.gather(canonical: nil, spool: nil, now: Date())
  #expect(snap.status == .notSetUp)
  #expect(snap.eventCount == 0 && snap.spoolPending == 0 && snap.looseEndCount == 0)
}

/// A canonical store that EXISTS but will not open must not report `.notSetUp`.
///
/// "Not set up" is a claim about the machine, and it is the one reading that tells the user there is
/// nothing to do — so a corrupt or permission-denied store rendering as a fresh install is the worst
/// available answer. The counts have no honest value and stay zero; the status degrades to `.idle`,
/// which says "something is here, it just isn't moving".
///
/// The fixture is a real file of garbage at the canonical path, with no spool — the exact shape that
/// used to be indistinguishable from `gatherMissingStoresIsNotSetUp` above.
@Test func gatherUnreadableCanonicalStoreIsNotReportedAsNotSetUp() throws {
  let canonicalURL = tempURL("unreadable-canon")
  try Data("this is not a sqlite database".utf8).write(to: canonicalURL)
  let snapshot = MonitorSnapshot.gather(canonicalURL: canonicalURL,
                                        spoolURL: tempURL("absent-spool"), now: Date())
  #expect(snapshot.status != .notSetUp)
  #expect(snapshot.status == .idle)
  #expect(snapshot.eventCount == 0)   // no honest count to report
}
