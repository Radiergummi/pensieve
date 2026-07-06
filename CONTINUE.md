# CONTINUE — session handoff (2026-07-06)

Self-contained pickup instructions for a fresh agent. Read `CLAUDE.md` first (project rules), then this.

## Where things stand

Everything below is **merged to `main`** (`a74af56`) and the tree is **clean**. Test suite: **144 tests**, run
with `./scripts/test.sh` (now a thin `swift test` passthrough; plain `swift test` works too). Capture → ingest → **auto-extract**
runs unattended (sync daemon).

**Latest (this session): Menu-bar item + `pensieve://` deep links (v0.2) — DONE & merged.** The first
OS-integration surface: a `MenuBarExtra` `.window` popover in the *same* app (capture heartbeat over
`MonitorSnapshot` + top-5 What's Next over `SmartLists`; status by glyph shape; click-to-jump), plus a
tested `DeepLink` router (`Sources/PensieveKit/Support/DeepLink.swift`) for the registered `pensieve://`
scheme. Internal clicks navigate **in-process** via `applyDeepLink`; external `pensieve://` opens go through an
`NSApplicationDelegateAdaptor` → `pendingDeepLink` → the always-mounted `MenuBarExtra` label's `.onChange` →
the existing `PaletteDestination.apply(to:)`. Scheme registered via an **XcodeGen-managed Info.plist**
(`GENERATE_INFOPLIST_FILE` off; version/icon/name keys re-declared, verified by plist diff). **Additive only**
(dock + Window untouched). Spec/plan: `docs/superpowers/{specs,plans}/2026-07-06-menu-bar-deeplinks*`.
- **Two carries for whoever's next:** (1) a quick **pending-human visual check** — build the app and eyeball
  that the popover renders (heartbeat + What's Next) and a row-click jumps into the window; I proved C1 (an
  external `pensieve://` fronts the app) but the crowded-desktop + accessibility limits here blocked a clean
  click-through screenshot. (2) Launch Services currently points `pensieve://` at a removed worktree build
  path — a fresh `xcodegen generate && xcodebuild …` from `main` re-registers it at the real path.

Shipped and merged (all on `main`):
- **Phase 1A / 1B / 1B-org** — capture→ingest→query, the intelligence layer (grounded, cited loose ends;
  the make-or-break precision gate PASSED), the typed tree & strands.
- **Sync daemon — LIVE** — `pensieve sync`, `SessionEnd` hook, `com.pensieve.sync` launchd agent (every 300 s).
- **Source discovery** — `pensieve scan <folder> [--recursive] [--accept]`.
- **Pensieve.app three-pane — slices 1 & 2** — read-only three-pane `NavigationSplitView` (action-first sidebar,
  middle list, detail recall view with inline verbatim provenance); **Briefing** home (by-project "since last
  visit" world map; `lastOpenedAt` in UserDefaults) + **⌘K** navigation-only palette.
- **Pensieve.app GUI base-state (this session)** — migrated the imperative `NSApplication`/`NSWindow`/
  `NSHostingController` bootstrap to the first-party **SwiftUI `App` lifecycle** (single `Window` scene):
  standard menu bar + ⌘Q/⌘W/⌘M, window default/min size, automatic scene frame restoration. Menu `.commands`:
  **View ▸ Show/Hide Sidebar** (`SidebarCommands`), **Go ▸ Quick Jump** (⌘K, palette state hoisted from a hidden
  button onto `AppModel`), **Go ▸ Refresh** (⌘R → `AppModel.refreshNow()`). **Runtime Dock icon** via
  `NSApplication.applicationIconImage` (artwork committed under `icons/`). **Bug found + fixed in verification:**
  an unbundled SwiftPM executable needed an explicit `setActivationPolicy(.regular)` in an `AppDelegate`
  (both since removed by the Xcode-adoption bundle, which is `.regular` by default). Spec/plan under
  `docs/superpowers/{specs,plans}/2026-07-05-pensieve-app-gui-base-state*`. Subagent-driven, review-clean
  (Opus whole-branch: ready-to-merge, 0 Critical/Important).

## Xcode adoption — DONE

The app is now a real **`Pensieve.app`** bundle: **XcodeGen** (`project.yml`, the source of truth) + Xcode
26.6 (active — `xcode-select` → `/Applications/Xcode.app`), app target linking **PensieveKit as a local
SwiftPM package**, ad-hoc signed, bundled `icons/Pensieve.icon` via `actool`, `CFBundleName=Pensieve`. The
unbundled workarounds (setActivationPolicy, runtime applicationIconImage, AppDelegate) are gone. Build:
`xcodegen generate` → `xcodebuild -project Pensieve.xcodeproj -scheme Pensieve -configuration Debug
-derivedDataPath ./.build-xcode build`; app at `./.build-xcode/Build/Products/Debug/Pensieve.app`; smoke-launch
the inner binary (`…/Contents/MacOS/Pensieve`). `Pensieve.xcodeproj/` + `.build-xcode/` are gitignored.
`swift test` now works natively (`scripts/test.sh` is a thin passthrough). The `pensieve` CLI + daemon are
unchanged — no reinstall needed.

## THE NEXT ACTION (start here)

**The next OS-integration surface** — the bundle foundation **and** the first surface (menu-bar item +
`pensieve://`) are now **done**; the `pensieve://` scheme is **live** as the entry point every later surface
links back through. Remaining surfaces, each its own spec, roughly in tooling-cost order:
- **Spotlight** (Core Spotlight) → **App Intents skeleton** (one build lights up Siri + Shortcuts + Spotlight
  actions + Focus filters) → **Widgets** (WidgetKit extension, Xcode-gated) → **CloudKit** (entitlements + paid
  Developer membership). *Recommendation:* Spotlight or the App Intents skeleton next — both extend the grounded
  glance and reuse `pensieve://` for jump-in. Widgets/CloudKit also want **App Groups / a shared container** (so
  an extension process reads one store) — build that with the first surface that needs a second process.

Tooling tiers to carry into the next surface spec: Spotlight = Command-Line-Tools-friendly;
App-Intents/Widgets/CloudKit = hard Xcode gates.

> **The durable index of *all* pending work** (every pillar needing brainstorm→spec→plan, plus the parked
> depth-features and forward ideas with their revisit triggers) lives in **`docs/superpowers/backlog.md`**
> ("Roadmap" + the deferred ledger). This CONTINUE file is the per-session handoff; the backlog is the
> long-term list. Kept current as of 2026-07-06 (menu-bar item + `pensieve://` shipped).

**Also queued (three-pane app slices 3–6, per `specs/2026-07-05-pensieve-app-three-pane-design.md`):**
- **3 — inspector + polish:** ⌘⌥I provenance inspector; **LLM "Last Work Done" narration** (via `SummaryBuilder`,
  the deterministic "Recent Activity" list is the current stand-in); `ValueObservation` liveness (replacing the
  3 s `Timer`).
- **4** in-app organizing writes; **5** talk-to-system (describe→create strand); **6** forks surface (gated on
  the unbuilt fork-capture backend — brainstorm that backend first).

Two cheap carries to fold in when convenient (from slice-2 reviews):
- Key `pensieve.lastOpenedAt` per DB path so throwaway-store smoke/test launches don't perturb "since last visit."
- A shared per-node "latest event + days-dormant + open-loose-end-count" helper (recurs in `NextQueries`,
  `MonitorSnapshot`, `BriefingQueries`).

## LIVE deployment state (unchanged)

The GUI base-state slice touched **only the `PensieveApp` target** — the CLI/daemon are untouched, so **no
rebuild/reinstall of `~/.local/bin/pensieve` was needed.** Still running:
- `~/.local/bin/pensieve` = the release CLI the launchd plist runs. Rebuild + reinstall to this path
  (`swift build -c release` → copy → `pensieve install-daemon`) only when you land **daemon-adjacent** changes.
- Hooks in `~/.claude/settings.json`: SessionStart (`capture-session-start`, matcher `startup`) + SessionEnd.
- LaunchAgent `com.pensieve.sync` bootstrapped in `gui/501`. Watch: `tail -f ~/Library/Logs/Pensieve/sync.log`.
- Real stores: `~/Library/Application Support/Pensieve/{pensieve,capture}.sqlite`.

## How we work here (follow this exactly)

Design-first, subagent-driven. The proven loop, per feature:
1. `superpowers:brainstorming` → clarify → spec under `docs/superpowers/specs/`.
2. **Adversarial spec review before coding** (for a new feature/backend): 1–2 independent opus subagents review
   the spec against the real code. Fold findings back in.
3. `superpowers:writing-plans` → task-by-task plan with full code + steps under `docs/superpowers/plans/`.
4. `superpowers:subagent-driven-development` → **isolated git worktree**, fresh ledger at
   `<worktree>/.superpowers/sdd/progress.md`, one implementer per task, a task-reviewer per task, an **Opus**
   whole-branch review, fix waves, then `superpowers:finishing-a-development-branch` (user chooses "merge to main
   locally"; then remove the worktree + delete the branch).
- **Model choice:** implementers + task-reviewers = **Sonnet**; final whole-branch review = **Opus**. Avoid Haiku
  implementers (they've modified shared/production code to satisfy a test assertion).
- Skill helper scripts: `scripts/task-brief PLAN N [OUT]` and `scripts/review-package BASE HEAD [OUT]` under the
  subagent-driven-development skill dir. Hand subagents **file paths**, not pasted text.
- **New this session — the app is GUI-verifiable headlessly-ish:** launch the built binary in the background with
  throwaway `PENSIEVE_DB`/`PENSIEVE_CAPTURE_DB`, then `screencapture -x -o <png>` to grab the screen, and
  `osascript … set frontmost` / `name of first process whose frontmost is true` to check activation. Caught the
  activation-policy bug this way. Caveat: the user's Dock is auto-hidden, so full-screen grabs don't show the
  Dock tile — that pixel check stays a human item.

## Gotchas

**Process / environment**
- **Work each feature in an isolated `git worktree`** (`git worktree add ../pensieve-<slice> -b feat/<name>`).
  Remove on merge (`git worktree remove --force <path>`). Two efforts in the *same* checkout collided badly once.
- Merging a branch that adds files which exist **untracked** in the main checkout (e.g. `icons/`) can abort a
  fast-forward ("untracked working tree files would be overwritten"). Back the untracked copy aside, then merge.
- **Commit messages: backticks in a double-quoted `git commit -m "..."` get shell-executed** — use
  `git commit -F <heredoc with quoted 'EOF'>`. Keep the `Co-Authored-By:` + `Claude-Session:` trailers.
- **Do NOT set `PENSIEVE_DB` / `PENSIEVE_CAPTURE_DB` when touching the LIVE store** — those point at throwaway
  stores. App/CLI smoke tests SHOULD set them (to a `/tmp` path) to avoid perturbing real data.
- **`install-daemon` / `install-session-hook` bake in `Bundle.main.executablePath`** — run from
  `~/.local/bin/pensieve`, NEVER from `.build`.
- On a SwiftSyntax/macro **linker error**, `rm -rf .build` and retry (recurs intermittently; disk has headroom
  now, ~44 GB free).
- **`xcodebuild` + SPM macros:** first build on a fresh machine needs the macro fingerprints trusted (Xcode "Trust & Enable", or `defaults write com.apple.dt.Xcode IDESkip{PackagePlugin,Macro}FingerprintValidation -bool YES`) — a per-machine setting, not in the repo.

**Swift / SwiftUI**
- Predicates: `.eq(x)` NOT `== x`. Reuse `SourceKind`/`CaptureKind` constants. No shared mutable
  `static ISO8601DateFormatter` (Swift 6).
- **The app (`Sources/PensieveApp/`) has no unit tests** — verify with an `xcodebuild` build + a **non-blocking**
  smoke-launch of the inner binary (`./.build-xcode/Build/Products/Debug/Pensieve.app/Contents/MacOS/Pensieve`,
  background + `kill`; forward throwaway `PENSIEVE_DB`/`PENSIEVE_CAPTURE_DB`). Put derivation logic in tested
  PensieveKit; keep views thin.
- **The app is a real `.app` bundle built by XcodeGen + Xcode** (`project.yml` is the source of truth; single
  SwiftUI `Window` scene). Build: `xcodegen generate` → `xcodebuild -project Pensieve.xcodeproj -scheme Pensieve
  -configuration Debug -derivedDataPath ./.build-xcode build`. The bundle is `.regular` by default (no
  `setActivationPolicy` workaround) and its icon is the bundled `icons/Pensieve.icon` compiled by `actool` (no
  runtime `applicationIconImage`). Prefer first-party primitives (`.commands`, scene restoration) — see the
  "Platform primitives first" principle in `CLAUDE.md`.
- Foundation Models (on-device) is the default extractor; `claude -p` is the fallback (no API key).

## Long-term vision (don't lose this)

The full, still-intended vision — none foreclosed — lives in **`docs/superpowers/backlog.md`** (Roadmap + deferred
ledger) and **`docs/superpowers/specs/2026-07-03-pensieve-mvp-design.md`**. Pillars beyond the base app:
menu-bar + `LSUIElement` bundle; resident `pensieved` `SMAppService` (the launchd sync daemon already covers
auto-flow); **CloudKit sync + iOS companion**; system-integration surfaces (widgets, Siri/Shortcuts, Spotlight —
all read-only glances that must share the grounded query kernel, never re-derive); FSEvents real-time monitoring;
additional non-git source types (Notion, Entra, browser); analytics (dependency graphs, token-spend). Forward
ideas: **forks as first-class**, **talk to the system**, statistical **theme discovery** (`NLEmbedding`),
proactive project suggestion, native **localization** (chrome only, never captured content).

North star throughout: **grounded-with-provenance** — every AI-surfaced item cites real captured text or it
doesn't appear. The trust gate is sacred; the capture path must never block a git commit.
