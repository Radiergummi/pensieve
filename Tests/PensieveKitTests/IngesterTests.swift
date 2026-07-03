import Foundation
import Testing
import SQLiteData
@testable import PensieveKit

@Test func ingestsGitCommitIntoEvent() throws {
  // Arrange: a real temp git repo with one commit.
  let repo = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("repo-\(UUID().uuidString)")
  try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
  _ = Git.run(["init"], in: repo.path)
  _ = Git.run(["config", "user.email", "t@t.co"], in: repo.path)
  _ = Git.run(["config", "user.name", "T"], in: repo.path)
  try "hello".write(to: repo.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
  _ = Git.run(["add", "-A"], in: repo.path)
  _ = Git.run(["commit", "-m", "first commit"], in: repo.path)
  let hash = Git.run(["rev-parse", "HEAD"], in: repo.path)!

  let spoolURL = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("spool-\(UUID().uuidString).sqlite")
  let spool = try CaptureSpool(at: spoolURL)
  let dbURL = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("canon-\(UUID().uuidString).sqlite")
  let db = try openCanonicalDatabase(at: dbURL)

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
