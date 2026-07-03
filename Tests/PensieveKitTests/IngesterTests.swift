import Foundation
import Testing
import SQLiteData
@testable import PensieveKit

@Test func ingestsGitCommitIntoEvent() throws {
  // Arrange: a real temp git repo with one commit.
  let (repo, hash) = try makeCommittedRepo()
  let spool = try CaptureSpool(at: tempURL("spool"))
  let db = try openCanonicalDatabase(at: tempURL("canon"))

  let payload = GitCommitPayload(repoPath: repo.path, hash: hash, branch: "main")
  try spool.append(kind: CaptureKind.gitCommit, payload: try encodeJSON(payload))

  // Act
  let n = try Ingester(spool: spool, db: db).drain()

  // Assert
  #expect(n == 1)
  let events = try db.read { db in try Event.all.fetchAll(db) }
  #expect(events.count == 1)
  #expect(events.first?.summary == "first commit")
  #expect(events.first?.kind == CaptureKind.gitCommit)
  #expect(try spool.pending().isEmpty)   // marked ingested
}

@Test func failingRowStaysPendingWhileGoodRowProcesses() throws {
  // A real temp git repo with one commit (for the good row).
  let (repo, hash) = try makeCommittedRepo()
  let spool = try CaptureSpool(at: tempURL("spool"))
  let db = try openCanonicalDatabase(at: tempURL("canon"))

  // Bad row: git.commit kind but undecodable payload (missing required fields) → throws in ingest.
  try spool.append(kind: CaptureKind.gitCommit, payload: "{}")
  // Good row: a valid git.commit for the real repo.
  let payload = GitCommitPayload(repoPath: repo.path, hash: hash, branch: "main")
  try spool.append(kind: CaptureKind.gitCommit, payload: try encodeJSON(payload))

  let n = try Ingester(spool: spool, db: db).drain()

  #expect(n == 1)   // only the good row ingested
  let events = try db.read { db in try Event.all.fetchAll(db) }
  #expect(events.count == 1)
  #expect(events.first?.summary == "first commit")

  // The bad row is left unmarked so it retries next drain.
  let stillPending = try spool.pending()
  #expect(stillPending.count == 1)
  #expect(stillPending.first?.kind == CaptureKind.gitCommit)
  #expect(stillPending.first?.payload == "{}")
}

@Test func unknownKindIsDropped() throws {
  let spool = try CaptureSpool(at: tempURL("spool"))
  let db = try openCanonicalDatabase(at: tempURL("canon"))

  try spool.append(kind: "bogus.unknown", payload: "{}")

  let n = try Ingester(spool: spool, db: db).drain()

  #expect(n == 1)                        // counted as processed (dropped)
  #expect(try spool.pending().isEmpty)   // marked done via default: branch, not retried
  let events = try db.read { db in try Event.all.fetchAll(db) }
  #expect(events.isEmpty)                // nothing enriched
}
