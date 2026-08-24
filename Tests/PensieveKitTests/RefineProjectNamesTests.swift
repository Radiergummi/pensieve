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

/// A committed repo that carries real signal — a README with a body past its title line — which is
/// what `ProjectContext.hasMeaningfulSignal` requires before the naming pass will ask a model
/// anything at all.
///
/// Every test below that exercises a naming *guard* needs this. `makeCommittedRepo` alone produces a
/// repo holding only `a.txt`, and a node born from that is deliberately un-nameable now: without it
/// the tests asserting "the name did not change" would pass because the signal gate skipped the node
/// before their guard was ever reached — the vacuous-pass trap, not a verified guard.
private func makeRepoWithSignal() throws -> (repo: URL, hash: String) {
  let (repo, hash) = try makeCommittedRepo()
  try "# App\nRow-level security for Eloquent models, enforced at the database layer."
    .write(to: repo.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
  return (repo, hash)
}

/// Drains a single commit so a project node is born with the verbatim directory name.
private func bornProjectNode(repo: URL, spool: CaptureSpool, database: any DatabaseWriter,
                             llm: (any LLMProvider)? = nil) async throws -> Node {
  let hash = Git.run(["rev-parse", "HEAD"], in: repo.path)!
  try spool.append(kind: CaptureKind.gitCommit,
                   payload: try encodeJSON(GitCommitPayload(repoPath: repo.path, hash: hash, branch: "main")))
  _ = try await Ingester(spool: spool, database: database, llm: llm).drain()
  return try await database.read { database in try Node.where { $0.kind.eq(NodeKind.project) }.fetchAll(database) }.first!
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
  let (repo, _) = try makeRepoWithSignal()
  let spool = try CaptureSpool(at: tempURL("spool"))
  let database = try openCanonicalDatabase(at: tempURL("canon"))
  let node = try await bornProjectNode(repo: repo, spool: spool, database: database)

  await Ingester(spool: spool, database: database, llm: StubLLM(text: "Laravel RLS Package")).refineProjectNames()

  let after = try await database.read { database in try Node.where { $0.id.eq(node.id) }.fetchOne(database) }!
  #expect(after.name == "Laravel RLS Package")
  #expect(Ingester.nameInferred(inMetadata: after.metadataJSON) == true)
}

@Test func skipsHandRenamedNode() async throws {
  let (repo, _) = try makeRepoWithSignal()
  let spool = try CaptureSpool(at: tempURL("spool"))
  let database = try openCanonicalDatabase(at: tempURL("canon"))
  let node = try await bornProjectNode(repo: repo, spool: spool, database: database)
  try await database.write { database in
    try Node.where { $0.id.eq(node.id) }.update { $0.name = "My Custom Name" }.execute(database)
  }

  await Ingester(spool: spool, database: database, llm: StubLLM(text: "Should Not Apply")).refineProjectNames()

  let after = try await database.read { database in try Node.where { $0.id.eq(node.id) }.fetchOne(database) }!
  #expect(after.name == "My Custom Name")                 // untouched-default guard
}

@Test func skipsNodeWithTwoGitRepoSources() async throws {
  let (repo, _) = try makeRepoWithSignal()
  let spool = try CaptureSpool(at: tempURL("spool"))
  let database = try openCanonicalDatabase(at: tempURL("canon"))
  let node = try await bornProjectNode(repo: repo, spool: spool, database: database)
  // Simulate a merged (grouped) node: a second gitRepo source pointing elsewhere.
  try await database.write { database in
    try Source.insert { Source(nodeID: node.id, kind: SourceKind.gitRepo, key: "/other/repo/.git") }.execute(database)
  }

  await Ingester(spool: spool, database: database, llm: StubLLM(text: "Should Not Apply")).refineProjectNames()

  let after = try await database.read { database in try Node.where { $0.id.eq(node.id) }.fetchOne(database) }!
  #expect(after.name == node.name)                         // merged node left alone
}

@Test func markerMakesRefineIdempotentEvenWhenModelEchoesDefault() async throws {
  let (repo, _) = try makeRepoWithSignal()
  let spool = try CaptureSpool(at: tempURL("spool"))
  let database = try openCanonicalDatabase(at: tempURL("canon"))
  let node = try await bornProjectNode(repo: repo, spool: spool, database: database)
  // Model returns the dir name verbatim: name stays == default, but the marker must still be set
  // so a second pass does NOT re-infer (no infinite re-naming loop).
  let echo = StubLLM(text: node.name)

  await Ingester(spool: spool, database: database, llm: echo).refineProjectNames()
  let mid = try await database.read { database in try Node.where { $0.id.eq(node.id) }.fetchOne(database) }!
  #expect(Ingester.nameInferred(inMetadata: mid.metadataJSON) == true)

  // Second pass with a DIFFERENT name must be a no-op because the node is already marked.
  await Ingester(spool: spool, database: database, llm: StubLLM(text: "Different Name")).refineProjectNames()
  let after = try await database.read { database in try Node.where { $0.id.eq(node.id) }.fetchOne(database) }!
  #expect(after.name == node.name)
}

@Test func failingProviderKeepsNameButStillStampsMarker() async throws {
  let (repo, _) = try makeRepoWithSignal()
  let spool = try CaptureSpool(at: tempURL("spool"))
  let database = try openCanonicalDatabase(at: tempURL("canon"))
  let node = try await bornProjectNode(repo: repo, spool: spool, database: database)

  await Ingester(spool: spool, database: database, llm: FailingLLM()).refineProjectNames()

  let after = try await database.read { database in try Node.where { $0.id.eq(node.id) }.fetchOne(database) }!
  #expect(after.name == node.name)                         // fallback kept
  #expect(Ingester.nameInferred(inMetadata: after.metadataJSON) == true)   // but not retried
}

/// The signal gate `NodeDescriber.describe` has always applied to the same input, now applied here
/// too. With nothing but a directory name to go on the model has nothing to infer FROM, so it
/// invents something plausible instead: this is how `wt-550` became "Weight Transfer Tool" and
/// `web-trace-570` became "Web Trace Viewer 570" in the live store.
///
/// Two assertions, and the second is the one that matters most: the node must be left UNMARKED, so
/// that once the repo grows a README it gets named for real rather than being permanently retired
/// with a fabricated name.
@Test func signalLessRepoIsNeitherNamedNorMarkedSoItRetriesLater() async throws {
  let (repo, _) = try makeCommittedRepo()   // only `a.txt`: no README, no manifest → no signal
  let spool = try CaptureSpool(at: tempURL("spool"))
  let database = try openCanonicalDatabase(at: tempURL("canon"))
  let node = try await bornProjectNode(repo: repo, spool: spool, database: database)

  await Ingester(spool: spool, database: database,
                 llm: StubLLM(text: "Weight Transfer Tool")).refineProjectNames()

  let after = try await database.read { database in try Node.where { $0.id.eq(node.id) }.fetchOne(database) }!
  #expect(after.name == node.name)                                          // invention not applied
  #expect(Ingester.nameInferred(inMetadata: after.metadataJSON) == false)    // and it will retry

  // And the pairing half: give the SAME repo real signal and the pass now names it, proving the
  // skip above was the gate and not some unrelated guard swallowing the candidate.
  try "# App\nRow-level security for Eloquent models, enforced at the database layer."
    .write(to: repo.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
  await Ingester(spool: spool, database: database,
                 llm: StubLLM(text: "Laravel RLS Package")).refineProjectNames()

  let named = try await database.read { database in try Node.where { $0.id.eq(node.id) }.fetchOne(database) }!
  #expect(named.name == "Laravel RLS Package")
  #expect(Ingester.nameInferred(inMetadata: named.metadataJSON) == true)
}

@Test func refineIsNoOpWithoutProvider() async throws {
  let (repo, _) = try makeRepoWithSignal()
  let spool = try CaptureSpool(at: tempURL("spool"))
  let database = try openCanonicalDatabase(at: tempURL("canon"))
  let node = try await bornProjectNode(repo: repo, spool: spool, database: database)

  await Ingester(spool: spool, database: database, llm: nil).refineProjectNames()

  let after = try await database.read { database in try Node.where { $0.id.eq(node.id) }.fetchOne(database) }!
  #expect(after.name == node.name)
  #expect(Ingester.nameInferred(inMetadata: after.metadataJSON) == false)  // never attempted
}
