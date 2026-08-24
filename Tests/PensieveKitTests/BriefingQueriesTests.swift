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

/// The Briefing card and MCP's `whats_next` must cite the SAME loose end for the same node.
///
/// They did not. The card took the oldest SOURCE EVENT (`LooseEndQueries.open(nodeID:).first`);
/// `SessionContextQueries.rankedContext` ordered by `LooseEnd.createdAt`, which is *ingest* time and
/// therefore arbitrary within one drain — every end mined from a session is written in the same pass.
///
/// The fixture inverts the two orderings deliberately: the end whose source event is OLDER is
/// written to the store SECOND, so `createdAt` order and source-event order disagree. Under the old
/// rule the app cited "older source" and MCP cited "newer source"; a fixture where the two orders
/// coincide would pass either way.
@Test func briefingAndMCPCiteTheSameTopLooseEnd() async throws {
  let database = try openCanonicalDatabase(at: tempURL("briefing-top-agreement"))
  let resolver = ProjectResolver(database: database)
  let (node, source) = try resolver.resolve(path: "/p/agree", kind: SourceKind.claudeCode)
  let older = Calendar.current.date(byAdding: .day, value: -8, to: Date())!
  let newer = Calendar.current.date(byAdding: .day, value: -2, to: Date())!
  let olderEvent = Event(nodeID: node.id, sourceID: source.id, occurredAt: older,
                         kind: CaptureKind.ccSession, summary: "old session", detailJSON: "{}",
                         fingerprint: "ta1")
  let newerEvent = Event(nodeID: node.id, sourceID: source.id, occurredAt: newer,
                         kind: CaptureKind.ccSession, summary: "new session", detailJSON: "{}",
                         fingerprint: "ta2")
  try await database.write { database in
    try Event.insert { olderEvent }.execute(database)
    try Event.insert { newerEvent }.execute(database)
    // Inserted newest-source FIRST, so `createdAt` ascending picks the WRONG one.
    try LooseEnd.insert {
      LooseEnd(nodeID: node.id, sourceEventID: newerEvent.id, text: "from the newer session",
               quote: "newer quote", role: "user", sourceMessageIndex: 0,
               createdAt: Date(timeIntervalSince1970: 1_000))
    }.execute(database)
    try LooseEnd.insert {
      LooseEnd(nodeID: node.id, sourceEventID: olderEvent.id, text: "from the older session",
               quote: "older quote", role: "user", sourceMessageIndex: 0,
               createdAt: Date(timeIntervalSince1970: 2_000))
    }.execute(database)
  }

  let card = try #require(try BriefingQueries.cards(database, since: Date.distantPast, now: Date())
    .first { $0.node.id == node.id })
  let mcpItem = try #require(try SessionContextQueries.rankedContext(
    limit: 10, context: nil, database, now: Date()).first { $0.nodeID == node.id })

  // The meaningful ordering — oldest source event — on both surfaces.
  #expect(card.topLooseEnd == "from the older session")
  #expect(mcpItem.topLooseEnd == "older quote")
  // The two surfaces render different FIELDS of the same loose end (text vs verbatim quote), so
  // agreement is asserted by pinning both to the one end, not by comparing the strings.
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
