import Foundation

/// A slice of a transcript message's text, carrying the message's REAL index so a chunk
/// never exceeds the model's context window even when a single message is oversized.
/// Verification resolves `index` back to the full message — a quote from any fragment
/// is still a substring of that message, so it still verifies.
struct PromptFragment: Sendable {
  let index: Int
  let text: String
}

/// Proposes loose-end candidates from GENUINE USER PROSE only. The model proposes;
/// the LooseEndVerifier disposes — so this stage optimizes for recall, not trust.
public struct LooseEndExtractor {
  private let provider: any LLMProvider
  private let chunkCharBudget: Int

  public init(provider: any LLMProvider, chunkCharBudget: Int = 2500) {
    self.provider = provider
    self.chunkCharBudget = chunkCharBudget
  }

  /// The smallest chunk we bother re-splitting on a context-overflow retry: if a fragment
  /// this small still overflows, we skip it rather than loop (it can't exceed the window).
  static let minFragmentChars = 200

  public func extract(from messages: [TranscriptMessage]) async throws -> [LooseEndCandidate] {
    let prompts = messages.filter { $0.isUserPrompt }
    guard !prompts.isEmpty else { return [] }
    // Keep only the developer's genuine conversational intent — drop pasted briefs, plans,
    // code, and tool output that the transcript records as `user` turns but aren't intent.
    let genuine = await IntentClassifier(provider: provider).filterGenuine(prompts)
    guard !genuine.isEmpty else { return [] }
    var candidates: [LooseEndCandidate] = []
    for chunk in Self.chunkFragments(genuine, budget: chunkCharBudget) {
      candidates.append(contentsOf: try await extractChunk(chunk))
    }
    return candidates
  }

  /// Completes one chunk; if the model rejects it for exceeding the context window (token
  /// density varies wildly, so a char budget can't guarantee a fit), split the fragments
  /// and retry each half — so no chunk ever fails a whole session. Non-overflow errors are
  /// rethrown for the caller (ExtractionRunner) to isolate per session.
  private func extractChunk(_ fragments: [PromptFragment]) async throws -> [LooseEndCandidate] {
    guard !fragments.isEmpty else { return [] }
    do {
      return try await provider.extractCandidates(prompt: Self.buildPrompt(fragments))
    } catch {
      let message = "\(error)".lowercased()
      let isOverflow = message.contains("exceededcontextwindowsize")
        || (message.contains("exceeds") && message.contains("context"))
      let total = fragments.reduce(0) { $0 + $1.text.count }
      guard isOverflow, total > Self.minFragmentChars else { throw error }
      var out: [LooseEndCandidate] = []
      for half in Self.splitChunk(fragments) where !half.isEmpty {
        out.append(contentsOf: try await extractChunk(half))
      }
      return out
    }
  }

  /// Splits a chunk into two roughly-equal halves: by fragment when there are several, or
  /// by character (preserving the message index) when a single fragment is still too big.
  static func splitChunk(_ fragments: [PromptFragment]) -> [[PromptFragment]] {
    if fragments.count > 1 {
      let mid = fragments.count / 2
      return [Array(fragments[..<mid]), Array(fragments[mid...])]
    }
    guard let only = fragments.first, only.text.count > 1 else { return [fragments] }
    let mid = only.text.index(only.text.startIndex, offsetBy: only.text.count / 2)
    return [[PromptFragment(index: only.index, text: String(only.text[..<mid]))],
            [PromptFragment(index: only.index, text: String(only.text[mid...]))]]
  }

  /// Splits every message into ≤-budget fragments, then greedily packs fragments into
  /// chunks whose combined text stays within budget. Invariant: every fragment's
  /// `text.count <= budget`, and every chunk's total `text.count <= budget`.
  static func chunkFragments(_ prompts: [TranscriptMessage], budget: Int) -> [[PromptFragment]] {
    var chunks: [[PromptFragment]] = [], current: [PromptFragment] = [], size = 0
    for p in prompts {
      for fragment in splitIntoFragments(index: p.index, text: p.text, budget: budget) {
        if size + fragment.text.count > budget, !current.isEmpty {
          chunks.append(current); current = []; size = 0
        }
        current.append(fragment); size += fragment.text.count
      }
    }
    if !current.isEmpty { chunks.append(current) }
    return chunks
  }

  /// Splits `text` into consecutive character-windows of at most `budget` characters,
  /// each tagged with the owning message's real index.
  private static func splitIntoFragments(index: Int, text: String, budget: Int) -> [PromptFragment] {
    guard budget > 0, text.count > budget else { return [PromptFragment(index: index, text: text)] }
    var fragments: [PromptFragment] = []
    var start = text.startIndex
    while start < text.endIndex {
      let end = text.index(start, offsetBy: budget, limitedBy: text.endIndex) ?? text.endIndex
      fragments.append(PromptFragment(index: index, text: String(text[start..<end])))
      start = end
    }
    return fragments
  }

  static func buildPrompt(_ chunk: [PromptFragment]) -> String {
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

  /// Extracts the first complete top-level JSON array from arbitrary model output; skips malformed.
  public static func decodeCandidates(_ raw: String) -> [LooseEndCandidate] {
    guard let slice = firstJSONArray(in: raw), let data = slice.data(using: .utf8),
          let decoded = try? JSONDecoder().decode([LooseEndCandidate].self, from: data)
    else { return [] }
    return decoded
  }
}
