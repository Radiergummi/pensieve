// Tests/PensieveKitTests/BackgroundSyncPlistTests.swift
import Testing
import Foundation
@testable import PensieveKit

@Test func committedAgentPlistIsHomeIndependentAndComplete() throws {
  // Navigate from this test file up to the repo root: Tests/PensieveKitTests/<file> → repo root.
  let repoRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
  let plistURL = repoRoot.appendingPathComponent("SyncAgent/me.mazetti.pensieve.sync.plist")
  let obj = try PropertyListSerialization.propertyList(
    from: Data(contentsOf: plistURL), format: nil) as! [String: Any]

  #expect(obj["Label"] as? String == "me.mazetti.pensieve.sync")
  #expect(obj["BundleProgram"] as? String == "Contents/Library/Helpers/PensieveSyncAgent")
  // Asserted against the Swift constant, not a repeated literal: the plist cannot reference Swift,
  // so this test IS the mechanism keeping the two in agreement. Everything derived from the period
  // (the widget's staleness threshold, the agent's watchdog) reads `BackgroundSyncSchedule`, so a
  // schedule change that forgot the plist — or a plist change that forgot the code — fails here
  // instead of silently making the widget call a fresh digest stale.
  #expect(obj["StartInterval"] as? Int == Int(BackgroundSyncSchedule.interval))
  #expect(obj["ProcessType"] as? String == "Background")
  #expect(obj["RunAtLoad"] as? Bool == true)

  // C1/C2 regression guard: env + logging are the helper's runtime job, NOT the static plist
  // (launchd does no ~ expansion, so a committed file cannot carry a home-relative PATH/log path).
  #expect(obj["EnvironmentVariables"] == nil)
  #expect(obj["StandardOutPath"] == nil)
  #expect(obj["StandardErrorPath"] == nil)
}
