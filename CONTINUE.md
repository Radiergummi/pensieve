# CONTINUE — session handoff (2026-07-06)

Self-contained pickup instructions for a fresh agent. Read `CLAUDE.md` first (project rules), then this.

## Where things stand

Everything below is **merged to `main`** (`a74af56`) and the tree is **clean**. Test suite: **144 tests**, run
with `./scripts/test.sh` (now a thin `swift test` passthrough; plain `swift test` works too). Capture → ingest → **auto-extract**
runs unattended (sync daemon).

**Latest (this session): App Intents foundation + Spotlight (v0.3) — DONE & merged.** The second
OS-integration surface, and the foundation every later App-Intents surface builds on. One `NodeEntity`
(`AppEntity` + `IndexedEntity`) lights up **Spotlight content** (nodes searchable → tap opens the recall
view), a parameterized **Show Pensieve List** intent (What's Next / Dormant / Recently Active) + an **Open
Node** intent → **Siri + Shortcuts + Spotlight actions** via an `AppShortcutsProvider`. Derivation stays in a
tested PensieveKit kernel (`NodeFacts`/`NodeFactsQueries`, active-only + by-id, **read-only** via
`openCanonicalDatabaseReadOnly`); the app-target intents/entity/indexer are thin. Intents run **in-process**,
so `perform()` reuses the shipped `AppDelegate.receive` → `pendingDeepLink` bridge (no new nav path, **no App
Group**). `SpotlightIndexer` = **clear-then-index** of active nodes on launch + ⌘R (not the 3 s timer).
**Deployment target 14 → 15** (for `IndexedEntity`); `Package.swift` stays `.macOS(.v14)` (App-Intents code
is app-target-only). Built subagent-driven in an isolated worktree; per-task reviews clean; **Opus whole-branch
review: READY TO MERGE, 0 Critical / 0 Important** (the `NodeFacts`↔`NextQueries` math parity was explicitly
verified — no divergence). **146 tests.** Spec/plan: `docs/superpowers/{specs,plans}/2026-07-06-app-intents-foundation*`.
- **The one carry for whoever's next — the human OS-integration checks** (can't be asserted headlessly; run
  against the **real** store by a normal `open` of the built app): (1) Spotlight-search a real node's name → tap
  → recall view opens *(also try a word only in its `description` — records whether body matching works on this
  OS; if not, revisit `.content`→`.text` in `NodeEntity.attributeSet`)*; (2) **cold launch** (app fully quit) →
  "Show Pensieve List" from Shortcuts → app foregrounds on the right list; (3) Shortcuts app lists both actions;
  (4) Siri "show my dormant projects in Pensieve"; (5) delete a node → ⌘R → its stale Spotlight entry is gone.
- **Also still open from v0.2:** eyeball the **menu-bar popover** renders (heartbeat + What's Next) and a
  row-click jumps in — the crowded-desktop/accessibility limits here blocked a clean click-through screenshot.

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

**The next OS-integration surface** — the bundle foundation, `pensieve://`, the menu-bar item, **and the
App Intents foundation + Spotlight** are now **done**. The App-Intents entity/intent model is **live** and is
the foundation every later App-Intents surface builds on. Recommended next, each its own spec:
- **Focus filters** (`SetFocusFilterIntent`) — ⭐ **user-flagged high value** (free-time side-project workflow:
  a "Personal" Focus surfacing those strands). Builds **directly** on the App-Intents foundation; deferred out
  of the foundation skeleton because it needs its own filtering model + app-state plumbing. **This is the
  recommended next surface.** → then **Widgets** (WidgetKit extension — the first *second process*, so this is
  where **App Groups / a shared container** get built) → **CloudKit** (entitlements + paid Developer membership).
- **Deeper Spotlight (roadmap):** index loose-end text; **semantic / vector search** (evaluate `sqlite-vec`,
  on-device embeddings `NLContextualEmbedding` / Foundation Models SDK, native Spotlight semantic indexing);
  live/background re-indexing (folds into three-pane slice 3's `ValueObservation` liveness).

Tooling tiers: Focus-filters/Widgets/CloudKit = hard Xcode gates (already adopted). The App-Intents +
Core-Spotlight APIs used here compiled **verbatim** against the SDK — the spec's framework claims held.

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
