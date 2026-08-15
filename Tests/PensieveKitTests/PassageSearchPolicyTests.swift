import Foundation
import Testing
import SQLiteData
@testable import PensieveKit

// Policy the passage path shares with the ranked one — the path restriction, the English retry, and
// the rebuild guard. A separate file from `PassageQueriesTests` because that one is at SwiftLint's
// 400-line cap; the fixtures below are deliberately local rather than promoted, matching the note at
// the top of that file.

private func makeStore() throws -> any DatabaseWriter {
  try openCanonicalDatabase(at: tempURL("passage-policy-canon"))
}

private func addNode(_ database: any DatabaseWriter, name: String,
                     state: NodeState = .active) throws -> Node {
  let node = Node(name: name, state: state)
  try database.write { database in try Node.insert { node }.execute(database) }
  return node
}

private func addSessionEvent(_ database: any DatabaseWriter, nodeID: UUID,
                             transcriptPath: String = "") throws -> Event {
  let source = Source(nodeID: nodeID, kind: SourceKind.claudeCode,
                      key: tempURL("repo", ext: nil).path)
  let detail = try encodeJSON(["sessionID": UUID().uuidString, "prompts": "1",
                               "transcriptPath": transcriptPath])
  let event = Event(nodeID: nodeID, sourceID: source.id, occurredAt: Date(),
                    kind: CaptureKind.ccSession, summary: "session", detailJSON: detail)
  try database.write { database in
    try Source.insert { source }.execute(database)
    try Event.insert { event }.execute(database)
  }
  return event
}

@discardableResult
private func addPassage(_ database: any DatabaseWriter, nodeID: UUID, eventID: UUID,
                        text: String, role: PassageRole = .prompt) throws -> Passage {
  let passage = Passage(nodeID: nodeID, eventID: eventID, turnIndex: 0, messageIndex: 0,
                        role: role, text: text,
                        occurredAt: Date(timeIntervalSince1970: 1_700_000_000))
  try database.write { database in try Passage.insert { passage }.execute(database) }
  return passage
}

// MARK: - a path restriction must narrow passages to nothing, not be dropped

/// A passage has no file paths, so it can never satisfy a path clause. Matching its text while
/// silently discarding the path half put rows in the result that ignored the narrowing the caller
/// asked for — beside ranked hits that honoured it, in one array the MCP tool describes as one
/// contract. Mutation-check: restore `.textRestrictedByPath(let text, _): match = text` in
/// `SearchIndexStore.searchPassages` and both restricted cases below MUST fail.
@Test func aPathRestrictedQueryReturnsNoPassagesRatherThanIgnoringThePath() throws {
  let database = try makeStore()
  let store = tempSearchStore()
  let node = try addNode(database, name: "Pensieve")
  let event = try addSessionEvent(database, nodeID: node.id)
  try addPassage(database, nodeID: node.id, eventID: event.id,
                 text: "launchd refuses the spawn because the LWCR is stale")
  store.rebuildPassages(items: try EmbeddableCorpus.gatherPassages(database), passagesHash: "h1")
  let scope = SearchScope(visibleNodeIDs: [node.id])

  #expect(PassageQueries.search(query: "launchd", scope: scope, store: store, database).count == 1,
          "the unrestricted query still finds it")
  #expect(PassageQueries.search(query: "launchd", file: "SyncRunner.swift", scope: scope,
                                store: store, database).isEmpty,
          "a structured file restriction admits no passages")
  #expect(PassageQueries.search(query: "launchd files:SyncRunner.swift", scope: scope,
                                store: store, database).isEmpty,
          "and neither does a files: directive typed into the query")
}

// MARK: - the English retry reaches passages too

/// Records its calls so the negative assertion is real (the idiom `TranslatedSearchTests` uses).
private actor StubTranslator: Translator {
  private(set) var calls: [String] = []
  private let mapping: [String: String]
  init(mapping: [String: String]) { self.mapping = mapping }
  func translate(_ text: String, from source: String, to target: String) async -> String? {
    record(text)
    return mapping[text]
  }
  private func record(_ text: String) { calls.append(text) }
  func callCount() -> Int { calls.count }
}

/// Transcripts are overwhelmingly English even when the query is not, and a passage is captured
/// content that never gets a stored translation — so this is the corpus where the retry earns the
/// most, and it was the one list that never got it.
@Test func aGermanQueryOverEnglishPassagesIsRetriedInEnglish() async throws {
  let database = try makeStore()
  let store = tempSearchStore()
  let node = try addNode(database, name: "Pensieve")
  let event = try addSessionEvent(database, nodeID: node.id)
  try addPassage(database, nodeID: node.id, eventID: event.id,
                 text: "the background sync agent stopped running after the rebuild")
  store.rebuildPassages(items: try EmbeddableCorpus.gatherPassages(database), passagesHash: "h1")
  let scope = SearchScope(visibleNodeIDs: [node.id])
  let translator = StubTranslator(mapping: ["Hintergrund": "background"])

  #expect(PassageQueries.search(query: "Hintergrund", scope: scope, store: store, database).isEmpty,
          "the literal German query cannot match English captured content")
  let hits = await PassageQueries.searchTranslatingOnEmpty(
    query: "Hintergrund", scope: scope, store: store, language: "de", translator: translator,
    database)
  #expect(hits.count == 1, "the English retry finds it")
}

/// The safety property, asserted rather than assumed: a retry can never regress a query that
/// already returned rows. Mutation-check: delete the `guard hits.isEmpty` in
/// `PassageQueries.searchTranslatingOnEmpty` and this MUST fail.
@Test func aPassageQueryThatAlreadyHasResultsNeverReachesTheTranslator() async throws {
  let database = try makeStore()
  let store = tempSearchStore()
  let node = try addNode(database, name: "Pensieve")
  let event = try addSessionEvent(database, nodeID: node.id)
  try addPassage(database, nodeID: node.id, eventID: event.id,
                 text: "launchd refuses the spawn because the LWCR is stale")
  store.rebuildPassages(items: try EmbeddableCorpus.gatherPassages(database), passagesHash: "h1")
  let translator = StubTranslator(mapping: ["launchd": "launchd"])

  let hits = await PassageQueries.searchTranslatingOnEmpty(
    query: "launchd", scope: SearchScope(visibleNodeIDs: [node.id]), store: store, language: "de",
    translator: translator, database)
  #expect(hits.count == 1)
  #expect(await translator.callCount() == 0, "a non-empty result must not be translated at all")
}

// MARK: - the rebuild guard

/// The guard must not move when nothing did — it runs on every watch refresh, and a fingerprint
/// that drifted would rebuild the whole passage table each time.
@Test func thePassageFingerprintIsStableWhenNothingChanged() throws {
  let database = try makeStore()
  let node = try addNode(database, name: "Pensieve")
  let event = try addSessionEvent(database, nodeID: node.id)
  try addPassage(database, nodeID: node.id, eventID: event.id, text: "why does launchd refuse")

  let first = try EmbeddableCorpus.passageCorpusFingerprint(database)
  #expect(try EmbeddableCorpus.passageCorpusFingerprint(database) == first)
}

/// **The invariant the cheap fingerprint rests on.** It reads no passage TEXT, which is only sound
/// because text never changes under a fixed id: the supported writer replaces an event's passages
/// wholesale with freshly-minted ids. This runs that path and pins that the fingerprint notices.
/// A future writer that UPDATEs `passages.text` in place would leave this passing while the index
/// silently kept the old prose — so if this test is ever made to pass by relaxing it, the guard
/// itself has to grow text back.
@Test func thePassageFingerprintTracksAReplacedPassage() throws {
  let database = try makeStore()
  let node = try addNode(database, name: "Pensieve")
  let event = try addSessionEvent(database, nodeID: node.id)
  try addPassage(database, nodeID: node.id, eventID: event.id, text: "the original prose")
  let before = try EmbeddableCorpus.passageCorpusFingerprint(database)

  try database.write { database in
    try Ingester.replacePassages(database, eventID: event.id, with: [
      Passage(nodeID: node.id, eventID: event.id, turnIndex: 0, messageIndex: 0, role: .prompt,
              text: "completely different prose", occurredAt: Date(timeIntervalSince1970: 1))])
  }
  #expect(try EmbeddableCorpus.passageCorpusFingerprint(database) != before)
}

/// A repoint (strand birth, or a merge) rewrites `passage.nodeID` and nothing else. The index rows
/// carry that node, so the guard has to see it.
@Test func thePassageFingerprintTracksARepoint() throws {
  let database = try makeStore()
  let origin = try addNode(database, name: "Pensieve")
  let strand = try addNode(database, name: "Strand")
  let event = try addSessionEvent(database, nodeID: origin.id)
  try addPassage(database, nodeID: origin.id, eventID: event.id, text: "why does launchd refuse")
  let before = try EmbeddableCorpus.passageCorpusFingerprint(database)

  try database.write { database in
    try Passage.where { $0.eventID.eq(event.id) }.update { $0.nodeID = strand.id }.execute(database)
  }
  #expect(try EmbeddableCorpus.passageCorpusFingerprint(database) != before)
}

/// Archiving touches no passage row at all — it changes `Node.state`, which every index row copies
/// and the SQL scope filter reads. A passages-only change signal would miss this entirely.
@Test func thePassageFingerprintTracksItsNodesStateChange() throws {
  let database = try makeStore()
  let node = try addNode(database, name: "Pensieve")
  let event = try addSessionEvent(database, nodeID: node.id)
  try addPassage(database, nodeID: node.id, eventID: event.id, text: "why does launchd refuse")
  let before = try EmbeddableCorpus.passageCorpusFingerprint(database)

  try database.write { database in
    try Node.where { $0.id.eq(node.id) }.update { $0.state = #bind(.archived) }.execute(database)
  }
  #expect(try EmbeddableCorpus.passageCorpusFingerprint(database) != before)
}

/// End to end, which is what actually protects the user: replace a passage through the supported
/// path and the NEXT sync must make the new prose findable and the old prose not.
@Test func syncPassagesRebuildsAfterAPassageIsReplaced() throws {
  let database = try makeStore()
  let store = tempSearchStore()
  let node = try addNode(database, name: "Pensieve")
  let event = try addSessionEvent(database, nodeID: node.id)
  try addPassage(database, nodeID: node.id, eventID: event.id,
                 text: "launchd refuses the spawn because the LWCR is stale")
  let indexer = SearchIndexer(store: store)
  indexer.syncPassages(database)
  let scope = SearchScope(visibleNodeIDs: [node.id])
  #expect(PassageQueries.search(query: "launchd", scope: scope, store: store, database).count == 1)

  try database.write { database in
    try Ingester.replacePassages(database, eventID: event.id, with: [
      Passage(nodeID: node.id, eventID: event.id, turnIndex: 0, messageIndex: 0, role: .prompt,
              text: "the FTS5 tokenizer strips diacritics", occurredAt: Date())])
  }
  indexer.syncPassages(database)
  #expect(PassageQueries.search(query: "launchd", scope: scope, store: store, database).isEmpty,
          "the replaced prose is gone from the index")
  #expect(PassageQueries.search(query: "tokenizer", scope: scope, store: store, database).count == 1,
          "and the new prose is findable")
}

/// An unchanged corpus must not rewrite the index — the whole point of guarding at all.
@Test func syncPassagesLeavesTheStoredHashAloneWhenNothingChanged() throws {
  let database = try makeStore()
  let store = tempSearchStore()
  let node = try addNode(database, name: "Pensieve")
  let event = try addSessionEvent(database, nodeID: node.id)
  try addPassage(database, nodeID: node.id, eventID: event.id, text: "why does launchd refuse")
  let indexer = SearchIndexer(store: store)
  indexer.syncPassages(database)
  let hash = store.storedPassagesHash()

  indexer.syncPassages(database)
  #expect(store.storedPassagesHash() == hash)
  #expect(hash == (try EmbeddableCorpus.passageCorpusFingerprint(database)),
          "the stored hash is the fingerprint, so the next process agrees without a rebuild")
}

// MARK: - the shared transcript window

/// The containment guard normalizes whitespace on both sides, like loose-end provenance — so a
/// passage stored before a change in how the parser joins text blocks still resolves its window
/// rather than reporting a live transcript as gone. Mutation-check: change
/// `TranscriptWindow.slice` back to a raw `contains` and this MUST fail.
@Test func aPassageWhoseWhitespaceDriftedStillResolvesItsWindow() throws {
  let database = try makeStore()
  let transcript = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("\(UUID().uuidString).jsonl")
  try """
    {"type":"user","cwd":"/tmp","sessionId":"s","timestamp":"2026-06-30T10:00:00Z",\
    "message":{"role":"user","content":"why does   launchd\\nrefuse the spawn"}}
    """.write(to: transcript, atomically: true, encoding: .utf8)
  let node = try addNode(database, name: "Pensieve")
  let event = try addSessionEvent(database, nodeID: node.id, transcriptPath: transcript.path)
  // Stored with single spaces where the transcript has a run and a newline.
  let passage = try addPassage(database, nodeID: node.id, eventID: event.id,
                               text: "why does launchd refuse the spawn")

  let window = try PassageProvenance.window(database, passage: passage, radius: 4)
  #expect(window.transcriptAvailable)
  #expect(window.messages.contains { $0.isCited })
}
