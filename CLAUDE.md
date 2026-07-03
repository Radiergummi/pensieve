# Pensieve

Personal (single-user) native-macOS tool that reconstructs *where each of my parallel projects stands* by automatically capturing work — git commits and Claude Code sessions — and surfacing grounded, provenance-cited summaries and a "what's next" queue. Built to help an ADHD workflow reload context on many efforts. **Not a product.**

## Status

- **Phase 1A — DONE** (merged to `main`): headless capture → ingest → query pipeline + `pensieve` CLI + git-hook installer. 19 tests.
- **Phase 1B — NEXT**: the intelligence layer (loose-end extraction, grounded summaries, `next`/`digest`). This is the make-or-break validation gate. Not started.
- Later (intended, not scheduled): the SwiftUI app (the actual product — three-pane, Mela-like), `pensieved` background service, CloudKit sync + iOS, widgets/Siri/Spotlight.

## Build & test

- **Run the test suite with `./scripts/test.sh`** (optionally `--filter <name>`). **NOT plain `swift test`** — this machine is Command Line Tools–only (no Xcode.app), so `swift test` can't load the Swift Testing framework; the wrapper puts it on the search path/rpath. `swift build` and `swift run` work normally.
- Run the CLI: `swift run pensieve <subcommand>`. Tests/CLI honor `PENSIEVE_DB` and `PENSIEVE_CAPTURE_DB` env overrides to point at temp SQLite files.
- Disk on this machine runs tight; if a build dies with a SwiftSyntax/macro linker error, `rm -rf .build` and retry.

## Architecture (as built)

Two SQLite databases, deliberately separate:
- **Capture spool** (`capture.sqlite`) — dumb, append-only, WAL, never synced. Git hooks / `pensieve capture-*` append one raw row and exit. **The capture path is sacred: fast, fire-and-forget, and must never block or break a git commit.**
- **Canonical store** (`pensieve.sqlite`) — rich model via **SQLiteData (GRDB-backed)**, UUID PKs, STRICT tables. The only store that will ever sync (CloudKit, later).

Flow: `git hook / CLI → spool → Ingester.drain() → canonical events`. The **ingester** is the only writer of the canonical store; it enriches git commits (via `git show`) and Claude Code sessions (by reading the on-disk `.jsonl` transcripts) into project-attributed `Event`s.

**Core principle — a Project is an area of work, NOT a directory.** Git repos are one *source type* (`SourceKind.gitRepo`); Claude Code sessions another (`SourceKind.claudeCode`). Sources bind many-to-one to a project; `pensieve group` merges. Attribution is by *canonicalized filesystem path → source → project*.

Layout: `Sources/PensieveKit/{Model,Store,Capture,Transcript,Ingest,Query,Support}` (the framework — all real logic), `Sources/pensieve/` (thin CLI over PensieveKit), `Tests/PensieveKitTests/`.

## Conventions & gotchas

- **SQLiteData 1.6.6 predicates use `.eq(x)`, NOT `== x`** (e.g. `.where { $0.name.eq(name) }`). `==` is `unavailable` and won't compile.
- Table/column names must match `@Table` property names exactly; tables are `STRICT`; PKs are `UUID` (keeps CloudKit reachable).
- Kind strings live in `CaptureKind` / `SourceKind` (`CapturePayloads.swift`) — reuse the constants, don't hardcode.
- Don't use a shared mutable `static` `ISO8601DateFormatter` (Swift 6 concurrency); use a local instance or `Date.ISO8601FormatStyle`.
- **No Python, ever.** Swift only.
- LLM work (Phase 1B): I have a Claude *subscription*, **no API key** — go through an `LLMProvider` protocol whose default shells out to `claude -p`. Stay provider-agnostic.

## How we work here

Design-first. For any feature: brainstorm → write a spec/plan under `docs/superpowers/` → execute with review checkpoints (subagent-driven). Surface tradeoffs; keep changes surgical and minimal (YAGNI). Grounded-with-provenance is the north star for the intelligence layer — every AI-surfaced "loose end" must cite real captured text or it doesn't appear.

## Where to read next

- `docs/superpowers/specs/2026-07-03-pensieve-mvp-design.md` — the approved design (full intent, all phases).
- `docs/superpowers/plans/2026-07-03-pensieve-phase1a-capture-ingest.md` — the executed 1A plan.
- `docs/superpowers/phase-1a-outcome.md` — **what 1A actually shipped + concrete design inputs for Phase 1B** (read this before planning 1B).
