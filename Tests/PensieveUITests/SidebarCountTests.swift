import XCTest

final class SidebarCountTests: XCTestCase {
  /// The counts are the feature: before loose ends could be resolved, "Als Nächstes 155" never
  /// shrank and so meant nothing. The fixture has exactly 3 open loose ends and 1 archived node.
  func testSidebarShowsFixtureCounts() throws {
    let application = try launchPensieve()
    XCTAssertTrue(application.staticTexts["Briefing"].waitForExistence(timeout: 20))

    XCTAssertTrue(application.staticTexts["3"].exists,
                  "expected the open-loose-end count of 3 from the fixture")

    // The archived node must NOT appear in the normal tree.
    XCTAssertFalse(application.staticTexts["Old Prototype"].exists,
                   "an archived node leaked into the main tree")
  }
}
