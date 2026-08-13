import Foundation
import Testing
import SQLiteData
@testable import PensieveKit

/// Seeds one node + source + event + loose end, and returns the loose end's id.
/// File-private on purpose: two other suites already declare a `seedLooseEnd`, and an internal one
/// here would make the call ambiguous in those files.
@discardableResult
private func seedLooseEnd(_ database: any DatabaseWriter, text: String = "t", quote: String = "q",
                          status: LooseEndStatus = .open, label: String = "",
                          resolvedAt: Date? = nil, daysAgo: Int = 0) throws -> UUID {
  let node = Node(name: "N")
  let source = Source(nodeID: node.id, kind: SourceKind.claudeCode, key: "/src/\(UUID().uuidString)")
  let when = Calendar.current.date(byAdding: .day, value: -daysAgo, to: Date())!
  let event = Event(nodeID: node.id, sourceID: source.id, occurredAt: when,
                    kind: CaptureKind.ccSession, summary: "s", detailJSON: "{}")
  let looseEnd = LooseEnd(nodeID: node.id, sourceEventID: event.id, text: text, quote: quote,
                          status: status, label: label, resolvedAt: resolvedAt)
  try database.write { database in
    try Node.insert { node }.execute(database)
    try Source.insert { source }.execute(database)
    try Event.insert { event }.execute(database)
    try LooseEnd.insert { looseEnd }.execute(database)
  }
  return looseEnd.id
}

@Test func looseEndStatusRoundTripsThroughTheStore() throws {
  let database = try openCanonicalDatabase(at: tempURL("les-roundtrip"))
  let openID = try seedLooseEnd(database, quote: "still open")
  let doneID = try seedLooseEnd(database, quote: "finished", status: .done)
  let droppedID = try seedLooseEnd(database, quote: "abandoned", status: .dropped)
  let stored = try database.read { try LooseEnd.all.fetchAll($0) }
  #expect(stored.first { $0.id == openID }?.status == .open)
  #expect(stored.first { $0.id == doneID }?.status == .done)
  #expect(stored.first { $0.id == droppedID }?.status == .dropped)
}

/// The on-disk spelling must stay exactly what the shipped store holds, so no migration is needed
/// for the type change. Reads the raw column, deliberately bypassing the enum.
@Test func looseEndStatusStoresItsRawStringUnchanged() throws {
  let database = try openCanonicalDatabase(at: tempURL("les-raw"))
  try seedLooseEnd(database, quote: "open one")
  try seedLooseEnd(database, quote: "done one", status: .done)
  let raw = try database.read { database in
    try String.fetchAll(database, sql: #"SELECT "status" FROM "looseEnds" ORDER BY "status""#)
  }
  #expect(raw == ["done", "open"])
}

/// The whole feature rests on this: `isOpen` was not edited, and the new states fall out of it.
@Test func isOpenExcludesDoneAndDroppedWithoutBeingEdited() throws {
  let database = try openCanonicalDatabase(at: tempURL("les-isopen"))
  let openID = try seedLooseEnd(database, quote: "open one")
  try seedLooseEnd(database, quote: "done one", status: .done)
  try seedLooseEnd(database, quote: "dropped one", status: .dropped)
  try seedLooseEnd(database, quote: "noisy one", label: LooseEndLabel.noise)
  let open = try database.read { try LooseEnd.where { LooseEnd.isOpen($0) }.fetchAll($0) }
  #expect(open.map(\.id) == [openID])
}

@Test func resolvedAtDefaultsToNilAndPersists() throws {
  let database = try openCanonicalDatabase(at: tempURL("les-resolvedat"))
  let stamp = Date(timeIntervalSince1970: 1_700_000_000)
  try seedLooseEnd(database, quote: "never resolved")
  try seedLooseEnd(database, quote: "resolved", status: .done, resolvedAt: stamp)
  let stored = try database.read { try LooseEnd.all.fetchAll($0) }
  #expect(stored.filter { $0.resolvedAt == nil }.count == 1)
  #expect(stored.compactMap(\.resolvedAt).first.map { Int($0.timeIntervalSince1970) } == 1_700_000_000)
}
