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

/// A disposable index belongs to the store it was built FROM, so it has to follow `PENSIEVE_DB`
/// wherever `openCanonical()` does. Before this, `PENSIEVE_DB=/tmp/x pensieve sync` — and the
/// project's own app-smoke recipe — rebuilt the index in the shared support directory against a
/// throwaway store, wiping the developer's live one.
@Test func indexPathFollowsAnOverriddenStore() {
  let support = PensievePaths.supportDirectory().path

  // No override: byte-identical to the historical path, so no existing index is orphaned.
  #expect(PensievePaths.indexURL(named: "search-index.sqlite", storeOverride: nil).path
          == support + "/search-index.sqlite")
  #expect(PensievePaths.indexURL(named: "semantic-index.sqlite", storeOverride: nil).path
          == support + "/semantic-index.sqlite")
  #expect(PensievePaths.indexURL(named: "translation-cache.sqlite", storeOverride: nil).path
          == support + "/translation-cache.sqlite")

  // Overridden: a sibling of the throwaway store, never the shared directory.
  #expect(PensievePaths.indexURL(named: "search-index.sqlite",
                                 storeOverride: "/tmp/throwaway.sqlite").path
          == "/tmp/throwaway-search-index.sqlite")
  #expect(PensievePaths.indexURL(named: "translation-cache.sqlite",
                                 storeOverride: "/tmp/throwaway.sqlite").path
          == "/tmp/throwaway-translation-cache.sqlite")

  // Two throwaway stores in one directory do not share an index.
  #expect(PensievePaths.indexURL(named: "search-index.sqlite", storeOverride: "/tmp/a.sqlite")
          != PensievePaths.indexURL(named: "search-index.sqlite", storeOverride: "/tmp/b.sqlite"))
}
