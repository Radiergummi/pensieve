import Foundation
import Testing
import SQLiteData
@testable import PensieveKit

// MARK: sanitize

@Test func sanitizeTrimsAndKeepsProse() {
  #expect(NodeDescriber.sanitize("  A tool for reconstructing project state.  ")
          == "A tool for reconstructing project state.")
}

@Test func sanitizeStripsLeadingListMarkerAndQuotes() {
  #expect(NodeDescriber.sanitize("- \"A native macOS capture tool.\"")
          == "A native macOS capture tool.")
}

@Test func sanitizeStripsCodeFences() {
  #expect(NodeDescriber.sanitize("```\nA background sync daemon.\n```")
          == "A background sync daemon.")
}

@Test func sanitizeStripsLeadingHeadingMarker() {
  #expect(NodeDescriber.sanitize("# A row-level-security package")
          == "A row-level-security package")
}

@Test func sanitizeReturnsNilForEmpty() {
  #expect(NodeDescriber.sanitize("   \n  ") == nil)
  #expect(NodeDescriber.sanitize("```\n\n```") == nil)
}
