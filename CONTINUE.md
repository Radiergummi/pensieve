# CONTINUE — session handoff (2026-07-08)

Self-contained pickup instructions for a fresh agent. Read `CLAUDE.md` first (project rules), then this.

## Where things stand

Everything below is **on `main`** (HEAD `90348db`) and the tree is clean. Test suite: **211 tests**, run with
`./scripts/test.sh` (thin `swift test` passthrough). Capture → ingest → **auto-extract** runs unattended (sync
daemon).

**Latest (this session): Share a node's recall — DONE & on `main`.** A Share action renders a node's recall as
an **English Markdown snapshot** and hands it to the macOS share sheet (SwiftUI `ShareLink`) + copy/paste, from
the **detail toolbar** (and the ⌘⌥N recall window, inherited) and a **"Share Recall…" node context-menu** item.
**Summaries only — verbatim provenance quotes never leave the device** (grounded summaries, not fabrication;
trust gate untouched). One tested **pure** PensieveKit builder `RecallMarkdown.render` (no DB/LLM/localization;
fixed English headers, capitalized kind/state, `yyyy-MM-dd`; a test asserts the quote never appears) + thin app
wiring (`AppModel.recallMarkdown(for:)` reuses `detail(for:)`; toolbar `ShareLink` builds from `DetailView`
`@State`, no DB in `body`; context-menu `ShareLink` lazy on menu-open). Narration included only if **already
cached** (a share never blocks on an LLM call). German for the one new label (`"Share Recall…"` →
`"Rückblick teilen…"`); the export stays English. Subagent-driven (3 tasks: Sonnet impl+task-review; **Opus**
whole-branch READY-TO-MERGE, 0 Critical/Important). **211 tests** (+6 Kit). No entitlement/schema/capture change.
Spec/plan: `docs/superpowers/{specs,plans}/2026-07-08-share-node-recall*`.
- **Deferred (not foreclosed):** file export (Save panel), a "Share with provenance (quotes)" opt-in, a
  shareable link (needs CloudKit → paid team), subtree recall. **Deferred Minors:** whitespace-only
  narration/description → blank-looking section (upstream-gated); a one-frame ⌘R/node-switch transient where a
  Share tap could omit a recap the screen still shows (bounded by one LLM call; best-effort in the export).
- **Human-verify carries** (need the built app + real store + `open`): the detail-toolbar Share button opens the
  share sheet with the recall as Markdown (title, `*Kind · State*`, Last Work Done if present, Loose Ends,
  Recent Activity, footer); the ⌘⌥N recall window also shows Share; right-click a sidebar/middle row →
  "Share Recall…" shares that node without opening it; a node with no loose ends/activity shares the
  `_None open._`/`_No captured activity._` placeholders; the shared text contains **no** verbatim quote; German
  shows "Rückblick teilen…" (`-AppleLanguages '(de)'`) while the export stays English. Build: `xcodegen generate
  && xcodebuild -project Pensieve.xcodeproj -scheme Pensieve -configuration Debug -derivedDataPath ./.build-xcode
  build`, then `open ./.build-xcode/Build/Products/Debug/Pensieve.app`.

**Also this session: Widgets — investigated & DEFERRED.** A macOS widget extension is sandboxed and needs an
**App Group** (Team-ID-provisioned entitlement) to read the store; the app is ad-hoc signed with no paid team,
and free personal teams can't provision App Groups. Deferred with the finding recorded in
`docs/superpowers/backlog.md` ("Widgets — DEFERRED"). Same gate blocks CloudKit + any extension; revisit on a
paid Apple Developer membership.

**Prior this session: three-pane IA rework — DONE & on `main`.** Killed the sidebar→middle→detail
self-duplication (backlog "App UX & IA polish" item 5). The middle pane now lists a **focused node's children**
(or, for a leaf, its **loose ends**) instead of the node-plus-children; the detail always shows the focused
node's recall; clicking a child **drills** into it; **Smart-List/Briefing lists stay** on click (triage
preserved); loose-end provenance stays in the single **⌘⌥I inspector** (kept — reached identically from the
middle worklist and the detail recall's rows); the detail drops its Loose Ends section only for the focused
leaf (**one-home rule**). App-target rewiring (`AppModel.middleKind`/`selectMiddleNode`/`selectMiddleLooseEnd`/
`detailShowsLooseEnds`, `ContentListView`, `RootView`, a shared `LooseEndRow`, `DetailView.showsLooseEnds`) over
one tested Kit helper (`NodeForest.children`); no trust-gate/capture/schema changes. Subagent-driven (5 tasks:
Sonnet impl+task-review each; **Opus** whole-branch = READY-TO-MERGE, 0 Critical/Important). Spec/plan:
`docs/superpowers/{specs,plans}/2026-07-08-three-pane-ia-rework*`.
- **Merge wrinkle (resolved):** a **concurrent uncommitted Xcode reformat of `Localizable.xcstrings`** appeared
  on the `main` checkout mid-session (named format args, state flips, dropped `%lld Projects`). Preserved it via
  a union `chore(l10n)` (`d2df86b`): the reformat is the base, the 3 new IA keys added
  (`%lld strands`→Stränge, `%lld loose ends`→lose Enden, `None open`→Keine offen), `%lld Projects`→Projekte
  restored (the feature's middle subtitle uses it). No German lost either side; verified in the built `de.lproj`.
- **Deferred Minors** (from reviews, non-blocking): a shared "is-focused-leaf" predicate could replace the small
  duplication between `middleKind` and `detailShowsLooseEnds`; the middle's empty-space click no longer deselects
  a row (navigator model — likely fine); `ContentListView.looseEnds` has no `loadedNodeID` guard (sub-frame
  stale possible on a fast leaf→leaf switch, self-correcting because the read is synchronous — matches
  `DetailView`'s existing pattern).
- **Human-verify carries** (need the built app + real store + plain `open`; can't be asserted headlessly): a
  strand-less project no longer triple-appears (middle shows its loose ends, detail recall omits the duplicate
  section); a project with strands lists strands in the middle, clicking one drills to its loose ends + recall;
  What's Next/Dormant/Recently Active + Briefing cards keep the list on click; a loose-end click in the middle
  worklist and in a smart-list detail recall drive the **same** ⌘⌥I inspector; ⌘⌥N recall window still shows a
  node's loose ends; middle title reads the focused node name with "N strands"/"N loose ends" (Smart-List/
  Briefing keep "Pensieve"/"N Projects"); `pensieve list` matches after organizing writes; German in situ
  (`-AppleLanguages '(de)'`). Build: `xcodegen generate && xcodebuild -project Pensieve.xcodeproj -scheme
  Pensieve -configuration Debug -derivedDataPath ./.build-xcode build`, then `open
  ./.build-xcode/Build/Products/Debug/Pensieve.app`.

**Latest (this session): Focus filters (Work / Personal context) — DONE & on `main`.** The first
`SetFocusFilterIntent` surface: when a macOS Focus is active, Pensieve restricts the main window + menu-bar popover +
Spotlight to the projects/strands matching that Focus's context. **Kit (SwiftUI-free, tested):** migration **v9**
adds `nodes.context` (`work`/`personal`/`""`unset); `NodeContext.swift` — a `NodeContext` constant enum + pure
`NodeContextResolver` with **subtree inheritance** (nearest non-empty ancestor wins; child overrides) and a single
**visibility predicate** `visibleNodeIDs(for:in:)` (mute the opposite explicit context, always show unset, `""` ⇒
all); `NodeCommands.add/update` grow a defaulted `context`. **App (thin):** `PensieveFocusFilter: SetFocusFilterIntent`
with an **optional** `@Parameter` (nil on deactivation → persists `""` → unfiltered) writing `UserDefaults`
(`FocusFilterDefaults.activeContextKey`); `AppModel` seeds it on launch + observes `UserDefaults.didChangeNotification`
(main-queue hop) → re-filters `lists`/`briefingCards`/`forest` (forest rebuilds on context-only change via a
`lastForestContext` guard; `allNodes` stays the FULL set) + reindexes Spotlight; `SpotlightIndexer.reindex(activeContext:)`
filters its index; a **Context picker** (Work/Personal/Unset) in the New/Edit modal. Subagent-driven (7 tasks: Sonnet
impl + task-review each; **Opus** whole-branch review → READY-TO-MERGE, 0 Critical/Important, 2 Minors both fixed —
dropped unused `NodeContext.all`/`.unset`). German l10n of all new chrome. Menu-bar filtered too (shared `lists` state;
user-approved deviation from the spec's original "menu-bar unfiltered"). Spec/plan:
`docs/superpowers/{specs,plans}/2026-07-07-focus-filters*`.
- **Accepted trade-offs (not bugs):** Spotlight reindexes per Focus switch; while in Personal you won't find a Work
  node by name in Spotlight; if a Focus is deactivated while the app is fully quit, the persisted context reconciles on
  the next `perform()`/launch read (spec-accepted).
- **Human-verify carries** (need the built app + real store + System Settings; can't be asserted headlessly): attach the
  Pensieve filter to a "Personal" Focus in System Settings → set Personal → enable it → main window + menu-bar + tree +
  Briefing show only personal + unset nodes, Work hidden; disable → everything returns; a "Work" Focus mutes personal;
  Spotlight surfaces only the visible subset and re-indexes on switch; the modal Context picker sets a node's context and
  a child inherits its parent's; setting a project to Work hides its whole subtree while in Personal; `pensieve list`
  unaffected; German in situ (`-AppleLanguages '(de)'`) for the picker + the Settings filter row. Build: `xcodegen
  generate && xcodebuild -project Pensieve.xcodeproj -scheme Pensieve -configuration Debug -derivedDataPath
  ./.build-xcode build`, then `open ./.build-xcode/Build/Products/Debug/Pensieve.app`.

**Prior this session: app chrome polish batch — DONE & on `main`.** Ten app-target-only ("chrome") polish
tasks that make Pensieve.app feel Apple-native — **no PensieveKit changes** (196 tests unchanged). Two waves:
**Wave 1** — (T1) reading-prose typography (`ProseStyle.swift`: 14pt/lineSpacing/680pt measure cap); (T2/T9)
window toolbar actions moved onto the **detail column** (New Node "+" leading; Refresh + Inspector trailing) with a
single **native** sidebar toggle; (T3) native sidebar status bar (hairline over `.background(.bar)`); (T4/T8)
Reminders-parity New/Edit modal (`IconPicker.swift`) with anchored SF-Symbol search + emoji picker popovers.
**Wave 2** — (T5) consistent type scale + balanced activity timeline; (T7) inspector renders transcript **Markdown**
via MarkdownUI 2.4.1; (T9) content-column header ("Pensieve / N Projects"); (T10) layout robustness — firm column
width bounds (sidebar 220–340 / content 280–460 / detail min 380) + window min 900×480 / default 1040×660, inspector
Markdown horizontal-overflow wrap, timeline/meta font bumps (12pt meta, 14pt day header). Subagent-driven (Sonnet
impl+task-review each); **two Opus whole-branch reviews** (waves 1+2 → READY-TO-MERGE 0 Critical/Important; then a
final review of the post-review T9/T10 delta → READY-TO-MERGE, 0 Critical/Important, 3 cosmetic Minors). Fast-forward
merged (main was at the branch base; discarded the transient MarkdownUI `Package.resolved` churn — see T7 gotcha).
Spec/plans: `docs/superpowers/{specs,plans}/2026-07-07-app-chrome-polish-*` (+ `…-wave2.md`).
- **Minors left as-is (non-blocking):** detail column carries `ideal:380` where spec said `min:380` only (no-op —
  the flexible last column never binds to it); `"%lld Projects"` is un-pluralized ("1 Projects", matches spec);
  `firstEmoji(in:)` doesn't detect keycap-digit emoji (e.g. `5️⃣`) — pick silently no-ops (narrow subset).
- **Human-verify carries** (need the built app, real store, plain `open` — can't be asserted headlessly): prose
  reads larger/airier with a bounded ~680pt reading column on a wide window (Detail + Briefing); the sidebar bottom
  bar reads native (hairline + translucent), not bolted-on; each toolbar action opens the same sheet/dialog as the
  context menu and node-ops disable with no selection; the New/Edit modal is a balanced two-zone layout with a live
  preview circle, the Symbol popover searches + picks an SF Symbol, and the Emoji popover picks an emoji; inspector
  transcript Markdown wraps within the panel (no right-edge overflow) incl. long file-path code spans; timeline meta
  + day header read comfortably; the sidebar can't be dragged wide enough to push content/detail out and shrinking to
  the window min keeps all three columns readable; German renders in situ (`-AppleLanguages '(de)'`); `pensieve list`
  matches after a create/edit. Build: `xcodegen generate && xcodebuild -project Pensieve.xcodeproj -scheme Pensieve
  -configuration Debug -derivedDataPath ./.build-xcode build`, then `open
  ./.build-xcode/Build/Products/Debug/Pensieve.app`.

**Prior this session: app visual identity & UX polish — DONE & on `main`.** Seven UX fixes on a shared
per-kind/per-source **visual-identity system** (localizable label + icon + color; a node may override its own
icon+color, kind defaults otherwise). **Kit (SwiftUI-free, tested):** migration **v8** adds `nodes.icon`/`colorTag`;
`VisualIdentity.swift` (`AppearanceIcon` `sf:`/`emoji:` scheme, `NodeKindStyle`, `EventSourceStyle`,
`Node.appearance`); `NodeCommands.add(icon/colorTag)`, `.update`, and a **manual-only cascade `delete`** —
`subtreeIsActivityBorn` refuses to delete any node whose subtree holds a live `Source` **or an auto-birthed strand
(`branchKey != nil`)**, because both re-materialize via `ProjectResolver`/`attributeToNode` on the next drain (the
strand case was **caught by the Opus whole-branch review** — the source-free guard alone missed it — and fixed +
re-reviewed). **App (thin views):** `AppearanceStyle` resolver + `NodeBadge`; a **Reminders-style New/Edit modal**
(name/type/color grid/emoji+SF-symbol picker) that **replaces** inline-rename + the Change Type submenu and writes
fully-formed nodes; **manual delete** (context menu, disabled on activity-born nodes, destructive confirmation);
sidebar footer `.background(.bar)` clash fix + **collapsible sections** (`Section(isExpanded:)` in `@AppStorage`);
icon **badges** + localized **kind label** + colored **state orb** in list/sidebar/header; a **GitHub-style
day-grouped timeline** with source icon+color+localized label; **German localization** of all new chrome + a
localized `NodeEntity` Spotlight subtitle. Subagent-driven (12 tasks: Sonnet impl+task-review each; **Opus**
whole-branch review → 1 Important fixed, minors deferred). Spec/plans:
`docs/superpowers/{specs,plans}/2026-07-07-app-visual-identity-*`.
- **Merge wrinkle (resolved):** `main` was at the branch base (no parallel commits) but the checkout had an
  uncommitted **Xcode reformat of `Localizable.xcstrings`** (reorder + `%lld`→`%@`). Set aside, fast-forwarded the
  branch, then **reconciled** (`chore(l10n)` `3ba9da9`): a jq **union** kept the reformat (order + specifier
  changes) and appended the **26** new German chrome keys → **87 keys**; verified `de.lproj` compiles the German.
  The catalog's whitespace is now jq-serialized (Xcode re-normalizes it on next open); no keys/translations lost.
- **Human-verify carries** (need the built app, real store, plain `open` — can't be asserted headlessly): footer no
  longer clashes; sections collapse/expand and persist; the New/Edit modal creates/edits with a chosen color+icon
  (no empty placeholder); icon badges render in list/sidebar/header (incl. a custom emoji); state-orb color
  (active=green/muted=orange/archived=gray); the timeline rail + day headers + source badges (eyeball the
  last-per-day rail stub); **Delete… is disabled on activity-born nodes** (sources or a `branchKey` strand) and
  enabled+confirmed on manual ones; `pensieve list` matches after; German in situ (`-AppleLanguages '(de)'`) + a
  native-speaker tone pass on the new copy. Build: `xcodegen generate && xcodebuild -project Pensieve.xcodeproj
  -scheme Pensieve -configuration Debug -derivedDataPath ./.build-xcode build`, then `open
  ./.build-xcode/Build/Products/Debug/Pensieve.app`.

**Prior this session: three-pane slice 4 (in-app organizing writes) — DONE & on `main`.** The app can now
reorganize the typed tree. Five ops via native `.contextMenu` on **both** sidebar-tree and middle-list rows +
toolbar "+"/File ▸ New Node (⌘N): **New Child · Rename · Change Type ▸ (all 7 kinds) · Move to… · Merge into…**
(destructive, `.confirmationDialog`). In-place rename = focused `TextField` (Enter/blur commit, Esc cancel);
creation renames in the flat middle list (OutlineGroup can't be force-expanded), so New Child selects the
*parent*. **Two load-bearing PensieveKit correctness fixes (tested):** a unified **guarded
`NodeCommands.reparent`** (walk-to-root cycle guard; `nest` routes through it) and a **general cycle-safe
`ProjectResolver.group`** — the survivor is lifted above the highest absorbed node on its own ancestor chain, so
**no** merge (incl. multi-ancestor-in-one-call / non-adjacent ancestor) can create a self/transitive cycle; the
initially-planned parent-into-child-only fix was **caught insufficient in the task review and generalized** (a
concrete CLI-reachable counter-example was reproduced). Plus a pure `NodeForest.descendantIDs` picker guard
(Move/Merge exclude self+descendants — UI defense-in-depth atop the authoritative write guard). App writes are
thin on `AppModel` (op → explicit `refresh()`); `merge` moves selection/rename state off the deleted source;
default new-node **name is plain "New Node", NOT localized** (node names are content → the sync-bound canonical
store). Subagent-driven (Sonnet impl/review; **Opus** whole-branch = READY-TO-MERGE, 0 Critical/Important; two
new Minors (stale `sidebarSelection` on merge, localized default name) fixed before merge). Spec/plan:
`docs/superpowers/{specs,plans}/2026-07-07-three-pane-slice4-organizing-writes*`.
- **Merge wrinkle (resolved):** `main` advanced mid-session with two of your commits — `9d54438` (Xcode
  Build+Run scheme) and `03074fa` (inspector-perf, touches `RootView.swift`) — plus an uncommitted
  **Xcode-reformatted `Localizable.xcstrings`** (multi-line, +12 auto-extracted App-Intents/Spotlight keys). The
  branch was **rebased onto `03074fa`** (RootView auto-merged, no conflict) and merged `--no-ff`; a follow-up
  `chore(l10n)` commit **adopted your reformatted catalog and folded in the 10 slice-4 German keys** (66 keys
  total). Net: the Xcode String Catalog format is now the committed source of truth.
- **Human-verify carries** (need the built app, real store, plain `open` — can't be asserted headlessly): rename
  commit(Enter/blur)/cancel(Esc) in place on tree + middle list; Change Type updates the tree icon; **Move to…
  and Merge into… never list the node or its descendants** and Move offers "Top level"; the destructive-merge
  confirmation names both nodes and the merged node's activity re-homes under the target; `pensieve list` matches
  the app's tree after each op; German renders in situ (`-AppleLanguages '(de)'`). Build: `xcodegen generate &&
  xcodebuild -project Pensieve.xcodeproj -scheme Pensieve -configuration Debug -derivedDataPath ./.build-xcode
  build`, then `open ./.build-xcode/Build/Products/Debug/Pensieve.app`.

**Next up — track choice (each its own brainstorm→spec→plan):** **three-pane slice 5 (talk-to-system:
describe→create a strand via `LLMProvider`)**, or the OS-integration track (**Focus filters `SetFocusFilterIntent`**
⭐, then Widgets/CloudKit), or slice 6 (forks, gated on the unbuilt fork-capture backend). See
`docs/superpowers/backlog.md` **Roadmap**.

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

**Track A — the three-pane app** (the product spine). Slices 3a/3b, **slice 4 (organizing writes), and the
visual-identity & UX-polish pass all shipped. Next: slice 5 (talk-to-system** — describe→create a strand via
`LLMProvider`), then 6 (forks, backend-gated — brainstorm the fork-capture backend first). Design:
`specs/2026-07-05-pensieve-app-three-pane-design.md`.

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
