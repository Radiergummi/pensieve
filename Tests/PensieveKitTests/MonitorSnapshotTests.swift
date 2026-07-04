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
  let db = try openCanonicalDatabase(at: canonURL)
  let node = Node(name: "app")
  let src = Source(nodeID: node.id, kind: SourceKind.gitRepo, key: "/p/app/.git")
  let ev = Event(nodeID: node.id, sourceID: src.id, occurredAt: Date(),
                 kind: CaptureKind.gitCommit, summary: "x", detailJSON: "{}",
                 fingerprint: Fingerprint.commit(hash: "abc"))
  try db.write { db in
    try Node.insert { node }.execute(db)
    try Source.insert { src }.execute(db)
    try Event.insert { ev }.execute(db)
    try LooseEnd.insert {
      LooseEnd(nodeID: node.id, sourceEventID: ev.id, text: "t1", quote: "q1", status: "open")
    }.execute(db)
    try LooseEnd.insert {
      LooseEnd(nodeID: node.id, sourceEventID: ev.id, text: "t2", quote: "q2", status: "resolved")
    }.execute(db)
  }
  let snap = MonitorSnapshot.gather(canonicalURL: canonURL, spoolURL: tempURL("absent-spool"), now: Date())
  #expect(snap.eventCount == 1)
  #expect(snap.looseEndCount == 1)         // only the open one is counted
}
