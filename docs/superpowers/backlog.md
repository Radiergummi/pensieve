# Pensieve — Backlog (deferred, not forgotten)

Ideas we've deliberately parked so a phase stays focused. Each is on the roadmap;
none is foreclosed. Revisit when the noted trigger arrives.

The **Roadmap** below is the spine — the sequenced pillars from where we are to the finished
app. Everything after the first `---` is the detail-ledger: features parked out of specific
phases, plus forward ideas, each with its own revisit trigger. Read the roadmap for *where
we're going*; read the ledger for *what we deliberately deferred and why*.

---

## Roadmap — pillars from here to the finished app

**Source of truth for full intent:** `specs/2026-07-03-pensieve-mvp-design.md`. This section
lifts that spec's phasing + "Later" list into one sequenced place so "what's between here and
done" isn't split across two documents. **No new scope is invented here** — sizes are honest,
order is a recommendation, nothing is foreclosed.

### Shipped (the core loop is live)

Capture → ingest → grounded/cited loose ends → `next`/`digest` (1A + 1B); the typed tree &
strands (1B-org); source discovery (`scan`); the launchd auto-flow sync daemon; the v0.1
heartbeat window; **the three-pane `Pensieve.app` slices 1–2** (read-only core + Briefing home +
⌘K palette — see pillar #2); the **GUI base-state** (SwiftUI `App` lifecycle, standard menu bar,
⌘K/⌘R `.commands`); **Xcode adoption** (a real `Pensieve.app` bundle built by XcodeGen with
PensieveKit as a local SwiftPM package, ad-hoc signed, bundled `icons/Pensieve.icon` via `actool`);
and the **menu-bar item + `pensieve://` deep links (v0.2)** (a `MenuBarExtra` popover glance + a
tested `DeepLink` router; the `pensieve://` scheme is now **live** — see pillar #1). **The make-or-break
intelligence gate passed.** Dogfooding is on. This is the hard part, done.

### Pending pillars (sequenced; each is a brainstorm → spec → plan item unless noted)

This is the durable index of *everything still to build*. Each pillar below needs its own
brainstorm→spec→plan cycle (the loop in `CONTINUE.md` → "How we work here"); the deferred-ledger
sections after the first `---` hold the parked depth-features + forward ideas, each with a revisit
trigger. Order is a recommendation, not a commitment.

1. **Menu-bar item / `LSUIElement` (v0.2)** — ✅ **menu-bar item DONE** (merged 2026-07-06); **`LSUIElement`
   hide-dock toggle deferred.** Shipped: a `MenuBarExtra` `.window` popover (heartbeat over `MonitorSnapshot`
   + top-5 What's Next over `SmartLists`; status by glyph shape; click-to-jump) in the *same* app, plus the
   minimal, tested `pensieve://` `DeepLink` router as its first consumer. Spec/plan:
   `{specs,plans}/2026-07-06-menu-bar-deeplinks*`. **What remains (deferred → ledger below):** the optional
   `LSUIElement`/hide-dock toggle (needs a Settings surface); a menu-bar icon count badge; a Dormant/Recently-
   Active peek in the popover.

2. **The three-pane `Pensieve.app` (Phase 3) — THE product.** *The spine; specced + underway.* Design:
   `specs/2026-07-05-pensieve-app-three-pane-design.md` (a 6-slice build sequence). Sidebar smart-lists /
   list / provenance-bearing detail view. The forward ideas **talk-to-the-system** and
   **forks-as-first-class** (below) live *inside* this app (slices 5 & 6).
   - ✅ **Slice 1 — read-only core** (merged): `NavigationSplitView`, action-first sidebar (smart lists +
     node tree), middle list, detail recall view with **inline verbatim provenance**, launch drain.
     Plan: `plans/2026-07-05-pensieve-app-slice1-three-pane-core.md`.
   - ✅ **Slice 2 — Briefing home + ⌘K palette** (merged): by-project "since last visit" world map as the
     default landing (`BriefingQueries`; `lastOpenedAt` in UserDefaults); navigation-only command palette.
     Plan: `plans/2026-07-05-pensieve-app-slice2-briefing-palette.md`.
   - ✅ **Slice 3a — LLM "Last Work Done" narration** (merged 2026-07-06): `DetailView` prose recap via a tested
     `SummaryBuilder.narrate → String?` (nil-honest, outside the cited gate), on-device, automatic + progressive,
     ⌘R re-narrates. Spec/plan: `{specs,plans}/2026-07-06-three-pane-slice3a-last-work-done*`.
   - ✅ **Slice 3b — inspector + liveness + windows** (merged 2026-07-06): ⌘⌥I provenance inspector
     *(the `.inspector` panel was RETIRED 2026-07-08 → inline provenance in each loose-end row; see the
     "App layout + inline provenance rework" entry below)*, `ValueObservation` + FSEvents liveness (retired the
     3 s `Timer`), secondary recall windows.
   - ✅ **Slice 4 — in-app organizing writes** (merged 2026-07-07): create / `nest` / `group` / `rename` /
     `retype` via context menus + toolbar, with the unified walk-to-root cycle guard.
   - ✅ **Visual identity & UX polish** (merged 2026-07-07): per-kind/source icon+color system (migration v8),
     Reminders-style New/Edit modal, manual delete (guarded against strand resurrection), badges + state orb +
     GitHub-style timeline, German l10n. *Follow-up UX/IA carries in the dated section below.*
   - ⏳ **Slice 5 — talk-to-system stage 1:** describe a strand → structured create.
   - ⏳ **Slice 6 — forks surface:** ancestry trail + siblings + "Roads Not Taken" list. **Gated on the
     fork-capture backend** (see "Forks as first-class" below — that backend is a separate spec, still the
     long pole).
   - **Carries from slice reviews (fold in when convenient):** key `lastOpenedAt` per DB path; a shared
     per-node "latest event + days-dormant + open-loose-end-count" helper (that shape now recurs in
     `NextQueries` / `MonitorSnapshot` / `BriefingQueries`).

3. **Resident `pensieved` (`SMAppService`) (Phase 2)** — *medium; partially superseded.* The
   launchd one-shot sync daemon already delivers auto-flow, so a resident agent is now a
   *convenience upgrade* (lower latency, background digest pre-compute), **not** a prerequisite.
   Decide during app design whether the app's launch/foreground drain + launchd cover this, or a
   resident agent still earns its keep. May be reorderable with the app per the spec.

4. **CloudKit sync + iOS companion** — *large; on-ramp preserved, unbuilt.* SQLiteData's opt-in
   `SyncEngine`; sync lives only in the entitled app process (hooks/CLI stay local). "Flip it on,"
   not "build from scratch" — but still a real phase (conflict handling, iOS UI).

5. **System-integration surfaces** — *medium, each independent.* Widgets / Lock Screen widgets,
   Siri / Shortcuts, Spotlight indexing. Native, glanceable extensions of the digest/next data.
   Fully enumerated in **Platform extension points (candidate surfaces)** below.

6. **Real-time monitoring (FSEvents)** — *small–medium.* Replace/augment interval polling with
   FSEvents on `~/.claude/projects/**` for instant capture. Pure latency win.

7. **Additional source types** — *large, open-ended.* Notion, Entra, browser work, etc. The model
   already allows non-git sources; this is where the deferred **per-kind ingestion-handler
   protocol** (below) finally earns its place (trigger: the 4th source type).

8. **Analytics surfaces** — *medium.* Cross-project dependency graphs, dashboards, token-spend
   charts. Explicitly "Later" in the spec; lowest priority.

**Depth features that thread through the above** (detailed in the ledger, not standalone pillars):
domain-level recursive rollups, cross-cutting soft references (`node_links`) — which
forks-as-first-class builds on, statistical theme discovery (`NLEmbedding`), proactive project
suggestion, and native localization. These deepen existing surfaces rather than standing alone.

### ⭐ App Settings surface — FIRST CUT DONE (2026-07-08, merged to `main` `9de6d18`)

**Shipped** the first-party SwiftUI `Settings` scene (**⌘,**) with three knobs, each persisted where it
belongs. **Kit (tested):** `ProviderPreference` + `Preferences` (JSON in the shared, non-sandboxed support
dir, best-effort → `.auto`) + `PensievePaths.preferencesURL()`; pure `resolveProviderKind`;
`makeDefaultLLMProvider(prefsURL:)`/`defaultProviderKind(prefsURL:)` read the persisted choice (explicit URL →
`PENSIEVE_PREFS` → support dir) so **both the app AND the launchd daemon** honor it. **App (thin):** `SettingsView`
reads/writes `Preferences` directly; rebuildable `AppModel.summaryBuilder` (in-app provider switch takes effect
without relaunch); `AppDefaults` shared keys; `AppDelegate.applicationDidFinishLaunching` activation policy; German
l10n. Trust gate untouched. A high-effort `/code-review` fix wave then caught + fixed two defects the whole-branch
review missed (Share leaked disabled narration; narration cache wasn't provider-keyed). **246 tests** (+9 Kit).
Spec/plan: `{specs,plans}/2026-07-08-app-settings-surface*`.

**Delivered from the convergent threads:**
- ✅ **LLM provider selection** — Automatic / Foundation Models / `claude -p`, whole-system (app + daemon).
- ✅ **`LSUIElement` / hide-dock toggle** (deferred from v0.2) — runtime `NSApp.setActivationPolicy(.accessory)`.

**Deferred out of the first cut (on the roadmap, not foreclosed):**
- **Cloud/API LLM provider + Keychain-stored key + model selection** — the motivating long-term case; a meaty
  net-new subsystem (an HTTP `LLMProvider`) that builds on the shipped provider-preference scaffold. *Its own
  spec.*
- **Organizing-writes error surfacing** (code-quality carry) — still needs an app error-presentation mechanism;
  pairs with this surface but was not built. *Trigger: when an error-surface is added.*
- More knobs as they arise (capture/scan folders, daemon interval); tabbed multi-pane Settings.

### Platform extension points (candidate surfaces) — a menu, not a sequence

The macOS / Apple-ecosystem surfaces Pensieve could hook into long-term. **A candidate menu to draw from,
not a committed order** — each is its own future brainstorm→spec→plan; several already have pillars above
(cross-linked). **The north-star caveat applies to every one:** glance/voice surfaces read the shared
grounded kernel (`MonitorSnapshot` / `next` / `digest`) and never re-derive or fabricate — that is what
keeps them thin. *Fit* = suitability to Pensieve's nature (grounded glance + light query/organize + capture
+ sync); *cost* is rough. Availability is as of **macOS 26 (Tahoe) / Xcode 26** — confirm exact framework
availability + deployment-target floors at each surface's spec time.

**Recommended build order (when we start picking these up):**
1. **Foundational — everything leans on them:** `pensieve://` URL scheme / deep links; App Groups / shared
   container (so extensions read one store); the **App Intents** skeleton.
2. **Highest glance-value:** menu-bar item (pillar #1) → widgets → Spotlight indexing → *sparing* notifications.
3. **Highest leverage per effort:** App Intents — one build lights up Siri + Shortcuts + Spotlight actions + Focus filters.
4. **New capture signal worth the reach:** FSEvents (pillar #6) → active-context (NSWorkspace, then maybe AX) → EventKit.
5. **Big, deferred, on-ramp preserved:** CloudKit (pillar #4) → iOS / Watch companion.

**A — Glance / ambient (surface state, read-only)**
- **Menu-bar item** (`MenuBarExtra`) — ✅ **DONE (v0.2, 2026-07-06).** Heartbeat + top-5 What's Next popover + click-to-jump. **= pillar #1.**
- **Desktop / Notification-Center widgets** (WidgetKit) — *small–medium; strong.* "What's Next" / "Dormant" as a glance. Part of pillar #5.
- **Control Center controls** (`ControlWidget`, macOS 15+) — *small; medium.* "Open briefing" / "Refresh" button; rides on WidgetKit.
- **Spotlight indexing** — ✅ **DONE (v0.3, 2026-07-06)** as the **App Intents foundation** pillar (spec+plan `{specs,plans}/2026-07-06-app-intents-foundation*`). Nodes as `IndexedEntity` (macOS 15+) *on* App Intents, not standalone Core Spotlight — one `NodeEntity` serves Spotlight content + Siri + Shortcuts + Open-Node/Show-Pensieve-List intents; clear-then-index on launch + ⌘R. **Future extensions (roadmap):** index loose-end text; **semantic / vector search** so recall doesn't need exact words — evaluate `sqlite-vec`, on-device embeddings (`NLContextualEmbedding` / Foundation Models SDK), and native Spotlight semantic indexing (shares the embedding substrate with the theme-discovery spike below); live/background re-indexing (slice-3 liveness); `.text` vs `.content` attribute-set refinement if body matching underperforms. Part of pillar #5.
- **Notifications** (UserNotifications) — *small–medium; strong but sparing.* Grounded nudges (left-open, briefing-ready, dormant); noise risk → rare + cited.
- **Dock tile** — *tiny; marginal.* Open-loose-ends badge + a recent-projects dock menu.

**B — Intents & automation (hub: App Intents — build once, light up all)**
- **Siri / Apple Intelligence** — *medium, Xcode-gated; strong.* Grounded Q&A + describe→create strand. Part of pillar #5.
- **Shortcuts** — *medium; strong.* User-composable automations over the same intents.
- **Spotlight actions** (App Intents in Spotlight, expanded in macOS 26) — *small atop App Intents; good.* Run actions by typing.
- **Focus filters** (`SetFocusFilterIntent`) — ✅ **DONE (2026-07-07, merged to `main` `171c0e6`).** A macOS Focus restricts the main window + menu-bar + Spotlight to its context. Shipped: migration v9 `nodes.context` (`work`/`personal`/unset) + tested `NodeContextResolver` (subtree inheritance + mute-opposite/show-unset predicate); `PensieveFocusFilter: SetFocusFilterIntent` (optional param = deactivation signal) → `UserDefaults` → `AppModel` observes + re-filters + reindexes; a Context picker in the New/Edit modal; German l10n. Spec/plan: `{specs,plans}/2026-07-07-focus-filters*`. **Deferred follow-ups:** notification muting ("mute personal nudges" — moot until notifications exist); a bulk/right-click "Set Context" action; >2 contexts; CLI `--context`.
- **Services menu** (`NSServices`) — *small; medium.* Select text anywhere → create a strand.
- **URL scheme / deep links** (`pensieve://`) — ✅ **DONE (v0.2, 2026-07-06).** Registered scheme + tested `DeepLink` router (`briefing`/`node/<uuid>`/`smartlist/<kind>`); menu-bar item is the first consumer. Every later surface links back through it.

**C — Capture sources (feed ingest, not surface)**
- **FSEvents / DispatchSource** — *small–medium; strong.* Real-time monitoring vs interval polling. **= pillar #6.**
- **NSWorkspace active-app notifications** — *small; good.* Lightweight "what am I working on now" (frontmost bundle).
- **Accessibility API (`AXUIElement`)** — *medium; medium, privacy-sensitive.* Frontmost window title / browser URL; permission-heavy — gate carefully.
- **EventKit (Calendar / Reminders)** — *medium; medium.* Meetings/reminders as strand context — a genuinely new signal.
- **Safari App / browser extension** — *large; medium.* Web research as a source. Part of pillar #7 ("browser work").
- **FinderSync extension** — *medium; medium.* Right-click a repo → "Track in Pensieve" / status badge; a source-discovery on-ramp.
- **Mail / Messages / Notion / Entra / clipboard** — *large; later.* More non-code sources → the deferred per-kind ingestion handler. Part of pillar #7.

**D — Sync & cross-device**
- **CloudKit sync** (SQLiteData `SyncEngine`) — *large; strong.* **= pillar #4.**
- **iOS / iPadOS companion** — *large; strong.* Digest/next on the phone (widgets, Live Activities). Part of pillar #4.
- **Apple Watch complication** — *medium; marginal-but-delightful.* What's-next glance; rides on the iOS companion.
- **Handoff / Continuity** — *small; marginal.* Hand off "reviewing project X" Mac↔iPhone.
- **Live Activities** (iOS; surface in the Mac menu bar via Continuity) — *medium; marginal for a Mac-first tool.* "Capture in progress"; more compelling once the iOS companion exists.

**E — Packaging / background / plumbing**
- **SMAppService** — *medium; good, partly superseded.* Modern packaged login-item / agent. **= pillar #3.**
- **App Groups / shared container** — *small; foundational.* One store shared by app + widgets + extensions + Siri; build with the first extension.
- **BGTaskScheduler** — *later.* iOS-side background refresh (companion only).

**Deliberately skipped** (wrong shape for a grounded project-tracker; revisit only if the product's shape
changes): Writing Tools / Image Playground / Genmoji / Visual Intelligence (content-creation AI); Endpoint
Security / DeviceActivity / Screen Time (too invasive); Quick Look / Print services / legacy Automator
(App Intents + Shortcuts subsumes the useful part).

---

## Widgets — DEFERRED (2026-07-08): blocked on App Groups needing a paid Team ID

Attempted to pick up Widgets (the first *second process*). Hit a hard prerequisite during brainstorming and
deferred with the user's agreement.

**The blocker.** A macOS **WidgetKit extension is always sandboxed** — it cannot read the canonical store at
`~/Library/Application Support/Pensieve/` (`PensievePaths.supportDirectory()`), which every current writer (git
hooks via CLI, launchd daemon, app) and reader uses. The only way to share the store with the extension is an
**App Group container** (`~/Library/Group Containers/<TeamID>.<group>/`), which on macOS requires the app to be
**signed with a Team ID** and the `com.apple.security.application-groups` entitlement **provisioned**.

**Why blocked now.** The app is **ad-hoc signed** (`CODE_SIGN_IDENTITY: "-"`, no `DEVELOPMENT_TEAM`), which has
no Team ID. The only signing artifacts on the machine are corporate MDM/Configurator ones (an "Apple
Configurator: Matchory GmbH" identity; a Microsoft *Intune MDM Agent* profile, team `UBF8T346G9`) — none carry
App Groups. The user has a **free Personal Team** available (via Apple ID), but **free personal teams do not
support the App Groups capability** (Apple gates it as paid; Xcode blocks adding it). ~85% confident this is a
hard block for a personal team — a spike would confirm, but the odds favor failure.

**Revisit trigger.** A **paid Apple Developer membership** (personal enrollment, or an acceptable paid org team)
is in hand. Then the first move is switching the app + a new widget target to Team-ID signing and moving the
canonical store into an App Group container — a shared `PensievePaths.supportDirectory()` resolution that ALL
writers (hooks/daemon/CLI/app) adopt, not just the app. **This same gate blocks CloudKit** (pillar #4) and any
future extension; resolving the paid-membership + App-Group foundation unblocks the whole extension family at
once. If a spike is ever run: sign with the team, add the App Group entitlement to both targets, and confirm
`FileManager.containerURL(forSecurityApplicationGroupIdentifier:)` resolves non-nil in BOTH the app and the
widget, and that the widget can read a file the app wrote there — that go/no-go gates everything else.

---

## Narration-cache carry — 2026-07-08 (deferred, non-blocking)

From the ingestion-intelligence-quality branch (Part C). The persisted narration cache
(`AppModel.narrationCache` in `UserDefaults`, keyed per-DB-path) replaced the blanket
`removeAll()` with key-based invalidation, so entries for **deleted / merged-away nodes are
never pruned** and accumulate in the plist indefinitely. Low severity for a single-user store
(bounded by node count, device-local, never surfaced — reads are key-gated on live events), but
unbounded in principle. *Fix when convenient: prune `narrationCache` to the set of live node ids
on refresh (intersect keys with `allNodes`). Trigger: an app-target cleanup pass, or if the plist
ever grows noticeably.*

## Code-quality review carries — 2026-07-07 (deferred / design questions)

From a full code-quality + idiomatic-Swift review of the whole tree. Most findings were fixed in
the same pass (Swift 6 mode on the app target — which caught a real non-`Sendable` `Ingester`
crossing the `@MainActor` boundary; the inspector's in-`body` DB query; a `claude -p` timeout +
off-cooperative-pool + SIGPIPE guard; `DatabaseReader` widening; `@Sendable` FSEvents callback; a
`NodeKind` type; and a batch of smaller cleanups). These four were deliberately **not** taken on —
too big, or a genuine design question.

- **`AppModel` → `@Observable` migration** — the app still uses `ObservableObject`/`@Published`, so
  any `@Published` write invalidates *every* observing view. That's the root cause of a cluster of
  small "recomputed in `body`" items: the (now-fixed) inspector re-query, `ContentListView.nodesForSelection()`
  (filter + O(n log n) sort on every unrelated refresh), and `PaletteView.rows` (re-runs `matchingNodes`
  each keystroke). `@Observable` scopes invalidation to the properties each view actually reads.
  Deferred because it's a broad, non-surgical rewrite of every view's state wrappers in an untested
  target. *Trigger: a dedicated app-target modernization pass, or when broad invalidation shows a cost.*
- **Organizing-writes silent-failure surfacing** — `AppModel.move/merge/rename/retype/createNode`
  `try?` the Kit op then unconditionally `refresh()`, so a failed *write* (as opposed to a read) is
  invisible with no signal why. `try?`-degrade-to-empty is right for reads, worse for user-initiated
  writes. Needs an error-presentation mechanism the app doesn't have yet. *Trigger: pair with the
  first Settings/error-surface (same surface the `LSUIElement` toggle waits on).*
- **`BriefingQueries.cards` N+1-inside-N+1** — fetches *all* events for every active node (no limit)
  to read `events.first` + a since-count, then calls `LooseEndQueries.open` per node, which itself
  re-fetches each loose end's source `Event` by id. Fine at single-user scale; a real fix is a query
  restructuring that risks the tested default landing view for no practical gain today. *Trigger: if
  the Briefing landing feels slow, or node/event volume grows materially.* (Related: the long-standing
  "shared per-node latest-event + days-dormant + open-loose-end-count helper" carry under pillar #2.)
- **`Ingester.drain()` decode-failure poison-pill — design question, intentionally unchanged.** A
  permanently-undecodable `git.commit` / `git.checkout` / `cc.session.start` spool row throws every
  drain and is left unmarked, so it's re-processed every launchd cycle forever; only the `cc.session`
  branch distinguishes transient (retry) from permanent (drop-and-mark). This was **not** flipped
  because the existing test `failingRowStaysPendingWhileGoodRowProcesses` encodes a deliberate "never
  silently drop a capture row" decision, and the loop is invisible (`drain`'s `catch { continue }`
  swallows the cause). The decision to make: keep data-preservation (retry forever, harmless for a
  single row) vs. treat a *decode* failure as permanent (drop-and-mark) — ideally paired with drain
  observability so a stuck row is at least logged. *Trigger: if a malformed capture row is ever
  observed looping, or when adding drain logging/metrics.*

---

## App UX & IA polish carries — 2026-07-07 (from dogfooding the visual-identity build)

Observations from using the shipped visual-identity + three-pane app on the real store. Items 1–4 are
small-to-medium app-target polish (no unit tests → build + smoke + human eyeball); item 5 (the three-pane IA
change) is the meatiest and wants its **own brainstorm→spec**. Reference screenshots (Reminders parity) are in
the 2026-07-07 session.

**✅ Items 1–4 SHIPPED (2026-07-07, merged to `main` `0a7eb0f`)** as the **app chrome polish batch** (two waves,
10 tasks; spec/plans `{specs,plans}/2026-07-07-app-chrome-polish-*` + `…-wave2.md`). Delivered: (4) reading-prose
typography (`ProseStyle.swift`, 14pt/measure cap); (3) window toolbar actions on the detail column + single native
sidebar toggle; (1) native sidebar status bar (hairline + `.bar`); (2) Reminders-parity New/Edit modal with SF-Symbol
search + emoji popover pickers (`IconPicker.swift`); plus wave-2 refinements (Markdown inspector via MarkdownUI,
content-column header, layout-robustness column/window bounds, timeline/meta font bumps). No PensieveKit changes.
Two Opus whole-branch reviews → READY-TO-MERGE. **Item 5 (three-pane IA rework) remains — its own brainstorm→spec.**

1. **Sidebar tracking indicator — make it feel native.** The liveness footer now has a solid `.background(.bar)`
   (which fixed the clash) but reads as a bolted-on band, not an Apple-idiomatic treatment. Explore the
   first-party pattern: a translucent bottom bar with a hairline `Divider`, folding it into the sidebar `List`
   as a non-selectable status row, or a smaller unobtrusive glyph. *Trigger: the next app-chrome polish pass.*
2. **New/Edit modal + icon/emoji picker — Reminders-parity layout.** The current modal (name / type / color
   grid / inline segmented Symbol|Emoji grid) is unbalanced and cramped — the symbol grid reads as a random
   block. Match Reminders' balance: **Name + Type + a compact color row on the left; a Symbol area on the right
   whose two buttons open popovers** — a searchable **SF-Symbol grid** popover and the **native emoji picker**
   (system emoji popover / `NSApp.orderFrontCharacterPalette`) — instead of an always-open inline grid. See the
   Reminders reference screenshots (balanced two-zone layout + popover pickers). *Trigger: pair with #1 as one
   "make the chrome feel Apple-native" pass.*
3. **Use the window toolbar.** Only a "+" toolbar item exists; the top toolbar is otherwise empty. Surface the
   common actions there (New Node, Edit, Delete, Move/Merge, Refresh, Inspector toggle) as toolbar items/menus,
   per macOS convention. *Trigger: the polish pass.*
4. **Prose typography.** Displayed prose (LLM "Last Work Done" narration, node descriptions, loose-end text,
   timeline summaries) uses a too-small font with poor line height and no measure control. A typographic pass:
   larger body size, generous line spacing, a readable max-width measure, consistent hierarchy. *Trigger: the
   polish pass.*
5. **✅ Three-pane IA rework — DONE (2026-07-08, merged to `main` `d2df86b`).** The middle pane now lists a
   focused node's **children** (or, for a leaf, its **loose ends**) instead of the node-plus-children — killing
   the sidebar→middle→detail self-duplication. The detail always shows the focused node's recall; clicking a
   child **drills**; Smart-List/Briefing lists **stay** on click (triage preserved); loose-end provenance was
   shown in a **⌘⌥I inspector** *(RETIRED 2026-07-08 → inline in each loose-end row; see the layout+provenance
   rework entry below)*; the detail drops its Loose Ends section only for the focused leaf (**one-home rule**).
   App-target rewiring (`AppModel.middleKind`/`selectMiddle*`/`detailShowsLooseEnds`, `ContentListView`,
   `RootView`, a shared `LooseEndRow`, `DetailView.showsLooseEnds`) over one tested Kit helper
   (`NodeForest.children`). Subagent-driven (5 tasks, Sonnet impl+task-review each; **Opus** whole-branch =
   READY-TO-MERGE, 0 Critical/Important; 3 non-blocking Minors). **205 tests** (+1 Kit). Spec/plan:
   `{specs,plans}/2026-07-08-three-pane-ia-rework*`. **Deferred Minors** (non-blocking): shared "is-focused-leaf"
   predicate (duplicated between `middleKind`/`detailShowsLooseEnds`); middle empty-space click no longer
   deselects (navigator model); `ContentListView.looseEnds` has no `loadedNodeID` guard (sub-frame stale on fast
   leaf-switch, self-correcting — matches `DetailView`). **Merge wrinkle (resolved):** a concurrent uncommitted
   Xcode reformat of `Localizable.xcstrings` on `main` was preserved via a union `chore(l10n)` (`d2df86b`) — the
   reformat is the base, the 3 new keys added, `%lld Projects` restored; no German lost. **Human-verify carries**
   below.

---

## Sharing — export & share a node's grounded recall — DONE (2026-07-08, merged to `main` `90348db`)

**Shipped.** A Share action renders a node's recall as an **English Markdown snapshot** and hands it to the
macOS share sheet (SwiftUI `ShareLink`) + copy/paste, from the **detail column toolbar** (and the ⌘⌥N recall
window, inherited) and a **"Share Recall…" node context-menu** item. **Summaries only — verbatim provenance
quotes never leave the device** (a loose end's summary already passed the in-app grounding gate, so exporting it
without its quote is a grounded summary, not a fabrication; the trust gate is untouched). One tested **pure**
PensieveKit builder `RecallMarkdown.render(node:narration:looseEnds:events:now:)` (no DB/LLM/localization; fixed
English headers, capitalized raw kind/state, `yyyy-MM-dd` dates; a unit test asserts the verbatim quote never
appears) + thin app wiring (`AppModel.recallMarkdown(for:)` reuses `detail(for:)`; the toolbar `ShareLink` builds
from `DetailView`'s loaded `@State` — no DB in `body`; the context-menu `ShareLink` builds lazily on menu-open).
Narration is included **only if already cached** (a share never blocks on an LLM call). German l10n of the one
new chrome label (`"Share Recall…"` → `"Rückblick teilen…"`); the exported document stays English by design.
Subagent-driven (3 tasks: Sonnet impl+task-review each; **Opus** whole-branch = READY-TO-MERGE, 0
Critical/Important). **211 tests** (+6 Kit). No entitlement/schema/capture changes. Spec/plan:
`{specs,plans}/2026-07-08-share-node-recall*`.

**Deferred (out of this first cut, not foreclosed):** file export (Save panel → `.md`/PDF) and a "Share with
provenance (quotes)" opt-in variant — both build atop the same `RecallMarkdown` builder; a shareable **link** /
collaborative sharing (needs CloudKit, itself gated on a paid team — see the App-Groups deferral above);
recursive/subtree recall. **Deferred Minors** (non-blocking): whitespace-only narration/description would render
a blank-looking section (upstream-gated); a one-frame transient on ⌘R/node-switch where a Share tap could omit a
recap the screen still shows (bounded by one LLM call; narration is best-effort in the export). **Human-verify
carries** below.

---

## App layout + inline provenance rework — DONE (2026-07-08, merged to `main` `59688e4`)

**Fixed recurring pane-sizing bugs and retired the ⌘⌥I provenance inspector in favor of inline provenance.**
An interactive `systematic-debugging` session on `main` (not subagent-driven), user-verified via screenshots
(the accessibility sandbox blocks scripting window resize/toggle here). Reached `systematic-debugging` Phase 4.5
after 3 failed inspector patches **plus an AppKit crash** (`_updateSidebarPositionIfNeeded` →
`_tileTitlebarAndRedisplay`, from toggling the sidebar with the inspector open) → questioned the architecture →
user chose inline provenance.

- **Layout (platform-native, Mail-like):** the sidebar toggle is the **native `NavigationSplitView` toggle** via
  a `columnVisibility` binding (not a custom button); Refresh dropped from the toolbar (still ⌘R / Go ▸ Refresh)
  so the toggle isn't pushed to a `»` overflow. **Column drag limits** (sidebar 200–320, content 240–420,
  **detail min 360 floor-only → flexible**) end the divider-drag corruption + the "detail won't grow" bug.
  **Honest window min 860.** Reading column widened to **760** and centered in a wide detail pane.
- **Provenance (inline, unified):** deleted `InspectorView`; removed `showInspector`/`inspectedLooseEndID`/⌘⌥I.
  A window-level `.inspector` as a 4th region on the 3-column split overflowed the window and crashed AppKit's
  titlebar tiling. Now a loose end **expands inline** to a soft rounded box: a couple-line preview of the cited
  line + **Show more/less** disclosure to the full surrounding transcript (cited highlighted, neighbors dimmed);
  honest quote+note fallback when the transcript is gone. The tested `ProvenanceContext` kernel is unchanged —
  now consumed inline by `LooseEndRow`. German for the new chrome (`Show more/less`).
- App-target only; **PensieveKit unchanged (211 tests)**. No spec/plan (a bug-fix). **Why:** four resizable
  regions (3-column split + `.inspector`) is more than macOS reliably fits/tiles — the inline box is bounded by
  the detail column, so it always fits (children just get narrower), removing the whole class of clip/crash bugs.
- **Deferred/notes:** the inline provenance box has no pixel-measured truncation (it previews the cited line and
  discloses the rest by message count); fill tint / corner radius / preview length are easy to tune.

---

## Menu-bar item + `pensieve://` deep links (v0.2) — DONE (2026-07-06)

**Shipped** on `main` (`a74af56`; spec/plan `{specs,plans}/2026-07-06-menu-bar-deeplinks*`). 144 tests,
subagent-driven with per-task review gates + an Opus whole-branch review + `/simplify`. Delivered: a
`MenuBarExtra` `.window` popover in the *same* app (heartbeat over `MonitorSnapshot` + top-5 What's Next over
`SmartLists`; status by glyph shape); a tested `DeepLink` router (`Sources/PensieveKit/Support/DeepLink.swift`)
for the registered `pensieve://` scheme; internal in-process jump-in + external opens via
`NSApplicationDelegateAdaptor` → `pendingDeepLink` → always-mounted label `.onChange` →
`PaletteDestination.apply(to:)`. Scheme registered via an XcodeGen-managed Info.plist. Additive only.

### Deferred out of v0.2 (on the roadmap, not foreclosed)

- **`LSUIElement` / hide-dock toggle** — ✅ **DONE (2026-07-08, merged `9de6d18`)** as a knob in the new App
  Settings surface. Flips `NSApp.setActivationPolicy(.regular ↔ .accessory)` at launch + live on toggle.
- **Menu-bar icon count badge** — a numeric open-loose-ends / what's-next count on the menu-bar glyph itself
  (kept icon-only for v0.2). *Trigger: if the glance wants an at-rest number without opening the popover.*
- **Dormant / Recently-Active peek in the popover** — the popover shows What's Next only; the other two smart
  lists live behind "Open Pensieve." *Trigger: if the menu-bar glance should surface dormancy directly.*

### Small follow-ups / notes (deferred, non-blocking)

- **`DeepLink` parsing is lenient** — accepts a trailing slash (`pensieve://briefing/`) and ignores
  query/fragment. Only ever *more* permissive on otherwise-valid links; never wrong. *Tighten only if a future
  external caller needs strictness.*
- **Simultaneous multi-URL batch opens are last-wins** — `AppDelegate.application(_:open:)` collapses a batch
  to the final link (a `DeepLink?` buffer). Fine for a single-user tool.
- **`DeepLink.url` (serialize) has no production consumer yet** — internal clicks pass `DeepLink` values
  directly; external entry only *parses*. It's the symmetric, test-exercised half of the foundational scheme,
  kept for future surfaces (Spotlight/widgets/notifications) that will *emit* `pensieve://` links.
- **Pending-human visual check** — the interactive popover click-through (popover renders; a row-click jumps
  into the window) was not machine-verified (accessibility-restricted + crowded-desktop here); C1 (external
  `pensieve://` fronts the app) *was* verified at runtime. A ~10 s eyeball on next build closes it.

---

## Phase 1B-org: the typed tree & strands — DONE (2026-07-04)

**Shipped** on branch `phase-1b-org` (plan: `plans/2026-07-04-pensieve-phase1b-org.md`, spec:
`specs/2026-07-03-pensieve-phase1b-org-design.md`). 75 tests, subagent-driven with a per-task
review gate + an opus whole-branch review. Delivered: the `Project→Node` rename + strict
recursive typed tree; git-common-dir source keying (worktree unification); conservative
tag-then-materialize strand birth (≥2 same-kind events) with lossless repoint of events **and**
their loose ends; `SessionStart` hook + `SessionBranch`; on-device strand naming; `group()`
child re-parenting; organizing CLI + tree `list`. Additive migrations v4–v6; trust gate untouched.

### Deferred out of 1B-org (on the roadmap, not foreclosed)

- **Domain-level recursive rollup** summaries (CTE over descendants) so `status <domain>` shows
  loose ends sitting in child strands. *Trigger: when the tree is deep enough to want rollups.*
- **Per-kind ingestion-handler protocol** (fingerprint/enrich/extract) — a `switch` suffices for
  git+session. *Trigger: a 4th source type.*
- **Cross-cutting soft references** (`node_links`, cycles allowed).
- **Evidence-based loose-end auto-close** (1B/1B-org only surface + age; never auto-close).
- **`SessionEnd` auto-ingest wiring** — session *content* ingestion still runs via
  `pensieve ingest-session --path`; auto-triggering it from a hook is deferred.
- **Retroactive worktree-merge / source re-keying in migration** — v4–v6 do NOT re-key
  pre-1B-org sources to common-dir; a pre-existing repo forks into a new node on its next
  post-upgrade ingest (lossless, fixable with `group()`). Accepted per spec §8.

### Small follow-ups from the 1B-org whole-branch review (deferred, non-blocking)

- **`nest` / `add --parent` cycle guard** — no check prevents nesting a node under its own
  descendant; a resulting cycle becomes an island `list` silently drops (no infinite loop).
  Add a walk-to-root guard. *Protects the `list` view, the tool's main surface.*
- **`NodeCommands.find` name-collision handling** — name-addressed CLI resolves an arbitrary
  row when two nodes share a name (plausible: two `auth` strands). UUID is the preferred path;
  add an "ambiguous name" guard or note it in help text.
- **`SettingsHookInstaller` presence check** is a substring `.contains("capture-session-start")`
  (low risk; our own command string).
- **`SessionBranch` has no retention/GC** — one row per session forever (fine at single-user scale).
- **True v3→v4 upgrade test** — `SchemaV4Tests` exercises the head schema but not a seeded
  pre-v4 `projects` row migrated through v4 (GRDB migrator exposes no `upTo:` seam via
  `openCanonicalDatabase`; migration SQL is simple + additive).

### From the 2026-07-04 real-data validation run

- **Strand naming echoes the newest commit** — on-device naming tends to reuse the most recent
  commit's subject as the strand name rather than synthesizing across the branch's activity
  (real run: a `feat/compose-swarm-reconciliation` strand got named *"Improved code formatting"*
  after its newest commit). Best-effort metadata, **outside the trust gate by design**, and
  fixable with `rename`. *Revisit if strand labels feel consistently off; the naming prompt could
  weight the branchKey and the span of commits, not just the latest summary.* The description was
  correctly grounded — only the short name is weak.
- **(FIXED 2026-07-04) Fractional-second timestamps** — `TranscriptParser` used a default
  `ISO8601DateFormatter`, which rejects Claude Code's `…:43.382Z` timestamps, leaving
  `startedAt`/`endedAt` nil so every session event was stamped at ingest time and dormancy read
  `0d`. Fixed (fractional-then-plain fallback) + regression test `parsesFractionalSecondTimestamps`.

---

## Pensieve.app v0.1: the heartbeat window — DONE (2026-07-04)

**Shipped** on branch `feat/pensieve-app-heartbeat` (plan: `plans/2026-07-04-pensieve-app-heartbeat.md`, spec:
`specs/2026-07-04-pensieve-app-heartbeat-design.md`). 82 tests. Delivered: native read-only SwiftUI
heartbeat window (`swift run PensieveApp`) over a shared, testable `MonitorSnapshot` kernel (pure gather
function, never throws, read-only, WAL-safe). Window shows status dot (active/idle/not-set-up), last-capture
age, spool/event/loose-end counts, polls every 3 s. Unbundled SwiftPM executable (no Xcode, no `.app`
bundle yet).

### Deferred out of v0.1 (on the roadmap, not foreclosed)

- **Menu-bar item / `LSUIElement` app bundle** — the heartbeat window currently runs as an unbundled
  SwiftPM executable (dock icon, focus behavior still to be confirmed). Next phase wraps it in a proper
  `.app` bundle and adds a menu-bar item with `LSUIElement` to hide the dock icon. Own spec required; 
  revisit the Xcode.app decision there (Command Line Tools suffice for now; Xcode.app may be needed 
  for code signing, menu-bar item setup, or `.app` bundle best practices).

### Small follow-ups from v0.1 (deferred, non-blocking)

- **`lastCaptureAt` has no staleness cap** — a node with an ancient capture and 0 events currently reads
  `idle` not `not-set-up` (incorrect signal). Add a staleness check: if `lastCaptureAt` is older than a
  configured threshold (e.g. 30 days), and `eventCount == 0`, treat as `notSetUp`. *Fixes the edge case
  where a dormant project looks "idle" rather than "never started."*
- **Unbundled window visual behavior** — dock icon presence, focus/activation behavior, and close-on-⌘W
  exit behavior of the unbundled `NSApplication` are still to be confirmed at the menu-bar step (Step 1 
  verified a window appears, but in-situ behavior may differ once menu-bar integration is added).

---

## Source discovery (`pensieve scan`) — DONE (2026-07-04)

**Shipped** on branch `feat/source-discovery`. 96 tests. Delivered: filesystem-source abstraction
(`FileSystemSourceType`, `DiscoveredSource`, `DiscoveryCandidate`, `GitSource` with `.git`-directory rule),
write-free walk (`SourceScanner.discover`), best-effort registration + hook install (`SourceScanner.accept`),
CLI `pensieve scan <folder> [--recursive] [--accept]`.

### Deferred out of source discovery (on the roadmap, not foreclosed)

- **Proactively suggest new projects learned implicitly** — from session current working directories and
  commits in unregistered repos, infer candidate projects the user works on but hasn't registered yet.
  Auto-surface as a `next` suggestion. *Trigger: once capture is flowing from multiple sources.*
- **Pass 2: source-discovery settings window** — folder picker, recursive toggle, checkbox candidate list.
  May persist watched folders for periodic rescans. *Pair with the menu-bar step (v0.2);
  brings source discovery into the app proper.*

### Small follow-ups from the source-discovery whole-branch review (deferred, non-blocking)

- **`SourceScanner`'s `(kind, identityKey)` dedup set is untested (near-dead code).** Because
  `GitSource.detect` requires a `.git` *directory*, no non-symlink walk path reaches the same repo
  twice, so the dedup collision branch never fires with the current single kind. A direct unit test
  with a stub `FileSystemSourceType` emitting two `DiscoveredSource`s that share one `identityKey`
  would close the gap. Low risk; the dedup is insurance for future kinds.
- **`normalizedDirectory` builds its URL with `isDirectory: false`** (a directory mislabeled as a
  file) to preserve `URL ==` equality with test-created repo URLs. Fix to `isDirectory: true` when
  the affected tests are switched to compare `.path` instead of whole-`URL` equality.
- **Idempotent-accept test doesn't assert `setupFailed` stayed empty** on the second `accept`.

---

## Native localization — German & English

**Requested:** 2026-07-04. Moritz runs macOS in German but may switch to English; Pensieve
should support both via **native macOS facilities** (no custom i18n layer).

**The native path:** SwiftUI `String(localized:)` / `LocalizedStringKey` + `.strings`/`.xcstrings`
catalogs, with the app following the system language automatically (`AppleLanguages`). Format dates
via `Date.FormatStyle` / `RelativeDateTimeFormatter` (already locale-aware) and numbers via
locale-aware formatters — no hardcoded strings in views. Applies to the SwiftUI app surface
(`PensieveApp` and later three-pane views), NOT the CLI or captured/user data.

**Scope boundary (grounding caveat):** localize only *chrome* — labels, buttons, status words
("active"/"idle"), section titles. **Never translate captured content, quotes, loose-end text, or
LLM-generated strand names** — those are provenance-bearing user data and must stay verbatim.

*Trigger: when the app grows real UI text worth translating (menu-bar step or the three-pane app);
premature to catalog the two-label heartbeat window alone.*

---

## Spike: statistical theme discovery across strands (`NLEmbedding`)

**Parked:** 2026-07-03, during Phase 1B brainstorming.
**Revisit when:** the grounded loose-end/summary layer (1B) is proven and we want the
"broad picture of how strands unfold across the whole tree" — i.e. surfacing
*recurring cross-cutting themes* ("you keep touching auth across three projects")
rather than per-project state.

**Idea:** use unsupervised statistical analysis (word2vec-style embeddings +
clustering) over captured session/commit text and extracted loose ends to surface
recurring themes and candidate cross-cutting strands/concepts automatically.

**Constraints & the native path:**
- **No Python, ever.** The Swift-native route is Apple's `NLEmbedding` (the
  `NaturalLanguage` framework) for on-device word/sentence embeddings — no API key,
  no external service, runs locally. This is the intended implementation surface.
- **Grounding caveat (important).** Opaque embedding clusters are hard to *cite*,
  which cuts against Pensieve's provenance-or-it-doesn't-exist north star. When we
  build this, prefer using embeddings as a *retrieval/grouping aid* that feeds a
  grounded LLM synthesis (which can cite real captured text), rather than surfacing
  raw clusters as if they were findings. Themes must still trace to captured text.

**Why it's a perfect Pensieve dogfood case:** this note is itself a `concept`/`topic`
— a targeted exploration parked for later. When Pensieve can track a strand like this
(let me forget it for a month, then reload full context and continue), it's working.

---

## App: capture & instruct by talking to the system (prompt input → chat)

**Requested:** 2026-07-05.

**Idea, in two stages:**
1. **Capture a strand by describing it** — a prompt/text input in the Pensieve UI where I
   type a description of a new strand and it gets created (name + `description` + `kind`,
   parented sensibly). The lightweight "quick add a thing I'm about to work on" surface,
   as opposed to auto-birth from ≥2 captured events. Pairs with the organizing CLI
   (`add-node`) but conversational and in-app.
2. **Talk to the system** — a fuller Claude/OpenAI/Gemini chat session embedded in the app
   for giving instructions in natural language ("nest auth under the platform node",
   "what did I leave open on the sync daemon", "start a strand for X"). The chat drives the
   same organizing/query operations the CLI exposes, plus grounded Q&A over captured state.

**Scope note:** stage 1 (structured strand creation from a prompt) is achievable early and
independently. Stage 2 (a full conversational agent surface) **can be deferred very late** —
it's a large surface and not on the critical path.

**Constraints & the native path:**
- **Provider-agnostic** via the existing `LLMProvider` protocol (default shells out to
  `claude -p`; I have a subscription, **no API key**). "Claude/OpenAI/Gemini" is a
  someday-choice, not a requirement — don't hardcode a vendor.
- **Grounding caveat.** When the chat *answers questions* about project state, it stays
  under the provenance north star — cite captured text, don't fabricate. When it *creates a
  strand* from my description, the name/description are my own words (user-authored metadata,
  outside the trust gate, like `rename`), which is fine.
- A prompt that creates or re-parents nodes is a **write** — it must go through the same
  validated operations as the CLI (`add-node`/`nest`/`group`), including the deferred
  cycle guard, not raw SQL from model output.

**Stage 1 now specced:** describe-a-strand → structured create is designed in
`specs/2026-07-05-pensieve-app-three-pane-design.md` (slice 5). Stage 2 (conversational agent)
stays deferred to its own later spec.

*Trigger: stage 1 once the app has real interactive UI (the three-pane app, past the
read-only heartbeat/menu-bar steps). Stage 2 much later, once the read/query surface is solid.*

---

## Forks as first-class: capture & visualize strand ancestry and orphans

**Requested:** 2026-07-05.

**The observation:** working is full of *forks*. Claude offers two choices and I pick one;
I branch off to do something adjacent; I switch to another branch and carry on there. Each
is a decision point that splits the work — and today the *road not taken* silently goes cold.
The strands most likely to be forgotten are exactly the ones orphaned at a fork.

**Idea:** make forks first-class in the strand model and surface them prominently, git-branch-like:
- **Capture the fork** — a strand carries not just a parent (containment) but a *branched-from*
  ancestry: which strand/decision-point it split off from, and when. Sibling strands sharing a
  fork point are visibly related.
- **Walk back the ancestry** — from any strand, trace its lineage back through the forks that
  produced it (distinct from the `parentID` containment tree — this is *temporal/causal*
  ancestry).
- **Surface orphans at a fork** — when a fork has branches I started and left dormant, show them
  as "picked up / left open" so I can consciously return to the road not taken.

**Constraints & the native path:**
- **Ground every fork in real captured signal**, not inference. Candidate sources already in
  hand: `SessionBranch` (a session's git branch), git branch creation/switch, worktree
  activity, and — harder — Claude offering explicit choices within a transcript. A fork edge
  should trace to a captured event, consistent with the north star.
- This is likely a **new edge type distinct from `parentID`** — closer to the deferred
  *cross-cutting soft references* (`node_links`, cycles allowed) than to the strict containment
  tree. Design it as causal/temporal lineage, not by overloading containment.
- Detecting "Claude presented two choices and I picked one" from a transcript is the ambitious
  part and may warrant its own spike; branch-switch forks from git/`SessionBranch` are the
  tractable first cut.
- **The full pannable "fork canvas" node-graph is parked here as a power-view** — a 2-D map of
  decision points to walk when many strands accumulate. The app starts with the lightweight
  *ancestry-trail + siblings* surface instead (chosen in the app design). Revisit the canvas once
  strand volume makes the trail feel cramped.

**App surface now specced:** the ancestry-trail + siblings view and the *Roads Not Taken* smart
list are designed in `specs/2026-07-05-pensieve-app-three-pane-design.md` (slice 6), gated on this
capture backend. This entry is the **capture backend** — the still-needed long pole; brainstorm it
on its own before that slice.

*Trigger: once strand auto-birth is proven in dogfooding and the app has a visualization surface
worth walking a tree in (the three-pane app). Branch-switch forks first; transcript-choice
detection as a later spike.*
