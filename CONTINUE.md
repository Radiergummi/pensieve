# CONTINUE — session handoff (2026-07-18)

Self-contained pickup for a fresh agent. Read `CLAUDE.md` first (project rules + the full shipped
changelog in **Status**), then this. **`docs/superpowers/backlog.md`** is the durable long-term list
(Roadmap + deferred ledger with revisit triggers); this file is the per-session handoff.

## Where things stand

Everything is **on `main`**; the tracked tree is clean. **415 tests**, run with `./scripts/test.sh`
(thin `swift test` passthrough). The full loop is **LIVE and dogfooded**: capture → ingest →
auto-extract runs unattended via the bundled background-sync agent; the app is a real `Pensieve.app`
bundle (Xcode/XcodeGen) with the `pensieve` CLI embedded inside it. The core intelligence gate passed
long ago. The hard part is done — remaining work is feature breadth, not foundations.

## Most recent ships (newest first)

Brief — the exhaustive per-feature record lives in `CLAUDE.md` **Status**; deferred follow-ups + human
carries live in the matching `backlog.md` entries.

- **Bundle the `pensieve` CLI into the app** (2026-07-17, through `3a9092c` 2026-07-18). The CLI is now
  an embedded Xcode **tool target** (`PensieveCLI`, `PRODUCT_NAME=pensieve`) at
  `Pensieve.app/Contents/Helpers/pensieve`; `~/.local/bin/pensieve` is an **app-managed symlink** to it,
  auto-created on launch (guarded off `.build`) and installable/repairable/replaceable via **Settings ▸
  General ▸ Command-line tool**. Tested `CLIToolInstaller` kernel. **Updating the app now updates the
  CLI** — the old "rebuild + reinstall the release CLI" step is retired. **`swift run pensieve` no longer
  exists** — build via `xcodebuild -scheme PensieveCLI` (or the app scheme, which embeds it). Spec/plan:
  `{specs,plans}/2026-07-16-bundle-cli-into-app-design.md` + `2026-07-17-bundle-cli-into-app.md`.
- **Background sync via a bundled `SMAppService.agent`** (2026-07-16). Retired the hand-installed
  `com.pensieve.sync` LaunchAgent for a code-signed agent (`me.mazetti.pensieve.sync`) bundled inside the
  app, running the same `SyncRunner` every 300 s independently of the GUI. `BackgroundSyncService`
  (register/unregister/status), guarded off `.build`. **Gotcha:** must run from `/Applications/Pensieve.app`
  (SMAppService pins path + cdhash); `registerIfNeeded()` does unregister+register to survive ad-hoc
  cdhash churn. Approve once in System Settings ▸ Login Items.
- **App Settings v2 + organizing-writes error surfacing** (2026-07-14). Native tabbed Settings
  (**General · Intelligence · Advanced**) over a tested `SystemStatus` kernel; first-party About panel.
  The six organizing writes (create/rename/move/merge/delete + loose-end label) **no longer `try?`-swallow**
  — each classifies into a **refusal** (non-success return = stale state → refresh + gentle alert) or a
  **failure** (a throw → alert, no refresh) via `AppError`/`presentedError` → one `.alert` in `RootView`.
  **This closed Track B.**
- **Archive nodes** (2026-07-14). The escape hatch for stale work `delete` refuses. Archive/unarchive a
  whole subtree; archived nodes leave every normal view into a collapsed **Archived** sidebar section; new
  git/session activity resurfaces the node **and its ancestor chain** (ingest path only).
- **MCP `recall` tool** (2026-07-11). Loose-end-keyed read-only MCP tool → the surrounding transcript
  window via the tested `ProvenanceQueries` kernel (verbatim, inside the trust gate). Closed the
  "pointers, not passages" ceiling that `pensieve mcp` first exposed.

## THE NEXT ACTION — pick a track (each its own brainstorm→spec→plan)

**Track A — the three-pane app (the product spine).** Everything through Share-recall, archive, and
error-surfacing has shipped. Next: **slice 5 (talk-to-system** — describe a strand in natural language →
structured create via `LLMProvider`), then **slice 6 (forks** — gated on the unbuilt fork-capture backend;
brainstorm that backend first). Design: `specs/2026-07-05-pensieve-app-three-pane-design.md`.
**This is the recommended next feature.**

**Track B — DONE.** Both threads shipped: the cloud/API `LLMProvider` (2026-07-09) and organizing-writes
error surfacing (2026-07-14). Nothing open. (Spec 2's deferred source-management GUI + daemon-interval
editing remain parked in `backlog.md`, not part of Track B.)

**Track C — findability / OS-integration.** In-app find (⌘F), the menu-bar item, `pensieve://`, App
Intents + Spotlight, and Focus filters are all live. Remaining, unblocked + sequenced:
- **1b** — index loose-end text into Spotlight (own spec; extend `NodeEntity`/`SpotlightIndexer`).
- **#2** — semantic / vector recall (`sqlite-vec` / on-device embeddings; reuses the in-app-find corpus;
  the grounding caveat — opaque clusters are hard to cite — must be solved).
- Small follow-up: an "include archived" toggle in in-app search (archived nodes are currently only
  reachable via the collapsed Archived section).

**Blocked — do not start:** Widgets + CloudKit need a **paid Apple Developer team** (App Groups / Team-ID
entitlement). That single gate unblocks the whole extension family at once; revisit only when a paid
membership is in hand. See `backlog.md` "Widgets — DEFERRED".

## LIVE deployment state

- **CLI:** bundled inside `Pensieve.app` at `Contents/Helpers/pensieve`; `~/.local/bin/pensieve` is the
  app-managed symlink external callers (git hooks, `~/.claude/settings.json`, `claude mcp add`) resolve.
  Keep `~/.local/bin` on `PATH`. No manual CLI rebuild/reinstall anymore — updating the app updates it.
- **Background sync:** the bundled `SMAppService.agent` `me.mazetti.pensieve.sync`, registered from
  `/Applications/Pensieve.app` (approve once in System Settings ▸ Login Items). Watch:
  `tail -f ~/Library/Logs/Pensieve/sync.log`.
- **Hooks** in `~/.claude/settings.json`: SessionStart (`capture-session-start` + `pensieve prime`) +
  SessionEnd. **MCP:** `pensieve mcp` registered at user scope (`claude mcp get pensieve` → Connected).
- **Real stores:** `~/Library/Application Support/Pensieve/{pensieve,capture}.sqlite`.

## How we work here (follow this exactly)

Design-first, subagent-driven. The proven loop, per feature:
1. `superpowers:brainstorming` → clarify → spec under `docs/superpowers/specs/`.
2. **Adversarial spec review before coding** (new feature/backend): 1–2 independent Opus subagents review
   the spec against the real code; fold findings back in.
3. `superpowers:writing-plans` → task-by-task plan with full code under `docs/superpowers/plans/`.
4. `superpowers:subagent-driven-development` → **isolated git worktree**, fresh ledger at
   `<worktree>/.superpowers/sdd/progress.md`, one implementer + one task-reviewer per task, an **Opus**
   whole-branch review, fix waves, then `superpowers:finishing-a-development-branch` (user merges to main
   locally; then remove the worktree + delete the branch).
- **Model choice:** implementers + task-reviewers = **Sonnet**; whole-branch review = **Opus**. Avoid
  Haiku implementers (they've edited shared/production code to satisfy a test assertion).
- Skill helper scripts: `scripts/task-brief PLAN N [OUT]` and `scripts/review-package BASE HEAD [OUT]`
  under the subagent-driven-development skill dir. Hand subagents **file paths**, not pasted text.
- **App verification is headless-ish:** `xcodebuild` build + a non-blocking smoke-launch of the inner
  binary (`./.build-xcode/Build/Products/Debug/Pensieve.app/Contents/MacOS/Pensieve`, background + `kill`,
  throwaway `PENSIEVE_DB`/`PENSIEVE_CAPTURE_DB`). Interactive layout / OS-integration checks (Spotlight,
  Siri, Focus, Login Items) are the user's to run — the accessibility sandbox blocks scripting them.

## Gotchas

**Process / environment**
- **Work each feature in an isolated `git worktree`** (`git worktree add ../pensieve-<slice> -b feat/<name>`);
  remove on merge. Two efforts in the *same* checkout collided badly once. Confirm no stray `claude`
  process before subagent-driven runs in a shared worktree (a ghost SDD controller once ran a plan in
  parallel — harmless that time, but a reminder).
- Merging a branch that adds files existing **untracked** in the main checkout can abort a fast-forward;
  back the untracked copy aside, then merge.
- **Commit messages: backticks in a double-quoted `git commit -m "..."` get shell-executed** — use
  `git commit -F <heredoc with quoted 'EOF'>`. Keep the `Co-Authored-By:` + `Claude-Session:` trailers.
- **Do NOT set `PENSIEVE_DB` / `PENSIEVE_CAPTURE_DB` when touching the LIVE store.** App/CLI smoke tests
  SHOULD set them (to a `/tmp` path) to avoid perturbing real data.
- The app **must run from `/Applications/Pensieve.app`** for SMAppService — `rm -rf .build-xcode` would
  delete a registered bundle. `xcodebuild` + SPM macros: first build on a fresh machine needs the macro
  fingerprints trusted (Xcode "Trust & Enable", or the two `defaults write …IDESkip{PackagePlugin,Macro}
  FingerprintValidation` per-machine flags).
- On a SwiftSyntax/macro **linker error**, `rm -rf .build` and retry (recurs intermittently).
- **Stray build artifacts** currently sit untracked in the repo root (`BackgroundSyncGuard-2.{d,dia,
  swiftdeps,swiftmodule}`, `StoreOpen-2.*`, `SyncAgentEnvironment-2.*`, `SyncLog-2.*`) plus a modified
  `eval-config.json`. Noise from an out-of-tree build; safe to clean, but out of scope for a docs pass.

**Swift / SwiftUI**
- Predicates: `.eq(x)` NOT `== x`. Reuse `SourceKind`/`CaptureKind` constants. No shared mutable
  `static ISO8601DateFormatter` (Swift 6).
- **The app (`Sources/PensieveApp/`) has no unit tests** — put derivation logic in tested PensieveKit,
  keep views thin. App reads are read-only; the only canonical writer is `Ingester.drain()`.
- **The app is built by XcodeGen + Xcode** (`project.yml` is the source of truth; single SwiftUI `Window`
  scene). Build: `xcodegen generate` → `xcodebuild -project Pensieve.xcodeproj -scheme Pensieve
  -configuration Debug -derivedDataPath ./.build-xcode build`; app at
  `./.build-xcode/Build/Products/Debug/Pensieve.app`. `Pensieve.xcodeproj/` + `.build-xcode/` are
  gitignored. Prefer first-party primitives (`.commands`, scene restoration) — see "Platform primitives
  first" in `CLAUDE.md`.
- Foundation Models (on-device) is the default extractor; `claude -p` is the fallback (no API key). Cloud
  serves narration only; **extraction always stays on-device** (trust gate).

## Long-term vision (don't lose this)

The full, still-intended vision — none foreclosed — lives in `docs/superpowers/backlog.md` (Roadmap +
deferred ledger) and `docs/superpowers/specs/2026-07-03-pensieve-mvp-design.md`. Pillars beyond today:
CloudKit sync + iOS companion; more OS-integration surfaces (widgets, deeper Spotlight/semantic search,
Siri/Shortcuts depth); FSEvents real-time capture; additional non-git source types (Notion, Entra,
browser); analytics (dependency graphs, token-spend). Forward ideas: **forks as first-class**, **talk to
the system** (slice 5), statistical **theme discovery**, proactive project suggestion.

North star throughout: **grounded-with-provenance** — every AI-surfaced item cites real captured text or
it doesn't appear. The trust gate is sacred; the capture path must never block a git commit.
