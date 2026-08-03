import Testing
import Foundation
@testable import PensieveKit

private func tmpSettings() -> URL {
  FileManager.default.temporaryDirectory
    .appendingPathComponent("settings-\(UUID().uuidString).json")
}

@Test func installsSessionEndWithEmptyMatcherIdempotentlyPreservingOthers() throws {
  let url = tmpSettings()
  // Pre-existing SessionStart (ours) + a foreign hook must survive.
  try SettingsHookInstaller.install(settingsURL: url, pensievePath: "/bin/pensieve")
  let seeded = try Data(contentsOf: url)
  var root = try JSONSerialization.jsonObject(with: seeded) as! [String: Any]
  var seededHooks = root["hooks"] as! [String: Any]
  seededHooks["Stop"] = [["matcher": "x", "hooks": [["type": "command", "command": "/other tool"]]]]
  root["hooks"] = seededHooks
  try JSONSerialization.data(withJSONObject: root).write(to: url)

  let first = try SettingsHookInstaller.installSessionEnd(settingsURL: url, pensievePath: "/bin/pensieve")
  let second = try SettingsHookInstaller.installSessionEnd(settingsURL: url, pensievePath: "/bin/pensieve")
  #expect(first == true)     // added
  #expect(second == false)   // idempotent

  let obj = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
  let hooks = obj["hooks"] as! [String: Any]
  let sessionEnd = hooks["SessionEnd"] as! [[String: Any]]
  #expect(sessionEnd.count == 1)
  #expect(sessionEnd[0]["matcher"] as? String == "")
  let cmd = ((sessionEnd[0]["hooks"] as! [[String: Any]])[0]["command"] as! String)
  #expect(cmd.contains("capture-session-end"))
  #expect(hooks["SessionStart"] != nil)   // preserved
  #expect(hooks["Stop"] != nil)           // foreign preserved
}
