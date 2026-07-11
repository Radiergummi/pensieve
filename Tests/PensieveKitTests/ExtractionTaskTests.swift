import Testing
@testable import PensieveKit

// Classifier that keeps the genuine message. NOTE: `complete` returning "[]" is NOT a
// fail-open signal — the default `classifyGenuineIndices` decodes it successfully as an
// empty index set, and `IntentClassifier.filterGenuine` treats a successfully-decoded empty
// set as "drop the whole batch" (only a THROWN error fails open). So this double overrides
// `classifyGenuineIndices` directly to report message index 0 as genuine — which it
// genuinely is: "we should revisit retries later" is real developer intent.
private struct KeepGenuineClassifier: LLMProvider {
  func complete(prompt: String) async throws -> String { "[]" }
  func classifyGenuineIndices(prompt: String) async throws -> [Int] { [0] }
}
private struct OneCandidateExtractor: LLMProvider {
  func complete(prompt: String) async throws -> String { "" }
  func extractCandidates(prompt: String) async throws -> [LooseEndCandidate] {
    [LooseEndCandidate(text: "follow up on retries", quote: "we should revisit retries", messageIndex: 0)]
  }
}

@Test func extractionTaskSurfacesVerifiedLooseEnds() async throws {
  let msgs = [TranscriptMessageDTO(TranscriptMessage(index: 0, role: "user", text: "we should revisit retries later", timestamp: nil, isUserPrompt: true))]
  let item = CorpusItem.extraction(ExtractionCorpusItem(id: "x1", shape: "short", messages: msgs))
  let out = try await ExtractionTask().run(item: item, model: OneCandidateExtractor(), reference: KeepGenuineClassifier())
  #expect(out.looseEnds?.count == 1)
  #expect(out.looseEnds?.first?.quote == "we should revisit retries") // verbatim substring of the message
}

@Test func extractionTaskRejectsWrongItemType() async {
  let item = CorpusItem.narration(NarrationCorpusItem(id: "n", nodeName: "x", events: []))
  await #expect(throws: (any Error).self) {
    _ = try await ExtractionTask().run(item: item, model: OneCandidateExtractor(), reference: KeepGenuineClassifier())
  }
}
