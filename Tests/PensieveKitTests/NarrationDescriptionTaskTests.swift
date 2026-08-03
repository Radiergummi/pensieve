import Foundation
import Testing
@testable import PensieveKit

private struct EchoProvider: LLMProvider {
  let text: String
  func complete(prompt: String) async throws -> String { text }
}

@Test func narrationTaskReturnsProse() async throws {
  let item = CorpusItem.narration(NarrationCorpusItem(id: "n1", nodeName: "colibri", events: []))
  // narrate returns nil on no events → task yields empty text, not a crash
  let out = try await NarrationTask().run(item: item, model: EchoProvider(text: "worked on auth"), reference: EchoProvider(text: ""))
  #expect(out.looseEnds == nil)
}

@Test func narrationTaskPassesThroughModelProseWithEvents() async throws {
  let event = Event(nodeID: UUID(), sourceID: UUID(), occurredAt: Date(), kind: "cc.session",
                     summary: "shipped auth", detailJSON: "{}")
  let item = CorpusItem.narration(NarrationCorpusItem(id: "n2", nodeName: "colibri", events: [EventDTO(event)]))
  let out = try await NarrationTask().run(item: item, model: EchoProvider(text: "worked on auth"), reference: EchoProvider(text: ""))
  #expect(out.text == "worked on auth")
  #expect(out.looseEnds == nil)
}

@Test func descriptionTaskSanitizesModelOutput() async throws {
  let ctx = ProjectContextDTO(ProjectContext(dirName: "colibri", gitRemote: nil, readmeHead: "# Colibri",
                                              claudeMdHead: nil, manifest: "src/main.swift"))
  let item = CorpusItem.description(DescriptionCorpusItem(id: "d1", context: ctx))
  let out = try await DescriptionTask().run(item: item, model: EchoProvider(text: "A native macOS recipe app."),
                                             reference: EchoProvider(text: ""))
  #expect(out.text == "A native macOS recipe app.")
}
