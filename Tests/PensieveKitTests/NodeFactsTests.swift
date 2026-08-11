import Foundation
import Testing
import SQLiteData
@testable import PensieveKit

@Test func nodeFactsComputesGroundedFactsForActiveNodes() throws {
  let database = try openCanonicalDatabase(at: tempURL("nodefacts"))
  let resolver = ProjectResolver(database: database)
  let (testNode, testNodeSource) = try resolver.resolve(path: "/p/a", kind: SourceKind.claudeCode)
  let tenDaysAgo = Calendar.current.date(byAdding: .day, value: -10, to: Date())!
  try database.write { database in
    let testEvent = Event(nodeID: testNode.id, sourceID: testNodeSource.id, occurredAt: tenDaysAgo, kind: CaptureKind.ccSession,
                   summary: "s", detailJSON: "{}", fingerprint: "a1")
    try Event.insert { testEvent }.execute(database)
    try LooseEnd.insert {   // a resolved loose end must NOT be counted
      LooseEnd(nodeID: testNode.id, sourceEventID: testEvent.id, text: "t", quote: "q", role: "user")
    }.execute(database)
    try LooseEnd.insert {
      LooseEnd(nodeID: testNode.id, sourceEventID: testEvent.id, text: "t2", quote: "q2", status: "resolved")
    }.execute(database)
  }
  let facts = try NodeFactsQueries.all(database, now: Date())
  let testNodeFacts = try #require(facts.first { $0.node.id == testNode.id })
  #expect(testNodeFacts.openLooseEnds == 1)   // resolved excluded
  #expect(testNodeFacts.daysDormant == 10)
}

@Test func nodeFactsExcludesConfirmedNoiseFromOpenLooseEndCount() throws {
  let database = try openCanonicalDatabase(at: tempURL("nodefacts-noise"))
  let resolver = ProjectResolver(database: database)
  let (testNode, testNodeSource) = try resolver.resolve(path: "/p/noise", kind: SourceKind.claudeCode)
  let testEvent = Event(nodeID: testNode.id, sourceID: testNodeSource.id, occurredAt: Date(), kind: CaptureKind.ccSession,
                 summary: "s", detailJSON: "{}", fingerprint: "nf1")
  try database.write { database in
    try Event.insert { testEvent }.execute(database)
    try LooseEnd.insert {
      LooseEnd(nodeID: testNode.id, sourceEventID: testEvent.id, text: "t1", quote: "unlabeled item")
    }.execute(database)
    try LooseEnd.insert {
      LooseEnd(nodeID: testNode.id, sourceEventID: testEvent.id, text: "t2", quote: "confirmed noise",
               label: LooseEndLabel.noise)
    }.execute(database)
    try LooseEnd.insert {
      LooseEnd(nodeID: testNode.id, sourceEventID: testEvent.id, text: "t3", quote: "only suggested noise",
               labelSuggestion: LooseEndLabel.noise)
    }.execute(database)
  }
  let facts = try NodeFactsQueries.all(database, now: Date())
  let testNodeFacts = try #require(facts.first { $0.node.id == testNode.id })
  #expect(testNodeFacts.openLooseEnds == 2)   // confirmed-noise excluded; unlabeled + suggestion-only-noise kept
}

@Test func nodeFactsExcludesArchivedFromAllButFetchesByID() throws {
  let database = try openCanonicalDatabase(at: tempURL("nodefacts-archived"))
  let archivedID = UUID()
  try database.write { database in
    try Node.insert { Node(id: archivedID, name: "Archived", state: .archived) }.execute(database)
  }
  let all = try NodeFactsQueries.all(database, now: Date())
  #expect(!all.contains { $0.node.id == archivedID })   // active-only population
  let byID = try NodeFactsQueries.facts(for: [archivedID], database, now: Date())
  #expect(byID.first?.node.id == archivedID)             // a tap still resolves it
  #expect(byID.first?.daysDormant == 0)                  // no events → 0
}

@Test func nodeFactsCarriesTheLatestEventTimestamp() throws {
  let database = try openCanonicalDatabase(at: tempURL("nodefacts-timestamp"))
  let resolver = ProjectResolver(database: database)
  let (testNode, testNodeSource) = try resolver.resolve(path: "/p/stamp", kind: SourceKind.claudeCode)
  let older = Calendar.current.date(byAdding: .day, value: -10, to: Date())!
  let newest = Calendar.current.date(byAdding: .day, value: -2, to: Date())!
  try database.write { database in
    try Event.insert {
      Event(nodeID: testNode.id, sourceID: testNodeSource.id, occurredAt: older,
            kind: CaptureKind.ccSession, summary: "old", detailJSON: "{}", fingerprint: "ts1")
    }.execute(database)
    try Event.insert {
      Event(nodeID: testNode.id, sourceID: testNodeSource.id, occurredAt: newest,
            kind: CaptureKind.gitCommit, summary: "new", detailJSON: "{}", fingerprint: "ts2")
    }.execute(database)
  }
  let facts = try NodeFactsQueries.all(database, now: Date())
  let testNodeFacts = try #require(facts.first { $0.node.id == testNode.id })
  let lastActivityAt = try #require(testNodeFacts.lastActivityAt)
  #expect(abs(lastActivityAt.timeIntervalSince(newest)) < 0.001)
  #expect(testNodeFacts.daysDormant == 2)   // unchanged: still derived from the same event
}

@Test func nodeFactsHasNoTimestampWithoutEvents() throws {
  let database = try openCanonicalDatabase(at: tempURL("nodefacts-no-events"))
  let emptyID = UUID()
  try database.write { database in
    try Node.insert { Node(id: emptyID, name: "Empty") }.execute(database)
  }
  let facts = try NodeFactsQueries.facts(for: [emptyID], database, now: Date())
  let emptyFacts = try #require(facts.first)
  #expect(emptyFacts.lastActivityAt == nil)   // honest absence, NOT a fake zero
  #expect(emptyFacts.daysDormant == 0)        // the old integer still reports 0 for ranking
}

@Test func rowFactsAgreesWithPerNodeFacts() throws {
  let database = try openCanonicalDatabase(at: tempURL("rowfacts-agreement"))
  let resolver = ProjectResolver(database: database)
  let (nodeA, sourceA) = try resolver.resolve(path: "/p/row-a", kind: SourceKind.claudeCode)
  let (nodeB, sourceB) = try resolver.resolve(path: "/p/row-b", kind: SourceKind.gitRepo)
  let older = Calendar.current.date(byAdding: .day, value: -9, to: Date())!
  let newest = Calendar.current.date(byAdding: .day, value: -4, to: Date())!
  try database.write { database in
    let eventA1 = Event(nodeID: nodeA.id, sourceID: sourceA.id, occurredAt: older,
                        kind: CaptureKind.ccSession, summary: "a1", detailJSON: "{}", fingerprint: "rf1")
    let eventA2 = Event(nodeID: nodeA.id, sourceID: sourceA.id, occurredAt: newest,
                        kind: CaptureKind.gitCommit, summary: "a2", detailJSON: "{}", fingerprint: "rf2")
    let eventB = Event(nodeID: nodeB.id, sourceID: sourceB.id, occurredAt: older,
                       kind: CaptureKind.gitCommit, summary: "b1", detailJSON: "{}", fingerprint: "rf3")
    try Event.insert { eventA1 }.execute(database)
    try Event.insert { eventA2 }.execute(database)
    try Event.insert { eventB }.execute(database)
    // nodeA: one open, one resolved, one confirmed-noise → exactly 1 open
    try LooseEnd.insert { LooseEnd(nodeID: nodeA.id, sourceEventID: eventA1.id, text: "open", quote: "q") }.execute(database)
    try LooseEnd.insert { LooseEnd(nodeID: nodeA.id, sourceEventID: eventA1.id, text: "done", quote: "q", status: "resolved") }.execute(database)
    try LooseEnd.insert { LooseEnd(nodeID: nodeA.id, sourceEventID: eventA1.id, text: "noise", quote: "q",
                                   label: LooseEndLabel.noise) }.execute(database)
  }
  let batched = try NodeFactsQueries.rowFacts(database)
  let perNode = try NodeFactsQueries.facts(for: [nodeA.id, nodeB.id], database, now: Date())
  for facts in perNode {
    let row = try #require(batched[facts.node.id], "batched result missing \(facts.node.name)")
    #expect(row.openLooseEnds == facts.openLooseEnds)
    switch (row.lastActivityAt, facts.lastActivityAt) {
    case let (batchedDate?, perNodeDate?):
      // A tolerance, not exact equality: a mismatch between the raw-SQL date decoder and
      // SQLiteData's would show up here as hours, not microseconds.
      #expect(abs(batchedDate.timeIntervalSince(perNodeDate)) < 0.001)
    case (nil, nil): break
    default: Issue.record("one side had a date and the other did not for \(facts.node.name)")
    }
  }
  #expect(batched[nodeA.id]?.openLooseEnds == 1)
  #expect(batched[nodeB.id]?.openLooseEnds == 0)
}

@Test func looseEndOpenPredicatesAgree() throws {
  let database = try openCanonicalDatabase(at: tempURL("open-predicate-agreement"))
  let resolver = ProjectResolver(database: database)
  let (testNode, testNodeSource) = try resolver.resolve(path: "/p/predicate", kind: SourceKind.claudeCode)
  let testEvent = Event(nodeID: testNode.id, sourceID: testNodeSource.id, occurredAt: Date(),
                        kind: CaptureKind.ccSession, summary: "s", detailJSON: "{}", fingerprint: "pa1")
  try database.write { database in
    try Event.insert { testEvent }.execute(database)
    // Every status × label combination the predicate must judge.
    for (status, label, suggestion) in [
      ("open", "", ""), ("open", LooseEndLabel.salient, ""), ("open", LooseEndLabel.noise, ""),
      ("open", "", LooseEndLabel.noise), ("resolved", "", ""),
      ("resolved", LooseEndLabel.salient, ""), ("resolved", LooseEndLabel.noise, ""),
    ] {
      try LooseEnd.insert {
        LooseEnd(nodeID: testNode.id, sourceEventID: testEvent.id, text: "t", quote: "q",
                 status: status, label: label, labelSuggestion: suggestion)
      }.execute(database)
    }
  }
  let typedCount = try database.read { database in
    try LooseEnd.where { LooseEnd.isOpen($0) }.fetchCount(database)
  }
  // The SQL spelling is exercised through the production path rather than re-issued here — no test
  // file in this suite imports GRDB, and going through `rowFacts` tests the code that ships.
  let batched = try NodeFactsQueries.rowFacts(database)
  #expect(typedCount == 3)   // open+unlabeled, open+salient, open+suggestion-only-noise
  #expect(batched[testNode.id]?.openLooseEnds == typedCount)   // the two spellings must never diverge
}
