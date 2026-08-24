import ArgumentParser
import PensieveKit

struct CaptureCheckout: ParsableCommand {
  static let configuration = CommandConfiguration(commandName: "capture-checkout")
  @Option var repo: String
  @Option var from: String
  // Installed git hooks pass `--to`, so the flag name is pinned independently of the property name.
  @Option(name: .customLong("to")) var toRef: String
  @Option var branch: String

  func run() {
    // Capture-time identity resolution, for the reason spelled out in `CaptureCommit`.
    let payload = GitCheckoutPayload(repoPath: repo, from: from, to: toRef, branch: branch,
                                     commonDir: ProjectResolver.identityKey(forRepoPath: repo))
    appendCapture(kind: CaptureKind.gitCheckout, encoding: payload)
  }
}
