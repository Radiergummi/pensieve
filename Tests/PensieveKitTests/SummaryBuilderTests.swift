import Foundation
import Testing
import SQLiteData
@testable import PensieveKit

private struct EchoProvider: LLMProvider {
  func complete(prompt: String) async throws -> String { "NARRATED: " + prompt.prefix(20) }
}

@Test func assembleFactsListsRecentCommitSubjects() {
  let p = Node(name: "colibri")
  let s = UUID()
  let events = [
    Event(nodeID: p.id, sourceID: s, occurredAt: Date(), kind: CaptureKind.gitCommit,
          summary: "add auth", detailJSON: "{}", fingerprint: "1"),
    Event(nodeID: p.id, sourceID: s, occurredAt: Date(), kind: CaptureKind.ccSession,
          summary: "session (3 prompts)", detailJSON: "{}", fingerprint: "2"),
  ]
  let facts = SummaryBuilder.assembleFacts(project: p, events: events)
  #expect(facts.contains("add auth"))
  #expect(facts.contains("colibri"))
}

@Test func summaryBuildReturnsNarrationAndLooseEnds() async throws {
  let db = try openCanonicalDatabase(at: tempURL("sum"))
  let (project, source) = try ProjectResolver(db: db).resolve(path: "/p/colibri", kind: SourceKind.gitRepo)
  try await db.write { db in
    try Event.insert {
      Event(nodeID: project.id, sourceID: source.id, occurredAt: Date(), kind: CaptureKind.gitCommit,
            summary: "add auth", detailJSON: "{}", fingerprint: "c1")
    }.execute(db)
  }
  let sum = try await SummaryBuilder(provider: EchoProvider()).build(db, projectName: "colibri", now: Date())
  #expect(sum != nil)
  #expect(sum?.lastWorkDone.hasPrefix("NARRATED:") == true)
}
