import Foundation
import Testing
import SQLiteData
@testable import PensieveKit

@Test func cardsSplitMovedFromQuietAndCarryLooseEnds() throws {
  let db = try openCanonicalDatabase(at: tempURL("briefing"))
  let resolver = ProjectResolver(db: db)
  let (moved, ms) = try resolver.resolve(path: "/p/moved", kind: SourceKind.claudeCode)
  let (quiet, qs) = try resolver.resolve(path: "/p/quiet", kind: SourceKind.claudeCode)
  let now = Date()
  let since = Calendar.current.date(byAdding: .day, value: -2, to: now)!   // "last visit" = 2 days ago
  let recent = Calendar.current.date(byAdding: .day, value: -1, to: now)!  // after `since`
  let old = Calendar.current.date(byAdding: .day, value: -10, to: now)!    // before `since`
  try db.write { db in
    let e1 = Event(nodeID: moved.id, sourceID: ms.id, occurredAt: recent, kind: CaptureKind.ccSession,
                   summary: "shipped the thing", detailJSON: "{}", fingerprint: "m1")
    try Event.insert { e1 }.execute(db)
    try LooseEnd.insert {
      LooseEnd(nodeID: moved.id, sourceEventID: e1.id, text: "rotate CI keys", quote: "set CI vars",
               role: "user", sourceMessageIndex: 0)
    }.execute(db)
    try Event.insert {
      Event(nodeID: quiet.id, sourceID: qs.id, occurredAt: old, kind: CaptureKind.ccSession,
            summary: "old work", detailJSON: "{}", fingerprint: "q1")
    }.execute(db)
  }

  let cards = try BriefingQueries.cards(db, since: since, now: now)

  #expect(cards.count == 2)
  #expect(cards.first?.node.id == moved.id)            // moved sorts before quiet
  let movedCard = try #require(cards.first)
  #expect(movedCard.movedSince == 1)
  #expect(movedCard.latestSummary == "shipped the thing")
  #expect(movedCard.openLooseEnds == 1)
  #expect(movedCard.topLooseEnd == "rotate CI keys")
  let quietCard = try #require(cards.last)
  #expect(quietCard.movedSince == 0)                   // its only event predates `since`
  #expect(quietCard.topLooseEnd == nil)
}

@Test func nodeWithNoEventsIsSkipped() throws {
  let db = try openCanonicalDatabase(at: tempURL("briefing-empty"))
  let resolver = ProjectResolver(db: db)
  _ = try resolver.resolve(path: "/p/untouched", kind: SourceKind.claudeCode)
  let cards = try BriefingQueries.cards(db, since: Date.distantPast, now: Date())
  #expect(cards.isEmpty)
}
