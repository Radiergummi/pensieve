import Testing
import Foundation
@testable import PensieveKit

@Test func sessionEndHookDecodesTranscriptPathAndRejectsGarbage() throws {
  let good = #"{"session_id":"s1","cwd":"/x","transcript_path":"/tmp/t.jsonl","reason":"clear"}"#
  #expect(sessionRefFromSessionEndHook(Data(good.utf8))?.transcriptPath == "/tmp/t.jsonl")

  #expect(sessionRefFromSessionEndHook(Data("not json".utf8)) == nil)
  #expect(sessionRefFromSessionEndHook(Data(#"{"reason":"other"}"#.utf8)) == nil)   // no path
  #expect(sessionRefFromSessionEndHook(Data(#"{"transcript_path":""}"#.utf8)) == nil) // empty
}

@Test func sessionEndHookSpoolsExactlyOneSessionRow() throws {
  let url = FileManager.default.temporaryDirectory
    .appendingPathComponent("se-spool-\(UUID().uuidString).sqlite")
  let spool = try CaptureSpool(at: url)
  let ref = sessionRefFromSessionEndHook(Data(#"{"transcript_path":"/tmp/x.jsonl"}"#.utf8))!
  try spool.append(kind: CaptureKind.ccSession, payload: try encodeJSON(ref))
  let rows = try spool.pending()
  #expect(rows.count == 1)
  #expect(rows.first?.kind == CaptureKind.ccSession)
  #expect(rows.first?.payload.contains("/tmp/x.jsonl") == true)
}
