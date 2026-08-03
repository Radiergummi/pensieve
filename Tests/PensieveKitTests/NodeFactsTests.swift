import Foundation
import Testing
import SQLiteData
@testable import PensieveKit

@Test func nodeFactsComputesGroundedFactsForActiveNodes() throws {
  let database = try openCanonicalDatabase(at: tempURL("nodefacts"))
  let resolver = ProjectResolver(database: database)
  let (a, sa) = try resolver.resolve(path: "/p/a", kind: SourceKind.claudeCode)
  let tenDaysAgo = Calendar.current.date(byAdding: .day, value: -10, to: Date())!
  try database.write { database in
    let ea = Event(nodeID: a.id, sourceID: sa.id, occurredAt: tenDaysAgo, kind: CaptureKind.ccSession,
                   summary: "s", detailJSON: "{}", fingerprint: "a1")
    try Event.insert { ea }.execute(database)
    try LooseEnd.insert {   // a resolved loose end must NOT be counted
      LooseEnd(nodeID: a.id, sourceEventID: ea.id, text: "t", quote: "q", role: "user")
    }.execute(database)
    try LooseEnd.insert {
      LooseEnd(nodeID: a.id, sourceEventID: ea.id, text: "t2", quote: "q2", status: "resolved")
    }.execute(database)
  }
  let facts = try NodeFactsQueries.all(database, now: Date())
  let fa = try #require(facts.first { $0.node.id == a.id })
  #expect(fa.openLooseEnds == 1)   // resolved excluded
  #expect(fa.daysDormant == 10)
}

@Test func nodeFactsExcludesConfirmedNoiseFromOpenLooseEndCount() throws {
  let database = try openCanonicalDatabase(at: tempURL("nodefacts-noise"))
  let resolver = ProjectResolver(database: database)
  let (a, sa) = try resolver.resolve(path: "/p/noise", kind: SourceKind.claudeCode)
  let ea = Event(nodeID: a.id, sourceID: sa.id, occurredAt: Date(), kind: CaptureKind.ccSession,
                 summary: "s", detailJSON: "{}", fingerprint: "nf1")
  try database.write { database in
    try Event.insert { ea }.execute(database)
    try LooseEnd.insert {
      LooseEnd(nodeID: a.id, sourceEventID: ea.id, text: "t1", quote: "unlabeled item")
    }.execute(database)
    try LooseEnd.insert {
      LooseEnd(nodeID: a.id, sourceEventID: ea.id, text: "t2", quote: "confirmed noise",
               label: LooseEndLabel.noise)
    }.execute(database)
    try LooseEnd.insert {
      LooseEnd(nodeID: a.id, sourceEventID: ea.id, text: "t3", quote: "only suggested noise",
               labelSuggestion: LooseEndLabel.noise)
    }.execute(database)
  }
  let facts = try NodeFactsQueries.all(database, now: Date())
  let fa = try #require(facts.first { $0.node.id == a.id })
  #expect(fa.openLooseEnds == 2)   // confirmed-noise excluded; unlabeled + suggestion-only-noise kept
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
