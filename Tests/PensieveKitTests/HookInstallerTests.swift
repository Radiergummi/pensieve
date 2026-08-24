import Foundation
import Testing
@testable import PensieveKit

/// A repo fixture for the hook installer, with `core.hooksPath` pinned OFF repo-locally.
///
/// The pin matters for the same reason `configureTestRepo` pins the default branch and signing:
/// `install` now refuses when `core.hooksPath` redirects hooks away from `.git/hooks`, and
/// `git config --get` walks up into the developer's `--global` and `--system` config. Without a
/// repo-local override these tests would pass here and fail on a machine that sets it globally.
/// An empty value reads as "unset", which is exactly what the installer's guard checks for.
private func makeHookRepo() throws -> URL {
  let repo = tempURL("hookrepo", ext: nil)
  try FileManager.default.createDirectory(
    at: repo.appendingPathComponent(".git/hooks"), withIntermediateDirectories: true)
  _ = Git.run(["init", "--initial-branch=main"], in: repo.path)
  _ = Git.run(["config", "core.hooksPath", ""], in: repo.path)
  return repo
}

@Test func installsExecutableHooks() throws {
  let repo = try makeHookRepo()

  let written = try HookInstaller.install(inRepo: repo)
  #expect(written.count == 2)

  let postCommit = repo.appendingPathComponent(".git/hooks/post-commit")
  let body = try String(contentsOf: postCommit, encoding: .utf8)
  #expect(body.contains("\"pensieve\" capture-commit"))
  let perms = try FileManager.default.attributesOfItem(atPath: postCommit.path)[.posixPermissions] as! NSNumber
  #expect(perms.intValue & 0o111 != 0)   // executable bit set
}

@Test func bakesAbsolutePensievePath() throws {
  let repo = try makeHookRepo()

  _ = try HookInstaller.install(inRepo: repo, pensievePath: "/opt/pensieve/bin/pensieve")

  let postCommit = repo.appendingPathComponent(".git/hooks/post-commit")
  let body = try String(contentsOf: postCommit, encoding: .utf8)
  #expect(body.contains("\"/opt/pensieve/bin/pensieve\" capture-commit"))
}

@Test func refusesToOverwriteForeignHook() throws {
  let repo = try makeHookRepo()
  let hooksDir = repo.appendingPathComponent(".git/hooks")

  let custom = "#!/bin/sh\necho custom"
  let postCommit = hooksDir.appendingPathComponent("post-commit")
  try custom.write(to: postCommit, atomically: true, encoding: .utf8)

  #expect(throws: HookInstallError.self) {
    _ = try HookInstaller.install(inRepo: repo)
  }
  // Foreign hook left untouched, not destroyed.
  let onDisk = try String(contentsOf: postCommit, encoding: .utf8)
  #expect(onDisk == custom)
}

/// `core.hooksPath` redirects git away from `.git/hooks` entirely. Nothing in Pensieve knew about it,
/// so on such a repo the installer wrote two perfectly good hooks that git would never run and then
/// reported the repo as set up — capture producing nothing, forever, behind a success message.
@Test func installRefusesWhenCoreHooksPathRedirectsHooksElsewhere() throws {
  let repo = try makeHookRepo()
  _ = Git.run(["config", "core.hooksPath", ".githooks"], in: repo.path)

  #expect(HookInstaller.configuredHooksPath(inRepo: repo) == ".githooks")
  #expect(throws: HookInstallError.self) {
    _ = try HookInstaller.install(inRepo: repo)
  }
  // And it wrote nothing: a hook git ignores is worse than no hook, because it reads as installed.
  #expect(!FileManager.default.fileExists(
    atPath: repo.appendingPathComponent(".git/hooks/post-commit").path))

  // The absence half: with the redirect removed the same repo installs normally, so the refusal
  // above is the guard and not some unrelated failure. Set back to empty rather than `--unset`,
  // which would let the developer's global config decide the outcome of this assertion.
  _ = Git.run(["config", "core.hooksPath", ""], in: repo.path)
  #expect(HookInstaller.configuredHooksPath(inRepo: repo) == nil)
  #expect(try HookInstaller.install(inRepo: repo).count == 2)
}
