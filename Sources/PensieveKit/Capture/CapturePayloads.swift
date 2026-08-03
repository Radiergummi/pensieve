import Foundation

public enum CaptureKind {
  public static let gitCommit = "git.commit"
  public static let gitCheckout = "git.checkout"
  public static let ccSession = "cc.session"
  public static let ccSessionStart = "cc.session.start"
}

public enum SourceKind {
  public static let gitRepo = "gitRepo"
  public static let claudeCode = "claudeCode"
}

public struct GitCommitPayload: Codable, Sendable {
  public var repoPath: String; public var hash: String; public var branch: String
  public init(repoPath: String, hash: String, branch: String) {
    self.repoPath = repoPath; self.hash = hash; self.branch = branch
  }
}

public struct GitCheckoutPayload: Codable, Sendable {
  public var repoPath: String; public var fromRef: String; public var toRef: String; public var branch: String
  public init(repoPath: String, from fromRef: String, to toRef: String, branch: String) {
    self.repoPath = repoPath; self.fromRef = fromRef; self.toRef = toRef; self.branch = branch
  }

  // The JSON keys are the on-disk spool contract: rows written by an older CLI must still decode.
  enum CodingKeys: String, CodingKey {
    case repoPath, branch
    case fromRef = "from"
    case toRef = "to"
  }
}

public struct SessionRefPayload: Codable, Sendable {
  public var transcriptPath: String
  public init(transcriptPath: String) { self.transcriptPath = transcriptPath }
}

public struct SessionStartPayload: Codable, Sendable {
  public var sessionID: String; public var cwd: String
  public var branch: String; public var commonDir: String; public var transcriptPath: String
  public init(sessionID: String, cwd: String, branch: String, commonDir: String, transcriptPath: String) {
    self.sessionID = sessionID; self.cwd = cwd; self.branch = branch
    self.commonDir = commonDir; self.transcriptPath = transcriptPath
  }
}

enum EncodeJSONError: Error { case invalidUTF8 }

public func encodeJSON<T: Encodable>(_ value: T) throws -> String {
  let encoder = JSONEncoder()
  encoder.outputFormatting = [.sortedKeys]
  let data = try encoder.encode(value)
  guard let json = String(bytes: data, encoding: .utf8) else { throw EncodeJSONError.invalidUTF8 }
  return json
}

public func decodeJSON<T: Decodable>(_ jsonString: String) throws -> T {
  try JSONDecoder().decode(T.self, from: Data(jsonString.utf8))
}

/// Decodes a Claude Code `SessionEnd` hook payload (stdin JSON) into a spoolable session ref.
/// Returns nil for malformed JSON or an empty/absent `transcript_path` — dumb by design: the
/// hook must never fail a session.
public func sessionRefFromSessionEndHook(_ data: Data) -> SessionRefPayload? {
  struct HookInput: Decodable {
    let transcriptPath: String?
    enum CodingKeys: String, CodingKey { case transcriptPath = "transcript_path" }
  }
  guard let hookInput = try? JSONDecoder().decode(HookInput.self, from: data),
        let path = hookInput.transcriptPath, !path.isEmpty else { return nil }
  return SessionRefPayload(transcriptPath: path)
}
