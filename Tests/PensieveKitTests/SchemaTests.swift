import Foundation
import Testing
import SQLiteData
@testable import PensieveKit

@Test func allTablesRoundTrip() throws {
  let database = try openCanonicalDatabase(at: tempURL("pensieve-schema"))

  let project = Node(name: "Colibri")
  let source = Source(nodeID: project.id, kind: "gitRepo", key: "/Users/moritz/Projects/colibri")
  let event = Event(nodeID: project.id, sourceID: source.id, occurredAt: Date(),
                    kind: "git.commit", summary: "init", detailJSON: "{}")
  try database.write { database in
    try Node.insert { project }.execute(database)
    try Source.insert { source }.execute(database)
    try Event.insert { event }.execute(database)
  }
  let events = try database.read { database in try Event.all.fetchAll(database) }
  #expect(events.first?.summary == "init")
  #expect(events.first?.nodeID == project.id)
}
