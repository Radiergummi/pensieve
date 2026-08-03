import Foundation
import Testing
import SQLiteData
@testable import PensieveKit

@Test func drainPersistsSessionBranch() async throws {
  let spool = try CaptureSpool(at: tempURL("spool"))
  let database = try openCanonicalDatabase(at: tempURL("canon"))
  let payload = SessionStartPayload(sessionID: "S1", cwd: "/p/app",
    branch: "feature-x", commonDir: "/p/app/.git", transcriptPath: "/t.jsonl")
  try spool.append(kind: CaptureKind.ccSessionStart, payload: try encodeJSON(payload))

  let eventCount = try await Ingester(spool: spool, database: database).drain()
  #expect(eventCount == 0)                                    // metadata, not an event
  let sessionBranch = try await database.read { database in try SessionBranch.all.fetchAll(database) }.first
  #expect(sessionBranch?.sessionID == "S1")
  #expect(sessionBranch?.branch == "feature-x")
  #expect(try spool.pending().isEmpty)               // marked ingested
}
