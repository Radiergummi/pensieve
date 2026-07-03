import Foundation
import Testing
@testable import PensieveKit

@Test func gitCommitPayloadEncodesToSpool() throws {
  let spool = try CaptureSpool(at: tempURL("capture"))

  let payload = GitCommitPayload(repoPath: "/Users/moritz/Projects/colibri", hash: "abc123", branch: "main")
  try spool.append(kind: CaptureKind.gitCommit, payload: try encodeJSON(payload))

  let rows = try spool.pending()
  #expect(rows.first?.kind == CaptureKind.gitCommit)
  let decoded = try JSONDecoder().decode(GitCommitPayload.self, from: Data(rows[0].payload.utf8))
  #expect(decoded.hash == "abc123")
}
