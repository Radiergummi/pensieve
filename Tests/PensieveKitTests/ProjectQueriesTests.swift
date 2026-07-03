import Foundation
import Testing
import SQLiteData
@testable import PensieveKit

@Test func statusReturnsRecentEvents() throws {
  let db = try openCanonicalDatabase(at: tempURL("q"))
  let (project, source) = try ProjectResolver(db: db).resolve(path: "/p/colibri", kind: "gitRepo")
  try db.write { db in
    try Event.insert {
      Event(projectID: project.id, sourceID: source.id, occurredAt: Date(),
            kind: "git.commit", summary: "did a thing", detailJSON: "{}")
    }.execute(db)
  }

  let status = try ProjectQueries.status(db, name: "colibri", limit: 10)
  #expect(status?.recentEvents.first?.summary == "did a thing")
}
