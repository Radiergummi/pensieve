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

@Test func eventRoundTrips() throws {
  let original = Event(
    id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
    nodeID: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
    sourceID: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!,
    occurredAt: Date(timeIntervalSince1970: 1_000),
    kind: "cc.session",
    summary: "did work",
    detailJSON: "{\"a\":1}",
    fingerprint: "fp-123",
    branchKey: "feature/x",
    extractedAt: Date(timeIntervalSince1970: 2_000),
    extractedMessageCount: 7,
    extractedTranscriptSize: 4_096,
    workSummary: "shipped the thing",
    createdAt: Date(timeIntervalSince1970: 3_000)
  )
  let data = try JSONEncoder().encode(EventDTO(original))
  let back = try JSONDecoder().decode(EventDTO.self, from: data).toDomain()
  #expect(back == original)
  #expect(back.fingerprint == "fp-123")
  #expect(back.branchKey == "feature/x")
}
