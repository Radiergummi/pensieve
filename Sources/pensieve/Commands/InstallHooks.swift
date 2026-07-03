import ArgumentParser
import Foundation
import PensieveKit

struct InstallHooks: ParsableCommand {
  static let configuration = CommandConfiguration(commandName: "install-hooks",
    abstract: "Install Pensieve git hooks into a repository.")
  @Argument var repo: String
  func run() throws {
    let url = URL(fileURLWithPath: repo).standardizedFileURL
    let pensievePath = Bundle.main.executablePath ?? "pensieve"
    let written = try HookInstaller.install(inRepo: url, pensievePath: pensievePath)
    for w in written { print("installed \(w.path)") }
  }
}
