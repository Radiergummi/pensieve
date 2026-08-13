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

/// `ranked` already fetches the latest event to derive `daysDormant`; it now keeps the `Date` too, so
/// the menu-bar row renders recency from the item instead of a second whole-database aggregate.
///
/// Three events, inserted OUT of chronological order on purpose. A query that dropped the `order`
/// clause, or read the first row instead of the last, still returns a non-nil `Date` on a
/// single-event fixture — so asserting "carries a date" would pass on a broken implementation. This
/// pins WHICH date.
@Test func rankedCarriesTheLatestActivityDateNotTheFirst() throws {
  let database = try openCanonicalDatabase(at: tempURL("next-last-activity"))
  let resolver = ProjectResolver(database: database)
  let (node, source) = try resolver.resolve(path: "/p/recency", kind: SourceKind.claudeCode)
  let middle = Calendar.current.date(byAdding: .day, value: -5, to: Date())!
  let oldest = Calendar.current.date(byAdding: .day, value: -12, to: Date())!
  let newest = Calendar.current.date(byAdding: .day, value: -1, to: Date())!
  try database.write { database in
    for (index, occurredAt) in [middle, newest, oldest].enumerated() {
      try Event.insert {
        Event(nodeID: node.id, sourceID: source.id, occurredAt: occurredAt, kind: CaptureKind.ccSession,
              summary: "s", detailJSON: "{}", fingerprint: "recency-\(index)")
      }.execute(database)
    }
  }
  let item = try #require(try NextQueries.ranked(database, now: Date()).first { $0.project.id == node.id })
  // Tolerance, not equality: a Date does not survive the SQLite round-trip bit-for-bit (the stored
  // form has second resolution), so `==` fails against two values that both print as the same
  // instant. One second still separates the three fixtures, which sit a day or more apart — the
  // discrimination this test exists for is intact.
  #expect(abs(item.lastActivityAt.timeIntervalSince(newest)) < 1)
  // The derived Int and the carried Date must describe the same event, or the row and the ranking
  // would disagree about how stale the same project is.
  #expect(item.daysDormant == 1)
}
