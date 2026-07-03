import Foundation

public enum PensievePaths {
  public static func supportDirectory() -> URL {
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    return base.appendingPathComponent("Pensieve", isDirectory: true)
  }
  public static func canonicalURL() -> URL {
    supportDirectory().appendingPathComponent("pensieve.sqlite")
  }
  public static func captureURL() -> URL {
    supportDirectory().appendingPathComponent("capture.sqlite")
  }
}
