# Source Discovery — Watched-Folder Scan Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let `pensieve scan <folder> [--recursive] [--accept]` discover filesystem-backed sources under a folder (git repos today) and, on `--accept`, register + hook each — the broad dogfooding enabler.

**Architecture:** A source-oriented, kind-agnostic engine in `PensieveKit`: a `FileSystemSourceType` protocol with one conformer (`GitSource`), and a `SourceScanner` with two operations — `discover` (write-free: walk + detect + dedup + `alreadyRegistered`) and `accept` (best-effort per candidate: `ProjectResolver.resolve` + `onRegister`). The scanner holds zero git logic. A thin `scan` CLI command drives it.

**Tech Stack:** Swift 6, SwiftPM, SQLiteData (GRDB-backed), ArgumentParser, Swift Testing.

**Spec:** `docs/superpowers/specs/2026-07-04-pensieve-source-discovery-design.md`.

## Global Constraints

- **Build/test with `./scripts/test.sh` (optionally `--filter <name>`), NOT `swift test`** — Command Line Tools only. `swift build`/`swift run` work normally.
- **SQLiteData predicates use `.eq(x)`, NOT `== x`** (e.g. `.where { $0.kind.eq(k) && $0.key.eq(key) }`). `==` is unavailable.
- Reuse `SourceKind` constants (`CapturePayloads.swift`); reuse `ProjectResolver.resolve` / `.canonical` / `.displayName(forKey:)`, `HookInstaller.install`, `Git.commonDir` — do NOT reimplement.
- **Capture path stays sacred:** `discover` is write-free; `accept` only writes the canonical store + installs marker-guarded hooks (never clobbering foreign hooks). Nothing on the scan path blocks a commit.
- **`GitSource.detect` matches a git source ONLY when `directory/.git` is a real directory** — this skips linked worktrees and submodules (whose `.git` is a *file*) and is the fix for the duplicate-candidate + `accept`-crash bug.
- **`identityKey` = `ProjectResolver.canonical(Git.commonDir(...))`** — canonicalized so it equals the stored `Source.key` (keeps `alreadyRegistered` from drifting).
- **`accept` is best-effort per candidate:** an `onRegister` failure (e.g. foreign hooks) is recorded in `setupFailed` and the `Source` is kept; the batch never aborts on it. `accept` rethrows only on a catastrophic DB failure.
- No shared mutable `static ISO8601DateFormatter` (Swift 6).
- Disk runs tight; on a SwiftSyntax/macro linker error, `rm -rf .build` and retry.

## File Structure

**Created:**
- `Sources/PensieveKit/Discovery/FileSystemSourceType.swift` — `DiscoveredSource`, `DiscoveryCandidate`, the `FileSystemSourceType` protocol.
- `Sources/PensieveKit/Discovery/GitSource.swift` — the one concrete conformer.
- `Sources/PensieveKit/Discovery/SourceScanner.swift` — `discover` + `accept` + `AcceptResult`.
- `Sources/pensieve/Commands/Scan.swift` — the `scan` CLI command.
- `Tests/PensieveKitTests/GitSourceTests.swift`, `Tests/PensieveKitTests/SourceScannerTests.swift`.

**Modified:**
- `Sources/pensieve/Pensieve.swift` — register `Scan.self`.
- `Tests/PensieveKitTests/TestSupport.swift` — add small helpers (plain dir, foreign-hook repo, symlink).

---

## Task 1: Discovery vocabulary + `GitSource`

The source-oriented types and the git conformer. `detect` is pure filesystem/subprocess (no DB, no writes).

**Files:**
- Create: `Sources/PensieveKit/Discovery/FileSystemSourceType.swift`
- Create: `Sources/PensieveKit/Discovery/GitSource.swift`
- Create: `Tests/PensieveKitTests/GitSourceTests.swift`
- Modify: `Tests/PensieveKitTests/TestSupport.swift` (add `makePlainDir`)

**Interfaces:**
- Consumes: `SourceKind.gitRepo`; `Git.commonDir(in:)`; `ProjectResolver.canonical(_:)` / `.displayName(forKey:)`; `HookInstaller.install(inRepo:pensievePath:)`.
- Produces: `struct DiscoveredSource`, `struct DiscoveryCandidate`, `protocol FileSystemSourceType`, `struct GitSource: FileSystemSourceType` with `init(pensievePath:)`.

- [ ] **Step 1: Add a test helper**

In `Tests/PensieveKitTests/TestSupport.swift`, add:

```swift
/// A fresh empty temp directory (not a repo).
func makePlainDir(_ prefix: String = "plain") throws -> URL {
  let dir = tempURL(prefix, ext: nil)
  try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
  return dir
}
```

- [ ] **Step 2: Write the failing tests**

Create `Tests/PensieveKitTests/GitSourceTests.swift`:

```swift
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
```

- [ ] **Step 3: Run to verify failure**

Run: `./scripts/test.sh --filter gitSource`
Expected: FAIL — `cannot find 'GitSource' in scope`.

- [ ] **Step 4: Implement the vocabulary**

Create `Sources/PensieveKit/Discovery/FileSystemSourceType.swift`:

```swift
import Foundation
import SQLiteData

/// A filesystem-backed source discovered by inspecting a directory. Pure data — no DB state.
public struct DiscoveredSource: Equatable, Sendable {
  public let kind: String          // a SourceKind constant (e.g. gitRepo)
  public let directory: URL        // the source's main directory (git: the working tree holding .git/)
  public let identityKey: String   // canonicalized; becomes Source.key (git: canonicalized common-dir)
  public let displayName: String   // listing/UI only — accept ignores it (resolve names the node)
  public init(kind: String, directory: URL, identityKey: String, displayName: String) {
    self.kind = kind; self.directory = directory
    self.identityKey = identityKey; self.displayName = displayName
  }
}

/// A discovered source plus whether it is already registered in the canonical store.
public struct DiscoveryCandidate: Equatable, Sendable {
  public let source: DiscoveredSource
  public let alreadyRegistered: Bool
  public init(source: DiscoveredSource, alreadyRegistered: Bool) {
    self.source = source; self.alreadyRegistered = alreadyRegistered
  }
}

/// How to discover and set up one kind of filesystem-backed source. The scanner holds a registry
/// of these and stays kind-agnostic; all git specifics live in `GitSource`.
public protocol FileSystemSourceType: Sendable {
  var kind: String { get }
  /// Policy (not a law): whether the walk skips a detected source's interior. git: true.
  var prunesChildrenWhenDetected: Bool { get }
  /// Detect a source rooted at `directory`. Performs no persistence writes; may touch the
  /// filesystem / shell out to git. Returns nil when there is no source of this kind here.
  func detect(directory: URL) -> DiscoveredSource?
  /// Capture-setup side effects for an accepted source (git: install hooks). No DB access —
  /// `accept` owns the canonical write.
  func onRegister(_ discovered: DiscoveredSource) throws
}
```

Create `Sources/PensieveKit/Discovery/GitSource.swift`:

```swift
import Foundation

/// Git as one concrete filesystem-backed source: a directory whose `.git` is a real directory
/// (a main working tree). Linked worktrees and submodules (whose `.git` is a file) are skipped.
public struct GitSource: FileSystemSourceType {
  public let pensievePath: String
  public init(pensievePath: String) { self.pensievePath = pensievePath }

  public var kind: String { SourceKind.gitRepo }
  public var prunesChildrenWhenDetected: Bool { true }

  public func detect(directory: URL) -> DiscoveredSource? {
    var isDir: ObjCBool = false
    let dotGit = directory.appendingPathComponent(".git").path
    guard FileManager.default.fileExists(atPath: dotGit, isDirectory: &isDir), isDir.boolValue,
          let common = Git.commonDir(in: directory.path)
    else { return nil }
    let identityKey = ProjectResolver.canonical(common)
    return DiscoveredSource(kind: kind, directory: directory, identityKey: identityKey,
                            displayName: ProjectResolver.displayName(forKey: identityKey))
  }

  public func onRegister(_ discovered: DiscoveredSource) throws {
    _ = try HookInstaller.install(inRepo: discovered.directory, pensievePath: pensievePath)
  }
}
```

- [ ] **Step 5: Run to verify pass**

Run: `./scripts/test.sh --filter gitSource`
Expected: PASS (3 tests; the worktree test may early-return if worktrees are unsupported in the sandbox — acceptable).

- [ ] **Step 6: Commit**

```bash
git add Sources/PensieveKit/Discovery/FileSystemSourceType.swift Sources/PensieveKit/Discovery/GitSource.swift Tests/PensieveKitTests/GitSourceTests.swift Tests/PensieveKitTests/TestSupport.swift
git commit -m "feat: source-discovery vocabulary + GitSource (detect main working trees only)"
```

---

## Task 2: `SourceScanner.discover`

The write-free walk: detect at each directory, prune, honor depth/noise/symlink rules, dedup by `(kind, identityKey)`, and annotate `alreadyRegistered` from the DB (read-only).

**Files:**
- Create: `Sources/PensieveKit/Discovery/SourceScanner.swift`
- Modify: `Tests/PensieveKitTests/TestSupport.swift` (add `makeSymlink`)
- Create: `Tests/PensieveKitTests/SourceScannerTests.swift`

**Interfaces:**
- Consumes: `FileSystemSourceType`, `DiscoveredSource`, `DiscoveryCandidate` (Task 1); `Source` model; `Git`.
- Produces: `struct SourceScanner` with `init(types:)` and `func discover(root:recursive:db:) throws -> [DiscoveryCandidate]`.

- [ ] **Step 1: Add a symlink test helper**

In `TestSupport.swift`, add:

```swift
/// Creates a symlink at `link` pointing to `target`. Returns the link URL.
@discardableResult
func makeSymlink(at link: URL, to target: URL) throws -> URL {
  try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
  return link
}
```

- [ ] **Step 2: Write the failing tests**

Create `Tests/PensieveKitTests/SourceScannerTests.swift`:

```swift
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
```

- [ ] **Step 3: Run to verify failure**

Run: `./scripts/test.sh --filter Scanner`
Expected: FAIL — `cannot find 'SourceScanner' in scope`.

- [ ] **Step 4: Implement `SourceScanner.discover`**

Create `Sources/PensieveKit/Discovery/SourceScanner.swift`:

```swift
import Foundation
import SQLiteData

public struct SourceScanner {
  let types: [any FileSystemSourceType]
  public init(types: [any FileSystemSourceType]) { self.types = types }

  static let noiseDirs: Set<String> = ["node_modules", ".build", ".git", "vendor", "Pods", "DerivedData"]

  /// Write-free: walks `root`, detects sources, dedups by (kind, identityKey), and annotates
  /// whether each is already registered (read-only DB query). Never follows directory symlinks;
  /// skips unreadable directories rather than aborting.
  public func discover(root: URL, recursive: Bool, db: any DatabaseWriter) throws -> [DiscoveryCandidate] {
    var found: [DiscoveredSource] = []
    walk(root, depth: 0, recursive: recursive, into: &found)

    var seen = Set<String>()
    let unique = found.filter { seen.insert("\($0.kind)\u{0}\($0.identityKey)").inserted }

    return try db.read { db in
      try unique.map { s in
        let exists = try Source.where { $0.kind.eq(s.kind) && $0.key.eq(s.identityKey) }.fetchOne(db) != nil
        return DiscoveryCandidate(source: s, alreadyRegistered: exists)
      }
    }
  }

  private func walk(_ dir: URL, depth: Int, recursive: Bool, into found: inout [DiscoveredSource]) {
    var pruned = false
    for type in types {
      if let d = type.detect(directory: dir) {
        found.append(d)
        if type.prunesChildrenWhenDetected { pruned = true }
      }
    }
    if pruned { return }
    guard recursive || depth < 1 else { return }        // non-recursive = root + depth-1

    let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey]
    guard let children = try? FileManager.default.contentsOfDirectory(
      at: dir, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles])
    else { return }                                      // unreadable dir → skip, don't abort

    for child in children {
      let vals = try? child.resourceValues(forKeys: keys)
      guard vals?.isDirectory == true, vals?.isSymbolicLink != true else { continue }  // dirs only; never follow symlinks
      if Self.noiseDirs.contains(child.lastPathComponent) { continue }
      walk(child, depth: depth + 1, recursive: recursive, into: &found)
    }
  }
}
```

- [ ] **Step 5: Run to verify pass, then full suite**

Run: `./scripts/test.sh --filter Scanner` → PASS. Then `./scripts/test.sh` → all green.

- [ ] **Step 6: Commit**

```bash
git add Sources/PensieveKit/Discovery/SourceScanner.swift Tests/PensieveKitTests/SourceScannerTests.swift Tests/PensieveKitTests/TestSupport.swift
git commit -m "feat: SourceScanner.discover — write-free walk, prune, dedup, alreadyRegistered"
```

---

## Task 3: `SourceScanner.accept` + `AcceptResult`

Register + set up the selected candidates, best-effort per candidate.

**Files:**
- Modify: `Sources/PensieveKit/Discovery/SourceScanner.swift`
- Modify: `Tests/PensieveKitTests/TestSupport.swift` (add `writeForeignHook`)
- Modify: `Tests/PensieveKitTests/SourceScannerTests.swift` (accept tests)

**Interfaces:**
- Consumes: `ProjectResolver.resolve(path:kind:)`; `FileSystemSourceType.onRegister`; `Source`/`Node` models; `HookInstaller` (via `GitSource.onRegister`).
- Produces: `struct AcceptResult`; `func accept(_:db:) throws -> AcceptResult` on `SourceScanner`.

- [ ] **Step 1: Add a foreign-hook helper**

In `TestSupport.swift`, add:

```swift
/// Writes a non-pensieve post-commit hook into a repo (simulates a user-owned hook).
func writeForeignHook(in repo: URL) throws {
  let hooks = repo.appendingPathComponent(".git/hooks")
  try FileManager.default.createDirectory(at: hooks, withIntermediateDirectories: true)
  try "#!/bin/sh\necho foreign\n".write(to: hooks.appendingPathComponent("post-commit"),
                                        atomically: true, encoding: .utf8)
}
```

- [ ] **Step 2: Write the failing tests**

Add to `SourceScannerTests.swift`:

```swift
@Test func acceptRegistersAndHooksThenIsIdempotent() throws {
  let root = try makePlainDir("root")
  let a = try repo(in: root, "alpha")
  let db = try openCanonicalDatabase(at: tempURL("canon"))
  let cands = try scanner().discover(root: root, recursive: false, db: db).map(\.source)

  let r1 = try scanner().accept(cands, db: db)
  #expect(r1.registered.count == 1)
  #expect(r1.setupFailed.isEmpty)
  #expect(try db.read { db in try Source.all.fetchAll(db).count } == 1)
  // hook installed with our marker
  let hook = try String(contentsOf: a.appendingPathComponent(".git/hooks/post-commit"), encoding: .utf8)
  #expect(hook.contains("pensieve-managed-hook"))

  let r2 = try scanner().accept(cands, db: db)           // re-accept: clean no-op
  #expect(r2.alreadyRegistered.count == 1)
  #expect(r2.registered.isEmpty)
  #expect(try db.read { db in try Source.all.fetchAll(db).count } == 1)   // no duplicate
}

@Test func acceptForeignHookRepoRecordsFailureButKeepsSourceAndContinues() throws {
  let root = try makePlainDir("root")
  let bad = try repo(in: root, "bad"); try writeForeignHook(in: bad)
  _ = try repo(in: root, "good")
  let db = try openCanonicalDatabase(at: tempURL("canon"))
  let cands = try scanner().discover(root: root, recursive: false, db: db).map(\.source)

  let r = try scanner().accept(cands, db: db)
  #expect(r.registered.count == 2)                        // BOTH sources created (batch not aborted)
  #expect(r.setupFailed.count == 1)                       // bad repo's hook install refused
  #expect(r.setupFailed.first?.0.directory.lastPathComponent == "bad")
  #expect(try db.read { db in try Source.all.fetchAll(db).count } == 2)  // bad still tracked
}

@Test func acceptOnWorktreeTreeDoesNotThrowAndHooksOnlyMain() throws {
  let root = try makePlainDir("root")
  let main = try repo(in: root, "main")
  _ = Git.run(["worktree", "add", "-b", "inside", root.appendingPathComponent("main-wt").path], in: main.path)
  let db = try openCanonicalDatabase(at: tempURL("canon"))
  let cands = try scanner().discover(root: root, recursive: true, db: db).map(\.source)

  let r = try scanner().accept(cands, db: db)             // must NOT throw
  #expect(r.registered.count == 1)
  #expect(r.setupFailed.isEmpty)
  // worktree's .git is still a file (never hooked)
  var isDir: ObjCBool = true
  _ = FileManager.default.fileExists(atPath: root.appendingPathComponent("main-wt/.git").path, isDirectory: &isDir)
  #expect(isDir.boolValue == false)
}
```

- [ ] **Step 3: Run to verify failure**

Run: `./scripts/test.sh --filter accept`
Expected: FAIL — `value of type 'SourceScanner' has no member 'accept'`.

- [ ] **Step 4: Implement `accept`**

Add to `SourceScanner.swift` (inside `struct SourceScanner`), and add the `AcceptResult` type at file scope:

```swift
  /// Best-effort per candidate: find-or-create the Source(+Node), then run the type's capture
  /// setup. An onRegister failure (e.g. foreign hooks) is recorded and the Source is kept; the
  /// batch never aborts on it. Rethrows only on a catastrophic DB failure.
  public func accept(_ candidates: [DiscoveredSource], db: any DatabaseWriter) throws -> AcceptResult {
    var result = AcceptResult()
    let resolver = ProjectResolver(db: db)
    for c in candidates {
      let existedBefore = try db.read { db in
        try Source.where { $0.kind.eq(c.kind) && $0.key.eq(c.identityKey) }.fetchOne(db) != nil
      }
      _ = try resolver.resolve(path: c.identityKey, kind: c.kind)   // find-or-create (own write tx)
      if existedBefore { result.alreadyRegistered.append(c) } else { result.registered.append(c) }
      if let type = types.first(where: { $0.kind == c.kind }) {
        do { try type.onRegister(c) }
        catch { result.setupFailed.append((c, String(describing: error))) }
      }
    }
    return result
  }
```

```swift
public struct AcceptResult: Sendable {
  public var registered: [DiscoveredSource] = []
  public var alreadyRegistered: [DiscoveredSource] = []
  public var setupFailed: [(DiscoveredSource, String)] = []
  public init() {}
}
```

- [ ] **Step 5: Run to verify pass, then full suite**

Run: `./scripts/test.sh --filter accept` → PASS. Then `./scripts/test.sh` → all green.

- [ ] **Step 6: Commit**

```bash
git add Sources/PensieveKit/Discovery/SourceScanner.swift Tests/PensieveKitTests/SourceScannerTests.swift Tests/PensieveKitTests/TestSupport.swift
git commit -m "feat: SourceScanner.accept — best-effort register+setup (keeps Source on hook failure)"
```

---

## Task 4: `scan` CLI command

Thin driver: build the registry, discover, list or accept.

**Files:**
- Create: `Sources/pensieve/Commands/Scan.swift`
- Modify: `Sources/pensieve/Pensieve.swift` (register `Scan.self`)

**Interfaces:**
- Consumes: `SourceScanner`, `GitSource`, `openCanonical()` (in `Pensieve.swift`).
- Produces: the `scan` subcommand.

- [ ] **Step 1: Write the command**

Create `Sources/pensieve/Commands/Scan.swift`:

```swift
import ArgumentParser
import Foundation
import PensieveKit

struct Scan: ParsableCommand {
  static let configuration = CommandConfiguration(commandName: "scan",
    abstract: "Discover sources (git repos) under a folder; --accept registers + installs hooks.")

  @Argument(help: "Folder to scan.") var folder: String
  @Flag(name: .long, help: "Recurse into subdirectories (default: folder + immediate children).") var recursive = false
  @Flag(name: .long, help: "Register discovered sources and install their capture setup.") var accept = false

  func run() throws {
    let db = try openCanonical()
    let pensievePath = Bundle.main.executablePath ?? "pensieve"
    let scanner = SourceScanner(types: [GitSource(pensievePath: pensievePath)])
    let root = URL(fileURLWithPath: (folder as NSString).expandingTildeInPath).resolvingSymlinksInPath()

    let candidates = try scanner.discover(root: root, recursive: recursive, db: db)
    guard !candidates.isEmpty else { print("no sources found under \(root.path)"); return }

    if !accept {
      print("discovered \(candidates.count) source(s):")
      for c in candidates {
        print("  \(c.source.kind)  \(c.source.displayName)  \(c.source.directory.path)\(c.alreadyRegistered ? "  [registered]" : "")")
      }
      print("\nre-run with --accept to register + install hooks.")
      return
    }

    let fresh = candidates.filter { !$0.alreadyRegistered }.map(\.source)
    let result = try scanner.accept(fresh, db: db)
    let already = candidates.count - fresh.count
    print("registered \(result.registered.count), already \(already), setup-failed \(result.setupFailed.count)")
    for (s, why) in result.setupFailed { print("  ! \(s.displayName): \(why)") }
  }
}
```

- [ ] **Step 2: Register the subcommand**

In `Sources/pensieve/Pensieve.swift`, add `Scan.self,` to the `subcommands` array.

- [ ] **Step 3: Build**

Run: `swift build`
Expected: `Build complete!` (on a SwiftSyntax/macro linker error, `rm -rf .build` and retry).

- [ ] **Step 4: Smoke-check against a throwaway store**

```bash
SP=$(mktemp -d); TREE=$(mktemp -d)
git init "$TREE/repoA" >/dev/null 2>&1; git -C "$TREE/repoA" commit --allow-empty -m x >/dev/null 2>&1
export PENSIEVE_DB="$SP/pensieve.sqlite" PENSIEVE_CAPTURE_DB="$SP/capture.sqlite"
.build/debug/pensieve scan "$TREE"                 # dry run: lists repoA
.build/debug/pensieve scan "$TREE" --accept        # registers + hooks repoA
.build/debug/pensieve list                         # repoA appears as a node
test -f "$TREE/repoA/.git/hooks/post-commit" && echo "HOOK INSTALLED"
```
Expected: dry run lists `repoA`; `--accept` prints `registered 1, already 0, setup-failed 0`; `list` shows `repoA`; hook file present.

- [ ] **Step 5: Confirm the kit suite still passes**

Run: `./scripts/test.sh`
Expected: all green (adding the CLI command must not disturb the kit).

- [ ] **Step 6: Commit**

```bash
git add Sources/pensieve/Commands/Scan.swift Sources/pensieve/Pensieve.swift
git commit -m "feat: pensieve scan <folder> [--recursive] [--accept]"
```

---

## Task 5: Docs

**Files:**
- Modify: `CLAUDE.md` (Status), `docs/superpowers/backlog.md`

- [ ] **Step 1: Update status docs**

In `CLAUDE.md`, add a Status line noting **source discovery (`pensieve scan`) shipped**: source-oriented (`FileSystemSourceType`/`GitSource`), `SourceScanner.discover`/`accept`, discovers git repos under a folder and registers + hooks them; settings-window UI (pass 2) still deferred. In `docs/superpowers/backlog.md`, add a bullet under a suitable section: **proactively suggest new projects learned implicitly** (from session cwds / commits in unregistered repos) — future, once capture is flowing; and note **pass 2: source-discovery settings window** (folder picker, recursive toggle, checkbox candidate list) may persist watched folders.

- [ ] **Step 2: Full suite + commit**

Run: `./scripts/test.sh` → green.

```bash
git add CLAUDE.md docs/superpowers/backlog.md
git commit -m "docs: note source discovery (pensieve scan) shipped"
```

---

## Self-Review (completed against the spec)

**Spec coverage:**
- §The discovery abstraction (`FileSystemSourceType`, `DiscoveredSource`, `DiscoveryCandidate`, `GitSource` with `.git`-directory rule, canonical identityKey, no `db` on onRegister): Task 1. ✅
- §`SourceScanner.discover` (write-free walk, prune, noise, no-symlink-follow, skip-unreadable, non-recursive = root+depth-1, dedup by (kind,identityKey), alreadyRegistered via canonical key): Task 2. ✅
- §`SourceScanner.accept` (best-effort per candidate, resolve + onRegister, keep Source on failure, setupFailed, idempotent): Task 3. ✅
- §Worktrees & submodules (detect skips `.git`-file dirs; dedup; hooks only main tree; accept doesn't throw): Task 1 detect + Task 2 dedup test + Task 3 accept test. ✅
- §CLI (`scan`/`--recursive`/`--accept`, groups + setupFailed, Bundle.main.executablePath): Task 4. ✅
- §Testing (recursion, prune/nested-in-repo, noise, worktree discover+accept, alreadyRegistered, symlink cycle, accept happy/idempotent/partial-failure, GitSource.detect unit incl. worktree→nil): Tasks 1–3. ✅
- §Non-goals: no settings window, no backfill, no auto-rescan, no other kinds. ✅

**Placeholder scan:** none — every code step carries full code; every run step an exact command + expected output.

**Type consistency:** `DiscoveredSource`/`DiscoveryCandidate`/`AcceptResult` and `FileSystemSourceType`(`detect`/`onRegister`/`prunesChildrenWhenDetected`) are identical across Task 1's definitions, Task 2/3's use, and Task 4's CLI; `discover(root:recursive:db:)` and `accept(_:db:)` signatures match call sites; `GitSource(pensievePath:)`, `ProjectResolver.resolve(path:kind:)`, `Git.commonDir(in:)`, `HookInstaller.install(inRepo:pensievePath:)` match the verified existing signatures.

**Note on `permission-denied` test:** omitted as a dedicated test because it can't be reliably created on all machines (running as owner); the `try?`-and-skip in `walk` covers it, and `symlinkCycleTerminates` exercises the "don't abort / don't loop" walk-safety path. Flagged so a reviewer doesn't treat the omission as a gap.
