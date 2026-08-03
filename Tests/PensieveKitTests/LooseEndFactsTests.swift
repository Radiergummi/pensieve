import Foundation
import Testing
import SQLiteData
@testable import PensieveKit

@Test func looseEndFactsAllReturnsOpenEndsInActiveNodesWithNodeName() throws {
  let database = try openCanonicalDatabase(at: tempURL("lef-all"))
  let resolver = ProjectResolver(database: database)
  let (a, sa) = try resolver.resolve(path: "/p/lef", kind: SourceKind.claudeCode)
  let ea = Event(nodeID: a.id, sourceID: sa.id, occurredAt: Date(), kind: CaptureKind.ccSession,
                 summary: "s", detailJSON: "{}", fingerprint: "lef1")
  try database.write { database in
    try Event.insert { ea }.execute(database)
    try LooseEnd.insert {
      LooseEnd(nodeID: a.id, sourceEventID: ea.id, text: "wire up the retry", quote: "we should retry")
    }.execute(database)
    try LooseEnd.insert {   // resolved → excluded
      LooseEnd(nodeID: a.id, sourceEventID: ea.id, text: "done item", quote: "q", status: "resolved")
    }.execute(database)
    try LooseEnd.insert {   // confirmed noise → excluded
      LooseEnd(nodeID: a.id, sourceEventID: ea.id, text: "noise item", quote: "q2",
               label: LooseEndLabel.noise)
    }.execute(database)
  }
  let facts = try LooseEndFactsQueries.all(database)
  #expect(facts.count == 1)
  let f = try #require(facts.first)
  #expect(f.text == "wire up the retry")
  #expect(f.quote == "we should retry")
  #expect(f.nodeID == a.id)
  #expect(f.nodeName == a.name)
}

@Test func looseEndFactsAllExcludesEndsWhoseNodeIsArchived() throws {
  let database = try openCanonicalDatabase(at: tempURL("lef-archived"))
  let nodeID = UUID(), sourceID = UUID(), eventID = UUID()
  try database.write { database in
    try Node.insert { Node(id: nodeID, name: "Archived", state: .archived) }.execute(database)
    try Source.insert {
      Source(id: sourceID, nodeID: nodeID, kind: SourceKind.claudeCode, key: "/archived")
    }.execute(database)
    try Event.insert {
      Event(id: eventID, nodeID: nodeID, sourceID: sourceID, occurredAt: Date(), kind: CaptureKind.ccSession,
            summary: "s", detailJSON: "{}", fingerprint: "archived1")
    }.execute(database)
    try LooseEnd.insert {
      LooseEnd(id: UUID(), nodeID: nodeID, sourceEventID: eventID, text: "orphan", quote: "q")
    }.execute(database)
  }
  #expect(try LooseEndFactsQueries.all(database).isEmpty)   // node not active → excluded
}

@Test func looseEndFactsForResolvesKnownIDsAndDropsUnknown() throws {
  let database = try openCanonicalDatabase(at: tempURL("lef-byid"))
  let resolver = ProjectResolver(database: database)
  let (a, sa) = try resolver.resolve(path: "/p/byid", kind: SourceKind.claudeCode)
  let ea = Event(nodeID: a.id, sourceID: sa.id, occurredAt: Date(), kind: CaptureKind.ccSession,
                 summary: "s", detailJSON: "{}", fingerprint: "byid1")
  let openID = UUID(), closedID = UUID()
  try database.write { database in
    try Event.insert { ea }.execute(database)
    try LooseEnd.insert {
      LooseEnd(id: openID, nodeID: a.id, sourceEventID: ea.id, text: "open", quote: "q")
    }.execute(database)
    try LooseEnd.insert {   // a since-closed end STILL resolves by id (degrade: tap opens its node)
      LooseEnd(id: closedID, nodeID: a.id, sourceEventID: ea.id, text: "closed", quote: "q2",
               status: "resolved")
    }.execute(database)
  }
  let facts = try LooseEndFactsQueries.facts(for: [openID, closedID, UUID()], database)
  #expect(facts.count == 2)                                   // unknown dropped; closed still resolves
  #expect(facts.contains { $0.looseEndID == openID && $0.nodeID == a.id && $0.nodeName == a.name })
  #expect(facts.contains { $0.looseEndID == closedID })
}
