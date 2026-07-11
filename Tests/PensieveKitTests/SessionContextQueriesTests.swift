import Foundation
import Testing
import SQLiteData
@testable import PensieveKit

@Test func nodeIDResolvesABoundNonGitPath() throws {
  let db = try openCanonicalDatabase(at: tempURL("sc"))
  let dir = try makePlainDir()   // not a git repo
  let (node, _) = try ProjectResolver(db: db).resolve(path: dir.path, kind: SourceKind.claudeCode)
  let resolved = try SessionContextQueries.nodeID(forPath: dir.path, db)
  #expect(resolved == node.id)
}

@Test func nodeIDResolvesAGitCwdViaCommonDir() throws {
  let db = try openCanonicalDatabase(at: tempURL("sc"))
  let (repo, _) = try makeCommittedRepo()
  // Seed the source the way capture does: keyed on the git common-dir, not the working dir.
  let common = Git.commonDir(in: repo.path)!
  let (node, _) = try ProjectResolver(db: db).resolve(path: common, kind: SourceKind.gitRepo)
  // Resolve from the WORKING directory — must map through the common-dir to the same node.
  let resolved = try SessionContextQueries.nodeID(forPath: repo.path, db)
  #expect(resolved == node.id)
}

@Test func nodeIDReturnsNilForUnboundPath() throws {
  let db = try openCanonicalDatabase(at: tempURL("sc"))
  let dir = try makePlainDir()
  #expect(try SessionContextQueries.nodeID(forPath: dir.path, db) == nil)
}

/// A canned provider: `complete` returns a fixed string so narration is deterministic and offline.
private struct StubProvider: LLMProvider {
  let reply: String
  func complete(prompt: String) async throws -> String { reply }
}

/// Seeds one node with one event + one loose end; returns the node and the event.
private func seedOneNode(_ db: any DatabaseWriter) throws -> (node: Node, event: Event) {
  let (node, source) = try ProjectResolver(db: db).resolve(path: "/p/one", kind: SourceKind.claudeCode)
  let event = Event(nodeID: node.id, sourceID: source.id, occurredAt: Date(),
                    kind: CaptureKind.ccSession, summary: "did the thing", detailJSON: "{}", fingerprint: "f1")
  try db.write { db in
    try Event.insert { event }.execute(db)
    try LooseEnd.insert {
      LooseEnd(nodeID: node.id, sourceEventID: event.id, text: "finish auth",
               quote: "we must finish the auth flow", role: "user", sourceMessageIndex: 0)
    }.execute(db)
  }
  return (node, event)
}

@Test func bundleComposesGroundedState() async throws {
  let db = try openCanonicalDatabase(at: tempURL("sc"))
  let (node, _) = try seedOneNode(db)
  let bundle = try #require(try await SessionContextQueries.bundle(
    forPath: "/p/one", nodeID: nil, db, now: Date(),
    summaryBuilder: nil, providerKind: "fm", cache: nil))
  #expect(bundle.nodeID == node.id)
  #expect(bundle.openLooseEndCount == 1)
  #expect(bundle.looseEnds.first?.quote == "we must finish the auth flow")
  #expect(bundle.recentEvents.first?.summary == "did the thing")
  #expect(bundle.prose == nil)   // no builder, empty cache → no prose (never a facts-dump)
}

@Test func bundleReturnsNilForUnboundPath() async throws {
  let db = try openCanonicalDatabase(at: tempURL("sc"))
  let bundle = try await SessionContextQueries.bundle(
    forPath: "/nope", nodeID: nil, db, now: Date(),
    summaryBuilder: nil, providerKind: "fm", cache: nil)
  #expect(bundle == nil)
}

@Test func bundleServesCachedProseWithoutABuilder() async throws {
  let db = try openCanonicalDatabase(at: tempURL("sc"))
  let (node, _) = try seedOneNode(db)
  let cache = NarrationCache(url: tempURL("narr"))
  // Pre-warm the cache with the exact key bundle() will compute (top recentLimit events, same provider).
  let events = try ProjectQueries.status(db, node: node, limit: 8).recentEvents
  cache.put(NarrationCacheKey.make(events: events, provider: "fm"), prose: "cached recap")
  let bundle = try #require(try await SessionContextQueries.bundle(
    forPath: "/p/one", nodeID: nil, db, now: Date(),
    summaryBuilder: nil, providerKind: "fm", cache: cache))
  #expect(bundle.prose == "cached recap")
}

@Test func bundleNarratesOnMissAndWritesThrough() async throws {
  let db = try openCanonicalDatabase(at: tempURL("sc"))
  let (node, _) = try seedOneNode(db)
  let cache = NarrationCache(url: tempURL("narr"))
  let builder = SummaryBuilder(provider: StubProvider(reply: "fresh recap"))
  let bundle = try #require(try await SessionContextQueries.bundle(
    forPath: "/p/one", nodeID: nil, db, now: Date(),
    summaryBuilder: builder, providerKind: "fm", cache: cache))
  #expect(bundle.prose == "fresh recap")
  // Write-through: the key is now populated.
  let events = try ProjectQueries.status(db, node: node, limit: 8).recentEvents
  #expect(cache.get(NarrationCacheKey.make(events: events, provider: "fm")) == "fresh recap")
}

@Test func bundleLooseEndCarriesItsID() async throws {
  let db = try openCanonicalDatabase(at: tempURL("sc"))
  let (node, event) = try seedOneNode(db)
  // The one loose end seeded by seedOneNode — read its id back for the assertion.
  let seededID = try #require(try await db.read { db in
    try LooseEnd.where { $0.nodeID.eq(node.id) }.fetchOne(db)?.id
  })
  _ = event
  let bundle = try #require(try await SessionContextQueries.bundle(
    forPath: "/p/one", nodeID: nil, db, now: Date(),
    summaryBuilder: nil, providerKind: "fm", cache: nil))
  #expect(bundle.looseEnds.first?.id == seededID)
}

@Test func rankedContextFiltersSlicesAndCites() throws {
  let db = try openCanonicalDatabase(at: tempURL("sc"))
  let resolver = ProjectResolver(db: db)
  let (work, ws) = try resolver.resolve(path: "/p/work", kind: SourceKind.claudeCode)
  let (personal, ps) = try resolver.resolve(path: "/p/personal", kind: SourceKind.claudeCode)
  let old = Calendar.current.date(byAdding: .day, value: -10, to: Date())!
  try db.write { db in
    try Node.where { $0.id.eq(work.id) }.update { $0.context = #bind(NodeContext.work) }.execute(db)
    try Node.where { $0.id.eq(personal.id) }.update { $0.context = #bind(NodeContext.personal) }.execute(db)
    let ew = Event(nodeID: work.id, sourceID: ws.id, occurredAt: old, kind: CaptureKind.ccSession,
                   summary: "s", detailJSON: "{}", fingerprint: "w1")
    let ep = Event(nodeID: personal.id, sourceID: ps.id, occurredAt: old, kind: CaptureKind.ccSession,
                   summary: "s", detailJSON: "{}", fingerprint: "p1")
    try Event.insert { ew }.execute(db); try Event.insert { ep }.execute(db)
    try LooseEnd.insert {
      LooseEnd(nodeID: work.id, sourceEventID: ew.id, text: "t",
               quote: "ship the work thing", role: "user", sourceMessageIndex: 0)
    }.execute(db)
  }
  // Unfiltered: both nodes present.
  #expect(try SessionContextQueries.rankedContext(limit: 5, context: nil, db, now: Date()).count == 2)
  // Work focus: personal is muted; the work node's top loose end is cited.
  let work_only = try SessionContextQueries.rankedContext(limit: 5, context: NodeContext.work, db, now: Date())
  #expect(work_only.count == 1)
  #expect(work_only.first?.nodeID == work.id)
  #expect(work_only.first?.topLooseEnd == "ship the work thing")
  // Limit is honored.
  #expect(try SessionContextQueries.rankedContext(limit: 1, context: nil, db, now: Date()).count == 1)
}

// MARK: - Recall tests

/// Local copy of the transcript writer (mirrors ProvenanceQueriesTests): one JSONL line per
/// (type, text); "user" prose → isUserPrompt true.
private func writeRecallTranscript(_ prefix: String, _ lines: [(type: String, text: String)]) throws -> URL {
  let url = tempURL(prefix, ext: "jsonl")
  let jsonl = lines.map { line in
    #"{"type":"\#(line.type)","cwd":"/p/app","timestamp":"2026-06-29T13:03:43.382Z","message":{"role":"\#(line.type)","content":"\#(line.text)"}}"#
  }.joined(separator: "\n")
  try jsonl.write(to: url, atomically: true, encoding: .utf8)
  return url
}

/// Inserts an event pointing at `transcriptURL` + a loose end citing `citedIndex` with `quote`.
private func seedRecallLooseEnd(_ db: any DatabaseWriter, transcriptURL: URL,
                                citedIndex: Int, quote: String) throws -> LooseEnd {
  let (node, source) = try ProjectResolver(db: db).resolve(path: "/p/recall", kind: SourceKind.claudeCode)
  let detail = try encodeJSON(["transcriptPath": transcriptURL.path, "sessionID": "s", "prompts": "2"])
  let event = Event(nodeID: node.id, sourceID: source.id, occurredAt: Date(),
                    kind: CaptureKind.ccSession, summary: "session", detailJSON: detail, fingerprint: "fpr")
  let le = LooseEnd(nodeID: node.id, sourceEventID: event.id, text: "finish the migration",
                    quote: quote, role: "user", sourceMessageIndex: citedIndex)
  try db.write { db in
    try Event.insert { event }.execute(db)
    try LooseEnd.insert { le }.execute(db)
  }
  return le
}

@Test func recallReturnsWindowAroundCitedUserPrompt() throws {
  let db = try openCanonicalDatabase(at: tempURL("recall-happy"))
  let url = try writeRecallTranscript("recall-happy", [
    (type: "user", text: "hello there"),                            // index 0
    (type: "assistant", text: "sure working on it"),                // index 1
    (type: "user", text: "we still need to finish the migration"),  // index 2 (cited)
    (type: "assistant", text: "got it"),                            // index 3
    (type: "user", text: "thanks"),                                 // index 4
  ])
  let le = try seedRecallLooseEnd(db, transcriptURL: url, citedIndex: 2, quote: "finish the migration")
  let bundle = try #require(try SessionContextQueries.recall(looseEndID: le.id, radius: 1, db))
  #expect(bundle.transcriptAvailable)
  #expect(bundle.quote == "finish the migration")
  #expect(bundle.looseEndText == "finish the migration")
  #expect(bundle.messages.map(\.index) == [1, 2, 3])   // radius 1 around index 2
  let cited = bundle.messages.first { $0.isCited }
  #expect(cited?.index == 2)
  #expect(cited?.isUserPrompt == true)
}

@Test func recallRespectsRadius() throws {
  let db = try openCanonicalDatabase(at: tempURL("recall-radius"))
  let url = try writeRecallTranscript("recall-radius", [
    (type: "user", text: "aaa"), (type: "assistant", text: "bbb"),
    (type: "user", text: "we still need to finish the migration"),  // index 2 (cited)
    (type: "assistant", text: "ccc"), (type: "user", text: "ddd"),
  ])
  let le = try seedRecallLooseEnd(db, transcriptURL: url, citedIndex: 2, quote: "finish the migration")
  let bundle = try #require(try SessionContextQueries.recall(looseEndID: le.id, radius: 4, db))
  #expect(bundle.messages.map(\.index) == [0, 1, 2, 3, 4])   // wider radius → whole clamped window
}

@Test func recallReturnsNilForUnknownID() throws {
  let db = try openCanonicalDatabase(at: tempURL("recall-unknown"))
  #expect(try SessionContextQueries.recall(looseEndID: UUID(), radius: 8, db) == nil)
}

@Test func recallDegradesHonestlyWhenTranscriptGone() throws {
  let db = try openCanonicalDatabase(at: tempURL("recall-gone"))
  let gone = tempURL("recall-gone-file", ext: "jsonl")   // never written to disk
  let le = try seedRecallLooseEnd(db, transcriptURL: gone, citedIndex: 0, quote: "anything")
  let bundle = try #require(try SessionContextQueries.recall(looseEndID: le.id, radius: 8, db))
  #expect(bundle.transcriptAvailable == false)
  #expect(bundle.messages.isEmpty)
  #expect(bundle.quote == "anything")   // stored quote preserved for honest fallback
}
