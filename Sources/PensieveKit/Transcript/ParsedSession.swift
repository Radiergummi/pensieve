import Foundation

public struct TranscriptMessage: Sendable {
  public let index: Int
  public let role: String
  public let text: String
  public let timestamp: Date?
  public let isUserPrompt: Bool
}

public struct ParsedSession: Sendable {
  public let sessionID: String
  public let cwd: String?
  public let startedAt: Date?
  public let endedAt: Date?
  public let userPromptCount: Int
  public let messages: [TranscriptMessage]
}
