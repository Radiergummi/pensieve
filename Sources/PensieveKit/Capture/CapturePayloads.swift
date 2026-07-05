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
  public var repoPath: String; public var from: String; public var to: String; public var branch: String
  public init(repoPath: String, from: String, to: String, branch: String) {
    self.repoPath = repoPath; self.from = from; self.to = to; self.branch = branch
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

public func encodeJSON<T: Encodable>(_ v: T) throws -> String {
  let encoder = JSONEncoder()
  encoder.outputFormatting = [.withoutEscapingSlashes]
  let data = try encoder.encode(v)
  return String(decoding: data, as: UTF8.self)
}

/// Decodes a Claude Code `SessionEnd` hook payload (stdin JSON) into a spoolable session ref.
/// Returns nil for malformed JSON or an empty/absent `transcript_path` — dumb by design: the
/// hook must never fail a session.
public func sessionRefFromSessionEndHook(_ data: Data) -> SessionRefPayload? {
  struct HookInput: Decodable { let transcript_path: String? }
  guard let h = try? JSONDecoder().decode(HookInput.self, from: data),
        let path = h.transcript_path, !path.isEmpty else { return nil }
  return SessionRefPayload(transcriptPath: path)
}
