# Pensieve

Personal (single-user) native-macOS tool that reconstructs *where each of my parallel projects stands* by automatically capturing work — git commits and Claude Code sessions — and surfacing grounded, provenance-cited summaries and a "what's next" queue. Built to help an ADHD workflow reload context on many efforts. **Not a product.**

## Status

- **Phase 1A — DONE** (merged to `main`): headless capture → ingest → query pipeline + `pensieve` CLI + git-hook installer. 19 tests.
- **Phase 1B — DONE** (merged to `main`): the intelligence layer (loose-end extraction, verbatim trust gate, on-device guided-generation LLM, grounded summaries, `next`/`digest`). **The make-or-break precision gate PASSED** on real transcripts (0 noise, 0 fabrication across 3 on-device acceptance runs). 56 tests. See `docs/superpowers/phase-1b-outcome.md`.
- **Phase 1B-org — DONE** (merged to `main`): the typed tree & strands. `Project→Node` rename + strict recursive tree (`parentID`/`kind`/`description`/`metadataJSON`/`branchKey`); git-common-dir source keying (unifies worktrees into one node); auto-birth *strand* nodes from git/session activity (tag-then-materialize, ≥2 same-kind events, lossless repoint of events **and** their loose ends); `SessionStart` hook + `SessionBranch` (captures a session's branch); on-device strand naming (best-effort, outside the trust gate); `group()` re-parents children; organizing CLI (`add-node`/`nest`/`rename`/`retype`) + tree-aware `list`. Additive migrations v4–v6; **trust gate untouched**. 75 tests. See `docs/superpowers/plans/2026-07-04-pensieve-phase1b-org.md`.
- **Pensieve.app v0.1 (heartbeat) — DONE** (merged to `main`): the read-only SwiftUI window over a shared, testable `MonitorSnapshot` kernel (pure gather, reads both stores read-only, never throws). **Superseded by the three-pane app below** — its `MonitorSnapshot` kernel lives on as the sidebar status footer.
- **Source discovery (`pensieve scan`) — DONE** (merged): filesystem scanner (`FileSystemSourceType`, `GitSource`). `SourceScanner.discover(root:recursive:db:)` walks write-free (dedup, prune); `accept(_:db:)` registers + installs hooks (best-effort). CLI: `pensieve scan <folder> [--recursive] [--accept]`. Settings window UI (pass 2) deferred.
- **Sync daemon — DONE & LIVE** (merged): closes the manual-ingest gap. `pensieve sync` = drain spool → `TranscriptDiscovery` (glob finished + in-progress transcripts) → drain again → incremental `ExtractionRunner.run()` (byte-size-gated). `SessionEnd` capture hook (precise trigger) + periodic launchd `com.pensieve.sync` LaunchAgent (`install-daemon`, one-shot every 300 s, `RunAtLoad`). Auto-drain + auto-extract now run unattended.
- **Pensieve.app three-pane — slices 1–2 DONE** (merged): the real app (`swift run PensieveApp`). **Slice 1** — read-only three-pane `NavigationSplitView`: action-first sidebar (Briefing + What's Next/Dormant/Recently Active smart lists + the typed node tree), middle node list, detail recall view (What It Is / Loose Ends with **inline verbatim provenance** / Recent Activity); drains the spool on launch; `NodeForest`/`SmartLists` are tested PensieveKit helpers, views are thin. **Slice 2** — **Briefing** home (by-project "since last visit" world map, default landing, backed by tested `BriefingQueries`; `lastOpenedAt` persisted in **UserDefaults**, not the canonical store) + **⌘K** navigation-only command palette. Window hosted via `NSHostingController` (titlebar safe-area). Design: `docs/superpowers/specs/2026-07-05-pensieve-app-three-pane-design.md`; plans `…-slice1-…` / `…-slice2-…`. **138 tests.**
- **Dogfooding — LIVE**: capture + auto-drain + auto-extract all running. Release binary at `~/.local/bin/pensieve`; SessionStart + SessionEnd hooks in `~/.claude/settings.json`; `com.pensieve.sync` LaunchAgent bootstrapped; real stores at `~/Library/Application Support/Pensieve/`. Watch: `tail -f ~/Library/Logs/Pensieve/sync.log`.
- **Next: three-pane app slices 3–6** — 3: inspector (⌘⌥I) + window polish + LLM "Last Work Done" narration + `ValueObservation` liveness; 4: in-app organizing writes; 5: talk-to-system (describe→create strand); 6: forks surface (gated on the unbuilt fork-capture backend). See `docs/superpowers/backlog.md` **Roadmap**.
- **Long-term (intended, not scheduled)** — the full vision, none foreclosed: menu-bar + `LSUIElement` bundle; resident `pensieved` `SMAppService` (the launchd daemon already covers auto-flow); CloudKit sync + iOS companion; widgets / Siri-Shortcuts / Spotlight; FSEvents real-time monitoring; additional non-code source types (Notion, Entra, browser); cross-project dependency graphs / analytics. Full detail: `docs/superpowers/backlog.md` (Roadmap + deferred ledger) and `docs/superpowers/specs/2026-07-03-pensieve-mvp-design.md`.

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

Layout: `Sources/PensieveKit/{Model,Store,Capture,Transcript,Ingest,Intelligence,LLM,Discovery,Daemon,Sync,Query,Support}` (the framework — all real logic), `Sources/pensieve/` (thin CLI over PensieveKit), `Sources/PensieveApp/` (thin SwiftUI three-pane app over PensieveKit), `Tests/PensieveKitTests/`.

## Conventions & gotchas

- **SQLiteData 1.6.6 predicates use `.eq(x)`, NOT `== x`** (e.g. `.where { $0.name.eq(name) }`). `==` is `unavailable` and won't compile.
- Table/column names must match `@Table` property names exactly; tables are `STRICT`; PKs are `UUID` (keeps CloudKit reachable).
- Kind strings live in `CaptureKind` / `SourceKind` (`CapturePayloads.swift`) — reuse the constants, don't hardcode.
- Don't use a shared mutable `static` `ISO8601DateFormatter` (Swift 6 concurrency); use a local instance or `Date.ISO8601FormatStyle`.
- **No Python, ever.** Swift only.
- LLM work (Phase 1B): I have a Claude *subscription*, **no API key** — go through an `LLMProvider` protocol whose default shells out to `claude -p`. Stay provider-agnostic.
- **SwiftUI app (`Sources/PensieveApp/`) has no unit tests** — it's an executable target, not covered by `PensieveKitTests`. Verify with `swift build` + a **non-blocking** smoke-launch (background it and `kill` after a few seconds — `swift run PensieveApp` blocks on `app.run()`; never foreground it). Keep derivation logic (bucketing, tree/card building, ranking) in **tested PensieveKit**; keep views thin. App reads are read-only; the only canonical writer is still `Ingester.drain()`.
- **Host the window via `NSHostingController` (contentViewController), not `contentView = NSHostingView`** — otherwise the titlebar safe-area inset isn't propagated and the full-height sidebar scrolls under the traffic-light chrome.

## How we work here

Design-first. For any feature: brainstorm → write a spec/plan under `docs/superpowers/` → execute with review checkpoints (subagent-driven). Surface tradeoffs; keep changes surgical and minimal (YAGNI). Grounded-with-provenance is the north star for the intelligence layer — every AI-surfaced "loose end" must cite real captured text or it doesn't appear.

**Platform primitives first.** Always prefer the first-party / OS-native mechanism over a custom implementation when one exists — SwiftUI `App`/`Scene` lifecycle and `.commands` over a hand-built `NSMenu`, `WindowGroup` window restoration over manual frame autosave, Foundation/AppKit facilities over reinvented equivalents. Reach for a custom path only when the native one is proven insufficient, and say why. This keeps Pensieve idiomatic, small, and durable across OS versions.

## Where to read next

- `docs/superpowers/specs/2026-07-03-pensieve-mvp-design.md` — the approved design (full intent, all phases).
- `docs/superpowers/plans/2026-07-03-pensieve-phase1a-capture-ingest.md` — the executed 1A plan.
- `docs/superpowers/phase-1a-outcome.md` — **what 1A actually shipped + concrete design inputs for Phase 1B** (read this before planning 1B).
