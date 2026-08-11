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
