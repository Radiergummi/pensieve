# CONTINUE — session handoff (2026-07-06)

Self-contained pickup instructions for a fresh agent. Read `CLAUDE.md` first (project rules), then this.

## Where things stand

Everything below is **on `main`** (HEAD `802e215`) and the tree is clean. Test suite: **173 tests**, run with
`./scripts/test.sh` (thin `swift test` passthrough). Capture → ingest → **auto-extract** runs unattended (sync
daemon).

**Latest (this session): Pensieve.app localization (String Catalog + German) — DONE & on `main`.** First-party
Xcode **String Catalog** (`Sources/PensieveApp/Localizable.xcstrings`, English base + German `de`, 44 keys)
localizing **all app UI chrome**, impersonal/infinitive German; wired via `project.yml`
(`options.developmentLanguage`/`knownRegions [en,de]`, `CFBundleLocalizations`, `SWIFT_EMIT_LOC_STRINGS`).
**Chrome only** — content (node names, quotes, descriptions, event summaries, roles, transcripts) never
localized; content-mixed frames + proper names ("Pensieve"/"Briefing") stay English-fallback. **Gotcha:**
`xcodebuild … build` does NOT auto-populate the source `.xcstrings` (IDE-only) — keys were reconciled by hand
against the Swift literals (`%lld`/`%@`). Subagent-driven (Sonnet implementers/task-reviewers, **Opus**
whole-branch review = READY-TO-MERGE, 0 findings). **Out of scope / deferred follow-up:** App Intents / Siri /
Shortcuts phrases + the `pensieve` CLI. **Human-verify carry:** native-speaker in-situ tone pass (open the built
app under the real macOS German language; e.g. "Moved→Bewegt", "capturing→erfasst" read literally). Spec/plan:
`docs/superpowers/{specs,plans}/2026-07-06-app-localization-german*`.

**Next up — three-pane slice 4 (in-app organizing writes): design already brainstormed this session, needs its
own spec/plan.** Agreed shape: **context menus + inline rename** (New Child / Rename / Change Type ▸ / Move to… /
Merge into… on tree + middle-list rows; toolbar "+" for a top-level node); **all five ops incl. destructive
merge** with a confirmation dialog. Two load-bearing PensieveKit changes (with tests): a **write-side walk-to-root
cycle guard in `NodeCommands.nest`** (currently absent — nesting under a descendant would create a cycle), and
**fix the latent `ProjectResolver.group` self-cycle bug** (merging a parent into its own child leaves the child
pointing at itself). App write path: `AppModel` already holds a read/write `db` + one shared model across all
windows; organizing methods call the ops then `refresh()` explicitly (Node-only writes don't trip the
Event-count `ValueObservation`); Move/Merge pickers filter out self + descendants (UI-level guard on top of the
write guard). Single-writer principle untouched (it governs *event ingestion*, not organizing metadata).

**Latest (this session): three-pane slice 3b — liveness · inspector · recall windows — DONE & on `main`.** Four
parts, subagent-driven, review-clean. **(1) `ProvenanceContext` kernel** (tested PensieveKit, read-only): loose
end → source `cc.session` event → **surrounding transcript context**, with a two-part guard (`isUserPrompt`
**and** the cited message still contains the stored `quote`) so a stale/compacted index never highlights the
wrong message; degrades honestly (`transcriptAvailable == false` → stored quote + accurate note, never a
fabrication). **(2) ⌘⌥I inspector**: `.inspector` panel (cited highlighted, machine-envelope messages dimmed);
`DetailView` gained `allowsInspector: Bool` gating the shared `AppModel.inspectedLooseEndID` write, which clears
on `selectedNodeID` change — together they prevent cross-window contamination. **(3) Recall
`WindowGroup(for: UUID.self)`** (⌘⌥N): focused single-node window reusing `DetailView(allowsInspector: false)`,
**strictly additive** so the `pensieve://`/App-Intents deep-link bridge is untouched; + a `SmartListKind.color`
sidebar polish. **(4) Liveness**: retired the 3 s `Timer` for `ValueObservation` + two directory `FSEventStream`
watches (spool + canonical, incl. `-wal`) coalesced via a tested actor `Debouncer` (~150 ms), app-lifetime;
canonical busy `.timeout`; Spotlight reindex on the debounced refresh. Reviews: **two adversarial spec reviews**
(spool-`-wal` watch, app-lifetime teardown, `isUserPrompt` guard, shared-state fix, `ValueObservation`
redundancy) **+ per-task reviews** (caught InspectorView stale-render race + flaky timing tests → deterministic
injectable-sleep `Debouncer` tests) **+ Opus whole-branch review** (READY-TO-MERGE, 0 Critical/Important; traced
the self-drain echo → converges). Spec/plan:
`docs/superpowers/{specs,plans}/2026-07-06-three-pane-slice3b-liveness-inspector-windowing*`.
- **Human-verify carries** (need the built app; can't be asserted headlessly): select a loose end → ⌘⌥I shows the
  surrounding transcript (cited highlighted, non-user dimmed), and a loose end whose transcript is gone shows the
  honest fallback caption; ⌘⌥N opens a recall window on the selected node, a loose-end tap there does **not** move
  the main inspector, a 2nd recall window keeps its own node; a new commit/session appears **without ⌘R** and the
  menu-bar glyph updates on real activity; and **eyeball idle CPU / `sync.log`** for a few seconds after activity
  settles to confirm the app is quiet (self-drain echo is bounded but has no unit test). Build: `xcodegen generate
  && xcodebuild -project Pensieve.xcodeproj -scheme Pensieve -configuration Debug -derivedDataPath ./.build-xcode
  build`, then `open ./.build-xcode/Build/Products/Debug/Pensieve.app`.
- **Deferred Minors** (from reviews, none blocking): the `.inspector` content closure calls `model.detail(for:)`
  inline (re-runs on RootView body eval while shown — mildly amplified by liveness); `RecallWindowView` looks up
  `model.node(nodeID)` twice per body eval; `DirectoryWatcher` uses `Unmanaged.passUnretained` + `deinit`-only
  teardown (safe only because watchers are app-lifetime). ⌘⌥N reads the *main* window's selection.

**Prior this session: three-pane slice 3a — LLM "Last Work Done" narration — DONE & merged.** The app's **first
LLM call**: `DetailView` shows a grounded on-device prose recap above Loose Ends (`SummaryBuilder.narrate → nil`
on no-events/failure — best-effort, outside the cited trust gate). Spec/plan:
`docs/superpowers/{specs,plans}/2026-07-06-three-pane-slice3a-last-work-done*`.
- **Earlier this session (also merged): App Intents foundation + Spotlight (v0.3)** — `NodeEntity`
  (`AppEntity`+`IndexedEntity`) → Spotlight content + Siri/Shortcuts/Spotlight actions; on-device, in-process,
  reuses the `pensieve://` bridge; target bumped 14→15 for `IndexedEntity`. Its human OS-integration checks
  (real Spotlight hit, Siri phrase, Shortcuts, cold-launch) are still yours to run. Spec/plan:
  `docs/superpowers/{specs,plans}/2026-07-06-app-intents-foundation*`.
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

**Two live tracks — pick per appetite** (each its own brainstorm→spec→plan):

**Track A — the three-pane app** (the product spine). Slices 3a (LLM narration) **and 3b (liveness · inspector ·
recall windows) just shipped. Next: slice 4 (in-app organizing writes** — create/`nest`/`group`/`rename`/`retype`
via existing PensieveKit ops, with the walk-to-root cycle guard). Then 5 (talk-to-system), 6 (forks,
backend-gated). Design: `specs/2026-07-05-pensieve-app-three-pane-design.md`. *(Live/background Spotlight
re-indexing that slice 3 promised now rides the slice-3b liveness `refresh` debounce — done.)*

**Track B — the next OS-integration surface.** The bundle foundation, `pensieve://`, the menu-bar item, **and
the App Intents foundation + Spotlight** are done; the App-Intents entity/intent model is **live** as the
foundation later surfaces build on. Recommended:
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
