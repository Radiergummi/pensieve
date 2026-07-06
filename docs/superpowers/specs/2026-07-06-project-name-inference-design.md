# On-device display-name inference for git projects

**Status:** Design — approved, ready for implementation plan
**Date:** 2026-07-06
**Revised:** 2026-07-06 after independent adversarial review (multi-source nodes, working-tree derivation, attempt-once marker, hook site, signal hardening).

## Problem

Git-sourced project nodes are named after the working-directory's last path component, verbatim (`ProjectResolver.displayName(forKey:)`). So a repo directory `laravel-rls` becomes a node literally named "laravel-rls". These read like folder names, not projects. We want a human-readable display name — "Laravel RLS Package" — inferred on-device from cheap local context.

## Non-goals

- No new user-facing knobs, config, or CLI flags. Inference just happens.
- No dedicated backfill command. Retroactive application = back up + flush `pensieve.sqlite` + re-ingest (see §4).
- No new schema/migration. The attempt-once marker rides in the existing `Node.metadataJSON` bag.
- No change to attribution, the tree, strands, or the trust gate. Naming is organizational, outside the verbatim gate — like existing strand naming.
- Not applied to non-git nodes (claudeCode-only) or to **merged** nodes with more than one `gitRepo` source (already user-curated).
- No name-uniqueness constraint. Directory names can already collide; two inferred names matching is acceptable.

## Precedent

`Ingester.nameStrand()` already asks the on-device model for a "3–6 word human-readable name" for a freshly-materialized strand: best-effort, non-fatal, outside the trust gate, leaving the deterministic fallback on any failure. This feature is the same shape applied to git project nodes, with richer, project-describing input signals and a persisted attempt marker so it runs exactly once per node.

The on-device model is already wired: `FoundationModelsProvider` behind `DefaultProvider.select()` (Apple Foundation Models when available on macOS 26 + Apple Intelligence, else `claude -p`), reached through `LLMProvider.complete(prompt:)`, which the `Ingester` holds as `let llm: (any LLMProvider)?`.

## Design

### 1. Control flow — idempotent, once-per-node, batch pass

`ProjectResolver.resolve()` is unchanged: it still sets the verbatim directory name synchronously inside the write transaction. That name is now the **fallback**, and the sacred capture/ingest fast path stays LLM-free.

Add a best-effort async method `Ingester.refineProjectNames()`, a **batch pass** (not per-row — it cannot live where `nameStrand` lives). It opens with `guard let llm else { return }` (mirroring `nameStrand:210`), then:

1. **Candidate selection (in-Swift filter, not a single SQL `.where`).** Fetch project-kind nodes joined to their sources; keep a node only when **all** hold:
   - it has **exactly one** `gitRepo` source (skip merged/multi-repo nodes — already user-curated);
   - its `metadataJSON` does **not** carry the attempt marker (see below);
   - its current `name` still equals `ProjectResolver.displayName(forKey:)` of that one source key (untouched default — never clobber a hand-rename).
2. For each candidate, gather repo context (§2), ask the model (§3), sanitize, and in one write set `name` (only if a usable name came back) **and** stamp the attempt marker regardless of outcome.
3. Sequential and best-effort; a single failure skips that node and continues. **Per-cycle cap:** process at most N candidates per pass (proposed N ≈ 20); the marker makes the remainder monotonic, so they're picked up on the next drain cycle without ever repeating.

**Attempt-once marker.** A key in `Node.metadataJSON` (the existing "YAGNI bag for non-queried extras"), e.g. `"nameInferred": true`, stamped whenever refine *attempts* a node — success, empty output, or model-echoes-the-default alike. This is what actually guarantees the pass runs once per node: without it, a model that echoes `laravel-rls` verbatim would keep matching the untouched-default predicate and be re-inferred every drain forever. The untouched-default check remains as the hand-rename guard; the marker provides convergence.

**Hook site.** `SyncRunner.run()` drains twice (`SyncRunner.swift:29,38`) while holding `provider`. Call `refineProjectNames()` **after the second drain**, so it sees every node born this cycle. The app's launch/refresh drain uses `Ingester(...).drain()` with `llm == nil` (`AppModel.swift:105`) and is therefore a clean no-op (the `guard let llm` returns immediately) — the app never runs the model, consistent with today.

### 2. Signal gathering — `ProjectContext`

A new PensieveKit helper: `ProjectContext.gather(commonDir:)` reads cheap local signals and returns a small struct. Every read is best-effort — a missing/unreadable file is an absent field, never an error. All fields are size-capped so the prompt stays small.

**Working-tree derivation.** The source key is the git **common-dir**. Resolve the actual checkout with `git -C <commonDir> rev-parse --show-toplevel` (via the existing `Git.run`). If that yields nothing — bare repo, submodule common-dir, or a linked worktree with no obvious tree — skip the file reads and gather only `dirName` + `gitRemote`. Do **not** assume "parent of common-dir" is the working tree; it isn't for bare/submodule layouts and would read a wrong-repo README.

Fields:

- `dirName` — verbatim last path component of the derived name (always present; the thing being expanded).
- `gitRemote` — `git -C <commonDir> remote get-url origin`, if any.
- `readmeHead` — first ~40 lines / ~1 KB of the first **text** README (`README`, `README.md`, `README.txt`, case-insensitive). Skip binary/other extensions (`.pdf`, `.docx`, …).
- `claudeMdHead` — first ~1 KB of `CLAUDE.md`, if present.
- `manifest` — from the first match among `composer.json`, `package.json`, `Package.swift`, `Cargo.toml`, `pyproject.toml`: just the package `name` + `description`/summary as a short string (JSON parsed for `composer.json`/`package.json`; grep `name:` for `Package.swift`; grep `name`/`description` for `Cargo.toml`/`pyproject.toml`). **Advisory, not authoritative** — in a monorepo the arbitrary first match may be worse than the dir name; it is one signal among several and the model decides.

### 3. Prompt, sanitization, marker

Prompt (mirrors `nameStrand`'s shape): present the gathered signals and ask for a human-readable project display name on line 1 — 2–6 words, a plain label, no numbering/bullets, no trailing period. Guidance: **prefer the signals; reasonable expansion and formatting are fine (title-casing, expanding an abbreviation the signals support), but do not fabricate a category** (`Package`/`App`/`CLI`) the signals don't support. Description is out of scope — this feature sets `name` only.

Reuse `Ingester.sanitizeStrandName(_:)` (it's `static`, trivially liftable/shared) to strip leading list markers, wrapping quotes/backticks, and trailing sentence punctuation. On empty/failed output, leave the verbatim fallback; **still stamp the marker** so the node isn't retried.

Apply in one write: `Node.where { $0.id.eq(nodeID) }.update { … }` — set `name` (when a usable name returned) and the updated `metadataJSON` (always). Convention: `.eq(...)`, never `== ...`.

### 4. Retroactive application

No migration, no command. Everything in the current canonical store is automatically generated and reproducible, so the retroactive path is:

1. **Back up** `pensieve.sqlite` (copy the file aside). The capture spool (`capture.sqlite`) is untouched throughout.
2. Delete `pensieve.sqlite` and re-run ingest/sync. Every node re-births with its verbatim default and, having no attempt marker, is named by `refineProjectNames()`.
3. **Diff** the fresh store against the backup and manually reconcile anything worth keeping (e.g. a hand-`retype`/`nest`/`group`/rename you'd made). Because the store to date is auto-generated, this is expected to be a near-empty diff.

Caveat stated plainly: a flush discards **all** manual organization (renames, `retype`, `nest`, `group`, strand names, descriptions), not just verbatim names. That's acceptable *now* because the store is reproducible; the backup-then-diff step exists precisely to catch anything that isn't. Going forward, the once-per-node birth pass makes this automatic — no re-flush is ever needed again.

### Blast-radius note

`Node.name` is not just a sidebar label: per v0.3 it is the `NodeEntity` title indexed into Spotlight and surfaced to Siri/Shortcuts, and the primary label in Briefing and `⌘K`. A wrong inference mislabels the node everywhere the OS surfaces it. This is an accepted tradeoff (naming is organizational, best-effort, and correctable via `pensieve rename`), but it's why §3 forbids fabricating unsupported categories and why the pass is conservative (git-only, single-source, once).

## Testing

PensieveKit is the tested layer; keep logic there and mock the model via `LLMProvider`.

- **`ProjectContext.gather`** over temp-repo fixtures: each signal present/absent; size caps enforced; `git rev-parse --show-toplevel` derivation for a **normal** checkout, a **bare** repo, a **submodule**, and a **linked worktree** (bare/submodule/worktree → name+remote only, no wrong-repo README); README text-only (a binary `README.pdf` is ignored); manifest parsing per format; monorepo arbitrary-first-match documented.
- **`refineProjectNames` candidate selection:** node with **one** `gitRepo` source and untouched default → refined; node with **two** `gitRepo` sources (post-`group`) → **skipped**; hand-renamed node → skipped; node already carrying the `metadataJSON` marker → skipped (idempotent); `claudeCode`-only node → skipped.
- **Outcome handling** with a `MockLLMProvider`: canned name → `name` updates + marker stamped; **model echoes the dir name verbatim** → marker stamped, node not re-inferred on a second pass (no loop); empty/throwing provider → fallback name kept **but marker still stamped**.
- **`llm == nil` path** (app drain) → `refineProjectNames` is a clean no-op.
- **Per-cycle cap** → with > N candidates, exactly N are attempted this pass, the rest next pass, none twice.

No app-target changes; the app reads names read-only as today.

## Files

- `Sources/PensieveKit/Ingest/Ingester.swift` — add `refineProjectNames()` (batch, `guard let llm`, in-Swift candidate filter, per-cycle cap, marker write); share/lift `sanitizeStrandName`.
- `Sources/PensieveKit/Ingest/ProjectContext.swift` — **new** signal-gathering helper (`gather(commonDir:)`, `rev-parse --show-toplevel` derivation).
- `Sources/PensieveKit/Sync/SyncRunner.swift` — call `refineProjectNames()` after the second drain, gated on `provider`.
- `Sources/PensieveKit/Ingest/ProjectResolver.swift` — no behavior change; `displayName(forKey:)` reused by the candidate predicate.
- `Sources/PensieveKit/Model/Node.swift` — no schema change; marker rides in existing `metadataJSON`.
- `Tests/PensieveKitTests/` — new tests for `ProjectContext` and `refineProjectNames` (cases above).
