import Foundation
import Testing
@testable import PensieveKit

@Suite struct PassageExtractorTests {
  private let nodeID = UUID()
  private let eventID = UUID()
  private let anchorDate = Date(timeIntervalSince1970: 1_700_000_000)

  private func message(_ index: Int, _ role: String, _ text: String,
                       isUserPrompt: Bool) -> TranscriptMessage {
    TranscriptMessage(index: index, role: role, text: text,
                      timestamp: Date(timeIntervalSince1970: 1_700_000_000 + Double(index)),
                      isUserPrompt: isUserPrompt)
  }

  private func extract(_ messages: [TranscriptMessage]) -> [Passage] {
    let session = ParsedSession(sessionID: "s", cwd: "/tmp", startedAt: nil, endedAt: nil,
                               userPromptCount: 0, messages: messages)
    return PassageExtractor.passages(from: session, nodeID: nodeID, eventID: eventID,
                                     fallbackDate: anchorDate)
  }

  @Test func aPromptAndItsReplyShareATurn() {
    let passages = extract([
      message(0, "user", "why does background sync refuse to spawn", isUserPrompt: true),
      message(1, "assistant", "The agent's LWCR is stale, so launchd rejects the spawn.",
              isUserPrompt: false),
    ])
    #expect(passages.count == 2)
    #expect(passages[0].role == .prompt)
    #expect(passages[1].role == .reply)
    #expect(passages[0].turnIndex == 0)
    #expect(passages[1].turnIndex == 0)
  }

  @Test func aSecondPromptStartsANewTurn() {
    let passages = extract([
      message(0, "user", "first real question about the sync agent", isUserPrompt: true),
      message(1, "assistant", "First substantive answer about launchd.", isUserPrompt: false),
      message(2, "user", "second real question about the search index", isUserPrompt: true),
      message(3, "assistant", "Second substantive answer about FTS5.", isUserPrompt: false),
    ])
    #expect(passages.map(\.turnIndex) == [0, 0, 1, 1])
  }

  /// The gate that keeps the corpus clean. A `type:"user"` record that is a tool result or an
  /// injected envelope arrives with `isUserPrompt == false` and is NOT assistant prose, so it must
  /// produce nothing at all.
  @Test func nonPromptUserRecordsAreExcluded() {
    let passages = extract([
      message(0, "user", "<system-reminder>injected body</system-reminder>", isUserPrompt: false),
      message(1, "user", "tool result payload with lots of text", isUserPrompt: false),
    ])
    #expect(passages.isEmpty)
  }

  /// An unknown role is neither a prompt nor assistant prose. `role` is not a closed set, so this
  /// must fall through rather than be stored as one or the other.
  @Test func unknownRolesAreExcluded() {
    let passages = extract([message(0, "system", "some machine envelope text", isUserPrompt: false)])
    #expect(passages.isEmpty)
  }

  /// The prompt gate is `TextQuality.isProse` — the project's single definition of text worth
  /// keeping — not a second notion of degeneracy invented here. What it rejects is what gets
  /// dropped; a short affirmation that clears it is still real user text and is stored.
  @Test func degeneratePromptsAreDropped() {
    let passages = extract([
      message(0, "user", "ok", isUserPrompt: true),
      message(1, "user", "yes", isUserPrompt: true),
    ])
    #expect(passages.isEmpty)
  }

  /// A reply longer than the single-chunk limit becomes several passages that share their message
  /// index and their turn — that shared identity is what the retrieval layer dedupes on.
  @Test func aLongReplyBecomesSeveralPassagesSharingItsTurnAndMessageIndex() {
    let long = Array(repeating: "sentence about the retrieval index", count: 200)
      .joined(separator: " ")
    let passages = extract([
      message(0, "user", "explain the retrieval index in detail please", isUserPrompt: true),
      message(1, "assistant", long, isUserPrompt: false),
    ])
    let replies = passages.filter { $0.role == .reply }
    #expect(replies.count > 1)
    #expect(Set(replies.map(\.messageIndex)) == [1])
    #expect(Set(replies.map(\.turnIndex)) == [0])
    #expect(Set(replies.map(\.id)).count == replies.count, "each chunk is its own row")
  }

  /// A reply with no preceding prompt (a transcript that starts mid-stream, or one whose opening
  /// prompt was an injected envelope) still gets a turn rather than being dropped or crashing.
  @Test func aReplyWithNoPrecedingPromptStillGetsATurn() {
    let passages = extract([
      message(0, "assistant", "Continuing from the previous session's work.", isUserPrompt: false),
    ])
    #expect(passages.count == 1)
    #expect(passages[0].role == .reply)
    #expect(passages[0].turnIndex == 0)
  }

  @Test func aMessageWithoutATimestampFallsBackToTheAnchorDate() {
    let session = ParsedSession(sessionID: "s", cwd: "/tmp", startedAt: nil, endedAt: nil,
                               userPromptCount: 0,
                               messages: [TranscriptMessage(index: 0, role: "user",
                                                            text: "a real question about sync",
                                                            timestamp: nil, isUserPrompt: true)])
    let passages = PassageExtractor.passages(from: session, nodeID: nodeID, eventID: eventID,
                                            fallbackDate: anchorDate)
    #expect(passages.first?.occurredAt == anchorDate)
  }
}
