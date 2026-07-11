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
