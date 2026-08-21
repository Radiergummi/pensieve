import XCTest
import PensieveKit

@MainActor
final class DetailOrderTests: XCTestCase {
  /// Loose ends render above Recent Activity.
  ///
  /// **What this does and does not cover.** The motivating defect was slice A moving the recap
  /// *below* the loose ends while the parallel in-node-find branch still emitted the narration slot
  /// first. That exact ordering is **not** covered here and cannot be: the recap only exists when
  /// narration has run, and narration is an LLM call the suite disables (`-app.narrationEnabled NO`).
  /// So this pins the neighbouring, always-present boundary instead.
  ///
  /// The plan's version asserted against a locator matching "Hummingbird ingest pipeline" — the
  /// node's *description*, which `DetailView` renders in the header at `:46`, above the loose ends
  /// at `:52`. It would have failed against correct code while appearing to test ordering.
  ///
  /// Locale is forced so the section header is a known string rather than whatever language the
  /// developer's Mac happens to be in.
  func testLooseEndsRenderAboveRecentActivity() throws {
    let application = try launchPensieve(locale: "en")

    // Scoped to `.cells` (a SwiftUI `List`, the same convention `SidebarCountTests` uses for sidebar
    // rows) rather than a bare `staticTexts["Colibri"]` or `.firstMatch`: `BriefingView` renders a
    // plain `Text(briefingCard.node.name)` for Colibri outside any List, in both its card and quiet
    // rows, so an unscoped lookup can match more than one element at once. Every candidate navigates
    // to the same node, so scoping to one is correct, not just convenient.
    let colibri = application.cells.staticTexts["Colibri"]
    XCTAssertTrue(colibri.waitForExistence(timeout: 20), "fixture tree never rendered")
    colibri.click()

    // A loose end is an AXButton carrying its text as the accessibility DESCRIPTION — it is a
    // disclosure control, not a label. `staticTexts[...]` never matches it.
    let looseEnd = application.buttons[UITestFixture.colibriOpenLooseEndText]
    XCTAssertTrue(looseEnd.waitForExistence(timeout: 15), "the open loose end never rendered")

    let recentActivity = application.staticTexts.matching(
      NSPredicate(format: "value CONTAINS[c] %@", "recent activity")
    ).firstMatch
    XCTAssertTrue(recentActivity.waitForExistence(timeout: 15), "the Recent Activity section is missing")

    XCTAssertLessThan(looseEnd.frame.minY, recentActivity.frame.minY,
                      "loose ends must render above Recent Activity")
  }

  /// The cited quote is rendered verbatim: it is the trust gate's visible output.
  ///
  /// The row must be EXPANDED first — provenance is collapsed by default, so the plan's version
  /// asserted on a string that is not in the tree at all until the disclosure is opened.
  ///
  /// The fixture has no transcript file on disk, so this exercises `ProvenanceContext`'s honest
  /// degrade path: the stored quote is shown rather than a transcript window. That the stored quote
  /// still renders byte-for-byte is exactly the guarantee worth pinning.
  func testCitedQuoteRendersVerbatim() throws {
    let application = try launchPensieve(locale: "en")

    // See the doc comment on the other test's `colibri` lookup for why this is scoped to `.cells`.
    let colibri = application.cells.staticTexts["Colibri"]
    XCTAssertTrue(colibri.waitForExistence(timeout: 20))
    colibri.click()

    let looseEnd = application.buttons[UITestFixture.colibriOpenLooseEndText]
    XCTAssertTrue(looseEnd.waitForExistence(timeout: 15))
    looseEnd.click()

    let quoted = application.staticTexts[UITestFixture.colibriOpenLooseEndQuote]
    XCTAssertTrue(quoted.waitForExistence(timeout: 15),
                  "the cited quote is missing or was altered — provenance must render verbatim")
  }
}
