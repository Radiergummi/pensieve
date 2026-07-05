import Testing
import Foundation
@testable import PensieveKit

@Test func pathHelpersAreHomeRootedAndCorrectlySuffixed() {
  let home = PensievePaths.homeDirectory().path
  #expect(!home.isEmpty)
  #expect(PensievePaths.claudeProjectsURL().path == home + "/.claude/projects")
  #expect(PensievePaths.logsDirectory().path == home + "/Library/Logs/Pensieve")
  #expect(PensievePaths.syncLogURL().path == home + "/Library/Logs/Pensieve/sync.log")
  #expect(PensievePaths.launchAgentURL().path == home + "/Library/LaunchAgents/com.pensieve.sync.plist")
  #expect(PensievePaths.installedBinaryURL().path == home + "/.local/bin/pensieve")
}
