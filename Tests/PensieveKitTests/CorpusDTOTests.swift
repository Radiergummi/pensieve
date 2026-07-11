import Testing
import Foundation
@testable import PensieveKit

@Test func transcriptMessageRoundTrips() throws {
  let m = TranscriptMessage(index: 3, role: "user", text: "ship it", timestamp: nil, isUserPrompt: true)
  let dto = TranscriptMessageDTO(m)
  let data = try JSONEncoder().encode(dto)
  let back = try JSONDecoder().decode(TranscriptMessageDTO.self, from: data).toDomain()
  #expect(back.index == 3 && back.role == "user" && back.text == "ship it" && back.isUserPrompt)
}

@Test func projectContextRoundTrips() throws {
  let ctx = ProjectContext(dirName: "colibri", gitRemote: "git@x", readmeHead: "# hi", claudeMdHead: nil, manifest: "a\nb")
  let back = ProjectContextDTO(ctx).toDomain()
  #expect(back.dirName == "colibri" && back.gitRemote == "git@x" && back.manifest == "a\nb" && back.claudeMdHead == nil)
}
