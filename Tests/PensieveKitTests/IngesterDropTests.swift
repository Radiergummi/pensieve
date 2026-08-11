import Testing
import Foundation
@testable import PensieveKit

private func tmp(_ name: String, ext: String) -> URL {
  FileManager.default.temporaryDirectory
    .appendingPathComponent("\(name)-\(UUID().uuidString)").appendingPathExtension(ext)
}

@Test func drainDropsNonEmptyCwdlessSessionButRetriesEmpty() async throws {
  let spool = try CaptureSpool(at: tmp("drop-spool", ext: "sqlite"))
  let database = try openCanonicalDatabase(at: tmp("drop-canon", ext: "sqlite"))

  // (a) A non-empty transcript with NO cwd anywhere → permanently unattributable → drop.
  let noCwd = tmp("nocwd", ext: "jsonl")
  try #"{"type":"assistant","message":{"role":"assistant","content":"hi"}}"#
    .write(to: noCwd, atomically: true, encoding: .utf8)
  // (b) A 0-byte transcript → transient (may fill later) → stays pending.
  let empty = tmp("empty", ext: "jsonl")
  try "".write(to: empty, atomically: true, encoding: .utf8)

  for url in [noCwd, empty] {
    try spool.append(kind: CaptureKind.ccSession,
                     payload: try encodeJSON(SessionRefPayload(transcriptPath: url.path)))
  }

  let created = try await Ingester(spool: spool, database: database).drain()
  #expect(created == 0)                       // neither produced an event
  #expect(try spool.pendingCount() == 1)      // only the 0-byte row remains pending
  let remaining = try spool.pending()
  #expect(remaining.count == 1)
  #expect(remaining.first?.payload.contains("empty-") == true)   // the empty one stayed
}

@Test func drainStopsRetryingLongAbsentTranscripts() async throws {
  // Retrying an absent transcript is right only inside the window where it may still be
  // written. Past the grace period the file is gone for good (deleted, or an ephemeral temp
  // cwd), so the row must be dropped — otherwise it is re-parsed and re-logged on EVERY
  // drain forever. A fresh row in the same state must still be retried.
  let spool = try CaptureSpool(at: tmp("stale-spool", ext: "sqlite"))
  let database = try openCanonicalDatabase(at: tmp("stale-canon", ext: "sqlite"))

  let staleGone = tmp("stale-gone", ext: "jsonl")        // never created → absent
  let freshGone = tmp("fresh-gone", ext: "jsonl")        // never created → absent
  try spool.append(kind: CaptureKind.ccSession,
                   payload: try encodeJSON(SessionRefPayload(transcriptPath: staleGone.path)),
                   at: Date().addingTimeInterval(-8 * 24 * 60 * 60))
  try spool.append(kind: CaptureKind.ccSession,
                   payload: try encodeJSON(SessionRefPayload(transcriptPath: freshGone.path)))

  let created = try await Ingester(spool: spool, database: database).drain()

  #expect(created == 0)                       // neither produced an event
  let remaining = try spool.pending()
  #expect(remaining.count == 1)               // the stale one was dropped, not retried
  #expect(remaining.first?.payload.contains("fresh-gone-") == true)
}
