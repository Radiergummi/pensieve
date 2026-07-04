import Foundation
import Testing
import SQLiteData
@testable import PensieveKit

@Test func allTablesRoundTrip() throws {
  let db = try openCanonicalDatabase(at: tempURL("pensieve-schema"))

  let project = Node(name: "Colibri")
  let source = Source(nodeID: project.id, kind: "gitRepo", key: "/Users/moritz/Projects/colibri")
  let event = Event(nodeID: project.id, sourceID: source.id, occurredAt: Date(),
                    kind: "git.commit", summary: "init", detailJSON: "{}")
  try db.write { db in
    try Node.insert { project }.execute(db)
    try Source.insert { source }.execute(db)
    try Event.insert { event }.execute(db)
  }
  let events = try db.read { db in try Event.all.fetchAll(db) }
  #expect(events.first?.summary == "init")
  #expect(events.first?.nodeID == project.id)
}
