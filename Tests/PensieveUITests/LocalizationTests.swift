import XCTest

@MainActor
final class LocalizationTests: XCTestCase {
  /// English chrome, verbatim content, on a machine whose own `AppleLanguages` default is German
  /// (`("de-DE", "en-DE")` — confirmed with `defaults read -g AppleLanguages`). This is the actual
  /// proof the argument domain reaches the app: English chrome here can only come from the explicit
  /// `-AppleLanguages (en)` override, since the ambient default would render German on its own. The
  /// German test below cannot carry that proof on this machine — its target locale and the ambient
  /// default are the same, so it would pass identically whether or not the override took effect.
  func testEnglishChromeOverridesGermanDefault() throws {
    let application = try launchPensieve(locale: "en")
    XCTAssertTrue(application.staticTexts["Briefing"].waitForExistence(timeout: 20))

    // Chrome is localized — and specifically English, not this host's German default.
    XCTAssertTrue(application.staticTexts["Loose Ends"].exists,
                  "sidebar chrome did not render in English — the argument domain may not be reaching the app")
    XCTAssertTrue(application.staticTexts["What's Next"].exists)

    // Content is never localized — node names come from the canonical store verbatim. Scoped to
    // `.cells` (a SwiftUI `List`) rather than a bare lookup: `BriefingView` renders a plain
    // `Text(briefingCard.node.name)` for Colibri outside any List, so an unscoped query can match
    // more than one element at once.
    XCTAssertTrue(application.cells.staticTexts["Colibri"].exists,
                  "a node name was localized; content must stay verbatim")
  }

  /// German chrome, English content. This proves the German half of the catalog renders correctly
  /// and that content stays verbatim under it — it does NOT prove `-AppleLanguages` reaches the app
  /// on this machine: this host's own locale default is German, so a `-AppleLanguages (de)` launch
  /// renders German whether or not the argument domain was honoured.
  /// `testEnglishChromeOverridesGermanDefault` above carries that proof instead, by requesting the
  /// locale this host would NOT default to.
  func testGermanChromeWithEnglishContent() throws {
    let application = try launchPensieve(locale: "de")
    XCTAssertTrue(application.staticTexts["Briefing"].waitForExistence(timeout: 20))

    // Chrome is localized.
    XCTAssertTrue(application.staticTexts["Als Nächstes"].exists,
                  "sidebar chrome did not render in German")
    XCTAssertTrue(application.staticTexts["Lose Enden"].exists)

    // Content is never localized — see the note on the English test for why this is scoped.
    XCTAssertTrue(application.cells.staticTexts["Colibri"].exists,
                  "a node name was localized; content must stay verbatim")
  }
}
