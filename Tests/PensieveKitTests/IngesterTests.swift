import Foundation
import Testing
import SQLiteData
@testable import PensieveKit

@Test func ingestsGitCommitIntoEvent() async throws {
  // Arrange: a real temp git repo with one commit.
  let (repo, hash) = try makeCommittedRepo()
  let spool = try CaptureSpool(at: tempURL("spool"))
  let database = try openCanonicalDatabase(at: tempURL("canon"))

  let payload = GitCommitPayload(repoPath: repo.path, hash: hash, branch: "main")
  try spool.append(kind: CaptureKind.gitCommit, payload: try encodeJSON(payload))

  // Act
  let n = try await Ingester(spool: spool, database: database).drain()

  // Assert
  #expect(n == 1)
  let events = try await database.read { database in try Event.all.fetchAll(database) }
  #expect(events.count == 1)
  #expect(events.first?.summary == "first commit")
  #expect(events.first?.kind == CaptureKind.gitCommit)
  #expect(try spool.pending().isEmpty)   // marked ingested
}

@Test func failingRowStaysPendingWhileGoodRowProcesses() async throws {
  // A real temp git repo with one commit (for the good row).
  let (repo, hash) = try makeCommittedRepo()
  let spool = try CaptureSpool(at: tempURL("spool"))
  let database = try openCanonicalDatabase(at: tempURL("canon"))

  // Bad row: git.commit kind but undecodable payload (missing required fields) → throws in ingest.
  try spool.append(kind: CaptureKind.gitCommit, payload: "{}")
  // Good row: a valid git.commit for the real repo.
  let payload = GitCommitPayload(repoPath: repo.path, hash: hash, branch: "main")
  try spool.append(kind: CaptureKind.gitCommit, payload: try encodeJSON(payload))

  let n = try await Ingester(spool: spool, database: database).drain()

  #expect(n == 1)   // only the good row ingested
  let events = try await database.read { database in try Event.all.fetchAll(database) }
  #expect(events.count == 1)
  #expect(events.first?.summary == "first commit")

  // The bad row is left unmarked so it retries next drain.
  let stillPending = try spool.pending()
  #expect(stillPending.count == 1)
  #expect(stillPending.first?.kind == CaptureKind.gitCommit)
  #expect(stillPending.first?.payload == "{}")
}

@Test func unknownKindIsDropped() async throws {
  let spool = try CaptureSpool(at: tempURL("spool"))
  let database = try openCanonicalDatabase(at: tempURL("canon"))

  try spool.append(kind: "bogus.unknown", payload: "{}")

  let n = try await Ingester(spool: spool, database: database).drain()

  #expect(n == 0)                        // dropped row creates no events
  #expect(try spool.pending().isEmpty)   // marked done via default: branch, not retried
  let events = try await database.read { database in try Event.all.fetchAll(database) }
  #expect(events.isEmpty)                // nothing enriched
}

@Test func unattributableSessionStaysPending() async throws {
  // Transcript path doesn't exist → TranscriptParser returns cwd == nil → ingest throws.
  let spool = try CaptureSpool(at: tempURL("spool"))
  let database = try openCanonicalDatabase(at: tempURL("canon"))

  let payload = SessionRefPayload(transcriptPath: "/tmp/does-not-exist-\(UUID().uuidString).jsonl")
  try spool.append(kind: CaptureKind.ccSession, payload: try encodeJSON(payload))

  let n = try await Ingester(spool: spool, database: database).drain()

  #expect(n == 0)
  let pending = try spool.pending()
  #expect(pending.count == 1)
  #expect(pending.first?.kind == CaptureKind.ccSession)
}

@Test func unknownKindDoesNotCountAsEvent() async throws {
  let (repo, hash) = try makeCommittedRepo()
  let spool = try CaptureSpool(at: tempURL("spool"))
  let database = try openCanonicalDatabase(at: tempURL("canon"))

  try spool.append(kind: "bogus.x", payload: "{}")
  let payload = GitCommitPayload(repoPath: repo.path, hash: hash, branch: "main")
  try spool.append(kind: CaptureKind.gitCommit, payload: try encodeJSON(payload))

  let n = try await Ingester(spool: spool, database: database).drain()

  #expect(n == 1)                        // only the real commit counts
  #expect(try spool.pending().isEmpty)   // both rows marked (unknown dropped, commit ingested)
}

@Test func sessionFromSubdirectoryAttributesToRepoRoot() async throws {
  let (repo, hash) = try makeCommittedRepo()
  let sub = repo.appendingPathComponent("sub", isDirectory: true)
  try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)

  let spool = try CaptureSpool(at: tempURL("spool"))
  let database = try openCanonicalDatabase(at: tempURL("canon"))

  let commitPayload = GitCommitPayload(repoPath: repo.path, hash: hash, branch: "main")
  try spool.append(kind: CaptureKind.gitCommit, payload: try encodeJSON(commitPayload))

  let transcript = tempURL("session", ext: "jsonl")
  let line = """
    {"type":"user","cwd":"\(sub.path)","timestamp":"2026-06-30T10:00:00Z","message":{"role":"user","content":"hi"}}
    """
  try line.write(to: transcript, atomically: true, encoding: .utf8)
  let sessionPayload = SessionRefPayload(transcriptPath: transcript.path)
  try spool.append(kind: CaptureKind.ccSession, payload: try encodeJSON(sessionPayload))

  _ = try await Ingester(spool: spool, database: database).drain()

  let projects = try await database.read { database in try Node.all.fetchAll(database) }
  #expect(projects.count == 1)

  let events = try await database.read { database in try Event.all.fetchAll(database) }
  let commitEvent = events.first { $0.kind == CaptureKind.gitCommit }
  let sessionEvent = events.first { $0.kind == CaptureKind.ccSession }
  #expect(commitEvent != nil && sessionEvent != nil)
  #expect(commitEvent?.nodeID == sessionEvent?.nodeID)
}

/// A session whose cwd is the filesystem root (or $HOME) is not an area of work — it's a session
/// launched from nowhere in particular, e.g. Pensieve's own `claude -p` subprocess under the
/// launchd daemon, which inherits cwd `/`. Attributing it created a catch-all phantom project
/// named "/" that swallowed hundreds of events. Drop it: no node, no event, spool row consumed.
@Test func sessionFromDegenerateRootIsNotAttributed() async throws {
  for root in ["/", NSHomeDirectory()] {
    let spool = try CaptureSpool(at: tempURL("spool"))
    let database = try openCanonicalDatabase(at: tempURL("canon"))

    let transcript = tempURL("session", ext: "jsonl")
    let line = """
      {"type":"user","cwd":"\(root)","timestamp":"2026-06-30T10:00:00Z","message":{"role":"user","content":"hi"}}
      """
    try line.write(to: transcript, atomically: true, encoding: .utf8)
    try spool.append(kind: CaptureKind.ccSession, payload: try encodeJSON(SessionRefPayload(transcriptPath: transcript.path)))

    _ = try await Ingester(spool: spool, database: database).drain()

    #expect(try await database.read { database in try Node.all.fetchAll(database) }.isEmpty, "cwd \(root) must not create a node")
    #expect(try await database.read { database in try Event.all.fetchAll(database) }.isEmpty, "cwd \(root) must not create an event")
    #expect(try spool.pending().isEmpty, "row must be consumed, not retried forever")
  }
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

@Test func commitOnFeatureBranchTagsBranchKey() async throws {
  let (repo, _) = try makeCommittedRepo()   // default branch resolves to "main"
  _ = Git.run(["checkout", "-b", "feature-x"], in: repo.path)
  try "more".write(to: repo.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)
  _ = Git.run(["add", "-A"], in: repo.path)
  _ = Git.run(["commit", "-m", "on feature"], in: repo.path)
  let hash = Git.run(["rev-parse", "HEAD"], in: repo.path)!

  let spool = try CaptureSpool(at: tempURL("spool"))
  let database = try openCanonicalDatabase(at: tempURL("canon"))
  try spool.append(kind: CaptureKind.gitCommit,
                   payload: try encodeJSON(GitCommitPayload(repoPath: repo.path, hash: hash, branch: "feature-x")))
  _ = try await Ingester(spool: spool, database: database).drain()

  let event = try await database.read { database in try Event.all.fetchAll(database) }.first { $0.kind == CaptureKind.gitCommit }
  #expect(event?.branchKey == "feature-x")
}

@Test func defaultBranchCommitHasNilBranchKey() async throws {
  let (repo, hash) = try makeCommittedRepo()   // commit is on "main"
  let spool = try CaptureSpool(at: tempURL("spool"))
  let database = try openCanonicalDatabase(at: tempURL("canon"))
  try spool.append(kind: CaptureKind.gitCommit,
                   payload: try encodeJSON(GitCommitPayload(repoPath: repo.path, hash: hash, branch: "main")))
  _ = try await Ingester(spool: spool, database: database).drain()
  let event = try await database.read { database in try Event.all.fetchAll(database) }.first
  #expect(event?.branchKey == nil)
}

@Test func newActivityResurfacesArchivedNodeAndAncestors() async throws {
  let (repo, _) = try makeCommittedRepo()
  let spool = try CaptureSpool(at: tempURL("spool"))
  let database = try openCanonicalDatabase(at: tempURL("canon"))

  // First commit → drain → creates the project node P (active, root).
  let hash1 = Git.run(["rev-parse", "HEAD"], in: repo.path)!
  try spool.append(kind: CaptureKind.gitCommit,
                   payload: try encodeJSON(GitCommitPayload(repoPath: repo.path, hash: hash1, branch: "main")))
  _ = try await Ingester(spool: spool, database: database).drain()
  let proj = try #require(try await database.read { database in try Node.all.fetchAll(database).first })

  // Give P a parent domain D and an extra child strand S.
  let domain = try #require(try NodeCommands.add(database, name: "Work", kind: .domain, parent: nil, description: ""))
  _ = try NodeCommands.reparent(database, nodeID: proj.id, newParentID: domain.id)
  let strand = try #require(try NodeCommands.add(database, name: "sibling", kind: .strand, parent: proj.name, description: ""))

  // Archive the whole subtree (D + P + S archived), then make D muted (sticky).
  #expect(try NodeCommands.archive(database, nodeID: domain.id))
  try await database.write { database in try Node.where { $0.id.eq(domain.id) }.update { $0.state = NodeState.muted }.execute(database) }

  // Second commit → drain → attributes to P.
  try "more".write(to: repo.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)
  _ = Git.run(["add", "-A"], in: repo.path)
  _ = Git.run(["commit", "-m", "second commit"], in: repo.path)
  let hash2 = Git.run(["rev-parse", "HEAD"], in: repo.path)!
  try spool.append(kind: CaptureKind.gitCommit,
                   payload: try encodeJSON(GitCommitPayload(repoPath: repo.path, hash: hash2, branch: "main")))
  _ = try await Ingester(spool: spool, database: database).drain()

  func state(_ id: UUID) async throws -> String? {
    try await database.read { database in try Node.where { $0.id.eq(id) }.fetchOne(database)?.state.rawValue }
  }
  #expect(try await state(proj.id) == "active")     // resurfaced
  #expect(try await state(domain.id) == "muted")    // ancestor stays sticky
  #expect(try await state(strand.id) == "archived") // sibling descendant untouched
}
