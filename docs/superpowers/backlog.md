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

The full loop is **LIVE and dogfooded** (439 tests). **`CLAUDE.md` Status is the authoritative,
exhaustive shipped changelog** — this is the short version. Shipped: capture → ingest → grounded/cited
loose ends → `next`/`digest` (1A/1B); the typed tree & strands (1B-org); source discovery (`scan`);
**background sync** via a bundled `SMAppService.agent` (retired the launchd daemon, pillar #3); the real
**`Pensieve.app`** (Xcode/XcodeGen bundle) three-pane app through slice 4 + visual identity, IA rework,
Share-recall, **archive nodes**, and **organizing-writes error surfacing**; the **bundled `pensieve` CLI**
(inside the app, symlink-managed); OS-integration — **menu-bar item + `pensieve://`**, **App Intents +
Spotlight**, **Focus filters**, **in-app find (⌘F)** (⌘K palette retired); intelligence config — the
**App Settings surface** (tabbed) with **on-device / `claude -p` / cloud provider** selection; and the
**MCP context server** (`pensieve mcp`/`prime` + `recall`). **The make-or-break intelligence gate passed.**
This is the hard part, done.

### Pending pillars (sequenced; each is a brainstorm → spec → plan item unless noted)

This is the durable index of *everything still to build*. Each pillar below needs its own
brainstorm→spec→plan cycle (the loop in `CONTINUE.md` → "How we work here"); the deferred-ledger
sections after the first `---` hold the parked depth-features + forward ideas, each with a revisit
trigger. Order is a recommendation, not a commitment.

1. **Menu-bar item / `LSUIElement` (v0.2)** — ✅ **DONE** (menu-bar item merged 2026-07-06; the
   `LSUIElement` hide-dock toggle shipped 2026-07-08 in the App Settings surface). Shipped: a `MenuBarExtra`
   `.window` popover (heartbeat over `MonitorSnapshot` + top-5 What's Next over `SmartLists`; status by glyph
   shape; click-to-jump) in the *same* app, plus the minimal, tested `pensieve://` `DeepLink` router as its
   first consumer. Spec/plan: `{specs,plans}/2026-07-06-menu-bar-deeplinks*`. **What remains (deferred →
   ledger below):** a menu-bar icon count badge; a Dormant/Recently-Active peek in the popover.

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

3. **Retire the launchd daemon → in-app background service (Phase 2)** — ✅ **DONE (2026-07-16, see the
   dated entry below).** The hand-installed `com.pensieve.sync` LaunchAgent + `install-daemon` command are
   gone, replaced by a code-signed `SMAppService.agent` (`me.mazetti.pensieve.sync`) bundled inside the app,
   running the same `SyncRunner` every 300 s independently of the GUI (no force-quit gap). App owns
   register/unregister/status via `BackgroundSyncService` (Settings toggle + status + open-Login-Items); the
   app boots out the legacy agent on first launch. *(The app also still self-drains while foregrounded via
   the FSEvents spool watch + `Debouncer` → `drainThenRefresh`.)*

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

**Cloud/API LLM provider + Keychain-stored key + model selection — ✅ DONE (2026-07-09, merged to `main`
`34a2bb9`).** The motivating long-term case, now shipped: an **app-only** cloud (HTTP) `LLMProvider`
(Anthropic + OpenAI-compatible, one flavor-switched struct) driving the app's best-effort narration. **Kit
(tested):** `CloudFlavor`/`CloudConfig` + pure `CloudHTTP` builders/parsers (per-flavor suffixes, no `/v1`
double, trailing-slash-safe) + `CloudLLMProvider` (`complete` + static `listModels`) over an injected transport;
`KeychainSecretStore` (generic-password, `account=flavor`). **Storage:** retired `preferences.json` — selection +
non-secret config in **UserDefaults** (`me.mazetti.pensieve`), read cross-process by the CLI/daemon via
`PensieveDefaults.shared()` (no daemon regression: a `.cloud` selection the keyless CLI reads falls back to local).
API key is **Keychain-only**. Settings cloud subsection (flavor / base URL / key / model + Fetch = populate *and*
validate) + German l10n; **trust gate untouched** (cloud = narration only, extraction stays on-device).
Subagent-driven (7 tasks + fix wave; Opus whole-branch READY-TO-MERGE). **260 tests.** Spec/plan:
`{specs,plans}/2026-07-08-cloud-llm-provider-design.md` + `2026-07-09-cloud-llm-provider.md`. **Out of scope
(deferred, not foreclosed):** cloud extraction, streaming, per-request cost/telemetry, daemon/CLI cloud use.
**Post-merge carry:** rebuild + reinstall the release CLI (the provider-selection read changed).

**Deferred out of the first cut (on the roadmap, not foreclosed):**
- **Organizing-writes error surfacing** (code-quality carry) — ✅ **DONE (2026-07-14)** with the Settings v2
  work: `AppError`/`presentedError` → one `.alert` on `RootView`, all six writes classify refusal vs failure.
  See the "App Settings v2 + organizing-writes error surfacing" dated entry below.
- **Tabbed multi-pane Settings** — ✅ **DONE (2026-07-14)**: General · Intelligence · Advanced. Remaining
  knobs as they arise (capture/scan source-management GUI, daemon-interval editing — Spec 2, own brainstorm).

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
- **Spotlight indexing** — ✅ **DONE (v0.3, 2026-07-06)** as the **App Intents foundation** pillar (spec+plan `{specs,plans}/2026-07-06-app-intents-foundation*`). Nodes as `IndexedEntity` (macOS 15+) *on* App Intents, not standalone Core Spotlight — one `NodeEntity` serves Spotlight content + Siri + Shortcuts + Open-Node/Show-Pensieve-List intents; clear-then-index on launch + ⌘R. **Future extensions (roadmap):** index loose-end text (**1b**, still open); **semantic / vector search** — ✅ **DONE (2026-07-18, in-app ⌘F + MCP)** via `NLContextualEmbedding` + `sqlite-vec` (see the dated entry below); native *Spotlight* semantic indexing specifically remains open; live/background re-indexing (slice-3 liveness); `.text` vs `.content` attribute-set refinement if body matching underperforms. Part of pillar #5.
- **In-app find (search captured content)** — ✅ **DONE (2026-07-11, merged to `main` `02bb0a1`)** as **Track C sub-project 1a**. Native `.searchable` field + ⌘F over the grounded core corpus (node name/description, open loose-end text/quote), grouped results in the content column, land-on-the-cited-row (auto-expand + scroll); Focus-scoped; tested `SnippetMaker` + `SearchQueries` Kit kernels; ⌘K palette retired (nav core retained). Spec/plan: `{specs,plans}/2026-07-10-in-app-find*`. **Deferred siblings:** **1b** — index loose-end text into Spotlight (own spec, still open); **#2** — semantic/vector recall — ✅ **DONE (2026-07-18, `e640645`)**, see the dated entry below (`NLContextualEmbedding` + `sqlite-vec`, ⌘F "Related" + MCP `search`). **Follow-up carry — ✅ DONE (2026-07-11, `192641d`):** a description-only node hit now leads with `hit.name` (primary) + the description snippet (secondary); name-matches keep the highlighted name + kind. `NodeHit.matchedField` drives the layout. Debounced search input + consolidated search-mode state landed alongside (`15594ee`).
- **Notifications** (UserNotifications) — *small–medium; strong but sparing.* Grounded nudges (left-open, briefing-ready, dormant); noise risk → rare + cited.
- **Dock tile** — *tiny; marginal.* Open-loose-ends badge + a recent-projects dock menu.

**B — Intents & automation (hub: App Intents — build once, light up all)**
- **Siri / Apple Intelligence** — *medium, Xcode-gated; strong.* Grounded Q&A + describe→create strand. Part of pillar #5.
- **Shortcuts** — *medium; strong.* User-composable automations over the same intents.
- **Spotlight actions** (App Intents in Spotlight, expanded in macOS 26) — *small atop App Intents; good.* Run actions by typing.
- **Focus filters** (`SetFocusFilterIntent`) — ✅ **DONE (2026-07-07, merged to `main` `171c0e6`).** A macOS Focus restricts the main window + menu-bar + Spotlight to its context. Shipped: migration v9 `nodes.context` (`work`/`personal`/unset) + tested `NodeContextResolver` (subtree inheritance + mute-opposite/show-unset predicate); `PensieveFocusFilter: SetFocusFilterIntent` (optional param = deactivation signal) → `UserDefaults` → `AppModel` observes + re-filters + reindexes; a Context picker in the New/Edit modal; German l10n. Spec/plan: `{specs,plans}/2026-07-07-focus-filters*`. **Deferred follow-ups:** notification muting ("mute personal nudges" — moot until notifications exist); a bulk/right-click "Set Context" action; >2 contexts; CLI `--context`. **⚠️ BLOCKED at runtime (2026-08-11): ad-hoc signing.** The filter appears in System Settings but **"Add" is permanently disabled** — `linkd` refuses an app with no Team ID (`requiresValidatedBundle`), so the sheet can never prepare the intent instance. Diagnosed in full in `CLAUDE.md`; needs an Apple-issued signing cert (no self-signed workaround — team IDs come only from Apple-issued certs). Until then the Work/Personal machinery is reachable only by writing `pensieve.activeFocusContext` in `UserDefaults` directly; **an in-app manual Context switcher is the obvious unblocked alternative and wants its own brainstorm.**
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

## Competitive scan — ideas worth stealing from Contextify (2026-08-02)

[Contextify](https://contextify.sh) (Perch Innovations; free + $8–15/mo) is the closest thing to
Pensieve found in the wild: a macOS app that indexes Claude Code **and Codex** transcripts into a
local SQLite FTS index, shows a live timeline with per-message LLM summaries (Apple Intelligence on
Tahoe), and feeds search back to the agent. Reviewed: marketing site, docs tree (Total Recall, Live
Recall, ingestion, CLI), App Store listing + release notes, cloud/teams/pricing.

**The overlap is narrower than it looks.** Contextify indexes *transcripts*; Pensieve reconstructs
*project state*. They have no loose ends, no trust gate, no typed node/strand tree, no git commits as
events (they only *anchor by* touched files), no Briefing, no semantic recall. Their "project" is a
directory — the thing our core principle explicitly rejects. Their thesis is an **ambient flow
monitor** ("watch the AI work"); ours is **reload context after the session scrolls away**.

Items below are ordered by value×cheapness for *us*. Items 1–3 are one coherent spec; 4–5 a second,
much smaller one.

> **Status 2026-08-11 — items 1, 2, 3 SHIPPED and item 4 PARTLY shipped**, as the retrieval
> P1+P2′ branch (spec `2026-07-28-retrieval-eval-harness-design.md`). **1**: file paths are indexed in
> their own FTS5 table and reachable from ⌘F and MCP `search`'s structured `file` parameter. **2**: the
> exact and semantic halves now share **one** corpus (`EmbeddableCorpus`), closing the asymmetry.
> **3**: FTS5 + `bm25()` replaced the substring matcher outright, so multi-word queries are token-AND
> ranked instead of all-or-nothing — and it replaced the *vector* path as the default too, which is how
> the inert-floor defect above got closed. **4**: MCP `search` returns an `index_state` distinguishing
> an unbuilt index from a real miss; the *daemon-age* half ("last synced 40 min ago") is NOT done.
> Left open below: **5** (`pensieve doctor`), **6** (folded into transcript chunking), **7** (Live
> Recall, parked), **8** (skill + researcher subagent). Stemming became P3's `bm25Porter` strategy —
> our evidence neither supports nor refutes it, so it is measured rather than assumed.

- **1. ⭐ Git-anchored search — find sessions by the files they touched.** *Small; the data is
  already captured.* `Ingester.swift:355` runs `git show --name-only` and stores the changed-file
  list in `Event.detailJSON["files"]` — we capture it and never search it. "What was I doing last
  time I touched `SemanticQueries.swift`?" is *exactly* the reload-context question Pensieve exists
  to answer, and the one query where a file path beats both keywords and embeddings. Wants a `file:`
  anchor across ⌘F and the MCP `search` tool. *Revisit trigger:* now — it's the cheapest real win on
  this list.
- **2. Events are absent from the exact-search corpus.** *Small–medium; found while checking #1, not
  a Contextify idea.* `SearchQueries.search` covers node name/description + open loose-end
  text/quote **only** (`SearchQueries.swift:51`). Commit subjects and file lists are invisible to
  ⌘F; they reach the semantic index alone, via `EmbeddableCorpus`. So the exact and semantic halves
  of ⌘F search *different corpora* — an asymmetry nothing documents and nobody chose.
- **3. Real full-text matching (FTS5 + stemming + bm25).** *Medium; touches a load-bearing kernel.*
  `SearchQueries` does a single whole-string `range(of:options:.caseInsensitive)`, so **multi-word
  queries are all-or-nothing substrings**: `focus filter spotlight` returns nothing unless that exact
  phrase exists verbatim. Contextify's pitch is stemming ("matches deploy, deployed, deployment") but
  **token-based AND matching + bm25 ranking is the bigger win** — substring can't express it at all.
  Semantic "Related" partly masks this today; note the interaction with the inert-floor defect above
  (a real lexical signal is also one of that item's candidate remedies — **hybrid retrieval** — so
  these two should be specced with each other in view).
- **4. Honest staleness reporting on the retrieval path.** *Small; strongly on-brand.* Before Live
  Recall blocks, Contextify checks index liveness and **reports the age plus remediation** rather
  than silently returning nothing. Same value as our trust gate applied to retrieval: an MCP `search`
  that comes back empty because the daemon last ran 40 min ago should say so. `SystemStatus` already
  computes this — it just isn't wired into the MCP/CLI answer path.
- **5. `pensieve doctor`.** *Small.* One command checking the whole install surface — `~/.local/bin`
  symlink, SessionStart/SessionEnd hooks, MCP registration, SMAppService approval, sync-log age,
  semantic-index version, Spotlight index. Our surface has more moving parts than theirs and
  diagnosing it currently means re-reading CLAUDE.md's gotcha list.
- **6. Entry classes for transcript chunking.** *Folds into an existing deferred item.* Contextify
  1.7.7 added "command runs and summaries" as distinct indexed entry types. Refinement to our
  deferred **transcript-passage chunking** spec: don't chunk into undifferentiated text — classify
  passages (prompt / tool run / assistant summary) so search can filter by kind. *Revisit trigger:*
  when transcript-passage chunking is specced.
- **7. Live Recall (`watch` / `tail` / `since`).** *Medium–large; novel but off-axis.* Their most
  original feature: block until a matching entry appears, stream matches as JSON, or fetch everything
  since a checkpoint — so one agent session can wait on another worktree's progress. We're
  technically well placed (FSEvents + `ValueObservation` + the spool all exist). But it is
  **coordination, not recall** — a different product axis. Parked deliberately. *Revisit trigger:*
  parallel-worktree sessions become a routine workflow and the hand-off friction is felt.
- **8. Skill + researcher-subagent alongside MCP.** *Small; complements the shipped MCP server.*
  Their Total Recall is a **skill** shelling out to the CLI, *not* MCP — zero always-loaded tool
  schema, invoked deliberately. Plus a `contextify-researcher` agent that fans out multiple queries
  and synthesizes. A fan-out researcher over `pensieve search` is a pattern our MCP tools can't
  express today.

**Deliberately NOT stealing.** Cloud / teams / self-hosted / pricing (not a product). **Codex as a
source type** — would validate the `SourceKind` abstraction, but only worth it if Codex actually
enters the workflow. **Per-message live summaries + always-on-top monitor window** — their core
thesis and the opposite of ours; adopting it would blur the north star (the adjacent piece that *is*
ours is the long-standing per-project **timeline** loose end). **⌘K "family tabs" project switcher** —
our typed tree is richer and ⌘K was retired deliberately for ⌘F.

**Where we're ahead** (worth remembering when scoping): loose ends with cited provenance + the trust
gate; git commits as first-class events; the node/strand tree vs flat directories; Briefing; Focus
filters, App Intents, Spotlight, deep links; semantic/vector recall (they appear FTS-only); MCP
`recall` returning the surrounding transcript window rather than a pointer.

---

## Semantic relevance floor — CLOSED by removing the engine (2026-08-11)

**The floor no longer exists, because the engine no longer exists.** This entry was first closed as
*quarantined* — the vector path retained but default-off — which meant the compressed-cosine problem had
been taken off the default path rather than solved, and enabling the toggle reinstated it in full. That
half-measure is gone: `SemanticQueries`, its `floor: 0.25`, the embedder, the `vec0` store and the
vendored `sqlite-vec` target were **deleted** (plan `2026-08-11-remove-vector-search.md`). There is no
toggle left to enable, so nothing can reinstate the behaviour measured below.

**⚠️ Why it was removed rather than left quarantined — observed live 2026-08-11.** Only the *unset*
default had changed; the reader deliberately honoured an explicitly stored `true`. Semantic search
shipped **default-ON** on 2026-07-18, and this machine had `app.semanticSearch = 1` persisted in
`~/Library/Preferences/me.mazetti.pensieve.plist` — so after the BM25 ship the vector engine was **still
running**, and `pensieve mcp search "focus filter spotlight"` returned two unrelated projects at
0.886/0.878 beneath the correct BM25 top hit. "Quarantined behind a default-off toggle" was true of the
code and false of the only machine that runs it. **General lesson: flipping a default is not a
migration** — a shipped default-on toggle leaves persisted `true`s behind on every machine that ever ran
it, and no code review can see that. The persisted key is now inert (nothing reads it); clear it with
`defaults delete me.mazetti.pensieve app.semanticSearch`.

**Resolved, but not the way this entry predicted — read the correction before reusing anything below.**
The measurements were right and the *diagnosis* was wrong: it was a **ranking failure, not a scale
failure.** Mean-pooled `NLContextualEmbedding` was never a sentence-similarity encoder, so no floor —
absolute, centered, or percentile-calibrated — could have separated a topical match from gibberish.
Every remedy this entry proposed (mean-centering, empirical percentile) would have been work spent
calibrating a signal that carries too little information to calibrate.

What shipped instead (spec `2026-07-28-retrieval-eval-harness-design.md`, plan
`2026-08-03-retrieval-bm25-single-path.md`): **FTS5/BM25 became the search engine**, replacing BOTH the
inert vector path *and* the old whole-string substring matcher. The vector stack was retained
default-off at that point and **deleted outright on 2026-08-11**. Measured paired on the real corpus
(n=1500): BM25 P@1 **0.395** vs vector **0.255**. **The floor is gone rather than retuned** — BM25
scores are unbounded and per-query-scaled, so a fixed cutoff was never meaningful for it either.
Relevance is now bounded by rank plus the requirement that a document actually contain the query
terms. **A rank cap is not a relevance threshold**, and nothing here claims otherwise.

**The measurement discipline is the reusable part**, not the conclusion: the probes live in
`docs/superpowers/measurements/2026-07-28-retrieval-recall/`, and the pre-registered verification gate
*rejected* the plan's own primary design on paired evidence (McNemar p = 0.017) rather than shipping it.
**Still open — P3**, the one question this did not answer: see the roadmap entry below.

<details>
<summary>Original entry (2026-07-19) — kept for the measurements, which stand</summary>

## Semantic relevance floor is inert — OPEN DEFECT (found 2026-07-19, needs its own spec)

**The `floor: 0.25` similarity cutoff never rejects anything.** Measured against the live store via
`pensieve mcp` `search` right after the 2026-07-19 reinstall:

| Query | Top hit | Similarity |
|---|---|---|
| "German localization String Catalog" | the localization spec commit ✅ | 0.936 |
| "sqlite-vec vendored C target" | `feat(acl): allow tag:ci-pipeline-puppet SSH to panopticon` ❌ | 0.934 |
| "background sync agent login items" | `Log owner-mode seq-scan finding` ❌ | 0.921 |
| **"banana zeppelin custard velocipede"** (gibberish) | `checkout feat/pensieve-app-three-pane` | **0.880** |

Gibberish scores **0.880**; a perfect topical match scores **0.936**. The entire usable range is
~0.06 wide and sits far above the 0.25 floor (`Mcp.swift:210`, `AppModel.swift:531`).

**Consequences.** (1) ⌘F "Related" and MCP `search` **always** return a full result set regardless of
relevance — the grounding guards hold (every hit is a real cited item, nothing fabricated) but
relevance is not enforced at all. (2) Ranking is directionally correct yet so compressed that corpus
noise outranks true matches — see the sqlite-vec and background-sync rows. (3) *Reasoned, not
measured:* Part D's floor-aware early exit (`SemanticQueries.swift:46`) can never fire, so a
heavily-Focus-muted query should climb the grow-`k` loop to the `maxFetch=2000` cap instead of
exiting early — the inverse of that optimization's intent.

**Likely cause:** anisotropy of mean-pooled contextual embeddings — vectors occupy a narrow cone, so
raw cosine is compressed and offset far from zero. Short git-commit-subject documents amplify it.
**Candidate remedies (pick at spec time):** center embeddings against the corpus mean before
comparing; calibrate the floor empirically (percentile / z-score against a sampled baseline) instead
of an absolute constant; or hybrid retrieval blending a lexical signal so rare tokens like
"sqlite-vec" carry weight. **Not a one-line tweak** — a floor change alone would be guesswork without
a calibration method. *Revisit trigger:* next time semantic recall is touched, or sooner — this is
live, default-on, and currently diluting the grounded context fed to Claude via MCP.

</details>

## P3 — a paraphrase-only eval harness — OPEN, and blocked on the user

The one retrieval question still unanswered: **does any on-device strategy deliver "find without
remembering the words"?** Both candidates fail it today — on hand-written short paraphrase queries
`vector` scored ≈0/8 and `bm25` ≈2/8. BM25 winning the headline metric does not mean it can paraphrase;
it means it is less bad, and the same-node gold set that measured it uses **full documents as queries**,
which flatters lexical matching in a way real short typed queries do not.

**Blocked on one input only: 30–50 paraphrase queries the user writes**, from real recall needs, each
naming the item(s) it should find. That single choice is what dissolves LLM circularity and the leakage
guard — as sole user, your own queries *are* the ground truth. Design is already written (spec §P3):
two files (`RetrievalCorpus`, `RetrievalMetrics`), per-query-normalised operating-point search with an
explicit `NO VIABLE THRESHOLD` verdict, no ROC-AUC, strategies `bm25` / `bm25Porter` / `vector` /
`hybridRRF`, and a **pre-registered absolute floor** so the report can conclude "the incumbent is
unusable". *Revisit trigger:* when the gold set exists.

---

## Transcript rendering — deferred siblings (2026-07-19, split out of the readability spec)

Raised together while dogfooding the inline provenance view; **sub-project #1 (transcript
readability — role bubbles, XML-tag callouts, heading type scale) SHIPPED 2026-07-26** (merged to
`main` `4b184a3`; see CLAUDE.md ▸ Status). These two were split off because each is a different
*kind* of decision, not a styling one — **both revisit triggers are now live.**

- **Rich code blocks — syntax highlighting + diagram rendering.** *Medium–large; its own spec.*
  Transcript code fences currently render unhighlighted (MarkdownUI default). Two separable pieces:
  (1) **syntax highlighting** — needs a highlighter dependency (or a hand-rolled tokenizer for the
  handful of languages that actually appear: Swift, shell, JSON, Markdown); (2) **diagram
  rendering** — the harder half. **Note: the observed diagrams are Graphviz DOT** (`digraph … {}`
  emitted by skill docs), **not Mermaid**, though Claude emits both depending on context. Neither has
  a first-party macOS renderer: Mermaid means bundling mermaid.js in a `WKWebView`; DOT means a
  WebView (viz.js) or a Swift layout engine. Both collide with **"platform primitives first"** and
  add a heavyweight dependency to a view that today is pure SwiftUI. **Decide the DOT-vs-Mermaid
  question with real corpus evidence before committing** — a Mermaid-only renderer may buy nothing.
  *Revisit trigger:* transcript readability has shipped and code blocks are still the worst part of
  the view.
- **macOS Writing Tools on loose ends** (condense / summarize / explain). *Unknown feasibility;
  spike first.* **Open question that gates the whole idea:** Writing Tools attaches to the standard
  text system (`NSTextView`/`TextEditor`); MarkdownUI renders custom SwiftUI views, so Writing Tools
  may never appear in that hierarchy at all. **Do a small spike before any design.** Second gate is
  the **trust gate**: rewriting a loose end *in place* would mutate displayed provenance — the one
  thing that must stay verbatim. A read-only "explain this" overlay is a different, safer feature
  than "condense this text", and the spec must pick one deliberately. *Revisit trigger:* the spike
  proves Writing Tools reachable from the loose-end surface.

---

## Semantic / vector recall (Track C #2) — DONE (2026-07-18, merged to `main` `e640645`)

"Find without exact words" across ⌘F and MCP over one shared Kit kernel. **Native
`NLContextualEmbedding`** (per-token → mean-pooled → unit-normalized; by-script Latin covers EN+DE)
+ **`sqlite-vec`** vendored as a static SwiftPM C target (`Sources/CSQLiteVec`). Apple disables
process-global `sqlite3_auto_extension`, so it registers **per-connection** via GRDB
`Configuration.prepareDatabase` → `pensieve_sqlite_vec_init_connection`. The index is a **separate,
rebuildable, never-synced `semantic-index.sqlite`** (`vec0` + `node_id`/`state` metadata cols;
drop+rebuild on embedder-version/dimension change; busy `.timeout(5)`). **Kit (tested):**
`TextEmbedder`/`NLContextualEmbedder`, `SemanticIndexStore`, `EmbeddableItem`+`SemanticIndexer`
(**membership/metadata-driven** — prune by live `LooseEnd.isOpen`/`state`, repoint without re-embed,
embedder-nil skips-and-retries), `SemanticQueries` (**over-fetch** `k'=max(k*8,50)` + in-KNN `state`
filter, then `visibleNodeIDs`/floor; the canonical join **re-applies the live predicate** — last
grounding defense). **Grounded-retrieval-only, on-device only** (cloud never used), best-effort
throughout. **App:** ⌘F "Related" section + app-side index sync in `drainThenRefresh`; default-on
Settings ▸ Intelligence toggle (`PensieveDefaults.semanticSearchKey`, honored by app/daemon/MCP);
German. **MCP:** a unified `search` tool (exact+semantic blend — **subsumes the deferred keyword
sibling**). v1 corpus = active nodes + open loose ends + enriched events; the `EmbeddableItem` seam
makes transcripts/future sources additive. Subagent-driven (sqlite-vec GO/NO-GO spike + 8 tasks;
**Opus** whole-branch = READY-TO-MERGE, 0 Critical, 1 Important fixed = busy timeout; two real
defects caught+fixed — embedder-nil starvation, a non-failing over-fetch test). **439 tests.**
Spec/plan: `{specs,plans}/2026-07-18-semantic-vector-recall*`.

**Deferred (fast-follow, not foreclosed):** ✅ **expand-and-retry under heavy Focus-muting** (DONE
2026-07-19, `3ece8b5` — grow-`k` loop + floor-aware exit); ✅ **MCP per-call embedder/store caching**
(DONE 2026-07-19, `static let` hoist); ✅ **idempotent rebuild guard** (RESOLVED 2026-07-19 — proven
already race-safe via GRDB implicit `BEGIN IMMEDIATE`; a regression test pins the invariant, no code
change); per-hit `db.read` batching in `resolve`; ✅ **archived content in the semantic index /
"Related"** (DONE 2026-07-19, see the dedicated section below — `EmbeddableCorpus.gather` now indexes
archived nodes/items too, and `SemanticIndexStore.knn`/`SemanticQueries.search` grow an
`includeArchived` allow-list flag so the ⌘F Include-Archived toggle drives semantic results, not just
exact); **transcript-passage chunking** (the next corpus increment — its own spec; would also make
Part D's `maxFetch=2000` cap worth revisiting).
**Post-merge carry:** rebuild + reinstall the app to `/Applications` so the bundled `pensieve mcp`
exposes `search`. **Human-verify:** live MCP `search`; ⌘F "Related" after the NL asset downloads;
toggle-off → no Related + MCP exact-only; German "Verwandt" in situ.

---

## Archived content in the semantic index / "Related" — DONE (2026-07-19)

Closes the deferred item the semantic-recall-hardening batch left open (above): archived work is now
recallable through semantic search, not just exact ⌘F. **Kit (tested):** `EmbeddableCorpus.gather`
now indexes archived nodes and their loose ends/events too, tagged with the owning node's live
`state`; `SemanticIndexStore.knn` and `SemanticQueries.search` grow an **allow-list** `includeArchived`
flag (defaulted `false`); `resolve`'s canonical re-check predicate widens in lockstep so a stale/pruned
row can't leak through; `SemanticHit` (and `NodeHit`/`LooseEndHit`) carry `isArchived` for the caller
to badge. **App:** the existing ⌘F Include-Archived scope now drives **both** the exact and semantic
halves (previously exact-only) and badges archived rows in Related too. **MCP:** the `search` tool's
`include_archived` parameter now reaches semantic results, and its JSON `SearchItem` carries the
`archived` flag through all three hit types (a final whole-branch review caught this dropped at the
MCP boundary — fixed). Trust gate untouched — only which live rows are eligible to be returned changes,
never what may be said about them. **465 tests** (+1 Kit). Spec/plan:
`docs/superpowers/{specs,plans}/2026-07-19-archived-semantic-index*`. **Post-merge carry:** rebuild +
reinstall to `/Applications` so the bundled `pensieve mcp` and app pick up the widened search.

---

## Bundle the `pensieve` CLI into the app — DONE (2026-07-17, through `3a9092c` 2026-07-18)

Retired the standalone SwiftPM `pensieve` executable + the "rebuild + reinstall the release CLI"
step. The CLI is now an embedded Xcode **tool target** (`PensieveCLI`, `PRODUCT_NAME=pensieve` — the
target is renamed to dodge a case-insensitive-filesystem collision with the app target `Pensieve`;
the shipped binary is still `pensieve`) at `Pensieve.app/Contents/Helpers/pensieve`.
`~/.local/bin/pensieve` is an **app-managed symlink** to it, auto-created on launch when absent
(guarded off `.build` paths) and installable/repairable/replaceable via **Settings ▸ General ▸
Command-line tool**, over a tested `CLIToolInstaller` symlink kernel (`apply`/`replace` deduped via
`forceLink`). Git hooks, `~/.claude/settings.json`, and `claude mcp add` all resolve the CLI through
that symlink. **Updating the app now updates the CLI.** `swift run pensieve` no longer exists — build
via `xcodebuild -scheme PensieveCLI` (or the app scheme, which embeds it); PensieveKit + tests stay
SwiftPM. Spec/plan: `{specs,plans}/2026-07-16-bundle-cli-into-app-design.md` +
`2026-07-17-bundle-cli-into-app.md`.

---

## Background sync via a bundled `SMAppService.agent` — DONE (2026-07-16, = pillar #3)

Replaced the hand-installed `com.pensieve.sync` LaunchAgent with a code-signed agent
(`me.mazetti.pensieve.sync`) bundled inside the app. A committed, **home-independent** plist
(`Contents/Library/LaunchAgents/…`, `BundleProgram`, `StartInterval 300`, `ProcessType Background`)
schedules a thin in-bundle helper `Contents/Library/Helpers/PensieveSyncAgent` running the *same*
`SyncRunner`, exiting between runs. The helper resolves the machine-specific `PATH`
(`SyncAgentEnvironment.resolvedPATH` — launchd does no `~` expansion) and writes a **size-capped**
`sync.log` itself (keeping `SystemStatus.lastSyncAt`'s mtime honest). App owns register/unregister/
status via a thin `BackgroundSyncService` (Settings toggle + status + open-Login-Items), **guarded off
`.build` paths** (`BackgroundSyncGuard`) so a smoke-launch never touches real Login Items; it boots
out the legacy `com.pensieve.sync` on first launch. On-device provider only (trust gate unchanged).
**Gotchas:** must run from `/Applications/Pensieve.app` (SMAppService pins path + cdhash);
`registerIfNeeded()` does unregister+register to refresh the LWCR across ad-hoc cdhash churn (approval
persists — no re-prompt). Spec/plan: `{specs,plans}/2026-07-14-background-sync-smappservice-agent-design.md`
+ `2026-07-15-background-sync-smappservice-agent.md`.

---

## Cloud narration silently dead on the default setup path — FIXED (2026-07-14, `f35a9fd`)

**Was pre-existing on `main`**, not introduced by any recent branch (surfaced by the Settings v2 Opus
review, which confirmed `AppModel.cloudInputs()` was byte-identical to base). `@AppStorage` never
writes its own default, so a user who selected **Cloud (API)** and kept the default **Anthropic**
vendor left `cloudFlavor` unset; `cloudInputs()` read it with a bare `guard let`, returned
`(nil, nil)` ⇒ not configured ⇒ narration silently degraded to **local** while Settings still
displayed "Cloud (API)". Only *changing* the Vendor picker (which persists the key) made cloud run.

**Fix:** the derivation moved into a tested Kit `CloudConfig.fromDefaults(_:)` that falls back to
exactly what the UI displays for an untouched field (unset flavor ⇒ `.anthropic`, empty base URL ⇒
that flavor's default). "Not configured" is now expressed the way the resolver already checks it —
`isUsable` (needs a model) + a key — never by a nil config. `cloudInputs()` is a thin call into it,
so app and Kit can't drift. +2 Kit tests (402).

**Human-verify:** fresh defaults → ⌘, → pick **Cloud (API)**, leave the vendor on Anthropic, enter a
key + Fetch a model → open a node → the recap actually generates via the cloud model (previously it
silently ran local).

---

## App Settings v2 + organizing-writes error surfacing — DONE (2026-07-14, merged to `main` `d1fab6f`)

Spec 1 of 2 of the Settings follow-ups track. **Kit (tested):** `SystemStatus` gather kernel (+4
tests). **App:** the six organizing writes (create/rename/move/merge/delete + loose-end label) no
longer `try?`-swallow — each classifies its real return into a **refusal** (a non-success return =
stale state → refresh, then a non-alarming alert) or a **failure** (a real throw → alert, no refresh,
since an error says nothing about staleness), surfaced through one `.alert` on `RootView`. Settings
became a native tabbed shell (**General · Intelligence · Advanced**), the Advanced tab adds status
readouts + store paths, and About Pensieve is now the first-party `orderFrontStandardAboutPanel`.
Full German l10n. Spec/plan: `{specs,plans}/2026-07-12-app-settings-v2-error-surfacing-design.md` +
`2026-07-13-app-settings-v2-error-surfacing.md`.

**Process note:** implemented subagent-driven in a prior session (6 tasks, each review-clean; Opus
whole-branch review found **1 Important** — the Advanced tab re-derived the cloud config independently
of `AppModel.cloudInputs()` and the two were *not* equivalent, so a fresh Cloud install could narrate
**local** while the tab displayed "Cloud (API)"; fixed by making `cloudInputs()` the single resolution
path). That session was then lost. This session rebased it onto the archive-nodes main, resolved the
`AppModel` conflict, and did the **semantic integration** the rebase exposed: main's `archive`/
`unarchive` had arrived using the very `try?`-swallow pattern this branch removes, so both now route
through `refuse`/`fail` (+ German verb keys *archiviert* / *wiederhergestellt*). Opus reviewed the
integration delta → READY TO MERGE, 0 Critical/Important. **400 tests.**

**Deferred (Spec 2, its own brainstorm):** source-management GUI (wrapping `pensieve scan`) and
sync-daemon interval editing. The Advanced tab only *reads* daemon status; it never mutates it.

**Accepted carries (user's call, not fixed):**
- The single `.alert` is mounted only in `RootView`. `RecallWindowView` reuses `DetailView`, whose
  loose-end 👍/👎 can now refuse — a refusal raised from a recall window would surface on the **main**
  window, or sit unpresented if that window is closed. Rare (needs the row to vanish under
  re-extraction) and fails safe.
- 4 of the 6 writes raise their alert from **inside a sheet** (write-then-`dismiss()`). AppKit queues
  sheets so it should appear after the picker closes, but only the non-sheet delete path was manually
  tested. **Human-verify.**
- `AppModel.db` was widened `private` → `internal` so the Advanced tab can hand it to
  `SystemStatusGatherer`. Only a *reader* is needed; a `DatabaseReader` accessor would keep "views
  never write" type-enforced. Cosmetic.

**Human-verify:** ⌘, opens the tabbed pane; each tab persists its knobs; Advanced shows honest
status/paths (Never/— when absent); About shows version+build from the bundle; a stale context-menu
op (delete the node in another window first) raises the refusal alert; the sheet-raised alerts
(new/edit, move, merge) actually appear after the sheet dismisses; German in situ.

---

## Archive nodes — DONE (2026-07-14, merged to `main` `829c20e`)

The escape hatch for stale work `delete` refuses (any node with a live git/session source, which
would resurrect on the next drain). Archiving a node archives its **whole subtree**; archived nodes
leave every normal view (tree, middle list, project count, Smart Lists, Briefing, Spotlight,
**in-app search**) and render in a **collapsed-by-default "Archived" sidebar section**.
**Snooze semantics:** a new git commit / Claude session attributed to an archived node flips it
**and its ancestor chain** back to `active` (ingest path only — a `git.checkout` is not "work done"
and does not resurrect). **No migration** — reuses the long-latent `Node.state`; `muted` stays a
deferred, sticky, write-path-less state. Spec/plan: `{specs,plans}/2026-07-11-archive-nodes*`.

**Process note:** the 4 plan tasks were implemented in an earlier session whose SDD ledger was lost
with its worktree, leaving **no record of review**. This session treated the branch as unreviewed —
rebased it onto main, re-verified (396/396, `BUILD SUCCEEDED`, smoke launch), and ran the Opus
whole-branch review, which found **2 Important** (both fixed + re-reviewed → READY TO MERGE):
- **Manual unarchive walked only DOWN.** Unarchiving a *nested* strand left it `active` under a
  still-`archived` parent → `NodeForest.build` re-rooted it as a **phantom top-level root**.
  `NodeCommands.unarchive` now walks the ancestor chain too, sharing one `NodeCommands.resurface`
  helper with `Ingester.resurfaceIfArchived`. Invariant restored: **every active node's ancestors
  are active-or-muted.**
- **One-home rule broken:** `detailShowsLooseEnds` used unfiltered `children(of:)` while
  `middleKind()` filtered by state class → a project whose only strand was archived rendered its
  loose ends in *both* panes. One shared `visibleChildren(of:)` now backs both.
- Coupled Minor, also closed: "New Child…" is hidden on archived rows and archived nodes are gone
  from `moveTargets` (Move **and** Merge pickers) → active-under-archived is now unreachable in-app.

**Deferred / carries:**
- **`NodeState` constants enum** — bare `"active"`/`"archived"` literals are now spread across Kit
  and app (several pre-date this branch). Cleanup, not a regression; a mistyped literal silently
  no-ops.
- ~~**An archived node is unfindable by name in search**~~ — ✅ **DONE (2026-07-19, `3ece8b5`)**: the
  `.searchScopes` "Include Archived" toggle surfaces archived nodes + their open loose ends in **exact**
  ⌘F. (Semantic "Related" still excludes archived — see the semantic-recall fast-follow ledger above.)
- **Archived-tree housekeeping is impossible in-app** — you can't move/merge an archived node into
  another archived node (`moveTargets` excludes archived). Deliberate; revisit if it ever matters.
- **Known snooze limit (by design):** an in-progress `cc.session` already ingested dedups on its
  fingerprint and returns *before* resurrection, so continued work in a session archived mid-flight
  won't resurface the node until a commit or a new session.
- **When `muted` is built:** `resurface` skips a muted node mid-chain, so an active node under a
  muted parent would re-root as a phantom top-level entry. Unreachable today (no write path to
  mute); whoever builds `muted` must handle it.
- **Human-verify:** archive/unarchive from both context menus; nested-unarchive pulls its ancestors
  back in place; Archived section collapsed by default; a real commit in an archived project's repo
  resurfaces it after a daemon drain; German in situ (`Archivieren` / `Archiviert` /
  `Wiederherstellen` — a native pass may prefer `Aus dem Archiv holen`).

---

## MCP `recall` tool + deferred recall siblings — 2026-07-11

First real dogfooding win of `pensieve mcp` also exposed its ceiling: asked to *recall a past
conversation and its outcome*, the model **found** the topic via a cited loose end instantly,
then made ~5 shell calls to grep the `.jsonl` transcript for the actual passage. The MCP server
returns **pointers, not passages** — and Pensieve already computes the passage
(`ProvenanceQueries.context`, the app's ⌘⌥I inspector) but never exposed it over MCP.

- **`recall` tool — SPECCED, being built** (`specs/2026-07-11-mcp-recall-tool-design.md`).
  Loose-end-keyed read-only MCP tool → the surrounding transcript window via the existing tested
  `ProvenanceQueries` kernel; adds an additive `id` to `project_context` loose ends as the handle;
  model-controlled `radius` (default 8). No LLM, verbatim, inside the trust gate.

**Deferred siblings (with reasoning — not foreclosed):**
- **Keyword search tool over MCP** — jump straight to the relevant loose end/event across
  projects instead of scanning all of a node's loose ends (104 in the incident). *A `find` problem,
  orthogonal to `expand`; needs its own ranking/query design.* **Substrate already exists:** the
  tested `SearchQueries` Kit kernel from in-app find (2026-07-11) over the grounded corpus.
- **Semantic / vector recall over MCP** (`sqlite-vec` + on-device embeddings) — recall without
  exact words. *Large project (embedding pipeline, migration, index maintenance); already a
  standing loose end.* Shares the embedding substrate with the Spotlight semantic-search extension
  and the theme-discovery spike.
- **`whats_next` → recall handle** — `whats_next` returns a quote string, not an id. *Minor extra
  hop today (`project_context` on the node to get handles); additively add `topLooseEndID` if the
  hop proves annoying.*
- **Event-centric recall** — `ProvenanceQueries` is loose-end-centric (needs a `sourceMessageIndex`
  to center on); `cc.session` events have no single center message.

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

## Narration-cache carry — ✅ DONE (2026-07-19, app-quality cleanup pass)

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

- **`AppModel` → `@Observable` migration** — ✅ **DONE (2026-07-19, app-quality cleanup pass; plan `plans/2026-07-19-appmodel-observable-migration.md`).** Turned out cleaner than feared: no `@EnvironmentObject` to rewire, only `RootView` needed `@Bindable`, and the named hotspots (`nodesForSelection`/`PaletteView.rows`) were already gone (IA rework + ⌘K retirement). Non-UI infra is `@ObservationIgnored`; the Opus whole-branch review caught one wrongly-silenced property (`allNodes`, read by bodies via `node(_:)`) breaking `RecallWindowView` cold-restore, fixed. *Original note below, for context.* — the app still uses `ObservableObject`/`@Published`, so
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
- **`@MainActor` annotation on `AppModel`** — the model is main-actor-isolated by convention (only
  ever accessed from views or explicitly-hopped `Task`s), but it’s a plain `class` with no
  annotation. Adding `@MainActor final class AppModel` makes the compiler enforce the invariant,
  simplifies closures that currently need `@MainActor in` or `Task { @MainActor in }`, and catches
  any accidental off-main access at compile time. One-line change in declaration + removing the now-
  redundant explicit isolation annotations in `start()`/`focusContextDidChange()`. *Trigger: next
  touch of `AppModel`, or pair with the `@Observable` migration above.*
- **`NodeKind` / `NodeState` / `EventKind` → real `RawRepresentable` enums** — ✅ **DONE (2026-07-19, app-quality cleanup pass) for `NodeKind` + `NodeState`.** They're now `: String, CaseIterable, Codable, Sendable, Equatable, QueryBindable` enums (same strings on disk, no migration, all SchemaV4–V9 tests pass). **`EventKind` was NOT done — it doesn't exist:** `Event.kind` values come from `CaptureKind` on the sacred append-only capture spool, deliberately left `String`. *Original note below.* — currently string
  namespaces (`enum NodeKind { static let project = "project" ... }`). Making them real
  `enum NodeKind: String, Codable, Sendable, CaseIterable { case project, strand, ... }` gives
  exhaustive `switch` (the compiler catches a forgotten case), auto-`Codable`/`Equatable`, and
  eliminates the possibility of a typo creating a silent wrong-kind. SQLiteData column adapters
  handle `RawRepresentable` natively (no schema change — same strings on disk). The trade-off:
  adding a new kind becomes a migration-sized change (new enum case + update all `switch`es),
  but at the current rate (≤0.5 new kinds/month) that’s a feature, not a cost. *Trigger: next
  model-layer refactor, or pair with the `@Observable` pass.*
- **`Ingester.drain()` decode-failure poison-pill — design question, intentionally unchanged.**
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
