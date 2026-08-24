import Foundation
import Testing
import SQLiteData
import GRDB
@testable import PensieveKit

/// Attribution of git captures whose directory no longer exists at drain time — the phantom-project
/// defect. The identity key is a git *common dir*, which can only be learned by asking git inside the
/// directory, so resolving it at drain time asks about a directory this workflow deletes constantly.
///
/// `IngesterTests.worktreesOfOneRepoShareCommonDir` covers the case where the worktree still exists.
/// These cover it being gone, which is the case that actually happened: 9 phantom nodes holding ~42
/// events that belong to one repo, and 42 of 198 sources keyed on something that is not a `.git`
/// common dir.

/// The fix, end to end: capture resolves the identity key while the worktree exists, the worktree is
/// then deleted, and the drain still lands the commit in the REPO's node.
@Test func commitFromADeletedWorktreeStillLandsInTheRepoNode() async throws {
  let (repo, _) = try makeCommittedRepo()
  guard let worktree = try? addWorktree(to: repo, branch: "feature"),
        FileManager.default.fileExists(atPath: worktree.path) else { return }  // worktree unsupported here
  let repoCommonDir = try #require(Git.commonDir(in: repo.path))

  try "w".write(to: worktree.appendingPathComponent("w.txt"), atomically: true, encoding: .utf8)
  _ = Git.run(["add", "-A"], in: worktree.path)
  _ = Git.run(["commit", "-m", "in worktree"], in: worktree.path)
  let hash = try #require(Git.run(["rev-parse", "HEAD"], in: worktree.path))

  let spool = try CaptureSpool(at: tempURL("spool"))
  let database = try openCanonicalDatabase(at: tempURL("canon"))
  // Exactly what the post-commit hook now writes: the key resolved where the directory still is.
  try spool.append(kind: CaptureKind.gitCommit, payload: try encodeJSON(GitCommitPayload(
    repoPath: worktree.path, hash: hash, branch: "feature",
    commonDir: ProjectResolver.identityKey(forRepoPath: worktree.path))))

  // The worktree is deleted before the drain — the ordinary case in this repo's own workflow.
  try FileManager.default.removeItem(at: worktree)
  #expect(Git.commonDir(in: worktree.path) == nil, "the directory must really be unresolvable now")

  _ = try await Ingester(spool: spool, database: database).drain()

  let sources = try await database.read { database in try Source.all.fetchAll(database) }
  let nodes = try await database.read { database in try Node.all.fetchAll(database) }
  #expect(sources.map(\.key) == [repoCommonDir])   // NOT the dead worktree path
  #expect(nodes.count == 1)                        // exactly one project, no phantom beside it
}

/// A spool row written before `commonDir` existed, whose directory is now gone. There is no way to
/// attribute it, so it must stay pending and be reported — never invent a `Source`+`Node` keyed on
/// the dead path, which is precisely what produced the phantoms.
@Test func legacyGitRowWithAGoneDirectoryStaysPendingInsteadOfMintingAPhantom() async throws {
  let gone = tempURL("repo", ext: nil)   // deliberately never created
  let spool = try CaptureSpool(at: tempURL("spool"))
  let database = try openCanonicalDatabase(at: tempURL("canon"))
  // No `commonDir`: an old row. `GitCommitPayload`'s field is optional precisely so this decodes.
  try spool.append(kind: CaptureKind.gitCommit, payload: try encodeJSON(
    GitCommitPayload(repoPath: gone.path, hash: "deadbeef", branch: "main")))

  let created = try await Ingester(spool: spool, database: database).drain()

  #expect(created == 0)
  #expect(try await database.read { database in try Node.all.fetchAll(database) }.isEmpty)
  #expect(try await database.read { database in try Source.all.fetchAll(database) }.isEmpty)
  #expect(try spool.pending().count == 1, "transient: retried, never silently dropped")
}

/// A checkout's fingerprint is derived from the canonical identity key, not the raw path it was
/// captured with, so one repo reached through two spellings of its path dedups to one event. With the
/// raw path the fingerprint differed per spelling while the `Source` did not, so dedup missed.
@Test func checkoutDedupsAcrossTwoSpellingsOfOneRepoPath() async throws {
  // On macOS `/tmp` is a symlink to `/private/tmp`, so these are two spellings of ONE directory.
  let name = "pensieve-checkout-\(UUID().uuidString)"
  let viaTmp = URL(fileURLWithPath: "/tmp").appendingPathComponent(name)
  let viaPrivateTmp = URL(fileURLWithPath: "/private/tmp").appendingPathComponent(name)
  try FileManager.default.createDirectory(at: viaTmp, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: viaTmp) }
  _ = Git.run(["init", "--initial-branch=main"], in: viaTmp.path)
  configureTestRepo(at: viaTmp.path)
  try #require(ProjectResolver.canonical(viaTmp.path) == ProjectResolver.canonical(viaPrivateTmp.path))

  let spool = try CaptureSpool(at: tempURL("spool"))
  let database = try openCanonicalDatabase(at: tempURL("canon"))
  for spelling in [viaTmp, viaPrivateTmp] {
    try spool.append(kind: CaptureKind.gitCheckout, payload: try encodeJSON(GitCheckoutPayload(
      repoPath: spelling.path, from: "aaa", to: "bbb", branch: "main",
      commonDir: ProjectResolver.identityKey(forRepoPath: spelling.path))))
  }

  _ = try await Ingester(spool: spool, database: database).drain()

  let events = try await database.read { database in try Event.all.fetchAll(database) }
  #expect(events.count == 1, "one checkout of one repo, however its path was spelled")
}

/// A transcript that exists with bytes but cannot be decoded is a TRANSIENT failure. It used to be
/// retired on the first look — permanently, because the drain consumed the row — so one unreadable
/// byte lost a real session for good.
@Test func aNonUTF8TranscriptStaysPendingRatherThanBeingRetiredForever() async throws {
  let transcript = tempURL("session", ext: "jsonl")
  try Data([0xFF, 0xFE, 0xFF, 0xFE]).write(to: transcript)   // invalid UTF-8, non-zero size
  defer { try? FileManager.default.removeItem(at: transcript) }
  let spool = try CaptureSpool(at: tempURL("spool"))
  let database = try openCanonicalDatabase(at: tempURL("canon"))
  try spool.append(kind: CaptureKind.ccSession,
                   payload: try encodeJSON(SessionRefPayload(transcriptPath: transcript.path)))

  let created = try await Ingester(spool: spool, database: database).drain()

  #expect(created == 0)
  #expect(try spool.pending().count == 1, "unreadable is transient — it must retry")
  #expect(try await database.read { database in try Node.all.fetchAll(database) }.isEmpty)

  // The pairing half: a transcript that READS fine and simply carries no cwd is permanent, and is
  // consumed. Without this, the assertion above would also pass if nothing were ever consumed.
  let readable = tempURL("session", ext: "jsonl")
  try #"{"type":"user","message":{"role":"user","content":"hi"}}"#
    .write(to: readable, atomically: true, encoding: .utf8)
  defer { try? FileManager.default.removeItem(at: readable) }
  let spool2 = try CaptureSpool(at: tempURL("spool"))
  try spool2.append(kind: CaptureKind.ccSession,
                    payload: try encodeJSON(SessionRefPayload(transcriptPath: readable.path)))
  _ = try await Ingester(spool: spool2, database: database).drain()
  #expect(try spool2.pending().isEmpty, "readable-but-unattributable is permanent — consumed")
}

/// Counts `complete` calls so a per-pass cap is observable.
private actor NamingCallCounter: LLMProvider {
  private var calls = 0
  func complete(prompt: String) async throws -> String { calls += 1; return "Named Thing" }
  func callCount() -> Int { calls }
}

/// `nameStrand` runs inside `drain()`, so without a cap one pass makes one model call per strand
/// born — a flush-and-reingest, or a backlog after the sync agent was down, then stalls the whole
/// cycle on N sequential LLM round-trips. Its two sibling passes both carry a cap and both document
/// why; this one did not.
@Test func strandNamingIsCappedPerDrain() async throws {
  let (repo, _) = try makeCommittedRepo()
  let spool = try CaptureSpool(at: tempURL("spool"))
  let database = try openCanonicalDatabase(at: tempURL("canon"))
  let commonDir = ProjectResolver.identityKey(forRepoPath: repo.path)
  let branchCount = Ingester.strandNameCap + 5

  // Two same-branch commits birth a strand. The hashes need not be real commits: enrichment falls
  // back to the hash as the subject when `git show` cannot resolve it, which is all this needs.
  for branch in 0..<branchCount {
    for commit in 0..<2 {
      try spool.append(kind: CaptureKind.gitCommit, payload: try encodeJSON(GitCommitPayload(
        repoPath: repo.path, hash: "hash-\(branch)-\(commit)", branch: "feature-\(branch)",
        commonDir: commonDir)))
    }
  }

  let counter = NamingCallCounter()
  _ = try await Ingester(spool: spool, database: database, llm: counter).drain()

  #expect(await counter.callCount() == Ingester.strandNameCap)
  // The strands themselves are all still born and attributed — only the naming is bounded.
  let strands = try await database.read { database in
    try Node.where { $0.kind.eq(NodeKind.strand) }.fetchAll(database)
  }
  #expect(strands.count == branchCount)
}

/// One unrecognized `status` value must cost one row, not the whole query. The synthesized
/// `RawRepresentable` decoder throws, and because decoding happens per column while fetching, that
/// throw fails the ENTIRE fetch — blanking every loose-end surface over one unexpected cell.
@Test func anUnrecognizedLooseEndStatusDegradesPerRowInsteadOfFailingTheQuery() async throws {
  let database = try openCanonicalDatabase(at: tempURL("canon"))
  let node = Node(name: "P", kind: NodeKind.project)
  let source = Source(nodeID: node.id, kind: SourceKind.claudeCode, key: "/p/app")
  let event = Event(nodeID: node.id, sourceID: source.id, occurredAt: Date(),
                    kind: CaptureKind.ccSession, summary: "s", detailJSON: "{}")
  try await database.write { database in
    try Node.insert { node }.execute(database)
    try Source.insert { source }.execute(database)
    try Event.insert { event }.execute(database)
    try LooseEnd.insert {
      LooseEnd(nodeID: node.id, sourceEventID: event.id, text: "t", quote: "q", role: "user")
    }.execute(database)
    // A status no build of this app writes — a newer version, a hand-edited row, a partial restore.
    try database.execute(sql: "UPDATE looseEnds SET status = 'someFutureState'")
  }

  let all = try await database.read { database in try LooseEnd.all.fetchAll(database) }

  #expect(all.count == 1, "the query must still return its row")
  #expect(all.first?.status == .dropped, "degraded to closed, never promoted to open")
}
