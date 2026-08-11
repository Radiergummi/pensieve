import Foundation
import Testing
import SQLiteData
@testable import PensieveKit

@Test func cardsSplitMovedFromQuietAndCarryLooseEnds() throws {
  let database = try openCanonicalDatabase(at: tempURL("briefing"))
  let resolver = ProjectResolver(database: database)
  let (moved, movedSource) = try resolver.resolve(path: "/p/moved", kind: SourceKind.claudeCode)
  let (quiet, quietSource) = try resolver.resolve(path: "/p/quiet", kind: SourceKind.claudeCode)
  let now = Date()
  let since = Calendar.current.date(byAdding: .day, value: -2, to: now)!   // "last visit" = 2 days ago
  let recent = Calendar.current.date(byAdding: .day, value: -1, to: now)!  // after `since`
  let old = Calendar.current.date(byAdding: .day, value: -10, to: now)!    // before `since`
  try database.write { database in
    let recentEvent = Event(nodeID: moved.id, sourceID: movedSource.id, occurredAt: recent, kind: CaptureKind.ccSession,
                   summary: "shipped the thing", detailJSON: "{}", fingerprint: "m1")
    try Event.insert { recentEvent }.execute(database)
    try LooseEnd.insert {
      LooseEnd(nodeID: moved.id, sourceEventID: recentEvent.id, text: "rotate CI keys", quote: "set CI vars",
               role: "user", sourceMessageIndex: 0)
    }.execute(database)
    try Event.insert {
      Event(nodeID: quiet.id, sourceID: quietSource.id, occurredAt: old, kind: CaptureKind.ccSession,
            summary: "old work", detailJSON: "{}", fingerprint: "q1")
    }.execute(database)
  }

  let cards = try BriefingQueries.cards(database, since: since, now: now)

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
  let database = try openCanonicalDatabase(at: tempURL("briefing-empty"))
  let resolver = ProjectResolver(database: database)
  _ = try resolver.resolve(path: "/p/untouched", kind: SourceKind.claudeCode)
  let cards = try BriefingQueries.cards(database, since: Date.distantPast, now: Date())
  #expect(cards.isEmpty)
}

@Test func briefingCardCarriesTheLatestEventTimestamp() throws {
  let database = try openCanonicalDatabase(at: tempURL("briefing-timestamp"))
  let resolver = ProjectResolver(database: database)
  let (testNode, testNodeSource) = try resolver.resolve(path: "/p/brief-stamp", kind: SourceKind.claudeCode)
  let older = Calendar.current.date(byAdding: .day, value: -6, to: Date())!
  let newest = Calendar.current.date(byAdding: .day, value: -1, to: Date())!
  try database.write { database in
    try Event.insert {
      Event(nodeID: testNode.id, sourceID: testNodeSource.id, occurredAt: older,
            kind: CaptureKind.ccSession, summary: "old", detailJSON: "{}", fingerprint: "bt1")
    }.execute(database)
    try Event.insert {
      Event(nodeID: testNode.id, sourceID: testNodeSource.id, occurredAt: newest,
            kind: CaptureKind.gitCommit, summary: "new", detailJSON: "{}", fingerprint: "bt2")
    }.execute(database)
  }
  let since = Calendar.current.date(byAdding: .day, value: -3, to: Date())!
  let cards = try BriefingQueries.cards(database, since: since, now: Date())
  let card = try #require(cards.first { $0.node.id == testNode.id })
  #expect(abs(card.lastActivityAt.timeIntervalSince(newest)) < 0.001)
  #expect(card.movedSince == 1)      // only the newest event is after `since`
  #expect(card.daysDormant == 1)     // unchanged
}
