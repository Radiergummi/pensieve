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
  let sum = try await SummaryBuilder(provider: EchoProvider()).build(db, node: project, now: Date())
  #expect(sum != nil)
  #expect(sum?.lastWorkDone.hasPrefix("NARRATED:") == true)
}

@Test func summaryBuildReturnsNilForNodeWithNoActivity() async throws {
  let db = try openCanonicalDatabase(at: tempURL("sum-empty"))
  // A bare scanned repo: the node/source exist but nothing was ever captured.
  // build() must skip it rather than narrate an empty fact sheet (which the model
  // "narrates" by hallucinating or echoing the prompt).
  let (empty, _) = try ProjectResolver(db: db).resolve(path: "/p/empty", kind: SourceKind.gitRepo)
  let sum = try await SummaryBuilder(provider: EchoProvider()).build(db, node: empty, now: Date())
  #expect(sum == nil)
}

@Test func summaryBuildKeysByNodeNotAmbiguousName() async throws {
  let db = try openCanonicalDatabase(at: tempURL("sum-dup"))
  // Two DISTINCT repos share a basename (real: ~/a/calliope and ~/b/calliope).
  let (active, source) = try ProjectResolver(db: db).resolve(path: "/a/calliope", kind: SourceKind.gitRepo)
  let (empty, _) = try ProjectResolver(db: db).resolve(path: "/b/calliope", kind: SourceKind.gitRepo)
  #expect(active.id != empty.id)
  #expect(active.name == empty.name)   // same name, different nodes
  try await db.write { db in
    try Event.insert {
      Event(nodeID: active.id, sourceID: source.id, occurredAt: Date(), kind: CaptureKind.gitCommit,
            summary: "add auth", detailJSON: "{}", fingerprint: "c1")
    }.execute(db)
  }
  let builder = SummaryBuilder(provider: EchoProvider())
  // Keyed by node, each resolves to its OWN activity — the empty twin no longer shadows the active one.
  #expect(try await builder.build(db, node: active, now: Date()) != nil)
  #expect(try await builder.build(db, node: empty, now: Date()) == nil)
}
