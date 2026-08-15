import XCTest

final class LocalizationTests: XCTestCase {
  /// German chrome, English content. This also proves the argument domain reaches the app: if
  /// -AppleLanguages were ignored the app would render English and this would fail loudly.
  func testGermanChromeWithEnglishContent() throws {
    let application = try launchPensieve(locale: "de")
    XCTAssertTrue(application.staticTexts["Briefing"].waitForExistence(timeout: 20))

    // Chrome is localized.
    XCTAssertTrue(application.staticTexts["Als Nächstes"].exists,
                  "sidebar chrome did not render in German")
    XCTAssertTrue(application.staticTexts["Lose Enden"].exists)

    // Content is never localized — node names come from the canonical store verbatim.
    XCTAssertTrue(application.staticTexts["Colibri"].exists,
                  "a node name was localized; content must stay verbatim")
  }
}
