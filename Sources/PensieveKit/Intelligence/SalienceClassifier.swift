import Foundation

/// The salience gate: drops verified loose ends that are in-the-moment requests the assistant
/// simply carried out ("read the spec", "can you fix this?") rather than deferred/parked/decision
/// work the developer left open. Runs AFTER the verbatim gate, so it only ever judges real,
/// already-verified quotes and can never fabricate — it only filters.
///
/// Conservative by construction: the model returns the DROP set (clear non-loose-ends); a hard
/// provider error fails open (keep all) and an empty drop set keeps all, so every uncertain path
/// favors keeping. The verbatim trust gate is untouched.
public struct SalienceClassifier {
  private let provider: any LLMProvider
  private let batchCharBudget: Int

  public init(provider: any LLMProvider, batchCharBudget: Int = 2000) {
    self.provider = provider
    self.batchCharBudget = batchCharBudget
  }

  /// Messages each side of the cited one included as disambiguating context.
  static let contextNeighbors = 1
  /// Per-message char cap in the context window (keeps a batch bounded).
  static let messageHeadLimit = 300

  public func filter(_ ends: [VerifiedLooseEnd], messages: [TranscriptMessage]) async -> [VerifiedLooseEnd] {
    guard !ends.isEmpty else { return [] }
    var kept: [VerifiedLooseEnd] = []
    for batch in Self.batches(ends, messages: messages, budget: batchCharBudget) {
      let drop: Set<Int>
      if let idx = try? await provider.classifyNonSalientIndices(prompt: Self.buildPrompt(batch, messages: messages)) {
        drop = Set(idx)                       // structured answer: trust the drop set (empty = keep all)
      } else {
        drop = []                             // hard error: fail open, keep all
      }
      for (n, e) in batch.enumerated() where !drop.contains(n) { kept.append(e) }
    }
    return kept
  }

  /// Groups ends into batches whose per-item prompt cost (quote + capped context) stays within budget.
  static func batches(_ ends: [VerifiedLooseEnd], messages: [TranscriptMessage], budget: Int) -> [[VerifiedLooseEnd]] {
    var out: [[VerifiedLooseEnd]] = [], current: [VerifiedLooseEnd] = [], size = 0
    for e in ends {
      let cost = e.quote.count + contextWindow(for: e, messages: messages).count + 16
      if size + cost > budget, !current.isEmpty { out.append(current); current = []; size = 0 }
      current.append(e); size += cost
    }
    if !current.isEmpty { out.append(current) }
    return out
  }

  /// The cited message ± `contextNeighbors`, each capped, joined — the framing signal.
  static func contextWindow(for end: VerifiedLooseEnd, messages: [TranscriptMessage]) -> String {
    guard let pos = messages.firstIndex(where: { $0.index == end.sourceMessageIndex }) else { return "" }
    let lo = max(0, pos - contextNeighbors)
    let hi = min(messages.count - 1, pos + contextNeighbors)
    return messages[lo...hi].map { m in
      let head = m.text.count > messageHeadLimit ? String(m.text.prefix(messageHeadLimit)) + " …" : m.text
      return "\(m.role): \(head)"
    }.joined(separator: "\n")
  }

  static func buildPrompt(_ batch: [VerifiedLooseEnd], messages: [TranscriptMessage]) -> String {
    let body = batch.enumerated().map { (n, e) in
      "[\(n)] QUOTE: \(e.quote)\nCONTEXT:\n\(contextWindow(for: e, messages: messages))"
    }.joined(separator: "\n\n")
    return """
    Each item below is a candidate LOOSE END quoted from a developer's message, with surrounding \
    context. A LOOSE END is deferred, parked, or decision work the developer left open for later — \
    e.g. "we should also migrate the auth tables", "let's do X later", "TODO: wire up the webhook", \
    "let's go with A instead of B". It is NOT an in-the-moment request the assistant simply carried \
    out now — e.g. "read the spec", "can you fix this?", "run the tests", "subagent-driven, let's go".

    Return ONLY a JSON array of the [n] numbers that are clearly in-the-moment requests / NOT loose \
    ends (these will be dropped). When you are unsure about an item, do NOT include it (keep it). If \
    every item is a genuine loose end, return [].

    Items:
    \(body)
    """
  }
}
