import Foundation

/// Pure writer for the `com.pensieve.sync` LaunchAgent plist. All paths are ABSOLUTE — launchd
/// performs no `~`/shell expansion of plist values.
public enum LaunchAgentPlist {
  public static let label = "com.pensieve.sync"

  public static func dictionary(pensievePath: String, home: URL, interval: Int = 300) -> [String: Any] {
    let logPath = home.appendingPathComponent("Library/Logs/Pensieve/sync.log").path
    // launchd REPLACES the job PATH (no login-PATH inheritance): /usr/bin+/bin are mandatory for
    // Git.run's `/usr/bin/env git`; ~/.local/bin (expanded) + /opt/homebrew/bin resolve `claude`
    // for the extraction fallback.
    let path = "\(home.path)/.local/bin:/opt/homebrew/bin:/usr/bin:/bin"
    return [
      "Label": label,
      "ProgramArguments": [pensievePath, "sync"],
      "StartInterval": interval,
      "RunAtLoad": true,
      "ProcessType": "Background",
      "StandardOutPath": logPath,
      "StandardErrorPath": logPath,
      "EnvironmentVariables": ["PATH": path],
    ]
  }

  public static func data(pensievePath: String, home: URL, interval: Int = 300) throws -> Data {
    try PropertyListSerialization.data(
      fromPropertyList: dictionary(pensievePath: pensievePath, home: home, interval: interval),
      format: .xml, options: 0)
  }
}
