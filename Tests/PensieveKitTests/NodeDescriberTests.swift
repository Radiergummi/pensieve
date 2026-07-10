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
private func describableProjectNode(db: any DatabaseWriter) async throws -> (node: Node, repo: URL) {
  let (repo, _) = try makeCommittedRepo()
  try writeFile("# App\nRow-level security for Eloquent models, enforced at the database layer.",
                to: repo.appendingPathComponent("README.md"))
  let commonDir = Git.commonDir(in: repo.path)!
  let node = Node(name: "app", kind: NodeKind.project)
  try await db.write { db in
    try Node.insert { node }.execute(db)
    try Source.insert { Source(nodeID: node.id, kind: SourceKind.gitRepo, key: commonDir) }.execute(db)
  }
  return (node, repo)
}

@Test func describeWritesDescriptionForSubstantiveRepo() async throws {
  let db = try openCanonicalDatabase(at: tempURL("canon"))
  let (node, _) = try await describableProjectNode(db: db)

  let outcome = await NodeDescriber.describe(db, nodeID: node.id,
                                             provider: StubLLM(text: "A row-level-security package for Laravel."),
                                             force: false)

  #expect(outcome == .wrote)
  let after = try await db.read { db in try Node.where { $0.id.eq(node.id) }.fetchOne(db) }!
  #expect(after.description == "A row-level-security package for Laravel.")
}

@Test func describeReturnsNoSignalWithoutInvokingLLM() async throws {
  let db = try openCanonicalDatabase(at: tempURL("canon"))
  let (repo, _) = try makeCommittedRepo()   // no README/manifest → no meaningful signal
  let commonDir = Git.commonDir(in: repo.path)!
  let node = Node(name: "bare", kind: NodeKind.project)
  try await db.write { db in
    try Node.insert { node }.execute(db)
    try Source.insert { Source(nodeID: node.id, kind: SourceKind.gitRepo, key: commonDir) }.execute(db)
  }
  let flag = InvocationFlag()

  let outcome = await NodeDescriber.describe(db, nodeID: node.id,
                                             provider: SpyLLM(text: "should not run", flag: flag), force: false)

  #expect(outcome == .noSignal)
  #expect(await flag.invoked == false)       // gated before any LLM call
  let after = try await db.read { db in try Node.where { $0.id.eq(node.id) }.fetchOne(db) }!
  #expect(after.description == "")
}

@Test func describeReturnsAttemptedEmptyWhenModelSaysNothing() async throws {
  let db = try openCanonicalDatabase(at: tempURL("canon"))
  let (node, _) = try await describableProjectNode(db: db)

  let outcome = await NodeDescriber.describe(db, nodeID: node.id,
                                             provider: StubLLM(text: "   "), force: false)

  #expect(outcome == .attemptedEmpty)
  let after = try await db.read { db in try Node.where { $0.id.eq(node.id) }.fetchOne(db) }!
  #expect(after.description == "")           // nothing written → still eligible next pass
}

@Test func describeIsIneligibleForNonProjectNode() async throws {
  let db = try openCanonicalDatabase(at: tempURL("canon"))
  let node = Node(name: "s", kind: NodeKind.strand)
  try await db.write { db in try Node.insert { node }.execute(db) }

  let outcome = await NodeDescriber.describe(db, nodeID: node.id,
                                             provider: StubLLM(text: "x"), force: false)
  #expect(outcome == .ineligible)
}

@Test func describeIsIneligibleWithZeroOrTwoGitSources() async throws {
  let db = try openCanonicalDatabase(at: tempURL("canon"))
  // Zero git sources.
  let a = Node(name: "a", kind: NodeKind.project)
  try await db.write { db in try Node.insert { a }.execute(db) }
  #expect(await NodeDescriber.describe(db, nodeID: a.id, provider: StubLLM(text: "x"), force: false) == .ineligible)
  // Two git sources (merged node).
  let b = Node(name: "b", kind: NodeKind.project)
  try await db.write { db in
    try Node.insert { b }.execute(db)
    try Source.insert { Source(nodeID: b.id, kind: SourceKind.gitRepo, key: "/x/.git") }.execute(db)
    try Source.insert { Source(nodeID: b.id, kind: SourceKind.gitRepo, key: "/y/.git") }.execute(db)
  }
  #expect(await NodeDescriber.describe(db, nodeID: b.id, provider: StubLLM(text: "x"), force: false) == .ineligible)
}

@Test func describeSkipsAlreadyDescribedUnlessForced() async throws {
  let db = try openCanonicalDatabase(at: tempURL("canon"))
  let (node, _) = try await describableProjectNode(db: db)
  try await db.write { db in
    try Node.where { $0.id.eq(node.id) }.update { $0.description = "Existing." }.execute(db)
  }

  // Without force: refuse to clobber.
  #expect(await NodeDescriber.describe(db, nodeID: node.id,
                                       provider: StubLLM(text: "New one."), force: false) == .ineligible)
  let mid = try await db.read { db in try Node.where { $0.id.eq(node.id) }.fetchOne(db) }!
  #expect(mid.description == "Existing.")

  // With force: overwrite.
  #expect(await NodeDescriber.describe(db, nodeID: node.id,
                                       provider: StubLLM(text: "New one."), force: true) == .wrote)
  let after = try await db.read { db in try Node.where { $0.id.eq(node.id) }.fetchOne(db) }!
  #expect(after.description == "New one.")
}

// MARK: describeProjectNodes (daemon pass)

@Test func passDescribesEligibleGitProjectNode() async throws {
  let spool = try CaptureSpool(at: tempURL("spool"))
  let db = try openCanonicalDatabase(at: tempURL("canon"))
  let (node, _) = try await describableProjectNode(db: db)

  await Ingester(spool: spool, db: db, llm: StubLLM(text: "A capture-and-recall tool."))
    .describeProjectNodes()

  let after = try await db.read { db in try Node.where { $0.id.eq(node.id) }.fetchOne(db) }!
  #expect(after.description == "A capture-and-recall tool.")
}

@Test func passIsNoOpWithoutProvider() async throws {
  let spool = try CaptureSpool(at: tempURL("spool"))
  let db = try openCanonicalDatabase(at: tempURL("canon"))
  let (node, _) = try await describableProjectNode(db: db)

  await Ingester(spool: spool, db: db, llm: nil).describeProjectNodes()

  let after = try await db.read { db in try Node.where { $0.id.eq(node.id) }.fetchOne(db) }!
  #expect(after.description == "")           // no provider → nothing attempted
}

@Test func passSkipsAlreadyDescribedNode() async throws {
  let spool = try CaptureSpool(at: tempURL("spool"))
  let db = try openCanonicalDatabase(at: tempURL("canon"))
  let (node, _) = try await describableProjectNode(db: db)
  try await db.write { db in
    try Node.where { $0.id.eq(node.id) }.update { $0.description = "Kept." }.execute(db)
  }

  await Ingester(spool: spool, db: db, llm: StubLLM(text: "Should not apply.")).describeProjectNodes()

  let after = try await db.read { db in try Node.where { $0.id.eq(node.id) }.fetchOne(db) }!
  #expect(after.description == "Kept.")      // non-empty description ⇒ not a candidate
}

@Test func passCapBoundsInvocationsNotCandidatesSoSignalLessNodesDontStarve() async throws {
  let spool = try CaptureSpool(at: tempURL("spool"))
  let db = try openCanonicalDatabase(at: tempURL("canon"))

  // 21 signal-less project nodes (bogus git-source keys → gather finds no worktree → .noSignal,
  // free, no LLM call). This exceeds descriptionRefineCap (20). If the cap counted CANDIDATES
  // instead of invocations, these 21 would exhaust it before the describable node below is reached.
  for i in 0..<21 {
    let n = Node(name: "empty-\(i)", kind: NodeKind.project)
    try await db.write { db in
      try Node.insert { n }.execute(db)
      try Source.insert { Source(nodeID: n.id, kind: SourceKind.gitRepo, key: "/nonexistent/repo-\(i)/.git") }.execute(db)
    }
  }
  // One describable node with a substantive README, inserted last (worst case for starvation).
  let (describable, _) = try await describableProjectNode(db: db)

  await Ingester(spool: spool, db: db, llm: StubLLM(text: "A real described project."))
    .describeProjectNodes()

  // Reached and described despite 21 signal-less candidates ahead of it — .noSignal consumes no cap slot.
  let after = try await db.read { db in try Node.where { $0.id.eq(describable.id) }.fetchOne(db) }!
  #expect(after.description == "A real described project.")
}
