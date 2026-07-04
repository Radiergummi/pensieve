import Foundation
import Testing
import SQLiteData
@testable import PensieveKit

@Test func drainPersistsSessionBranch() async throws {
  let spool = try CaptureSpool(at: tempURL("spool"))
  let db = try openCanonicalDatabase(at: tempURL("canon"))
  let payload = SessionStartPayload(sessionID: "S1", cwd: "/p/app",
    branch: "feature-x", commonDir: "/p/app/.git", transcriptPath: "/t.jsonl")
  try spool.append(kind: CaptureKind.ccSessionStart, payload: try encodeJSON(payload))

  let n = try await Ingester(spool: spool, db: db).drain()
  #expect(n == 0)                                    // metadata, not an event
  let sb = try await db.read { db in try SessionBranch.all.fetchAll(db) }.first
  #expect(sb?.sessionID == "S1")
  #expect(sb?.branch == "feature-x")
  #expect(try spool.pending().isEmpty)               // marked ingested
}
