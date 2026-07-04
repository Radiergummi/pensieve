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

@Test func parsesFractionalSecondTimestamps() throws {
  // Real Claude Code transcripts stamp fractional seconds ("…:43.382Z"); a default
  // ISO8601DateFormatter rejects them, which would leave startedAt/endedAt nil and
  // collapse the dormancy signal. Timestamps must parse regardless of fractional seconds.
  let url = tempURL("fractional", ext: "jsonl")
  let lines = """
    {"type":"user","cwd":"/p/app","timestamp":"2026-06-29T13:03:43.382Z","message":{"role":"user","content":"hi"}}
    {"type":"user","cwd":"/p/app","timestamp":"2026-06-29T13:05:10Z","message":{"role":"user","content":"bye"}}
    """
  try lines.write(to: url, atomically: true, encoding: .utf8)
  let s = TranscriptParser.parse(fileURL: url)
  #expect(s.startedAt != nil)                            // fractional-second line parsed
  #expect(s.endedAt != nil)
  #expect(s.startedAt != s.endedAt)                      // both timestamps parsed, min < max
}
