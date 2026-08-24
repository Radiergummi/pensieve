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

/// `userPromptCount` must count HUMAN turns, not `type:"user"` records. Claude Code records every
/// tool result as `type:"user"` too: measured on a real transcript, 331 of 362 such records were
/// `tool_result`, so a ~20-turn session rendered as "session (207 prompts)" in the app and in the
/// text the narrator reads. The count is now the same predicate the messages already carry.
@Test func userPromptCountCountsHumanTurnsNotToolResultsOrInjections() throws {
  let url = tempURL("prompt-count", ext: "jsonl")
  let lines = """
    {"type":"user","cwd":"/p/app","message":{"role":"user","content":"add rate limiting"}}
    {"type":"user","message":{"role":"user","content":[{"type":"tool_result","content":"ok"}]}}
    {"type":"user","message":{"role":"user","content":[{"type":"tool_result","content":"ok"}]}}
    {"type":"user","message":{"role":"user","content":[{"type":"tool_result","content":"ok"}]}}
    {"type":"user","isMeta":true,"message":{"role":"user","content":"injected harness body"}}
    {"type":"assistant","message":{"role":"assistant","content":"done"}}
    {"type":"user","cwd":"/p/app","message":{"role":"user","content":"now add tests"}}
    """
  try lines.write(to: url, atomically: true, encoding: .utf8)

  let session = TranscriptParser.parse(fileURL: url)

  // Two genuine human turns among seven records, four of which are `type:"user"` but not human.
  #expect(session.userPromptCount == 2)
  #expect(session.messages.filter(\.isUserPrompt).count == 2)   // count agrees with the flag
}

/// The read-failure signal the ingester uses to tell a transient failure from a permanent one.
@Test func anUndecodableTranscriptReportsThatItCouldNotBeRead() throws {
  let url = tempURL("binary", ext: "jsonl")
  try Data([0xFF, 0xFE, 0xFF, 0xFE]).write(to: url)
  #expect(TranscriptParser.parse(fileURL: url).wasReadable == false)

  let fine = tempURL("fine", ext: "jsonl")
  try #"{"type":"user","message":{"role":"user","content":"hi"}}"#
    .write(to: fine, atomically: true, encoding: .utf8)
  #expect(TranscriptParser.parse(fileURL: fine).wasReadable == true)
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
