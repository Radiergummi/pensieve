# Project Display-Name Inference Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give git-sourced project nodes a human-readable display name (e.g. `laravel-rls` → "Laravel RLS Package") inferred on-device from local repo signals, best-effort and once per node.

**Architecture:** `ProjectResolver.resolve()` still sets the verbatim directory name synchronously (the fallback). A new best-effort batch pass `Ingester.refineProjectNames()` runs after `SyncRunner`'s second drain: it selects untouched, single-`gitRepo` project nodes, gathers cheap local signals via a new `ProjectContext` helper, asks the on-device `LLMProvider` for a name, and writes it — stamping a `nameInferred` marker in `Node.metadataJSON` so each node is attempted exactly once. Mirrors the existing `nameStrand()` shape; outside the trust gate (organizational label).

**Tech Stack:** Swift 6, SQLiteData (GRDB-backed), Swift Testing, on-device `LLMProvider` (Foundation Models / `claude -p`).

## Global Constraints

- SQLiteData predicates use `.eq(x)`, **never** `== x`.
- Table/column names match `@Table` property names exactly; tables are STRICT; PKs are UUID.
- Kind strings come from `SourceKind` / `CaptureKind` constants — don't hardcode `"gitRepo"` where a constant exists (`SourceKind.gitRepo`).
- No shared mutable `static` `ISO8601DateFormatter`.
- Swift only. No new dependencies. No schema migration (marker rides in the existing `Node.metadataJSON` string).
- Naming is **outside the trust gate** — best-effort, non-fatal, never throws out of the pass.
- Tests: run with `./scripts/test.sh --filter <name>`. The suite is at 150 tests today; every new test adds to it.
- Scope: only `kind == "project"` nodes with **exactly one** `gitRepo` source, whose current `name` still equals the verbatim default, and not already marked. Skip everything else.

---

### Task 1: `ProjectContext` — local signal gathering

**Files:**
- Create: `Sources/PensieveKit/Ingest/ProjectContext.swift`
- Test: `Tests/PensieveKitTests/ProjectContextTests.swift`

**Interfaces:**
- Consumes: `ProjectResolver.displayName(forKey:) -> String` (existing, static), `Git.run(_:in:) -> String?` (existing).
- Produces:
  - `public struct ProjectContext: Sendable` with `dirName: String`, `gitRemote: String?`, `readmeHead: String?`, `claudeMdHead: String?`, `manifest: String?`.
  - `public static func gather(commonDir: String) -> ProjectContext`
  - `static func namePrompt(_ ctx: ProjectContext) -> String` (internal; used by Task 2).

Key derivation fact (verified empirically): `git -C <commonDir> rev-parse --show-toplevel` **fails** when `commonDir` is the `.git` directory ("must be run in a work tree"). The working tree is the **parent of the common-dir when it ends in `.git`**, then validated by running `rev-parse --show-toplevel` *from that parent*. A common-dir that does not end in `.git` (bare repo `foo.git`, submodule `.git/modules/<name>`) has no reachable worktree → gather name + remote only.

- [ ] **Step 1: Write the failing tests**

Create `Tests/PensieveKitTests/ProjectContextTests.swift`:

```swift
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

@Test func namePromptIncludesOnlyPresentSignals() {
  let ctx = ProjectContext(dirName: "laravel-rls", gitRemote: "https://x/laravel-rls.git",
                           readmeHead: nil, claudeMdHead: nil, manifest: "acme/laravel-rls — RLS package")
  let p = ProjectContext.namePrompt(ctx)
  #expect(p.contains("Directory name: laravel-rls"))
  #expect(p.contains("Git remote: https://x/laravel-rls.git"))
  #expect(p.contains("acme/laravel-rls — RLS package"))
  #expect(!p.contains("README excerpt"))     // nil signal omitted
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `./scripts/test.sh --filter ProjectContext`
Expected: FAIL — `ProjectContext` is not defined / no such type.

- [ ] **Step 3: Create `ProjectContext.swift`**

```swift
import Foundation

/// Cheap, best-effort local signals used to infer a human-readable project display name.
/// Every field is optional except `dirName`; a missing/unreadable/binary file is simply absent.
/// All reads are size-capped so the prompt stays small. Never throws.
public struct ProjectContext: Sendable {
  public var dirName: String
  public var gitRemote: String?
  public var readmeHead: String?
  public var claudeMdHead: String?
  public var manifest: String?

  public init(dirName: String, gitRemote: String?, readmeHead: String?,
              claudeMdHead: String?, manifest: String?) {
    self.dirName = dirName; self.gitRemote = gitRemote; self.readmeHead = readmeHead
    self.claudeMdHead = claudeMdHead; self.manifest = manifest
  }

  /// Gathers signals for the repo whose git common-dir is `commonDir` (the Source key).
  public static func gather(commonDir: String) -> ProjectContext {
    let dirName = ProjectResolver.displayName(forKey: commonDir)
    let worktree = workingTree(forCommonDir: commonDir)
    let remoteRepo = worktree?.path ?? commonDir
    let remote = Git.run(["remote", "get-url", "origin"], in: remoteRepo).flatMap { $0.isEmpty ? nil : $0 }
    guard let worktree else {
      return ProjectContext(dirName: dirName, gitRemote: remote,
                            readmeHead: nil, claudeMdHead: nil, manifest: nil)
    }
    return ProjectContext(dirName: dirName, gitRemote: remote,
                          readmeHead: readmeHead(in: worktree),
                          claudeMdHead: head(of: worktree.appendingPathComponent("CLAUDE.md")),
                          manifest: manifest(in: worktree))
  }

  /// The main working tree, or nil for bare/submodule/no-checkout layouts. The common-dir is the
  /// `.git` directory; its parent is the worktree, validated via `rev-parse --show-toplevel` run
  /// FROM the parent (running it from the common-dir itself fails — that's not a work tree). A
  /// common-dir not ending in `.git` (bare `foo.git`, submodule `.git/modules/<name>`) has none.
  private static func workingTree(forCommonDir commonDir: String) -> URL? {
    let url = URL(fileURLWithPath: commonDir)
    guard url.lastPathComponent == ".git" else { return nil }
    let parent = url.deletingLastPathComponent()
    guard let top = Git.run(["rev-parse", "--show-toplevel"], in: parent.path), !top.isEmpty else { return nil }
    return parent
  }

  /// First text README (`README`, `README.md`, `README.txt`, case-insensitive). Binary/other
  /// extensions (`README.pdf`, …) are skipped by construction.
  private static func readmeHead(in worktree: URL) -> String? {
    guard let entries = try? FileManager.default.contentsOfDirectory(atPath: worktree.path) else { return nil }
    let names: Set<String> = ["readme", "readme.md", "readme.txt"]
    guard let match = entries.first(where: { names.contains($0.lowercased()) }) else { return nil }
    return head(of: worktree.appendingPathComponent(match))
  }

  /// First matching package manifest → a short `name — description` string (advisory, not
  /// authoritative). Order is fixed; a monorepo's arbitrary first match is acceptable.
  private static func manifest(in worktree: URL) -> String? {
    if let s = jsonNameDesc(worktree.appendingPathComponent("composer.json")) { return s }
    if let s = jsonNameDesc(worktree.appendingPathComponent("package.json")) { return s }
    if let s = grepFirst(worktree.appendingPathComponent("Package.swift"), pattern: #"name:\s*"([^"]+)""#) { return s }
    if let s = tomlNameDesc(worktree.appendingPathComponent("Cargo.toml")) { return s }
    if let s = tomlNameDesc(worktree.appendingPathComponent("pyproject.toml")) { return s }
    return nil
  }

  private static func jsonNameDesc(_ url: URL) -> String? {
    guard let data = try? Data(contentsOf: url),
          let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
    return joinNameDesc(obj["name"] as? String, obj["description"] as? String)
  }

  private static func tomlNameDesc(_ url: URL) -> String? {
    let name = grepFirst(url, pattern: #"(?m)^\s*name\s*=\s*"([^"]+)""#)
    let desc = grepFirst(url, pattern: #"(?m)^\s*description\s*=\s*"([^"]+)""#)
    return joinNameDesc(name, desc)
  }

  private static func joinNameDesc(_ name: String?, _ desc: String?) -> String? {
    let parts = [name, desc].compactMap { $0 }.filter { !$0.isEmpty }
    guard !parts.isEmpty else { return nil }
    return String(parts.joined(separator: " — ").prefix(300))
  }

  /// First capture group of the first regex match in the file's head, or nil.
  private static func grepFirst(_ url: URL, pattern: String) -> String? {
    guard let text = head(of: url, maxBytes: 4096),
          let re = try? NSRegularExpression(pattern: pattern) else { return nil }
    let range = NSRange(text.startIndex..., in: text)
    guard let m = re.firstMatch(in: text, range: range), m.numberOfRanges > 1,
          let r = Range(m.range(at: 1), in: text) else { return nil }
    return String(text[r])
  }

  /// Bounded UTF-8 head of a file: up to `maxBytes` and `maxLines`, trimmed. nil if absent,
  /// empty, or not decodable as UTF-8 (i.e. binary).
  private static func head(of url: URL, maxBytes: Int = 1024, maxLines: Int = 40) -> String? {
    guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
    defer { try? handle.close() }
    let data = (try? handle.read(upToCount: maxBytes)) ?? Data()
    guard !data.isEmpty, let s = String(data: data, encoding: .utf8) else { return nil }
    let joined = s.split(separator: "\n", omittingEmptySubsequences: false).prefix(maxLines).joined(separator: "\n")
    let trimmed = joined.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  /// Builds the naming prompt from the present signals only.
  static func namePrompt(_ ctx: ProjectContext) -> String {
    var lines = ["Directory name: \(ctx.dirName)"]
    if let r = ctx.gitRemote { lines.append("Git remote: \(r)") }
    if let m = ctx.manifest { lines.append("Package manifest: \(m)") }
    if let rd = ctx.readmeHead { lines.append("README excerpt:\n\(rd)") }
    if let cm = ctx.claudeMdHead { lines.append("CLAUDE.md excerpt:\n\(cm)") }
    return """
    Infer a concise, human-readable display name for this software project from the signals below. \
    Output only the name on a single line: 2-6 words, Title Case, a plain label — no numbering, \
    bullets, quotes, or trailing period. Prefer what the signals say; sensible formatting and \
    expanding an abbreviation the signals support is fine, but do not invent a category (like \
    "App", "CLI", or "Package") the signals do not support.

    \(lines.joined(separator: "\n"))
    """
  }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `./scripts/test.sh --filter ProjectContext`
Expected: PASS (6 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/PensieveKit/Ingest/ProjectContext.swift Tests/PensieveKitTests/ProjectContextTests.swift
git commit -m "feat: ProjectContext gathers local repo signals for name inference"
```

---

### Task 2: `refineProjectNames()` + `metadataJSON` marker

**Files:**
- Modify: `Sources/PensieveKit/Ingest/Ingester.swift` (add marker helpers + `refineProjectNames()`)
- Test: `Tests/PensieveKitTests/RefineProjectNamesTests.swift`

**Interfaces:**
- Consumes: `ProjectContext.gather(commonDir:)`, `ProjectContext.namePrompt(_:)` (Task 1); `Ingester.sanitizeStrandName(_:)`, `Ingester.llm`, `writeSync`/`readSync` (existing); `ProjectResolver.displayName(forKey:)`; `SourceKind.gitRepo`.
- Produces:
  - `func refineProjectNames() async` (best-effort, void, never throws).
  - `static func nameInferred(inMetadata json: String) -> Bool`
  - `static func settingNameInferred(in json: String) -> String`
  - `static let nameRefineCap = 20`

- [ ] **Step 1: Write the failing tests**

Create `Tests/PensieveKitTests/RefineProjectNamesTests.swift`:

```swift
import Foundation
import Testing
import SQLiteData
@testable import PensieveKit

private struct StubLLM: LLMProvider {
  let text: String
  func complete(prompt: String) async throws -> String { text }
}
private struct FailingLLM: LLMProvider {
  func complete(prompt: String) async throws -> String { throw LLMError.providerFailed("nope") }
}

/// Drains a single commit so a project node is born with the verbatim directory name.
private func bornProjectNode(repo: URL, spool: CaptureSpool, db: any DatabaseWriter,
                             llm: (any LLMProvider)? = nil) async throws -> Node {
  let hash = Git.run(["rev-parse", "HEAD"], in: repo.path)!
  try spool.append(kind: CaptureKind.gitCommit,
                   payload: try encodeJSON(GitCommitPayload(repoPath: repo.path, hash: hash, branch: "main")))
  _ = try await Ingester(spool: spool, db: db, llm: llm).drain()
  return try await db.read { db in try Node.where { $0.kind.eq("project") }.fetchAll(db) }.first!
}

// MARK: marker helpers

@Test func nameInferredMarkerRoundTrips() {
  #expect(Ingester.nameInferred(inMetadata: "{}") == false)
  let stamped = Ingester.settingNameInferred(in: "{}")
  #expect(Ingester.nameInferred(inMetadata: stamped) == true)
}

@Test func settingNameInferredPreservesOtherKeys() {
  let stamped = Ingester.settingNameInferred(in: #"{"foo":"bar"}"#)
  #expect(stamped.contains("\"foo\":\"bar\""))
  #expect(Ingester.nameInferred(inMetadata: stamped) == true)
}

// MARK: refine pass

@Test func refinesUntouchedGitProjectNameAndStampsMarker() async throws {
  let (repo, _) = try makeCommittedRepo()
  let spool = try CaptureSpool(at: tempURL("spool"))
  let db = try openCanonicalDatabase(at: tempURL("canon"))
  let node = try await bornProjectNode(repo: repo, spool: spool, db: db)

  await Ingester(spool: spool, db: db, llm: StubLLM(text: "Laravel RLS Package")).refineProjectNames()

  let after = try await db.read { db in try Node.where { $0.id.eq(node.id) }.fetchOne(db) }!
  #expect(after.name == "Laravel RLS Package")
  #expect(Ingester.nameInferred(inMetadata: after.metadataJSON) == true)
}

@Test func skipsHandRenamedNode() async throws {
  let (repo, _) = try makeCommittedRepo()
  let spool = try CaptureSpool(at: tempURL("spool"))
  let db = try openCanonicalDatabase(at: tempURL("canon"))
  let node = try await bornProjectNode(repo: repo, spool: spool, db: db)
  try await db.write { db in
    try Node.where { $0.id.eq(node.id) }.update { $0.name = "My Custom Name" }.execute(db)
  }

  await Ingester(spool: spool, db: db, llm: StubLLM(text: "Should Not Apply")).refineProjectNames()

  let after = try await db.read { db in try Node.where { $0.id.eq(node.id) }.fetchOne(db) }!
  #expect(after.name == "My Custom Name")                 // untouched-default guard
}

@Test func skipsNodeWithTwoGitRepoSources() async throws {
  let (repo, _) = try makeCommittedRepo()
  let spool = try CaptureSpool(at: tempURL("spool"))
  let db = try openCanonicalDatabase(at: tempURL("canon"))
  let node = try await bornProjectNode(repo: repo, spool: spool, db: db)
  // Simulate a merged (grouped) node: a second gitRepo source pointing elsewhere.
  try await db.write { db in
    try Source.insert { Source(nodeID: node.id, kind: SourceKind.gitRepo, key: "/other/repo/.git") }.execute(db)
  }

  await Ingester(spool: spool, db: db, llm: StubLLM(text: "Should Not Apply")).refineProjectNames()

  let after = try await db.read { db in try Node.where { $0.id.eq(node.id) }.fetchOne(db) }!
  #expect(after.name == node.name)                         // merged node left alone
}

@Test func markerMakesRefineIdempotentEvenWhenModelEchoesDefault() async throws {
  let (repo, _) = try makeCommittedRepo()
  let spool = try CaptureSpool(at: tempURL("spool"))
  let db = try openCanonicalDatabase(at: tempURL("canon"))
  let node = try await bornProjectNode(repo: repo, spool: spool, db: db)
  // Model returns the dir name verbatim: name stays == default, but the marker must still be set
  // so a second pass does NOT re-infer (no infinite re-naming loop).
  let echo = StubLLM(text: node.name)

  await Ingester(spool: spool, db: db, llm: echo).refineProjectNames()
  let mid = try await db.read { db in try Node.where { $0.id.eq(node.id) }.fetchOne(db) }!
  #expect(Ingester.nameInferred(inMetadata: mid.metadataJSON) == true)

  // Second pass with a DIFFERENT name must be a no-op because the node is already marked.
  await Ingester(spool: spool, db: db, llm: StubLLM(text: "Different Name")).refineProjectNames()
  let after = try await db.read { db in try Node.where { $0.id.eq(node.id) }.fetchOne(db) }!
  #expect(after.name == node.name)
}

@Test func failingProviderKeepsNameButStillStampsMarker() async throws {
  let (repo, _) = try makeCommittedRepo()
  let spool = try CaptureSpool(at: tempURL("spool"))
  let db = try openCanonicalDatabase(at: tempURL("canon"))
  let node = try await bornProjectNode(repo: repo, spool: spool, db: db)

  await Ingester(spool: spool, db: db, llm: FailingLLM()).refineProjectNames()

  let after = try await db.read { db in try Node.where { $0.id.eq(node.id) }.fetchOne(db) }!
  #expect(after.name == node.name)                         // fallback kept
  #expect(Ingester.nameInferred(inMetadata: after.metadataJSON) == true)   // but not retried
}

@Test func refineIsNoOpWithoutProvider() async throws {
  let (repo, _) = try makeCommittedRepo()
  let spool = try CaptureSpool(at: tempURL("spool"))
  let db = try openCanonicalDatabase(at: tempURL("canon"))
  let node = try await bornProjectNode(repo: repo, spool: spool, db: db)

  await Ingester(spool: spool, db: db, llm: nil).refineProjectNames()

  let after = try await db.read { db in try Node.where { $0.id.eq(node.id) }.fetchOne(db) }!
  #expect(after.name == node.name)
  #expect(Ingester.nameInferred(inMetadata: after.metadataJSON) == false)  // never attempted
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `./scripts/test.sh --filter RefineProjectNames`
Expected: FAIL — `refineProjectNames`, `nameInferred`, `settingNameInferred` not defined.

- [ ] **Step 3: Add marker helpers + `refineProjectNames()` to `Ingester`**

Insert into `Sources/PensieveKit/Ingest/Ingester.swift`, immediately after `sanitizeStrandName(_:)` (around line 204):

```swift
  /// Per-pass cap so a big first run (or a flush-and-reingest) can't stall the sync cycle on N
  /// sequential model calls. The `nameInferred` marker makes the remainder monotonic across passes.
  static let nameRefineCap = 20

  /// True when `metadataJSON` already carries the "naming attempted" marker.
  static func nameInferred(inMetadata json: String) -> Bool {
    let obj = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any]
    return (obj?["nameInferred"] as? Bool) ?? false
  }

  /// Returns `metadataJSON` with the "naming attempted" marker set, preserving other keys.
  static func settingNameInferred(in json: String) -> String {
    var obj = ((try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any]) ?? [:]
    obj["nameInferred"] = true
    guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])
    else { return json }
    return String(decoding: data, as: UTF8.self)
  }

  /// Best-effort, once-per-node display-name inference for git project nodes. Selects untouched,
  /// single-`gitRepo` project nodes (name still == verbatim default, not already marked), infers
  /// a name on-device from local repo signals, and writes it — always stamping the marker so each
  /// node is attempted exactly once. Non-fatal and outside the trust gate (organizational label),
  /// exactly like `nameStrand`. A no-op when no provider is configured (e.g. the app's drain).
  func refineProjectNames() async {
    guard let llm else { return }

    struct Candidate { let id: UUID; let commonDir: String; let metadataJSON: String }
    let candidates: [Candidate] = (try? readSync { db -> [Candidate] in
      let projects = try Node.where { $0.kind.eq("project") }.fetchAll(db)
      var out: [Candidate] = []
      for node in projects {
        if Self.nameInferred(inMetadata: node.metadataJSON) { continue }
        let gitSources = try Source
          .where { $0.nodeID.eq(node.id) && $0.kind.eq(SourceKind.gitRepo) }.fetchAll(db)
        guard gitSources.count == 1, let key = gitSources.first?.key else { continue }
        guard node.name == ProjectResolver.displayName(forKey: key) else { continue }
        out.append(Candidate(id: node.id, commonDir: key, metadataJSON: node.metadataJSON))
      }
      return out
    }) ?? []

    for candidate in candidates.prefix(Self.nameRefineCap) {
      let ctx = ProjectContext.gather(commonDir: candidate.commonDir)
      let raw = try? await llm.complete(prompt: ProjectContext.namePrompt(ctx))
      let firstLine = raw?.split(separator: "\n", omittingEmptySubsequences: true)
        .first.map(String.init) ?? ""
      let name = Self.sanitizeStrandName(firstLine)
      let newMeta = Self.settingNameInferred(in: candidate.metadataJSON)
      try? writeSync { db in
        if let name {
          try Node.where { $0.id.eq(candidate.id) }
            .update { $0.name = name; $0.metadataJSON = newMeta }.execute(db)
        } else {
          try Node.where { $0.id.eq(candidate.id) }
            .update { $0.metadataJSON = newMeta }.execute(db)
        }
      }
    }
  }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `./scripts/test.sh --filter RefineProjectNames`
Expected: PASS (8 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/PensieveKit/Ingest/Ingester.swift Tests/PensieveKitTests/RefineProjectNamesTests.swift
git commit -m "feat: Ingester.refineProjectNames — once-per-node on-device git project naming"
```

---

### Task 3: Wire into `SyncRunner`

**Files:**
- Modify: `Sources/PensieveKit/Sync/SyncRunner.swift:38` (after the second drain)
- Test: `Tests/PensieveKitTests/SyncRunnerTests.swift` (add one test)

**Interfaces:**
- Consumes: `Ingester.refineProjectNames()` (Task 2), the existing `ingester` local in `SyncRunner.run()`.
- Produces: no signature change to `SyncRunner.run()`.

- [ ] **Step 1: Write the failing test**

Append to `Tests/PensieveKitTests/SyncRunnerTests.swift`:

```swift
/// A provider that returns a fixed name (and no loose ends) so the refine pass is deterministic.
private struct NamingProvider: LLMProvider {
  let name: String
  func complete(prompt: String) async throws -> String { name }
  func extractCandidates(prompt: String) async throws -> [LooseEndCandidate] { [] }
  func classifyGenuineIndices(prompt: String) async throws -> [Int] { [] }
}

@Test func syncRefinesGitProjectNameAfterDrain() async throws {
  let projects = tmp("projects", ext: "d")
  try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
  let spool = try CaptureSpool(at: tmp("sync-spool", ext: "sqlite"))
  let db = try openCanonicalDatabase(at: tmp("sync-canon", ext: "sqlite"))

  // A committed repo + one spooled commit → a project node born with the verbatim dir name.
  let (repo, hash) = try makeCommittedRepo()
  try spool.append(kind: CaptureKind.gitCommit,
                   payload: try encodeJSON(GitCommitPayload(repoPath: repo.path, hash: hash, branch: "main")))

  let runner = SyncRunner(spool: spool, db: db, provider: NamingProvider(name: "Cool Project"),
                          projectsDir: projects, now: { Date() })
  _ = try await runner.run()

  let node = try await db.read { db in try Node.where { $0.kind.eq("project") }.fetchAll(db) }.first!
  #expect(node.name == "Cool Project")
  #expect(Ingester.nameInferred(inMetadata: node.metadataJSON) == true)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `./scripts/test.sh --filter syncRefinesGitProjectNameAfterDrain`
Expected: FAIL — node name is still the verbatim repo directory name (refine not wired in).

- [ ] **Step 3: Call `refineProjectNames()` after the second drain**

In `Sources/PensieveKit/Sync/SyncRunner.swift`, change the second-drain block (line 38):

```swift
    ingested += try await ingester.drain()
    await ingester.refineProjectNames()
```

- [ ] **Step 4: Run the new test + the existing SyncRunner test**

Run: `./scripts/test.sh --filter SyncRunner`
Expected: PASS (existing `syncDiscoversIngestsThenNoOpsThenReextractsOnGrowth` + new `syncRefinesGitProjectNameAfterDrain`).

- [ ] **Step 5: Run the full suite**

Run: `./scripts/test.sh`
Expected: PASS — all prior tests plus the 15 new ones (6 + 8 + 1).

- [ ] **Step 6: Commit**

```bash
git add Sources/PensieveKit/Sync/SyncRunner.swift Tests/PensieveKitTests/SyncRunnerTests.swift
git commit -m "feat: run project-name inference after the sync drain"
```

---

## Retroactive application (manual, after merge — not a code task)

Everything in the current canonical store is auto-generated and reproducible, so to re-name existing nodes:

1. **Back up** `~/Library/Application Support/Pensieve/pensieve.sqlite` (copy aside). The capture spool `capture.sqlite` is untouched.
2. Delete `pensieve.sqlite` and run `pensieve sync` (or wait for the LaunchAgent). Every node re-births with its verbatim default and, having no `nameInferred` marker, is named by `refineProjectNames()`.
3. Diff the fresh store against the backup and manually reconcile anything worth keeping (hand `rename`/`retype`/`nest`/`group`). Expected to be near-empty since the store to date is auto-generated.

## Self-Review notes

- **Spec coverage:** §1 control flow → Task 2 (candidate filter, marker, cap) + Task 3 (hook site after 2nd drain, `llm==nil` no-op). §2 signal gathering → Task 1 (`gather`, `rev-parse --show-toplevel` derivation, text-only README, advisory manifest). §3 prompt/sanitize/marker → Task 1 `namePrompt` + Task 2 `sanitizeStrandName` reuse + marker-always. §4 retroactive → manual section above. Blast-radius note → no code (accepted tradeoff). Testing matrix → Task 1 (normal/absent/worktree/bare/binary-README/prompt) + Task 2 (refine/hand-rename/two-source/model-echo idempotent/failing/`llm==nil`) + Task 3 (end-to-end via SyncRunner).
- **Submodule case:** handled by the same `lastPathComponent == ".git"` guard as bare (a submodule common-dir ends in the submodule name, not `.git`), so the bare-repo test exercises the identical no-worktree branch; no separate fixture needed.
- **Type consistency:** `refineProjectNames()`, `nameInferred(inMetadata:)`, `settingNameInferred(in:)`, `nameRefineCap`, `ProjectContext.gather(commonDir:)`, `ProjectContext.namePrompt(_:)` used identically across tasks.
