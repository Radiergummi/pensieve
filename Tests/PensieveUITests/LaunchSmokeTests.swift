import XCTest

@MainActor
final class LaunchSmokeTests: XCTestCase {
  /// The check the old CLAUDE.md recipe only appeared to make: that app code actually runs.
  /// AppModel.start() runs from a .task on a rendered view body, so asserting on rendered content
  /// is the only way to know the app booted rather than merely launched.
  func testWindowRendersSeededContent() throws {
    let application = try launchPensieve()

    let window = application.windows.firstMatch
    XCTAssertTrue(window.waitForExistence(timeout: 30), "no window appeared")

    XCTAssertTrue(application.staticTexts["Briefing"].waitForExistence(timeout: 15),
                  "sidebar never rendered — the app launched but no view body ran")

    // Proof the fixture reached the UI, not just that chrome drew. Scoped to the sidebar/content
    // column's `.cells` (a SwiftUI `List`) rather than a bare lookup: `BriefingView` renders a plain
    // `Text(briefingCard.node.name)` for Colibri outside any List, in both its card and quiet rows,
    // so an unscoped query can match more than one element at once.
    XCTAssertTrue(application.cells.staticTexts["Colibri"].waitForExistence(timeout: 15),
                  "fixture node 'Colibri' is missing from the tree")

    let screenshot = XCTAttachment(screenshot: window.screenshot())
    screenshot.name = "launch-seeded"
    screenshot.lifetime = .keepAlways
    add(screenshot)
  }
}
