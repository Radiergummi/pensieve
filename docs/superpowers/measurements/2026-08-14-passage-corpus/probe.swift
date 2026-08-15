// probe.swift — throwaway measurement, committed as evidence. Not a product target.
//
// Task 1's brief specified this as a standalone script compiled with `swiftc` against
// the built `.build/debug` module. That does not link here: `ProvenanceQueries.transcriptPath(in:)`
// is module-internal (Sources/PensieveKit/Query/ProvenanceQueries.swift) and `TextQuality` is
// internal too, so an external `import PensieveKit` cannot reach them. Per the brief's own stated
// fallback, this ran as a temporary `@Test func passageCorpusProbe()` in
// `Tests/PensieveKitTests/PassageCorpusProbe.swift` (tests use `@testable import PensieveKit`),
// executed with `make test FILTER=passageCorpusProbe`, then the test file was deleted before
// committing. The logic below is unchanged from the brief and from what actually ran — only the
// harness (top-level script vs. @Test function body) differs. The numbers come from
// `TranscriptParser`, never from grep or jq.
import Foundation
import Testing
@testable import PensieveKit

@Test func passageCorpusProbe() throws {
  // Read-only. Never sets PENSIEVE_DB; reads the live store through the read-only opener.
  let storeURL = PensievePaths.canonicalURL()
  let database = try openCanonicalDatabaseReadOnly(at: storeURL)

  var liveTranscripts = 0, missingTranscripts = 0
  var promptCount = 0, replyCount = 0
  var promptBytes = 0, replyBytes = 0
  var promptsOverChunkLimit = 0, repliesOverChunkLimit = 0

  let events = try database.read { database in
    try Event.where { $0.kind.eq(CaptureKind.ccSession) }.fetchAll(database)
  }
  for event in events {
    guard let path = ProvenanceQueries.transcriptPath(in: event) else { continue }
    guard FileManager.default.fileExists(atPath: path) else { missingTranscripts += 1; continue }
    liveTranscripts += 1
    let session = TranscriptParser.parse(fileURL: URL(fileURLWithPath: path))
    for message in session.messages {
      if message.isUserPrompt {
        promptCount += 1; promptBytes += message.text.utf8.count
        if message.text.count > 2000 { promptsOverChunkLimit += 1 }
      } else if message.role == "assistant" {
        replyCount += 1; replyBytes += message.text.utf8.count
        if message.text.count > 2000 { repliesOverChunkLimit += 1 }
      }
    }
  }
  print("live=\(liveTranscripts) missing=\(missingTranscripts)")
  print("prompts=\(promptCount) bytes=\(promptBytes) over2000=\(promptsOverChunkLimit)")
  print("replies=\(replyCount) bytes=\(replyBytes) over2000=\(repliesOverChunkLimit)")
  print("estimatedDocuments=\(promptCount + replyCount + promptsOverChunkLimit * 2 + repliesOverChunkLimit * 2)")
}
