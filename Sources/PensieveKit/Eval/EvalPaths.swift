import Foundation

public enum EvalPaths {
  public static func dir() -> URL {
    if let o = ProcessInfo.processInfo.environment["PENSIEVE_EVAL_DIR"] {
      return URL(fileURLWithPath: o)
    }
    return URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".eval")
  }
  public static func corpusDir() -> URL { dir().appendingPathComponent("corpus") }
  public static func manifestURL() -> URL { corpusDir().appendingPathComponent("manifest.json") }
  public static func scorecardURL() -> URL { dir().appendingPathComponent("scorecard.json") }
  public static func reportURL() -> URL { dir().appendingPathComponent("report.md") }
  public static func goldURL() -> URL { dir().appendingPathComponent("gold.json") }
  public static func configURL() -> URL {
    URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("eval-config.json")
  }
  public static func ensureDir(_ url: URL) throws {
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  }
}
