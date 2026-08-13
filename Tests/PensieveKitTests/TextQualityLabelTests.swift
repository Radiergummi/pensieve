import Testing
@testable import PensieveKit

@Test func sanitizeLabelStripsListMarkersQuotesAndTrailingPunctuation() {
  #expect(TextQuality.sanitizeLabel("1. Event Watermark Fields") == "Event Watermark Fields")
  #expect(TextQuality.sanitizeLabel("2) Drop Rows") == "Drop Rows")
  #expect(TextQuality.sanitizeLabel("- Sync daemon") == "Sync daemon")
  #expect(TextQuality.sanitizeLabel("Security enhancement with admin bypass.") == "Security enhancement with admin bypass")
  #expect(TextQuality.sanitizeLabel("\"Quoted Name\"") == "Quoted Name")
  #expect(TextQuality.sanitizeLabel("Already Clean") == "Already Clean")
  #expect(TextQuality.sanitizeLabel("   ") == nil)
}

@Test func sanitizeLabelRejectsSentencesAndOverlongOutput() {
  #expect(TextQuality.sanitizeLabel("Wire noise filters into pipeline. Fixes chunk splitting issue") == nil)
  #expect(TextQuality.sanitizeLabel(
    "A really long strand name that runs well past the sixty character cap we enforce") == nil)
  #expect(TextQuality.sanitizeLabel(
    "Refactor the ingest pipeline. Then rename the strand accordingly") == nil)
  // Internal dots that are not sentence boundaries must survive.
  #expect(TextQuality.sanitizeLabel("v3.1 migration") == "v3.1 migration")
  #expect(TextQuality.sanitizeLabel("Fix auth.middleware") == "Fix auth.middleware")
}

@Test func shortenReturnsShortInputWhole() {
  // The measured common case: quick-add sentences usually already fit, so most inputs
  // pass through untouched. Nine of eleven probe inputs were <= the cap.
  #expect(TextQuality.shorten("look into why the sync agent stopped") == "look into why the sync agent stopped")
  #expect(TextQuality.shorten("Steuerunterlagen für 2025 zusammenstellen") == "Steuerunterlagen für 2025 zusammenstellen")
  #expect(TextQuality.shorten("  padded  ") == "padded")
}

@Test func shortenBreaksOnWordBoundariesNeverMidWord() throws {
  let long = "I want to eventually get around to reconsidering whether projects and strands are the same kind of thing"
  let shortened = try #require(TextQuality.shorten(long))
  #expect(shortened.count <= TextQuality.labelLengthCap)
  // Every kept word must be a whole word from the input — a cut word reads as corruption.
  let inputWords = Set(long.split(separator: " ").map(String.init))
  #expect(shortened.split(separator: " ").allSatisfy { inputWords.contains(String($0)) })
  #expect(long.hasPrefix(shortened))
}

@Test func shortenHandlesASingleOverlongWordAndEmptyInput() {
  // No boundary to preserve, so cutting is the only option.
  let oneWord = String(repeating: "a", count: 80)
  #expect(TextQuality.shorten(oneWord)?.count == TextQuality.labelLengthCap)
  #expect(TextQuality.shorten("") == nil)
  #expect(TextQuality.shorten("   \n  ") == nil)
}
