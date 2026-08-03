import Foundation
import Testing
import SQLiteData
@testable import PensieveKit

@Test func reDrainDoesNotDuplicateCommitEvents() async throws {
  let (repo, hash) = try makeCommittedRepo()
  let spool = try CaptureSpool(at: tempURL("dedup-spool"))
  let database = try openCanonicalDatabase(at: tempURL("dedup-canon"))

  let payload = try encodeJSON(GitCommitPayload(repoPath: repo.path, hash: hash, branch: "main"))
  try spool.append(kind: CaptureKind.gitCommit, payload: payload)
  _ = try await Ingester(spool: spool, database: database).drain()

  // Append the SAME commit again and drain again.
  try spool.append(kind: CaptureKind.gitCommit, payload: payload)
  _ = try await Ingester(spool: spool, database: database).drain()

  let events = try await database.read { database in try Event.all.fetchAll(database) }
  #expect(events.count == 1)
  #expect(events.first?.fingerprint == Fingerprint.commit(hash: hash))
}
