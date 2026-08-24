import Foundation
import Testing
import SQLiteData
@testable import PensieveKit

/// The extraction watermark is what makes extraction lossless: a slice marked extracted is never
/// mined again (the byte-size gate skips it), so the watermark may only advance over a slice the
/// model actually answered about. These tests pin BOTH directions of that rule.
///
/// Lives beside `ExtractionRunnerTests` rather than in it because that file is at the 400-line cap.

/// A cc.session event plus its transcript on disk. Deliberately its own small helper rather than a
/// reach into `ExtractionRunnerTests`' fileprivate ones.
private func seedSession(_ database: any DatabaseWriter, texts: [String]) throws -> Event {
  let transcript = tempURL("watermark-transcript", ext: "jsonl")
  let lines = try texts.enumerated().map { index, text -> String in
    let record: [String: Any] = ["type": "user", "cwd": "/p/watermark",
                                 "timestamp": String(format: "2026-08-24T10:%02d:00Z", index),
                                 "message": ["role": "user", "content": text]]
    let data = try JSONSerialization.data(withJSONObject: record)
    return String(bytes: data, encoding: .utf8) ?? ""
  }
  try (lines.joined(separator: "\n") + "\n").write(to: transcript, atomically: true, encoding: .utf8)

  let (node, source) = try ProjectResolver(database: database).resolve(path: "/p/watermark",
                                                                      kind: SourceKind.claudeCode)
  let detail = try encodeJSON(["sessionID": "watermark-session", "transcriptPath": transcript.path])
  let event = Event(nodeID: node.id, sourceID: source.id, occurredAt: Date(),
                   kind: CaptureKind.ccSession, summary: "s", detailJSON: detail,
                   fingerprint: "fp-\(UUID().uuidString)")
  try database.write { database in try Event.insert { event }.execute(database) }
  return event
}

private func reload(_ database: any DatabaseWriter, _ event: Event) throws -> Event {
  try database.read { database in try Event.where { $0.id.eq(event.id) }.fetchOne(database) }!
}

private let looseEndQuote = "we should also migrate the auth tables before launch"

/// The realistic failure: `claude -p` answers a chunk with prose — a refusal, a "Here are the loose
/// ends:" preamble, a truncated reply. There is no JSON array to parse, so nothing was mined.
private struct ProseOnlyProvider: LLMProvider {
  func complete(prompt: String) async throws -> String {
    "Here are the loose ends I found: the developer still wants to migrate the auth tables."
  }
}

/// The model answered the question and found nothing — an empty array, not an unparseable reply.
private struct EmptyArrayProvider: LLMProvider {
  func complete(prompt: String) async throws -> String { "[]" }
  func classifyGenuineIndices(prompt: String) async throws -> [Int] { [0] }
}

@Test func unparseableExtractionReplyLeavesTheWatermarkUnadvanced() async throws {
  let database = try openCanonicalDatabase(at: tempURL("watermark-unparseable"))
  let event = try seedSession(database, texts: [looseEndQuote])

  let results = try await ExtractionRunner(database: database, provider: ProseOnlyProvider()).run()

  // Nothing was mined, so nothing may be recorded as mined: the size gate keys off these three
  // fields, and advancing them here retires the slice permanently.
  #expect(results.isEmpty)
  let reloaded = try reload(database, event)
  #expect(reloaded.extractedAt == nil)
  #expect(reloaded.extractedMessageCount == 0)
  #expect(reloaded.extractedTranscriptSize == -1)   // still the "never watermarked" sentinel

  // And the next pass genuinely re-tries it — with a provider that answers, the loose end lands.
  struct AnsweringProvider: LLMProvider {
    func complete(prompt: String) async throws -> String { "[]" }
    func classifyGenuineIndices(prompt: String) async throws -> [Int] { [0] }
    func extractCandidates(prompt: String) async throws -> [LooseEndCandidate] {
      [LooseEndCandidate(text: "migrate auth tables", quote: looseEndQuote, messageIndex: 0)]
    }
  }
  let retry = try await ExtractionRunner(database: database, provider: AnsweringProvider()).run()
  #expect(retry.first?.inserted == 1)
  let stored = try await database.read { database in try LooseEnd.all.fetchAll(database) }
  #expect(stored.map(\.quote) == [looseEndQuote])
}

@Test func genuinelyEmptyExtractionReplyStillAdvancesTheWatermark() async throws {
  // The other direction, and the reason "just throw on empty" is not the fix: a model that answers
  // "[]" HAS mined the slice. Re-mining it every pass would burn the model on it forever.
  let database = try openCanonicalDatabase(at: tempURL("watermark-empty"))
  let event = try seedSession(database, texts: [looseEndQuote])

  let results = try await ExtractionRunner(database: database, provider: EmptyArrayProvider()).run()

  #expect(results.count == 1)
  #expect(results.first?.proposed == 0)
  #expect(results.first?.inserted == 0)
  let reloaded = try reload(database, event)
  #expect(reloaded.extractedAt != nil)
  #expect(reloaded.extractedMessageCount == 1)
  #expect(reloaded.extractedTranscriptSize > 0)
  #expect(try await database.read { database in try LooseEnd.all.fetchAll(database) }.isEmpty)

  // Watermarked ⇒ the unchanged transcript is skipped next pass.
  #expect(try await ExtractionRunner(database: database, provider: EmptyArrayProvider()).run().isEmpty)
}

// MARK: - Cancellation (a quit is not N failures)

/// Reports when the model call has been entered, then spins until the Task is cancelled — so the
/// test can cancel strictly AFTER the per-session work has begun.
private actor EntryFlag {
  private(set) var entered = false
  func mark() { entered = true }
}

private struct CancelAwareProvider: LLMProvider {
  let flag: EntryFlag
  func complete(prompt: String) async throws -> String { "[]" }
  func classifyGenuineIndices(prompt: String) async throws -> [Int] { [0] }
  func extractCandidates(prompt: String) async throws -> [LooseEndCandidate] {
    await flag.mark()
    while !Task.isCancelled { await Task.yield() }
    throw CancellationError()
  }
}

@Test func cancellingAPassEndsAsCancellationAndLeavesTheWatermarkUnadvanced() async throws {
  let database = try openCanonicalDatabase(at: tempURL("watermark-cancel"))
  let event = try seedSession(database, texts: [looseEndQuote])
  let flag = EntryFlag()
  let provider = CancelAwareProvider(flag: flag)

  let pass = Task { try await ExtractionRunner(database: database, provider: provider).run() }
  // Cancel only once the session's extraction is already running, so the loop's own
  // `checkCancellation` has already passed for this session: the ONLY route to a thrown
  // CancellationError is the per-session catch rethrowing it instead of logging a failure.
  while !(await flag.entered) { await Task.yield() }
  pass.cancel()

  await #expect(throws: CancellationError.self) { try await pass.value }
  let reloaded = try reload(database, event)
  #expect(reloaded.extractedAt == nil)               // an abandoned pass mines nothing
  #expect(reloaded.extractedTranscriptSize == -1)
}
