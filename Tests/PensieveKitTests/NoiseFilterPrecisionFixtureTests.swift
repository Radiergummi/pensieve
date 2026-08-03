import Foundation
import Testing
@testable import PensieveKit

/// Precision fixture built from REAL quotes sampled from the live store's open loose ends.
/// Scope: `CandidateFilter`'s domain — quote-level noise (closures/acks/status/tool-output)
/// vs. real loose ends. Brief-derived noise is dropped at the MESSAGE level by
/// `StructuralNoiseFilter` (needs the full >=800-char message, not the stored substring),
/// and truncation is fixed at the source; those are covered by their own unit tests
/// (Tasks 1 & 3) and by the end-to-end retroactive re-extraction (Task 7). This fixture
/// is the frozen CandidateFilter regression guard: it must KEEP every real loose end
/// (hard recall) and DROP every curated quote-level noise case (precision).
private struct LabeledQuote: Codable { let quote: String; let label: String }

private func loadFixture() throws -> [LabeledQuote] {
  let url = Bundle.module.url(forResource: "loose-end-precision-sample", withExtension: "json",
                             subdirectory: "Fixtures")!
  return try JSONDecoder().decode([LabeledQuote].self, from: Data(contentsOf: url))
}

private func candidateDropped(_ quote: String) -> Bool {
  CandidateFilter.strip([LooseEndCandidate(text: "p", quote: quote, messageIndex: 0)]).isEmpty
}

@Test func candidateFilterKeepsRealsAndDropsNoiseOnLiveSample() throws {
  let fixture = try loadFixture()
  let reals = fixture.filter { $0.label == "looseEnd" }
  let noise = fixture.filter { $0.label == "noise" }
  #expect(reals.count >= 15 && noise.count >= 8)   // fixture is populated

  // HARD recall guard: not one real loose end may be dropped.
  for realLooseEnd in reals { #expect(!candidateDropped(realLooseEnd.quote), "dropped a REAL loose end: \(realLooseEnd.quote)") }

  // Precision: every curated quote-level noise case is removed.
  for noiseItem in noise { #expect(candidateDropped(noiseItem.quote), "failed to drop noise: \(noiseItem.quote)") }
}
