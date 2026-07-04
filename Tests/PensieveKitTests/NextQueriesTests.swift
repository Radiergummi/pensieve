import Foundation
import Testing
import SQLiteData
@testable import PensieveKit

@Test func nextRanksByLooseEndsThenDormancy() throws {
  let db = try openCanonicalDatabase(at: tempURL("next"))
  let resolver = ProjectResolver(db: db)
  let (a, sa) = try resolver.resolve(path: "/p/a", kind: SourceKind.claudeCode)   // 2 loose ends, recent
  let (b, sb) = try resolver.resolve(path: "/p/b", kind: SourceKind.claudeCode)   // 0 loose ends, old
  let recent = Date(), old = Calendar.current.date(byAdding: .day, value: -30, to: Date())!
  try db.write { db in
    let ea = Event(nodeID: a.id, sourceID: sa.id, occurredAt: recent, kind: CaptureKind.ccSession,
                   summary: "s", detailJSON: "{}", fingerprint: "a1")
    let eb = Event(nodeID: b.id, sourceID: sb.id, occurredAt: old, kind: CaptureKind.ccSession,
                   summary: "s", detailJSON: "{}", fingerprint: "b1")
    try Event.insert { ea }.execute(db); try Event.insert { eb }.execute(db)
    for q in ["we must finish the auth flow", "don't forget the deploy vars"] {
      try LooseEnd.insert {
        LooseEnd(nodeID: a.id, sourceEventID: ea.id, text: "t", quote: q, role: "user", sourceMessageIndex: 0)
      }.execute(db)
    }
  }
  let ranked = try NextQueries.ranked(db, now: Date())
  #expect(ranked.first?.project.id == b.id)   // 0*2+30 = 30 > 2*2+~0 = 4; long dormancy dominates by design
  #expect(ranked.contains { $0.project.id == a.id })
}
