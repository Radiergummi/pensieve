import ArgumentParser
import Foundation
import PensieveKit

struct InstallSessionHook: ParsableCommand {
  static let configuration = CommandConfiguration(commandName: "install-session-hook",
    abstract: "Install the Claude Code SessionStart and SessionEnd hooks into ~/.claude/settings.json.")
  func run() throws {
    let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/settings.json")
    let pensievePath = Bundle.main.executablePath ?? "pensieve"
    let start = try SettingsHookInstaller.install(settingsURL: url, pensievePath: pensievePath)
    let end = try SettingsHookInstaller.installSessionEnd(settingsURL: url, pensievePath: pensievePath)
    print(start ? "installed SessionStart hook in \(url.path)" : "SessionStart hook already present in \(url.path)")
    print(end ? "installed SessionEnd hook in \(url.path)" : "SessionEnd hook already present in \(url.path)")
  }
}
