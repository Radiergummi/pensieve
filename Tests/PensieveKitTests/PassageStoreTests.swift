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

/// The load-bearing case. An in-progress session is re-ingested as it grows: the EVENT is a
/// duplicate, but the transcript has new messages, so passages must be rewritten rather than skipped
/// or duplicated. A test that ingested only once would pass with the delete removed.
///
/// Written in the idiom `IngesterTests` / `IngesterDropTests` / `StrandBirthTests` already use —
/// `tempURL`, a real `CaptureSpool`, a real committed repo for attribution, and a transcript named
/// `<sessionID>.jsonl` (the parser derives the id from the FILENAME, not the content). There are no
/// harness structs in this suite; do not add the first one.
@Test func reIngestingAGrownSessionReplacesItsPassagesRatherThanDuplicating() async throws {
  let (repo, _) = try makeCommittedRepo()
  let spool = try CaptureSpool(at: tempURL("passage-spool"))
  let database = try openCanonicalDatabase(at: tempURL("passage-canon"))

  let sessionID = UUID().uuidString
  let transcript = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("\(sessionID).jsonl")
  func userLine(_ text: String) -> String {
    """
    {"type":"user","cwd":"\(repo.path)","sessionId":"\(sessionID)",\
    "timestamp":"2026-06-30T10:00:00Z","message":{"role":"user","content":"\(text)"}}
    """
  }
  func assistantLine(_ text: String) -> String {
    """
    {"type":"assistant","sessionId":"\(sessionID)","timestamp":"2026-06-30T10:00:01Z",\
    "message":{"role":"assistant","content":[{"type":"text","text":"\(text)"}]}}
    """
  }
  func ingest() async throws {
    try spool.append(kind: CaptureKind.ccSession,
                     payload: try encodeJSON(SessionRefPayload(transcriptPath: transcript.path)))
    _ = try await Ingester(spool: spool, database: database).drain()
  }
  func passageTexts() async throws -> [String] {
    try await database.read { database in try Passage.all.fetchAll(database) }.map(\.text)
  }

  var lines = [userLine("first real question about the sync agent"),
               assistantLine("First substantive answer about launchd.")]
  try lines.joined(separator: "\n").write(to: transcript, atomically: true, encoding: .utf8)
  try await ingest()
  #expect(try await passageTexts().count == 2)

  // The session grows and is re-spooled. Same sessionID, so the EVENT dedupes — but the transcript
  // now has two more turns, and those must appear.
  lines += [userLine("second real question about the search index"),
            assistantLine("Second substantive answer about FTS5.")]
  try lines.joined(separator: "\n").write(to: transcript, atomically: true, encoding: .utf8)
  try await ingest()

  let afterSecond = try await passageTexts()
  #expect(afterSecond.count == 4, "the grown session contributes its new turns")
  #expect(Set(afterSecond).count == 4, "and does not duplicate the turns it already had")
  let events = try await database.read { database in
    try Event.where { $0.kind.eq(CaptureKind.ccSession) }.fetchAll(database)
  }
  #expect(events.count == 1, "still one event")
}
