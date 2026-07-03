import Foundation
import Testing
@testable import PensieveKit

@Test func gitCommitPayloadEncodesToSpool() throws {
  let url = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("capture-\(UUID().uuidString).sqlite")
  let spool = try CaptureSpool(at: url)

  let payload = GitCommitPayload(repoPath: "/Users/moritz/Projects/colibri", hash: "abc123", branch: "main")
  try spool.append(kind: CaptureKind.gitCommit, payload: try encodeJSON(payload))

  let rows = try spool.pending()
  #expect(rows.first?.kind == CaptureKind.gitCommit)
  let decoded = try JSONDecoder().decode(GitCommitPayload.self, from: Data(rows[0].payload.utf8))
  #expect(decoded.hash == "abc123")
}
