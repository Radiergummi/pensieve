import Foundation
import Testing
@testable import PensieveKit

private func readJSON(_ url: URL) throws -> [String: Any] {
  try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
}

@Test func installsSessionStartHookIntoMissingFile() throws {
  let url = tempURL("settings", ext: "json")
  let added = try SettingsHookInstaller.install(settingsURL: url, pensievePath: "/opt/pensieve")
  #expect(added)
  let root = try readJSON(url)
  let groups = ((root["hooks"] as? [String: Any])?["SessionStart"]) as? [[String: Any]]
  #expect(groups?.count == 1)
  #expect(groups?.first?["matcher"] as? String == "startup")
  let cmd = ((groups?.first?["hooks"] as? [[String: Any]])?.first?["command"]) as? String
  #expect(cmd == "/opt/pensieve capture-session-start")
}

@Test func installIsIdempotent() throws {
  let url = tempURL("settings", ext: "json")
  _ = try SettingsHookInstaller.install(settingsURL: url, pensievePath: "/opt/pensieve")
  let addedAgain = try SettingsHookInstaller.install(settingsURL: url, pensievePath: "/opt/pensieve")
  #expect(!addedAgain)
  let groups = ((try readJSON(url)["hooks"] as? [String: Any])?["SessionStart"]) as? [[String: Any]]
  #expect(groups?.count == 1)   // not duplicated
}

@Test func installPreservesForeignContent() throws {
  let url = tempURL("settings", ext: "json")
  let seed: [String: Any] = [
    "model": "opus",
    "hooks": ["SessionStart": [["matcher": "startup",
      "hooks": [["type": "command", "command": "/other/tool run"]]]]],
  ]
  try JSONSerialization.data(withJSONObject: seed).write(to: url)
  _ = try SettingsHookInstaller.install(settingsURL: url, pensievePath: "/opt/pensieve")
  let root = try readJSON(url)
  #expect(root["model"] as? String == "opus")                  // foreign top-level key kept
  let groups = ((root["hooks"] as? [String: Any])?["SessionStart"]) as? [[String: Any]]
  #expect(groups?.count == 2)                                  // foreign entry kept, ours appended
  let commands = groups?.flatMap { ($0["hooks"] as? [[String: Any]]) ?? [] }
    .compactMap { $0["command"] as? String }
  #expect(commands?.contains("/other/tool run") == true)
  #expect(commands?.contains("/opt/pensieve capture-session-start") == true)
}
