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
