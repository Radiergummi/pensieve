# On-device display-name inference for git projects

**Status:** Design — approved, ready for implementation plan
**Date:** 2026-07-06

## Problem

Git-sourced project nodes are named after the working-directory's last path component, verbatim (`ProjectResolver.displayName(forKey:)`). So a repo directory `laravel-rls` becomes a node literally named "laravel-rls". These read like folder names, not projects. We want a human-readable display name — "Laravel RLS Package" — inferred on-device from cheap local context.

## Non-goals

- No new user-facing knobs, config, or CLI flags. Inference just happens.
- No dedicated backfill command. Retroactive application = flush `pensieve.sqlite` and re-ingest fresh (acceptable to the user); every node re-births through the same idempotent pass.
- No change to attribution, the tree, strands, or the trust gate. Naming is organizational, outside the verbatim gate — exactly like existing strand naming.
- Not applied to non-git nodes (claudeCode-only nodes). Scope is git projects.

## Precedent

`Ingester.nameStrand()` already asks the on-device model for a "3–6 word human-readable name" for a freshly-materialized strand: best-effort, non-fatal, outside the trust gate, leaving the deterministic fallback name on any failure. This feature is the same shape applied to git project nodes, with a richer, project-describing set of input signals.

The on-device model is already wired: `FoundationModelsProvider` behind `DefaultProvider.select()` (Apple Foundation Models when available on macOS 26 + Apple Intelligence, else `claude -p`), reached through the `LLMProvider.complete(prompt:)` protocol the `Ingester` already holds as `llm`.

## Design

### 1. Control flow — idempotent post-ingest pass

`ProjectResolver.resolve()` is unchanged: it still sets the verbatim directory name synchronously inside the write transaction. That name is now the **fallback**, and the sacred capture/ingest fast path stays LLM-free.

A new best-effort async method on `Ingester` — `refineProjectNames()` — runs after a drain/ingest, mirroring `nameStrand()`: non-fatal, outside the trust gate. It:

1. Selects candidate nodes: project nodes that have a `gitRepo` source **and whose current name still equals the verbatim default** for that source key (`ProjectResolver.displayName(forKey: gitSourceKey)`).
2. For each, gathers repo context (§2), asks the model for a name (§3), sanitizes and applies it.

The candidate predicate is doing three jobs at once:

- **Guard** — a hand-renamed node (via `pensieve rename`) no longer equals its verbatim default, so it is never touched.
- **Idempotency** — once refined, a node no longer matches, so it is named exactly once. Safe to run every ingest.
- **Backfill-for-free** — on a flush-and-reingest, every node re-births with its verbatim default and therefore matches, so all get named through this one path. No separate born-flag threading, no separate command.

Where it's called: after `Ingester` finishes its ingest work (same places `nameStrand` is reached / at the end of the drain cycle). Sequential over candidates, best-effort; a single failure skips that node and continues.

### 2. Signal gathering — `ProjectContext`

A new PensieveKit helper: `ProjectContext.gather(repoPath:)` reads cheap local signals from the repo working directory and returns a small struct. Every read is best-effort — a missing file is an absent field, never an error. All fields are size-capped so the prompt stays small and the model stays fast.

The git source key is the git **common-dir** (ends in `.git`; worktrees unify there). The working tree to read files from is derived the same way `displayName(forKey:)` already strips `.git` — the common-dir's parent directory.

Fields:

- `dirName` — verbatim last path component (always present; the thing being expanded).
- `gitRemote` — `git remote get-url origin` via `Git.run`, if any.
- `readmeHead` — first ~40 lines / ~1 KB of the first case-insensitive `README*` match.
- `claudeMdHead` — first ~1 KB of `CLAUDE.md`, if present.
- `manifest` — from the first match among `composer.json`, `package.json`, `Package.swift`, `Cargo.toml`, `pyproject.toml`: just the package `name` + `description`/summary, as a short string. JSON parsed where trivial (`composer.json`, `package.json`); `Package.swift` grep the package `name:`; `Cargo.toml`/`pyproject.toml` grep the `name`/`description` lines. Kept short, never the whole file.

### 3. Prompt, sanitization, guard

Prompt (mirrors `nameStrand`'s shape): present the gathered signals and ask for a human-readable project display name on line 1 — 2–6 words, a plain label, no numbering/bullets, no trailing period — and instruct the model not to invent facts beyond the signals shown. (Description is out of scope here; this feature only sets the name. The existing empty/other description handling is untouched.)

Reuse `Ingester.sanitizeStrandName(_:)` (or a shared sibling) to strip leading list markers, wrapping quotes/backticks, and trailing sentence punctuation. On empty/failed output, leave the verbatim fallback in place.

Apply: `Node.where { $0.id.eq(nodeID) }.update { $0.name = name }` — name only.

### 4. Retroactive application

No migration, no command. To re-name the already-captured store: delete `pensieve.sqlite` (canonical store only; the capture spool is untouched) and re-run ingest/sync. Every node re-births with its verbatim default and is named by `refineProjectNames()`. Sequential on-device calls over the current handful of projects is a one-time cost and acceptable.

## Testing

PensieveKit is the tested layer; keep logic there and mock the model via `LLMProvider`.

- `ProjectContext.gather` — pure file/`Git.run` reads over a temp repo fixture: each signal present/absent, size caps enforced, `.git` common-dir → working-tree derivation, manifest parsing per format.
- `refineProjectNames` candidate selection — nodes with/without a `gitRepo` source; name-equals-default vs. hand-renamed (must be skipped); already-refined (must be skipped → idempotent); with a `MockLLMProvider` returning a canned name, assert the node's name updates and the fallback survives on empty/throwing provider.
- `sanitizeStrandName` reuse — existing tests already cover it; add a project-name case if a shared rename warrants it.

No app-target changes; the app reads names read-only as today.

## Files

- `Sources/PensieveKit/Ingest/Ingester.swift` — add `refineProjectNames()`; call it in the drain/ingest cycle; reuse/lift `sanitizeStrandName`.
- `Sources/PensieveKit/Ingest/ProjectContext.swift` — **new** signal-gathering helper.
- `Sources/PensieveKit/Ingest/ProjectResolver.swift` — no behavior change; `displayName(forKey:)` / working-tree derivation reused by the candidate predicate and `ProjectContext`.
- `Tests/PensieveKitTests/` — new tests for `ProjectContext` and `refineProjectNames`.
