import ArgumentParser
import Foundation
import PensieveKit

struct InstallSessionHook: ParsableCommand {
  static let configuration = CommandConfiguration(commandName: "install-session-hook",
    abstract: "Install the Claude Code SessionStart hook into ~/.claude/settings.json.")
  func run() throws {
    let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/settings.json")
    let pensievePath = Bundle.main.executablePath ?? "pensieve"
    let added = try SettingsHookInstaller.install(settingsURL: url, pensievePath: pensievePath)
    print(added ? "installed SessionStart hook in \(url.path)"
                : "SessionStart hook already present in \(url.path)")
  }
}
