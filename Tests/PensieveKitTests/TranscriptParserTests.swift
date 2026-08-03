import Foundation
import Testing
@testable import PensieveKit

@Test func parsesSessionDefensively() throws {
  let url = Bundle.module.url(forResource: "session", withExtension: "jsonl", subdirectory: "Fixtures")!
  let session = TranscriptParser.parse(fileURL: url)

  #expect(session.cwd == "/Users/moritz/Projects/colibri")
  #expect(session.userPromptCount == 2)                       // bad line skipped, not counted
  #expect(session.messages.contains { $0.text.contains("rate limiting") })
  #expect(session.startedAt != nil && session.endedAt != nil)
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
  let session = TranscriptParser.parse(fileURL: url)
  #expect(session.startedAt != nil)                            // fractional-second line parsed
  #expect(session.endedAt != nil)
  #expect(session.startedAt != session.endedAt)                      // both timestamps parsed, min < max
}
