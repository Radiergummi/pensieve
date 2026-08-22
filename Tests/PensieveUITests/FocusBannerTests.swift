import XCTest

/// The Focus filter used to scope the middle column with nothing on screen saying so — a shortened
/// list reads as "not much going on" rather than "you are seeing half of it". These two tests are
/// the pair that matters: the banner appears when a context is active, and does NOT appear when one
/// is not. Either alone would pass against a banner that is always visible, or never.
@MainActor
final class FocusBannerTests: XCTestCase {
  /// German, because the banner is chrome and must be localized — and because the context name beside
  /// it is user data that must survive verbatim. One launch proves both halves of that rule at once.
  func testBannerNamesTheActiveContextInGermanChrome() throws {
    let application = try launchPensieve(locale: "de", focusContext: "work")
    XCTAssertTrue(application.staticTexts["Briefing"].waitForExistence(timeout: 20))

    XCTAssertTrue(application.staticTexts["Nach Fokus gefiltert · work"].exists,
                  "no Focus banner while a context is active — the filter is scoping the column silently")
  }

  /// The absence half. Runs in English so a missing German catalog entry could never be what makes
  /// this pass, and asserts the list still rendered so "banner absent" cannot be satisfied by an app
  /// that failed to launch.
  func testNoBannerWithoutAnActiveContext() throws {
    let application = try launchPensieve(locale: "en")
    XCTAssertTrue(application.staticTexts["Briefing"].waitForExistence(timeout: 20))

    // Predicated on `value`, NOT `label` or `identifier`: a SwiftUI `Text` on macOS carries its
    // string in AXValue and leaves both of the others EMPTY. The `staticTexts["…"]` subscript the
    // rest of this suite uses happens to match against value, which is why it works — but a
    // `label`-predicated query matches nothing at all, and an absence assertion built on one is
    // vacuous. This one was, and stayed green through the mutation run that caught it.
    let banners = application.staticTexts.matching(
      NSPredicate(format: "value BEGINSWITH %@", "Filtered by Focus"))
    XCTAssertEqual(banners.count, 0, "Focus banner rendered with no Focus context active")
  }
}
