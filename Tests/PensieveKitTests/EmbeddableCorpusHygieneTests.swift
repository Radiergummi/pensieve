import Testing
import Foundation
import SQLiteData
@testable import PensieveKit

/// `EmbeddableCorpus.gather`'s event hygiene rules (spec P1) — split into its own file to keep
/// `SemanticIndexerTests.swift` under the file-length limit.
@Suite struct EmbeddableCorpusHygieneTests {
  @Test func gatherSkipsCheckoutEvents() async throws {
    let database = try openCanonicalDatabase(at: tempURL("gather-checkout"))
    let node = Node(name: "Pensieve", kind: NodeKind.project)
    let source = Source(nodeID: node.id, kind: SourceKind.gitRepo, key: "/p/\(node.id)")
    try await database.write { database in
      try Node.insert { node }.execute(database)
      try Source.insert { source }.execute(database)
      try Event.insert {
        Event(nodeID: node.id, sourceID: source.id, occurredAt: Date(),
              kind: CaptureKind.gitCheckout, summary: "checkout main",
              detailJSON: "{}", fingerprint: "checkout-1")
      }.execute(database)
      try Event.insert {
        Event(nodeID: node.id, sourceID: source.id, occurredAt: Date(),
              kind: CaptureKind.gitCommit, summary: "add the parser",
              detailJSON: "{}", fingerprint: "commit-1")
      }.execute(database)
    }
    let corpus = try EmbeddableCorpus.gather(database)
    let eventTexts = corpus.filter { $0.kind == "event" }.map(\.text)
    #expect(eventTexts == ["add the parser"])
  }

  @Test func gatherDeDupesWithinANodeKeepingTheEarliest() async throws {
    let database = try openCanonicalDatabase(at: tempURL("gather-dedup"))
    let node = Node(name: "Pensieve", kind: NodeKind.project)
    let source = Source(nodeID: node.id, kind: SourceKind.gitRepo, key: "/p/\(node.id)")
    let earliest = Date(timeIntervalSince1970: 1_000)
    let latest = Date(timeIntervalSince1970: 2_000)
    let keptID = UUID()
    try await database.write { database in
      try Node.insert { node }.execute(database)
      try Source.insert { source }.execute(database)
      // Insert the LATER one first, so passing requires real ordering, not insertion luck.
      try Event.insert {
        Event(nodeID: node.id, sourceID: source.id, occurredAt: latest,
              kind: CaptureKind.gitCommit, summary: "fix ci", detailJSON: "{}", fingerprint: "b")
      }.execute(database)
      try Event.insert {
        Event(id: keptID, nodeID: node.id, sourceID: source.id, occurredAt: earliest,
              kind: CaptureKind.gitCommit, summary: "fix ci", detailJSON: "{}", fingerprint: "a")
      }.execute(database)
    }
    let events = try EmbeddableCorpus.gather(database).filter { $0.kind == "event" }
    #expect(events.count == 1)
    #expect(events[0].itemID == keptID.uuidString)
  }

  @Test func gatherKeepsIdenticalTextsInDifferentNodes() async throws {
    let database = try openCanonicalDatabase(at: tempURL("gather-dedup-cross"))
    let first = Node(name: "Alpha", kind: NodeKind.project)
    let second = Node(name: "Beta", kind: NodeKind.project)
    try await database.write { database in
      try Node.insert { first }.execute(database)
      try Node.insert { second }.execute(database)
      for node in [first, second] {
        let source = Source(nodeID: node.id, kind: SourceKind.gitRepo, key: "/p/\(node.id)")
        try Source.insert { source }.execute(database)
        try Event.insert {
          Event(nodeID: node.id, sourceID: source.id, occurredAt: Date(),
                kind: CaptureKind.gitCommit, summary: "fix ci",
                detailJSON: "{}", fingerprint: "fix-\(node.id)")
        }.execute(database)
      }
    }
    let events = try EmbeddableCorpus.gather(database).filter { $0.kind == "event" }
    #expect(events.count == 2)   // cross-node duplicates are NOT collapsed
  }
}
