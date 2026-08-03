import Foundation
import Testing
import SQLiteData
@testable import PensieveKit

@discardableResult
private func seed(_ database: any DatabaseWriter, quote: String, label: String, suggestion: String,
                 status: String = "open", daysAgo: Int = 0) throws -> UUID {
  let node = Node(name: "N")
  let source = Source(nodeID: node.id, kind: SourceKind.claudeCode, key: "/src/\(UUID().uuidString)")
  let when = Calendar.current.date(byAdding: .day, value: -daysAgo, to: Date())!
  let ev = Event(nodeID: node.id, sourceID: source.id, occurredAt: when,
                 kind: CaptureKind.ccSession, summary: "s", detailJSON: "{}")
  let le = LooseEnd(nodeID: node.id, sourceEventID: ev.id, text: quote, quote: quote,
                    status: status, label: label, labelSuggestion: suggestion)
  try database.write { database in
    try Node.insert { node }.execute(database)
    try Source.insert { source }.execute(database)
    try Event.insert { ev }.execute(database)
    try LooseEnd.insert { le }.execute(database)
  }
  return le.id
}

@Test func reviewPendingReturnsOnlyUnlabeledSuggestedOpen() throws {
  let database = try openCanonicalDatabase(at: tempURL("rev-filter"))
  let want = try seed(database, quote: "unlabeled with suggestion", label: "", suggestion: LooseEndLabel.salient)
  _ = try seed(database, quote: "already human labeled", label: LooseEndLabel.salient, suggestion: LooseEndLabel.salient)
  _ = try seed(database, quote: "unlabeled no suggestion", label: "", suggestion: "")
  _ = try seed(database, quote: "resolved one", label: "", suggestion: LooseEndLabel.noise, status: "resolved")
  let pending = try SalienceReviewQueries.pending(database, now: Date())
  #expect(pending.map(\.looseEnd.id) == [want])
  #expect(try SalienceReviewQueries.pendingCount(database) == 1)
}

@Test func reviewPendingOrdersSuggestedSalientFirst() throws {
  let database = try openCanonicalDatabase(at: tempURL("rev-order"))
  let noiseOld = try seed(database, quote: "noise suggested older", label: "", suggestion: LooseEndLabel.noise, daysAgo: 10)
  let salientNew = try seed(database, quote: "salient suggested newer", label: "", suggestion: LooseEndLabel.salient, daysAgo: 1)
  let pending = try SalienceReviewQueries.pending(database, now: Date())
  // Salient-suggested first regardless of age; then the noise one.
  #expect(pending.map(\.looseEnd.id) == [salientNew, noiseOld])
}
