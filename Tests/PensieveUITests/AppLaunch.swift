import XCTest
import PensieveKit

/// `@MainActor` here and on every test class in this target: under Swift 6, `XCUIApplication` and
/// `XCUIElement` are main-actor-isolated, so each `.exists`/`.click()`/`.frame` from a nonisolated
/// context is a concurrency warning. The target emitted 62 of them before this annotation. Isolating
/// to the main actor is what XCUITest already requires at runtime, so this is the true declaration,
/// not a warning silencer.
@MainActor
extension XCTestCase {
  /// Launches a fresh Pensieve against a seeded throwaway store.
  ///
  /// Every read of UserDefaults is pinned through the argument domain, which outranks every other
  /// defaults domain (including @AppStorage). Without this the app inherits the developer's live Focus
  /// context and silently filters the fixture. Writes are contained by `make uitest`, which exports and
  /// restores the real domain around the suite.
  ///
  /// An `XCTestCase` extension method rather than a free function so it can register its own teardown:
  /// each call makes a fresh temp directory that nothing else ever removes, and every test in this
  /// suite calls it at least once.
  func launchPensieve(seededAt now: Date = Date(), locale: String? = nil,
                      focusContext: String = "") throws -> XCUIApplication {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("pensieve-uitest-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    // Best-effort: a crash mid-test must not itself fail the test over a leftover temp directory.
    addTeardownBlock { try? FileManager.default.removeItem(at: directory) }

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
      // Defaults to "" — no Focus filtering, whatever the developer's Mac is doing. A test that passes
      // a context is asking for the filter to be ACTIVE, which is what FocusBannerTests renders.
      "-pensieve.activeFocusContext", focusContext,
      "-app.narrationEnabled", "NO",        // narration is an LLM call; never in a test
      "-app.hideDockIcon", "NO",
      // `AppModel.init` reads this as `UserDefaults.standard.object(forKey:) as? Date`. Confirmed
      // empirically (a standalone process spawned with argv identical to how XCUIApplication launches
      // its target): the argument domain always stores its values as NSString — even a numeric-looking
      // string comes back as NSString, never NSDate/NSNumber — so the cast fails regardless of what is
      // passed here, and AppModel falls through to its own hardcoded `now - 7 days` fallback.
      //
      // That fallback IS the pin: the argument domain outranks the app's own persisted domain (the same
      // `me.mazetti.pensieve` domain a real launch on this machine writes to), so `briefingSince`
      // deterministically lands ~7 days before launch regardless of whatever real `lastOpenedAt` this
      // host has stored. The fixture's newest event is `now - 2h`, comfortably inside that window, so
      // Colibri's card always lands in Briefing's "Moved" section and never in the "Quiet" group —
      // which is what makes "Colibri" render predictably on every host.
      //
      // The value below is inert by construction (see above); pinning comes from the KEY being present.
      // Written as an ISO 8601 timestamp 3 days before the fixture's `now` anyway, so that if a future
      // AppModel ever learns to parse this domain's value as a real date, the reading would still land
      // inside the intended window rather than silently drifting back onto ambient state.
      "-pensieve.lastOpenedAt", ISO8601DateFormatter().string(from: now.addingTimeInterval(-3 * 86_400)),
    ]
    if let locale {
      application.launchArguments += ["-AppleLanguages", "(\(locale))"]
    }

    application.launch()
    return application
  }
}
