import Foundation
import Testing
@testable import PensieveKit

@Test func parserFlagsGenuineUserPrompts() throws {
  let url = Bundle.module.url(forResource: "session-roles", withExtension: "jsonl", subdirectory: "Fixtures")!
  let s = TranscriptParser.parse(fileURL: url)

  // indices are contiguous over retained messages
  #expect(s.messages.map(\.index) == Array(0..<s.messages.count))

  let userPrompts = s.messages.filter { $0.isUserPrompt }
  #expect(userPrompts.contains { $0.text.contains("rate limiting") })
  #expect(userPrompts.contains { $0.text.contains("ship it") })
  // assistant suggestion is NOT a user prompt
  #expect(!userPrompts.contains { $0.text.contains("pagination") })
  // tool-result user-record is NOT a user prompt (and has no text, so may be absent)
  #expect(!userPrompts.contains { $0.text.contains("exit 0") })
}
