import Foundation
import Testing
import SQLiteData
@testable import PensieveKit

private struct StubLLM: LLMProvider {
  let text: String
  func complete(prompt: String) async throws -> String { text }
}
private struct FailingLLM: LLMProvider {
  func complete(prompt: String) async throws -> String { throw LLMError.providerFailed("nope") }
}

/// Drains a single commit so a project node is born with the verbatim directory name.
private func bornProjectNode(repo: URL, spool: CaptureSpool, db: any DatabaseWriter,
                             llm: (any LLMProvider)? = nil) async throws -> Node {
  let hash = Git.run(["rev-parse", "HEAD"], in: repo.path)!
  try spool.append(kind: CaptureKind.gitCommit,
                   payload: try encodeJSON(GitCommitPayload(repoPath: repo.path, hash: hash, branch: "main")))
  _ = try await Ingester(spool: spool, db: db, llm: llm).drain()
  return try await db.read { db in try Node.where { $0.kind.eq(NodeKind.project) }.fetchAll(db) }.first!
}

// MARK: marker helpers

@Test func nameInferredMarkerRoundTrips() {
  #expect(Ingester.nameInferred(inMetadata: "{}") == false)
  let stamped = Ingester.settingNameInferred(in: "{}")
  #expect(Ingester.nameInferred(inMetadata: stamped) == true)
}

@Test func settingNameInferredPreservesOtherKeys() {
  let stamped = Ingester.settingNameInferred(in: #"{"foo":"bar"}"#)
  #expect(stamped.contains("\"foo\":\"bar\""))
  #expect(Ingester.nameInferred(inMetadata: stamped) == true)
}

// MARK: refine pass

@Test func refinesUntouchedGitProjectNameAndStampsMarker() async throws {
  let (repo, _) = try makeCommittedRepo()
  let spool = try CaptureSpool(at: tempURL("spool"))
  let db = try openCanonicalDatabase(at: tempURL("canon"))
  let node = try await bornProjectNode(repo: repo, spool: spool, db: db)

  await Ingester(spool: spool, db: db, llm: StubLLM(text: "Laravel RLS Package")).refineProjectNames()

  let after = try await db.read { db in try Node.where { $0.id.eq(node.id) }.fetchOne(db) }!
  #expect(after.name == "Laravel RLS Package")
  #expect(Ingester.nameInferred(inMetadata: after.metadataJSON) == true)
}

@Test func skipsHandRenamedNode() async throws {
  let (repo, _) = try makeCommittedRepo()
  let spool = try CaptureSpool(at: tempURL("spool"))
  let db = try openCanonicalDatabase(at: tempURL("canon"))
  let node = try await bornProjectNode(repo: repo, spool: spool, db: db)
  try await db.write { db in
    try Node.where { $0.id.eq(node.id) }.update { $0.name = "My Custom Name" }.execute(db)
  }

  await Ingester(spool: spool, db: db, llm: StubLLM(text: "Should Not Apply")).refineProjectNames()

  let after = try await db.read { db in try Node.where { $0.id.eq(node.id) }.fetchOne(db) }!
  #expect(after.name == "My Custom Name")                 // untouched-default guard
}

@Test func skipsNodeWithTwoGitRepoSources() async throws {
  let (repo, _) = try makeCommittedRepo()
  let spool = try CaptureSpool(at: tempURL("spool"))
  let db = try openCanonicalDatabase(at: tempURL("canon"))
  let node = try await bornProjectNode(repo: repo, spool: spool, db: db)
  // Simulate a merged (grouped) node: a second gitRepo source pointing elsewhere.
  try await db.write { db in
    try Source.insert { Source(nodeID: node.id, kind: SourceKind.gitRepo, key: "/other/repo/.git") }.execute(db)
  }

  await Ingester(spool: spool, db: db, llm: StubLLM(text: "Should Not Apply")).refineProjectNames()

  let after = try await db.read { db in try Node.where { $0.id.eq(node.id) }.fetchOne(db) }!
  #expect(after.name == node.name)                         // merged node left alone
}

@Test func markerMakesRefineIdempotentEvenWhenModelEchoesDefault() async throws {
  let (repo, _) = try makeCommittedRepo()
  let spool = try CaptureSpool(at: tempURL("spool"))
  let db = try openCanonicalDatabase(at: tempURL("canon"))
  let node = try await bornProjectNode(repo: repo, spool: spool, db: db)
  // Model returns the dir name verbatim: name stays == default, but the marker must still be set
  // so a second pass does NOT re-infer (no infinite re-naming loop).
  let echo = StubLLM(text: node.name)

  await Ingester(spool: spool, db: db, llm: echo).refineProjectNames()
  let mid = try await db.read { db in try Node.where { $0.id.eq(node.id) }.fetchOne(db) }!
  #expect(Ingester.nameInferred(inMetadata: mid.metadataJSON) == true)

  // Second pass with a DIFFERENT name must be a no-op because the node is already marked.
  await Ingester(spool: spool, db: db, llm: StubLLM(text: "Different Name")).refineProjectNames()
  let after = try await db.read { db in try Node.where { $0.id.eq(node.id) }.fetchOne(db) }!
  #expect(after.name == node.name)
}

@Test func failingProviderKeepsNameButStillStampsMarker() async throws {
  let (repo, _) = try makeCommittedRepo()
  let spool = try CaptureSpool(at: tempURL("spool"))
  let db = try openCanonicalDatabase(at: tempURL("canon"))
  let node = try await bornProjectNode(repo: repo, spool: spool, db: db)

  await Ingester(spool: spool, db: db, llm: FailingLLM()).refineProjectNames()

  let after = try await db.read { db in try Node.where { $0.id.eq(node.id) }.fetchOne(db) }!
  #expect(after.name == node.name)                         // fallback kept
  #expect(Ingester.nameInferred(inMetadata: after.metadataJSON) == true)   // but not retried
}

@Test func refineIsNoOpWithoutProvider() async throws {
  let (repo, _) = try makeCommittedRepo()
  let spool = try CaptureSpool(at: tempURL("spool"))
  let db = try openCanonicalDatabase(at: tempURL("canon"))
  let node = try await bornProjectNode(repo: repo, spool: spool, db: db)

  await Ingester(spool: spool, db: db, llm: nil).refineProjectNames()

  let after = try await db.read { db in try Node.where { $0.id.eq(node.id) }.fetchOne(db) }!
  #expect(after.name == node.name)
  #expect(Ingester.nameInferred(inMetadata: after.metadataJSON) == false)  // never attempted
}
