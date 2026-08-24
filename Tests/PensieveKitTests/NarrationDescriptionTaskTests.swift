import Foundation
import Testing
@testable import PensieveKit

private struct EchoProvider: LLMProvider {
  let text: String
  func complete(prompt: String) async throws -> String { text }
}

/// Renamed from `narrationTaskReturnsProse`, which asserted only `out.looseEnds == nil` — a value
/// `NarrationTask` hardcodes, so the test passed with the task's text gutted (mutation-proven during
/// the 2026-08-24 sweep). What this case actually establishes is the no-events contract: `narrate`
/// returns nil, and the task must turn that into empty text rather than crashing or inventing prose.
/// Asserting the text is what makes it a test.
@Test func narrationTaskYieldsEmptyTextWhenThereIsNothingToNarrate() async throws {
  let item = CorpusItem.narration(NarrationCorpusItem(id: "n1", nodeName: "colibri", events: []))
  let out = try await NarrationTask().run(item: item, model: EchoProvider(text: "worked on auth"),
                                          reference: EchoProvider(text: ""))
  // Empty despite a provider that would happily answer — no events means nothing grounded to say,
  // and a narration invented from an empty fact sheet is exactly what the north star forbids.
  #expect(out.text.isEmpty)
  #expect(out.looseEnds == nil)
}

@Test func narrationTaskPassesThroughModelProseWithEvents() async throws {
  // Enriched session (`workSummary` present): an unenriched one carries only a generated
  // "session (N prompts)" label, which `SummaryBuilder` deliberately refuses to narrate.
  let event = Event(nodeID: UUID(), sourceID: UUID(), occurredAt: Date(), kind: "cc.session",
                     summary: "shipped auth", detailJSON: "{}", workSummary: "shipped auth")
  let item = CorpusItem.narration(NarrationCorpusItem(id: "n2", nodeName: "colibri", events: [EventDTO(event)]))
  let out = try await NarrationTask().run(item: item, model: EchoProvider(text: "worked on auth"), reference: EchoProvider(text: ""))
  #expect(out.text == "worked on auth")
  #expect(out.looseEnds == nil)
}

private func descriptionItem() -> CorpusItem {
  let context = ProjectContextDTO(ProjectContext(dirName: "colibri", gitRemote: nil,
                                                 readmeHead: "# Colibri", claudeMdHead: nil,
                                                 manifest: "src/main.swift"))
  return .description(DescriptionCorpusItem(id: "d1", context: context))
}

/// The old `descriptionTaskSanitizesModelOutput` fed `"A native macOS recipe app."` — text that
/// needs no sanitizing — so it asserted pass-through and nothing else. Removing the sanitize call
/// entirely left it green (mutation-proven during the 2026-08-24 sweep). Sanitizing is only tested
/// by input that must actually be rejected.
@Test func descriptionTaskRejectsStructuredOutputWearingAProseCostume() async throws {
  // A fenced JSON array is what these providers really emit when they misread the prompt — the code
  // comments record 139 such "recaps". A rejected output is a legitimate model-quality result, so it
  // becomes empty text and a SUCCESSFUL run, not a thrown error.
  let out = try await DescriptionTask().run(item: descriptionItem(),
                                            model: EchoProvider(text: "```json\n[0,3,7]\n```"),
                                            reference: EchoProvider(text: ""))
  #expect(out.text.isEmpty)
}

@Test func descriptionTaskPassesThroughGenuineProse() async throws {
  let out = try await DescriptionTask().run(item: descriptionItem(),
                                            model: EchoProvider(text: "A native macOS recipe app."),
                                            reference: EchoProvider(text: ""))
  #expect(out.text == "A native macOS recipe app.")
}
