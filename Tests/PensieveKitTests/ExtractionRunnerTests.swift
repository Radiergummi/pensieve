import Foundation
import Testing
import SQLiteData
@testable import PensieveKit

private struct CannedProvider: LLMProvider {
  let json: String
  func complete(prompt: String) async throws -> String { json }
}

/// Models slice-scoped extraction: proposes a `genuine` candidate only when its `quote`
/// literally appears in the extraction prompt (i.e. its message is in the sliced input),
/// so it faithfully mirrors "extract only the new slice". `fabricated` candidates are
/// always proposed but never appear in any message, so the verifier must drop them
/// (exercising the trust gate). The intent classifier is forced to fail open (keep every
/// user prompt) by throwing — matching the protocol default's non-array behavior.
private struct SliceAwareProvider: LLMProvider {
  var genuine: [(quote: String, index: Int)] = []
  var fabricated: [(quote: String, index: Int)] = []
  func complete(prompt: String) async throws -> String { "[]" }
  func extractCandidates(prompt: String) async throws -> [LooseEndCandidate] {
    var out = genuine.filter { prompt.contains($0.quote) }
      .map { LooseEndCandidate(text: "todo: \($0.quote)", quote: $0.quote, messageIndex: $0.index) }
    out += fabricated.map { LooseEndCandidate(text: "fab", quote: $0.quote, messageIndex: $0.index) }
    return out
  }
  func classifyGenuineIndices(prompt: String) async throws -> [Int] {
    throw LLMError.providerFailed("force fail-open: keep all user prompts")
  }
}

/// One JSONL user-message line as Claude Code records it.
private func userLine(_ text: String, ts: String) -> String {
  let obj: [String: Any] = ["type": "user", "cwd": "/p/x", "timestamp": ts,
                            "message": ["role": "user", "content": text]]
  let data = try! JSONSerialization.data(withJSONObject: obj)
  return String(data: data, encoding: .utf8)!
}

/// Writes a fresh temp transcript of user-message lines; returns its URL. Each text becomes
/// a genuine user prompt at dense index 0,1,2,… in order.
private func writeTranscript(_ texts: [String]) throws -> URL {
  let url = tempURL("transcript", ext: "jsonl")
  let lines = texts.enumerated().map { i, t in userLine(t, ts: "2026-06-30T10:0\(i):00Z") }
  try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
  return url
}

/// Appends one raw line (already JSON, no trailing newline) to an existing transcript.
private func appendRawLine(_ url: URL, _ line: String) throws {
  let handle = try FileHandle(forWritingTo: url)
  defer { try? handle.close() }
  try handle.seekToEnd()
  try handle.write(contentsOf: Data((line + "\n").utf8))
}

/// Inserts a cc.session Event pointing at `transcript` and returns it (already persisted).
private func makeSessionEvent(db: any DatabaseWriter, transcript: URL) throws -> Event {
  let (node, source) = try ProjectResolver(db: db).resolve(path: "/p/x", kind: SourceKind.claudeCode)
  let detail = try encodeJSON(["sessionID": transcript.deletingPathExtension().lastPathComponent,
                               "transcriptPath": transcript.path])
  let event = Event(nodeID: node.id, sourceID: source.id, occurredAt: Date(),
                    kind: CaptureKind.ccSession, summary: "s", detailJSON: detail,
                    fingerprint: "fp-\(UUID().uuidString)")
  try db.write { db in try Event.insert { event }.execute(db) }
  return event
}

@Test func runnerStoresOnlyVerifiedLooseEnds() async throws {
  let db = try openCanonicalDatabase(at: tempURL("run-canon"))
  // A cc.session event pointing at the roles fixture (its cwd is /p/colibri).
  let url = Bundle.module.url(forResource: "session-roles", withExtension: "jsonl", subdirectory: "Fixtures")!
  let (project, source) = try ProjectResolver(db: db).resolve(path: "/p/colibri", kind: SourceKind.claudeCode)
  let detail = try encodeJSON(["sessionID": "session-roles", "prompts": "2", "transcriptPath": url.path])
  let event = Event(nodeID: project.id, sourceID: source.id, occurredAt: Date(),
                    kind: CaptureKind.ccSession, summary: "s", detailJSON: detail,
                    fingerprint: "fp-run")
  try await db.write { db in try Event.insert { event }.execute(db) }

  // Model proposes two: one real user quote, one fabricated → only the real one survives.
  let provider = CannedProvider(json: """
  [{"text":"add rate limiting","quote":"We still need to add rate limiting before launch","messageIndex":0},
   {"text":"call the bank","quote":"remember to call the bank tomorrow","messageIndex":0}]
  """)
  let results = try await ExtractionRunner(db: db, provider: provider).run()

  #expect(results.count == 1)
  #expect(results.first?.proposed == 2)
  #expect(results.first?.verified == 1)
  #expect(results.first?.inserted == 1)

  let ends = try await db.read { db in try LooseEnd.all.fetchAll(db) }
  #expect(ends.count == 1)
  #expect(ends.first?.quote == "We still need to add rate limiting before launch")
  #expect(ends.first?.role == "user")

  // extractedAt was set → a second run does nothing.
  let second = try await ExtractionRunner(db: db, provider: provider).run()
  #expect(second.isEmpty)
  #expect(try await db.read { db in try LooseEnd.all.fetchAll(db) }.count == 1)
}

@Test func reextractsOnlyNewMessagesOnGrowth() async throws {
  let db = try openCanonicalDatabase(at: tempURL("run-growth"))
  let rate = "We still need to add rate limiting before launch"
  let migration = "Also remember to write the migration test before merging"
  let transcript = try writeTranscript([rate])
  _ = try makeSessionEvent(db: db, transcript: transcript)

  // Run 1: only msg 0 exists → the rate-limiting loose end is inserted.
  let run1 = try await ExtractionRunner(db: db, provider:
    SliceAwareProvider(genuine: [(rate, 0)])).run()
  #expect(run1.first?.inserted == 1)
  let after1 = try await db.read { db in try LooseEnd.all.fetchAll(db) }
  #expect(after1.count == 1)
  #expect(after1.first?.quote == rate)

  // Watermark advanced to the current message count and byte size.
  let ev1 = try await db.read { db in try Event.all.fetchAll(db) }.first!
  #expect(ev1.extractedMessageCount == 1)
  #expect(ev1.extractedTranscriptSize > 0)

  // Append a second genuine user message (index 1) and re-run.
  try appendRawLine(transcript, userLine(migration, ts: "2026-06-30T10:05:00Z"))
  // Provider proposes the NEW loose end (index 1) plus one fabricated candidate that must
  // be dropped by the verifier; it does NOT re-propose the rate-limiting quote.
  let run2 = try await ExtractionRunner(db: db, provider:
    SliceAwareProvider(genuine: [(migration, 1)],
                       fabricated: [(quote: "never said this at all", index: 1)])).run()

  #expect(run2.first?.proposed == 2)   // genuine (in slice) + fabricated
  #expect(run2.first?.verified == 1)   // trust gate drops the fabricated one on re-extraction
  #expect(run2.first?.inserted == 1)   // only the new loose end, no duplicate of the old
  let after2 = try await db.read { db in try LooseEnd.all.fetchAll(db) }
  #expect(after2.count == 2)
  #expect(Set(after2.map { $0.quote }) == Set([rate, migration]))
  let ev2 = try await db.read { db in try Event.all.fetchAll(db) }.first!
  #expect(ev2.extractedMessageCount == 2)
}

@Test func unchangedTranscriptIsNoOp() async throws {
  let db = try openCanonicalDatabase(at: tempURL("run-noop"))
  let quote = "We still need to add rate limiting before launch"
  let transcript = try writeTranscript([quote])
  _ = try makeSessionEvent(db: db, transcript: transcript)

  _ = try await ExtractionRunner(db: db, provider: SliceAwareProvider(genuine: [(quote, 0)])).run()
  #expect(try await db.read { db in try LooseEnd.all.fetchAll(db) }.count == 1)

  // Re-run with NO change to the transcript → the size gate skips it: no result element,
  // nothing inserted.
  let second = try await ExtractionRunner(db: db, provider: SliceAwareProvider(genuine: [(quote, 0)])).run()
  #expect(second.isEmpty)
  #expect(try await db.read { db in try LooseEnd.all.fetchAll(db) }.count == 1)
}

@Test func countDropReextractsFromZeroWithoutCrashOrDuplicate() async throws {
  let db = try openCanonicalDatabase(at: tempURL("run-shrink"))
  let quote = "We still need to add rate limiting before launch"
  let transcript = try writeTranscript([quote])
  let event = try makeSessionEvent(db: db, transcript: transcript)

  _ = try await ExtractionRunner(db: db, provider: SliceAwareProvider(genuine: [(quote, 0)])).run()
  #expect(try await db.read { db in try LooseEnd.all.fetchAll(db) }.count == 1)

  // Simulate a rewrite/filter change: watermark far above the current message count, and a
  // size different from the real file (non-zero, so it is NOT mistaken for a legacy row).
  try await db.write { db in
    try Event.where { $0.id.eq(event.id) }.update {
      $0.extractedMessageCount = 99
      $0.extractedTranscriptSize = 1   // != real size and != 0
    }.execute(db)
  }

  // Must NOT trap on messages[99...]; re-extracts from 0, and the dedup prevents a duplicate.
  let rerun = try await ExtractionRunner(db: db, provider: SliceAwareProvider(genuine: [(quote, 0)])).run()
  #expect(rerun.first?.inserted == 0)   // already-open loose end deduped
  let ends = try await db.read { db in try LooseEnd.all.fetchAll(db) }
  #expect(ends.count == 1)
  // Watermark repaired to the real count.
  let ev = try await db.read { db in try Event.all.fetchAll(db) }.first!
  #expect(ev.extractedMessageCount == 1)
}

@Test func legacyRowInitializesWithoutResurrectingResolved() async throws {
  let db = try openCanonicalDatabase(at: tempURL("run-legacy"))
  let resolvedQuote = "We still need to add rate limiting before launch"
  let transcript = try writeTranscript([resolvedQuote])
  let event = try makeSessionEvent(db: db, transcript: transcript)

  // Simulate a pre-feature row: extractedAt set, size still 0, count 0; and a RESOLVED loose
  // end whose quote is still in the transcript.
  try await db.write { db in
    try Event.where { $0.id.eq(event.id) }.update { $0.extractedAt = #bind(Date(timeIntervalSince1970: 1)) }.execute(db)
    try LooseEnd.insert {
      LooseEnd(nodeID: event.nodeID, sourceEventID: event.id, text: "rate limiting",
               quote: resolvedQuote, status: "resolved", role: "user", sourceMessageIndex: 0)
    }.execute(db)
  }

  // Legacy init: initializes the watermark/size, extracts NOTHING → the resolved item is not
  // resurfaced.
  let init1 = try await ExtractionRunner(db: db, provider: SliceAwareProvider(genuine: [(resolvedQuote, 0)])).run()
  #expect(init1.isEmpty)
  let after1 = try await db.read { db in try LooseEnd.all.fetchAll(db) }
  #expect(after1.count == 1)
  #expect(after1.first?.status == "resolved")
  let ev1 = try await db.read { db in try Event.all.fetchAll(db) }.first!
  #expect(ev1.extractedMessageCount == 1)
  #expect(ev1.extractedTranscriptSize > 0)

  // A later append then extracts only the genuinely new content.
  let newQuote = "Also remember to write the migration test before merging"
  try appendRawLine(transcript, userLine(newQuote, ts: "2026-06-30T10:05:00Z"))
  let run2 = try await ExtractionRunner(db: db, provider: SliceAwareProvider(genuine: [(newQuote, 1)])).run()
  #expect(run2.first?.inserted == 1)
  let after2 = try await db.read { db in try LooseEnd.all.fetchAll(db) }
  #expect(after2.count == 2)
  #expect(after2.filter { $0.status == "open" }.map { $0.quote } == [newQuote])
}

@Test func unreadableTranscriptSkipsAndLeavesWatermarkUnadvanced() async throws {
  let db = try openCanonicalDatabase(at: tempURL("run-missing"))
  // Point the event at a path that does not exist.
  let missing = tempURL("no-such-transcript", ext: "jsonl")
  _ = try makeSessionEvent(db: db, transcript: missing)

  let results = try await ExtractionRunner(db: db, provider: SliceAwareProvider()).run()
  #expect(results.isEmpty)
  let ev = try await db.read { db in try Event.all.fetchAll(db) }.first!
  #expect(ev.extractedAt == nil)              // not marked; will retry
  #expect(ev.extractedMessageCount == 0)
  #expect(ev.extractedTranscriptSize == 0)
}

@Test func partialTrailingLinePicksUpAtCorrectIndexAfterCompletion() async throws {
  let db = try openCanonicalDatabase(at: tempURL("run-partial"))
  let q0 = "We still need to add rate limiting before launch"
  let q1 = "Also remember to write the migration test before merging"
  let transcript = try writeTranscript([q0])
  // Append a half-written (invalid-JSON) trailing line: the parser skips it (1 message).
  try appendRawLine(transcript, "{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":\"Als")
  _ = try makeSessionEvent(db: db, transcript: transcript)

  let run1 = try await ExtractionRunner(db: db, provider: SliceAwareProvider(genuine: [(q0, 0)])).run()
  #expect(run1.first?.inserted == 1)
  let ev1 = try await db.read { db in try Event.all.fetchAll(db) }.first!
  #expect(ev1.extractedMessageCount == 1)   // partial line did not create a phantom message

  // "Complete" the record by rewriting the file with both full messages present.
  try (userLine(q0, ts: "2026-06-30T10:00:00Z") + "\n" + userLine(q1, ts: "2026-06-30T10:05:00Z") + "\n")
    .write(to: transcript, atomically: true, encoding: .utf8)

  // The now-complete message is picked up at index 1 with no offset drift.
  let run2 = try await ExtractionRunner(db: db, provider: SliceAwareProvider(genuine: [(q1, 1)])).run()
  #expect(run2.first?.inserted == 1)
  let ends = try await db.read { db in try LooseEnd.all.fetchAll(db) }
  #expect(ends.count == 2)
  #expect(ends.first(where: { $0.quote == q1 })?.sourceMessageIndex == 1)
}
