import Foundation

public struct LooseEndCandidate: Codable, Sendable {
  public let text: String
  public let quote: String
  public let messageIndex: Int
  public init(text: String, quote: String, messageIndex: Int) {
    self.text = text; self.quote = quote; self.messageIndex = messageIndex
  }
}

public struct VerifiedLooseEnd: Sendable {
  public let text: String
  public let quote: String
  public let role: String
  public let sourceMessageIndex: Int
}

/// The gate: a candidate survives only if its quote is verbatim (whitespace-normalized),
/// long enough, and drawn from a genuine user-authored message. Everything else is dropped.
public enum LooseEndVerifier {
  public static let minQuoteLength = 15

  public static func verify(_ c: LooseEndCandidate, messages: [TranscriptMessage]) -> VerifiedLooseEnd? {
    guard c.quote.count >= minQuoteLength else { return nil }
    guard let m = messages.first(where: { $0.index == c.messageIndex }) else { return nil }
    guard m.isUserPrompt else { return nil }
    let haystack = normalizeWhitespace(m.text)
    let needle = normalizeWhitespace(c.quote)
    guard !needle.isEmpty, haystack.contains(needle) else { return nil }
    return VerifiedLooseEnd(text: c.text, quote: c.quote, role: m.role, sourceMessageIndex: m.index)
  }
}
