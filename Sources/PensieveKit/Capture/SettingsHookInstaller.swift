import Foundation

public enum SettingsHookInstallError: Error, CustomStringConvertible {
  case unparseableSettings(URL)

  public var description: String {
    switch self {
    case .unparseableSettings(let url):
      return "Refusing to modify \(url.path): existing content is not a valid JSON object. Fix or remove it, then re-run."
    }
  }
}

public enum SettingsHookInstaller {
  static let command = "capture-session-start"
  static let sessionEndCommand = "capture-session-end"

  /// Installs the `SessionStart` hook. Returns true if added, false if already present.
  @discardableResult
  public static func install(settingsURL: URL, pensievePath: String) throws -> Bool {
    try installHook(settingsURL: settingsURL, event: "SessionStart", matcher: "startup",
                    marker: command, command: "\(pensievePath) \(command)")
  }

  /// Installs the `SessionEnd` hook (matcher "" = all reasons). Returns true if added.
  @discardableResult
  public static func installSessionEnd(settingsURL: URL, pensievePath: String) throws -> Bool {
    try installHook(settingsURL: settingsURL, event: "SessionEnd", matcher: "",
                    marker: sessionEndCommand, command: "\(pensievePath) \(sessionEndCommand)")
  }

  /// Idempotent JSON merge of one Claude Code command hook into a settings.json. Preserves all
  /// existing content and never modifies foreign hook entries. Presence is detected by the
  /// subcommand `marker` substring (so a changed `pensievePath` is still recognized as ours).
  private static func installHook(settingsURL: URL, event: String, matcher: String,
                                  marker: String, command: String) throws -> Bool {
    var root: [String: Any] = [:]
    if FileManager.default.fileExists(atPath: settingsURL.path) {
      guard let data = try? Data(contentsOf: settingsURL),
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw SettingsHookInstallError.unparseableSettings(settingsURL)
      }
      root = obj
    }
    var hooks = root["hooks"] as? [String: Any] ?? [:]
    var group = hooks[event] as? [[String: Any]] ?? []

    let present = group.contains { g in
      ((g["hooks"] as? [[String: Any]]) ?? []).contains {
        ($0["command"] as? String)?.contains(marker) == true
      }
    }
    if present { return false }

    group.append([
      "matcher": matcher,
      "hooks": [["type": "command", "command": command]],
    ])
    hooks[event] = group
    root["hooks"] = hooks

    try PensievePaths.ensureParentDirectory(of: settingsURL)
    let out = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
    try out.write(to: settingsURL, options: .atomic)
    return true
  }
}
