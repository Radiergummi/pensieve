import Foundation
import Testing
import SQLiteData
@testable import PensieveKit

@Test func v3AddsColumnsAndRoundTrips() throws {
  let database = try openCanonicalDatabase(at: tempURL("v3"))
  let project = Node(name: "Colibri")
  let source = Source(nodeID: project.id, kind: SourceKind.claudeCode, key: "/p/colibri")
  let event = Event(nodeID: project.id, sourceID: source.id, occurredAt: Date(),
                    kind: CaptureKind.ccSession, summary: "s", detailJSON: "{}",
                    fingerprint: "fp-1", extractedAt: nil)
  try database.write { database in
    try Node.insert { project }.execute(database)
    try Source.insert { source }.execute(database)
    try Event.insert { event }.execute(database)
    try LooseEnd.insert {
      LooseEnd(nodeID: project.id, sourceEventID: event.id, text: "do X",
               quote: "we still need to do X", role: "user", sourceMessageIndex: 3)
    }.execute(database)
  }
  let le = try database.read { database in try LooseEnd.all.fetchAll(database) }.first
  #expect(le?.role == "user")
  #expect(le?.sourceMessageIndex == 3)
  let ev = try database.read { database in try Event.all.fetchAll(database) }.first
  #expect(ev?.fingerprint == "fp-1")
  #expect(ev?.extractedAt == nil)
}

@Test func v3UniqueFingerprintIndexRejectsDuplicate() throws {
  let database = try openCanonicalDatabase(at: tempURL("v3dup"))
  let project = Node(name: "P")
  let source = Source(nodeID: project.id, kind: SourceKind.gitRepo, key: "/p")
  try database.write { database in
    try Node.insert { project }.execute(database)
    try Source.insert { source }.execute(database)
    try Event.insert {
      Event(nodeID: project.id, sourceID: source.id, occurredAt: Date(),
            kind: CaptureKind.gitCommit, summary: "a", detailJSON: "{}", fingerprint: "dup")
    }.execute(database)
  }
  #expect(throws: (any Error).self) {
    try database.write { database in
      try Event.insert {
        Event(nodeID: project.id, sourceID: source.id, occurredAt: Date(),
              kind: CaptureKind.gitCommit, summary: "b", detailJSON: "{}", fingerprint: "dup")
      }.execute(database)
    }
  }
}
