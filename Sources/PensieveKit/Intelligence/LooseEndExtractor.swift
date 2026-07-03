import Foundation

/// Proposes loose-end candidates from GENUINE USER PROSE only. The model proposes;
/// the LooseEndVerifier disposes — so this stage optimizes for recall, not trust.
public struct LooseEndExtractor {
  private let provider: any LLMProvider
  private let chunkCharBudget: Int

  public init(provider: any LLMProvider, chunkCharBudget: Int = 6000) {
    self.provider = provider
    self.chunkCharBudget = chunkCharBudget
  }

  public func extract(from messages: [TranscriptMessage]) async throws -> [LooseEndCandidate] {
    let prompts = messages.filter { $0.isUserPrompt }
    guard !prompts.isEmpty else { return [] }
    var candidates: [LooseEndCandidate] = []
    for chunk in chunked(prompts) {
      let raw = try await provider.complete(prompt: Self.buildPrompt(chunk))
      candidates.append(contentsOf: Self.decodeCandidates(raw))
    }
    return candidates
  }

  /// Groups user prompts into windows under the char budget (approximate token control).
  private func chunked(_ prompts: [TranscriptMessage]) -> [[TranscriptMessage]] {
    var chunks: [[TranscriptMessage]] = [], current: [TranscriptMessage] = [], size = 0
    for p in prompts {
      if size + p.text.count > chunkCharBudget, !current.isEmpty {
        chunks.append(current); current = []; size = 0
      }
      current.append(p); size += p.text.count
    }
    if !current.isEmpty { chunks.append(current) }
    return chunks
  }

  static func buildPrompt(_ chunk: [TranscriptMessage]) -> String {
    let body = chunk.map { "[\($0.index)] \($0.text)" }.joined(separator: "\n\n")
    return """
    You extract LOOSE ENDS from a developer's own messages: things they said they would \
    do, planned, or left unfinished, but which may not be done. Only use the text below.

    Return ONLY a JSON array. Each element: {"text": <short paraphrase>, "quote": <a VERBATIM \
    substring copied exactly from one message, including its original wording and casing>, \
    "messageIndex": <the [n] of the message the quote is from>}. The quote MUST be copied \
    character-for-character from a single message. If there are no loose ends, return [].

    Messages:
    \(body)
    """
  }

  /// Extracts the first top-level JSON array from arbitrary model output; skips malformed.
  public static func decodeCandidates(_ raw: String) -> [LooseEndCandidate] {
    guard let start = raw.firstIndex(of: "["), let end = raw.lastIndex(of: "]"), start < end
    else { return [] }
    let slice = String(raw[start...end])
    guard let data = slice.data(using: .utf8),
          let decoded = try? JSONDecoder().decode([LooseEndCandidate].self, from: data)
    else { return [] }
    return decoded
  }
}
