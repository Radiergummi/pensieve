import Foundation
import Testing
@testable import PensieveKit

/// Writes a file into a directory (creating intermediate dirs).
private func write(_ text: String, to url: URL) throws {
  try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
  try text.write(to: url, atomically: true, encoding: .utf8)
}

@Test func gatherPopulatesAllSignalsFromWorkingTree() throws {
  let (repo, _) = try makeCommittedRepo()
  _ = Git.run(["remote", "add", "origin", "https://github.com/acme/laravel-rls.git"], in: repo.path)
  try write("# Laravel RLS\nRow-level security for Eloquent.", to: repo.appendingPathComponent("README.md"))
  try write("Project instructions here.", to: repo.appendingPathComponent("CLAUDE.md"))
  try write(#"{"name":"acme/laravel-rls","description":"RLS package"}"#, to: repo.appendingPathComponent("composer.json"))
  let commonDir = Git.commonDir(in: repo.path)!

  let ctx = ProjectContext.gather(commonDir: commonDir)

  #expect(ctx.gitRemote == "https://github.com/acme/laravel-rls.git")
  #expect(ctx.readmeHead?.contains("Row-level security") == true)
  #expect(ctx.claudeMdHead?.contains("Project instructions") == true)
  #expect(ctx.manifest?.contains("acme/laravel-rls") == true)
  #expect(ctx.manifest?.contains("RLS package") == true)
  #expect(!ctx.dirName.isEmpty)
}

@Test func gatherLeavesFileSignalsNilWhenAbsent() throws {
  let (repo, _) = try makeCommittedRepo()   // no README/CLAUDE.md/manifest/remote
  let ctx = ProjectContext.gather(commonDir: Git.commonDir(in: repo.path)!)
  #expect(ctx.readmeHead == nil)
  #expect(ctx.claudeMdHead == nil)
  #expect(ctx.manifest == nil)
  #expect(ctx.gitRemote == nil)
  #expect(!ctx.dirName.isEmpty)
}

@Test func gatherReadsMainWorktreeFromLinkedWorktreeCommonDir() throws {
  let (repo, _) = try makeCommittedRepo()
  try write("# Main Readme\nfrom the main worktree", to: repo.appendingPathComponent("README.md"))
  let wt = try addWorktree(to: repo, branch: "feature")
  // A linked worktree shares the main repo's common-dir; gather must read the MAIN worktree.
  let ctx = ProjectContext.gather(commonDir: Git.commonDir(in: wt.path)!)
  #expect(ctx.readmeHead?.contains("from the main worktree") == true)
}

@Test func gatherOnBareRepoHasNoWorktreeSignals() throws {
  let bare = tempURL("bare", ext: "git")
  _ = Git.run(["init", "--bare", bare.path], in: NSTemporaryDirectory())
  let ctx = ProjectContext.gather(commonDir: Git.commonDir(in: bare.path) ?? bare.path)
  #expect(ctx.readmeHead == nil)     // no worktree → no file reads, no wrong-repo README
  #expect(ctx.claudeMdHead == nil)
  #expect(ctx.manifest == nil)
  #expect(!ctx.dirName.isEmpty)
}

@Test func gatherIgnoresBinaryReadme() throws {
  let (repo, _) = try makeCommittedRepo()
  // A non-text README extension must not be slurped into the prompt.
  try Data([0xFF, 0xFE, 0x00, 0x01]).write(to: repo.appendingPathComponent("README.pdf"))
  let ctx = ProjectContext.gather(commonDir: Git.commonDir(in: repo.path)!)
  #expect(ctx.readmeHead == nil)     // only README / README.md / README.txt are read
}

@Test func gatherRecoversReadmeTruncatedMidMultibyteCharacter() throws {
  let (repo, _) = try makeCommittedRepo()
  let body = String(repeating: "a", count: 1023) + "—— tail"   // cut at 1024 bytes lands inside the em dash
  try write(body, to: repo.appendingPathComponent("README.md"))
  let ctx = ProjectContext.gather(commonDir: Git.commonDir(in: repo.path)!)
  #expect(ctx.readmeHead != nil)
  #expect(ctx.readmeHead?.hasPrefix("aaa") == true)
}

@Test func namePromptIncludesOnlyPresentSignals() {
  let ctx = ProjectContext(dirName: "laravel-rls", gitRemote: "https://x/laravel-rls.git",
                           readmeHead: nil, claudeMdHead: nil, manifest: "acme/laravel-rls — RLS package")
  let p = ProjectContext.namePrompt(ctx)
  #expect(p.contains("Directory name: laravel-rls"))
  #expect(p.contains("Git remote: https://x/laravel-rls.git"))
  #expect(p.contains("acme/laravel-rls — RLS package"))
  #expect(!p.contains("README excerpt"))     // nil signal omitted
}

// MARK: describePrompt

@Test func describePromptIncludesOnlyPresentSignals() {
  let ctx = ProjectContext(dirName: "laravel-rls", gitRemote: "https://x/laravel-rls.git",
                           readmeHead: nil, claudeMdHead: nil, manifest: "acme/laravel-rls — RLS package")
  let p = ProjectContext.describePrompt(ctx)
  #expect(p.contains("Directory name: laravel-rls"))
  #expect(p.contains("Git remote: https://x/laravel-rls.git"))
  #expect(p.contains("acme/laravel-rls — RLS package"))
  #expect(!p.contains("README excerpt"))                 // nil signal omitted
  #expect(p.contains("Summarize what this software project"))   // description instruction, not naming
}

// MARK: hasMeaningfulSignal (substance gate)

@Test func meaningfulSignalTrueForSubstantiveReadme() {
  let ctx = ProjectContext(dirName: "app", gitRemote: nil,
                           readmeHead: "# App\nRow-level security for Eloquent models.",
                           claudeMdHead: nil, manifest: nil)
  #expect(ProjectContext.hasMeaningfulSignal(ctx) == true)
}

@Test func meaningfulSignalFalseForTitleOnlyReadme() {
  let ctx = ProjectContext(dirName: "foo", gitRemote: "https://x/foo.git",
                           readmeHead: "# foo", claudeMdHead: nil, manifest: nil)
  #expect(ProjectContext.hasMeaningfulSignal(ctx) == false)   // `# foo` alone is not enough
}

@Test func meaningfulSignalFalseForBareNameManifestAndRemoteOnly() {
  let ctx = ProjectContext(dirName: "foo", gitRemote: "https://x/foo.git",
                           readmeHead: nil, claudeMdHead: nil, manifest: "MyPackage")  // name only, no " — desc"
  #expect(ProjectContext.hasMeaningfulSignal(ctx) == false)
}

@Test func meaningfulSignalTrueForManifestWithDescription() {
  let ctx = ProjectContext(dirName: "foo", gitRemote: nil,
                           readmeHead: nil, claudeMdHead: nil, manifest: "acme/foo — does a real thing")
  #expect(ProjectContext.hasMeaningfulSignal(ctx) == true)
}
