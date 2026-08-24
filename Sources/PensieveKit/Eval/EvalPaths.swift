import Foundation

public enum EvalPaths {
  public static func directory() -> URL {
    if let envPath = ProcessInfo.processInfo.environment["PENSIEVE_EVAL_DIR"] {
      return URL(fileURLWithPath: envPath)
    }
    return URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".eval")
  }
  public static func corpusDirectory() -> URL { directory().appendingPathComponent("corpus") }
  public static func manifestURL() -> URL { corpusDirectory().appendingPathComponent("manifest.json") }
  public static func scorecardURL() -> URL { directory().appendingPathComponent("scorecard.json") }
  public static func reportURL() -> URL { directory().appendingPathComponent("report.md") }
  public static func goldURL() -> URL { directory().appendingPathComponent("gold.json") }
  public static func configURL() -> URL {
    URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("eval-config.json")
  }
  public static func ensureDirectory(_ url: URL) throws {
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  }
}
