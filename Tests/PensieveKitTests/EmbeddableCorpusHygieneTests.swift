import Testing
import Foundation
import SQLiteData
@testable import PensieveKit

/// `EmbeddableCorpus.gather`'s event hygiene rules (spec P1) — in their own file to stay under the
/// file-length limit. The corpus they cover is the one BM25 searches.
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

  @Test func gatherCarriesChangedFilePathsOnCommitEvents() async throws {
    let database = try openCanonicalDatabase(at: tempURL("gather-files"))
    let node = Node(name: "Pensieve", kind: NodeKind.project)
    let source = Source(nodeID: node.id, kind: SourceKind.gitRepo, key: "/p/\(node.id)")
    let detail = #"{"hash":"abc","branch":"main","files":"Sources/A.swift\nSources/B.swift"}"#
    try await database.write { database in
      try Node.insert { node }.execute(database)
      try Source.insert { source }.execute(database)
      try Event.insert {
        Event(nodeID: node.id, sourceID: source.id, occurredAt: Date(),
              kind: CaptureKind.gitCommit, summary: "add the parser",
              detailJSON: detail, fingerprint: "c1")
      }.execute(database)
      try Event.insert {
        Event(nodeID: node.id, sourceID: source.id, occurredAt: Date(),
              kind: CaptureKind.ccSession, summary: "session",
              detailJSON: "{}", fingerprint: "s1", workSummary: "worked on the parser for a while")
      }.execute(database)
    }
    let corpus = try EmbeddableCorpus.gather(database)
    let commit = corpus.first { $0.text == "add the parser" }
    #expect(commit?.files == "Sources/A.swift\nSources/B.swift")
    #expect(corpus.first { $0.kind == "node" }?.files == "")
    #expect(corpus.first { $0.text.contains("worked on the parser") }?.files == "")
  }

  /// Finding 2.17. The dedup is a TEXT rule. Two commits sharing a message but touching different
  /// files must BOTH contribute their paths, or `files:` search cannot find the second commit's
  /// files at all — while `documents` still holds exactly one row for the repeated text.
  @Test func aRepeatedEventTextStillIndexesTheLaterCommitsPaths() async throws {
    let database = try openCanonicalDatabase(at: tempURL("gather-dedup-files"))
    let node = Node(name: "Pensieve", kind: NodeKind.project)
    let source = Source(nodeID: node.id, kind: SourceKind.gitRepo, key: "/p/\(node.id)")
    let firstID = UUID(), secondID = UUID()
    try await database.write { database in
      try Node.insert { node }.execute(database)
      try Source.insert { source }.execute(database)
      try Event.insert {
        Event(id: firstID, nodeID: node.id, sourceID: source.id,
              occurredAt: Date(timeIntervalSince1970: 1_000), kind: CaptureKind.gitCommit,
              summary: "fix ci", detailJSON: #"{"files":"Sources/First.swift"}"#, fingerprint: "a")
      }.execute(database)
      try Event.insert {
        Event(id: secondID, nodeID: node.id, sourceID: source.id,
              occurredAt: Date(timeIntervalSince1970: 2_000), kind: CaptureKind.gitCommit,
              summary: "fix ci", detailJSON: #"{"files":"Sources/Second.swift"}"#, fingerprint: "b")
      }.execute(database)
    }
    let events = try EmbeddableCorpus.gather(database).filter { $0.kind == "event" }
    #expect(Set(events.map(\.files)) == ["Sources/First.swift", "Sources/Second.swift"])
    // The repeat carries the paths and NO text, so the text index keeps one row for "fix ci".
    #expect(events.filter { !$0.text.isEmpty }.map(\.itemID) == [firstID.uuidString])
    #expect(events.first { $0.itemID == secondID.uuidString }?.text == "")

    // End to end: the second commit's file is findable, and the repeated text is not duplicated.
    let store = tempSearchStore()
    store.rebuild(items: events, corpusHash: "h")
    #expect(store.search(FTSQueryBuilder.build("second.swift ")!, limit: 10,
                         includeArchived: false).map(\.itemID) == [secondID.uuidString])
    #expect(store.search(FTSQueryBuilder.build("fix ci ")!, limit: 10,
                         includeArchived: false).map(\.itemID) == [firstID.uuidString])
  }

  /// Finding 1.5. `SearchQueries.buildHits` parses the stored `kind` back through
  /// `SearchHit.Kind(rawValue:)`, so a producer literal that stopped matching would index fine and
  /// resolve to nothing. Every kind the producer writes must round-trip through that enum.
  @Test func everyProducedKindRoundTripsThroughSearchHitKind() async throws {
    let database = try openCanonicalDatabase(at: tempURL("gather-kinds"))
    let node = Node(name: "Pensieve", kind: NodeKind.project)
    let source = Source(nodeID: node.id, kind: SourceKind.gitRepo, key: "/p/\(node.id)")
    let eventID = UUID()
    try await database.write { database in
      try Node.insert { node }.execute(database)
      try Source.insert { source }.execute(database)
      try Event.insert {
        Event(id: eventID, nodeID: node.id, sourceID: source.id, occurredAt: Date(),
              kind: CaptureKind.gitCommit, summary: "add the parser", detailJSON: "{}",
              fingerprint: "c1")
      }.execute(database)
      try LooseEnd.insert {
        LooseEnd(nodeID: node.id, sourceEventID: eventID, text: "wire up the retry",
                 quote: "we should wire up the retry")
      }.execute(database)
    }
    let corpus = try EmbeddableCorpus.gather(database)
    #expect(!corpus.isEmpty)
    for item in corpus {
      #expect(SearchHit.Kind(rawValue: item.kind) != nil, "unresolvable kind '\(item.kind)'")
    }
    #expect(Set(corpus.map(\.kind)) == ["node", "loose_end", "event"])
    // `loose_end` is a STORED index value: changing it orphans every existing index row.
    #expect(SearchHit.Kind.looseEnd.rawValue == "loose_end")
    // Passages are produced separately, from `Passage.searchKind`, and resolve the same way.
    #expect(SearchHit.Kind(rawValue: Passage.searchKind) == nil)   // not a SearchHit kind, by design
  }

  @Test func contentHashIgnoresFilesSoPathsNeverForceAReEmbed() {
    let withoutFiles = EmbeddableItem(itemID: "i", kind: "event", nodeID: "n", state: "active",
                                      text: "same text")
    let withFiles = EmbeddableItem(itemID: "i", kind: "event", nodeID: "n", state: "active",
                                   text: "same text", files: "Sources/A.swift")
    #expect(withoutFiles.contentHash == withFiles.contentHash)
  }
}
