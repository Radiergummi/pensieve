import Foundation
import Testing
@testable import PensieveKit

@Test func gitSourceDetectsAMainWorkingTree() throws {
  let (repo, _) = try makeCommittedRepo()
  let detectedSource = GitSource(pensievePath: "/opt/pensieve").detect(directory: repo)
  #expect(detectedSource != nil)
  #expect(detectedSource?.kind == SourceKind.gitRepo)
  #expect(detectedSource?.directory == repo)
  // identityKey is the canonicalized common-dir and equals what resolve would store.
  #expect(detectedSource?.identityKey == ProjectResolver.canonical(Git.commonDir(in: repo.path)!))
  #expect(detectedSource?.displayName == ProjectResolver.displayName(forKey: detectedSource!.identityKey))
}

@Test func gitSourceIgnoresPlainDirectory() throws {
  let plain = try makePlainDir()
  #expect(GitSource(pensievePath: "/opt/pensieve").detect(directory: plain) == nil)
}

@Test func gitSourceIgnoresWorktreeWhoseGitIsAFile() throws {
  let (repo, _) = try makeCommittedRepo()
  // A hard requirement, not a silent skip. This was `guard … else { return }`, which turned "git
  // worktree add failed" into a PASSING test that asserted nothing — and linked worktrees are the
  // whole subject here, so there is no degraded version of this test worth running.
  let worktree = try #require(try? addWorktree(to: repo, branch: "feature"),
                              "git worktree add failed; this test cannot verify anything without it")
  #expect(FileManager.default.fileExists(atPath: worktree.path))
  // A linked worktree's .git is a FILE — detect must skip it (no candidate, no hook-crash).
  var isDir: ObjCBool = true
  _ = FileManager.default.fileExists(atPath: worktree.appendingPathComponent(".git").path, isDirectory: &isDir)
  #expect(isDir.boolValue == false)                     // precondition: it's a file
  #expect(GitSource(pensievePath: "/opt/pensieve").detect(directory: worktree) == nil)
}
