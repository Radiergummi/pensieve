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

  // Pin isToolResult guard: message with mixed tool_result+text content IS retained
  // (because text is non-empty) BUT is NOT classified as user prompt (because of guard)
  #expect(s.messages.contains { $0.text.contains("tool result marker phrase") })
  #expect(!userPrompts.contains { $0.text.contains("tool result marker phrase") })

  // Injected/command content (type:"user" but carrying structural markers) is retained
  // (has text) but is NOT classified as a genuine user prompt.
  #expect(s.messages.contains { $0.text.contains("injected command marker phrase") })
  #expect(!userPrompts.contains { $0.text.contains("injected command marker phrase") })

  // Subagent-result envelope (<task-notification>/<usage>/</tool_uses>) is a machine
  // record, not human prose.
  #expect(s.messages.contains { $0.text.contains("subagent result marker phrase") })
  #expect(!userPrompts.contains { $0.text.contains("subagent result marker phrase") })

  // A "[Request interrupted…]" notice is likewise not a genuine user prompt.
  #expect(s.messages.contains { $0.text.contains("interruption marker phrase") })
  #expect(!userPrompts.contains { $0.text.contains("interruption marker phrase") })
}
