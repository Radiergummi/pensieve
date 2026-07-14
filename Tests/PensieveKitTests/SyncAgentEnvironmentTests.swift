import Testing
import Foundation
@testable import PensieveKit

@Test func resolvedPATHCoversGitClaudeAndHasNoTilde() {
  let path = SyncAgentEnvironment.resolvedPATH(home: URL(fileURLWithPath: "/Users/tester"))
  #expect(!path.contains("~"))                        // launchd does not expand ~
  #expect(path.contains("/usr/bin"))                  // Git.run needs /usr/bin/env git
  #expect(path.contains("/bin"))
  #expect(path.contains("/Users/tester/.local/bin"))  // claude -p fallback
  #expect(path.contains("/opt/homebrew/bin"))         // Homebrew git/claude
}
