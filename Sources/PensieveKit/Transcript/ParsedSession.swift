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
  /// Genuine human turns only — not every `type:"user"` record. See `TranscriptParser`.
  public let userPromptCount: Int
  public let messages: [TranscriptMessage]
  /// Whether the transcript file could be read and decoded at all.
  ///
  /// `false` means the parse never saw any content: the file is absent, unreadable (a permissions
  /// blip), or its bytes are not UTF-8. That is what lets the ingester tell a TRANSIENT read failure
  /// (retry — dropping is permanent) from a transcript that read perfectly well and simply carries
  /// no `cwd` (drop — it never will). Without the distinction, one unreadable byte retired a real
  /// session forever.
  ///
  /// Defaults to `true` so a hand-built fixture is a successfully-read session, which also keeps the
  /// memberwise initializer's existing call sites unchanged.
  public var wasReadable: Bool = true
}
