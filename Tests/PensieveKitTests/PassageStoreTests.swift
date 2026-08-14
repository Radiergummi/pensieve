import Foundation
import Testing
import SQLiteData
@testable import PensieveKit

@Suite struct PassageStoreTests {
  /// v13 is additive: a store migrated from scratch has the table, and every earlier-schema test
  /// in this suite still opens. Mirrors the v4–v12 migration tests.
  @Test func migrationV13CreatesPassages() throws {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("passages-\(UUID().uuidString).sqlite")
    defer { try? FileManager.default.removeItem(at: url) }
    let database = try openCanonicalDatabase(at: url)

    let node = Node(name: "Pensieve")
    let source = Source(nodeID: node.id, kind: SourceKind.claudeCode, key: "/tmp/x")
    let event = Event(nodeID: node.id, sourceID: source.id, occurredAt: Date(),
                      kind: CaptureKind.ccSession, summary: "session", detailJSON: "{}")
    let passage = Passage(nodeID: node.id, eventID: event.id, turnIndex: 0, messageIndex: 3,
                          role: .prompt, text: "why does background sync die",
                          occurredAt: Date(timeIntervalSince1970: 1_000_000))
    try database.write { database in
      try Node.insert { node }.execute(database)
      try Source.insert { source }.execute(database)
      try Event.insert { event }.execute(database)
      try Passage.insert { passage }.execute(database)
    }

    let stored = try database.read { database in
      try Passage.where { $0.id.eq(passage.id) }.fetchOne(database)
    }
    #expect(stored?.text == "why does background sync die")
    #expect(stored?.role == .prompt)
    #expect(stored?.messageIndex == 3)
  }

  /// Deleting the anchor event takes its passages with it, so a re-ingest cannot orphan rows and
  /// the corpus cannot serve a passage whose session no longer exists.
  @Test func deletingAnEventCascadesToItsPassages() throws {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("passages-\(UUID().uuidString).sqlite")
    defer { try? FileManager.default.removeItem(at: url) }
    let database = try openCanonicalDatabase(at: url)
    let node = Node(name: "Pensieve")
    let source = Source(nodeID: node.id, kind: SourceKind.claudeCode, key: "/tmp/x")
    let event = Event(nodeID: node.id, sourceID: source.id, occurredAt: Date(),
                      kind: CaptureKind.ccSession, summary: "session", detailJSON: "{}")
    try database.write { database in
      try Node.insert { node }.execute(database)
      try Source.insert { source }.execute(database)
      try Event.insert { event }.execute(database)
      try Passage.insert {
        Passage(nodeID: node.id, eventID: event.id, turnIndex: 0, messageIndex: 0,
                role: .prompt, text: "hello", occurredAt: Date())
      }.execute(database)
      try Event.where { $0.id.eq(event.id) }.delete().execute(database)
    }
    let remaining = try database.read { database in try Passage.all.fetchCount(database) }
    #expect(remaining == 0)
  }
}
