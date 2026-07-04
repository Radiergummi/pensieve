import Foundation

/// Idempotent JSON merge of the Claude Code `SessionStart` hook into a settings.json.
/// Preserves all existing content and never modifies foreign hook entries.
public enum SettingsHookInstaller {
  static let command = "capture-session-start"

  /// Returns true if an entry was added, false if ours was already present.
  @discardableResult
  public static func install(settingsURL: URL, pensievePath: String) throws -> Bool {
    var root: [String: Any] = [:]
    if let data = try? Data(contentsOf: settingsURL),
       let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
      root = obj
    }
    var hooks = root["hooks"] as? [String: Any] ?? [:]
    var sessionStart = hooks["SessionStart"] as? [[String: Any]] ?? []

    let present = sessionStart.contains { group in
      ((group["hooks"] as? [[String: Any]]) ?? []).contains {
        ($0["command"] as? String)?.contains(command) == true
      }
    }
    if present { return false }

    sessionStart.append([
      "matcher": "startup",
      "hooks": [["type": "command", "command": "\(pensievePath) \(command)"]],
    ])
    hooks["SessionStart"] = sessionStart
    root["hooks"] = hooks

    try PensievePaths.ensureParentDirectory(of: settingsURL)
    let out = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
    try out.write(to: settingsURL, options: .atomic)
    return true
  }
}
