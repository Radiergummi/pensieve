import Foundation
import Testing
import SQLiteData
@testable import PensieveKit

// MARK: sanitize

@Test func sanitizeTrimsAndKeepsProse() {
  #expect(NodeDescriber.sanitize("  A tool for reconstructing project state.  ")
          == "A tool for reconstructing project state.")
}

@Test func sanitizeStripsLeadingListMarkerAndQuotes() {
  #expect(NodeDescriber.sanitize("- \"A native macOS capture tool.\"")
          == "A native macOS capture tool.")
}

@Test func sanitizeStripsCodeFences() {
  #expect(NodeDescriber.sanitize("```\nA background sync daemon.\n```")
          == "A background sync daemon.")
}

@Test func sanitizeStripsLeadingHeadingMarker() {
  #expect(NodeDescriber.sanitize("# A row-level-security package")
          == "A row-level-security package")
}

@Test func sanitizeReturnsNilForEmpty() {
  #expect(NodeDescriber.sanitize("   \n  ") == nil)
  #expect(NodeDescriber.sanitize("```\n\n```") == nil)
}

// MARK: describe (IO)

private struct StubLLM: LLMProvider {
  let text: String
  func complete(prompt: String) async throws -> String { text }
}

/// Records whether the provider was actually invoked (for the no-signal / no-LLM assertion).
private actor InvocationFlag { var invoked = false; func mark() { invoked = true } }
private struct SpyLLM: LLMProvider {
  let text: String
  let flag: InvocationFlag
  func complete(prompt: String) async throws -> String { await flag.mark(); return text }
}

/// Writes a file into a directory (creating intermediate dirs).
private func writeFile(_ text: String, to url: URL) throws {
  try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
  try text.write(to: url, atomically: true, encoding: .utf8)
}

/// A committed repo with a substantive README + a project node whose single git source points at it.
private func describableProjectNode(database: any DatabaseWriter) async throws -> (node: Node, repo: URL) {
  let (repo, _) = try makeCommittedRepo()
  try writeFile("# App\nRow-level security for Eloquent models, enforced at the database layer.",
                to: repo.appendingPathComponent("README.md"))
  let commonDir = Git.commonDir(in: repo.path)!
  let node = Node(name: "app", kind: NodeKind.project)
  try await database.write { database in
    try Node.insert { node }.execute(database)
    try Source.insert { Source(nodeID: node.id, kind: SourceKind.gitRepo, key: commonDir) }.execute(database)
  }
  return (node, repo)
}

@Test func describeWritesDescriptionForSubstantiveRepo() async throws {
  let database = try openCanonicalDatabase(at: tempURL("canon"))
  let (node, _) = try await describableProjectNode(database: database)

  let outcome = await NodeDescriber.describe(database, nodeID: node.id,
                                             provider: StubLLM(text: "A row-level-security package for Laravel."),
                                             force: false)

  #expect(outcome == .wrote)
  let after = try await database.read { database in try Node.where { $0.id.eq(node.id) }.fetchOne(database) }!
  #expect(after.description == "A row-level-security package for Laravel.")
}

@Test func describeReturnsNoSignalWithoutInvokingLLM() async throws {
  let database = try openCanonicalDatabase(at: tempURL("canon"))
  let (repo, _) = try makeCommittedRepo()   // no README/manifest → no meaningful signal
  let commonDir = Git.commonDir(in: repo.path)!
  let node = Node(name: "bare", kind: NodeKind.project)
  try await database.write { database in
    try Node.insert { node }.execute(database)
    try Source.insert { Source(nodeID: node.id, kind: SourceKind.gitRepo, key: commonDir) }.execute(database)
  }
  let flag = InvocationFlag()

  let outcome = await NodeDescriber.describe(database, nodeID: node.id,
                                             provider: SpyLLM(text: "should not run", flag: flag), force: false)

  #expect(outcome == .noSignal)
  #expect(await flag.invoked == false)       // gated before any LLM call
  let after = try await database.read { database in try Node.where { $0.id.eq(node.id) }.fetchOne(database) }!
  #expect(after.description == "")
}

@Test func describeReturnsAttemptedEmptyWhenModelSaysNothing() async throws {
  let database = try openCanonicalDatabase(at: tempURL("canon"))
  let (node, _) = try await describableProjectNode(database: database)

  let outcome = await NodeDescriber.describe(database, nodeID: node.id,
                                             provider: StubLLM(text: "   "), force: false)

  #expect(outcome == .attemptedEmpty)
  let after = try await database.read { database in try Node.where { $0.id.eq(node.id) }.fetchOne(database) }!
  #expect(after.description == "")           // nothing written → still eligible next pass
}

@Test func describeIsIneligibleForNonProjectNode() async throws {
  let database = try openCanonicalDatabase(at: tempURL("canon"))
  let node = Node(name: "s", kind: NodeKind.strand)
  try await database.write { database in try Node.insert { node }.execute(database) }

  let outcome = await NodeDescriber.describe(database, nodeID: node.id,
                                             provider: StubLLM(text: "x"), force: false)
  #expect(outcome == .ineligible)
}

@Test func describeIsIneligibleWithZeroOrTwoGitSources() async throws {
  let database = try openCanonicalDatabase(at: tempURL("canon"))
  // Zero git sources.
  let nodeWithoutGitSources = Node(name: "a", kind: NodeKind.project)
  try await database.write { database in try Node.insert { nodeWithoutGitSources }.execute(database) }
  #expect(await NodeDescriber.describe(database, nodeID: nodeWithoutGitSources.id, provider: StubLLM(text: "x"), force: false) == .ineligible)
  // Two git sources (merged node).
  let nodeWithTwoGitSources = Node(name: "b", kind: NodeKind.project)
  try await database.write { database in
    try Node.insert { nodeWithTwoGitSources }.execute(database)
    try Source.insert { Source(nodeID: nodeWithTwoGitSources.id, kind: SourceKind.gitRepo, key: "/x/.git") }.execute(database)
    try Source.insert { Source(nodeID: nodeWithTwoGitSources.id, kind: SourceKind.gitRepo, key: "/y/.git") }.execute(database)
  }
  #expect(await NodeDescriber.describe(database, nodeID: nodeWithTwoGitSources.id, provider: StubLLM(text: "x"), force: false) == .ineligible)
}

@Test func describeSkipsAlreadyDescribedUnlessForced() async throws {
  let database = try openCanonicalDatabase(at: tempURL("canon"))
  let (node, _) = try await describableProjectNode(database: database)
  try await database.write { database in
    try Node.where { $0.id.eq(node.id) }.update { $0.description = "Existing." }.execute(database)
  }

  // Without force: refuse to clobber.
  #expect(await NodeDescriber.describe(database, nodeID: node.id,
                                       provider: StubLLM(text: "New one."), force: false) == .ineligible)
  let mid = try await database.read { database in try Node.where { $0.id.eq(node.id) }.fetchOne(database) }!
  #expect(mid.description == "Existing.")

  // With force: overwrite.
  #expect(await NodeDescriber.describe(database, nodeID: node.id,
                                       provider: StubLLM(text: "New one."), force: true) == .wrote)
  let after = try await database.read { database in try Node.where { $0.id.eq(node.id) }.fetchOne(database) }!
  #expect(after.description == "New one.")
}

// MARK: describeProjectNodes (daemon pass)

@Test func passDescribesEligibleGitProjectNode() async throws {
  let spool = try CaptureSpool(at: tempURL("spool"))
  let database = try openCanonicalDatabase(at: tempURL("canon"))
  let (node, _) = try await describableProjectNode(database: database)

  await Ingester(spool: spool, database: database, llm: StubLLM(text: "A capture-and-recall tool."))
    .describeProjectNodes()

  let after = try await database.read { database in try Node.where { $0.id.eq(node.id) }.fetchOne(database) }!
  #expect(after.description == "A capture-and-recall tool.")
}

@Test func passIsNoOpWithoutProvider() async throws {
  let spool = try CaptureSpool(at: tempURL("spool"))
  let database = try openCanonicalDatabase(at: tempURL("canon"))
  let (node, _) = try await describableProjectNode(database: database)

  await Ingester(spool: spool, database: database, llm: nil).describeProjectNodes()

  let after = try await database.read { database in try Node.where { $0.id.eq(node.id) }.fetchOne(database) }!
  #expect(after.description == "")           // no provider → nothing attempted
}

@Test func passSkipsAlreadyDescribedNode() async throws {
  let spool = try CaptureSpool(at: tempURL("spool"))
  let database = try openCanonicalDatabase(at: tempURL("canon"))
  let (node, _) = try await describableProjectNode(database: database)
  try await database.write { database in
    try Node.where { $0.id.eq(node.id) }.update { $0.description = "Kept." }.execute(database)
  }

  await Ingester(spool: spool, database: database, llm: StubLLM(text: "Should not apply.")).describeProjectNodes()

  let after = try await database.read { database in try Node.where { $0.id.eq(node.id) }.fetchOne(database) }!
  #expect(after.description == "Kept.")      // non-empty description ⇒ not a candidate
}

@Test func passCapBoundsInvocationsNotCandidatesSoSignalLessNodesDontStarve() async throws {
  let spool = try CaptureSpool(at: tempURL("spool"))
  let database = try openCanonicalDatabase(at: tempURL("canon"))

  // 21 signal-less project nodes (bogus git-source keys → gather finds no worktree → .noSignal,
  // free, no LLM call). This exceeds descriptionRefineCap (20). If the cap counted CANDIDATES
  // instead of invocations, these 21 would exhaust it before the describable node below is reached.
  for index in 0..<21 {
    let emptyNode = Node(name: "empty-\(index)", kind: NodeKind.project)
    try await database.write { database in
      try Node.insert { emptyNode }.execute(database)
      try Source.insert { Source(nodeID: emptyNode.id, kind: SourceKind.gitRepo, key: "/nonexistent/repo-\(index)/.git") }.execute(database)
    }
  }
  // One describable node with a substantive README, inserted last (worst case for starvation).
  let (describable, _) = try await describableProjectNode(database: database)

  await Ingester(spool: spool, database: database, llm: StubLLM(text: "A real described project."))
    .describeProjectNodes()

  // Reached and described despite 21 signal-less candidates ahead of it — .noSignal consumes no cap slot.
  let after = try await database.read { database in try Node.where { $0.id.eq(describable.id) }.fetchOne(database) }!
  #expect(after.description == "A real described project.")
}
