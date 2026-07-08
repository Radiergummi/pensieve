import Foundation

/// Produces a short, grounded "what was worked on this session" summary from a parsed
/// transcript. Best-effort prose that feeds narration (Part B) — it reads assistant turns
/// the loose-end trust gate deliberately never touches, so it is an explicit, bounded
/// groundedness exemption (like narration / strand naming), NOT part of the cited gate.
///
/// Bounded like the extractor: sessions are multi-MB, so a single `complete` over a whole
/// session overflows the ~3B window. The summarizer chunks the input, summarizes each chunk
/// (map), then summarizes the joined partials (reduce), and hard-caps the stored output.
/// Every failure path returns nil so a bad/absent summary never gates loose-end insertion.
public struct SessionSummarizer: Sendable {
  private let provider: any LLMProvider

  /// Max chars fed to the model in one `complete` call (keeps a single call within the window).
  public static let inputBudget = 6000
  /// Hard cap on the stored `workSummary` (a couple of sentences).
  public static let outputCap = 600

  public init(provider: any LLMProvider) { self.provider = provider }

  /// nil when there is nothing to summarize or the provider fails/returns empty.
  public func summarize(_ messages: [TranscriptMessage]) async -> String? {
    let blob = Self.relevantBlob(messages)
    guard !blob.isEmpty else { return nil }
    return await summarizeText(blob)
  }

  /// The developer's own prompts + the assistant's replies, in order — the material a
  /// "what was worked on" summary needs. Excludes tool results / meta / injected content
  /// (those are neither `isUserPrompt` nor `role == "assistant"`).
  static func relevantBlob(_ messages: [TranscriptMessage]) -> String {
    messages
      .filter { $0.isUserPrompt || $0.role == "assistant" }
      .map { "\($0.role): \($0.text)" }
      .joined(separator: "\n\n")
  }

  private func summarizeText(_ text: String) async -> String? {
    let chunks = Self.chunk(text, budget: Self.inputBudget)
    if chunks.count <= 1 {
      return await completeCapped(chunks.first ?? text)
    }
    var partials: [String] = []
    for c in chunks {
      if let s = await completeCapped(c) { partials.append(s) }
    }
    guard !partials.isEmpty else { return nil }
    let joined = partials.joined(separator: "\n")
    // One reduce level. If the partials themselves overflow, feed a truncated head; the
    // fallback (capped joined partials) still yields grounded-if-terse prose.
    return await completeCapped(String(joined.prefix(Self.inputBudget))) ?? String(joined.prefix(Self.outputCap))
  }

  private func completeCapped(_ body: String) async -> String? {
    guard let raw = try? await provider.complete(prompt: Self.prompt(body)) else { return nil }
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : String(trimmed.prefix(Self.outputCap))
  }

  static func prompt(_ body: String) -> String {
    """
    Summarize, in 1-2 sentences, ONLY the work actually done in the coding session below — \
    what was built, changed, investigated, or decided. Do not speculate, infer, or add \
    anything not present in the text. If the text is thin, be brief.

    \(body)
    """
  }

  /// Splits text into ≤-budget windows on whitespace boundaries (never mid-word unless a
  /// single token exceeds the budget).
  static func chunk(_ text: String, budget: Int) -> [String] {
    guard budget > 0, text.count > budget else { return text.isEmpty ? [] : [text] }
    var out: [String] = []
    var start = text.startIndex
    while start < text.endIndex {
      var end = text.index(start, offsetBy: budget, limitedBy: text.endIndex) ?? text.endIndex
      if end < text.endIndex, let ws = text[start..<end].lastIndex(where: { $0.isWhitespace }) {
        end = text.index(after: ws)
      }
      out.append(String(text[start..<end]))
      start = end
    }
    return out
  }
}
