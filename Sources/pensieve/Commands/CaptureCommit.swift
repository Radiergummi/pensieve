import ArgumentParser
import PensieveKit

struct CaptureCommit: ParsableCommand {
  static let configuration = CommandConfiguration(commandName: "capture-commit")
  @Option var repo: String
  @Option var hash: String
  @Option var branch: String

  func run() throws {
    let payload = GitCommitPayload(repoPath: repo, hash: hash, branch: branch)
    try openSpool().append(kind: CaptureKind.gitCommit, payload: try encodeJSON(payload))
  }
}
