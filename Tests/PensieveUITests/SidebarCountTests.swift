import XCTest

@MainActor
final class SidebarCountTests: XCTestCase {
  /// The counts are the feature: before loose ends could be resolved, "Als Nächstes 155" never
  /// shrank and so meant nothing. The fixture has exactly 3 open loose ends across nodes.
  ///
  /// A bare `staticTexts["3"]` (this test's original form) is ambiguous here: the Smart Lists
  /// section renders `Text("\(count)")` unconditionally for What's Next, and in this fixture that
  /// count is also 3 — so the old assertion passed with the Loose Ends count feature entirely
  /// broken. This scopes to the sidebar cell that actually contains "Loose Ends" instead of
  /// asserting a bare digit exists somewhere in the window.
  func testLooseEndsCountMatchesFixture() throws {
    let application = try launchPensieve(locale: "en")
    XCTAssertTrue(application.staticTexts["Briefing"].waitForExistence(timeout: 20))

    let looseEndsRow = application.cells.containing(.staticText, identifier: "Loose Ends").firstMatch
    XCTAssertTrue(looseEndsRow.waitForExistence(timeout: 15), "the Loose Ends sidebar row never rendered")
    XCTAssertTrue(looseEndsRow.staticTexts["3"].exists,
                  "expected the open-loose-end count of 3 next to Loose Ends specifically")
  }

  /// Two things at once, both needing both sections actually expanded to mean anything:
  ///
  /// (1) The archived node must not leak into the Projects tree. A bare `XCTAssertFalse(exists)` —
  /// what this test used to do — is vacuous whenever Archived starts collapsed, and worse than
  /// vacuous on a host where Archived starts EXPANDED (`sidebar.archived.expanded` defaults to
  /// false, but the domain persists across runs): "Old Prototype" then already exists, from
  /// Archived, before the Projects check even runs, and a bare unscoped existence check reports a
  /// false leak. Since this sidebar `List` renders Projects and all its rows strictly before the
  /// "Archived" heading row, an archived node actually leaking into Projects would render ABOVE
  /// that heading; one genuinely under Archived renders below it. So this reveals Archived too and
  /// checks `frame.minY` against the heading — correct regardless of either section's start state.
  ///
  /// (2) The one personal-context node must be reachable once expanded — asserting Focus filtering
  /// does not silently mute it. That only proves the launch argument domain
  /// (`-pensieve.activeFocusContext ""`) neutralised an ACTIVE Focus when this suite happens to run
  /// on a host with one running: with no Focus active at all, the node would be reachable whether or
  /// not the override took effect, so this assertion alone cannot tell the two apart. The argument
  /// domain genuinely reaching the app is proven independently, on every host, by
  /// `LocalizationTests.testEnglishChromeOverridesGermanDefault` — English chrome there only renders
  /// because its own `-AppleLanguages (en)` override took effect on a host whose default is German.
  func testArchivedSeparateFromProjectsPersonalReachable() throws {
    let application = try launchPensieve(locale: "en")
    XCTAssertTrue(application.staticTexts["Briefing"].waitForExistence(timeout: 20))

    let sourdoughLog = application.staticTexts["Sourdough Log"]
    revealSidebarSection(named: "Projects", showing: sourdoughLog, in: application)
    XCTAssertTrue(sourdoughLog.waitForExistence(timeout: 15),
                  "the personal-context node never became reachable — Focus neutralisation may have failed")

    let oldPrototype = application.staticTexts["Old Prototype"]
    revealSidebarSection(named: "Archived", showing: oldPrototype, in: application)
    XCTAssertTrue(oldPrototype.waitForExistence(timeout: 15),
                  "the archived node was not reachable under Archived")

    let archivedHeading = application.descendants(matching: .any)["Archived"]
    XCTAssertTrue(archivedHeading.waitForExistence(timeout: 15))
    XCTAssertGreaterThan(oldPrototype.frame.minY, archivedHeading.frame.minY,
                         "the archived node rendered above the Archived heading — it leaked into Projects")
  }

  /// Makes `target` reachable by expanding the named sidebar section, **without assuming which state
  /// it starts in**.
  ///
  /// This is state-derived, not a blind toggle: it checks whether `target` is already visible before
  /// doing anything, and only clicks if it is not. That matters because `SidebarView` declares
  /// `projectsExpanded`/`archivedExpanded` with real `@AppStorage` defaults (`true`/`false`), but
  /// `make uitest` only exports and restores the shared `me.mazetti.pensieve` domain **around** the
  /// whole run — it does not reset it — so whatever a previous run (or the developer's own use of
  /// the real app) last persisted for those keys is what a fresh launch sees. A blind toggle is
  /// correct only by coincidence with whatever this machine happens to have stored; a state-derived
  /// check is correct regardless. Calling this twice in a row is idempotent: the second call finds
  /// `target` already visible and does nothing.
  ///
  /// Confirmed empirically: macOS exposes each section's disclosure only as a hover-revealed AppKit
  /// control (`AXDisclosureTriangle`, identifier `NSOutlineViewShowHideButtonKey`) — a plain
  /// `.click()` on the header text alone does not toggle it, so this hovers first to reveal the
  /// control, then clicks it. The `heading.click()` fallback (for a hypothetical future macOS that
  /// renders the disclosure without a hover) has never actually been exercised — this machine always
  /// takes the hover-then-click path — so it is unverified defensive code, not a tested branch.
  private func revealSidebarSection(named title: String, showing target: XCUIElement, in application: XCUIApplication) {
    if target.waitForExistence(timeout: 2) { return }   // already expanded — nothing to do

    let heading = application.descendants(matching: .any)[title]
    XCTAssertTrue(heading.waitForExistence(timeout: 15), "\(title) heading never appeared")
    heading.hover()
    let toggle = application.descendants(matching: .any)
      .matching(identifier: "NSOutlineViewShowHideButtonKey").firstMatch
    if toggle.waitForExistence(timeout: 3) {
      toggle.click()
    } else {
      heading.click()   // unverified fallback — see doc comment above
    }
  }
}
