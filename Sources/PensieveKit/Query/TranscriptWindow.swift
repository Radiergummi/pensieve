import Foundation

/// The one definition of "slice the conversation around a cited message, and refuse if the citation
/// no longer holds".
///
/// Loose ends and passages both need this, and they differ in exactly ONE way: a loose end always
/// cites a human turn, so a non-prompt at the stored index proves the index is stale; a passage
/// legitimately cites assistant prose, so requiring `isUserPrompt` would withhold the window from
/// every `.reply` passage — half the corpus, silently. That difference is a PARAMETER. Everything
/// else has to be identical, because this is the mechanism whose entire purpose is never
/// highlighting the wrong message.
///
/// It shipped as two copies once and they drifted inside a single branch: the loose-end copy
/// normalized whitespace on both sides of the containment check (a scar — an un-normalized compare
/// made the inspector falsely report live transcripts as gone), the passage copy compared raw; and
/// one took ±radius of ARRAY POSITIONS where the other took ±radius of INDEX VALUES. The second
/// difference is inert today only because `TranscriptParser` advances `index` solely for messages it
/// keeps, so indices are contiguous and position == value — an accident of that loop, not a property
/// anything states. Both copies' own comments describe indices as sparse, which is what that
/// divergence was reasoning about. One function is what keeps the accident from mattering.
public enum TranscriptWindow {
  /// The ±`radius` window around the message at `messageIndex`, or nil when the citation no longer
  /// holds and the caller must degrade to its own "transcript unavailable" answer.
  public static func slice(session: ParsedSession, messageIndex: Int, citedText: String,
                           requireUserPrompt: Bool, radius: Int) -> [ProvenanceMessage]? {
    // Resolve by identity (index), not bare position — robust to parser-version drift.
    guard let citedPosition = session.messages.firstIndex(where: { $0.index == messageIndex })
    else { return nil }
    let cited = session.messages[citedPosition]

    // Normalize both sides the same way `LooseEndVerifier` did when it accepted a quote (it stores
    // the raw model quote but verifies against whitespace-normalized text) — else a quote whose
    // whitespace the model collapsed fails a raw `contains` and the caller falsely reports the
    // transcript as gone. A passage is sliced verbatim out of the message by our own chunker rather
    // than quoted by a model, so it does not NEED the tolerance; it is safe there (a chunk is a
    // contiguous, end-trimmed substring, so its normalization is still a substring of the
    // message's) and one comparison shared is worth more than one comparison saved.
    guard !requireUserPrompt || cited.isUserPrompt,
          normalizeWhitespace(cited.text).contains(normalizeWhitespace(citedText))
    else { return nil }

    // ±radius of POSITIONS. Slicing the array rather than filtering on index VALUES keeps the
    // window the size the caller asked for even if `index` ever stops being contiguous — a value
    // filter would then silently return fewer neighbours, by an amount that depends on how much
    // tool traffic the session happened to contain.
    let lower = max(0, citedPosition - radius)
    let upper = min(session.messages.count - 1, citedPosition + radius)
    return session.messages[lower...upper].map {
      ProvenanceMessage(index: $0.index, role: $0.role, text: $0.text,
                        isCited: $0.index == messageIndex, isUserPrompt: $0.isUserPrompt)
    }
  }
}
