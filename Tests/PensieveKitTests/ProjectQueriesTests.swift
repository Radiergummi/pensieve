import Foundation
import Testing
import SQLiteData
@testable import PensieveKit

@Test func statusReturnsRecentEvents() throws {
  let database = try openCanonicalDatabase(at: tempURL("q"))
  let (project, source) = try ProjectResolver(database: database).resolve(path: "/p/colibri", kind: "gitRepo")
  try database.write { database in
    try Event.insert {
      Event(nodeID: project.id, sourceID: source.id, occurredAt: Date(),
            kind: "git.commit", summary: "did a thing", detailJSON: "{}")
    }.execute(database)
  }

  let status = try ProjectQueries.status(database, name: "colibri", limit: 10)
  #expect(status?.recentEvents.first?.summary == "did a thing")
}
