import Foundation

/// Decides which of a developer's messages express their OWN conversational intent
/// (requests, questions, decisions, todos) versus pasted or instructional content —
/// agent briefs ("You are taking over…"), step-by-step plans, source code,
/// documentation, or tool/assistant output. Only genuine-intent messages should feed
/// loose-end extraction.
///
/// The transcript's own metadata cannot separate these (a pasted brief is recorded as a
/// `promptSource: typed` user message just like real prose), so this is necessarily a
/// semantic judgment. It runs on the same local `LLMProvider` as extraction (free,
/// on-device). It FAILS OPEN — on any classifier hiccup it keeps the messages — so a
/// glitch never silently zeroes out extraction; the verbatim verifier still gates trust.
public struct IntentClassifier {
  private let provider: any LLMProvider
  private let batchCharBudget: Int

  public init(provider: any LLMProvider, batchCharBudget: Int = 2000) {
    self.provider = provider
    self.batchCharBudget = batchCharBudget
  }

  /// Returns the subset of `messages` judged to be the developer's own conversational
  /// intent, preserving order. Excludes pasted/instructional/code/tool content.
  public func filterGenuine(_ messages: [TranscriptMessage]) async -> [TranscriptMessage] {
    guard !messages.isEmpty else { return [] }
    var kept: [TranscriptMessage] = []
    for batch in Self.batches(messages, budget: batchCharBudget) {
      let keep: Set<Int>
      if let raw = try? await provider.complete(prompt: Self.buildPrompt(batch)),
         let indices = Self.decodeIndices(raw) {
        keep = indices
      } else {
        keep = Set(batch.map { $0.index })   // fail open: keep the whole batch
      }
      kept.append(contentsOf: batch.filter { keep.contains($0.index) })
    }
    return kept
  }

  /// Groups messages into batches whose per-message classification cost (capped, see
  /// `buildPrompt`) stays within `budget`, so a batch prompt never blows the context.
  static func batches(_ messages: [TranscriptMessage], budget: Int) -> [[TranscriptMessage]] {
    var out: [[TranscriptMessage]] = [], current: [TranscriptMessage] = [], size = 0
    for m in messages {
      let cost = min(m.text.count, headLimit) + 8   // capped head + the "[n] " tag overhead
      if size + cost > budget, !current.isEmpty { out.append(current); current = []; size = 0 }
      current.append(m); size += cost
    }
    if !current.isEmpty { out.append(current) }
    return out
  }

  /// The classifier only needs the opening of each message to tell intent from a pasted
  /// brief/plan/code, so each message is capped to this many characters in the prompt.
  static let headLimit = 400

  static func buildPrompt(_ batch: [TranscriptMessage]) -> String {
    let body = batch.map { m -> String in
      let head = m.text.count > headLimit ? String(m.text.prefix(headLimit)) + " …" : m.text
      return "[\(m.index)] \(head)"
    }.joined(separator: "\n\n")
    return """
    Below are a developer's chat messages, each tagged [n]. Some are the developer's OWN \
    words — a request, a question, a decision, or a note about what they want done. Others \
    are PASTED or INSTRUCTIONAL content: briefs written to an AI assistant (e.g. "You are \
    taking over…", "Your job is…"), step-by-step plans or checklists, source code, \
    documentation, or tool/assistant output.

    Return ONLY a JSON array of the [n] numbers whose message is the developer's OWN \
    conversational intent. Exclude anything that is pasted, instructional, code, or tool \
    output. If none qualify, return [].

    Messages:
    \(body)
    """
  }

  /// Parses a JSON array of integers from arbitrary model output. Returns nil when no
  /// integer array is parseable (→ caller fails open), so a non-array response — e.g. the
  /// model echoing prose — never silently drops every message.
  static func decodeIndices(_ raw: String) -> Set<Int>? {
    guard let start = raw.firstIndex(of: "["), let end = raw.lastIndex(of: "]"), start < end
    else { return nil }
    let slice = String(raw[start...end])
    guard let data = slice.data(using: .utf8),
          let array = try? JSONDecoder().decode([Int].self, from: data)
    else { return nil }
    return Set(array)
  }
}
