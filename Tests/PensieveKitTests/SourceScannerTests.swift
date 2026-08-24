import Foundation
import Testing
import SQLiteData
@testable import PensieveKit

private func scanner() -> SourceScanner { SourceScanner(types: [GitSource(pensievePath: "/opt/pensieve")]) }

/// Puts a fresh committed repo INSIDE `parent` under `name`; returns the repo URL.
private func repo(in parent: URL, _ name: String) throws -> URL {
  let dir = parent.appendingPathComponent(name)
  try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
  _ = Git.run(["init"], in: dir.path)
  configureTestRepo(at: dir.path)
  try "x".write(to: dir.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
  _ = Git.run(["add", "-A"], in: dir.path)
  _ = Git.run(["commit", "-m", "c"], in: dir.path)
  return dir
}

@Test func nonRecursiveFindsDepthOneReposOnly() throws {
  let root = try makePlainDir("root")
  _ = try repo(in: root, "alpha")
  _ = try repo(in: root, "beta")
  let plain = root.appendingPathComponent("plain"); try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)
  _ = try repo(in: plain, "deep")                        // depth-2 repo under a plain dir
  let database = try openCanonicalDatabase(at: tempURL("canon"))

  let flat = try scanner().discover(root: root, recursive: false, database: database)
  #expect(Set(flat.map { $0.source.directory.lastPathComponent }) == ["alpha", "beta"])
  let deep = try scanner().discover(root: root, recursive: true, database: database)
  #expect(Set(deep.map { $0.source.directory.lastPathComponent }) == ["alpha", "beta", "deep"])
}

@Test func rootItselfARepoYieldsOneCandidateNoChildInspection() throws {
  let (repoRoot, _) = try makeCommittedRepo()
  _ = try repo(in: repoRoot, "nested")                   // a repo inside the repo's working tree
  let database = try openCanonicalDatabase(at: tempURL("canon"))
  let found = try scanner().discover(root: repoRoot, recursive: true, database: database)
  #expect(found.count == 1)                              // prune-on-detect: interior not scanned
  #expect(found.first?.source.directory == repoRoot)
}

@Test func noiseDirsAreNotDescended() throws {
  let root = try makePlainDir("root")
  let nodeModulesPath = root.appendingPathComponent("node_modules")
  try FileManager.default.createDirectory(at: nodeModulesPath, withIntermediateDirectories: true)
  _ = try repo(in: nodeModulesPath, "buried")                         // repo inside node_modules
  let database = try openCanonicalDatabase(at: tempURL("canon"))
  let found = try scanner().discover(root: root, recursive: true, database: database)
  #expect(found.isEmpty)
}

@Test func worktreeDedupesToOneCandidate() throws {
  let root = try makePlainDir("root")
  let main = try repo(in: root, "main")
  // A hard requirement, not a silent skip: the dedup-to-one-candidate property is the subject, and
  // `guard … else { return }` made a failed `git worktree add` look like a passing test.
  _ = try #require(try? addWorktree(to: main, branch: "wt"),
                   "git worktree add failed; this test cannot verify anything without it")
  // NOTE: `git worktree add <path>` places the worktree OUTSIDE root by default (tempURL), so also
  // make one inside root to exercise the walk:
  let wtInside = root.appendingPathComponent("main-wt")
  _ = Git.run(["worktree", "add", "-b", "inside", wtInside.path], in: main.path)
  let database = try openCanonicalDatabase(at: tempURL("canon"))
  let found = try scanner().discover(root: root, recursive: true, database: database)
  #expect(found.filter { $0.source.kind == SourceKind.gitRepo }.count == 1)   // only the main tree
  #expect(found.first?.source.directory == main)
}

@Test func alreadyRegisteredReflectsExistingSource() throws {
  let root = try makePlainDir("root")
  let alphaRepo = try repo(in: root, "alpha")
  _ = try repo(in: root, "beta")
  let database = try openCanonicalDatabase(at: tempURL("canon"))
  // Pre-register alpha exactly as accept/resolve would key it.
  _ = try ProjectResolver(database: database).resolve(
    path: ProjectResolver.canonical(Git.commonDir(in: alphaRepo.path)!), kind: SourceKind.gitRepo)
  let found = try scanner().discover(root: root, recursive: false, database: database)
  let byName = Dictionary(uniqueKeysWithValues: found.map { ($0.source.directory.lastPathComponent, $0.alreadyRegistered) })
  #expect(byName["alpha"] == true)
  #expect(byName["beta"] == false)
}

@Test func symlinkCycleTerminates() throws {
  let root = try makePlainDir("root")
  _ = try repo(in: root, "alpha")
  try makeSymlink(at: root.appendingPathComponent("loop"), to: root)   // self-cycle
  let database = try openCanonicalDatabase(at: tempURL("canon"))
  let found = try scanner().discover(root: root, recursive: true, database: database)   // must not hang
  #expect(found.map { $0.source.directory.lastPathComponent } == ["alpha"])
}

@Test func acceptRegistersAndHooksThenIsIdempotent() throws {
  let root = try makePlainDir("root")
  let alphaRepo = try repo(in: root, "alpha")
  let database = try openCanonicalDatabase(at: tempURL("canon"))
  let cands = try scanner().discover(root: root, recursive: false, database: database).map(\.source)

  let firstAcceptResult = try scanner().accept(cands, database: database)
  #expect(firstAcceptResult.registered.count == 1)
  #expect(firstAcceptResult.setupFailed.isEmpty)
  #expect(try database.read { database in try Source.all.fetchAll(database).count } == 1)
  // hook installed with our marker
  let hook = try String(contentsOf: alphaRepo.appendingPathComponent(".git/hooks/post-commit"), encoding: .utf8)
  #expect(hook.contains("pensieve-managed-hook"))

  let secondAcceptResult = try scanner().accept(cands, database: database)           // re-accept: clean no-op
  #expect(secondAcceptResult.alreadyRegistered.count == 1)
  #expect(secondAcceptResult.registered.isEmpty)
  #expect(try database.read { database in try Source.all.fetchAll(database).count } == 1)   // no duplicate
}

@Test func acceptForeignHookRepoRecordsFailureButKeepsSourceAndContinues() throws {
  let root = try makePlainDir("root")
  let bad = try repo(in: root, "bad"); try writeForeignHook(in: bad)
  _ = try repo(in: root, "good")
  let database = try openCanonicalDatabase(at: tempURL("canon"))
  let cands = try scanner().discover(root: root, recursive: false, database: database).map(\.source)

  let acceptResult = try scanner().accept(cands, database: database)
  #expect(acceptResult.registered.count == 2)                        // BOTH sources created (batch not aborted)
  #expect(acceptResult.setupFailed.count == 1)                       // bad repo's hook install refused
  #expect(acceptResult.setupFailed.first?.0.directory.lastPathComponent == "bad")
  #expect(try database.read { database in try Source.all.fetchAll(database).count } == 2)  // bad still tracked
}

@Test func acceptOnWorktreeTreeDoesNotThrowAndHooksOnlyMain() throws {
  let root = try makePlainDir("root")
  let main = try repo(in: root, "main")
  _ = Git.run(["worktree", "add", "-b", "inside", root.appendingPathComponent("main-wt").path], in: main.path)
  let database = try openCanonicalDatabase(at: tempURL("canon"))
  let cands = try scanner().discover(root: root, recursive: true, database: database).map(\.source)

  let acceptResult = try scanner().accept(cands, database: database)             // must NOT throw
  #expect(acceptResult.registered.count == 1)
  #expect(acceptResult.setupFailed.isEmpty)
  // worktree's .git is still a file (never hooked)
  var isDir: ObjCBool = true
  _ = FileManager.default.fileExists(atPath: root.appendingPathComponent("main-wt/.git").path, isDirectory: &isDir)
  #expect(isDir.boolValue == false)
}
