import Testing
import Foundation
@testable import PensieveKit

@Test func resolvedPATHCoversGitClaudeAndHasNoTilde() {
  let path = SyncAgentEnvironment.resolvedPATH(home: URL(fileURLWithPath: "/Users/tester"))
  #expect(!path.contains("~"))                        // launchd does not expand ~
  // Compared as PATH entries, not substrings. As a substring check the `/bin` assertion could never
  // fail while the `/usr/bin` one passed — `"/usr/bin".contains("/bin")` is true — so it asserted
  // nothing. Splitting also catches a malformed separator, which a substring search cannot see.
  let entries = path.split(separator: ":").map(String.init)
  #expect(entries.contains("/usr/bin"))                  // Git.run needs /usr/bin/env git
  #expect(entries.contains("/bin"))
  #expect(entries.contains("/Users/tester/.local/bin"))  // claude -p fallback
  #expect(entries.contains("/opt/homebrew/bin"))         // Homebrew git/claude
}
