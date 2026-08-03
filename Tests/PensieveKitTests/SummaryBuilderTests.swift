import Foundation
import Testing
import SQLiteData
@testable import PensieveKit

private struct EchoProvider: LLMProvider {
  func complete(prompt: String) async throws -> String { "NARRATED: " + prompt.prefix(20) }
}

@Test func assembleFactsListsRecentCommitSubjects() {
  let projectNode = Node(name: "colibri")
  let sourceID = UUID()
  let events = [
    Event(nodeID: projectNode.id, sourceID: sourceID, occurredAt: Date(), kind: CaptureKind.gitCommit,
          summary: "add auth", detailJSON: "{}", fingerprint: "1"),
    Event(nodeID: projectNode.id, sourceID: sourceID, occurredAt: Date(), kind: CaptureKind.ccSession,
          summary: "session (3 prompts)", detailJSON: "{}", fingerprint: "2"),
  ]
  let facts = SummaryBuilder.assembleFacts(project: projectNode, events: events)
  #expect(facts.contains("add auth"))
  #expect(facts.contains("colibri"))
}

@Test func summaryBuildReturnsNarrationAndLooseEnds() async throws {
  let database = try openCanonicalDatabase(at: tempURL("sum"))
  let (project, source) = try ProjectResolver(database: database).resolve(path: "/p/colibri", kind: SourceKind.gitRepo)
  try await database.write { database in
    try Event.insert {
      Event(nodeID: project.id, sourceID: source.id, occurredAt: Date(), kind: CaptureKind.gitCommit,
            summary: "add auth", detailJSON: "{}", fingerprint: "c1")
    }.execute(database)
  }
  let sum = try await SummaryBuilder(provider: EchoProvider()).build(database, node: project, now: Date())
  #expect(sum != nil)
  #expect(sum?.lastWorkDone.hasPrefix("NARRATED:") == true)
}

@Test func summaryBuildReturnsNilForNodeWithNoActivity() async throws {
  let database = try openCanonicalDatabase(at: tempURL("sum-empty"))
  // A bare scanned repo: the node/source exist but nothing was ever captured.
  // build() must skip it rather than narrate an empty fact sheet (which the model
  // "narrates" by hallucinating or echoing the prompt).
  let (empty, _) = try ProjectResolver(database: database).resolve(path: "/p/empty", kind: SourceKind.gitRepo)
  let sum = try await SummaryBuilder(provider: EchoProvider()).build(database, node: empty, now: Date())
  #expect(sum == nil)
}

@Test func assembleFactsPrefersWorkSummaryOverTerseSummary() {
  let node = Node(name: "Pensieve")
  let event = Event(nodeID: node.id, sourceID: UUID(), occurredAt: Date(),
                kind: CaptureKind.ccSession, summary: "session (9 prompts)", detailJSON: "{}",
                workSummary: "Wired the sync daemon and fixed the watermark.")
  let facts = SummaryBuilder.assembleFacts(project: node, events: [event])
  #expect(facts.contains("Wired the sync daemon and fixed the watermark."))
  #expect(!facts.contains("session (9 prompts)"))
}

@Test func assembleFactsFallsBackToTerseSummaryWhenNoWorkSummary() {
  let node = Node(name: "Pensieve")
  let event = Event(nodeID: node.id, sourceID: UUID(), occurredAt: Date(),
                kind: CaptureKind.gitCommit, summary: "fix: watermark off-by-one", detailJSON: "{}")
  let facts = SummaryBuilder.assembleFacts(project: node, events: [event])
  #expect(facts.contains("fix: watermark off-by-one"))
}

@Test func assembleFactsRespectsCharBudget() {
  let node = Node(name: "Pensieve")
  let events = (0..<15).map { _ in
    Event(nodeID: node.id, sourceID: UUID(), occurredAt: Date(),
          kind: CaptureKind.ccSession, summary: "s", detailJSON: "{}",
          workSummary: String(repeating: "x", count: 400))
  }
  let facts = SummaryBuilder.assembleFacts(project: node, events: events)
  #expect(facts.count <= SummaryBuilder.factSheetBudget + 200)   // header + a few lines, never all 15
}

@Test func summaryBuildKeysByNodeNotAmbiguousName() async throws {
  let database = try openCanonicalDatabase(at: tempURL("sum-dup"))
  // Two DISTINCT repos share a basename (real: ~/a/calliope and ~/b/calliope).
  let (active, source) = try ProjectResolver(database: database).resolve(path: "/a/calliope", kind: SourceKind.gitRepo)
  let (empty, _) = try ProjectResolver(database: database).resolve(path: "/b/calliope", kind: SourceKind.gitRepo)
  #expect(active.id != empty.id)
  #expect(active.name == empty.name)   // same name, different nodes
  try await database.write { database in
    try Event.insert {
      Event(nodeID: active.id, sourceID: source.id, occurredAt: Date(), kind: CaptureKind.gitCommit,
            summary: "add auth", detailJSON: "{}", fingerprint: "c1")
    }.execute(database)
  }
  let builder = SummaryBuilder(provider: EchoProvider())
  // Keyed by node, each resolves to its OWN activity — the empty twin no longer shadows the active one.
  #expect(try await builder.build(database, node: active, now: Date()) != nil)
  #expect(try await builder.build(database, node: empty, now: Date()) == nil)
}
