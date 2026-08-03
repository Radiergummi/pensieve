import Foundation
import PensieveKit

/// A unique temp URL for a test database or directory.
/// Pass `ext: nil` for a directory (no extension).
func tempURL(_ prefix: String, ext: String? = "sqlite") -> URL {
  let name = ext.map { "\(prefix)-\(UUID().uuidString).\($0)" } ?? "\(prefix)-\(UUID().uuidString)"
  return URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(name)
}

/// Creates a fresh temp git repo with a single commit and returns its path and HEAD hash.
func makeCommittedRepo(message: String = "first commit") throws -> (repo: URL, hash: String) {
  let repo = tempURL("repo", ext: nil)
  try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
  // Pin the branch on both axes Git.defaultBranch consults, so these tests don't
  // inherit the machine's git configuration: --initial-branch fixes the branch that
  // actually gets created, and the repo-local init.defaultBranch overrides any
  // global setting, which defaultBranch checks first.
  _ = Git.run(["init", "--initial-branch=main"], in: repo.path)
  _ = Git.run(["config", "init.defaultBranch", "main"], in: repo.path)
  _ = Git.run(["config", "user.email", "t@t.co"], in: repo.path)
  _ = Git.run(["config", "user.name", "T"], in: repo.path)
  try "hello".write(to: repo.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
  _ = Git.run(["add", "-A"], in: repo.path)
  _ = Git.run(["commit", "-m", message], in: repo.path)
  let hash = Git.run(["rev-parse", "HEAD"], in: repo.path)!
  return (repo, hash)
}

/// Adds a linked worktree on a new branch to an existing repo; returns its path.
func addWorktree(to repo: URL, branch: String) throws -> URL {
  let worktree = tempURL("worktree", ext: nil)
  _ = Git.run(["worktree", "add", "-b", branch, worktree.path], in: repo.path)
  return worktree
}

/// A fresh empty temp directory (not a repo).
func makePlainDir(_ prefix: String = "plain") throws -> URL {
  let dir = tempURL(prefix, ext: nil)
  try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
  return dir
}

/// Creates a symlink at `link` pointing to `target`. Returns the link URL.
@discardableResult
func makeSymlink(at link: URL, to target: URL) throws -> URL {
  try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
  return link
}

/// Writes a non-pensieve post-commit hook into a repo (simulates a user-owned hook).
func writeForeignHook(in repo: URL) throws {
  let hooks = repo.appendingPathComponent(".git/hooks")
  try FileManager.default.createDirectory(at: hooks, withIntermediateDirectories: true)
  try "#!/bin/sh\necho foreign\n".write(to: hooks.appendingPathComponent("post-commit"),
                                        atomically: true, encoding: .utf8)
}
