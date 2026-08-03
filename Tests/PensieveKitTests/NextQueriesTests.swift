import Foundation
import Testing
import SQLiteData
@testable import PensieveKit

@Test func nextRanksByLooseEndsThenDormancy() throws {
  let database = try openCanonicalDatabase(at: tempURL("next"))
  let resolver = ProjectResolver(database: database)
  let (nodeA, sourceA) = try resolver.resolve(path: "/p/a", kind: SourceKind.claudeCode)   // 2 loose ends, recent
  let (nodeB, sourceB) = try resolver.resolve(path: "/p/b", kind: SourceKind.claudeCode)   // 0 loose ends, old
  let recent = Date(), old = Calendar.current.date(byAdding: .day, value: -30, to: Date())!
  try database.write { database in
    let eventA = Event(nodeID: nodeA.id, sourceID: sourceA.id, occurredAt: recent, kind: CaptureKind.ccSession,
                   summary: "s", detailJSON: "{}", fingerprint: "a1")
    let eventB = Event(nodeID: nodeB.id, sourceID: sourceB.id, occurredAt: old, kind: CaptureKind.ccSession,
                   summary: "s", detailJSON: "{}", fingerprint: "b1")
    try Event.insert { eventA }.execute(database); try Event.insert { eventB }.execute(database)
    for quote in ["we must finish the auth flow", "don't forget the deploy vars"] {
      try LooseEnd.insert {
        LooseEnd(nodeID: nodeA.id, sourceEventID: eventA.id, text: "t", quote: quote, role: "user", sourceMessageIndex: 0)
      }.execute(database)
    }
  }
  let ranked = try NextQueries.ranked(database, now: Date())
  #expect(ranked.first?.project.id == nodeB.id)   // 0*2+30 = 30 > 2*2+~0 = 4; long dormancy dominates by design
  #expect(ranked.contains { $0.project.id == nodeA.id })
}

@Test func nextExcludesConfirmedNoiseFromOpenLooseEndCount() throws {
  let database = try openCanonicalDatabase(at: tempURL("next-noise"))
  let resolver = ProjectResolver(database: database)
  let (nodeA, sourceA) = try resolver.resolve(path: "/p/noise", kind: SourceKind.claudeCode)
  let eventA = Event(nodeID: nodeA.id, sourceID: sourceA.id, occurredAt: Date(), kind: CaptureKind.ccSession,
                 summary: "s", detailJSON: "{}", fingerprint: "n1")
  try database.write { database in
    try Event.insert { eventA }.execute(database)
    try LooseEnd.insert {
      LooseEnd(nodeID: nodeA.id, sourceEventID: eventA.id, text: "t1", quote: "unlabeled item")
    }.execute(database)
    try LooseEnd.insert {
      LooseEnd(nodeID: nodeA.id, sourceEventID: eventA.id, text: "t2", quote: "confirmed noise",
               label: LooseEndLabel.noise)
    }.execute(database)
    try LooseEnd.insert {
      LooseEnd(nodeID: nodeA.id, sourceEventID: eventA.id, text: "t3", quote: "only suggested noise",
               labelSuggestion: LooseEndLabel.noise)
    }.execute(database)
  }
  let ranked = try NextQueries.ranked(database, now: Date())
  let item = try #require(ranked.first { $0.project.id == nodeA.id })
  #expect(item.openLooseEnds == 2)   // confirmed-noise excluded; unlabeled + suggestion-only-noise kept
}
