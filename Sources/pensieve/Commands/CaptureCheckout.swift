import ArgumentParser
import PensieveKit

struct CaptureCheckout: ParsableCommand {
  static let configuration = CommandConfiguration(commandName: "capture-checkout")
  @Option var repo: String
  @Option var from: String
  @Option var to: String
  @Option var branch: String

  func run() throws {
    let payload = GitCheckoutPayload(repoPath: repo, from: from, to: to, branch: branch)
    try openSpool().append(kind: CaptureKind.gitCheckout, payload: try encodeJSON(payload))
  }
}
