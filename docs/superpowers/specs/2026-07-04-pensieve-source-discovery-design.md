# Source Discovery — Watched-Folder Scan (Design)

**Date:** 2026-07-04. **Status:** approved in brainstorming, ready for a plan. **Pass 1 of 2**
(engine + CLI; the settings-window UI is pass 2, its own spec).

## Goal

Let Moritz point Pensieve at a folder (e.g. `~/Projects`) and, in one action, **discover the
sources under it and turn them on** — register each as a node/source and install its capture
setup — instead of running per-repo `install-hooks`/`track` by hand. This is the dogfooding
enabler: broad capture, switched on from a folder.

## Framing: sources, not git

Per the project's core principle ("a Project is an area of work, not a directory; git repos are
one *source type*"), this feature is organized around **sources**, and git is one concrete kind:

- A **Source** (existing persisted record — `nodeID`, `kind`, `key`; unchanged) is something
  Pensieve captures work from.
- A **filesystem-backed source** lives at a filesystem path (a root directory + an identity key
  derived from the filesystem).
- A **git source** is the one concrete filesystem-backed kind implemented now: discovered by
  finding a `.git` entry; identity key = git common-dir (unifies worktrees); capture setup =
  install commit/checkout hooks.
- `claudeCode` sessions are *also* filesystem-backed but arrive via the session hook and are **not
  discoverable by walking a directory**, so they are outside the scanner. The scanner handles
  filesystem-backed sources that are **discoverable by directory inspection**.

## What the database holds (and does not)

The DB holds the **concrete accepted sources** — for git, the folders containing a `.git/` — as
ordinary `Source` (+ `Node`) rows, exactly as today. It does **not** persist "watched roots":
discovery is a transient act, not a stored entity to re-scan. Consequences:

- **No new table, no migration.** Accepting a discovered source is just `ProjectResolver.resolve`
  + capture setup.
- Adding a repo created later = re-run `scan` on the folder; already-accepted sources come back
  flagged `alreadyRegistered` and are skipped, new ones appear as fresh candidates.

## Architecture — two clean operations + a small type registry

### The discovery abstraction (`FileSystemSourceType`)

One protocol, one conformer today (`GitSource`). The scanner holds **zero** git-specific logic.

```swift
public struct DiscoveredSource: Equatable, Sendable {
  public let kind: String          // a SourceKind constant (e.g. gitRepo)
  public let directory: URL        // the folder that IS the source (git: the dir containing .git)
  public let identityKey: String   // becomes Source.key (git: git common-dir)
  public let displayName: String
  public var alreadyRegistered: Bool   // filled by the scanner from the DB (read-only)
}

public protocol FileSystemSourceType: Sendable {
  var kind: String { get }
  var prunesChildrenWhenDetected: Bool { get }        // git: true — don't descend into a repo
  func detect(directory: URL) -> DiscoveredSource?    // pure; no DB, no writes; alreadyRegistered = false here
  func onRegister(_ discovered: DiscoveredSource, db: any DatabaseWriter) throws  // git: install hooks
}
```

- **`GitSource`** conforms: `kind = SourceKind.gitRepo`; `detect` returns a candidate when the
  directory holds a `.git` entry and `git` validates it, with `identityKey = Git.commonDir(in:)`
  and `displayName = ProjectResolver.displayName(forKey:)`; `prunesChildrenWhenDetected = true`;
  `onRegister` installs hooks via `HookInstaller.install(inRepo: discovered.directory,
  pensievePath:)`. `GitSource` is constructed with the `pensievePath` it should bake into hooks
  (`GitSource(pensievePath:)`), so `onRegister` needs no extra parameter and the protocol stays
  kind-agnostic.
- **Registry:** `[GitSource(pensievePath: …)]` today. A future kind = one new `FileSystemSourceType`
  added to the registry; the scanner is untouched. (This discovery-side abstraction is distinct
  from the ingestion-side per-kind handler the backlog still defers.)

### `SourceScanner`

- **`discover(root:recursive:db:) -> [DiscoveredSource]`** — *read-only, no side effects.* Walks
  the folder, runs each registered type's `detect` at each directory, and fills `alreadyRegistered`
  by checking the DB read-only for an existing `Source` with that `(kind, key)`. Pruning:
  - **noise dirs** always skipped: `node_modules`, `.build`, `.git`, `vendor`, `Pods`,
    `DerivedData`, and dot-directories.
  - when a type detects a source and `prunesChildrenWhenDetected` is true, do not descend into it.
  - **recursion:** `recursive == false` → inspect the root itself + its immediate children
    (depth 1); `recursive == true` → full walk (still honoring prune rules).
- **`accept(_ candidates:[DiscoveredSource], db:) throws -> AcceptResult`** — persists + sets up
  the *selected* candidates: `ProjectResolver.resolve(db, path: identityKey, kind:)` (find-or-create
  the `Source` + `Node`), then `type.onRegister(discovered, db:)`. **Idempotent** — re-accepting an
  existing source is a no-op (resolve is find-or-create; `HookInstaller` is marker-guarded).
  `AcceptResult` reports, per kind: registered (new), alreadySeen, and hook/setup outcomes.

The **curation step** (checkbox list, un-checking) lives between `discover` and `accept` and is the
**app's** job (pass 2). Pass 1 exposes both ends via the CLI.

### Worktrees

A linked worktree's `.git` is a *file* pointing at the main repo's common dir. `detect` resolves
`identityKey` via `Git.commonDir`, so a worktree yields the **same** identity key as its main repo
→ it dedupes to one `Source`, and hooks (which live in the shared common dir) are covered by the
main repo. The scanner needs no special worktree case beyond using common-dir as the key.

## CLI surface (pass 1)

- `pensieve scan <folder> [--recursive]` — discover and **list** candidates grouped by kind
  (dry run; persists nothing), marking already-registered ones.
- `pensieve scan <folder> [--recursive] --accept` — discover, then **accept all** candidates
  (register + install setup). Prints the `AcceptResult`.

Fine-grained per-candidate selection is deferred to the app's checkbox UI (pass 2). The CLI
resolves its own executable path for `GitSource(pensievePath:)` the way `install-session-hook`
already does (`Bundle.main.executablePath`).

## Testing

`SourceScannerTests` against a temp tree built with the existing `makeCommittedRepo` /
`addWorktree` helpers:

- **discover:** a root with two child repos + one nested repo + a `node_modules` dir → non-recursive
  finds the depth-1 repos only; recursive finds the nested one too; noise dirs never descended;
  the folder-itself-is-a-repo case detected.
- **prune-on-detect:** a repo containing a subdir is not descended into (one candidate, not two).
- **worktree dedupe:** a repo + a linked worktree under the root → one candidate (shared
  common-dir identity key).
- **alreadyRegistered:** seed a `Source` for one repo → that candidate comes back
  `alreadyRegistered == true`, the other `false`.
- **accept:** accepting candidates creates the expected `Source`(+`Node`) rows and installs git
  hooks (assert the hook files exist with the marker); a second `accept` of the same candidates is
  a clean no-op (no duplicate sources, hooks unchanged).
- **GitSource.detect** unit: a plain dir → nil; a `git init` dir → candidate with common-dir key
  and repo-dir displayName.

`GitSource` and `SourceScanner` are pure/DB-only (no GUI), so all of this runs under
`./scripts/test.sh`.

## Non-goals (pass 1) / future

- **Settings-window UI** (folder picker, recursive toggle, checkbox candidate list, accept/uncheck)
  — pass 2, its own spec, built on `discover`/`accept`.
- **Historical backfill** — `accept` installs hooks + registers, so *future* commits are captured
  and the source appears in the tree; it does **not** ingest past `git log`. A freshly-accepted
  repo shows zero events until its next commit. Deferred.
- **Automatic periodic re-scan** — manual `scan` only; auto-rescan belongs to the future
  `pensieved` daemon.
- **Proactively suggesting new projects** learned implicitly (e.g. from session cwds or commits in
  unregistered repos) — a future direction once capture is flowing; not built now.
- **Non-git source kinds** — the abstraction exists; no speculative kinds implemented.

## Open constraints

- Build/test with `./scripts/test.sh` (optionally `--filter`), NOT `swift test` — Command Line
  Tools only. `swift build`/`swift run` work normally.
- SQLiteData predicates use `.eq(x)`, NOT `== x`. Reuse `SourceKind` constants.
- Reuse existing pieces — `ProjectResolver.resolve` / `.displayName(forKey:)`,
  `HookInstaller.install`, `Git.commonDir` — don't reimplement.
- **Capture path stays sacred:** scanning is read-only until `accept`; `accept` only writes the
  canonical store + installs marker-guarded hooks; nothing on the scan path blocks or slows a
  commit.
- No shared mutable `static ISO8601DateFormatter` (Swift 6).

## Self-review

- **Placeholders:** none — every type and operation has a concrete interface.
- **Consistency:** persistence claim ("no new table") matches "DB holds concrete sources = existing
  `Source` rows"; the scanner-has-no-git-logic claim matches all git specifics living in
  `GitSource`; worktree handling matches the existing common-dir keying.
- **Scope:** one protocol + one conformer + one scanner (two ops) + a `scan` CLI command — a single
  plan. The UI is explicitly a separate pass.
- **Ambiguity:** recursion depth pinned (non-recursive = root + depth-1; recursive = full walk);
  "the concrete directory" pinned (git: the `.git`-containing folder for `directory`; common-dir
  for `identityKey`/`Source.key`).
