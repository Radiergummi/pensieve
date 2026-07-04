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
private func spoolCommits(_ n: Int, on branch: String, repo: URL, spool: CaptureSpool) throws {
  _ = Git.run(["checkout", "-B", branch], in: repo.path)
  for i in 0..<n {
    try "\(branch)-\(i)".write(to: repo.appendingPathComponent("f\(branch)\(i).txt"), atomically: true, encoding: .utf8)
    _ = Git.run(["add", "-A"], in: repo.path)
    _ = Git.run(["commit", "-m", "\(branch) commit \(i)"], in: repo.path)
    let hash = Git.run(["rev-parse", "HEAD"], in: repo.path)!
    try spool.append(kind: CaptureKind.gitCommit,
                     payload: try encodeJSON(GitCommitPayload(repoPath: repo.path, hash: hash, branch: branch)))
  }
}

@Test func twoCommitsOnBranchBirthAStrand() async throws {
  let (repo, _) = try makeCommittedRepo()   // default "main"
  let spool = try CaptureSpool(at: tempURL("spool"))
  let db = try openCanonicalDatabase(at: tempURL("canon"))
  try spoolCommits(2, on: "feature-x", repo: repo, spool: spool)

  _ = try await Ingester(spool: spool, db: db).drain()

  let strands = try await db.read { db in try Node.where { $0.kind.eq("strand") }.fetchAll(db) }
  #expect(strands.count == 1)
  #expect(strands.first?.branchKey == "feature-x")
  // Both commits on the branch are repointed to the strand.
  let evs = try await db.read { db in try Event.where { $0.nodeID.eq(strands.first!.id) }.fetchAll(db) }
  #expect(evs.count == 2)
}

@Test func oneCommitStaysTaggedNoStrand() async throws {
  let (repo, _) = try makeCommittedRepo()
  let spool = try CaptureSpool(at: tempURL("spool"))
  let db = try openCanonicalDatabase(at: tempURL("canon"))
  try spoolCommits(1, on: "feature-y", repo: repo, spool: spool)

  _ = try await Ingester(spool: spool, db: db).drain()

  let strands = try await db.read { db in try Node.where { $0.kind.eq("strand") }.fetchAll(db) }
  #expect(strands.isEmpty)                              // tagged, not materialized
  let ev = try await db.read { db in try Event.all.fetchAll(db) }.first { $0.kind == CaptureKind.gitCommit }
  #expect(ev?.branchKey == "feature-y")                // branch is still recorded on the event
}

@Test func materializedStrandGetsLLMName() async throws {
  let (repo, _) = try makeCommittedRepo()
  let spool = try CaptureSpool(at: tempURL("spool"))
  let db = try openCanonicalDatabase(at: tempURL("canon"))
  try spoolCommits(2, on: "auth", repo: repo, spool: spool)

  _ = try await Ingester(spool: spool, db: db, llm: StubLLM(text: "Auth refactor\nReworking the login flow.")).drain()

  let strand = try await db.read { db in try Node.where { $0.kind.eq("strand") }.fetchAll(db) }.first
  #expect(strand?.name == "Auth refactor")
  #expect(strand?.description == "Reworking the login flow.")
}

@Test func strandNamingFailureLeavesBranchName() async throws {
  let (repo, _) = try makeCommittedRepo()
  let spool = try CaptureSpool(at: tempURL("spool"))
  let db = try openCanonicalDatabase(at: tempURL("canon"))
  try spoolCommits(2, on: "billing", repo: repo, spool: spool)

  _ = try await Ingester(spool: spool, db: db, llm: FailingLLM()).drain()

  let strand = try await db.read { db in try Node.where { $0.kind.eq("strand") }.fetchAll(db) }.first
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
  let db = try openCanonicalDatabase(at: tempURL("canon"))
  try spoolSession(id: "S1", on: "feature-s", repo: repo, spool: spool)
  try spoolSession(id: "S2", on: "feature-s", repo: repo, spool: spool)

  _ = try await Ingester(spool: spool, db: db).drain()

  let strands = try await db.read { db in try Node.where { $0.kind.eq("strand") }.fetchAll(db) }
  #expect(strands.count == 1)
  #expect(strands.first?.branchKey == "feature-s")
}

@Test func oneCommitPlusOneSessionDoesNotBirthStrand() async throws {
  let (repo, _) = try makeCommittedRepo()
  let spool = try CaptureSpool(at: tempURL("spool"))
  let db = try openCanonicalDatabase(at: tempURL("canon"))
  try spoolCommits(1, on: "mixed", repo: repo, spool: spool)   // leaves repo on branch "mixed"
  try spoolSession(id: "S9", on: "mixed", repo: repo, spool: spool)

  _ = try await Ingester(spool: spool, db: db).drain()

  let strands = try await db.read { db in try Node.where { $0.kind.eq("strand") }.fetchAll(db) }
  #expect(strands.isEmpty)                                     // threshold is 2 of the SAME kind
}
