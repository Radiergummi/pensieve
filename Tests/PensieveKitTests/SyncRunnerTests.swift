import Testing
import Foundation
@testable import PensieveKit

private func tmp(_ name: String, ext: String) -> URL {
  FileManager.default.temporaryDirectory.appendingPathComponent("\(name)-\(UUID().uuidString)").appendingPathExtension(ext)
}

/// A provider that returns no loose ends — keeps SyncRunner tests about discovery/ingestion,
/// not extraction content (extraction correctness is covered by ExtractionRunnerTests). All
/// three methods are implemented explicitly so extraction never throws (the default
/// classifyGenuineIndices throws on an unparseable response), keeping the watermark assertion
/// deterministic.
private struct NoopProvider: LLMProvider {
  func complete(prompt: String) async throws -> String { "" }
  func extractCandidates(prompt: String) async throws -> [LooseEndCandidate] { [] }
  func classifyGenuineIndices(prompt: String) async throws -> [Int] { [] }
}

/// Writes a minimal but attributable transcript (has cwd + a user prompt) under
/// <projects>/repoA/<sessionID>.jsonl.
@discardableResult
private func writeSession(_ projects: URL, _ sessionID: String, prompts: Int) throws -> URL {
  let dir = projects.appendingPathComponent("repoA", isDirectory: true)
  try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
  let cwd = FileManager.default.temporaryDirectory.path
  var lines: [String] = []
  for index in 0..<prompts {
    lines.append(#"{"type":"user","cwd":"\#(cwd)","timestamp":"2026-06-30T10:0\#(index):00Z","# +
                 #""message":{"role":"user","content":"prompt \#(index)"}}"#)
  }
  let url = dir.appendingPathComponent("\(sessionID).jsonl")
  try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
  return url
}

@Test func syncDiscoversIngestsThenNoOpsThenReextractsOnGrowth() async throws {
  let projects = tmp("projects", ext: "d")
  try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
  let sessionID = UUID().uuidString
  let txURL = try writeSession(projects, sessionID, prompts: 1)

  let spool = try CaptureSpool(at: tmp("sync-spool", ext: "sqlite"))
  let database = try openCanonicalDatabase(at: tmp("sync-canon", ext: "sqlite"))
  func runner() -> SyncRunner {
    SyncRunner(spool: spool, database: database, provider: NoopProvider(),
               projectsDir: projects, now: { Date() })
  }

  // Cycle 1: discovers + ingests the session.
  let status1 = try await runner().run()
  #expect(status1.discovered == 1)
  #expect(status1.ingested >= 1)
  let ingested = try await database.read { database in
    try Event.where { $0.fingerprint.eq(Fingerprint.session(sessionID: sessionID)) }.fetchOne(database)
  }
  #expect(ingested != nil)
  let sizeAfter1 = ingested?.extractedTranscriptSize ?? -99

  // Cycle 2: nothing new — already an event, byte size unchanged.
  let status2 = try await runner().run()
  #expect(status2.discovered == 0)
  #expect(status2.ingested == 0)

  // Grow the transcript, then Cycle 3 re-extracts (watermark size advances).
  let more = #"{"type":"user","cwd":"\#(FileManager.default.temporaryDirectory.path)","# +
    #""timestamp":"2026-06-30T10:05:00Z","message":{"role":"user","content":"prompt later"}}"# + "\n"
  let handle = try FileHandle(forWritingTo: txURL)
  try handle.seekToEnd(); handle.write(Data(more.utf8)); try handle.close()

  _ = try await runner().run()
  let after3 = try await database.read { database in
    try Event.where { $0.fingerprint.eq(Fingerprint.session(sessionID: sessionID)) }.fetchOne(database)
  }
  #expect((after3?.extractedTranscriptSize ?? -1) > sizeAfter1)   // re-extraction ran on growth
}

/// A provider that returns a fixed name (and no loose ends) so the refine pass is deterministic.
private struct NamingProvider: LLMProvider {
  let name: String
  func complete(prompt: String) async throws -> String { name }
  func extractCandidates(prompt: String) async throws -> [LooseEndCandidate] { [] }
  func classifyGenuineIndices(prompt: String) async throws -> [Int] { [] }
}

@Test func syncRefinesGitProjectNameAfterDrain() async throws {
  let projects = tmp("projects", ext: "d")
  try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
  let spool = try CaptureSpool(at: tmp("sync-spool", ext: "sqlite"))
  let database = try openCanonicalDatabase(at: tmp("sync-canon", ext: "sqlite"))

  // A committed repo + one spooled commit → a project node born with the verbatim dir name.
  let (repo, hash) = try makeCommittedRepo()
  try spool.append(kind: CaptureKind.gitCommit,
                   payload: try encodeJSON(GitCommitPayload(repoPath: repo.path, hash: hash, branch: "main")))

  let runner = SyncRunner(spool: spool, database: database, provider: NamingProvider(name: "Cool Project"),
                          projectsDir: projects, now: { Date() })
  _ = try await runner.run()

  let node = try await database.read { database in try Node.where { $0.kind.eq(NodeKind.project) }.fetchAll(database) }.first!
  #expect(node.name == "Cool Project")
  #expect(Ingester.nameInferred(inMetadata: node.metadataJSON) == true)
}

/// The retired vector path must leave no way back in. `SyncRunner` used to construct a
/// SemanticIndexer itself when none was injected and the toggle was on — pointing at the SHARED
/// index path, so any caller could rebuild a real index it never asked for. This pins the surviving
/// shape: one optional indexer, no self-construction, and a run that indexes only what it was given.
@Test func syncTakesOnlyASearchIndexer() async throws {
  let projects = tmp("projects", ext: "d")
  try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
  let spool = try CaptureSpool(at: tmp("sync-onlysearch-spool", ext: "sqlite"))
  let database = try openCanonicalDatabase(at: tmp("sync-onlysearch-canon", ext: "sqlite"))
  let node = Node(name: "Background sync agent", kind: NodeKind.project)
  try await database.write { database in try Node.insert { node }.execute(database) }

  let store = SearchIndexStore(url: tmp("sync-onlysearch-index", ext: "sqlite"))
  // Compiles ONLY while `semanticIndexer:` does not exist: adding it back with a default would keep
  // this green, but re-adding a self-constructing fallback is what the deleted `else if` did, and
  // Step 4's grep is what guards that.
  let runner = SyncRunner(spool: spool, database: database, provider: NoopProvider(),
                          projectsDir: projects, searchIndexer: SearchIndexer(store: store))
  _ = try await runner.run()

  #expect(store.state() == .ready)
  #expect(store.search(FTSQueryBuilder.build("background ")!, limit: 5,
                       includeArchived: false).map(\.itemID) == [node.id.uuidString])
}

/// Proves the injected `searchIndexer` runs at the end of `run()` and leaves a ready, searchable
/// FTS5 index. Unlike the semantic one this is NOT toggle-gated — BM25 is the only retrieval path.
@Test func runBuildsTheSearchIndex() async throws {
  let projects = tmp("projects", ext: "d")
  try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
  let spool = try CaptureSpool(at: tmp("sync-search-spool", ext: "sqlite"))
  let database = try openCanonicalDatabase(at: tmp("sync-search-canon", ext: "sqlite"))

  let node = Node(name: "Background sync agent", kind: NodeKind.project)
  try await database.write { database in try Node.insert { node }.execute(database) }

  let store = SearchIndexStore(url: tmp("sync-search-index", ext: "sqlite"))
  let runner = SyncRunner(spool: spool, database: database, provider: NoopProvider(),
                          projectsDir: projects, searchIndexer: SearchIndexer(store: store))
  _ = try await runner.run()

  #expect(store.state() == .ready)
  #expect(store.search(FTSQueryBuilder.build("background ")!, limit: 5,
                       includeArchived: false).map(\.itemID) == [node.id.uuidString])
}

// NOTE: "a nil `searchIndexer` writes to no index" is deliberately NOT unit-tested. The obvious test —
// assert some bystander store is untouched — is vacuous, because `SyncRunner` has no way to reach a
// fresh temp URL and so passes it whether or not a `PensievePaths` fallback exists. Testing it for
// real means pointing `PENSIEVE_DB` at a temp path, and `setenv` is process-global while Swift Testing
// runs suites in parallel. The property is held by the type (`SearchIndexer?`, no `??` in `run()`) and
// by `PensievePathsTests.indexPathFollowsAnOverriddenStore`, which makes the fallback harmless anyway.
