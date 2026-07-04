import Foundation
import Testing
@testable import PensieveKit

@Test func gitSourceDetectsAMainWorkingTree() throws {
  let (repo, _) = try makeCommittedRepo()
  let d = GitSource(pensievePath: "/opt/pensieve").detect(directory: repo)
  #expect(d != nil)
  #expect(d?.kind == SourceKind.gitRepo)
  #expect(d?.directory == repo)
  // identityKey is the canonicalized common-dir and equals what resolve would store.
  #expect(d?.identityKey == ProjectResolver.canonical(Git.commonDir(in: repo.path)!))
  #expect(d?.displayName == ProjectResolver.displayName(forKey: d!.identityKey))
}

@Test func gitSourceIgnoresPlainDirectory() throws {
  let plain = try makePlainDir()
  #expect(GitSource(pensievePath: "/opt/pensieve").detect(directory: plain) == nil)
}

@Test func gitSourceIgnoresWorktreeWhoseGitIsAFile() throws {
  let (repo, _) = try makeCommittedRepo()
  guard let wt = try? addWorktree(to: repo, branch: "feature"),
        FileManager.default.fileExists(atPath: wt.path) else { return }  // worktree unsupported here
  // A linked worktree's .git is a FILE — detect must skip it (no candidate, no hook-crash).
  var isDir: ObjCBool = true
  _ = FileManager.default.fileExists(atPath: wt.appendingPathComponent(".git").path, isDirectory: &isDir)
  #expect(isDir.boolValue == false)                     // precondition: it's a file
  #expect(GitSource(pensievePath: "/opt/pensieve").detect(directory: wt) == nil)
}
