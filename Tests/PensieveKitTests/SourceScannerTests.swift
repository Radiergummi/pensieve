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
  _ = Git.run(["config", "user.email", "t@t.co"], in: dir.path)
  _ = Git.run(["config", "user.name", "T"], in: dir.path)
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
  let db = try openCanonicalDatabase(at: tempURL("canon"))

  let flat = try scanner().discover(root: root, recursive: false, db: db)
  #expect(Set(flat.map { $0.source.directory.lastPathComponent }) == ["alpha", "beta"])
  let deep = try scanner().discover(root: root, recursive: true, db: db)
  #expect(Set(deep.map { $0.source.directory.lastPathComponent }) == ["alpha", "beta", "deep"])
}

@Test func rootItselfARepoYieldsOneCandidateNoChildInspection() throws {
  let (repoRoot, _) = try makeCommittedRepo()
  _ = try repo(in: repoRoot, "nested")                   // a repo inside the repo's working tree
  let db = try openCanonicalDatabase(at: tempURL("canon"))
  let found = try scanner().discover(root: repoRoot, recursive: true, db: db)
  #expect(found.count == 1)                              // prune-on-detect: interior not scanned
  #expect(found.first?.source.directory == repoRoot)
}

@Test func noiseDirsAreNotDescended() throws {
  let root = try makePlainDir("root")
  let nm = root.appendingPathComponent("node_modules")
  try FileManager.default.createDirectory(at: nm, withIntermediateDirectories: true)
  _ = try repo(in: nm, "buried")                         // repo inside node_modules
  let db = try openCanonicalDatabase(at: tempURL("canon"))
  let found = try scanner().discover(root: root, recursive: true, db: db)
  #expect(found.isEmpty)
}

@Test func worktreeDedupesToOneCandidate() throws {
  let root = try makePlainDir("root")
  let main = try repo(in: root, "main")
  guard let _ = try? addWorktree(to: main, branch: "wt") else { return }
  // NOTE: `git worktree add <path>` places the worktree OUTSIDE root by default (tempURL), so also
  // make one inside root to exercise the walk:
  let wtInside = root.appendingPathComponent("main-wt")
  _ = Git.run(["worktree", "add", "-b", "inside", wtInside.path], in: main.path)
  let db = try openCanonicalDatabase(at: tempURL("canon"))
  let found = try scanner().discover(root: root, recursive: true, db: db)
  #expect(found.filter { $0.source.kind == SourceKind.gitRepo }.count == 1)   // only the main tree
  #expect(found.first?.source.directory == main)
}

@Test func alreadyRegisteredReflectsExistingSource() throws {
  let root = try makePlainDir("root")
  let a = try repo(in: root, "alpha")
  _ = try repo(in: root, "beta")
  let db = try openCanonicalDatabase(at: tempURL("canon"))
  // Pre-register alpha exactly as accept/resolve would key it.
  _ = try ProjectResolver(db: db).resolve(path: ProjectResolver.canonical(Git.commonDir(in: a.path)!), kind: SourceKind.gitRepo)
  let found = try scanner().discover(root: root, recursive: false, db: db)
  let byName = Dictionary(uniqueKeysWithValues: found.map { ($0.source.directory.lastPathComponent, $0.alreadyRegistered) })
  #expect(byName["alpha"] == true)
  #expect(byName["beta"] == false)
}

@Test func symlinkCycleTerminates() throws {
  let root = try makePlainDir("root")
  _ = try repo(in: root, "alpha")
  try makeSymlink(at: root.appendingPathComponent("loop"), to: root)   // self-cycle
  let db = try openCanonicalDatabase(at: tempURL("canon"))
  let found = try scanner().discover(root: root, recursive: true, db: db)   // must not hang
  #expect(found.map { $0.source.directory.lastPathComponent } == ["alpha"])
}
