import Foundation
import Testing
import SQLiteData
@testable import PensieveKit

@Test func nodeFactsComputesGroundedFactsForActiveNodes() throws {
  let db = try openCanonicalDatabase(at: tempURL("nodefacts"))
  let resolver = ProjectResolver(db: db)
  let (a, sa) = try resolver.resolve(path: "/p/a", kind: SourceKind.claudeCode)
  let tenDaysAgo = Calendar.current.date(byAdding: .day, value: -10, to: Date())!
  try db.write { db in
    let ea = Event(nodeID: a.id, sourceID: sa.id, occurredAt: tenDaysAgo, kind: CaptureKind.ccSession,
                   summary: "s", detailJSON: "{}", fingerprint: "a1")
    try Event.insert { ea }.execute(db)
    try LooseEnd.insert {   // a resolved loose end must NOT be counted
      LooseEnd(nodeID: a.id, sourceEventID: ea.id, text: "t", quote: "q", role: "user")
    }.execute(db)
    try LooseEnd.insert {
      LooseEnd(nodeID: a.id, sourceEventID: ea.id, text: "t2", quote: "q2", status: "resolved")
    }.execute(db)
  }
  let facts = try NodeFactsQueries.all(db, now: Date())
  let fa = try #require(facts.first { $0.node.id == a.id })
  #expect(fa.openLooseEnds == 1)   // resolved excluded
  #expect(fa.daysDormant == 10)
}

@Test func nodeFactsExcludesConfirmedNoiseFromOpenLooseEndCount() throws {
  let db = try openCanonicalDatabase(at: tempURL("nodefacts-noise"))
  let resolver = ProjectResolver(db: db)
  let (a, sa) = try resolver.resolve(path: "/p/noise", kind: SourceKind.claudeCode)
  let ea = Event(nodeID: a.id, sourceID: sa.id, occurredAt: Date(), kind: CaptureKind.ccSession,
                 summary: "s", detailJSON: "{}", fingerprint: "nf1")
  try db.write { db in
    try Event.insert { ea }.execute(db)
    try LooseEnd.insert {
      LooseEnd(nodeID: a.id, sourceEventID: ea.id, text: "t1", quote: "unlabeled item")
    }.execute(db)
    try LooseEnd.insert {
      LooseEnd(nodeID: a.id, sourceEventID: ea.id, text: "t2", quote: "confirmed noise",
               label: LooseEndLabel.noise)
    }.execute(db)
    try LooseEnd.insert {
      LooseEnd(nodeID: a.id, sourceEventID: ea.id, text: "t3", quote: "only suggested noise",
               labelSuggestion: LooseEndLabel.noise)
    }.execute(db)
  }
  let facts = try NodeFactsQueries.all(db, now: Date())
  let fa = try #require(facts.first { $0.node.id == a.id })
  #expect(fa.openLooseEnds == 2)   // confirmed-noise excluded; unlabeled + suggestion-only-noise kept
}

@Test func nodeFactsExcludesArchivedFromAllButFetchesByID() throws {
  let db = try openCanonicalDatabase(at: tempURL("nodefacts-archived"))
  let archivedID = UUID()
  try db.write { db in
    try Node.insert { Node(id: archivedID, name: "Archived", state: .archived) }.execute(db)
  }
  let all = try NodeFactsQueries.all(db, now: Date())
  #expect(!all.contains { $0.node.id == archivedID })   // active-only population
  let byID = try NodeFactsQueries.facts(for: [archivedID], db, now: Date())
  #expect(byID.first?.node.id == archivedID)             // a tap still resolves it
  #expect(byID.first?.daysDormant == 0)                  // no events → 0
}
