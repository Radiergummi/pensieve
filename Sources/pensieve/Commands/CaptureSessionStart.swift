import ArgumentParser
import Foundation
import PensieveKit

struct CaptureSessionStart: ParsableCommand {
  static let configuration = CommandConfiguration(commandName: "capture-session-start",
    abstract: "Record the branch a Claude Code session launched on (reads hook JSON from stdin).")

  private struct HookInput: Decodable { let session_id: String; let cwd: String; let transcript_path: String? }

  func run() throws {
    let data = FileHandle.standardInput.readDataToEndOfFile()
    guard let h = try? JSONDecoder().decode(HookInput.self, from: data) else { return }  // dumb: never fail a session
    let branch = Git.run(["rev-parse", "--abbrev-ref", "HEAD"], in: h.cwd) ?? ""
    let commonDir = Git.commonDir(in: h.cwd) ?? ""
    let payload = SessionStartPayload(sessionID: h.session_id, cwd: h.cwd,
      branch: branch, commonDir: commonDir, transcriptPath: h.transcript_path ?? "")
    try? openSpool().append(kind: CaptureKind.ccSessionStart, payload: try encodeJSON(payload))
  }
}
