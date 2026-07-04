# Phase 1B-org — the typed tree & strands (design)

**Date:** 2026-07-03. **Branch:** `phase-1b-org` (off `main`). **Status:** design.

Phase 1B shipped and validated the intelligence layer on a flat `Project` model; the
make-or-break precision gate passed on real transcripts. 1B-org is the deferred
**organization layer**, now designed against that real data: a typed recursive tree of
nodes, automatic *strand* birth from git/session activity, and the organizing CLI. It is an
**additive v4 migration** — UUID PKs + STRICT tables keep CloudKit reachable; it forecloses
nothing.

**This phase is organization only.** Loose-end extraction and its verbatim trust gate are
**untouched**. The north star holds: any AI-surfaced discrete claim cites real captured text
verbatim or it doesn't appear.

---

## 1. Goals & non-goals

**Goals**
- Rename `Project → Node`; introduce a strict recursive tree (`parentID`, open-string
  `kind`, `description`, `metadataJSON`).
- Attribute events to the *most-specific* node: a **strand** (branch/worktree fork) when one
  exists, else the top-level project node.
- **Auto-birth strands** conservatively from real activity, without exploding on
  short-lived/merged branches.
- Capture the branch signal a session runs on (new Claude Code `SessionStart` hook) so
  sessions attribute to strands as precisely as commits do.
- Name/describe a strand with a cheap on-device model **when it materializes**.
- Organizing CLI (`add-node`, `nest`, `rename`, `retype`, tree-aware `list`).
- Extend `group()` to re-parent children.

**Non-goals (deferred — see §9)**
- Domain-level recursive rollup summaries (CTE over descendants).
- Per-kind ingestion-handler protocol (a `switch` still suffices for git + session).
- Cross-cutting soft references (`node_links`), evidence-based loose-end auto-close,
  `NLEmbedding` theme discovery, SessionEnd auto-ingest wiring.

---

## 2. Core model change: the strand belongs on the *event*

Today attribution is `path + kind → Source → Project`, and `Event.projectID` points at the
area. A `Source` is *"the repo at path P"* — stable — but one repo throws off events across
many branches/forks. So the strand is a property of the **event**, not the source:

- One `Source` (a repo, or a Claude Code area) → many `Event`s.
- Each `Event` records the point-in-time **`branchKey`** it belongs to and an **`nodeID`**
  pointing at the most-specific node: the project node by default, repointed to a strand node
  once that strand materializes.

`Event.projectID` therefore becomes `Event.nodeID` (and likewise on `Source`, `LooseEnd`,
`Checkpoint`) — the honest name once these can point at any node in the tree.

---

## 3. Data model

### 3.1 `Node` (was `Project`; table `projects` → `nodes`)

```
id            UUID   PK
name          String
state         String  = "active"          // "active" | "archived" | "muted"
createdAt     Date
parentID      UUID?   REFERENCES nodes(id) ON DELETE SET NULL   // strict tree; nil = root
kind          String  = "project"         // open string, soft label
description   String  = ""                // LLM- or user-authored
metadataJSON  String  = "{}"              // YAGNI bag for non-queried extras
branchKey     String?                     // set only on kind == "strand"
```

- **`kind`** is an open string with soft labels — `domain` / `project` / `strand` /
  `concept` / `initiative` / `task` / `topic`. **No enforced levels.** Auto-created nodes are
  `project` (repos/areas) or `strand`; every other kind is user-made via the CLI.
- **`branchKey` is a real column, not in `metadataJSON`** — strand birth queries
  `(parentID, branchKey)` on the ingest hot path, where the YAGNI-blob argument fails.
- **`parentID` uses `ON DELETE SET NULL`** — deleting a node never silently drops a subtree;
  orphans float to root. Deletion normally goes through `group()`, which re-parents first
  (§6).

### 3.2 FK rename `projectID → nodeID`

On `Source`, `Event`, `LooseEnd`, `Checkpoint`. Mechanical but wide (models, queries, CLI,
tests, migration) — scoped as its own plan task.

### 3.3 `Event` gains `branchKey`

```
branchKey     String?    // point-in-time branch this event belongs to (real column, hot-path)
```

`nil` for default-branch / detached-HEAD / non-git events. Populated for non-default-branch
git commits and for sessions (from the `SessionStart` capture).

### 3.4 Source identity moves to the repo, not the worktree

`Source.key` for a `gitRepo`/`claudeCode` source becomes the **git-common-dir**, so every
worktree of one repo binds to one `Source` → one project node. This is the
`--show-toplevel` → `--git-common-dir` fix (§4.3, §5). The existing
`idx_sources_key_kind` unique index still holds — now keyed on the common-dir.

---

## 4. Capture-time signals

### 4.1 Git hooks — unchanged

The git hooks already capture the only *volatile* fact — the branch name at commit time
(`git rev-parse --abbrev-ref HEAD`). Everything else is a *stable* property of the repo that
the ingester resolves when it already shells into `git`. The sacred capture path stays
dumb, fast, fire-and-forget. **No git-hook changes in this phase.**

### 4.2 New Claude Code `SessionStart` hook (branch capture for sessions)

Sessions record no git branch anywhere — the hook only stores a transcript path. To
attribute a session to a strand precisely (rather than best-effort at ingest, which is stale
if you branch-switch in the main worktree mid-session), we capture the branch at session
start.

- **Event:** `SessionStart` with **matcher `"startup"`** — fires once, before the first
  prompt exists, and its stdin JSON carries `session_id`, `cwd`, `transcript_path`.
  Matching `"startup"` avoids re-triggers on resume / `/clear` / compaction.
  (Confirmed against `code.claude.com/docs/en/hooks.md`, 2026-07-03.)
- **The hook stays dumb.** The shell script resolves branch + common-dir from `cwd` at start
  and spools one row — no LLM call, no blocking work (same principle as the git hooks). It
  reads the `SessionStart` JSON from stdin.
- **New capture kind `cc.session.start`**, payload
  `{ sessionID, cwd, branch, commonDir, transcriptPath }`.
- **Installation is global** (`~/.claude/settings.json`), since sessions happen across all
  repos, and the script resolves the branch from `cwd`. The installer **merges idempotently**
  into an existing `settings.json` (parse → add our `SessionStart` entry if absent →
  write) and **never clobbers** foreign hooks.

> **Session *content* ingestion (transcript → loose ends) is unchanged** — it stays on the
> existing `pensieve ingest-session --path` path, joined to its branch by `sessionID` from
> the `cc.session.start` row. Auto-wiring a `SessionEnd` hook to trigger content ingestion is
> deferred (§9).

### 4.3 What the ingester resolves (stable repo properties)

- **common-dir:** `git -C <path> rev-parse --git-common-dir` → the repo identity that unifies
  worktrees. Replaces `--show-toplevel` for source keying (git commits *and* sessions).
- **default branch:** `git symbolic-ref refs/remotes/origin/HEAD` → `git config
  init.defaultBranch` → probe `main` then `master`. Used to decide strand-worthiness.
- **detached HEAD:** detected when the captured branch is `HEAD` (`--abbrev-ref` output when
  detached). Never mints a `"HEAD"` strand.

---

## 5. Ingest & strand birth

The ingester (`switch` on capture kind — no handler protocol yet) does, per event:

1. **Resolve the repo & node.** Compute common-dir; resolve/find the `Source` (keyed by
   common-dir) and its project node, as today via `ProjectResolver`.
2. **Compute `branchKey`.** For git commits, from the captured branch name. For sessions,
   from the matching `cc.session.start` row (joined by `sessionID`); best-effort from `cwd`
   if absent.
3. **Decide attribution.**
   - Branch is the default branch, **or** detached HEAD, **or** non-git → `branchKey = nil`,
     `nodeID = project node`.
   - Otherwise → set `Event.branchKey`, and `nodeID = project node` for now (the branch is
     *tagged* but not yet a strand).
4. **Strand-birth check** (only for non-default, non-detached branches). Count existing
   events under this project sharing `branchKey`. The branch materializes into a strand when
   it has **≥2 commits OR ≥2 sessions** (two events *of the same kind* — a lone commit plus
   its own session does not trigger it). On crossing the threshold:
   - **Find-or-create** the `strand` node: `parentID = project node`, `kind = "strand"`,
     `branchKey = <branch>`, `name = <branch>` initially.
   - **Repoint** every matching event's `nodeID` (and the current one) from the project node
     to the strand node.
   - **Name/describe** the strand from the accumulated text (commit subjects + session
     prompts on that branch) via the on-device `LLMProvider` (`claude -p` fallback). Failure
     is non-fatal: the strand keeps its branch-name and empty description.

Strand birth is checked on the ingest path (which already shells `git`), never on the sacred
capture path. Because every event carries its `branchKey`, materialization is always a
lossless repoint — a branch that never crosses the threshold simply stays tagged at the
project node, and short-lived / merged branches never become nodes.

### 5.1 Trust boundary

A strand **name/description is an organizational label**, not a surfaced discrete claim, so
it is outside the verbatim gate by design. Loose-end extraction and its verbatim gate are
**not modified** by this phase.

---

## 6. `group()` extension

When merging node `B` into primary `A`, before repointing and deleting `B`:

- **Re-parent B's children:** `Node.where { $0.parentID.eq(B) }.update { $0.parentID = A }`.

Then, as today, repoint `Source` / `Event` / `LooseEnd` / `Checkpoint` `nodeID` from `B` to
`A` and delete `B`. Extend `groupPreservesLooseEndsAndCheckpoints` with a child-reparent
assertion.

---

## 7. Organizing CLI

- `add-node <name> --kind <kind> [--parent <name|id>] [--description <text>]` — create any
  node (domains, concepts, initiatives, …).
- `nest <child> --under <parent>` — set `parentID` (manual strand/organizing move).
- `rename <node> <newName>`.
- `retype <node> <newKind>`.
- `list` (was `ListProjects`) — renders the tree indented by depth; strands under their
  projects.

`status` / `looseends` / `next` continue to operate per-node, unchanged. No cross-child
aggregation this phase (rollup deferred — §9); the tree is *visible* via `list`.

---

## 8. Migration v4 (additive)

Registered after `v3-fingerprint-extraction-provenance`:

- `ALTER TABLE "projects" RENAME TO "nodes"`.
- Add to `nodes`: `parentID` (`REFERENCES nodes(id) ON DELETE SET NULL`),
  `kind TEXT NOT NULL DEFAULT 'project'`, `description TEXT NOT NULL DEFAULT ''`,
  `metadataJSON TEXT NOT NULL DEFAULT '{}'`, `branchKey TEXT`.
- `ALTER TABLE ... RENAME COLUMN "projectID" TO "nodeID"` on `sources`, `events`,
  `looseEnds`, `checkpoints`.
- Add `branchKey TEXT` to `events`.
- Existing rows migrate cleanly: every node becomes `kind='project'`, `parentID=NULL` —
  correct, they are top-level areas.

**Not done retroactively:** the migration does *not* re-key existing sources to common-dir or
merge pre-existing worktree-split projects (1A keyed by `--show-toplevel`). New resolutions
use common-dir; fix any pre-existing split with `group()`. Acceptable — worktree splits are
rare and losslessly mergeable.

STRICT tables + `RENAME COLUMN` / `RENAME TO` are supported by the SQLite in use; SQLiteData
`@Table` maps by property name, so the renamed columns must match the renamed properties.

---

## 9. Deferred (on the roadmap, not foreclosed)

- Domain-level recursive **rollup summaries** (CTE over descendants) — additive later.
- **Per-kind ingestion-handler protocol** — when a 4th source type arrives.
- **`node_links`** cross-cutting soft references (cycles allowed).
- **Evidence-based loose-end auto-close** (1B only surfaces + ages).
- **`NLEmbedding`** statistical theme discovery (see `backlog.md`).
- **SessionEnd auto-ingest wiring** for transcript content.
- Retroactive worktree-merge / source re-keying in migration.

---

## 10. Testing

- **Strand birth:** 2 commits on a branch → strand; 1 commit + 1 session → *no* strand;
  2 sessions → strand.
- **Detached HEAD** → no strand (no `"HEAD"` node).
- **Default branch** → no strand; event at project node, `branchKey = nil`.
- **Worktree unification:** two worktree paths of one repo → one project node (common-dir).
- **Repoint on birth:** events tagged before the threshold get `nodeID` repointed to the new
  strand.
- **`group()`** re-parents children (extended `groupPreservesLooseEndsAndCheckpoints`).
- **Migration v4** upgrades a v3 DB: rows become `kind='project'`/`parentID=NULL`, all
  existing queries still pass.
- **LLM naming** via a mock `LLMProvider`: a materialized strand gets the mock's name;
  provider failure leaves the branch-name + empty description (non-fatal).
- **SessionStart hook installer** merges idempotently into an existing `settings.json` and
  refuses to clobber foreign entries.

---

## 11. Carried minor findings — fold in opportunistically

Where this phase already touches the code, fold in the 1B-carried findings (non-blocking):
`FoundationModelsProbe` unavailable-reason string coupling; `ClaudeCLIProvider.shellRun`
stdin fire-and-forget SIGPIPE risk; `LooseEndQueries.open` / `NextQueries.ranked` N+1/2N
per-project queries and `Calendar.current` locale/TZ dependence; `SummaryBuilder`
`events.prefix(15)` redundancy; `CheckpointCommand` bare-name collision. Optional precision
polish (gate already passes) stays backlog, not scope.

---

## 12. Key decisions & rationale (for future-me)

- **Strand on the event, not the source.** A source is a stable repo; strands are forks
  within it. `Event.branchKey` + `Event.nodeID` capture this without a source per branch.
- **Conservative auto-birth via tag-then-materialize.** Every event is tagged with its
  branch immediately; a strand node appears only past a ≥2-same-kind-events threshold. No
  explosion on short-lived/merged branches; materialization is a lossless repoint.
- **`branchKey` promoted to a column.** Queried by `(parentID, branchKey)` on the ingest hot
  path — the one place the YAGNI-blob argument fails.
- **Signals resolved in the ingester, not the hook.** Only the branch name is volatile
  (already captured); common-dir + default-branch are stable repo properties the ingester
  resolves where it already shells `git`. Keeps the sacred capture path untouched.
- **CC hook is dumb; naming happens at materialization.** `SessionStart source=startup` has
  an empty transcript, and an LLM call per session launch would tax the capture path. Naming
  from accumulated text at birth is cheaper and better-grounded.
- **`--git-common-dir`, not `--show-toplevel`.** Unifies worktrees into one project instead
  of splitting each into its own — the documented trap.
- **Organization only; the trust gate is untouched.** Strand labels are metadata, not
  surfaced claims; loose-end extraction and its verbatim gate are unchanged.
