import Foundation
import Testing
@testable import PensieveKit

@Test func parsesSessionDefensively() throws {
  let url = Bundle.module.url(forResource: "session", withExtension: "jsonl", subdirectory: "Fixtures")!
  let s = TranscriptParser.parse(fileURL: url)

  #expect(s.cwd == "/Users/moritz/Projects/colibri")
  #expect(s.userPromptCount == 2)                       // bad line skipped, not counted
  #expect(s.messages.contains { $0.text.contains("rate limiting") })
  #expect(s.startedAt != nil && s.endedAt != nil)
}
