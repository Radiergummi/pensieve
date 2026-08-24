import ArgumentParser
import Foundation
import PensieveKit

/// The JSON keys are Claude Code's hook contract; the Swift properties stay camelCase. Lives at
/// file scope, not nested in the command, so its `CodingKeys` stays within the type-nesting limit.
private struct HookInput: Decodable {
  let sessionID: String
  let cwd: String
  let transcriptPath: String?
  enum CodingKeys: String, CodingKey {
    case sessionID = "session_id"
    case cwd
    case transcriptPath = "transcript_path"
  }
}

struct CaptureSessionStart: ParsableCommand {
  static let configuration = CommandConfiguration(commandName: "capture-session-start",
    abstract: "Record the branch a Claude Code session launched on (reads hook JSON from stdin).")

  func run() {
    let data = FileHandle.standardInput.readDataToEndOfFile()
    guard let input = try? JSONDecoder().decode(HookInput.self, from: data) else { return }  // dumb: never fail a session
    let branch = Git.run(["rev-parse", "--abbrev-ref", "HEAD"], in: input.cwd) ?? ""
    let commonDir = ProjectResolver.identityKey(forRepoPath: input.cwd) ?? ""
    let payload = SessionStartPayload(sessionID: input.sessionID, cwd: input.cwd,
      branch: branch, commonDir: commonDir, transcriptPath: input.transcriptPath ?? "")
    appendCapture(kind: CaptureKind.ccSessionStart, encoding: payload)
  }
}
