// Tests/PensieveKitTests/BackgroundSyncPlistTests.swift
import Testing
import Foundation

@Test func committedAgentPlistIsHomeIndependentAndComplete() throws {
  // Navigate from this test file up to the repo root: Tests/PensieveKitTests/<file> → repo root.
  let repoRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
  let plistURL = repoRoot.appendingPathComponent("SyncAgent/me.mazetti.pensieve.sync.plist")
  let obj = try PropertyListSerialization.propertyList(
    from: Data(contentsOf: plistURL), format: nil) as! [String: Any]

  #expect(obj["Label"] as? String == "me.mazetti.pensieve.sync")
  #expect(obj["BundleProgram"] as? String == "Contents/Library/Helpers/PensieveSyncAgent")
  #expect(obj["StartInterval"] as? Int == 300)
  #expect(obj["ProcessType"] as? String == "Background")
  #expect(obj["RunAtLoad"] as? Bool == true)

  // C1/C2 regression guard: env + logging are the helper's runtime job, NOT the static plist
  // (launchd does no ~ expansion, so a committed file cannot carry a home-relative PATH/log path).
  #expect(obj["EnvironmentVariables"] == nil)
  #expect(obj["StandardOutPath"] == nil)
  #expect(obj["StandardErrorPath"] == nil)
}
