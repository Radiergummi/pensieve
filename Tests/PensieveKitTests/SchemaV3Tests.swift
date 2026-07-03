import Foundation
import Testing
import SQLiteData
@testable import PensieveKit

@Test func v3AddsColumnsAndRoundTrips() throws {
  let db = try openCanonicalDatabase(at: tempURL("v3"))
  let project = Project(name: "Colibri")
  let source = Source(projectID: project.id, kind: SourceKind.claudeCode, key: "/p/colibri")
  let event = Event(projectID: project.id, sourceID: source.id, occurredAt: Date(),
                    kind: CaptureKind.ccSession, summary: "s", detailJSON: "{}",
                    fingerprint: "fp-1", extractedAt: nil)
  try db.write { db in
    try Project.insert { project }.execute(db)
    try Source.insert { source }.execute(db)
    try Event.insert { event }.execute(db)
    try LooseEnd.insert {
      LooseEnd(projectID: project.id, sourceEventID: event.id, text: "do X",
               quote: "we still need to do X", role: "user", sourceMessageIndex: 3)
    }.execute(db)
  }
  let le = try db.read { db in try LooseEnd.all.fetchAll(db) }.first
  #expect(le?.role == "user")
  #expect(le?.sourceMessageIndex == 3)
  let ev = try db.read { db in try Event.all.fetchAll(db) }.first
  #expect(ev?.fingerprint == "fp-1")
  #expect(ev?.extractedAt == nil)
}

@Test func v3UniqueFingerprintIndexRejectsDuplicate() throws {
  let db = try openCanonicalDatabase(at: tempURL("v3dup"))
  let project = Project(name: "P")
  let source = Source(projectID: project.id, kind: SourceKind.gitRepo, key: "/p")
  try db.write { db in
    try Project.insert { project }.execute(db)
    try Source.insert { source }.execute(db)
    try Event.insert {
      Event(projectID: project.id, sourceID: source.id, occurredAt: Date(),
            kind: CaptureKind.gitCommit, summary: "a", detailJSON: "{}", fingerprint: "dup")
    }.execute(db)
  }
  #expect(throws: (any Error).self) {
    try db.write { db in
      try Event.insert {
        Event(projectID: project.id, sourceID: source.id, occurredAt: Date(),
              kind: CaptureKind.gitCommit, summary: "b", detailJSON: "{}", fingerprint: "dup")
      }.execute(db)
    }
  }
}
