import ArgumentParser
import PensieveKit

struct CaptureCheckout: ParsableCommand {
  static let configuration = CommandConfiguration(commandName: "capture-checkout")
  @Option var repo: String
  @Option var from: String
  // Installed git hooks pass `--to`, so the flag name is pinned independently of the property name.
  @Option(name: .customLong("to")) var toRef: String
  @Option var branch: String

  func run() throws {
    let payload = GitCheckoutPayload(repoPath: repo, from: from, to: toRef, branch: branch)
    try openSpool().append(kind: CaptureKind.gitCheckout, payload: try encodeJSON(payload))
  }
}
