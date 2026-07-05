import Testing
import Foundation
@testable import PensieveKit

@Test func stablePathIsLocalBinAndBuildPathsAreRefused() throws {
  let home = URL(fileURLWithPath: "/Users/tester")
  #expect(DaemonInstaller.stablePensievePath(home: home) == "/Users/tester/.local/bin/pensieve")

  // A .build path must be refused.
  var threw = false
  do { try DaemonInstaller.ensureStable(runningExecutable: "/repo/.build/debug/pensieve") }
  catch { threw = true }
  #expect(threw)

  // A normal installed path is accepted.
  try DaemonInstaller.ensureStable(runningExecutable: "/Users/tester/.local/bin/pensieve")
}

@Test func writePlistCreatesLogDirAndStablePlist() throws {
  let home = FileManager.default.temporaryDirectory
    .appendingPathComponent("home-\(UUID().uuidString)", isDirectory: true)
  let plistURL = home.appendingPathComponent("Library/LaunchAgents/com.pensieve.sync.plist")
  try DaemonInstaller.writePlist(home: home, runningExecutable: home.appendingPathComponent(".local/bin/pensieve").path, plistURL: plistURL)

  #expect(FileManager.default.fileExists(atPath: home.appendingPathComponent("Library/Logs/Pensieve").path))
  let obj = try PropertyListSerialization.propertyList(
    from: Data(contentsOf: plistURL), format: nil) as! [String: Any]
  #expect((obj["ProgramArguments"] as? [String])?.first == home.appendingPathComponent(".local/bin/pensieve").path)
}
