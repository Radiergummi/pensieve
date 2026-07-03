import Foundation
import Testing
import SQLiteData
@testable import PensieveKit

@Test func reDrainDoesNotDuplicateCommitEvents() throws {
  let (repo, hash) = try makeCommittedRepo()
  let spool = try CaptureSpool(at: tempURL("dedup-spool"))
  let db = try openCanonicalDatabase(at: tempURL("dedup-canon"))

  let payload = try encodeJSON(GitCommitPayload(repoPath: repo.path, hash: hash, branch: "main"))
  try spool.append(kind: CaptureKind.gitCommit, payload: payload)
  _ = try Ingester(spool: spool, db: db).drain()

  // Append the SAME commit again and drain again.
  try spool.append(kind: CaptureKind.gitCommit, payload: payload)
  _ = try Ingester(spool: spool, db: db).drain()

  let events = try db.read { db in try Event.all.fetchAll(db) }
  #expect(events.count == 1)
  #expect(events.first?.fingerprint == Fingerprint.commit(hash: hash))
}
