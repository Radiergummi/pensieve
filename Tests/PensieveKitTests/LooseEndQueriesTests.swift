import Foundation
import Testing
import SQLiteData
@testable import PensieveKit

@Test func openLooseEndsCarrySourceAge() throws {
  let db = try openCanonicalDatabase(at: tempURL("le-q"))
  let (project, source) = try ProjectResolver(db: db).resolve(path: "/p/x", kind: SourceKind.claudeCode)
  let occurred = Calendar.current.date(byAdding: .day, value: -10, to: Date())!
  let event = Event(projectID: project.id, sourceID: source.id, occurredAt: occurred,
                    kind: CaptureKind.ccSession, summary: "s", detailJSON: "{}", fingerprint: "f")
  try db.write { db in
    try Event.insert { event }.execute(db)
    try LooseEnd.insert {
      LooseEnd(projectID: project.id, sourceEventID: event.id, text: "t",
               quote: "we still need to finish the migration", role: "user", sourceMessageIndex: 0)
    }.execute(db)
  }
  let views = try LooseEndQueries.open(db, projectID: project.id, now: Date())
  #expect(views.count == 1)
  #expect(views.first?.ageDays == 10)
}
