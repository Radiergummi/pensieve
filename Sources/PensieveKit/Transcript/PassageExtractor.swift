import Foundation

/// Turns a parsed transcript into the passages Pensieve stores.
///
/// **The corpus rule, and why it needs no new vocabulary.** Prompts are exactly the messages
/// `TranscriptParser` flags `isUserPrompt` — a conjunctive gate that already excludes tool results,
/// `isMeta` records, slash-command envelopes and injected skill bodies. Replies are exactly
/// `role == "assistant"`, which already excludes tool calls for free: `extractText` reads only
/// `text` blocks, so a tool-use-only message has empty text and never enters
/// `ParsedSession.messages`. Everything else is skipped.
///
/// `TranscriptVocabulary.injectionMarkers` is therefore READ (transitively, through
/// `isUserPrompt`) and never written, extended, or referenced here. The trust gate is untouched.
public enum PassageExtractor {
  /// Assistant prose is not put through `TextQuality.isProse`. That gate exists to drop degenerate
  /// *model output* stored as a summary ("[]", a bare "/"), and a short real answer ("Yes — the
  /// LWCR is stale.") is legitimate content whose brevity is meaningful.
  /// Prompts ARE gated, through `TextQuality.isProse` — this project's single definition of text
  /// worth keeping — because a bare "ok" carries no recallable intent. Deliberately NOT a second,
  /// passage-specific notion of degeneracy: a short affirmation that clears the shared gate is still
  /// real user text, and two competing definitions of "degenerate" would drift apart.
  public static func passages(from session: ParsedSession, nodeID: UUID, eventID: UUID,
                              fallbackDate: Date) -> [Passage] {
    var passages: [Passage] = []
    var turnIndex = 0
    var sawAnyMessageInTurn = false

    for message in session.messages {
      let role: PassageRole
      if message.isUserPrompt {
        // A new human turn. Only advance PAST the first one, so the first prompt is turn 0.
        if sawAnyMessageInTurn { turnIndex += 1 }
        sawAnyMessageInTurn = true
        guard TextQuality.isProse(message.text) else { continue }
        role = .prompt
      } else if message.role == "assistant" {
        sawAnyMessageInTurn = true
        role = .reply
      } else {
        continue   // tool result, injected envelope, unknown role — not conversation
      }
      for chunk in PassageChunker.chunk(message.text) {
        passages.append(Passage(nodeID: nodeID, eventID: eventID, turnIndex: turnIndex,
                                messageIndex: message.index, role: role, text: chunk,
                                occurredAt: message.timestamp ?? fallbackDate))
      }
    }
    return passages
  }
}
