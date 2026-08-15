import Foundation
import Testing
import SQLiteData
@testable import PensieveKit

/// Minimal LLM stub: `complete` returns a fixed string; structured methods inherit protocol defaults.
private struct StubLLM: LLMProvider {
  let text: String
  func complete(prompt: String) async throws -> String { text }
}
private struct FailingLLM: LLMProvider {
  func complete(prompt: String) async throws -> String { throw LLMError.providerFailed("nope") }
}

/// Appends N commits on `branch` to `repo` and spools them; returns nothing.
private func spoolCommits(_ numberOfCommits: Int, on branch: String, repo: URL, spool: CaptureSpool) throws {
  _ = Git.run(["checkout", "-B", branch], in: repo.path)
  for index in 0..<numberOfCommits {
    try "\(branch)-\(index)".write(to: repo.appendingPathComponent("f\(branch)\(index).txt"), atomically: true, encoding: .utf8)
    _ = Git.run(["add", "-A"], in: repo.path)
    _ = Git.run(["commit", "-m", "\(branch) commit \(index)"], in: repo.path)
    let hash = Git.run(["rev-parse", "HEAD"], in: repo.path)!
    try spool.append(kind: CaptureKind.gitCommit,
                     payload: try encodeJSON(GitCommitPayload(repoPath: repo.path, hash: hash, branch: branch)))
  }
}

@Test func twoCommitsOnBranchBirthAStrand() async throws {
  let (repo, _) = try makeCommittedRepo()   // default "main"
  let spool = try CaptureSpool(at: tempURL("spool"))
  let database = try openCanonicalDatabase(at: tempURL("canon"))
  try spoolCommits(2, on: "feature-x", repo: repo, spool: spool)

  _ = try await Ingester(spool: spool, database: database).drain()

  let strands = try await database.read { database in try Node.where { $0.kind.eq(NodeKind.strand) }.fetchAll(database) }
  #expect(strands.count == 1)
  #expect(strands.first?.branchKey == "feature-x")
  // Both commits on the branch are repointed to the strand.
  let evs = try await database.read { database in try Event.where { $0.nodeID.eq(strands.first!.id) }.fetchAll(database) }
  #expect(evs.count == 2)
}

@Test func oneCommitStaysTaggedNoStrand() async throws {
  let (repo, _) = try makeCommittedRepo()
  let spool = try CaptureSpool(at: tempURL("spool"))
  let database = try openCanonicalDatabase(at: tempURL("canon"))
  try spoolCommits(1, on: "feature-y", repo: repo, spool: spool)

  _ = try await Ingester(spool: spool, database: database).drain()

  let strands = try await database.read { database in try Node.where { $0.kind.eq(NodeKind.strand) }.fetchAll(database) }
  #expect(strands.isEmpty)                              // tagged, not materialized
  let event = try await database.read { database in try Event.all.fetchAll(database) }.first { $0.kind == CaptureKind.gitCommit }
  #expect(event?.branchKey == "feature-y")                // branch is still recorded on the event
}

@Test func materializedStrandGetsLLMName() async throws {
  let (repo, _) = try makeCommittedRepo()
  let spool = try CaptureSpool(at: tempURL("spool"))
  let database = try openCanonicalDatabase(at: tempURL("canon"))
  try spoolCommits(2, on: "auth", repo: repo, spool: spool)

  _ = try await Ingester(spool: spool, database: database, llm: StubLLM(text: "Auth refactor\nReworking the login flow.")).drain()

  let strand = try await database.read { database in try Node.where { $0.kind.eq(NodeKind.strand) }.fetchAll(database) }.first
  #expect(strand?.name == "Auth refactor")
  #expect(strand?.description == "Reworking the login flow.")
}

@Test func strandNamingFailureLeavesBranchName() async throws {
  let (repo, _) = try makeCommittedRepo()
  let spool = try CaptureSpool(at: tempURL("spool"))
  let database = try openCanonicalDatabase(at: tempURL("canon"))
  try spoolCommits(2, on: "billing", repo: repo, spool: spool)

  _ = try await Ingester(spool: spool, database: database, llm: FailingLLM()).drain()

  let strand = try await database.read { database in try Node.where { $0.kind.eq(NodeKind.strand) }.fetchAll(database) }.first
  #expect(strand?.name == "billing")                   // falls back to branch name
  #expect(strand?.description == "")
}

/// Spools a session-start row + a parsed session transcript on `branch` in `repo`.
private func spoolSession(id: String, on branch: String, repo: URL, spool: CaptureSpool) throws {
  let commonDir = Git.commonDir(in: repo.path) ?? repo.path
  try spool.append(kind: CaptureKind.ccSessionStart, payload: try encodeJSON(
    SessionStartPayload(sessionID: id, cwd: repo.path, branch: branch, commonDir: commonDir, transcriptPath: "")))
  // Named exactly `<id>.jsonl`: TranscriptParser derives sessionID from the transcript's
  // FILENAME (not from its JSON content), and the branch lookup below joins on that
  // sessionID against the SessionBranch row keyed by `id` — they must match verbatim.
  let transcript = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("\(id).jsonl")
  let line = """
    {"type":"user","cwd":"\(repo.path)","sessionId":"\(id)","timestamp":"2026-06-30T10:00:00Z","message":{"role":"user","content":"hi"}}
    """
  try line.write(to: transcript, atomically: true, encoding: .utf8)
  try spool.append(kind: CaptureKind.ccSession, payload: try encodeJSON(SessionRefPayload(transcriptPath: transcript.path)))
}

@Test func twoSessionsOnBranchBirthAStrand() async throws {
  let (repo, _) = try makeCommittedRepo()
  _ = Git.run(["checkout", "-B", "feature-s"], in: repo.path)
  let spool = try CaptureSpool(at: tempURL("spool"))
  let database = try openCanonicalDatabase(at: tempURL("canon"))
  try spoolSession(id: "S1", on: "feature-s", repo: repo, spool: spool)
  try spoolSession(id: "S2", on: "feature-s", repo: repo, spool: spool)

  _ = try await Ingester(spool: spool, database: database).drain()

  let strands = try await database.read { database in try Node.where { $0.kind.eq(NodeKind.strand) }.fetchAll(database) }
  #expect(strands.count == 1)
  #expect(strands.first?.branchKey == "feature-s")
}

@Test func oneCommitPlusOneSessionDoesNotBirthStrand() async throws {
  let (repo, _) = try makeCommittedRepo()
  let spool = try CaptureSpool(at: tempURL("spool"))
  let database = try openCanonicalDatabase(at: tempURL("canon"))
  try spoolCommits(1, on: "mixed", repo: repo, spool: spool)   // leaves repo on branch "mixed"
  try spoolSession(id: "S9", on: "mixed", repo: repo, spool: spool)

  _ = try await Ingester(spool: spool, database: database).drain()

  let strands = try await database.read { database in try Node.where { $0.kind.eq(NodeKind.strand) }.fetchAll(database) }
  #expect(strands.isEmpty)                                     // threshold is 2 of the SAME kind
}

/// A loose end extracted (by a prior drain) from an event that later gets repointed to a
/// strand must move with it — otherwise LooseEndQueries.open(nodeID: strand) misses it.
@Test func strandBirthRepointsLooseEndsFromEarlierDrain() async throws {
  let (repo, _) = try makeCommittedRepo()
  let spool = try CaptureSpool(at: tempURL("spool"))
  let database = try openCanonicalDatabase(at: tempURL("canon"))

  // First drain: single commit on the feature branch — stays tagged at the project node.
  try spoolCommits(1, on: "feature-z", repo: repo, spool: spool)
  _ = try await Ingester(spool: spool, database: database).drain()

  let firstEvent = try await database.read { database in
    try Event.where { $0.kind.eq(CaptureKind.gitCommit) && $0.branchKey.eq("feature-z") }.fetchAll(database)
  }.first
  let projectNodeID = try #require(firstEvent?.nodeID)
  let looseEnd = LooseEnd(nodeID: projectNodeID, sourceEventID: try #require(firstEvent?.id),
                          text: "x", quote: "some verbatim quote")
  try await database.write { database in try LooseEnd.insert { looseEnd }.execute(database) }
  // A passage extracted (by a prior drain) from the same earlier event must move with it too —
  // `passage.nodeID` is what retrieval and the search corpus both read, so a passage left behind
  // names the wrong node in every surface.
  let passage = Passage(nodeID: projectNodeID, eventID: try #require(firstEvent?.id), turnIndex: 0,
                        messageIndex: 0, role: .prompt, text: "y", occurredAt: Date())
  try await database.write { database in try Passage.insert { passage }.execute(database) }

  // Second drain: another (distinct) commit on the same branch — crosses the threshold,
  // strand is born. Written inline (not via spoolCommits, which always writes index `0` and
  // would produce a no-op/duplicate commit if called again with n: 1 on the same branch).
  try "feature-z-1".write(to: repo.appendingPathComponent("second.txt"), atomically: true, encoding: .utf8)
  _ = Git.run(["add", "-A"], in: repo.path)
  _ = Git.run(["commit", "-m", "feature-z commit 1"], in: repo.path)
  let secondHash = Git.run(["rev-parse", "HEAD"], in: repo.path)!
  try spool.append(kind: CaptureKind.gitCommit,
                   payload: try encodeJSON(GitCommitPayload(repoPath: repo.path, hash: secondHash, branch: "feature-z")))
  _ = try await Ingester(spool: spool, database: database).drain()

  let strand = try await database.read { database in try Node.where { $0.kind.eq(NodeKind.strand) }.fetchAll(database) }.first
  let strandID = try #require(strand?.id)
  let updated = try await database.read { database in try LooseEnd.where { $0.id.eq(looseEnd.id) }.fetchOne(database) }
  #expect(updated?.nodeID == strandID)
  let updatedPassage = try await database.read { database in try Passage.where { $0.id.eq(passage.id) }.fetchOne(database) }
  #expect(updatedPassage?.nodeID == strandID)
}
