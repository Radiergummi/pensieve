import Testing
import Foundation
@testable import PensieveKit

private func tmp(_ n: String, ext: String) -> URL {
  FileManager.default.temporaryDirectory.appendingPathComponent("\(n)-\(UUID().uuidString)").appendingPathExtension(ext)
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
  for i in 0..<prompts {
    lines.append(#"{"type":"user","cwd":"\#(cwd)","timestamp":"2026-06-30T10:0\#(i):00Z","message":{"role":"user","content":"prompt \#(i)"}}"#)
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
  let db = try openCanonicalDatabase(at: tmp("sync-canon", ext: "sqlite"))
  func runner() -> SyncRunner {
    SyncRunner(spool: spool, db: db, provider: NoopProvider(),
               projectsDir: projects, now: { Date() })
  }

  // Cycle 1: discovers + ingests the session.
  let s1 = try await runner().run()
  #expect(s1.discovered == 1)
  #expect(s1.ingested >= 1)
  let ingested = try await db.read { db in
    try Event.where { $0.fingerprint.eq(Fingerprint.session(sessionID: sessionID)) }.fetchOne(db)
  }
  #expect(ingested != nil)
  let sizeAfter1 = ingested?.extractedTranscriptSize ?? -99

  // Cycle 2: nothing new — already an event, byte size unchanged.
  let s2 = try await runner().run()
  #expect(s2.discovered == 0)
  #expect(s2.ingested == 0)

  // Grow the transcript, then Cycle 3 re-extracts (watermark size advances).
  let more = #"{"type":"user","cwd":"\#(FileManager.default.temporaryDirectory.path)","timestamp":"2026-06-30T10:05:00Z","message":{"role":"user","content":"prompt later"}}"# + "\n"
  let handle = try FileHandle(forWritingTo: txURL)
  try handle.seekToEnd(); handle.write(Data(more.utf8)); try handle.close()

  _ = try await runner().run()
  let after3 = try await db.read { db in
    try Event.where { $0.fingerprint.eq(Fingerprint.session(sessionID: sessionID)) }.fetchOne(db)
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
  let db = try openCanonicalDatabase(at: tmp("sync-canon", ext: "sqlite"))

  // A committed repo + one spooled commit → a project node born with the verbatim dir name.
  let (repo, hash) = try makeCommittedRepo()
  try spool.append(kind: CaptureKind.gitCommit,
                   payload: try encodeJSON(GitCommitPayload(repoPath: repo.path, hash: hash, branch: "main")))

  let runner = SyncRunner(spool: spool, db: db, provider: NamingProvider(name: "Cool Project"),
                          projectsDir: projects, now: { Date() })
  _ = try await runner.run()

  let node = try await db.read { db in try Node.where { $0.kind.eq("project") }.fetchAll(db) }.first!
  #expect(node.name == "Cool Project")
  #expect(Ingester.nameInferred(inMetadata: node.metadataJSON) == true)
}

/// Proves the injected `semanticIndexer` runs at the end of `run()` and populates the index
/// (an active node is embeddable content per `EmbeddableCorpus.gather`).
@Test func syncPopulatesSemanticIndexWhenEnabled() async throws {
  let projects = tmp("projects", ext: "d")
  try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
  let spool = try CaptureSpool(at: tmp("sync-spool", ext: "sqlite"))
  let db = try openCanonicalDatabase(at: tmp("sync-canon", ext: "sqlite"))

  try await db.write { db in
    let n = Node(name: "Indexed project", kind: NodeKind.project)
    try Node.insert { n }.execute(db)
  }

  let idxURL = tmp("s", ext: "sqlite")
  let store = SemanticIndexStore(url: idxURL, dimension: 16, embedderVersion: "stub:16")
  let runner = SyncRunner(spool: spool, db: db, provider: NoopProvider(), projectsDir: projects,
                         now: { Date() },
                         semanticIndexer: SemanticIndexer(store: store, embedder: StubEmbedder(dimension: 16)))
  _ = try await runner.run()

  #expect(!store.existingItems().isEmpty)
}
