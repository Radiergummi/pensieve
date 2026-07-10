import Foundation
import Testing
import SQLiteData
@testable import PensieveKit

/// Stub provider: returns a fixed drop set (never throws) — success path.
private struct DropSet: LLMProvider {
  let drop: [Int]
  func complete(prompt: String) async throws -> String { "[]" }
  func classifyNonSalientIndices(prompt: String) async throws -> [Int] { drop }
}
/// Stub provider: always throws — the write-nothing path.
private struct AlwaysThrows: LLMProvider {
  func complete(prompt: String) async throws -> String { "[]" }
  func classifyNonSalientIndices(prompt: String) async throws -> [Int] { throw LLMError.providerFailed("x") }
}

/// Seeds one node+source+event and a loose end on it. Returns (looseEndID, eventID).
@discardableResult
private func seedLE(_ db: any DatabaseWriter, quote: String, label: String = "",
                    suggestion: String = "", status: String = "open",
                    messageIndex: Int = 0) throws -> (UUID, UUID) {
  let node = Node(name: "N")
  let source = Source(nodeID: node.id, kind: SourceKind.claudeCode, key: "/src/\(UUID().uuidString)")
  let ev = Event(nodeID: node.id, sourceID: source.id, occurredAt: Date(),
                 kind: CaptureKind.ccSession, summary: "s",
                 detailJSON: "{\"transcriptPath\":\"/tmp/does-not-exist-\(UUID().uuidString).jsonl\"}")
  let le = LooseEnd(nodeID: node.id, sourceEventID: ev.id, text: quote, quote: quote,
                    status: status, sourceMessageIndex: messageIndex,
                    label: label, labelSuggestion: suggestion)
  try db.write { db in
    try Node.insert { node }.execute(db)
    try Source.insert { source }.execute(db)
    try Event.insert { ev }.execute(db)
    try LooseEnd.insert { le }.execute(db)
  }
  return (le.id, ev.id)
}

private func labelOf(_ db: any DatabaseWriter, _ id: UUID) throws -> (label: String, suggestion: String) {
  let row = try db.read { db in try LooseEnd.where { $0.id.eq(id) }.fetchOne(db) }!
  return (row.label, row.labelSuggestion)
}

// A parse stub that returns no messages → forces the quote-only path for every event.
private let noMessages: @Sendable (URL) -> ParsedSession = { _ in
  ParsedSession(sessionID: "s", cwd: nil, startedAt: nil, endedAt: nil, userPromptCount: 0, messages: [])
}

@Test func suggesterWritesSuggestionMatchingDropSet() async throws {
  let db = try openCanonicalDatabase(at: tempURL("sug-drop"))
  let (keep, _) = try seedLE(db, quote: "we should migrate the auth tables later")
  let (drop, _) = try seedLE(db, quote: "please read the spec right now")
  // Drop index 1 within the (single) batch. Both share one batch under the default budget.
  let summary = try await SalienceSuggester(provider: DropSet(drop: [1]), parse: noMessages)
    .run(db, limit: nil, force: false)
  // The suggester classifies in stored order; assert by resulting suggestion, not index.
  let all = [keep, drop].map { try! labelOf(db, $0) }
  #expect(all.contains { $0.suggestion == "salient" })
  #expect(all.contains { $0.suggestion == "noise" })
  #expect(summary.suggested == 2)
  #expect(summary.quoteOnly == 2)   // both had no transcript
  #expect(try labelOf(db, keep).label == "")   // never writes the human label
}

@Test func suggesterWritesNothingWhenProviderFails() async throws {
  let db = try openCanonicalDatabase(at: tempURL("sug-throw"))
  let (id, _) = try seedLE(db, quote: "a genuinely deferred item to revisit later")
  let summary = try await SalienceSuggester(provider: AlwaysThrows(), parse: noMessages)
    .run(db, limit: nil, force: false)
  #expect(try labelOf(db, id).suggestion == "")   // untouched → a re-run retries
  #expect(summary.suggested == 0)
  #expect(summary.skipped >= 1)
}

@Test func suggesterSkipsLabeledAndAlreadySuggested() async throws {
  let db = try openCanonicalDatabase(at: tempURL("sug-skip"))
  let (labeled, _) = try seedLE(db, quote: "already human labeled here", label: LooseEndLabel.salient)
  let (suggested, _) = try seedLE(db, quote: "already machine suggested here", suggestion: LooseEndLabel.noise)
  let (fresh, _) = try seedLE(db, quote: "fresh unlabeled candidate here")
  let summary = try await SalienceSuggester(provider: DropSet(drop: []), parse: noMessages)
    .run(db, limit: nil, force: false)
  #expect(summary.candidates == 1)                      // only `fresh`
  #expect(try labelOf(db, labeled).label == "salient")  // untouched
  #expect(try labelOf(db, suggested).suggestion == "noise")   // untouched
  #expect(try labelOf(db, fresh).suggestion == "salient")     // empty drop set → salient
}

@Test func suggesterForceReincludesAlreadySuggested() async throws {
  let db = try openCanonicalDatabase(at: tempURL("sug-force"))
  let (suggested, _) = try seedLE(db, quote: "already machine suggested here", suggestion: LooseEndLabel.salient)
  let summary = try await SalienceSuggester(provider: DropSet(drop: [0]), parse: noMessages)
    .run(db, limit: nil, force: true)
  #expect(summary.candidates == 1)
  #expect(try labelOf(db, suggested).suggestion == "noise")   // re-suggested (drop [0] → noise)
}

@Test func suggesterRespectsLimit() async throws {
  let db = try openCanonicalDatabase(at: tempURL("sug-limit"))
  for i in 0..<5 { try seedLE(db, quote: "candidate number \(i) to consider") }
  let summary = try await SalienceSuggester(provider: DropSet(drop: []), parse: noMessages)
    .run(db, limit: 2, force: false)
  #expect(summary.candidates == 2)
  #expect(summary.suggested == 2)
}
