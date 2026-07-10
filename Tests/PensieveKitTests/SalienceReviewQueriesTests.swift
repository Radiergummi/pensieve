import Foundation
import Testing
import SQLiteData
@testable import PensieveKit

@discardableResult
private func seed(_ db: any DatabaseWriter, quote: String, label: String, suggestion: String,
                 status: String = "open", daysAgo: Int = 0) throws -> UUID {
  let node = Node(name: "N")
  let source = Source(nodeID: node.id, kind: SourceKind.claudeCode, key: "/src/\(UUID().uuidString)")
  let when = Calendar.current.date(byAdding: .day, value: -daysAgo, to: Date())!
  let ev = Event(nodeID: node.id, sourceID: source.id, occurredAt: when,
                 kind: CaptureKind.ccSession, summary: "s", detailJSON: "{}")
  let le = LooseEnd(nodeID: node.id, sourceEventID: ev.id, text: quote, quote: quote,
                    status: status, label: label, labelSuggestion: suggestion)
  try db.write { db in
    try Node.insert { node }.execute(db)
    try Source.insert { source }.execute(db)
    try Event.insert { ev }.execute(db)
    try LooseEnd.insert { le }.execute(db)
  }
  return le.id
}

@Test func reviewPendingReturnsOnlyUnlabeledSuggestedOpen() throws {
  let db = try openCanonicalDatabase(at: tempURL("rev-filter"))
  let want = try seed(db, quote: "unlabeled with suggestion", label: "", suggestion: LooseEndLabel.salient)
  _ = try seed(db, quote: "already human labeled", label: LooseEndLabel.salient, suggestion: LooseEndLabel.salient)
  _ = try seed(db, quote: "unlabeled no suggestion", label: "", suggestion: "")
  _ = try seed(db, quote: "resolved one", label: "", suggestion: LooseEndLabel.noise, status: "resolved")
  let pending = try SalienceReviewQueries.pending(db, now: Date())
  #expect(pending.map(\.looseEnd.id) == [want])
  #expect(try SalienceReviewQueries.pendingCount(db) == 1)
}

@Test func reviewPendingOrdersSuggestedSalientFirst() throws {
  let db = try openCanonicalDatabase(at: tempURL("rev-order"))
  let noiseOld = try seed(db, quote: "noise suggested older", label: "", suggestion: LooseEndLabel.noise, daysAgo: 10)
  let salientNew = try seed(db, quote: "salient suggested newer", label: "", suggestion: LooseEndLabel.salient, daysAgo: 1)
  let pending = try SalienceReviewQueries.pending(db, now: Date())
  // Salient-suggested first regardless of age; then the noise one.
  #expect(pending.map(\.looseEnd.id) == [salientNew, noiseOld])
}
