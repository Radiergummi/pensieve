import Foundation
import PensieveKit

/// Removes the per-process temp root. A free function with no captures so it converts to the C
/// function pointer `atexit` requires.
private func removeTestTemporaryRoot() {
  guard let path = testTemporaryRootPath else { return }
  try? FileManager.default.removeItem(atPath: path)
}

/// Set once, from `testTemporaryRoot`'s initializer, and read only by `atexit`.
private nonisolated(unsafe) var testTemporaryRootPath: String?

/// One directory per test process, removed when the process exits.
///
/// `tempURL` used to place its file directly in `NSTemporaryDirectory()` and nothing ever removed it,
/// so a suite run left roughly one artifact per test behind — and with 403 call sites, most creating a
/// SQLite database plus its `-wal`/`-shm`, that accumulates fast. Tens of thousands had piled up by
/// the 2026-08-24 sweep and were a material part of a disk exhaustion that broke the build mid-run.
///
/// Rooting them makes cleanup a single `removeItem`, and `atexit` runs it whether the suite passed,
/// failed, or threw. It deliberately does NOT run per test: several tests hand a path to a subprocess
/// or assert on a sibling file, so lifetime is the process, not the test.
///
/// 35 sites still build paths straight from `FileManager.default.temporaryDirectory` and are NOT
/// covered by this — see the quality backlog.
private let testTemporaryRoot: URL = {
  let root = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("pensieve-tests-\(ProcessInfo.processInfo.processIdentifier)",
                            isDirectory: true)
  try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  testTemporaryRootPath = root.path
  atexit(removeTestTemporaryRoot)
  return root
}()

/// A unique temp URL for a test database or directory, under the per-process root above.
/// Pass `ext: nil` for a directory (no extension).
func tempURL(_ prefix: String, ext: String? = "sqlite") -> URL {
  let name = ext.map { "\(prefix)-\(UUID().uuidString).\($0)" } ?? "\(prefix)-\(UUID().uuidString)"
  return testTemporaryRoot.appendingPathComponent(name)
}

/// A fresh, empty FTS5 search index in a unique temp file.
func tempSearchStore() -> SearchIndexStore {
  SearchIndexStore(url: tempURL("search-index"))
}

/// The repo-local git config every test repo needs, in one place so the two creation sites cannot
/// drift apart.
///
/// These tests must not inherit the developer's git configuration. The branch is pinned on both axes
/// `Git.defaultBranch` consults: `--initial-branch` (at the call site) fixes the branch that actually
/// gets created, and the repo-local `init.defaultBranch` overrides any global setting, which
/// `defaultBranch` checks first.
///
/// Signing is pinned OFF for a harder-won reason. This machine sets `commit.gpgsign=true` globally
/// with an SSH signer behind a Secure-Enclave agent, which refuses to sign in a non-interactive run
/// ("Couldn't sign message (signer): agent refused operation?"). `git commit` then fails with
/// "fatal: failed to write commit object", `rev-parse HEAD` returns nil, and the force-unwrap at the
/// call site raises a fatal error that kills the ENTIRE test process — so the suite dies mid-run
/// having reported only unrelated passing tests. Nothing here signs anything, so turn it off.
func configureTestRepo(at path: String) {
  _ = Git.run(["config", "init.defaultBranch", "main"], in: path)
  _ = Git.run(["config", "user.email", "t@t.co"], in: path)
  _ = Git.run(["config", "user.name", "T"], in: path)
  _ = Git.run(["config", "commit.gpgsign", "false"], in: path)
}

/// Creates a fresh temp git repo with a single commit and returns its path and HEAD hash.
func makeCommittedRepo(message: String = "first commit") throws -> (repo: URL, hash: String) {
  let repo = tempURL("repo", ext: nil)
  try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
  _ = Git.run(["init", "--initial-branch=main"], in: repo.path)
  configureTestRepo(at: repo.path)
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
