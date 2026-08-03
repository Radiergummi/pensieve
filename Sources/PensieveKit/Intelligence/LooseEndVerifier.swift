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

  public static func verify(_ candidate: LooseEndCandidate, messages: [TranscriptMessage]) -> VerifiedLooseEnd? {
    let needle = normalizeWhitespace(candidate.quote)
    guard needle.count >= minQuoteLength else { return nil }
    guard let message = messages.first(where: { $0.index == candidate.messageIndex }) else { return nil }
    guard message.isUserPrompt else { return nil }
    let haystack = normalizeWhitespace(message.text)
    guard haystack.contains(needle) else { return nil }   // needle is already ≥ minQuoteLength, so non-empty
    return VerifiedLooseEnd(text: candidate.text, quote: candidate.quote, role: message.role, sourceMessageIndex: message.index)
  }
}
