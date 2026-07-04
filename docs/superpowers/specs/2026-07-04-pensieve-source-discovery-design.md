# Source Discovery — Watched-Folder Scan (Design)

**Date:** 2026-07-04. **Status:** approved in brainstorming; revised after two adversarial spec
reviews (architecture + correctness). **Pass 1 of 2** (engine + CLI; the settings-window UI is
pass 2, its own spec).

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
  finding a `.git` **directory** (a main working tree); identity key = git common-dir (unifies
  worktrees); capture setup = install commit/checkout hooks.
- `claudeCode` sessions are *also* filesystem-backed but arrive via the session hook and are **not
  discoverable by walking a directory**, so they are outside the scanner. The scanner handles
  filesystem-backed sources that are **discoverable by directory inspection**.

## What the database holds (and does not — pass 1)

The DB holds the **concrete accepted sources** — for git, the folders containing a `.git/` — as
ordinary `Source` (+ `Node`) rows, exactly as today. **Pass 1 persists no "watched roots": the CLI
is stateless (it takes a folder argument), so there is no root entity to store or re-scan.**
Consequences:

- **No new table, no migration** in pass 1. Accepting a discovered source is just
  `ProjectResolver.resolve` + capture setup.
- Adding a repo created later = re-run `scan` on the folder; already-accepted sources come back
  flagged `alreadyRegistered` and are skipped, new ones appear as fresh candidates.
- **Pass 2 may reasonably persist watched folders + the recursive flag** so the settings window can
  render its checkbox list without re-typing paths — that is pass 2's call, not foreclosed here.
  (Migrations are additive and routine; reintroducing a `WatchedRoot` table later is cheap.)

## Architecture — two clean operations + a small type registry

### The discovery abstraction (`FileSystemSourceType`)

The user directed a source-oriented model ("a git source is one concrete filesystem-backed
source"). To honor that **and** keep the scanner kind-agnostic, discovery goes through a small
protocol whose job is to keep *all* git specifics out of the scanner. It is kept to the minimum the
one conformer actually exercises — no parameter exists for a hypothetical future kind. (This
discovery-side seam is distinct from, and does not pre-empt, the ingestion-side per-kind handler
the backlog still defers.)

```swift
public struct DiscoveredSource: Equatable, Sendable {
  public let kind: String          // a SourceKind constant (e.g. gitRepo)
  public let directory: URL        // the source's main directory (git: the working tree holding .git/)
  public let identityKey: String   // canonicalized; becomes Source.key (git: canonicalized common-dir)
  public let displayName: String   // for listing/UI only — accept IGNORES this (resolve names the node)
}

public protocol FileSystemSourceType: Sendable {
  var kind: String { get }
  var prunesChildrenWhenDetected: Bool { get }   // policy (not a law): git chooses not to re-scan a detected repo's interior
  func detect(directory: URL) -> DiscoveredSource?  // performs NO persistence writes; may touch the filesystem / shell git
  func onRegister(_ discovered: DiscoveredSource) throws  // capture-setup side effects only (git: install hooks)
}
```

- **`GitSource`** conforms: `kind = SourceKind.gitRepo`; `prunesChildrenWhenDetected = true`.
  - `detect` returns a candidate **only when `directory/.git` is a real directory** (a main working
    tree) and `git` validates it. This deliberately **skips linked worktrees and submodules**
    (whose `.git` is a *file*, not a directory) — see Worktrees & submodules below.
    `identityKey = ProjectResolver.canonical(Git.commonDir(in: directory))` — canonicalized so it
    is byte-identical to the key `resolve`/ingest already store (guards `alreadyRegistered` against
    drift). `displayName = ProjectResolver.displayName(forKey: identityKey)`.
  - `onRegister` installs hooks via `HookInstaller.install(inRepo: discovered.directory,
    pensievePath:)`. `GitSource` is constructed with the `pensievePath` to bake into hooks
    (`GitSource(pensievePath:)`), so `onRegister` needs no extra parameter and the protocol stays
    kind-agnostic. (No `db` parameter: `accept` owns the DB write; `onRegister` is filesystem
    side-effects only.)
- **Registry:** `[GitSource(pensievePath: …)]` today. A future kind = one new `FileSystemSourceType`
  added to the registry; the scanner is untouched.

### `SourceScanner`

Holds the `[FileSystemSourceType]` registry; both operations use it.

- **`discover(root:recursive:db:) -> [DiscoveryCandidate]`** — performs **no writes** (reads the
  filesystem, shells `git`, and reads the DB read-only). Walks the folder, runs each type's
  `detect` at each directory, then annotates membership:

  ```swift
  public struct DiscoveryCandidate: Equatable, Sendable {
    public let source: DiscoveredSource
    public let alreadyRegistered: Bool   // a Source with (kind, identityKey) already exists
  }
  ```
  - **Candidate dedup:** collapse by `(kind, identityKey)` before returning (belt-and-suspenders;
    with the `.git`-must-be-a-directory rule a worktree won't even be detected, but two paths that
    canonicalize to one identity still merge to one candidate).
  - **`alreadyRegistered`:** true iff a `Source` with that `(kind, identityKey)` exists (read-only
    query; `identityKey` is already canonicalized to match stored `Source.key`).
  - **Walk safety (must be specified, not left to the enumerator's defaults):**
    - **Do not follow directory symlinks** (avoids `~/Projects/current -> .` self-links and cycles → infinite walk).
    - **Skip-and-continue on unreadable directories** — a permission-denied subdir must never abort the whole scan.
    - **Noise dirs always skipped:** `node_modules`, `.build`, `.git`, `vendor`, `Pods`,
      `DerivedData`, and dot-directories.
    - When a type detects a source and `prunesChildrenWhenDetected` is true, do not descend into it.
    - **Recursion & the root:** detection+prune takes precedence over the depth rule. If the root
      itself is a source, it yields one candidate and its children are **not** inspected. Otherwise:
      `recursive == false` → inspect the root + its immediate children (depth 1); `recursive == true`
      → full walk (honoring prune + noise + symlink rules).

- **`accept(_ candidates:[DiscoveredSource], db:) throws -> AcceptResult`** — **best-effort, per
  candidate** (a single bad repo must not abort the batch):

  ```swift
  public struct AcceptResult: Sendable {
    public var registered: [DiscoveredSource]        // newly created Source(+Node)
    public var alreadyRegistered: [DiscoveredSource]  // resolve found an existing Source
    public var setupFailed: [(DiscoveredSource, String)]  // registered, but onRegister threw (reason)
  }
  ```
  For each candidate: `ProjectResolver.resolve(db, path: identityKey, kind:)` (find-or-create the
  `Source`+`Node`), then look up the matching type and call `type.onRegister(discovered)`. If
  `onRegister` throws — the **expected** case for a repo carrying a pre-existing *foreign*
  `post-commit`/`post-checkout` hook, which `HookInstaller` refuses to clobber
  (`HookInstallError.existingHooks`) — record it in `setupFailed` and **continue**; the `Source`
  row is **kept** (the area is still tracked and can capture sessions / be ingested manually; the
  user can resolve hooks later). `accept` only rethrows on a catastrophic DB failure, never on a
  per-candidate setup failure. **Idempotency:** re-accepting is a clean no-op *for our own repos*
  (resolve find-or-create returns the existing row; `HookInstaller` is marker-guarded and skips a
  hook it already owns); a foreign-hook repo re-reports in `setupFailed` each run (correct — nothing
  was clobbered).

The **curation step** (checkbox list, un-checking) lives between `discover` and `accept` and is the
**app's** job (pass 2). Pass 1 exposes both ends via the CLI.

### Worktrees & submodules

A linked worktree's `.git` is a *file* pointing at the main repo's common dir; a submodule's `.git`
is likewise a file. **`GitSource.detect` requires `.git` to be a real directory, so it detects only
main working trees and skips worktrees and submodules entirely.** This is deliberate and fixes two
failures the naive "any `.git` entry" rule would cause:
1. a worktree would otherwise be a *separate* candidate (its `directory` differs from the main
   repo's, so `Equatable` wouldn't merge them) — now it is never detected;
2. `HookInstaller.install(inRepo: worktreeDir)` would `createDirectory(worktreeDir/.git/hooks)` and
   **throw**, because `worktreeDir/.git` is a file — now no hook is ever installed into a worktree.
Hooks live in the shared common dir, so hooking the main working tree already covers every worktree.
The `(kind, identityKey)` dedup (identity = common-dir) is the second layer of safety. **Bare repos**
(no working tree, no `.git` dir) are intentionally not discovered — no local commits happen there.

## CLI surface (pass 1)

- `pensieve scan <folder> [--recursive]` — discover and **list** candidates grouped by kind
  (dry run; persists nothing), marking already-registered ones.
- `pensieve scan <folder> [--recursive] --accept` — discover, then **accept all** candidates
  (register + install setup). Prints the `AcceptResult`, including any `setupFailed` repos and why.

Fine-grained per-candidate selection is deferred to the app's checkbox UI (pass 2). The CLI resolves
its own executable path for `GitSource(pensievePath:)` the way `install-session-hook` already does
(`Bundle.main.executablePath`).

## Testing

`SourceScannerTests` + `GitSourceTests` against a temp tree built with the existing
`makeCommittedRepo` / `addWorktree` helpers. **Happy paths and every dangerous case the reviews
surfaced:**

- **discover / recursion:** a root with two child repos + one repo nested at depth-2 under a *plain*
  dir + a `node_modules` dir → non-recursive finds the two depth-1 repos only; recursive also finds
  the depth-2 one; noise dirs never descended; the root-itself-is-a-repo case yields one candidate
  and no child inspection.
- **prune-on-detect / repo-nested-in-repo:** a repo whose working tree *contains another repo* →
  only the outer repo is a candidate (the inner one is intentionally not discovered; `--recursive`
  does not change this). Asserts prune-on-detect and disambiguates "nested" from the depth-2 case.
- **worktree & submodule:** a repo + a linked worktree (and a submodule) under the root → **one**
  candidate (the main repo); `accept` on that tree **does not throw** and installs hooks only into
  the main repo's `.git/hooks` (assert the worktree's `.git` file is untouched).
- **alreadyRegistered:** seed a `Source` for one repo → that candidate returns
  `alreadyRegistered == true`, the other `false`; the seeded key matches via canonicalization.
- **accept happy + idempotent:** accepting creates the expected `Source`(+`Node`) rows and installs
  marker-bearing hooks; a second `accept` is a clean no-op (no duplicate sources, hooks unchanged).
- **accept partial failure:** a candidate whose repo has a pre-existing *foreign* `post-commit` hook
  → that repo lands in `setupFailed` (foreign hook not clobbered), its `Source` is still created,
  and **other candidates in the same batch still succeed** (batch not aborted).
- **walk safety:** a symlink cycle under the root (`current -> .`) → discovery terminates (symlinks
  not followed); a permission-denied subdir → skipped, scan completes.
- **GitSource.detect unit:** plain dir → nil; `git init` dir → candidate with canonicalized
  common-dir key + repo-dir displayName; a `.git`-*file* dir (worktree) → nil.

`GitSource` and `SourceScanner` are filesystem/DB-only (no GUI), so all of this runs under
`./scripts/test.sh`.

## Non-goals (pass 1) / future

- **Settings-window UI** (folder picker, recursive toggle, checkbox candidate list, accept/uncheck)
  — pass 2, its own spec, built on `discover`/`accept`. Pass 2 decides whether to persist watched
  folders.
- **Historical backfill** — `accept` installs hooks + registers, so *future* commits are captured
  and the source appears in the tree; it does **not** ingest past `git log`. A freshly-accepted repo
  shows zero events until its next commit. Deferred.
- **Automatic periodic re-scan** — manual `scan` only; auto-rescan belongs to the future
  `pensieved` daemon.
- **Proactively suggesting new projects** learned implicitly (e.g. from session cwds or commits in
  unregistered repos) — a future direction once capture is flowing; not built now.
- **Non-git source kinds** — the abstraction exists; no speculative kinds implemented.

## Open constraints

- Build/test with `./scripts/test.sh` (optionally `--filter`), NOT `swift test` — Command Line
  Tools only. `swift build`/`swift run` work normally.
- SQLiteData predicates use `.eq(x)`, NOT `== x`. Reuse `SourceKind` constants.
- Reuse existing pieces — `ProjectResolver.resolve` / `.canonical` / `.displayName(forKey:)`,
  `HookInstaller.install`, `Git.commonDir` — don't reimplement.
- **Capture path stays sacred:** discovery is write-free until `accept`; `accept` only writes the
  canonical store + installs marker-guarded hooks (never clobbering foreign hooks); nothing on the
  scan path blocks or slows a commit.
- No shared mutable `static ISO8601DateFormatter` (Swift 6).

## Self-review

- **Placeholders:** none — every type and operation has a concrete interface.
- **Consistency:** the "no new table" claim matches "DB holds concrete sources = existing `Source`
  rows"; "scanner has zero git logic" matches all git specifics (the `.git`-directory rule,
  common-dir identity, hook install) living in `GitSource`; the worktree/ submodule handling is now
  explicitly designed (detect skips `.git`-file dirs; dedup by identity; hooks only in the main
  working tree) rather than assumed.
- **Scope:** one protocol + one conformer + one scanner (two ops) + a `scan` CLI command — a single
  plan. The UI is explicitly a separate pass.
- **Ambiguity pinned:** identity vs directory (git: `directory` = the `.git`-dir working tree;
  `identityKey` = canonicalized common-dir = stored `Source.key`); recursion (non-recursive = root +
  depth-1, but detection+prune wins at the root); `alreadyRegistered` computed via canonicalized key;
  `accept` is best-effort per candidate and keeps the `Source` on a hook-setup failure.

**Resolved from adversarial review:** worktree dedup + no-crash (Critical); `accept`
partial-failure/atomicity policy; symlink-cycle + permission-denied walk safety; repo-nested-in-repo
is intentionally undiscovered; `onRegister` no longer carries an unused `db`; `alreadyRegistered`
moved off `DiscoveredSource` into a separate `DiscoveryCandidate`; purity claims reworded to
"write-free before accept"; `displayName` documented as listing-only; watched-roots framing softened
to a pass-1 statelessness choice.
