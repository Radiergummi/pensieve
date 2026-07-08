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
  let lines = texts.enumerated().map { i, t in userLine(t, ts: String(format: "2026-06-30T10:%02d:00Z", i)) }
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

/// Seeds a single-message session (transcript on disk + persisted cc.session Event) in one step.
private func seedSingleMessageSession(db: any DatabaseWriter, quote: String) throws -> (transcript: URL, event: Event) {
  let transcript = try writeTranscript([quote])
  return (transcript, try makeSessionEvent(db: db, transcript: transcript))
}

/// The two fixture quotes reused across the incremental tests — the same input under one name.
private let rateLimitingQuote = "We still need to add rate limiting before launch"
private let migrationQuote = "Also remember to write the migration test before merging"

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
  let rate = rateLimitingQuote
  let migration = migrationQuote
  let (transcript, _) = try seedSingleMessageSession(db: db, quote: rate)

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
  let quote = rateLimitingQuote
  _ = try seedSingleMessageSession(db: db, quote: quote)

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
  let quote = rateLimitingQuote
  let (_, event) = try seedSingleMessageSession(db: db, quote: quote)

  _ = try await ExtractionRunner(db: db, provider: SliceAwareProvider(genuine: [(quote, 0)])).run()
  #expect(try await db.read { db in try LooseEnd.all.fetchAll(db) }.count == 1)

  // Simulate a rewrite/filter change: watermark far above the current message count, and a
  // size different from the real file (not -1, so it is NOT mistaken for a legacy row).
  try await db.write { db in
    try Event.where { $0.id.eq(event.id) }.update {
      $0.extractedMessageCount = 99
      $0.extractedTranscriptSize = 1   // != real size and != -1
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

@Test func reextractFromZeroDoesNotResurrectResolvedLooseEnd() async throws {
  // The shrink→0 path re-mines the WHOLE transcript. A loose end the user already RESOLVED,
  // whose quote is still verbatim in the transcript, must not be re-inserted as open — the
  // dedup collapses against all statuses, not just open ones.
  let db = try openCanonicalDatabase(at: tempURL("run-resurrect"))
  let quote = rateLimitingQuote
  let (_, event) = try seedSingleMessageSession(db: db, quote: quote)

  _ = try await ExtractionRunner(db: db, provider: SliceAwareProvider(genuine: [(quote, 0)])).run()
  // Resolve the extracted loose end, then force the shrink→0 re-extract path.
  try await db.write { db in
    try LooseEnd.where { $0.quote.eq(quote) }.update { $0.status = "resolved" }.execute(db)
    try Event.where { $0.id.eq(event.id) }.update {
      $0.extractedMessageCount = 99
      $0.extractedTranscriptSize = 1   // != real size and != -1 → not legacy, forces start=0
    }.execute(db)
  }

  let rerun = try await ExtractionRunner(db: db, provider: SliceAwareProvider(genuine: [(quote, 0)])).run()
  #expect(rerun.first?.inserted == 0)   // resolved quote is deduped, not resurrected
  let ends = try await db.read { db in try LooseEnd.all.fetchAll(db) }
  #expect(ends.count == 1)
  #expect(ends.first?.status == "resolved")   // still resolved; nothing reopened
}

@Test func legacyRowInitializesWithoutResurrectingResolved() async throws {
  let db = try openCanonicalDatabase(at: tempURL("run-legacy"))
  let resolvedQuote = rateLimitingQuote
  let (transcript, event) = try seedSingleMessageSession(db: db, quote: resolvedQuote)

  // Simulate a pre-feature row: extractedAt set, size still the -1 sentinel (init default),
  // count 0; and a RESOLVED loose end whose quote is still in the transcript.
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
  let newQuote = migrationQuote
  try appendRawLine(transcript, userLine(newQuote, ts: "2026-06-30T10:05:00Z"))
  let run2 = try await ExtractionRunner(db: db, provider: SliceAwareProvider(genuine: [(newQuote, 1)])).run()
  #expect(run2.first?.inserted == 1)
  let after2 = try await db.read { db in try LooseEnd.all.fetchAll(db) }
  #expect(after2.count == 2)
  #expect(after2.filter { $0.status == "open" }.map { $0.quote } == [newQuote])
}

@Test func legacyZeroByteTranscriptThatGrowsExtractsNewContent() async throws {
  // Regression for the -1 sentinel: a legacy row whose real transcript is 0 bytes must not be
  // trapped. Under the old `size == 0` sentinel the size gate (0 == stored 0) skipped it forever,
  // and once it grew, legacy-init swallowed the new content. With -1, size 0 is a real size.
  let db = try openCanonicalDatabase(at: tempURL("run-legacy-empty"))
  let transcript = tempURL("transcript", ext: "jsonl")
  try Data().write(to: transcript)                       // a genuine 0-byte transcript
  let event = try makeSessionEvent(db: db, transcript: transcript)
  try await db.write { db in
    try Event.where { $0.id.eq(event.id) }
      .update { $0.extractedAt = #bind(Date(timeIntervalSince1970: 1)) }.execute(db)
  }

  // First run: 0 != -1 so the size gate does NOT skip; legacy-init records the real size (0)
  // and extracts nothing.
  let init1 = try await ExtractionRunner(db: db, provider: SliceAwareProvider()).run()
  #expect(init1.isEmpty)
  let ev1 = try await db.read { db in try Event.all.fetchAll(db) }.first!
  #expect(ev1.extractedTranscriptSize == 0)              // real size recorded; no longer the sentinel
  #expect(ev1.extractedMessageCount == 0)

  // The transcript later grows with genuinely new content → it must extract, not swallow.
  try (userLine(rateLimitingQuote, ts: "2026-06-30T10:00:00Z") + "\n")
    .write(to: transcript, atomically: true, encoding: .utf8)
  let run2 = try await ExtractionRunner(db: db, provider:
    SliceAwareProvider(genuine: [(rateLimitingQuote, 0)])).run()
  #expect(run2.first?.inserted == 1)
  #expect(try await db.read { db in try LooseEnd.all.fetchAll(db) }.count == 1)
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
  #expect(ev.extractedTranscriptSize == -1)   // still the "never watermarked" sentinel
}

@Test func runnerFiltersClosureCandidatesBeforeInsert() async throws {
  let db = try openCanonicalDatabase(at: tempURL("cf"))
  let transcript = try writeTranscript([
    "we still need to migrate the auth tables before launch",   // index 0 — real
    "looks good, yes.",                                          // index 1 — closure noise
  ])
  let event = try makeSessionEvent(db: db, transcript: transcript)
  let provider = SliceAwareProvider(genuine: [
    (quote: "we still need to migrate the auth tables before launch", index: 0),
    (quote: "looks good, yes.", index: 1),
  ])
  _ = try await ExtractionRunner(db: db, provider: provider).run()
  let quotes = try await db.read { db in try LooseEnd.order { $0.sourceMessageIndex }.fetchAll(db).map(\.quote) }
  #expect(quotes == ["we still need to migrate the auth tables before launch"])  // closure dropped
  _ = event
}

@Test func extractionStoresWorkSummary() async throws {
  let db = try openCanonicalDatabase(at: tempURL("run-worksummary"))
  let (_, event) = try seedSingleMessageSession(db: db, quote: "we should also migrate the auth tables later")
  struct SummarizingProvider: LLMProvider {
    func complete(prompt: String) async throws -> String { "Migrated the auth tables." }
    func extractCandidates(prompt: String) async throws -> [LooseEndCandidate] { [] }
    func classifyGenuineIndices(prompt: String) async throws -> [Int] { [0] }
  }
  _ = try await ExtractionRunner(db: db, provider: SummarizingProvider()).run()
  let ev = try await db.read { db in try Event.where { $0.id.eq(event.id) }.fetchOne(db) }
  #expect(ev?.workSummary == "Migrated the auth tables.")
}

@Test func summarizerFailureDoesNotBlockWatermark() async throws {
  let db = try openCanonicalDatabase(at: tempURL("run-worksummary-fail"))
  let (_, event) = try seedSingleMessageSession(db: db, quote: "please read the spec")
  struct FailSummaryProvider: LLMProvider {
    func complete(prompt: String) async throws -> String { throw LLMError.providerFailed("no summary") }
    func extractCandidates(prompt: String) async throws -> [LooseEndCandidate] { [] }
    func classifyGenuineIndices(prompt: String) async throws -> [Int] { [0] }
  }
  _ = try await ExtractionRunner(db: db, provider: FailSummaryProvider()).run()
  let ev = try await db.read { db in try Event.where { $0.id.eq(event.id) }.fetchOne(db) }
  #expect(ev?.workSummary == nil)                 // best-effort: left unset
  #expect(ev?.extractedTranscriptSize != -1)      // watermark still advanced
}

@Test func extractionAppliesSalienceGate() async throws {
  // Two candidates verified; the salience gate drops the in-the-moment one. Only the
  // deferred/salient quote is stored. Content-keyed drop (not a bare batch-local index
  // literal) so the stub stays correct regardless of how SalienceClassifier batches.
  let db = try openCanonicalDatabase(at: tempURL("run-salience"))
  let transcript = try writeTranscript([
    "we should also migrate the auth tables later",   // salient
    "please read the spec now",                        // in-the-moment -> dropped
  ])
  let event = try makeSessionEvent(db: db, transcript: transcript)
  struct TwoThenDrop: LLMProvider {
    func complete(prompt: String) async throws -> String { "" }
    func classifyGenuineIndices(prompt: String) async throws -> [Int] { [0, 1] }
    func extractCandidates(prompt: String) async throws -> [LooseEndCandidate] {
      [LooseEndCandidate(text: "migrate auth", quote: "we should also migrate the auth tables later", messageIndex: 0),
       LooseEndCandidate(text: "read spec", quote: "please read the spec now", messageIndex: 1)]
    }
    func classifyNonSalientIndices(prompt: String) async throws -> [Int] {
      // Drop whichever batch-local [n] item's QUOTE line is the in-the-moment request.
      var drop: [Int] = []
      for line in prompt.split(separator: "\n") {
        guard line.hasPrefix("["), let close = line.firstIndex(of: "]"),
              let n = Int(line[line.index(after: line.startIndex)..<close]) else { continue }
        if line.contains("QUOTE: please read the spec now") { drop.append(n) }
      }
      return drop
    }
  }
  _ = try await ExtractionRunner(db: db, provider: TwoThenDrop()).run()
  let stored = try await db.read { db in try LooseEnd.where { $0.nodeID.eq(event.nodeID) }.fetchAll(db) }
  #expect(stored.map(\.quote) == ["we should also migrate the auth tables later"])
}

@Test func partialTrailingLinePicksUpAtCorrectIndexAfterCompletion() async throws {
  let db = try openCanonicalDatabase(at: tempURL("run-partial"))
  let q0 = rateLimitingQuote
  let q1 = migrationQuote
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
