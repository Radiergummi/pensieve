import Foundation
import Testing
import SQLiteData
@testable import PensieveKit

// `looseEnds.sourceEventID` has an FK to `events.id`, and `events.sourceID` to `sources.id`, so a
// loose end needs the full Node -> Source -> Event chain (unique source key per call).
private func seedLooseEnd(_ database: any DatabaseWriter, quote: String) throws -> UUID {
  let node = Node(name: "N")
  let source = Source(nodeID: node.id, kind: SourceKind.claudeCode, key: "/src/\(UUID().uuidString)")
  let event = Event(nodeID: node.id, sourceID: source.id, occurredAt: Date(),
                 kind: CaptureKind.ccSession, summary: "s", detailJSON: "{}")
  let looseEnd = LooseEnd(nodeID: node.id, sourceEventID: event.id, text: quote, quote: quote)
  try database.write { database in
    try Node.insert { node }.execute(database)
    try Source.insert { source }.execute(database)
    try Event.insert { event }.execute(database)
    try LooseEnd.insert { looseEnd }.execute(database)
  }
  return looseEnd.id
}

@Test func setLabelConfirmsAndClears() throws {
  let database = try openCanonicalDatabase(at: tempURL("cmd-set"))
  let id = try seedLooseEnd(database, quote: "migrate later")
  #expect(try LooseEndCommands.setLabel(database, id: id, label: LooseEndLabel.salient) == true)
  #expect(try database.read { database in try LooseEnd.where { $0.id.eq(id) }.fetchOne(database) }?.label == "salient")
  // "" clears it
  _ = try LooseEndCommands.setLabel(database, id: id, label: LooseEndLabel.unlabeled)
  #expect(try database.read { database in try LooseEnd.where { $0.id.eq(id) }.fetchOne(database) }?.label == "")
}

@Test func setLabelReturnsFalseForUnknownID() throws {
  let database = try openCanonicalDatabase(at: tempURL("cmd-unknown"))
  #expect(try LooseEndCommands.setLabel(database, id: UUID(), label: LooseEndLabel.noise) == false)
}

@Test func suggestNeverTouchesConfirmedLabel() throws {
  let database = try openCanonicalDatabase(at: tempURL("cmd-suggest"))
  let id = try seedLooseEnd(database, quote: "read the spec")
  _ = try LooseEndCommands.suggest(database, id: id, label: LooseEndLabel.noise)
  let row = try database.read { database in try LooseEnd.where { $0.id.eq(id) }.fetchOne(database) }
  #expect(row?.labelSuggestion == "noise")
  #expect(row?.label == "")   // suggestion must not confirm
}

@Test func corpusReturnsOnlyConfirmedLabels() throws {
  let database = try openCanonicalDatabase(at: tempURL("cmd-corpus"))
  let looseEndA = try seedLooseEnd(database, quote: "migrate the auth tables later")
  let looseEndB = try seedLooseEnd(database, quote: "read the spec now")
  let looseEndC = try seedLooseEnd(database, quote: "only suggested, not confirmed")
  _ = try LooseEndCommands.setLabel(database, id: looseEndA, label: LooseEndLabel.salient)
  _ = try LooseEndCommands.setLabel(database, id: looseEndB, label: LooseEndLabel.noise)
  _ = try LooseEndCommands.suggest(database, id: looseEndC, label: LooseEndLabel.salient) // suggestion only -> excluded
  let corpus = try LooseEndCommands.corpus(database)
  #expect(Set(corpus.map { $0.quote }) == ["migrate the auth tables later", "read the spec now"])
  #expect(corpus.first { $0.quote == "migrate the auth tables later" }?.label == "salient")
}

@Test func importLabelsMatchesByNormalizedQuoteAndSkipsUnmatched() throws {
  let database = try openCanonicalDatabase(at: tempURL("cmd-import"))
  let looseEndA = try seedLooseEnd(database, quote: "we should migrate the auth tables later")
  let looseEndB = try seedLooseEnd(database, quote: "read the spec now")
  // Entry quote differs only by whitespace; entry 3 matches nothing.
  let result = try LooseEndCommands.importLabels(database, [
    (quote: "we should migrate   the auth tables later", label: LooseEndLabel.salient),
    (quote: "read the spec now", label: LooseEndLabel.noise),
    (quote: "this quote is not in the store at all", label: LooseEndLabel.salient),
  ])
  #expect(result.matched == 2)
  #expect(result.skipped == 1)
  #expect(try database.read { database in try LooseEnd.where { $0.id.eq(looseEndA) }.fetchOne(database) }?.label == "salient")
  #expect(try database.read { database in try LooseEnd.where { $0.id.eq(looseEndB) }.fetchOne(database) }?.label == "noise")
}

@Test func importLabelsIsIdempotent() throws {
  let database = try openCanonicalDatabase(at: tempURL("cmd-import-idem"))
  let looseEndA = try seedLooseEnd(database, quote: "park the canvas idea for now")
  _ = try LooseEndCommands.importLabels(database, [(quote: "park the canvas idea for now", label: LooseEndLabel.salient)])
  let second = try LooseEndCommands.importLabels(database, [(quote: "park the canvas idea for now", label: LooseEndLabel.salient)])
  #expect(second.matched == 1)   // matches again; a no-op write
  #expect(try database.read { database in try LooseEnd.where { $0.id.eq(looseEndA) }.fetchOne(database) }?.label == "salient")
}
