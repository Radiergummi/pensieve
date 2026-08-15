import XCTest
import PensieveKit

/// Launches a fresh Pensieve against a seeded throwaway store.
///
/// Every read of UserDefaults is pinned through the argument domain, which outranks every other
/// defaults domain (including @AppStorage). Without this the app inherits the developer's live Focus
/// context and silently filters the fixture. Writes are contained by `make uitest`, which exports and
/// restores the real domain around the suite.
func launchPensieve(seededAt now: Date = Date(), locale: String? = nil) throws -> XCUIApplication {
  let directory = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("pensieve-uitest-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

  let canonical = directory.appendingPathComponent("pensieve.sqlite")
  try UITestFixture.seed(canonicalAt: canonical, now: now)

  let application = XCUIApplication()
  application.launchEnvironment["PENSIEVE_DB"] = canonical.path
  application.launchEnvironment["PENSIEVE_CAPTURE_DB"] =
    directory.appendingPathComponent("capture.sqlite").path

  // Keys copied verbatim from AppDefaults.swift and PensieveFocusFilter.swift. The plan spelled two
  // of the three wrongly (`-focusFilterActiveContext`, `-hideDockIcon`) — and a mis-spelled
  // argument-domain key fails SILENTLY, leaving the app on the developer's real value, so these
  // must be checked against the source rather than retyped from memory.
  application.launchArguments += [
    "-pensieve.activeFocusContext", "",   // no Focus filtering, whatever the developer's Mac is doing
    "-app.narrationEnabled", "NO",        // narration is an LLM call; never in a test
    "-app.hideDockIcon", "NO",
  ]
  if let locale {
    application.launchArguments += ["-AppleLanguages", "(\(locale))"]
  }

  application.launch()
  return application
}
