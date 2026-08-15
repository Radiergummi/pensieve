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
  let supportURL = PensievePaths.supportDirectory()

  // No override: byte-identical to the historical path, so no existing index is orphaned.
  #expect(PensievePaths.indexURL(named: "search-index.sqlite", storeOverride: nil, support: supportURL).path
          == support + "/search-index.sqlite")
  #expect(PensievePaths.indexURL(named: "semantic-index.sqlite", storeOverride: nil, support: supportURL).path
          == support + "/semantic-index.sqlite")
  #expect(PensievePaths.indexURL(named: "translation-cache.sqlite", storeOverride: nil, support: supportURL).path
          == support + "/translation-cache.sqlite")

  // Overridden: a sibling of the throwaway store, never the shared directory.
  #expect(PensievePaths.indexURL(named: "search-index.sqlite",
                                 storeOverride: "/tmp/throwaway.sqlite", support: supportURL).path
          == "/tmp/throwaway-search-index.sqlite")
  #expect(PensievePaths.indexURL(named: "translation-cache.sqlite",
                                 storeOverride: "/tmp/throwaway.sqlite", support: supportURL).path
          == "/tmp/throwaway-translation-cache.sqlite")

  // Two throwaway stores in one directory do not share an index.
  #expect(PensievePaths.indexURL(named: "search-index.sqlite", storeOverride: "/tmp/a.sqlite", support: supportURL)
          != PensievePaths.indexURL(named: "search-index.sqlite", storeOverride: "/tmp/b.sqlite", support: supportURL))
}

/// Precedence is env > defaults > default, and it is a PURE function over injected values.
/// `setenv` is process-global and Swift Testing runs suites in parallel, so the rule is never
/// tested by mutating the real environment — the same reason `indexURL(named:storeOverride:)`
/// was split out at `PensievePaths.swift:44-46`.
@Test func supportDirectoryPrecedenceIsPure() {
  let fallback = PensievePaths.defaultSupportDirectory().path

  // No override: byte-identical to the historical path, so no existing install is orphaned.
  #expect(PensievePaths.supportDirectory(customRoot: nil).path == fallback)

  // A custom root wins over the default.
  #expect(PensievePaths.supportDirectory(customRoot: "/Volumes/Work/Pensieve").path
          == "/Volumes/Work/Pensieve")

  // An empty or whitespace-only stored value is treated as absent, never as "/".
  #expect(PensievePaths.supportDirectory(customRoot: "").path == fallback)
  #expect(PensievePaths.supportDirectory(customRoot: "   ").path == fallback)

  // A relative path is refused — a relative support root would resolve against whatever cwd
  // launchd handed the process (`/`), which is how you get a store at the filesystem root.
  #expect(PensievePaths.supportDirectory(customRoot: "relative/dir").path == fallback)
}

/// Everything derived must follow the custom root, or the install ends up half-relocated —
/// the state the one-root design exists to make unrepresentable.
@Test func derivedPathsFollowTheCustomRoot() {
  let root = "/Volumes/Work/Pensieve"
  let support = PensievePaths.supportDirectory(customRoot: root)

  #expect(PensievePaths.canonicalURL(in: support).path == root + "/pensieve.sqlite")
  #expect(PensievePaths.captureURL(in: support).path == root + "/capture.sqlite")
  #expect(PensievePaths.narrationCacheURL(in: support).path == root + "/narration-cache.sqlite")

  // The disposable indexes follow the root too. This is the regression this feature is most
  // likely to reintroduce: an index left behind in the OLD directory is a silent, total
  // retrieval outage (see PensievePaths.swift:30-35).
  #expect(PensievePaths.indexURL(named: "search-index.sqlite", storeOverride: nil, support: support).path
          == root + "/search-index.sqlite")
  #expect(PensievePaths.indexURL(named: "translation-cache.sqlite", storeOverride: nil, support: support).path
          == root + "/translation-cache.sqlite")

  // PENSIEVE_DB still wins over the custom root, and still keeps its per-store prefix rule,
  // so `make smoke` and every test recipe behave exactly as before.
  #expect(PensievePaths.indexURL(named: "search-index.sqlite",
                                 storeOverride: "/tmp/throwaway.sqlite", support: support).path
          == "/tmp/throwaway-search-index.sqlite")
}
