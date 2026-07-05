# CONTINUE — session handoff (2026-07-05)

Self-contained pickup instructions for a fresh agent. Read `CLAUDE.md` first (project rules), then this.

## Where things stand

Everything below is **merged to `main`** (`b465d22`) and the tree is **clean** (only this untracked
`CONTINUE.md`). Test suite: **138 tests**, run with `./scripts/test.sh` (NOT `swift test` — this machine is
Command Line Tools–only). Capture → ingest → **auto-extract** runs unattended (sync daemon, below).

Shipped and merged (all on `main`):
- **Phase 1A / 1B / 1B-org** — capture→ingest→query, the intelligence layer (grounded, cited loose ends;
  the make-or-break precision gate PASSED), the typed tree & strands.
- **Sync daemon — LIVE** — `pensieve sync` (drain → `TranscriptDiscovery` → drain → incremental
  `ExtractionRunner`), `SessionEnd` capture hook, and the `com.pensieve.sync` launchd agent
  (`install-daemon`). Closes the manual-ingest gap; runs every 300 s.
- **Source discovery** — `pensieve scan <folder> [--recursive] [--accept]`.
- **Pensieve.app v0.1 heartbeat** — superseded by the three-pane app; its `MonitorSnapshot` kernel lives on
  as the sidebar status footer.
- **Pensieve.app three-pane — slices 1 & 2** (this session's work):
  - **Slice 1 (read-only core):** `swift run PensieveApp` opens a three-pane `NavigationSplitView` —
    action-first sidebar (Briefing + What's Next / Dormant / Recently Active smart lists + the typed node
    tree), a middle node list, and a detail recall view (What It Is / Loose Ends with **inline verbatim
    provenance** / Recent Activity). Drains the spool on launch. `NodeForest` + `SmartLists` are tested
    PensieveKit helpers; the SwiftUI layer is thin. Window hosted via `NSHostingController`.
  - **Slice 2 (Briefing + ⌘K):** the **Briefing** home is the default landing — a by-project "since last
    visit" world map (tested `BriefingQueries`; `lastOpenedAt` persisted in **UserDefaults**, never the
    canonical store). **⌘K** opens a **navigation-only** command palette (fuzzy-jump to any
    project/strand/smart-list/Briefing).

## LIVE deployment state (unchanged, still running)

The sync daemon is **installed and running on this machine**:
- `~/.local/bin/pensieve` = the release CLI the launchd plist runs. **Rebuild + reinstall to this path**
  (`swift build -c release` → copy → `pensieve install-daemon`) whenever you land daemon-adjacent changes.
- Hooks in `~/.claude/settings.json`: Pensieve SessionStart (`capture-session-start`, matcher `startup`) +
  SessionEnd (`capture-session-end`, matcher `""`), alongside the user's own hooks.
- LaunchAgent `com.pensieve.sync` bootstrapped in `gui/501`; steady-state incremental run is **sub-second**.
  Watch: `tail -f ~/Library/Logs/Pensieve/sync.log`. Remove: `pensieve install-daemon --uninstall`.
- Real stores: `~/Library/Application Support/Pensieve/{pensieve,capture}.sqlite`.

## THE NEXT ACTION (start here)

Continue the three-pane app: **slice 3** of the build sequence in
`docs/superpowers/specs/2026-07-05-pensieve-app-three-pane-design.md`.

Remaining app slices (each its own plan; slices 1–2 done):
- **3 — inspector + polish:** ⌘⌥I provenance inspector (full quote + surrounding transcript); window tabbing /
  open-in-new-window; light/dark + materials pass; **LLM "Last Work Done" narration** (via `SummaryBuilder`,
  deferred from slice 1 — the deterministic "Recent Activity" list is the current stand-in); upgrade liveness
  from the 3 s `Timer` to GRDB `ValueObservation`.
- **4 — in-app organizing writes** (create / `nest` / `group` / `rename` / `retype`, via existing PensieveKit
  ops + the cycle guard).
- **5 — talk-to-system stage 1** (describe a strand → structured create).
- **6 — forks surface** (ancestry trail + siblings + "Roads Not Taken" list) — **gated on the unbuilt
  fork-capture backend** (see backlog "Forks as first-class"; brainstorm that backend on its own first).

Two cheap carries to fold in when convenient (from slice-2 reviews):
- Key `pensieve.lastOpenedAt` per DB path so throwaway-store smoke/test launches don't perturb the real
  "since last visit."
- A shared per-node "latest event + days-dormant + open-loose-end-count" helper — that shape now recurs in
  `NextQueries`, `MonitorSnapshot`, and `BriefingQueries`.

## How we work here (follow this exactly)

Design-first, subagent-driven. The proven loop, per feature:
1. `superpowers:brainstorming` → clarify (the app design already exists; for a sub-slice, confirm the 1–2 real
   decisions, then go straight to a plan) → spec under `docs/superpowers/specs/`.
2. **Adversarial spec review before coding** (for a new feature/backend): spawn 1–2 independent opus subagents
   to review the spec against the real code. Has caught a Critical flaw in most specs. Fold findings back in.
3. `superpowers:writing-plans` → task-by-task plan with full code + TDD steps under `docs/superpowers/plans/`.
4. `superpowers:subagent-driven-development` → **work in an isolated git worktree** (see gotcha below), fresh
   ledger at `<worktree>/.superpowers/sdd/progress.md`, one implementer per task, a task-reviewer per task, an
   **Opus** whole-branch review, fix waves, then `superpowers:finishing-a-development-branch` (user chooses
   "merge to main locally" each time; then remove the worktree + delete the branch).
- **Model choice:** implementers + task-reviewers = **Sonnet**; final whole-branch review = **Opus**. Avoid
  Haiku implementers — they have repeatedly modified shared/production code to satisfy a test assertion.
- Skill helper scripts: `scripts/task-brief PLAN N [OUT]` and `scripts/review-package BASE HEAD [OUT]` under
  the subagent-driven-development skill dir. Hand subagents **file paths**, not pasted text.
- Keep the ledger updated (it survives compaction; trust it + `git log` over memory after a compaction).

## Gotchas

**Process / environment**
- **Work each feature in an isolated `git worktree`** (`git worktree add ../pensieve-<slice> -b feat/<name>`).
  Learned the hard way this session: running two efforts in the *same* checkout collided — a collaborator's
  commit landed on the wrong branch, and the SDD scratch (`.superpowers/sdd/task-N-brief.md`, `progress.md`)
  clobbered each other. A worktree gives a separate checkout + `.build` + scratch. Remove it on merge
  (`git worktree remove --force <path>`).
- **Commit messages: backticks in a double-quoted `git commit -m "..."` get shell-executed** — use
  `git commit -F <heredoc with quoted 'EOF'>` or single quotes. Keep the `Co-Authored-By:` + `Claude-Session:`
  trailers.
- **Do NOT set `PENSIEVE_DB` / `PENSIEVE_CAPTURE_DB` when touching the LIVE store** — those overrides point at
  throwaway stores. App/CLI smoke tests should set them (to a `/tmp` path) to avoid perturbing real data.
- **`install-daemon` / `install-session-hook` bake in `Bundle.main.executablePath`** — run from
  `~/.local/bin/pensieve`, NEVER from `.build` (`install-daemon` refuses a `.build` path).
- On a SwiftSyntax/macro **linker error**, `rm -rf .build` and retry (disk runs tight — ~90% full).

**Swift / SwiftUI**
- Predicates: `.eq(x)` NOT `== x`. Reuse `SourceKind`/`CaptureKind` constants. No shared mutable
  `static ISO8601DateFormatter` (Swift 6).
- **The app target (`Sources/PensieveApp/`) has no unit tests** — verify with `swift build` + a **non-blocking**
  smoke-launch (background + `kill`; `swift run` blocks on `app.run()`). Put derivation logic in tested
  PensieveKit; keep views thin.
- **Host the window via `NSHostingController`**, not `contentView = NSHostingView` (titlebar safe-area).
- Naming/type traps hit while building the app (fixed, but watch for the pattern): `NodeTree` was already an
  enum in `NodeCommands.swift` (the CLI tree *renderer*) — the app's forest builder is `NodeForest`. Plain
  `public struct`s (`SmartLists`, `ProjectStatus`) need an **explicit `public init`** to be constructed from
  the `PensieveApp` module. `OutlineGroup(_:children:)` needs an **optional** children keypath (nil = leaf) —
  hence the `childrenIfAny` adapter. `LooseEndQueries.open` takes `any DatabaseWriter`, so you can't call it
  inside a `db.read { db in … }` (that `db` is a `Database`) — collect first, fetch loose ends after.
- Foundation Models (on-device) is the default extractor; `claude -p` is the fallback (no API key).

## Long-term vision (don't lose this)

The three-pane app is **roadmap pillar #2** of the finished product. The full, still-intended vision — none of
it foreclosed — lives in **`docs/superpowers/backlog.md` (the "Roadmap" section + the deferred ledger)** and
**`docs/superpowers/specs/2026-07-03-pensieve-mvp-design.md`** (the approved all-phases design). In brief, the
pillars beyond the app slices:

- **Menu-bar item + `LSUIElement` bundle** (v0.2 packaging; the heartbeat window's next step).
- **Resident `pensieved` `SMAppService`** (a convenience upgrade — the launchd sync daemon already delivers
  auto-flow).
- **CloudKit sync + iOS companion** (SQLiteData's opt-in `SyncEngine`; on-ramp preserved, unbuilt).
- **System-integration surfaces** — widgets / Lock-Screen, Siri / Shortcuts, Spotlight. All read-only glance
  surfaces that must **share the same grounded query kernel** (`MonitorSnapshot`/`next`), never re-derive.
- **FSEvents real-time monitoring** (replace interval polling; pure latency win).
- **Additional source types** — Notion, Entra, browser work (the model already allows non-git sources; needs
  the deferred per-kind ingestion-handler protocol at the 4th type).
- **Analytics** — cross-project dependency graphs, dashboards, token-spend.

Forward feature ideas captured in the backlog: **forks as first-class** (capture decision points; walk back
ancestry; rescue strands orphaned at a fork — a fork canvas power-view is parked there too), **talk to the
system** (stage 1 = describe→create strand; stage 2 = a full chat agent, deferred late), statistical
**theme discovery** across strands (`NLEmbedding`), proactively suggesting implicitly-learned projects, and
native de/en **localization** (chrome only, never captured content).

North star throughout: **grounded-with-provenance** — every AI-surfaced item cites real captured text or it
doesn't appear. The trust gate is sacred; the capture path must never block a git commit.
