import Foundation
import Testing
import SQLiteData
@testable import PensieveKit

@Test func allTablesRoundTrip() throws {
  let url = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("pensieve-schema-\(UUID().uuidString).sqlite")
  let db = try openCanonicalDatabase(at: url)

  let project = Project(name: "Colibri")
  let source = Source(projectID: project.id, kind: "gitRepo", key: "/Users/moritz/Projects/colibri")
  let event = Event(projectID: project.id, sourceID: source.id, occurredAt: Date(),
                    kind: "git.commit", summary: "init", detailJSON: "{}")
  try db.write { db in
    try Project.insert { project }.execute(db)
    try Source.insert { source }.execute(db)
    try Event.insert { event }.execute(db)
  }
  let events = try db.read { db in try Event.all.fetchAll(db) }
  #expect(events.first?.summary == "init")
  #expect(events.first?.projectID == project.id)
}
