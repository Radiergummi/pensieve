import Foundation
import Testing
import SQLiteData
@testable import PensieveKit

@Test func nodeIDResolvesABoundNonGitPath() throws {
  let database = try openCanonicalDatabase(at: tempURL("sc"))
  let dir = try makePlainDir()   // not a git repo
  let (node, _) = try ProjectResolver(database: database).resolve(path: dir.path, kind: SourceKind.claudeCode)
  let resolved = try SessionContextQueries.nodeID(forPath: dir.path, database)
  #expect(resolved == node.id)
}

@Test func nodeIDResolvesAGitCwdViaCommonDir() throws {
  let database = try openCanonicalDatabase(at: tempURL("sc"))
  let (repo, _) = try makeCommittedRepo()
  // Seed the source the way capture does: keyed on the git common-dir, not the working dir.
  let common = Git.commonDir(in: repo.path)!
  let (node, _) = try ProjectResolver(database: database).resolve(path: common, kind: SourceKind.gitRepo)
  // Resolve from the WORKING directory — must map through the common-dir to the same node.
  let resolved = try SessionContextQueries.nodeID(forPath: repo.path, database)
  #expect(resolved == node.id)
}

@Test func nodeIDReturnsNilForUnboundPath() throws {
  let database = try openCanonicalDatabase(at: tempURL("sc"))
  let dir = try makePlainDir()
  #expect(try SessionContextQueries.nodeID(forPath: dir.path, database) == nil)
}

/// A canned provider: `complete` returns a fixed string so narration is deterministic and offline.
private struct StubProvider: LLMProvider {
  let reply: String
  func complete(prompt: String) async throws -> String { reply }
}

/// Seeds one node with one event + one loose end; returns the node and the event.
private func seedOneNode(_ database: any DatabaseWriter) throws -> (node: Node, event: Event) {
  let (node, source) = try ProjectResolver(database: database).resolve(path: "/p/one", kind: SourceKind.claudeCode)
  // Carries a `workSummary`, i.e. an ENRICHED session. Without one, a `cc.session`'s summary is a
  // generated label in production (`"session (N prompts)"`) and `SummaryBuilder` will not narrate
  // it — so a fixture lacking it cannot exercise the narration paths below.
  let event = Event(nodeID: node.id, sourceID: source.id, occurredAt: Date(),
                    kind: CaptureKind.ccSession, summary: "did the thing", detailJSON: "{}",
                    fingerprint: "f1", workSummary: "did the thing")
  try database.write { database in
    try Event.insert { event }.execute(database)
    try LooseEnd.insert {
      LooseEnd(nodeID: node.id, sourceEventID: event.id, text: "finish auth",
               quote: "we must finish the auth flow", role: "user", sourceMessageIndex: 0)
    }.execute(database)
  }
  return (node, event)
}

@Test func bundleComposesGroundedState() async throws {
  let database = try openCanonicalDatabase(at: tempURL("sc"))
  let (node, _) = try seedOneNode(database)
  let bundle = try #require(try await SessionContextQueries.bundle(
    forPath: "/p/one", nodeID: nil, database, now: Date(),
    narration: NarrationOptions(summaryBuilder: nil, providerKind: "fm", cache: nil)))
  #expect(bundle.nodeID == node.id)
  #expect(bundle.openLooseEndCount == 1)
  #expect(bundle.looseEnds.first?.quote == "we must finish the auth flow")
  #expect(bundle.recentEvents.first?.summary == "did the thing")
  #expect(bundle.prose == nil)   // no builder, empty cache → no prose (never a facts-dump)
}

@Test func bundleReturnsNilForUnboundPath() async throws {
  let database = try openCanonicalDatabase(at: tempURL("sc"))
  let bundle = try await SessionContextQueries.bundle(
    forPath: "/nope", nodeID: nil, database, now: Date(),
    narration: NarrationOptions(summaryBuilder: nil, providerKind: "fm", cache: nil))
  #expect(bundle == nil)
}

/// `pensieve prime` must be able to HIT an entry the app wrote — i.e. the app's narration cache key
/// for a node and `bundle`'s key for the same node must be the same string.
///
/// This agreement was broken for the entire life of the feature and nothing pinned it. The key is
/// `NarrationCacheKey.make(events: status.recentEvents, …)`, so it depends on how many recent events
/// the caller asked for: the app asked `ProjectQueries.status` for 15 while `bundle` defaulted
/// `recentLimit` to 8, and a lookup built from 8 events can never match an entry keyed on 15. The
/// SessionStart hook that exists to hand a session warm context was therefore permanently cold.
///
/// **The fixture seeds MORE events than the window** on purpose. The sibling tests in this file use
/// `limit: 8` literals and pass only because their fixture has one event, so 8 and 15 select the
/// same set — exactly the vacuity that let the bug live. With 20 events the window size is load-
/// bearing, and this test reproduces the APP's spelling of the key
/// (`SummaryBuilder.narratableEventWindow`, which is what `AppModel+Recall`/`DetailView` pass) rather
/// than restating a number.
@Test func primeCanHitTheNarrationEntryTheAppWrote() async throws {
  let database = try openCanonicalDatabase(at: tempURL("sc-narration-key"))
  let (node, source) = try ProjectResolver(database: database)
    .resolve(path: "/p/window", kind: SourceKind.claudeCode)
  try await database.write { database in
    for index in 0..<20 {
      let occurredAt = Calendar.current.date(byAdding: .hour, value: -index, to: Date())!
      try Event.insert {
        Event(nodeID: node.id, sourceID: source.id, occurredAt: occurredAt,
              kind: CaptureKind.ccSession, summary: "work \(index)", detailJSON: "{}",
              fingerprint: "win-\(index)", workSummary: "work \(index)")
      }.execute(database)
    }
  }

  // THE APP's path, verbatim: `ProjectQueries.status(node:limit:)` at the shared window, then
  // `NarrationCacheKey.make`. This is what `AppModel.narration(for:events:)` stores under.
  let appEvents = try ProjectQueries.status(database, node: node,
                                            limit: SummaryBuilder.narratableEventWindow).recentEvents
  #expect(appEvents.count == SummaryBuilder.narratableEventWindow)   // the window really is clamping
  let cache = NarrationCache(url: tempURL("narr-window"))
  cache.put(NarrationCacheKey.make(events: appEvents, provider: "fm"), prose: "the app wrote this")

  // MCP / `pensieve prime`: no builder, so a MISS yields nil prose and cannot be mistaken for a hit.
  let bundle = try #require(try await SessionContextQueries.bundle(
    forPath: "/p/window", nodeID: nil, database, now: Date(),
    narration: NarrationOptions(summaryBuilder: nil, providerKind: "fm", cache: cache)))
  #expect(bundle.prose == "the app wrote this")
}

@Test func bundleServesCachedProseWithoutABuilder() async throws {
  let database = try openCanonicalDatabase(at: tempURL("sc"))
  let (node, _) = try seedOneNode(database)
  let cache = NarrationCache(url: tempURL("narr"))
  // Pre-warm the cache with the exact key bundle() will compute (top recentLimit events, same provider).
  let events = try ProjectQueries.status(database, node: node, limit: SummaryBuilder.narratableEventWindow).recentEvents
  cache.put(NarrationCacheKey.make(events: events, provider: "fm"), prose: "cached recap")
  let bundle = try #require(try await SessionContextQueries.bundle(
    forPath: "/p/one", nodeID: nil, database, now: Date(),
    narration: NarrationOptions(summaryBuilder: nil, providerKind: "fm", cache: cache)))
  #expect(bundle.prose == "cached recap")
}

@Test func bundleNarratesOnMissAndWritesThrough() async throws {
  let database = try openCanonicalDatabase(at: tempURL("sc"))
  let (node, _) = try seedOneNode(database)
  let cache = NarrationCache(url: tempURL("narr"))
  let builder = SummaryBuilder(provider: StubProvider(reply: "fresh recap"))
  let bundle = try #require(try await SessionContextQueries.bundle(
    forPath: "/p/one", nodeID: nil, database, now: Date(),
    narration: NarrationOptions(summaryBuilder: builder, providerKind: "fm", cache: cache)))
  #expect(bundle.prose == "fresh recap")
  // Write-through: the key is now populated.
  let events = try ProjectQueries.status(database, node: node, limit: SummaryBuilder.narratableEventWindow).recentEvents
  #expect(cache.get(NarrationCacheKey.make(events: events, provider: "fm")) == "fresh recap")
}

@Test func bundleLooseEndCarriesItsID() async throws {
  let database = try openCanonicalDatabase(at: tempURL("sc"))
  let (node, event) = try seedOneNode(database)
  // The one loose end seeded by seedOneNode — read its id back for the assertion.
  let seededID = try #require(try await database.read { database in
    try LooseEnd.where { $0.nodeID.eq(node.id) }.fetchOne(database)?.id
  })
  _ = event
  let bundle = try #require(try await SessionContextQueries.bundle(
    forPath: "/p/one", nodeID: nil, database, now: Date(),
    narration: NarrationOptions(summaryBuilder: nil, providerKind: "fm", cache: nil)))
  #expect(bundle.looseEnds.first?.id == seededID)
}

@Test func rankedContextFiltersSlicesAndCites() throws {
  let database = try openCanonicalDatabase(at: tempURL("sc"))
  let resolver = ProjectResolver(database: database)
  let (work, workSource) = try resolver.resolve(path: "/p/work", kind: SourceKind.claudeCode)
  let (personal, personalSource) = try resolver.resolve(path: "/p/personal", kind: SourceKind.claudeCode)
  let old = Calendar.current.date(byAdding: .day, value: -10, to: Date())!
  try database.write { database in
    try Node.where { $0.id.eq(work.id) }.update { $0.context = #bind(NodeContext.work) }.execute(database)
    try Node.where { $0.id.eq(personal.id) }.update { $0.context = #bind(NodeContext.personal) }.execute(database)
    let eventWork = Event(nodeID: work.id, sourceID: workSource.id, occurredAt: old, kind: CaptureKind.ccSession,
                   summary: "s", detailJSON: "{}", fingerprint: "w1")
    let eventPersonal = Event(nodeID: personal.id, sourceID: personalSource.id, occurredAt: old, kind: CaptureKind.ccSession,
                   summary: "s", detailJSON: "{}", fingerprint: "p1")
    try Event.insert { eventWork }.execute(database); try Event.insert { eventPersonal }.execute(database)
    try LooseEnd.insert {
      LooseEnd(nodeID: work.id, sourceEventID: eventWork.id, text: "t",
               quote: "ship the work thing", role: "user", sourceMessageIndex: 0)
    }.execute(database)
  }
  // Unfiltered: both nodes present.
  #expect(try SessionContextQueries.rankedContext(limit: 5, context: nil, database, now: Date()).count == 2)
  // Work focus: personal is muted; the work node's top loose end is cited.
  let workOnly = try SessionContextQueries.rankedContext(limit: 5, context: NodeContext.work, database, now: Date())
  #expect(workOnly.count == 1)
  #expect(workOnly.first?.nodeID == work.id)
  #expect(workOnly.first?.topLooseEnd == "ship the work thing")
  // Limit is honored.
  #expect(try SessionContextQueries.rankedContext(limit: 1, context: nil, database, now: Date()).count == 1)
}

// MARK: - Recall tests

/// Local copy of the transcript writer (mirrors ProvenanceQueriesTests): one JSONL line per
/// (type, text); "user" prose → isUserPrompt true.
private func writeRecallTranscript(_ prefix: String, _ lines: [(type: String, text: String)]) throws -> URL {
  let url = tempURL(prefix, ext: "jsonl")
  let jsonl = lines.map { line in
    #"{"type":"\#(line.type)","cwd":"/p/app","timestamp":"2026-06-29T13:03:43.382Z","# +
      #""message":{"role":"\#(line.type)","content":"\#(line.text)"}}"#
  }.joined(separator: "\n")
  try jsonl.write(to: url, atomically: true, encoding: .utf8)
  return url
}

/// Inserts an event pointing at `transcriptURL` + a loose end citing `citedIndex` with `quote`.
private func seedRecallLooseEnd(_ database: any DatabaseWriter, transcriptURL: URL,
                                citedIndex: Int, quote: String) throws -> LooseEnd {
  let (node, source) = try ProjectResolver(database: database).resolve(path: "/p/recall", kind: SourceKind.claudeCode)
  let detail = try encodeJSON(["transcriptPath": transcriptURL.path, "sessionID": "s", "prompts": "2"])
  let event = Event(nodeID: node.id, sourceID: source.id, occurredAt: Date(),
                    kind: CaptureKind.ccSession, summary: "session", detailJSON: detail, fingerprint: "fpr")
  let looseEnd = LooseEnd(nodeID: node.id, sourceEventID: event.id, text: "finish the migration",
                    quote: quote, role: "user", sourceMessageIndex: citedIndex)
  try database.write { database in
    try Event.insert { event }.execute(database)
    try LooseEnd.insert { looseEnd }.execute(database)
  }
  return looseEnd
}

@Test func recallReturnsWindowAroundCitedUserPrompt() throws {
  let database = try openCanonicalDatabase(at: tempURL("recall-happy"))
  let url = try writeRecallTranscript("recall-happy", [
    (type: "user", text: "hello there"),                            // index 0
    (type: "assistant", text: "sure working on it"),                // index 1
    (type: "user", text: "we still need to finish the migration"),  // index 2 (cited)
    (type: "assistant", text: "got it"),                            // index 3
    (type: "user", text: "thanks"),                                 // index 4
  ])
  let looseEnd = try seedRecallLooseEnd(database, transcriptURL: url, citedIndex: 2, quote: "finish the migration")
  let bundle = try #require(try SessionContextQueries.recall(looseEndID: looseEnd.id, radius: 1, database))
  #expect(bundle.transcriptAvailable)
  #expect(bundle.quote == "finish the migration")
  #expect(bundle.looseEndText == "finish the migration")
  #expect(bundle.messages.map(\.index) == [1, 2, 3])   // radius 1 around index 2
  let cited = bundle.messages.first { $0.isCited }
  #expect(cited?.index == 2)
  #expect(cited?.isUserPrompt == true)
}

@Test func recallRespectsRadius() throws {
  let database = try openCanonicalDatabase(at: tempURL("recall-radius"))
  let url = try writeRecallTranscript("recall-radius", [
    (type: "user", text: "aaa"), (type: "assistant", text: "bbb"),
    (type: "user", text: "we still need to finish the migration"),  // index 2 (cited)
    (type: "assistant", text: "ccc"), (type: "user", text: "ddd"),
  ])
  let looseEnd = try seedRecallLooseEnd(database, transcriptURL: url, citedIndex: 2, quote: "finish the migration")
  let bundle = try #require(try SessionContextQueries.recall(looseEndID: looseEnd.id, radius: 4, database))
  #expect(bundle.messages.map(\.index) == [0, 1, 2, 3, 4])   // wider radius → whole clamped window
}

@Test func recallReturnsNilForUnknownID() throws {
  let database = try openCanonicalDatabase(at: tempURL("recall-unknown"))
  #expect(try SessionContextQueries.recall(looseEndID: UUID(), radius: 8, database) == nil)
}

@Test func recallDegradesHonestlyWhenTranscriptGone() throws {
  let database = try openCanonicalDatabase(at: tempURL("recall-gone"))
  let gone = tempURL("recall-gone-file", ext: "jsonl")   // never written to disk
  let looseEnd = try seedRecallLooseEnd(database, transcriptURL: gone, citedIndex: 0, quote: "anything")
  let bundle = try #require(try SessionContextQueries.recall(looseEndID: looseEnd.id, radius: 8, database))
  #expect(bundle.transcriptAvailable == false)
  #expect(bundle.messages.isEmpty)
  #expect(bundle.quote == "anything")   // stored quote preserved for honest fallback
}

/// A provider that ignores cancellation, the way a blocking system call does.
///
/// This is not a strawman: `ClaudeCLIProvider` became cancellation-aware only when `ChildProcessSlot`
/// was added, and the DEFAULT provider on macOS 26 is Foundation Models, whose
/// `LanguageModelSession.respond` is Apple's code and promises nothing about cancellation.
private struct UncancellableProvider: LLMProvider {
  let delay: TimeInterval
  let reply: String
  func complete(prompt: String) async throws -> String {
    // Suspends on a continuation that cancellation cannot resume — NOT `Task.sleep` (which would
    // observe cancellation and test the opposite of the point), and NOT a blocking `usleep` (which
    // occupies a cooperative-pool thread and made this test flaky under the full parallel suite:
    // 0.44 s alone, 2.39 s contended).
    //
    // This is also the more faithful model. The real hazard is not a thread that will not yield, it
    // is a suspension nothing can wake — exactly what `Server.listRoots` does, and what Apple's
    // `LanguageModelSession.respond` gives no guarantee against.
    await withCheckedContinuation { continuation in
      DispatchQueue.global().asyncAfter(deadline: .now() + delay) { continuation.resume() }
    }
    return reply
  }
}

/// The narration budget must be a real wall-clock bound, not a best-effort one.
///
/// `narrateWithin` used to be a `withTaskGroup` race, which silently does not bound anything: a task
/// group awaits ALL its children before returning, so `cancelAll()` only helps when the losing child
/// observes cancellation. Measured with that shape, a child ignoring cancellation turned a 0.5 s
/// budget into a 3.01 s return; a cancellation-aware one returned in 0.50 s. With Foundation Models
/// as the default provider — behind its own 120 s cap — that let a 3 s budget block MCP's
/// `project_context` for up to two minutes after it had already decided to answer without prose.
///
/// **The margins are wide on purpose.** A first attempt asserted `< 2 s` against a 4 s provider and
/// was flaky in roughly half of full-suite runs (2.09 s, 2.33 s, 2.39 s observed) while passing in
/// 0.41 s alone. The budget was being enforced correctly every time; what varies is *scheduling* —
/// with 879 tests running in parallel the cooperative pool is saturated, so the timeout's own
/// `Task.sleep` is delivered late and the measured wall-clock absorbs that delay.
///
/// So the provider is given a 20 s delay against a 0.3 s budget and the assertion allows 8 s: over
/// 3x the worst scheduling noise observed, and still 2.5x below the 20 s a regression would take.
/// It pins "the budget is enforced at all", never a latency figure. A tighter bound here would be a
/// test of the machine's load, not of this code.
@Test func narrationBudgetIsEnforcedEvenWhenTheProviderIgnoresCancellation() async throws {
  let database = try openCanonicalDatabase(at: tempURL("sc-timeout"))
  _ = try seedOneNode(database)
  let providerDelay: TimeInterval = 20
  let builder = SummaryBuilder(provider: UncancellableProvider(delay: providerDelay, reply: "too late"))

  let start = Date()
  let bundle = try #require(try await SessionContextQueries.bundle(
    forPath: "/p/one", nodeID: nil, database, now: Date(),
    narration: NarrationOptions(summaryBuilder: builder, providerKind: "fm",
                                cache: nil, timeout: 0.3)))
  let waited = Date().timeIntervalSince(start)

  // Costs nothing while passing: the abandoned narration is never awaited, so the 20 s elapses in
  // the background of a test that has already returned.
  #expect(waited < 8, "narration budget not enforced — waited \(waited)s on a 0.3s budget against a \(providerDelay)s provider")
  // And it degrades honestly: no prose rather than a fabricated one. The bundle's grounded parts
  // (name, loose ends) must still be there — giving up on prose is not giving up on the answer.
  #expect(bundle.prose == nil)
  #expect(!bundle.looseEnds.isEmpty)
}
