# Pensieve Phase 1B-org — Typed Tree & Strands Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn the flat `Project` model into a strict recursive tree of typed `Node`s, and auto-birth *strand* nodes (branch/worktree forks) from real git/session activity, without touching the loose-end trust gate.

**Architecture:** Rename `Project → Node` (table `projects → nodes`) with `parentID`/`kind`/`description`/`metadataJSON`/`branchKey`. The strand lives on the **event**: every `Event` records the point-in-time `branchKey` it belongs to and a `nodeID` pointing at the most-specific node (project node by default; repointed to a strand once that branch crosses a ≥2-same-kind-events threshold). A new dumb `SessionStart` Claude Code hook captures the branch a session launched on; the ingester resolves stable repo facts (git-common-dir, default branch) where it already shells `git`. Strand names/descriptions are organizational labels produced by the on-device LLM at materialization — outside the verbatim gate by design.

**Tech Stack:** Swift 6, SQLiteData (GRDB-backed), STRICT SQLite tables, UUID PKs, Swift Testing, ArgumentParser CLI.

## Global Constraints

- **Build/test with `./scripts/test.sh` (optionally `--filter <name>`), NOT `swift test`** — this machine is Command Line Tools–only. `swift build`/`swift run` work normally.
- **SQLiteData predicates use `.eq(x)`, NOT `== x`** (e.g. `.where { $0.name.eq(name) }`). `==` is `unavailable`.
- Table/column names must match `@Table` property names exactly; tables are `STRICT`; PKs are `UUID` (keeps CloudKit reachable).
- Kind strings live in `CaptureKind` / `SourceKind` (`CapturePayloads.swift`) — reuse the constants, don't hardcode.
- No shared mutable `static ISO8601DateFormatter` (Swift 6 concurrency); use a local instance or `Date.ISO8601FormatStyle`.
- **No Python, ever. Swift only.**
- LLM work goes through the `LLMProvider` protocol; the default shells out to `claude -p`. There is no API key. Stay provider-agnostic.
- **The capture path is sacred:** hooks/`capture-*` commands must be fast, fire-and-forget, and must never block or break a git commit or a session launch. No LLM calls on the capture path.
- **The trust gate is untouched by this phase.** Loose-end extraction (`LooseEndExtractor`/`IntentClassifier`/`LooseEndVerifier`/`ExtractionRunner`) is not modified. Strand labels are metadata, not surfaced discrete claims.
- Tests/CLI honor `PENSIEVE_DB` / `PENSIEVE_CAPTURE_DB` env overrides.
- Disk runs tight; on a SwiftSyntax/macro linker error, `rm -rf .build` and retry.

**Spec:** `docs/superpowers/specs/2026-07-03-pensieve-phase1b-org-design.md`.

---

## Deviations from the spec (decided while planning — read before starting)

1. **The migration is split across three additive migrations, not one `v4`.** `v4-nodes-tree` (Task 1: rename + tree columns + FK renames), `v5-event-branchkey` (Task 2), `v6-session-branches` (Task 3). SQLiteData maps each `@Table` struct to its columns by property name, so each schema change ships in the same task as its model change. This is functionally identical to the spec's single additive v4 and keeps every task's migration self-contained.
2. **A canonical `sessionBranches` table (model `SessionBranch`) realizes spec §4.2's "joined to its branch by `sessionID` from the `cc.session.start` row."** The spec names the capture kind + payload but not where the branch persists between session-start capture and (later) session-content ingest. Spool rows are consumed on drain, so the branch is persisted canonically. This is the one table the spec's §8 list didn't enumerate.
3. **Helper *type* names stay (`ProjectResolver`, `ProjectQueries`, `ProjectStatus`, `NextItem.project`, `SummaryBuilder.assembleFacts(project:)`).** The spec references `ProjectResolver`/`group()` by name and mandates renaming only the model (`Project→Node`) and the FK columns/params (`projectID→nodeID`). Renaming the model type and DB columns is in scope; renaming these local API surfaces is not (surgical). Their `.project`/`project:` labels now carry `Node` values.

---

## File Structure

**Renamed:**
- `Sources/PensieveKit/Model/Project.swift` → `Sources/PensieveKit/Model/Node.swift` — the tree node (was `Project`), gains `parentID`/`kind`/`description`/`metadataJSON`/`branchKey`.

**Created:**
- `Sources/PensieveKit/Model/SessionBranch.swift` — canonical record of the branch a session launched on (keyed by `sessionID`).
- `Sources/PensieveKit/Capture/SettingsHookInstaller.swift` — idempotent JSON merge of the `SessionStart` hook into `~/.claude/settings.json`.
- `Sources/PensieveKit/Query/NodeCommands.swift` — organizing writes (`add`/`nest`/`rename`/`retype`/`find`) + `NodeTree.render`.
- `Sources/pensieve/Commands/CaptureSessionStart.swift` — dumb capture command reading the `SessionStart` hook JSON from stdin.
- `Sources/pensieve/Commands/InstallSessionHook.swift` — installs the settings.json hook.
- `Sources/pensieve/Commands/AddNode.swift`, `Nest.swift`, `RenameNode.swift`, `RetypeNode.swift` — organizing CLI.
- Test files: `SchemaV4Tests.swift`, `StrandBirthTests.swift`, `SessionBranchTests.swift`, `SettingsHookInstallerTests.swift`, `NodeCommandsTests.swift`.

**Modified (Task 1 rename touches all of these):** every model referencing `projectID`, all `Query/*`, `Ingest/*`, `Intelligence/SummaryBuilder.swift` + `ExtractionRunner.swift`, `Store/CanonicalStore.swift`, CLI `Status.swift`/`LooseEnds.swift`, and all tests referencing `Project`/`projectID`.

---

## Task 1: Rename `Project → Node`, add tree columns, migration `v4-nodes-tree`

Foundational and wide. The codebase will not compile mid-rename, so the whole rename + migration ships as one atomic task with one green checkpoint.

**Files:**
- Rename + rewrite: `Sources/PensieveKit/Model/Node.swift` (was `Model/Project.swift`)
- Modify: `Sources/PensieveKit/Model/{Source,Event,LooseEnd,Checkpoint}.swift` (`projectID → nodeID`)
- Modify: `Sources/PensieveKit/Store/CanonicalStore.swift` (add migration `v4-nodes-tree`)
- Modify: `Sources/PensieveKit/Query/{ProjectQueries,LooseEndQueries,NextQueries,CheckpointCommands}.swift`
- Modify: `Sources/PensieveKit/Ingest/{ProjectResolver,Ingester}.swift`
- Modify: `Sources/PensieveKit/Intelligence/{SummaryBuilder,ExtractionRunner}.swift`
- Modify: `Sources/pensieve/Commands/{Status,LooseEnds}.swift` (the `projectID:` argument label on `LooseEndQueries.open`)
- Modify: all tests referencing `Project`/`projectID` (see rename rules)
- Create: `Tests/PensieveKitTests/SchemaV4Tests.swift`

**Interfaces:**
- Produces: `struct Node` with `init(id:name:state:createdAt:parentID:kind:description:metadataJSON:branchKey:)` (all but `name` defaulted); table `nodes`.
- Produces: `Event.nodeID`, `Source.nodeID`, `LooseEnd.nodeID`, `Checkpoint.nodeID` (renamed from `projectID`).
- Produces: `ProjectResolver.resolve(_:path:kind:)` now returns `(node: Node, source: Source)`; `LooseEndQueries.open(_:nodeID:now:)`.

### The rename rules (apply everywhere, in Sources and Tests)

These are pure token renames — apply globally, then let the compiler + tests confirm completeness:

- Type `Project` → `Node` (declarations, `Project.where`, `Project.insert`, `Project.all`, `Project.order`, type annotations `[Project]`, `project: Project`).
- Property/column/argument-label `projectID` → `nodeID` (models, `Event(projectID:…)` call sites, `LooseEndQueries.open(…, projectID:)`, `$0.projectID.eq`).
- Migration only: table `projects` → `nodes`, columns `projectID` → `nodeID`.
- **Do NOT rename:** `ProjectResolver`, `ProjectQueries`, `ProjectStatus`, `NextItem`, the tuple/field labels `.project` / `project:` (these keep their names and now carry `Node` values — see Deviation 3).

- [ ] **Step 1: Rewrite the model as `Node` with tree columns**

`git mv Sources/PensieveKit/Model/Project.swift Sources/PensieveKit/Model/Node.swift`, then replace its contents:

```swift
import Foundation
import SQLiteData

@Table
public struct Node: Identifiable, Equatable, Sendable {
  public let id: UUID
  public var name: String
  public var state: String          // "active" | "archived" | "muted"
  public var createdAt: Date
  public var parentID: UUID?        // strict tree; nil = root
  public var kind: String           // open string: domain|project|strand|concept|initiative|task|topic
  public var description: String    // LLM- or user-authored
  public var metadataJSON: String   // YAGNI bag for non-queried extras
  public var branchKey: String?     // set only on kind == "strand"

  public init(id: UUID = UUID(), name: String, state: String = "active", createdAt: Date = Date(),
              parentID: UUID? = nil, kind: String = "project", description: String = "",
              metadataJSON: String = "{}", branchKey: String? = nil) {
    self.id = id; self.name = name; self.state = state; self.createdAt = createdAt
    self.parentID = parentID; self.kind = kind; self.description = description
    self.metadataJSON = metadataJSON; self.branchKey = branchKey
  }
}
```

- [ ] **Step 2: Rename `projectID → nodeID` on the four FK-bearing models**

In each of `Source.swift`, `Event.swift`, `LooseEnd.swift`, `Checkpoint.swift`: rename the stored property `projectID` to `nodeID`, its `init` parameter, and the `self.projectID = projectID` assignment. Example for `Source.swift`:

```swift
@Table
public struct Source: Identifiable, Equatable, Sendable {
  public let id: UUID
  public var nodeID: UUID
  public var kind: String
  public var key: String
  public var createdAt: Date
  public init(id: UUID = UUID(), nodeID: UUID, kind: String, key: String, createdAt: Date = Date()) {
    self.id = id; self.nodeID = nodeID; self.kind = kind; self.key = key; self.createdAt = createdAt
  }
}
```

Apply the identical shape to `Event`, `LooseEnd`, `Checkpoint` (leave all other fields untouched).

- [ ] **Step 3: Add migration `v4-nodes-tree`**

In `Sources/PensieveKit/Store/CanonicalStore.swift`, register a new migration immediately after `v3-fingerprint-extraction-provenance` (before `try migrator.migrate(db)`):

```swift
  migrator.registerMigration("v4-nodes-tree") { db in
    try #sql(#"ALTER TABLE "projects" RENAME TO "nodes""#).execute(db)
    try #sql(#"ALTER TABLE "nodes" ADD COLUMN "parentID" TEXT REFERENCES "nodes"("id") ON DELETE SET NULL"#).execute(db)
    try #sql(#"ALTER TABLE "nodes" ADD COLUMN "kind" TEXT NOT NULL DEFAULT 'project'"#).execute(db)
    try #sql(#"ALTER TABLE "nodes" ADD COLUMN "description" TEXT NOT NULL DEFAULT ''"#).execute(db)
    try #sql(#"ALTER TABLE "nodes" ADD COLUMN "metadataJSON" TEXT NOT NULL DEFAULT '{}'"#).execute(db)
    try #sql(#"ALTER TABLE "nodes" ADD COLUMN "branchKey" TEXT"#).execute(db)
    try #sql(#"ALTER TABLE "sources" RENAME COLUMN "projectID" TO "nodeID""#).execute(db)
    try #sql(#"ALTER TABLE "events" RENAME COLUMN "projectID" TO "nodeID""#).execute(db)
    try #sql(#"ALTER TABLE "looseEnds" RENAME COLUMN "projectID" TO "nodeID""#).execute(db)
    try #sql(#"ALTER TABLE "checkpoints" RENAME COLUMN "projectID" TO "nodeID""#).execute(db)
  }
```

(SQLite ≥3.25 auto-updates the `idx_events_project` index's column reference and the child-table FK references on `RENAME TO`/`RENAME COLUMN`. `ADD COLUMN … REFERENCES` is allowed because `parentID` defaults to NULL.)

- [ ] **Step 4: Propagate the rename through queries, ingest, intelligence, and CLI**

Apply the rename rules to: `ProjectQueries.swift`, `LooseEndQueries.swift` (rename the `open` parameter `projectID:` → `nodeID:` and the two `$0.projectID.eq` uses), `NextQueries.swift`, `CheckpointCommands.swift`, `ProjectResolver.swift` (tuple type `Project → Node`, `$0.projectID` → `$0.nodeID`, `Project.insert`/`Project.where` → `Node.…`, and the new-node line `let project = Node(name: (path as NSString).lastPathComponent)`), `Ingester.swift` (`Event(projectID:…)` → `Event(nodeID:…)`, the resolver tuple binding stays `(project, source)`), `SummaryBuilder.swift` (`project: Project` → `project: Node`), `ExtractionRunner.swift` (`$0.projectID.eq(event.projectID)` → `$0.nodeID.eq(event.nodeID)`, `LooseEnd(projectID:…)` → `LooseEnd(nodeID:…)`), and CLI `Status.swift` + `LooseEnds.swift` (the `LooseEndQueries.open(db, projectID:…)` call → `nodeID:`).

- [ ] **Step 5: Propagate the rename through all tests**

Apply the rename rules to every test file the compiler flags: `SchemaTests.swift`, `SchemaV3Tests.swift`, `CanonicalStoreTests.swift`, `ProjectResolverTests.swift`, `ProjectQueriesTests.swift`, `IngesterTests.swift`, `NextQueriesTests.swift`, `ExtractionRunnerTests.swift`, `SummaryBuilderTests.swift`, `LooseEndQueriesTests.swift`, `CheckpointTests.swift`. (`Project.all` → `Node.all`, `projectID:` → `nodeID:`, `Project(name:)` → `Node(name:)`, `.project` labels stay.)

- [ ] **Step 6: Write the migration test (fails first)**

Create `Tests/PensieveKitTests/SchemaV4Tests.swift`:

```swift
import Foundation
import Testing
import SQLiteData
@testable import PensieveKit

@Test func v4RenamesProjectsToNodesWithTreeDefaults() throws {
  let db = try openCanonicalDatabase(at: tempURL("v4"))
  let node = Node(name: "Colibri")
  let source = Source(nodeID: node.id, kind: SourceKind.claudeCode, key: "/p/colibri")
  try db.write { db in
    try Node.insert { node }.execute(db)
    try Source.insert { source }.execute(db)
  }
  let fetched = try db.read { db in try Node.all.fetchAll(db) }.first
  #expect(fetched?.kind == "project")       // existing rows migrate to top-level project nodes
  #expect(fetched?.parentID == nil)
  #expect(fetched?.description == "")
  #expect(fetched?.metadataJSON == "{}")
  #expect(fetched?.branchKey == nil)
  let src = try db.read { db in try Source.all.fetchAll(db) }.first
  #expect(src?.nodeID == node.id)           // FK column renamed and still joins
}
```

- [ ] **Step 7: Build, run the full suite, confirm green**

Run: `./scripts/test.sh`
Expected: all pre-existing tests pass under the renamed schema, plus `v4RenamesProjectsToNodesWithTreeDefaults` PASS. (If a SwiftSyntax/macro linker error appears, `rm -rf .build` and retry.)

- [ ] **Step 8: Commit**

```bash
git add -A
git commit -m "refactor: rename Project→Node, add typed-tree columns, migration v4"
```

---

## Task 2: Common-dir source keying + `Event.branchKey` for git commits, migration `v5-event-branchkey`

Unify all worktrees of a repo into one node, and tag every non-default-branch commit with the branch it belongs to (no strand yet).

**Files:**
- Modify: `Sources/PensieveKit/Support/Git.swift` (add `commonDir`, `defaultBranch`, `strandBranchKey`)
- Modify: `Sources/PensieveKit/Ingest/ProjectResolver.swift` (add `displayName(forKey:)`, use it in the new-node branch)
- Modify: `Sources/PensieveKit/Model/Event.swift` (add `branchKey`)
- Modify: `Sources/PensieveKit/Store/CanonicalStore.swift` (migration `v5-event-branchkey`)
- Modify: `Sources/PensieveKit/Ingest/Ingester.swift` (commit + session handlers key on common-dir; commit tags `branchKey`)
- Modify: `Tests/PensieveKitTests/TestSupport.swift` (add a worktree helper)
- Create: `Tests/PensieveKitTests/` additions inside `IngesterTests.swift` (branchKey + worktree tests)

**Interfaces:**
- Consumes: `Node`, `Event.nodeID` (Task 1).
- Produces: `Git.commonDir(in:) -> String?`, `Git.defaultBranch(in:) -> String`, `Git.strandBranchKey(branch:defaultBranch:) -> String?`.
- Produces: `ProjectResolver.displayName(forKey:) -> String`.
- Produces: `Event.branchKey: String?` (new field, defaulted to nil in `init`).

- [ ] **Step 1: Write failing tests for the git helpers (pure decision + worktree unification)**

Add a worktree helper to `TestSupport.swift`:

```swift
/// Adds a linked worktree on a new branch to an existing repo; returns its path.
func addWorktree(to repo: URL, branch: String) throws -> URL {
  let wt = tempURL("worktree", ext: nil)
  _ = Git.run(["worktree", "add", "-b", branch, wt.path], in: repo.path)
  return wt
}
```

Add to `IngesterTests.swift`:

```swift
@Test func strandBranchKeyIgnoresDefaultAndDetached() {
  #expect(Git.strandBranchKey(branch: "main", defaultBranch: "main") == nil)
  #expect(Git.strandBranchKey(branch: "HEAD", defaultBranch: "main") == nil)
  #expect(Git.strandBranchKey(branch: "", defaultBranch: "main") == nil)
  #expect(Git.strandBranchKey(branch: "feature-x", defaultBranch: "main") == "feature-x")
}

@Test func worktreesOfOneRepoShareCommonDir() throws {
  let (repo, _) = try makeCommittedRepo()
  guard let wt = try? addWorktree(to: repo, branch: "feature"),
        FileManager.default.fileExists(atPath: wt.path) else { return }  // worktree unsupported here
  #expect(Git.commonDir(in: repo.path) == Git.commonDir(in: wt.path))
  #expect(Git.commonDir(in: repo.path) != nil)
}
```

Run: `./scripts/test.sh --filter strandBranchKey` → FAIL (`Git.strandBranchKey` not defined).

- [ ] **Step 2: Add the git helpers**

Append to `Sources/PensieveKit/Support/Git.swift` (after the `enum Git` closing brace):

```swift
public extension Git {
  /// The repo-identity directory that unifies all worktrees of one repo. `--git-common-dir`
  /// returns the *main* repo's `.git` even from a linked worktree. nil when `path` is not a repo.
  static func commonDir(in repo: String) -> String? {
    guard let raw = run(["rev-parse", "--path-format=absolute", "--git-common-dir"], in: repo)
    else { return nil }
    return URL(fileURLWithPath: raw).resolvingSymlinksInPath().path
  }

  /// Best-effort default branch: origin/HEAD → init.defaultBranch → probe main/master → "main".
  static func defaultBranch(in repo: String) -> String {
    if let ref = run(["symbolic-ref", "refs/remotes/origin/HEAD"], in: repo),
       let name = ref.split(separator: "/").last, !name.isEmpty {
      return String(name)
    }
    if let cfg = run(["config", "init.defaultBranch"], in: repo), !cfg.isEmpty { return cfg }
    if run(["rev-parse", "--verify", "--quiet", "refs/heads/main"], in: repo) != nil { return "main" }
    if run(["rev-parse", "--verify", "--quiet", "refs/heads/master"], in: repo) != nil { return "master" }
    return "main"
  }

  /// Pure decision: the branch key worth tagging on an event, or nil for default/detached/empty.
  static func strandBranchKey(branch: String, defaultBranch: String) -> String? {
    let b = branch.trimmingCharacters(in: .whitespacesAndNewlines)
    if b.isEmpty || b == "HEAD" || b == defaultBranch { return nil }
    return b
  }
}
```

Run: `./scripts/test.sh --filter strandBranchKey` and `--filter worktreesOfOneRepo` → PASS.

- [ ] **Step 3: Add `branchKey` to `Event` + migration `v5-event-branchkey`**

In `Event.swift`, add `public var branchKey: String?` after `fingerprint` and thread it through `init` (defaulted): add parameter `branchKey: String? = nil` and `self.branchKey = branchKey`.

In `CanonicalStore.swift`, register after `v4-nodes-tree`:

```swift
  migrator.registerMigration("v5-event-branchkey") { db in
    try #sql(#"ALTER TABLE "events" ADD COLUMN "branchKey" TEXT"#).execute(db)
  }
```

- [ ] **Step 4: Add `displayName(forKey:)` to `ProjectResolver` and use it**

In `ProjectResolver.swift`, add:

```swift
  /// Human-readable node name from an identity key. A git common-dir ends in `.git`;
  /// name the node after the repo directory, not ".git".
  static func displayName(forKey key: String) -> String {
    let url = URL(fileURLWithPath: key)
    return url.lastPathComponent == ".git"
      ? url.deletingLastPathComponent().lastPathComponent
      : url.lastPathComponent
  }
```

In the resolver's brand-new-node branch, replace `let project = Node(name: (path as NSString).lastPathComponent)` with:

```swift
    let project = Node(name: Self.displayName(forKey: path))
```

- [ ] **Step 5: Rewrite the ingester commit + session handlers to key on common-dir; commit tags branchKey**

In `Ingester.swift`, replace the `CaptureKind.gitCommit` case body:

```swift
    case CaptureKind.gitCommit:
      let p = try JSONDecoder().decode(GitCommitPayload.self, from: data)
      let key = Git.commonDir(in: p.repoPath) ?? ProjectResolver.canonical(p.repoPath)
      let branchKey = Git.strandBranchKey(branch: p.branch, defaultBranch: Git.defaultBranch(in: p.repoPath))
      let fields = gitCommitFields(hash: p.hash, repo: p.repoPath, fallbackTime: row.ts)
      let detail = try encodeJSON(["hash": p.hash, "branch": p.branch, "files": fields.files])
      let inserted = try db.write { db -> Bool in
        let (project, source) = try resolver.resolve(db, path: key, kind: SourceKind.gitRepo)
        return try insertIfNew(db, Event(nodeID: project.id, sourceID: source.id, occurredAt: fields.when,
              kind: CaptureKind.gitCommit, summary: fields.subject, detailJSON: detail,
              fingerprint: Fingerprint.commit(hash: p.hash), branchKey: branchKey))
      }
      return inserted ? 1 : 0
```

In the `CaptureKind.gitCheckout` and `CaptureKind.ccSession` cases, replace the source-key computation to use common-dir. For checkout: `let key = Git.commonDir(in: p.repoPath) ?? ProjectResolver.canonical(p.repoPath)` and pass `key` to `resolver.resolve`. For the session case, replace `let key = Git.run(["rev-parse", "--show-toplevel"], in: cwd) ?? cwd` with:

```swift
      let key = Git.commonDir(in: cwd) ?? ProjectResolver.canonical(cwd)
```

(Session `branchKey` stays nil until Task 3.)

- [ ] **Step 6: Write failing tests for commit branchKey + worktree node unification**

Add to `IngesterTests.swift`:

```swift
@Test func commitOnFeatureBranchTagsBranchKey() throws {
  let (repo, _) = try makeCommittedRepo()   // default branch resolves to "main"
  _ = Git.run(["checkout", "-b", "feature-x"], in: repo.path)
  try "more".write(to: repo.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)
  _ = Git.run(["add", "-A"], in: repo.path)
  _ = Git.run(["commit", "-m", "on feature"], in: repo.path)
  let hash = Git.run(["rev-parse", "HEAD"], in: repo.path)!

  let spool = try CaptureSpool(at: tempURL("spool"))
  let db = try openCanonicalDatabase(at: tempURL("canon"))
  try spool.append(kind: CaptureKind.gitCommit,
                   payload: try encodeJSON(GitCommitPayload(repoPath: repo.path, hash: hash, branch: "feature-x")))
  _ = try Ingester(spool: spool, db: db).drain()

  let ev = try db.read { db in try Event.all.fetchAll(db) }.first { $0.kind == CaptureKind.gitCommit }
  #expect(ev?.branchKey == "feature-x")
}

@Test func defaultBranchCommitHasNilBranchKey() throws {
  let (repo, hash) = try makeCommittedRepo()   // commit is on "main"
  let spool = try CaptureSpool(at: tempURL("spool"))
  let db = try openCanonicalDatabase(at: tempURL("canon"))
  try spool.append(kind: CaptureKind.gitCommit,
                   payload: try encodeJSON(GitCommitPayload(repoPath: repo.path, hash: hash, branch: "main")))
  _ = try Ingester(spool: spool, db: db).drain()
  let ev = try db.read { db in try Event.all.fetchAll(db) }.first
  #expect(ev?.branchKey == nil)
}
```

Run: `./scripts/test.sh --filter BranchKey` → PASS. Then run the full suite (`./scripts/test.sh`) to confirm the common-dir switch didn't regress `sessionFromSubdirectoryAttributesToRepoRoot` or the dedup tests.

- [ ] **Step 7: Commit**

```bash
git add -A
git commit -m "feat: common-dir source keying + Event.branchKey for commits (v5)"
```

---

## Task 3: `SessionStart` hook + `cc.session.start` capture + `SessionBranch`, migration `v6-session-branches`

Capture the branch a Claude Code session launches on, persist it canonically, and tag session events with `branchKey` so sessions attribute as precisely as commits.

> **Do this first:** re-confirm against current Claude Code docs (`code.claude.com/docs/en/hooks.md`) that the `SessionStart` event with `matcher: "startup"` fires once at launch and its stdin JSON carries `session_id`, `cwd`, `transcript_path`. The whole session-attribution path rests on this. If the event name/matcher differs, adjust the installer + capture command accordingly before writing tests.

**Files:**
- Create: `Sources/PensieveKit/Model/SessionBranch.swift`
- Modify: `Sources/PensieveKit/Store/CanonicalStore.swift` (migration `v6-session-branches`)
- Modify: `Sources/PensieveKit/Capture/CapturePayloads.swift` (`ccSessionStart` kind + `SessionStartPayload`)
- Create: `Sources/PensieveKit/Capture/SettingsHookInstaller.swift`
- Create: `Sources/pensieve/Commands/CaptureSessionStart.swift`, `Sources/pensieve/Commands/InstallSessionHook.swift`
- Modify: `Sources/pensieve/Pensieve.swift` (register both subcommands)
- Modify: `Sources/PensieveKit/Ingest/Ingester.swift` (drain `cc.session.start`; session content event gets `branchKey`)
- Create: `Tests/PensieveKitTests/SessionBranchTests.swift`, `Tests/PensieveKitTests/SettingsHookInstallerTests.swift`

**Interfaces:**
- Consumes: `Git.commonDir`, `Git.defaultBranch`, `Git.strandBranchKey` (Task 2); `Event.branchKey` (Task 2).
- Produces: `SessionBranch` model (table `sessionBranches`); `CaptureKind.ccSessionStart`; `SessionStartPayload`.
- Produces: `SettingsHookInstaller.install(settingsURL:pensievePath:) -> Bool`.

- [ ] **Step 1: Add the `SessionBranch` model + migration `v6-session-branches`**

Create `Sources/PensieveKit/Model/SessionBranch.swift`:

```swift
import Foundation
import SQLiteData

@Table
public struct SessionBranch: Identifiable, Equatable, Sendable {
  public let id: UUID
  public var sessionID: String
  public var branch: String?      // raw abbrev-ref at launch; nil = non-git / no branch
  public var commonDir: String    // repo identity (git common-dir), "" for non-git
  public var createdAt: Date
  public init(id: UUID = UUID(), sessionID: String, branch: String?, commonDir: String, createdAt: Date = Date()) {
    self.id = id; self.sessionID = sessionID; self.branch = branch
    self.commonDir = commonDir; self.createdAt = createdAt
  }
}
```

In `CanonicalStore.swift`, register after `v5-event-branchkey`:

```swift
  migrator.registerMigration("v6-session-branches") { db in
    try #sql("""
      CREATE TABLE "sessionBranches"(
        "id" TEXT NOT NULL PRIMARY KEY,
        "sessionID" TEXT NOT NULL,
        "branch" TEXT,
        "commonDir" TEXT NOT NULL,
        "createdAt" TEXT NOT NULL
      ) STRICT
      """).execute(db)
    try #sql(#"CREATE UNIQUE INDEX "idx_sessionbranches_sessionid" ON "sessionBranches"("sessionID")"#).execute(db)
  }
```

- [ ] **Step 2: Add the capture kind + payload**

In `CapturePayloads.swift`, add to `enum CaptureKind`:

```swift
  public static let ccSessionStart = "cc.session.start"
```

And a payload struct:

```swift
public struct SessionStartPayload: Codable, Sendable {
  public var sessionID: String; public var cwd: String
  public var branch: String; public var commonDir: String; public var transcriptPath: String
  public init(sessionID: String, cwd: String, branch: String, commonDir: String, transcriptPath: String) {
    self.sessionID = sessionID; self.cwd = cwd; self.branch = branch
    self.commonDir = commonDir; self.transcriptPath = transcriptPath
  }
}
```

- [ ] **Step 3: Write the settings-installer tests (fail first)**

Create `Tests/PensieveKitTests/SettingsHookInstallerTests.swift`:

```swift
import Foundation
import Testing
@testable import PensieveKit

private func readJSON(_ url: URL) throws -> [String: Any] {
  try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
}

@Test func installsSessionStartHookIntoMissingFile() throws {
  let url = tempURL("settings", ext: "json")
  let added = try SettingsHookInstaller.install(settingsURL: url, pensievePath: "/opt/pensieve")
  #expect(added)
  let root = try readJSON(url)
  let groups = ((root["hooks"] as? [String: Any])?["SessionStart"]) as? [[String: Any]]
  #expect(groups?.count == 1)
  #expect(groups?.first?["matcher"] as? String == "startup")
  let cmd = ((groups?.first?["hooks"] as? [[String: Any]])?.first?["command"]) as? String
  #expect(cmd == "/opt/pensieve capture-session-start")
}

@Test func installIsIdempotent() throws {
  let url = tempURL("settings", ext: "json")
  _ = try SettingsHookInstaller.install(settingsURL: url, pensievePath: "/opt/pensieve")
  let addedAgain = try SettingsHookInstaller.install(settingsURL: url, pensievePath: "/opt/pensieve")
  #expect(!addedAgain)
  let groups = ((try readJSON(url)["hooks"] as? [String: Any])?["SessionStart"]) as? [[String: Any]]
  #expect(groups?.count == 1)   // not duplicated
}

@Test func installPreservesForeignContent() throws {
  let url = tempURL("settings", ext: "json")
  let seed: [String: Any] = [
    "model": "opus",
    "hooks": ["SessionStart": [["matcher": "startup",
      "hooks": [["type": "command", "command": "/other/tool run"]]]]],
  ]
  try JSONSerialization.data(withJSONObject: seed).write(to: url)
  _ = try SettingsHookInstaller.install(settingsURL: url, pensievePath: "/opt/pensieve")
  let root = try readJSON(url)
  #expect(root["model"] as? String == "opus")                  // foreign top-level key kept
  let groups = ((root["hooks"] as? [String: Any])?["SessionStart"]) as? [[String: Any]]
  #expect(groups?.count == 2)                                  // foreign entry kept, ours appended
  let commands = groups?.flatMap { ($0["hooks"] as? [[String: Any]]) ?? [] }
    .compactMap { $0["command"] as? String }
  #expect(commands?.contains("/other/tool run") == true)
  #expect(commands?.contains("/opt/pensieve capture-session-start") == true)
}
```

Run: `./scripts/test.sh --filter Hook` → FAIL (`SettingsHookInstaller` not defined).

- [ ] **Step 4: Implement `SettingsHookInstaller`**

Create `Sources/PensieveKit/Capture/SettingsHookInstaller.swift`:

```swift
import Foundation

/// Idempotent JSON merge of the Claude Code `SessionStart` hook into a settings.json.
/// Preserves all existing content and never modifies foreign hook entries.
public enum SettingsHookInstaller {
  static let command = "capture-session-start"

  /// Returns true if an entry was added, false if ours was already present.
  @discardableResult
  public static func install(settingsURL: URL, pensievePath: String) throws -> Bool {
    var root: [String: Any] = [:]
    if let data = try? Data(contentsOf: settingsURL),
       let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
      root = obj
    }
    var hooks = root["hooks"] as? [String: Any] ?? [:]
    var sessionStart = hooks["SessionStart"] as? [[String: Any]] ?? []

    let present = sessionStart.contains { group in
      ((group["hooks"] as? [[String: Any]]) ?? []).contains {
        ($0["command"] as? String)?.contains(command) == true
      }
    }
    if present { return false }

    sessionStart.append([
      "matcher": "startup",
      "hooks": [["type": "command", "command": "\(pensievePath) \(command)"]],
    ])
    hooks["SessionStart"] = sessionStart
    root["hooks"] = hooks

    try PensievePaths.ensureParentDirectory(of: settingsURL)
    let out = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
    try out.write(to: settingsURL, options: .atomic)
    return true
  }
}
```

Run: `./scripts/test.sh --filter Hook` → PASS.

- [ ] **Step 5: Add the capture + install CLI commands**

Create `Sources/pensieve/Commands/CaptureSessionStart.swift`:

```swift
import ArgumentParser
import Foundation
import PensieveKit

struct CaptureSessionStart: ParsableCommand {
  static let configuration = CommandConfiguration(commandName: "capture-session-start",
    abstract: "Record the branch a Claude Code session launched on (reads hook JSON from stdin).")

  private struct HookInput: Decodable { let session_id: String; let cwd: String; let transcript_path: String? }

  func run() throws {
    let data = FileHandle.standardInput.readDataToEndOfFile()
    guard let h = try? JSONDecoder().decode(HookInput.self, from: data) else { return }  // dumb: never fail a session
    let branch = Git.run(["rev-parse", "--abbrev-ref", "HEAD"], in: h.cwd) ?? ""
    let commonDir = Git.commonDir(in: h.cwd) ?? ""
    let payload = SessionStartPayload(sessionID: h.session_id, cwd: h.cwd,
      branch: branch, commonDir: commonDir, transcriptPath: h.transcript_path ?? "")
    try? openSpool().append(kind: CaptureKind.ccSessionStart, payload: try encodeJSON(payload))
  }
}
```

Create `Sources/pensieve/Commands/InstallSessionHook.swift`:

```swift
import ArgumentParser
import Foundation
import PensieveKit

struct InstallSessionHook: ParsableCommand {
  static let configuration = CommandConfiguration(commandName: "install-session-hook",
    abstract: "Install the Claude Code SessionStart hook into ~/.claude/settings.json.")
  func run() throws {
    let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/settings.json")
    let pensievePath = Bundle.main.executablePath ?? "pensieve"
    let added = try SettingsHookInstaller.install(settingsURL: url, pensievePath: pensievePath)
    print(added ? "installed SessionStart hook in \(url.path)"
                : "SessionStart hook already present in \(url.path)")
  }
}
```

In `Pensieve.swift`, add `CaptureSessionStart.self, InstallSessionHook.self,` to the `subcommands` array.

- [ ] **Step 6: Drain `cc.session.start` into `SessionBranch`; tag session events with branchKey (fail first)**

Add to a new `Tests/PensieveKitTests/SessionBranchTests.swift`:

```swift
import Foundation
import Testing
import SQLiteData
@testable import PensieveKit

@Test func drainPersistsSessionBranch() throws {
  let spool = try CaptureSpool(at: tempURL("spool"))
  let db = try openCanonicalDatabase(at: tempURL("canon"))
  let payload = SessionStartPayload(sessionID: "S1", cwd: "/p/app",
    branch: "feature-x", commonDir: "/p/app/.git", transcriptPath: "/t.jsonl")
  try spool.append(kind: CaptureKind.ccSessionStart, payload: try encodeJSON(payload))

  let n = try Ingester(spool: spool, db: db).drain()
  #expect(n == 0)                                    // metadata, not an event
  let sb = try db.read { db in try SessionBranch.all.fetchAll(db) }.first
  #expect(sb?.sessionID == "S1")
  #expect(sb?.branch == "feature-x")
  #expect(try spool.pending().isEmpty)               // marked ingested
}
```

Then add the drain case to `Ingester.swift`'s `switch`, before `default`:

```swift
    case CaptureKind.ccSessionStart:
      let p = try JSONDecoder().decode(SessionStartPayload.self, from: data)
      try db.write { db in
        let exists = try SessionBranch.where { $0.sessionID.eq(p.sessionID) }.fetchOne(db) != nil
        if !exists {
          try SessionBranch.insert {
            SessionBranch(sessionID: p.sessionID,
                          branch: p.branch.isEmpty ? nil : p.branch,
                          commonDir: p.commonDir)
          }.execute(db)
        }
      }
      return 0
```

In the `CaptureKind.ccSession` case, compute `branchKey` from the persisted `SessionBranch` inside the write, and pass it to the `Event`:

```swift
      let inserted = try db.write { db -> Bool in
        let (project, source) = try resolver.resolve(db, path: key, kind: SourceKind.claudeCode)
        let branchKey: String? = {
          guard let sb = try? SessionBranch.where({ $0.sessionID.eq(session.sessionID) }).fetchOne(db),
                let raw = sb.branch else { return nil }
          return Git.strandBranchKey(branch: raw, defaultBranch: Git.defaultBranch(in: sb.commonDir))
        }()
        return try insertIfNew(db, Event(nodeID: project.id, sourceID: source.id,
              occurredAt: session.endedAt ?? row.ts, kind: CaptureKind.ccSession,
              summary: "session (\(session.userPromptCount) prompts)", detailJSON: detail,
              fingerprint: Fingerprint.session(sessionID: session.sessionID), branchKey: branchKey))
      }
```

Run: `./scripts/test.sh --filter SessionBranch` → PASS.

- [ ] **Step 7: Full suite + commit**

Run: `./scripts/test.sh` → all green.

```bash
git add -A
git commit -m "feat: SessionStart hook, cc.session.start capture, SessionBranch (v6)"
```

---

## Task 4: Strand birth — materialize, repoint, LLM naming

Consume `Event.branchKey` (commits + sessions) to auto-birth strand nodes conservatively and name them with the on-device model.

**Files:**
- Modify: `Sources/PensieveKit/Ingest/Ingester.swift` (add `llm` param; `drain`/`ingest` become `async`; add `attributeToNode` + `nameStrand`; both git-commit and session handlers route through attribution)
- Modify: `Sources/pensieve/Commands/Ingest.swift` (pass provider; already async)
- Modify: `Tests/PensieveKitTests/IngesterTests.swift`, `IngesterDedupTests.swift` (await `drain()`)
- Create: `Tests/PensieveKitTests/StrandBirthTests.swift`

**Interfaces:**
- Consumes: `Node` (parentID/kind/branchKey), `Event.branchKey`, `SessionBranch`, `LLMProvider.complete`.
- Produces: `Ingester.init(spool:db:llm:)` with `llm: (any LLMProvider)? = nil`; `func drain() async throws -> Int`.

- [ ] **Step 1: Make `drain`/`ingest` async and add the `llm` seam (mechanical, keep green)**

In `Ingester.swift`:
- Add stored property `let llm: (any LLMProvider)?` and update `init` to `public init(spool: CaptureSpool, db: any DatabaseWriter, llm: (any LLMProvider)? = nil) { self.spool = spool; self.db = db; self.resolver = ProjectResolver(db: db); self.llm = llm }`.
- Change `public func drain() throws -> Int` to `public func drain() async throws -> Int`, and inside the loop `let n = try await ingest(row)`.
- Change `private func ingest(_ row: SpoolRow) throws -> Int` to `private func ingest(_ row: SpoolRow) async throws -> Int`.

In `Sources/pensieve/Commands/Ingest.swift`, change the drain line to:

```swift
    let provider = makeDefaultLLMProvider()
    let created = try await Ingester(spool: try openSpool(), db: db, llm: provider).drain()
```

Update every `.drain()` call site in tests to `try await …drain()` (in `IngesterTests.swift` and `IngesterDedupTests.swift`). The enclosing `@Test func`s that now `await` must be `async` — add `async` to their signatures.

Run: `./scripts/test.sh` → all green (behavior unchanged so far).

- [ ] **Step 2: Write the strand-birth tests (fail first)**

Create `Tests/PensieveKitTests/StrandBirthTests.swift`:

```swift
import Foundation
import Testing
import SQLiteData
@testable import PensieveKit

/// Minimal LLM stub: `complete` returns a fixed string; structured methods inherit protocol defaults.
private struct StubLLM: LLMProvider {
  let text: String
  func complete(prompt: String) async throws -> String { text }
}
private struct FailingLLM: LLMProvider {
  func complete(prompt: String) async throws -> String { throw LLMError.providerFailed("nope") }
}

/// Appends N commits on `branch` to `repo` and spools them; returns nothing.
private func spoolCommits(_ n: Int, on branch: String, repo: URL, spool: CaptureSpool) throws {
  _ = Git.run(["checkout", "-B", branch], in: repo.path)
  for i in 0..<n {
    try "\(branch)-\(i)".write(to: repo.appendingPathComponent("f\(branch)\(i).txt"), atomically: true, encoding: .utf8)
    _ = Git.run(["add", "-A"], in: repo.path)
    _ = Git.run(["commit", "-m", "\(branch) commit \(i)"], in: repo.path)
    let hash = Git.run(["rev-parse", "HEAD"], in: repo.path)!
    try spool.append(kind: CaptureKind.gitCommit,
                     payload: try encodeJSON(GitCommitPayload(repoPath: repo.path, hash: hash, branch: branch)))
  }
}

@Test func twoCommitsOnBranchBirthAStrand() async throws {
  let (repo, _) = try makeCommittedRepo()   // default "main"
  let spool = try CaptureSpool(at: tempURL("spool"))
  let db = try openCanonicalDatabase(at: tempURL("canon"))
  try spoolCommits(2, on: "feature-x", repo: repo, spool: spool)

  _ = try await Ingester(spool: spool, db: db).drain()

  let strands = try db.read { db in try Node.where { $0.kind.eq("strand") }.fetchAll(db) }
  #expect(strands.count == 1)
  #expect(strands.first?.branchKey == "feature-x")
  // Both commits on the branch are repointed to the strand.
  let evs = try db.read { db in try Event.where { $0.nodeID.eq(strands.first!.id) }.fetchAll(db) }
  #expect(evs.count == 2)
}

@Test func oneCommitStaysTaggedNoStrand() async throws {
  let (repo, _) = try makeCommittedRepo()
  let spool = try CaptureSpool(at: tempURL("spool"))
  let db = try openCanonicalDatabase(at: tempURL("canon"))
  try spoolCommits(1, on: "feature-y", repo: repo, spool: spool)

  _ = try await Ingester(spool: spool, db: db).drain()

  let strands = try db.read { db in try Node.where { $0.kind.eq("strand") }.fetchAll(db) }
  #expect(strands.isEmpty)                              // tagged, not materialized
  let ev = try db.read { db in try Event.all.fetchAll(db) }.first { $0.kind == CaptureKind.gitCommit }
  #expect(ev?.branchKey == "feature-y")                // branch is still recorded on the event
}

@Test func materializedStrandGetsLLMName() async throws {
  let (repo, _) = try makeCommittedRepo()
  let spool = try CaptureSpool(at: tempURL("spool"))
  let db = try openCanonicalDatabase(at: tempURL("canon"))
  try spoolCommits(2, on: "auth", repo: repo, spool: spool)

  _ = try await Ingester(spool: spool, db: db, llm: StubLLM(text: "Auth refactor\nReworking the login flow.")).drain()

  let strand = try db.read { db in try Node.where { $0.kind.eq("strand") }.fetchAll(db) }.first
  #expect(strand?.name == "Auth refactor")
  #expect(strand?.description == "Reworking the login flow.")
}

@Test func strandNamingFailureLeavesBranchName() async throws {
  let (repo, _) = try makeCommittedRepo()
  let spool = try CaptureSpool(at: tempURL("spool"))
  let db = try openCanonicalDatabase(at: tempURL("canon"))
  try spoolCommits(2, on: "billing", repo: repo, spool: spool)

  _ = try await Ingester(spool: spool, db: db, llm: FailingLLM()).drain()

  let strand = try db.read { db in try Node.where { $0.kind.eq("strand") }.fetchAll(db) }.first
  #expect(strand?.name == "billing")                   // falls back to branch name
  #expect(strand?.description == "")
}
```

Run: `./scripts/test.sh --filter Strand` → FAIL (no strand created yet).

- [ ] **Step 3: Implement `attributeToNode` (materialize + repoint) and route commits through it**

Add to `Ingester.swift`:

```swift
  /// Decides the node an event belongs to, materializing a strand when a branch crosses the
  /// ≥2-same-kind-events threshold. Runs inside the write transaction. Returns the nodeID to
  /// stamp on the event, plus the id of a strand *born on this call* (for post-transaction
  /// naming) or nil.
  private func attributeToNode(_ db: Database, projectNodeID: UUID,
                               branchKey: String?, kind: String)
    throws -> (nodeID: UUID, bornStrand: UUID?) {
    guard let branchKey else { return (projectNodeID, nil) }

    if let strand = try Node
      .where({ $0.parentID.eq(projectNodeID) && $0.branchKey.eq(branchKey) && $0.kind.eq("strand") })
      .fetchOne(db) {
      return (strand.id, nil)                          // strand already exists → attribute directly
    }

    // Count same-kind events already tagged with this branch at the project node.
    let sameKind = try Event
      .where { $0.nodeID.eq(projectNodeID) && $0.branchKey.eq(branchKey) && $0.kind.eq(kind) }
      .fetchAll(db).count
    guard sameKind + 1 >= 2 else { return (projectNodeID, nil) }   // not yet — stay tagged

    let strand = Node(name: branchKey, parentID: projectNodeID, kind: "strand", branchKey: branchKey)
    try Node.insert { strand }.execute(db)
    try Event.where { $0.nodeID.eq(projectNodeID) && $0.branchKey.eq(branchKey) }
      .update { $0.nodeID = strand.id }.execute(db)   // repoint every tagged event (all kinds)
    return (strand.id, strand.id)
  }
```

Rewrite the `CaptureKind.gitCommit` case to route through attribution and name any newborn strand after the transaction:

```swift
    case CaptureKind.gitCommit:
      let p = try JSONDecoder().decode(GitCommitPayload.self, from: data)
      let key = Git.commonDir(in: p.repoPath) ?? ProjectResolver.canonical(p.repoPath)
      let branchKey = Git.strandBranchKey(branch: p.branch, defaultBranch: Git.defaultBranch(in: p.repoPath))
      let fields = gitCommitFields(hash: p.hash, repo: p.repoPath, fallbackTime: row.ts)
      let detail = try encodeJSON(["hash": p.hash, "branch": p.branch, "files": fields.files])
      let outcome = try db.write { db -> (inserted: Bool, born: UUID?) in
        let (project, source) = try resolver.resolve(db, path: key, kind: SourceKind.gitRepo)
        let dup = try Event.where { $0.sourceID.eq(source.id) && $0.fingerprint.eq(Fingerprint.commit(hash: p.hash)) }
          .fetchOne(db) != nil
        if dup { return (false, nil) }
        let attr = try attributeToNode(db, projectNodeID: project.id, branchKey: branchKey, kind: CaptureKind.gitCommit)
        try Event.insert {
          Event(nodeID: attr.nodeID, sourceID: source.id, occurredAt: fields.when,
                kind: CaptureKind.gitCommit, summary: fields.subject, detailJSON: detail,
                fingerprint: Fingerprint.commit(hash: p.hash), branchKey: branchKey)
        }.execute(db)
        return (true, attr.bornStrand)
      }
      if let born = outcome.born { await nameStrand(born, branchKey: branchKey ?? "") }
      return outcome.inserted ? 1 : 0
```

- [ ] **Step 4: Implement `nameStrand` (best-effort, non-fatal)**

Add to `Ingester.swift`:

```swift
  /// Names/describes a freshly materialized strand from its accumulated activity. Non-fatal:
  /// any failure leaves the branch-name + empty description. Organizational label, not a
  /// surfaced claim — outside the verbatim gate by design.
  private func nameStrand(_ strandID: UUID, branchKey: String) async {
    guard let llm else { return }
    let summaries: [String] = (try? db.read { db in
      try Event.where { $0.nodeID.eq(strandID) }
        .order { $0.occurredAt.desc() }.limit(20).fetchAll(db).map(\.summary)
    }) ?? []
    guard !summaries.isEmpty else { return }
    let prompt = """
    Below is recent activity on a branch of work called "\(branchKey)". In 3-6 words on line 1, \
    give it a human-readable name. On line 2, one sentence describing it. Do not invent facts \
    beyond the activity shown.

    \(summaries.joined(separator: "\n"))
    """
    guard let out = try? await llm.complete(prompt: prompt) else { return }
    let lines = out.split(separator: "\n", omittingEmptySubsequences: true)
      .map { $0.trimmingCharacters(in: .whitespaces) }
    guard let name = lines.first, !name.isEmpty else { return }
    let desc = lines.count > 1 ? lines[1] : ""
    try? db.write { db in
      try Node.where { $0.id.eq(strandID) }.update { $0.name = name; $0.description = desc }.execute(db)
    }
  }
```

Run: `./scripts/test.sh --filter Strand` → the commit-based tests PASS.

- [ ] **Step 5: Route the session content handler through attribution too**

Rewrite the `CaptureKind.ccSession` write block to mirror the commit path (dedup-check → branchKey from `SessionBranch` → `attributeToNode` → insert), then name any newborn strand:

```swift
      let outcome = try db.write { db -> (inserted: Bool, born: UUID?, branch: String?) in
        let (project, source) = try resolver.resolve(db, path: key, kind: SourceKind.claudeCode)
        let dup = try Event.where { $0.sourceID.eq(source.id) && $0.fingerprint.eq(Fingerprint.session(sessionID: session.sessionID)) }
          .fetchOne(db) != nil
        if dup { return (false, nil, nil) }
        let branchKey: String? = {
          guard let sb = try? SessionBranch.where({ $0.sessionID.eq(session.sessionID) }).fetchOne(db),
                let raw = sb.branch else { return nil }
          return Git.strandBranchKey(branch: raw, defaultBranch: Git.defaultBranch(in: sb.commonDir))
        }()
        let attr = try attributeToNode(db, projectNodeID: project.id, branchKey: branchKey, kind: CaptureKind.ccSession)
        try Event.insert {
          Event(nodeID: attr.nodeID, sourceID: source.id, occurredAt: session.endedAt ?? row.ts,
                kind: CaptureKind.ccSession, summary: "session (\(session.userPromptCount) prompts)",
                detailJSON: detail, fingerprint: Fingerprint.session(sessionID: session.sessionID),
                branchKey: branchKey)
        }.execute(db)
        return (true, attr.bornStrand, branchKey)
      }
      if let born = outcome.born { await nameStrand(born, branchKey: outcome.branch ?? "") }
      return outcome.inserted ? 1 : 0
```

Remove the now-unused `insertIfNew` helper if no case still calls it, **or** leave it if the `gitCheckout` case still uses it (checkouts don't get strands — keep them on `insertIfNew` with `nodeID: project.id`). Verify the checkout case still compiles with `Event(nodeID:…)`.

- [ ] **Step 6: Add the two-sessions and mixed-kind tests**

Add to `StrandBirthTests.swift`:

```swift
/// Spools a session-start row + a parsed session transcript on `branch` in `repo`.
private func spoolSession(id: String, on branch: String, repo: URL, spool: CaptureSpool) throws {
  let commonDir = Git.commonDir(in: repo.path) ?? repo.path
  try spool.append(kind: CaptureKind.ccSessionStart, payload: try encodeJSON(
    SessionStartPayload(sessionID: id, cwd: repo.path, branch: branch, commonDir: commonDir, transcriptPath: "")))
  let transcript = tempURL("t-\(id)", ext: "jsonl")
  let line = """
    {"type":"user","cwd":"\(repo.path)","sessionId":"\(id)","timestamp":"2026-06-30T10:00:00Z","message":{"role":"user","content":"hi"}}
    """
  try line.write(to: transcript, atomically: true, encoding: .utf8)
  try spool.append(kind: CaptureKind.ccSession, payload: try encodeJSON(SessionRefPayload(transcriptPath: transcript.path)))
}

@Test func twoSessionsOnBranchBirthAStrand() async throws {
  let (repo, _) = try makeCommittedRepo()
  _ = Git.run(["checkout", "-B", "feature-s"], in: repo.path)
  let spool = try CaptureSpool(at: tempURL("spool"))
  let db = try openCanonicalDatabase(at: tempURL("canon"))
  try spoolSession(id: "S1", on: "feature-s", repo: repo, spool: spool)
  try spoolSession(id: "S2", on: "feature-s", repo: repo, spool: spool)

  _ = try await Ingester(spool: spool, db: db).drain()

  let strands = try db.read { db in try Node.where { $0.kind.eq("strand") }.fetchAll(db) }
  #expect(strands.count == 1)
  #expect(strands.first?.branchKey == "feature-s")
}

@Test func oneCommitPlusOneSessionDoesNotBirthStrand() async throws {
  let (repo, _) = try makeCommittedRepo()
  let spool = try CaptureSpool(at: tempURL("spool"))
  let db = try openCanonicalDatabase(at: tempURL("canon"))
  try spoolCommits(1, on: "mixed", repo: repo, spool: spool)   // leaves repo on branch "mixed"
  try spoolSession(id: "S9", on: "mixed", repo: repo, spool: spool)

  _ = try await Ingester(spool: spool, db: db).drain()

  let strands = try db.read { db in try Node.where { $0.kind.eq("strand") }.fetchAll(db) }
  #expect(strands.isEmpty)                                     // threshold is 2 of the SAME kind
}
```

Run: `./scripts/test.sh --filter Strand` → PASS. Then full suite `./scripts/test.sh` → green.

- [ ] **Step 7: Commit**

```bash
git add -A
git commit -m "feat: conservative strand birth (tag-then-materialize) + on-device naming"
```

---

## Task 5: `group()` re-parents children

When merging node `B` into `A`, B's child nodes must float to `A`, not be orphaned.

**Files:**
- Modify: `Sources/PensieveKit/Ingest/ProjectResolver.swift` (one line in `group`)
- Modify: `Tests/PensieveKitTests/ProjectResolverTests.swift` (extend `groupPreservesLooseEndsAndCheckpoints`)

**Interfaces:**
- Consumes: `Node.parentID` (Task 1); existing `ProjectResolver.group(_:into:)`.

- [ ] **Step 1: Extend the group test to assert child re-parenting (fail first)**

In `ProjectResolverTests.swift`, inside `groupPreservesLooseEndsAndCheckpoints`, after creating the checkpoint under `b` and before the `group(...)` call, add a child node under B; after the group call, assert it now points at A. Add these blocks:

```swift
  // A child node under B must re-parent to A on merge, not orphan.
  let child = Node(name: "b-strand", parentID: b.project.id, kind: "strand", branchKey: "feature")
  try db.write { db in try Node.insert { child }.execute(db) }
```

…and after `try ProjectResolver(db: db).group(a.project.id, into: [b.project.id])`:

```swift
  let reparented = try db.read { db in try Node.where { $0.id.eq(child.id) }.fetchOne(db) }
  #expect(reparented?.parentID == a.project.id)
```

Run: `./scripts/test.sh --filter groupPreserves` → FAIL (child still points at deleted B, i.e. NULL via ON DELETE SET NULL).

- [ ] **Step 2: Re-parent children in `group`**

In `ProjectResolver.group`, inside the `for other in merged` loop, before `try Project.where { $0.id.eq(other) }.delete()…` (now `Node.where…`), add:

```swift
        try Node.where { $0.parentID.eq(other) }
          .update { $0.parentID = primaryID }.execute(db)
```

Run: `./scripts/test.sh --filter groupPreserves` → PASS. Full suite green.

- [ ] **Step 3: Commit**

```bash
git add -A
git commit -m "feat: group() re-parents child nodes on merge"
```

---

## Task 6: Organizing CLI — `add-node`, `nest`, `rename`, `retype`, tree-aware `list`

Surface the tree: create arbitrary nodes, move/rename/retype them, and render the tree.

**Files:**
- Create: `Sources/PensieveKit/Query/NodeCommands.swift`
- Create: `Sources/pensieve/Commands/{AddNode,Nest,RenameNode,RetypeNode}.swift`
- Modify: `Sources/pensieve/Commands/ListProjects.swift` (render the tree)
- Modify: `Sources/pensieve/Pensieve.swift` (register the four new subcommands)
- Create: `Tests/PensieveKitTests/NodeCommandsTests.swift`

**Interfaces:**
- Consumes: `Node`, `ProjectQueries.all` (Task 1).
- Produces: `NodeCommands.{find,add,nest,rename,retype}`; `NodeTree.render([Node]) -> [String]`.

- [ ] **Step 1: Write the NodeCommands + tree-render tests (fail first)**

Create `Tests/PensieveKitTests/NodeCommandsTests.swift`:

```swift
import Foundation
import Testing
import SQLiteData
@testable import PensieveKit

@Test func addNestRenameRetype() throws {
  let db = try openCanonicalDatabase(at: tempURL("nodecmd"))
  let domain = try NodeCommands.add(db, name: "Work", kind: "domain", parent: nil, description: "")
  #expect(domain != nil)
  let proj = try NodeCommands.add(db, name: "colibri", kind: "project", parent: "Work", description: "hummingbird")
  #expect(proj?.parentID == domain?.id)

  #expect(try NodeCommands.nest(db, child: "colibri", under: "Work"))
  #expect(try NodeCommands.rename(db, node: "colibri", to: "Colibri"))
  #expect(try NodeCommands.retype(db, node: "Colibri", to: "initiative"))

  let renamed = try db.read { db in try Node.where { $0.name.eq("Colibri") }.fetchOne(db) }
  #expect(renamed?.kind == "initiative")
  #expect(renamed?.description == "hummingbird")
}

@Test func rendersIndentedTree() throws {
  let root = Node(name: "Work", kind: "domain")
  let child = Node(name: "Colibri", parentID: root.id, kind: "project")
  let strand = Node(name: "auth", parentID: child.id, kind: "strand", branchKey: "auth")
  let lines = NodeTree.render([strand, root, child])   // order-independent
  #expect(lines == [
    "Work (domain)  [active]",
    "  Colibri  [active]",
    "    auth (strand)  [active]",
  ])
}
```

Run: `./scripts/test.sh --filter Node` → FAIL (`NodeCommands` not defined).

- [ ] **Step 2: Implement `NodeCommands` + `NodeTree`**

Create `Sources/PensieveKit/Query/NodeCommands.swift`:

```swift
import Foundation
import SQLiteData
import GRDB

public enum NodeCommands {
  /// Find a node by UUID string (preferred) or exact name.
  public static func find(_ db: Database, nameOrID: String) throws -> Node? {
    if let uuid = UUID(uuidString: nameOrID),
       let byID = try Node.where({ $0.id.eq(uuid) }).fetchOne(db) { return byID }
    return try Node.where { $0.name.eq(nameOrID) }.fetchOne(db)
  }

  @discardableResult
  public static func add(_ db: any DatabaseWriter, name: String, kind: String,
                         parent: String?, description: String) throws -> Node? {
    try db.write { db in
      var parentID: UUID? = nil
      if let parent {
        guard let p = try find(db, nameOrID: parent) else { return nil }
        parentID = p.id
      }
      let node = Node(name: name, parentID: parentID, kind: kind, description: description)
      try Node.insert { node }.execute(db)
      return node
    }
  }

  public static func nest(_ db: any DatabaseWriter, child: String, under parent: String) throws -> Bool {
    try db.write { db in
      guard let c = try find(db, nameOrID: child), let p = try find(db, nameOrID: parent) else { return false }
      try Node.where { $0.id.eq(c.id) }.update { $0.parentID = p.id }.execute(db)
      return true
    }
  }

  public static func rename(_ db: any DatabaseWriter, node: String, to newName: String) throws -> Bool {
    try db.write { db in
      guard let n = try find(db, nameOrID: node) else { return false }
      try Node.where { $0.id.eq(n.id) }.update { $0.name = newName }.execute(db)
      return true
    }
  }

  public static func retype(_ db: any DatabaseWriter, node: String, to newKind: String) throws -> Bool {
    try db.write { db in
      guard let n = try find(db, nameOrID: node) else { return false }
      try Node.where { $0.id.eq(n.id) }.update { $0.kind = newKind }.execute(db)
      return true
    }
  }
}

public enum NodeTree {
  /// Render nodes as an indented tree (roots first, children under parents, siblings by name).
  public static func render(_ nodes: [Node]) -> [String] {
    let byParent = Dictionary(grouping: nodes, by: { $0.parentID })
    var lines: [String] = []
    func walk(_ parent: UUID?, depth: Int) {
      for n in (byParent[parent] ?? []).sorted(by: { $0.name < $1.name }) {
        let indent = String(repeating: "  ", count: depth)
        let kindTag = n.kind == "project" ? "" : " (\(n.kind))"
        lines.append("\(indent)\(n.name)\(kindTag)  [\(n.state)]")
        walk(n.id, depth: depth + 1)
      }
    }
    walk(nil, depth: 0)
    return lines
  }
}
```

Run: `./scripts/test.sh --filter Node` → PASS.

- [ ] **Step 3: Add the CLI commands**

Create `Sources/pensieve/Commands/AddNode.swift`:

```swift
import ArgumentParser
import PensieveKit

struct AddNode: ParsableCommand {
  static let configuration = CommandConfiguration(commandName: "add-node",
    abstract: "Create a node (domain, concept, initiative, …).")
  @Argument var name: String
  @Option var kind: String = "concept"
  @Option var parent: String?
  @Option var description: String = ""
  func run() throws {
    let created = try NodeCommands.add(try openCanonical(), name: name, kind: kind,
                                       parent: parent, description: description)
    print(created != nil ? "added \(kind) '\(name)'" : "unknown parent '\(parent ?? "")'")
  }
}
```

Create `Sources/pensieve/Commands/Nest.swift`:

```swift
import ArgumentParser
import PensieveKit

struct Nest: ParsableCommand {
  static let configuration = CommandConfiguration(commandName: "nest",
    abstract: "Move a node under a new parent.")
  @Argument var child: String
  @Option(name: .long) var under: String
  func run() throws {
    let ok = try NodeCommands.nest(try openCanonical(), child: child, under: under)
    print(ok ? "nested \(child) under \(under)" : "unknown node name(s)")
  }
}
```

Create `Sources/pensieve/Commands/RenameNode.swift`:

```swift
import ArgumentParser
import PensieveKit

struct RenameNode: ParsableCommand {
  static let configuration = CommandConfiguration(commandName: "rename",
    abstract: "Rename a node.")
  @Argument var node: String
  @Argument var newName: String
  func run() throws {
    let ok = try NodeCommands.rename(try openCanonical(), node: node, to: newName)
    print(ok ? "renamed to \(newName)" : "unknown node '\(node)'")
  }
}
```

Create `Sources/pensieve/Commands/RetypeNode.swift`:

```swift
import ArgumentParser
import PensieveKit

struct RetypeNode: ParsableCommand {
  static let configuration = CommandConfiguration(commandName: "retype",
    abstract: "Change a node's kind.")
  @Argument var node: String
  @Argument var newKind: String
  func run() throws {
    let ok = try NodeCommands.retype(try openCanonical(), node: node, to: newKind)
    print(ok ? "retyped \(node) → \(newKind)" : "unknown node '\(node)'")
  }
}
```

- [ ] **Step 4: Render the tree in `list`**

Replace the body of `Sources/pensieve/Commands/ListProjects.swift`:

```swift
import ArgumentParser
import PensieveKit

struct ListProjects: ParsableCommand {
  static let configuration = CommandConfiguration(commandName: "list",
    abstract: "List the node tree (strands nested under their projects).")
  func run() throws {
    let nodes = try ProjectQueries.all(try openCanonical())
    for line in NodeTree.render(nodes) { print(line) }
  }
}
```

- [ ] **Step 5: Register the new subcommands**

In `Pensieve.swift`, add `AddNode.self, Nest.self, RenameNode.self, RetypeNode.self,` to the `subcommands` array.

- [ ] **Step 6: Build the CLI + full suite**

Run: `swift build` (confirm the CLI compiles), then `./scripts/test.sh` → all green.
Smoke-check manually:

```bash
PENSIEVE_DB=$(mktemp -u).sqlite swift run pensieve add-node Work --kind domain
```
Expected: `added domain 'Work'`.

- [ ] **Step 7: Commit**

```bash
git add -A
git commit -m "feat: organizing CLI (add-node/nest/rename/retype) + tree-aware list"
```

---

## Task 7: Update `CLAUDE.md` status + carried-findings fold-ins (opportunistic)

**Files:**
- Modify: `CLAUDE.md` (Status section), `docs/superpowers/backlog.md` (mark 1B-org items done)

- [ ] **Step 1: Fold in carried 1B findings only where this phase already touched the code**

Non-blocking, opportunistic (spec §11). Where a task above already edited the file, optionally apply: `CheckpointCommand` bare-name collision (only if it caused friction), `SummaryBuilder events.prefix(15)` redundancy. Skip anything not already touched — do not widen the diff. If none were touched cleanly, skip this step.

- [ ] **Step 2: Update status docs**

In `CLAUDE.md`, update the Status section: mark **Phase 1B-org — DONE** with the test count from `./scripts/test.sh`, and note the typed tree + strand birth shipped. In `backlog.md`, strike the 1B-org items now implemented (keep the deferred §9 items).

- [ ] **Step 3: Full suite + commit**

Run: `./scripts/test.sh` → green.

```bash
git add -A
git commit -m "docs: mark Phase 1B-org done (typed tree & strands)"
```

---

## Self-Review (completed against the spec)

**Spec coverage:**
- §2 strand-on-event: `Event.branchKey` + `Event.nodeID` — Task 2 (commits), Task 3 (sessions), Task 4 (attribution). ✅
- §3.1 `Node` model + columns: Task 1. ✅ §3.2 FK rename: Task 1. ✅ §3.3 `Event.branchKey`: Task 2. ✅ §3.4 common-dir source identity: Task 2. ✅
- §4.2 `SessionStart` hook + `cc.session.start` + global idempotent installer: Task 3. ✅ §4.3 common-dir / default-branch / detached-HEAD resolution: Task 2 (`Git.commonDir`/`defaultBranch`/`strandBranchKey`). ✅
- §5 ingest + strand birth (find-or-create, repoint, threshold, LLM naming, non-fatal): Task 4. ✅ §5.1 trust boundary (gate untouched): honored — no Intelligence logic changed. ✅
- §6 `group()` re-parent + extended test: Task 5. ✅
- §7 organizing CLI + tree `list`: Task 6. ✅
- §8 additive migration (v3→…): Tasks 1–3 (v4/v5/v6, see Deviation 1). ✅
- §10 testing matrix: strand birth (2 commits / 2 sessions / 1+1), detached & default branch → nil branchKey (proxy for no-strand), worktree unification, repoint-on-birth, group re-parent, migration upgrade, LLM naming + failure, installer idempotency/foreign-preservation — all covered across Tasks 1–6. ✅
- §11 carried findings: Task 7 (opportunistic). ✅

**Detached-HEAD note:** `Git.strandBranchKey` returns nil for `"HEAD"`, so a detached-HEAD commit tags no branch and never mints a `"HEAD"` strand (spec §4.3 / §10). The captured branch for detached HEAD is `"HEAD"` (git `--abbrev-ref` output), which the pure test in Task 2 Step 1 pins directly.

**Placeholder scan:** no TBD/TODO/"handle edge cases"/"similar to Task N" — all steps carry real code or exact commands. ✅

**Type consistency:** `Node` init and `nodeID` field names are identical across Tasks 1–6; `Ingester.init(spool:db:llm:)` and `drain() async` are introduced in Task 4 and used consistently; `attributeToNode`/`nameStrand`/`NodeCommands`/`NodeTree.render` signatures match their call sites. ✅
