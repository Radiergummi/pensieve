import Foundation
import Testing
import SQLiteData
@testable import PensieveKit

@Suite struct PassageStoreTests {
  /// v13 is additive: a store migrated from scratch has the table, and every earlier-schema test
  /// in this suite still opens. Mirrors the v4–v12 migration tests.
  @Test func migrationV13CreatesPassages() throws {
    let database = try openCanonicalDatabase(at: tempURL("passages"))

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
    let database = try openCanonicalDatabase(at: tempURL("passages"))
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

/// The JSONL fixture the two ingest tests below share. File-private free functions rather than a
/// harness struct, matching `IngesterTests` / `IngesterDropTests` / `StrandBirthTests`: the two
/// tests had verbatim copies, and the transcript wire shape is the thing most likely to move.
private func userLine(_ text: String, sessionID: String, cwd: String) -> String {
  """
  {"type":"user","cwd":"\(cwd)","sessionId":"\(sessionID)",\
  "timestamp":"2026-06-30T10:00:00Z","message":{"role":"user","content":"\(text)"}}
  """
}

private func assistantLine(_ text: String, sessionID: String) -> String {
  """
  {"type":"assistant","sessionId":"\(sessionID)","timestamp":"2026-06-30T10:00:01Z",\
  "message":{"role":"assistant","content":[{"type":"text","text":"\(text)"}]}}
  """
}

/// Spool the transcript as a `cc.session` reference and drain it, exactly as the capture hook does.
private func spoolAndDrain(transcript: URL, spool: CaptureSpool,
                           database: any DatabaseWriter) async throws {
  try spool.append(kind: CaptureKind.ccSession,
                   payload: try encodeJSON(SessionRefPayload(transcriptPath: transcript.path)))
  _ = try await Ingester(spool: spool, database: database).drain()
}

private func passageTexts(_ database: any DatabaseWriter) async throws -> [String] {
  try await database.read { database in try Passage.all.fetchAll(database) }.map(\.text)
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
  // Local shims over the shared fixture, so the call sites below stay about what each line SAYS.
  func user(_ text: String) -> String { userLine(text, sessionID: sessionID, cwd: repo.path) }
  func assistant(_ text: String) -> String { assistantLine(text, sessionID: sessionID) }
  func ingest() async throws {
    try await spoolAndDrain(transcript: transcript, spool: spool, database: database)
  }

  var lines = [user("first real question about the sync agent"),
               assistant("First substantive answer about launchd.")]
  try lines.joined(separator: "\n").write(to: transcript, atomically: true, encoding: .utf8)
  try await ingest()
  #expect(try await passageTexts(database).count == 2)

  // The session grows and is re-spooled. Same sessionID, so the EVENT dedupes — but the transcript
  // now has two more turns, and those must appear.
  lines += [user("second real question about the search index"),
            assistant("Second substantive answer about FTS5.")]
  try lines.joined(separator: "\n").write(to: transcript, atomically: true, encoding: .utf8)
  try await ingest()

  let afterSecond = try await passageTexts(database)
  #expect(afterSecond.count == 4, "the grown session contributes its new turns")
  #expect(Set(afterSecond).count == 4, "and does not duplicate the turns it already had")
  let events = try await database.read { database in
    try Event.where { $0.kind.eq(CaptureKind.ccSession) }.fetchAll(database)
  }
  #expect(events.count == 1, "still one event")
}

/// A re-ingest of a transcript that has NOT grown must not rewrite its passages at all.
///
/// The `SessionEnd` hook re-spools a session as it grows, so once the event exists every drain
/// re-derives its passages — and the rewrite was unconditional: a full delete plus up to 464 inserts
/// every cycle, forever, to arrive at exactly the rows already stored. Row identity is the probe: the
/// passages are minted with fresh UUIDs on every extraction, so if a rewrite happened the ids change.
@Test func reIngestingAnUnchangedTranscriptDoesNotRewriteItsPassages() async throws {
  let (repo, _) = try makeCommittedRepo()
  let spool = try CaptureSpool(at: tempURL("passage-unchanged-spool"))
  let database = try openCanonicalDatabase(at: tempURL("passage-unchanged-canon"))

  let sessionID = UUID().uuidString
  let transcript = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("\(sessionID).jsonl")
  let lines = [userLine("first real question about the sync agent", sessionID: sessionID, cwd: repo.path),
               assistantLine("First substantive answer about launchd.", sessionID: sessionID)]
  try lines.joined(separator: "\n").write(to: transcript, atomically: true, encoding: .utf8)

  try await spoolAndDrain(transcript: transcript, spool: spool, database: database)
  func passageIDs() async throws -> Set<UUID> {
    Set(try await database.read { database in try Passage.all.fetchAll(database) }.map(\.id))
  }
  let before = try await passageIDs()
  #expect(before.count == 2)

  // Same transcript, byte for byte, re-spooled and re-drained.
  try await spoolAndDrain(transcript: transcript, spool: spool, database: database)

  #expect(try await passageIDs() == before, "unchanged content must not be deleted and reinserted")

  // The pairing half: once it really grows, the rewrite DOES happen and the new turns land.
  let grown = lines + [userLine("second question about the search index", sessionID: sessionID, cwd: repo.path),
                       assistantLine("Second substantive answer about FTS5.", sessionID: sessionID)]
  try grown.joined(separator: "\n").write(to: transcript, atomically: true, encoding: .utf8)
  try await spoolAndDrain(transcript: transcript, spool: spool, database: database)
  #expect(try await passageTexts(database).count == 4)
}

/// A re-ingest whose transcript has lost its conversation content (compaction, rewrite,
/// truncation) must NOT wipe the durable copy already stored — that copy may be the only one left,
/// since the transcript it came from may no longer exist. `writePassages` must check whether
/// extraction produced anything BEFORE it deletes the event's existing passages, not after.
@Test func reIngestWithNoExtractablePassagesKeepsTheStoredOnes() async throws {
  let (repo, _) = try makeCommittedRepo()
  let spool = try CaptureSpool(at: tempURL("passage-empty-reingest-spool"))
  let database = try openCanonicalDatabase(at: tempURL("passage-empty-reingest-canon"))

  let sessionID = UUID().uuidString
  let transcript = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("\(sessionID).jsonl")
  func user(_ text: String) -> String { userLine(text, sessionID: sessionID, cwd: repo.path) }
  func ingest() async throws {
    try await spoolAndDrain(transcript: transcript, spool: spool, database: database)
  }

  let firstLines = [user("first real question about the sync agent"),
                    assistantLine("First substantive answer about launchd.", sessionID: sessionID)]
  try firstLines.joined(separator: "\n").write(to: transcript, atomically: true, encoding: .utf8)
  try await ingest()
  #expect(try await passageTexts(database).count == 2)

  // The transcript is rewritten (e.g. by compaction) down to a single line that still carries a
  // `cwd` — so the session still attributes and the EVENT still dedupes on the same sessionID —
  // but whose only content is "ok", which `TextQuality.isProse` rejects (under the 8-character
  // floor). Extraction legitimately yields zero passages; this is a NORMAL outcome, not exotic.
  try user("ok").write(to: transcript, atomically: true, encoding: .utf8)
  try await ingest()

  let afterEmptyReingest = try await passageTexts(database)
  #expect(afterEmptyReingest.count == 2, "the previously-stored passages must survive an extraction that yields nothing")
  let events = try await database.read { database in
    try Event.where { $0.kind.eq(CaptureKind.ccSession) }.fetchAll(database)
  }
  #expect(events.count == 1, "still one event")
}
