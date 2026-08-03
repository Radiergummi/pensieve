import Foundation
import Testing
import SQLiteData
@testable import PensieveKit

@Test func bucketsRankedItemsIntoSmartLists() throws {
  let database = try openCanonicalDatabase(at: tempURL("smartlists"))
  let resolver = ProjectResolver(database: database)
  let (recentNode, rs) = try resolver.resolve(path: "/p/recent", kind: SourceKind.claudeCode)
  let (oldNode, os) = try resolver.resolve(path: "/p/old", kind: SourceKind.claudeCode)
  let now = Date()
  let old = Calendar.current.date(byAdding: .day, value: -30, to: now)!
  try database.write { database in
    try Event.insert {
      Event(nodeID: recentNode.id, sourceID: rs.id, occurredAt: now, kind: CaptureKind.ccSession,
            summary: "s", detailJSON: "{}", fingerprint: "r1")
    }.execute(database)
    try Event.insert {
      Event(nodeID: oldNode.id, sourceID: os.id, occurredAt: old, kind: CaptureKind.ccSession,
            summary: "s", detailJSON: "{}", fingerprint: "o1")
    }.execute(database)
  }

  let lists = try SmartLists.compute(database, now: now, dormantAfterDays: 14, activeWithinDays: 3)

  #expect(lists.whatsNext.count == 2)                                   // all active nodes
  #expect(lists.dormant.map(\.project.id) == [oldNode.id])             // only the 30-day-old one
  #expect(lists.recentlyActive.map(\.project.id) == [recentNode.id])   // only the fresh one
}
