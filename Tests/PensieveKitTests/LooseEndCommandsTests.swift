import Foundation
import Testing
import SQLiteData
@testable import PensieveKit

// `looseEnds.sourceEventID` has an FK to `events.id`, and `events.sourceID` to `sources.id`, so a
// loose end needs the full Node -> Source -> Event chain (unique source key per call).
private func seedLooseEnd(_ db: any DatabaseWriter, quote: String) throws -> UUID {
  let node = Node(name: "N")
  let source = Source(nodeID: node.id, kind: SourceKind.claudeCode, key: "/src/\(UUID().uuidString)")
  let ev = Event(nodeID: node.id, sourceID: source.id, occurredAt: Date(),
                 kind: CaptureKind.ccSession, summary: "s", detailJSON: "{}")
  let le = LooseEnd(nodeID: node.id, sourceEventID: ev.id, text: quote, quote: quote)
  try db.write { db in
    try Node.insert { node }.execute(db)
    try Source.insert { source }.execute(db)
    try Event.insert { ev }.execute(db)
    try LooseEnd.insert { le }.execute(db)
  }
  return le.id
}

@Test func setLabelConfirmsAndClears() throws {
  let db = try openCanonicalDatabase(at: tempURL("cmd-set"))
  let id = try seedLooseEnd(db, quote: "migrate later")
  #expect(try LooseEndCommands.setLabel(db, id: id, label: LooseEndLabel.salient) == true)
  #expect(try db.read { db in try LooseEnd.where { $0.id.eq(id) }.fetchOne(db) }?.label == "salient")
  // "" clears it
  _ = try LooseEndCommands.setLabel(db, id: id, label: LooseEndLabel.unlabeled)
  #expect(try db.read { db in try LooseEnd.where { $0.id.eq(id) }.fetchOne(db) }?.label == "")
}

@Test func setLabelReturnsFalseForUnknownID() throws {
  let db = try openCanonicalDatabase(at: tempURL("cmd-unknown"))
  #expect(try LooseEndCommands.setLabel(db, id: UUID(), label: LooseEndLabel.noise) == false)
}

@Test func suggestNeverTouchesConfirmedLabel() throws {
  let db = try openCanonicalDatabase(at: tempURL("cmd-suggest"))
  let id = try seedLooseEnd(db, quote: "read the spec")
  _ = try LooseEndCommands.suggest(db, id: id, label: LooseEndLabel.noise)
  let row = try db.read { db in try LooseEnd.where { $0.id.eq(id) }.fetchOne(db) }
  #expect(row?.labelSuggestion == "noise")
  #expect(row?.label == "")   // suggestion must not confirm
}

@Test func corpusReturnsOnlyConfirmedLabels() throws {
  let db = try openCanonicalDatabase(at: tempURL("cmd-corpus"))
  let a = try seedLooseEnd(db, quote: "migrate the auth tables later")
  let b = try seedLooseEnd(db, quote: "read the spec now")
  let c = try seedLooseEnd(db, quote: "only suggested, not confirmed")
  _ = try LooseEndCommands.setLabel(db, id: a, label: LooseEndLabel.salient)
  _ = try LooseEndCommands.setLabel(db, id: b, label: LooseEndLabel.noise)
  _ = try LooseEndCommands.suggest(db, id: c, label: LooseEndLabel.salient) // suggestion only -> excluded
  let corpus = try LooseEndCommands.corpus(db)
  #expect(Set(corpus.map { $0.quote }) == ["migrate the auth tables later", "read the spec now"])
  #expect(corpus.first { $0.quote == "migrate the auth tables later" }?.label == "salient")
}
