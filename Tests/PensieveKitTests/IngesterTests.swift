import Foundation
import Testing
import SQLiteData
@testable import PensieveKit

@Test func ingestsGitCommitIntoEvent() throws {
  // Arrange: a real temp git repo with one commit.
  let (repo, hash) = try makeCommittedRepo()
  let spool = try CaptureSpool(at: tempURL("spool"))
  let db = try openCanonicalDatabase(at: tempURL("canon"))

  let payload = GitCommitPayload(repoPath: repo.path, hash: hash, branch: "main")
  try spool.append(kind: CaptureKind.gitCommit, payload: try encodeJSON(payload))

  // Act
  let n = try Ingester(spool: spool, db: db).drain()

  // Assert
  #expect(n == 1)
  let events = try db.read { db in try Event.all.fetchAll(db) }
  #expect(events.count == 1)
  #expect(events.first?.summary == "first commit")
  #expect(events.first?.kind == CaptureKind.gitCommit)
  #expect(try spool.pending().isEmpty)   // marked ingested
}

@Test func failingRowStaysPendingWhileGoodRowProcesses() throws {
  // A real temp git repo with one commit (for the good row).
  let (repo, hash) = try makeCommittedRepo()
  let spool = try CaptureSpool(at: tempURL("spool"))
  let db = try openCanonicalDatabase(at: tempURL("canon"))

  // Bad row: git.commit kind but undecodable payload (missing required fields) → throws in ingest.
  try spool.append(kind: CaptureKind.gitCommit, payload: "{}")
  // Good row: a valid git.commit for the real repo.
  let payload = GitCommitPayload(repoPath: repo.path, hash: hash, branch: "main")
  try spool.append(kind: CaptureKind.gitCommit, payload: try encodeJSON(payload))

  let n = try Ingester(spool: spool, db: db).drain()

  #expect(n == 1)   // only the good row ingested
  let events = try db.read { db in try Event.all.fetchAll(db) }
  #expect(events.count == 1)
  #expect(events.first?.summary == "first commit")

  // The bad row is left unmarked so it retries next drain.
  let stillPending = try spool.pending()
  #expect(stillPending.count == 1)
  #expect(stillPending.first?.kind == CaptureKind.gitCommit)
  #expect(stillPending.first?.payload == "{}")
}

@Test func unknownKindIsDropped() throws {
  let spool = try CaptureSpool(at: tempURL("spool"))
  let db = try openCanonicalDatabase(at: tempURL("canon"))

  try spool.append(kind: "bogus.unknown", payload: "{}")

  let n = try Ingester(spool: spool, db: db).drain()

  #expect(n == 0)                        // dropped row creates no events
  #expect(try spool.pending().isEmpty)   // marked done via default: branch, not retried
  let events = try db.read { db in try Event.all.fetchAll(db) }
  #expect(events.isEmpty)                // nothing enriched
}

@Test func unattributableSessionStaysPending() throws {
  // Transcript path doesn't exist → TranscriptParser returns cwd == nil → ingest throws.
  let spool = try CaptureSpool(at: tempURL("spool"))
  let db = try openCanonicalDatabase(at: tempURL("canon"))

  let payload = SessionRefPayload(transcriptPath: "/tmp/does-not-exist-\(UUID().uuidString).jsonl")
  try spool.append(kind: CaptureKind.ccSession, payload: try encodeJSON(payload))

  let n = try Ingester(spool: spool, db: db).drain()

  #expect(n == 0)
  let pending = try spool.pending()
  #expect(pending.count == 1)
  #expect(pending.first?.kind == CaptureKind.ccSession)
}

@Test func unknownKindDoesNotCountAsEvent() throws {
  let (repo, hash) = try makeCommittedRepo()
  let spool = try CaptureSpool(at: tempURL("spool"))
  let db = try openCanonicalDatabase(at: tempURL("canon"))

  try spool.append(kind: "bogus.x", payload: "{}")
  let payload = GitCommitPayload(repoPath: repo.path, hash: hash, branch: "main")
  try spool.append(kind: CaptureKind.gitCommit, payload: try encodeJSON(payload))

  let n = try Ingester(spool: spool, db: db).drain()

  #expect(n == 1)                        // only the real commit counts
  #expect(try spool.pending().isEmpty)   // both rows marked (unknown dropped, commit ingested)
}

@Test func sessionFromSubdirectoryAttributesToRepoRoot() throws {
  let (repo, hash) = try makeCommittedRepo()
  let sub = repo.appendingPathComponent("sub", isDirectory: true)
  try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)

  let spool = try CaptureSpool(at: tempURL("spool"))
  let db = try openCanonicalDatabase(at: tempURL("canon"))

  let commitPayload = GitCommitPayload(repoPath: repo.path, hash: hash, branch: "main")
  try spool.append(kind: CaptureKind.gitCommit, payload: try encodeJSON(commitPayload))

  let transcript = tempURL("session", ext: "jsonl")
  let line = """
    {"type":"user","cwd":"\(sub.path)","timestamp":"2026-06-30T10:00:00Z","message":{"role":"user","content":"hi"}}
    """
  try line.write(to: transcript, atomically: true, encoding: .utf8)
  let sessionPayload = SessionRefPayload(transcriptPath: transcript.path)
  try spool.append(kind: CaptureKind.ccSession, payload: try encodeJSON(sessionPayload))

  _ = try Ingester(spool: spool, db: db).drain()

  let projects = try db.read { db in try Node.all.fetchAll(db) }
  #expect(projects.count == 1)

  let events = try db.read { db in try Event.all.fetchAll(db) }
  let commitEvent = events.first { $0.kind == CaptureKind.gitCommit }
  let sessionEvent = events.first { $0.kind == CaptureKind.ccSession }
  #expect(commitEvent != nil && sessionEvent != nil)
  #expect(commitEvent?.nodeID == sessionEvent?.nodeID)
}

@Test func strandBranchKeyIgnoresDefaultAndDetached() {
  #expect(Git.strandBranchKey(branch: "main", defaultBranch: "main") == nil)
  #expect(Git.strandBranchKey(branch: "HEAD", defaultBranch: "main") == nil)
  #expect(Git.strandBranchKey(branch: "", defaultBranch: "main") == nil)
  #expect(Git.strandBranchKey(branch: "feature-x", defaultBranch: "main") == "feature-x")
}

@Test func worktreesOfOneRepoShareCommonDir() throws {
  let (repo, _) = try makeCommittedRepo()
  guard let wt = try? addWorktree(to: repo, branch: "feature"),
        FileManager.default.fileExists(atPath: wt.path) else { return }  // worktree unsupported here
  #expect(Git.commonDir(in: repo.path) == Git.commonDir(in: wt.path))
  #expect(Git.commonDir(in: repo.path) != nil)
}

@Test func commitOnFeatureBranchTagsBranchKey() throws {
  let (repo, _) = try makeCommittedRepo()   // default branch resolves to "main"
  _ = Git.run(["checkout", "-b", "feature-x"], in: repo.path)
  try "more".write(to: repo.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)
  _ = Git.run(["add", "-A"], in: repo.path)
  _ = Git.run(["commit", "-m", "on feature"], in: repo.path)
  let hash = Git.run(["rev-parse", "HEAD"], in: repo.path)!

  let spool = try CaptureSpool(at: tempURL("spool"))
  let db = try openCanonicalDatabase(at: tempURL("canon"))
  try spool.append(kind: CaptureKind.gitCommit,
                   payload: try encodeJSON(GitCommitPayload(repoPath: repo.path, hash: hash, branch: "feature-x")))
  _ = try Ingester(spool: spool, db: db).drain()

  let ev = try db.read { db in try Event.all.fetchAll(db) }.first { $0.kind == CaptureKind.gitCommit }
  #expect(ev?.branchKey == "feature-x")
}

@Test func defaultBranchCommitHasNilBranchKey() throws {
  let (repo, hash) = try makeCommittedRepo()   // commit is on "main"
  let spool = try CaptureSpool(at: tempURL("spool"))
  let db = try openCanonicalDatabase(at: tempURL("canon"))
  try spool.append(kind: CaptureKind.gitCommit,
                   payload: try encodeJSON(GitCommitPayload(repoPath: repo.path, hash: hash, branch: "main")))
  _ = try Ingester(spool: spool, db: db).drain()
  let ev = try db.read { db in try Event.all.fetchAll(db) }.first
  #expect(ev?.branchKey == nil)
}
