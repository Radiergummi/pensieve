# Pensieve — Backlog (deferred, not forgotten)

Ideas we've deliberately parked so a phase stays focused. Each is on the roadmap;
none is foreclosed. Revisit when the noted trigger arrives.

**How this file is organised (restructured 2026-08-15).** Everything still **open** comes first, in
four priority tiers; everything **shipped** is preserved verbatim in the **Archive** at the bottom.
Before the restructure the two were interleaved in one long ledger, so "what is actually open" was
only discoverable by reading all 1,700 lines. Nothing was deleted or reworded — entries were moved
and indexed.

- **Tier 0 — Foundation.** Structural carries from the 2026-08-15 architecture review. Ahead of feature
  work because each gets more expensive as the app half keeps growing untested.
- **Tier 1 — Product pillars.** The Roadmap: the sequenced spine from here to the finished app.
- **Tier 2 — Quality, measurement & known defects.** Open findings against shipped code.
- **Tier 3 — Parked, trigger-gated.** Real ideas waiting on a named trigger.
- **Archive.** Shipped work, dated, verbatim. Several archived entries carry
  *"Deferred out of …"* sub-lists whose items are still live; where one still matters it is
  cross-referenced from a tier above rather than duplicated.

---

## Open items — the index

**Tier 0 — Foundation** *(architecture review, 2026-08-15)*
1. The app is 6,202 lines with no automated tests — **half closed 2026-08-15** (UI harness shipped; the state machines are still untested).
2. Two narration caches, and the shared one is write-only from MCP — so `prime` can rarely hit it.
3. `Query/` is a namespace, not a layer — and the "only writer" invariant in `CLAUDE.md` is false.
4. The LLM surface has outgrown its eval gate: 9 model-backed tasks, 3 bars, and the guardrail cannot see the gap.
5. Three derived stores, three implementations, no shared contract — two have no schema versioning at all.
6. Ingest has no per-kind seam — the switch is fine, but the trigger should fire *before* the next kind lands.
7. Per-device state has no home decision, and CloudKit will force one.

**Tier 1 — Product pillars** — Roadmap §. Open: slice 6 (forks, gated on the capture backend) ·
CloudKit + iOS · system-integration surfaces · FSEvents real-time capture · additional source types ·
analytics. **The Apple *membership* gate is closed as of 2026-08-21** — paid team `TH593VRB6W`, and Focus
filters confirmed working. One residue remains: the App Group entitlement signs but `secd` **ignores it** for
want of a provisioning profile, so the sandboxed half is unproven — resolve that before Widgets. CloudKit is
now an ordinary unbuilt feature wanting its own brainstorm, and was never actually on this gate: an App Group
is same-device, CloudKit is cross-device. Both detailed under "Widgets" below.

**Tier 2 — Quality, measurement & known defects**
- Claude Design review — slice C (transcript reading, **live now**) and slice D (six items, each its own brainstorm).
- Contextify scan — open items: honest staleness on the retrieval path, `pensieve doctor`, Live Recall, skill + researcher subagent.
- P3 retrieval harness — **blocked on the user** writing 30–50 paraphrase queries.
- Follow-ups from the popover + harness session — the dropped node-scoped Loose Ends surface, plus three verification-practice findings.
- The UI harness has one remaining hole — the ordering test cannot cover its motivating defect. *(The vacuous sidebar-count test was closed 2026-08-16.)*
- String-catalog symbol generation was a latent build break, fixed 2026-08-21 — and a *cached build hid it*.
- The test suite was broken by the developer's own git signing config; fixed 2026-08-21 — and a *stale record hid it*.
- Extraction recall has never been measured; live sessions could supply the gold set.
- The salience pipeline is built, wired, and has never been run — two shipped features are inert.
- Naming has no eval coverage, and the harness has a silent hole. *(Subsumed by F4; kept for its detail.)*
- `TextQuality.shorten` — two weak tests on correct code.
- The `claude -p` self-capture loop left 427 rows behind — the bug is fixed, the residue is not.
- In-node find — highlight/document skew; needs a design, not a patch.
- Code-quality review carries (2026-07-07) — the still-open remainder, incl. the `drain()` poison-pill design question.

**Tier 3 — Parked, trigger-gated**
- Transcript rendering siblings — rich code blocks (syntax + DOT/Mermaid), Writing Tools on loose ends.
- Widgets — **half-unblocked 2026-08-21**: the App Group entitlement signs but `secd` ignores it for want of a provisioning profile, so the sandboxed half is unproven. Container shape is decided (publish a digest, do not move the store). Needs the profile resolved, then a brainstorm.
- Spike: statistical theme discovery across strands (`NLEmbedding`).
- Talk to the system, **stage 2** — the conversational agent (stage 1 shipped 2026-08-13).
- Forks as first-class — the capture backend; the long pole gating app slice 6.

---

# Tier 0 — Foundation (architecture review, 2026-08-15)

Seven structural carries from a high-level architecture review of the whole tree. Every claim below
was verified against the source before filing; line counts and call-site counts are as measured on
2026-08-15.

**What the review confirmed sound, and what these items are therefore protecting.** The spine has
held: all real logic in `PensieveKit` (10,464 lines) with four thin clients over it (app 6,202, CLI
1,214, sync agent, MCP), against 11,938 lines of tests. The two-store separation (sacred append-only
spool / canonical SQLiteData store) is intact, the 13 migrations are additive and forward-only, and
the trust gate is untouched by everything built around it. The strains are **not** in the model —
they are in *derived state* and in *verification coverage*, both of which have grown faster than the
abstractions holding them. Two decisions are worth naming as the pattern to repeat: retiring the
vector engine outright after it lost on measurement (rather than leaving it default-off), and keeping
`PassageHit` disjoint from `SearchHit` so a producer bug is unrepresentable rather than merely
unlikely.

**Sequencing.** 1 → 2 → 3 → 4 → 5. Item 1 is days; the rest are afternoons. Items 6 and 7 are
trigger-gated and listed last because their trigger has not arrived, not because they are smaller.

---

## F1. The app is 6,202 lines with no automated tests, and the smoke recipe renders no view body

> **HALF CLOSED 2026-08-15** — the UI verification harness shipped (`uiprobe`, `PensieveUITests`,
> `make uitest`, the `verify-app-ui` skill), and the smoke recipe that rendered no view body is
> retired from `CLAUDE.md`. **What remains is route (a) below, which is the larger half:** the harness
> asserts on *rendered output*, not on the state machines this finding actually names. `AppModel` + 7
> extensions, `NodeFindState` and `NodeOrganizing` still have **no unit tests**, and they are logic
> rather than chrome. A UI test can tell you the wrong thing rendered; it cannot tell you which
> reducer got it wrong. See also "The UI harness has two known holes".

**The largest verification hole in the project, and it grows with every slice.** `Sources/PensieveApp`
has no unit tests by construction — it is an Xcode app target, outside `PensieveKitTests` — and the
documented substitute (build + background-launch the inner Mach-O + `kill`) **executes no view body**:
`AppModel.start()` runs from `.task` on a rendered view, and a backgrounded direct-exec never renders
one. That gap was reproduced during the slice-5 run and is recorded there; it is pre-existing and not
specific to any branch.

The consequence is already visible in the record. The translation-settings entry states plainly that
**not one line** of `TranslationSettingsSection` or its three new `AppModel` methods had executed at
merge. Every recent slice closes with a human-verify checklist, and the defects worth catching — the
`.task(id:)` download-state race, the stale coverage-language write, the slice-3a render window — were
found by *reasoning about code that had never run*.

**Why now rather than earlier.** The "thin views over tested Kit" rule has mostly held, but the app now
carries real non-view state machines: `AppModel` + 7 extensions (1,438 lines), `NodeFindState` (289),
`NodeOrganizing` (253). These are logic, not chrome, and they are the parts the human checklist is
worst at covering.

**Two routes, and the first is smaller.** (a) Add a test target for the app in `project.yml`. No UI
automation is needed — `AppModel` is `@MainActor` but takes an injected `DatabaseWriter`, so it is
testable today against a throwaway store; the state machines above are the first targets. (b) Move more
of `AppModel` into Kit as pure kernels. (b) is the longer-term shape but (a) buys the most immediately
and does not require deciding where each piece belongs first.

*Revisit trigger: still now. The UI harness bought coverage of what renders; route (a) — a plain unit
test target exercising `AppModel` against a throwaway store — is untouched and is where the
race-condition class of defect actually lives.*

---

## F2. Two narration caches, and the shared one is write-only from MCP

**Same key function, two homes, one-way flow.** `AppModel.narrationCache`
(`AppModel+Narration.swift:34-54`) is a UserDefaults plist keyed by node UUID. `PensieveKit.NarrationCache`
is `narration-cache.sqlite`, written only by `pensieve mcp` (`Mcp.swift:206`) and read by `prime`
(`Prime.swift:18`) and `mcp`. **Both key on `NarrationCacheKey.make(events:provider:)`** — the same
invalidation contract — but the app never touches the shared store (`grep NarrationCache
Sources/PensieveApp` finds only the local struct).

So the process that generates narration all day, interactively, on every node open, writes to a plist
nobody else reads — and `pensieve prime`, the SessionStart hook that primes **every** Claude Code
session, can only reuse prose an MCP call happened to warm first. `NarrationCache.swift:5` already
documents the intended behaviour ("shared across app / CLI / MCP"); only the wiring is missing.

*Smallest action: have `AppModel.narration` write through to `NarrationCache` and read it as the
second-level lookup behind the synchronous plist. ~20 lines. Once that lands, whether the plist stays
as a fast synchronous first level or goes away entirely is a separate, cheap call.*

*Revisit trigger: now — this is the highest value-per-line item on the list, and `prime` is the surface
that benefits.*

---

## F3. `Query/` is a namespace, not a layer — and the "only writer" invariant is false

**Two separable problems in one directory.**

**(a) The folder no longer describes its contents.** `Sources/PensieveKit/Query/` holds 30 files
spanning four different kinds of thing: reads (`BriefingQueries`, `SmartLists`, `NodeFacts`,
`SearchQueries`), **writes** (`NodeCommands`, `LooseEndCommands`, `CheckpointCommands`), rendering
(`RecallMarkdown`, `ProjectContextRender`, `Snippet`), and interaction state machines (`FindSession`,
`NodeFindDocument`, `ProvenanceLoader`). `Store/` has 3 files and `Search/` has 4. A new file has no
obvious home, which is how a namespace decays.

**(b) The stated invariant is wrong, and it is load-bearing for reviewers.** `CLAUDE.md` says "the only
canonical writer is `Ingester.drain()`" and `NarrationCache.swift:6` repeats it in a doc comment.
Measured: **seven** files write the canonical store — `Ingester`, `ProjectResolver`, `ExtractionRunner`,
`NodeDescriber`, plus the three `*Commands` — and three more write derived stores. A reviewer relying
on the current wording would mis-review a write.

The true invariant is still crisp and worth stating: **ingest owns `events` / `passages` / `sources`;
user commands own `nodes` / `looseEnds` / `checkpoints`; neither writes a derived store.**

*Smallest action: split into `Read/`, `Commands/`, `Present/` (pure file moves, no logic change), and
correct the invariant in `CLAUDE.md` and the `NarrationCache` doc comment.*

*Revisit trigger: before the next batch of new query/command files — cheap at 30 files, annoying at 45.*

---

## F4. The LLM surface has outgrown its eval gate — 9 tasks, 3 bars, and a guardrail that cannot see the gap

**Nine model-backed production tasks:** `Ingester.nameStrand`, `IntentClassifier`, `LooseEndExtractor`,
`NodeDescriber`, `NodeLabeler`, `SalienceClassifier`, `SalienceSuggester`, `SessionSummarizer`,
`SummaryBuilder.narrate`. **Three registered `EvalTask`s** (`TaskRegistry.all` — extraction, narration,
description).

**The gap is structural, not accidental.** `TaskRegistry.consistency` (`EvalTask.swift:22-30`) checks
*registry ↔ config* — every task has a bar, every bar has a task. It never checks *call site ↔
registry*. So `CLAUDE.md`'s rule "new LLM-backed tasks must register an `EvalTask`" is **unenforceable
by the test that exists to enforce it**, and reality has drifted to 3 of 9 without anything failing.
Two of the uncovered tasks write user-visible node identity, and § "The salience pipeline is built,
wired, and has never been run" records that a third has never executed at all.

**The recommendation is deliberately not "register six more tasks."** That is expensive, and most of
these are legitimately best-effort — the trust gate covers *loose ends*, and everything else being
nil-honest rather than measured is a real design choice. What is missing is that the choice is
currently invisible. *Smallest action: one explicit inventory of every LLM call site tagged
`cited-gate` / `eval-gated` / `best-effort-unmeasured`, plus a test that fails when a new `any
LLMProvider` call site appears with no entry.* That converts silent drift into a deliberate, reviewable
decision.

**Two existing entries are the detail for this one, and should be closed with it:** § "Naming has no
eval coverage, and the harness has a silent hole" (which also records `CorpusBuilder`'s two hardcoded
task lists — a registered task can pass the whole suite while loading zero items) and § "Extraction
recall has never been measured".

*Revisit trigger: the next `EvalTask` addition or harness touch — and note that the `CorpusBuilder`
hole should be fixed first regardless, since it makes the rest harder to close safely.*

---

## F5. Three derived stores, three implementations, no shared contract

Beside the canonical store and the spool there are now three disposable stores:
`narration-cache.sqlite`, `search-index.sqlite`, `translation-cache.sqlite`. Each independently
reimplements open-or-delete-and-retry, best-effort no-op when unavailable, and schema handling —
**and only one of them actually has schema handling.** `SearchIndexStore` versions and drops on
mismatch (`schemaVersion = 5`, `SearchIndexStore.swift:21`); `NarrationCache` (`:27`) and
`TranslationStore` (`:35`) are bare `CREATE TABLE IF NOT EXISTS`, so a future column change fails
silently instead of rebuilding.

**The path rule is already shared and correct** — `PensievePaths.indexURL(named:)` makes every index
follow `PENSIEVE_DB`, which is the generalised form of a real scar (a verification recipe wiping the
live index). That is the proof the family is a family; nothing else about it is shared.

Nothing enumerates them, either: `SystemStatus` reports none, `pensieve status` shows none, and there
is no "rebuild derived" verb. Diagnosing a stale index currently means knowing which file to delete.

*Smallest action: one `DerivedStore` descriptor (url, schema version, rebuild action) listing the
three, consumed by `SystemStatus` and a single `pensieve reindex`. Folds naturally into the deferred
`pensieve doctor` (§ Contextify scan, item 5), which wants exactly this inventory.*

*Revisit trigger: before a fourth derived store is added, or when `pensieve doctor` is specced —
whichever comes first.*

---

## F6. Ingest has no per-kind seam — fire the existing trigger *before* the next kind lands

**Not a new finding — a re-dating of one this backlog already holds.** § "Phase 1B-org ▸ Deferred out
of 1B-org" records: *"Per-kind ingestion-handler protocol (fingerprint/enrich/extract) — a `switch`
suffices for git+session. Trigger: a 4th source type."* That judgement still stands. What the review
adds is the asymmetry and the drift risk.

**The asymmetry.** Discovery *has* a genuine seam — `FileSystemSourceType` is cleanly kind-agnostic and
all git specifics live in `GitSource`. Ingestion has none: `Ingester.ingest` is a four-case switch on
`CaptureKind` string constants with bespoke per-kind code inline, and `Ingester.swift` (395 lines) is now
the largest file in Kit. Note this is *not* an argument for typing `CaptureKind`: those strings are the
on-disk spool wire format on the sacred capture path and are deliberately `String` (unlike `NodeKind` /
`LooseEndStatus` / `PassageRole`, which became real enums). The dispatch is the seam, not the constant.

**Why re-file it.** "We will probably add more sources in the future, so the ingestion should really not
hard-code assumptions about git or claude sessions" is one of the **oldest open loose ends in the live
store**, and pillar #7 (additional source types) is where it lands. The refinement to the trigger: fire
it *before* the fourth kind goes in inline, not after — adding the kind first is what makes the
extraction expensive.

*Revisit trigger: the fourth source type is specced (unchanged) — but the seam comes first, not the kind.*

---

## F7. Per-device state has no home decision, and CloudKit will force one

`AppModel.narrationCache` (UserDefaults, node-UUID-keyed) and `lastOpenedAt` are device-local by
accident of where they were easiest to put, not by a decision anyone made. Today that is invisible —
there is one device.

**Derived stores are already handled correctly**: narration cache, search index and translation cache
are explicitly disposable, never-synced, rebuildable, and documented as such. UUID PKs and STRICT
tables have kept the CloudKit on-ramp open on the canonical side (pillar #4). These two UserDefaults
values sit in neither category: they are neither canonical state nor rebuildable derived output, and
nothing says which they should be when a second device exists.

The narration cache is genuinely ambiguous — it is derived output (rebuildable, so device-local is
defensible) but expensive to regenerate on a phone. `lastOpenedAt` is more clearly a *sync* candidate:
"since your last visit" means the wrong thing on a second device if each keeps its own.

*Smallest action: decide the category for each and write it down. It is a two-line decision now and a
migration later.* Note it also interacts with **F2**: if narration write-through lands, the shared
`narration-cache.sqlite` becomes the natural home and the plist question mostly answers itself.

*Revisit trigger: CloudKit (pillar #4) is specced, or the App Groups gate opens — whichever is first.
The App-Groups move already requires relocating the store for all writers, which is the moment to
settle this.*

---

# Tier 1 — Product pillars

The sequenced spine from where we are to the finished app. **Tier 0 above is scheduled ahead of this
tier**, not instead of it: none of the Tier 0 items blocks a pillar, but each gets more expensive the
longer the app half keeps growing untested.

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
brainstorm→spec→plan cycle (the loop in `CONTINUE.md` → "How we work here"); **Tier 3 — Parked,
trigger-gated** holds the parked depth-features + forward ideas, each with a revisit trigger, and the
**Archive** holds the shipped record. Order is a recommendation, not a commitment.

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
   - ✅ **Slice 5 — talk-to-system stage 1** (this branch, 2026-08-13; not yet merged to `main`): describe
     a strand in a sentence → structured create. `NodeLabeler` routes by detected language — English to
     the on-device model, everything else to a deterministic word-boundary shortener — because
     measurement showed the model *translates* non-English input rather than labeling it. The New/Edit
     modal gained a Description field + Suggest button; a new node lands under the current selection.
     **Model-assisted parenting is deferred, not shipped:** the spec's own measurement found
     `FTSQueryBuilder`'s AND-join makes typed-sentence retrieval return zero candidates; a working
     alternative (OR-aggregate across hit kinds) is recorded for its own measurement-gated follow-up (see
     "Deferred, with triggers" in `specs/2026-08-13-talk-to-system-slice5-design.md`). Spec/plan:
     `{specs,plans}/2026-08-13-talk-to-system-slice5*`.
   - ⏳ **Slice 6 — forks surface:** ancestry trail + siblings + "Roads Not Taken" list. **Gated on the
     fork-capture backend** (see "Forks as first-class" below — that backend is a separate spec, still the
     long pole).
   - **Carries from slice reviews (fold in when convenient):** key `lastOpenedAt` per DB path — and see
     **F7**, which asks the prior question of whether `lastOpenedAt` should be device-local at all.
     ~~a shared per-node "latest event + days-dormant + open-loose-end-count" helper~~ — ✅ **DONE
     (2026-08-12)**: slice A shipped `NodeRowFacts` over two grouped aggregates. *(`NextItem` still
     lacks `lastActivityAt`, so the menu-bar popover pays for its second line separately — that
     remainder is tracked in Tier 2 ▸ Claude Design review ▸ B's two open carries.)*

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
   protocol** finally earns its place (trigger: the 4th source type). **See F6** — the 2026-08-15
   review re-filed that deferral with one refinement: build the seam *before* the fourth kind goes
   in inline, because adding the kind first is what makes the extraction expensive.

8. **Analytics surfaces** — *medium.* Cross-project dependency graphs, dashboards, token-spend
   charts. Explicitly "Later" in the spec; lowest priority.

**Depth features that thread through the above** (detailed in Tier 3, not standalone pillars):
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
- **Focus filters** (`SetFocusFilterIntent`) — ✅ **DONE (2026-07-07, merged to `main` `171c0e6`).** A macOS Focus restricts the main window + menu-bar + Spotlight to its context. Shipped: migration v9 `nodes.context` (`work`/`personal`/unset) + tested `NodeContextResolver` (subtree inheritance + mute-opposite/show-unset predicate); `PensieveFocusFilter: SetFocusFilterIntent` (optional param = deactivation signal) → `UserDefaults` → `AppModel` observes + re-filters + reindexes; a Context picker in the New/Edit modal; German l10n. Spec/plan: `{specs,plans}/2026-07-07-focus-filters*`. **Deferred follow-ups:** notification muting ("mute personal nudges" — moot until notifications exist); a bulk/right-click "Set Context" action; >2 contexts; CLI `--context`. **⚠️ Was BLOCKED at runtime 2026-08-11 (ad-hoc signing) — ✅ RESOLVED 2026-08-21, with zero code changes, exactly as predicted.** The symptom: the filter appeared in System Settings but **"Add" was permanently disabled**, because `linkd` refuses an app with no Team ID (`requiresValidatedBundle`) and the sheet can never prepare the intent instance. **The real blocker was never the membership.** The machine's `Apple Development` certs (team `TH593VRB6W`) had been valid since 2026-07-06, but the login keychain was missing the **WWDR G3** intermediate that issued them — it held G5 plus three copies of the one that expired Feb 2023 — so no chain reached a self-signed root. `security find-identity -v -p codesigning` therefore hid them (1 of 3 "valid") and `codesign` failed with `unable to build chain to self-signed root` / `errSecInternalComponent`. **Note `security verify-cert -p codeSign` reported "successful" the whole time the chain was broken — it is useless as a check here.** Fix: import `AppleWWDRCAG3.cer` from apple.com/certificateauthority, then swap `project.yml` off `CODE_SIGN_IDENTITY: "-"` to `DEVELOPMENT_TEAM: TH593VRB6W` + `Apple Development` + `CODE_SIGN_STYLE: Manual` (Manual keeps it local: no portal writes, no App ID, no profile). `linkd` then logs `Accepting [pid]:me.mazetti.pensieve … com.apple.linkd.autoShortcut` instead of `Rejecting invalid client`, "Add" enables, and activating the Focus persists `pensieve.activeFocusContext = work`. **Verification gotcha:** `perform()` fires on Focus **activation**, not when the filter is added, so the defaults key stays absent until the Focus is actually switched on — an absent key right after configuring proves nothing. The in-app manual Context switcher is no longer needed as a *workaround*, though it may still be wanted on its own merits.
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

# Tier 2 — Quality, measurement & known defects

Open findings against shipped code. Each was verified against the source when filed; none is a
blocker, and several are recorded specifically because this project has twice shipped vacuous tests
and caught them only by mutation.

---

## Claude Design review of the shipped app — 2026-08-11 (four slices; A and B done, C live, D parked)

The user ran the live app past Claude Design and got a full redesign proposal back (mockups + a
"top 5"). Mockups are **medium-resolution intent, not a spec** — the standing instruction is to
reach the same outcomes through **platform primitives and Liquid Glass**, never by transcribing the
pixels. Verified against the source before filing: every "current state" claim below was confirmed
in the repo, and one proposal was **rejected on the evidence**.

Split into four slices. **A and B have shipped**; C is unblocked; D is parked here.

**A — "Where was I" (the reload-context pass) — DONE (verified 2026-08-12).**
Human-verify pass run against the built app and the real store; outcome and two process notes in
`verify/2026-08-11-where-was-i-human-verify.md`. One real defect found and fixed (hover-revealed
thumbs were unreachable — the `Spacer()` between text and thumbs was dead space, so hover ended
before the pointer arrived; `.contentShape(Rectangle())`). Four items found that belong elsewhere are
logged below.
Detail-pane order (state line first, loose ends before the recap, recap demoted to a closing
paragraph), middle-column rows carrying recency + counts instead of the repeated kind label,
honest localized relative dates, Briefing weighting (moved gets mass, quiet collapses), thumbs
moved off the permanent row. Confirmed defects it closes: `ContentListView.swift:120` renders
`kindLabel` as every row's only second line, so the column reads "Projekt / Projekt / Projekt";
`BriefingView.swift:44-45` hardcodes the English fragments `"dormant \(days)d"` and
`"\(n) since last visit"`, which are **absent from the String Catalog entirely** and render
untranslated in a German build (and `dormant 0d` is not a fact anyone needs); `BriefingView.swift:23-28`
gives `moved` and `quiet` identical cards, so five dormant projects outweigh the one that moved;
`DetailView.swift` has no state line at all and puts LLM prose above the cited loose ends.

**B — Liquid Glass chrome + the macOS 26 floor — DONE (2026-08-13).** `project.yml` now pins
`deploymentTarget.macOS: "26.0"`, so the macOS 26 APIs need no `if #available` scaffolding at the
call site. Human-verify carries (the checks that need a GUI session and a real store) live in
`verify/2026-08-12-macos26-floor-human-verify.md`; two carries that outgrew this slice are logged at
the end of this entry. Original scope, all landed: bump the target, adopt scroll-edge material so
content stops bleeding through chrome, revisit
the sidebar status footer (still the open item #1 from the 2026-07-07 UX carries — `.background(.bar)`
fixed the clash but it still reads as a bolted-on band), and **rebuild the menu-bar popover**, which is
the worst-looking surface in the app today: node rows with no per-item action. The proposal's shape
for it is right — a re-entry point with a `Fortsetzen` action per row, not a scoreboard. (The
untranslated `"868 open"` / `"288 open · 0d dormant"` were fixed in slice A; the 2026-08-12 verify
pass confirmed `869 offen` / `288 offen · 1T ruhend`. What remains there is **layout**: the
`Pensieve öffnen` button truncates to `Pensieve öf…` because the three-button row is too narrow for
German — the string is correct, the row is not.) The footer is now a full-width primary button plus
an ellipsis `Menu` holding Refresh and Quit, at a 320pt popover, so German cannot truncate it.

**B's two open carries** (found by the cleanup pass on 2026-08-13, both too deep for it):

- **Scroll-edge material is applied per-site and covers 4 of ~9 scroll surfaces.**
  `.scrollEdgeEffectStyle(.soft, for: .top)` sits on `SidebarView`, `ContentListView`, `BriefingView`
  and `DetailView`. Untreated: the three Settings `Form`s (`Settings/GeneralSettingsTab.swift:15`,
  `IntelligenceSettingsTab.swift:61`, `AdvancedSettingsTab.swift:17`), `NodeOrganizing.swift:156`/`:179`
  (`MovePicker`/`MergePicker` lists scrolling under a `navigationTitle` — the textbook case), the
  `NodeEditor` `Form` at `NodeOrganizing.swift:27`, and the two `IconPicker` grids (`:102`, `:138`).
  The four shipped sites already rely on the modifier propagating down a subtree (`ContentListView`
  attaches it to a `Group`, `DetailView` to a `ScrollViewReader` — neither is the scroll view itself),
  which is the argument that it can be hoisted: applying it once per scene in `PensieveApp.swift` — on
  `RootView`, `RecallWindowView`, `SettingsView` — would collapse the four call sites *and* close the
  gap, so scroll views added later inherit it instead of depending on someone remembering. **Needs a
  GUI session**, not a green build: propagation into sheet-presented content is the unverified part,
  and getting it wrong silently removes the effect from surfaces this slice deliberately treated.
- **`NextItem` lacks `lastActivityAt`, so the popover buys its second line with two whole-database
  aggregates.** `MenuBarRow` renders recency + open count from `model.nodeRowFacts`, which is why
  `refreshGlance()` gained a `NodeFactsQueries.rowFacts` call. But `NextQueries.ranked`
  (`Sources/PensieveKit/Query/NextQueries.swift:22-31`) *already* fetches the latest `Event` per
  project and discards the `Date`, keeping only `daysDormant`. `NodeFacts.swift:11-17` wrote down
  exactly this pattern — carry the `Date` alongside the `Int`, views read the `Date`, ranking reads
  the `Int` — and `NextItem` is simply the struct that never got the field. Adding it lets the row
  render from the item it already holds and deletes the query from `refreshGlance()` entirely.
  Adjacent, larger, and **pre-existing**: `ranked` runs `2N` queries per refresh, and `looseEnds` has
  no index on `nodeID` (only `idx_events_project` exists, `CanonicalStore.swift:88`), so each active
  node triggers a full table scan of it. At single-user scale that is milliseconds — but the index is
  the cheap half if this is ever revisited. Kit change; wants its own pass.

*Trigger for the two carries: the scroll-edge hoist wants the next GUI session; the `NextItem` field
wants the next pass that touches `NextQueries`.*

**C — Transcript reading: one rail, no nested cards.** The provenance transcript currently nests
three near-identical gray surfaces (message card inside system card inside HINWEIS/BEFEHL card) with
the speaker as an 11pt label *outside* the outermost one — it reads as a log, not a conversation.
Proposal: a **speaker column** carries the structure; only user messages get a filled bubble (they
are the minority and the thing being hunted for); assistant replies sit free on the page as prose;
harness events collapse to one folded `DisclosureGroup` line; attached skill documents become a chip,
not an embedded article; Markdown H1 inside a transcript never renders larger than the app's own
headings. **Conflict — now cleared:** this rewrites `LooseEndRow.swift` and `TranscriptSegmentView.swift`,
the same files in-node find (`plans/2026-08-11-in-node-find.md`) modifies, so the two were sequenced
rather than run together. **In-node find merged to `main` on 2026-08-12**, so C is unblocked — and its
accepted flatten-on-match trade-off lives in exactly those two files, which makes C the natural place to
revisit it. *Trigger: live now.*

**D — Not design at all; each needs its own brainstorm → spec.**
- **Loose ends can end — three verbs (`open` / `done` / `dropped`). ✅ DONE (2026-08-13, merged to
  `main` `a1c649a`).** Was the single highest-value idea in the whole review, and a data-model change
  rather than chrome: a loose end was open forever, so "Als Nächstes 155" and "Ruhend 112" never
  shrank and neither number meant anything. Shipped as specced — `LooseEndStatus` over the latent
  `status` column, migration v12 for `resolvedAt`, a burn-down queue, a *Completed* list, a per-node
  record, and `isActionable` so a project with no open ends leaves What's Next while staying in
  Dormant. The thumbs stayed what they were. `.swipeActions` + `UndoManager` both landed. See
  `CLAUDE.md` Status for the full record and the two review-caught defects.
  **One deliberate scope change during execution:** `SalienceSuggester` also dropped its
  `status == open` candidate filter (own commit, `ecd96ff`) — the spec's D9 only removed it from
  `SalienceReviewQueries`, which left closed ends auditable *only if they already had a suggestion*,
  so burning the backlog down would still have destroyed most training examples.
- **Merge inbox for duplicate nodes.** Not hypothetical: the live sidebar shows **"Agent" twice**.
  Proposal is an evidence-first review queue (both candidates side by side with created/path/remote/
  last-touched, a count of what would move, and three non-destructive verbs — merge / nest under /
  not a duplicate) where **"not a duplicate" is remembered permanently**, so the queue is an inbox
  rather than a nag. Distinct from the existing *Review Suggestions* list, which reviews loose ends.
- **Middle column as chronological history across all projects** ("Verlauf") instead of a node list.
  This is the same idea as **item 5 of the 2026-07-07 App UX & IA polish carries** (the three-pane IA
  rework), and it overlaps the long-standing *timeline per project* loose end. Still wants its own
  brainstorm. **Related ask (2026-08-12):** previous/next navigation — reloading context means a lot
  of jumping between nodes, and there is no way to step through a list without returning to it.
- **Narration can still emit a facts-dump** (found 2026-08-12). A real recap read: *"Recent work on
  the cetacean project consisted of eight `cc.session` sessions. The sessions included 41, 54, 107,
  41, 349, 28, and 410, and 1 prompts."* No fabrication and no trust-gate issue — narration is
  best-effort and outside the cited gate — but enumerating prompt counts is not a recap, and slice A
  just promoted the recap to the closing paragraph of the detail pane. Wants a quality bar in
  `SummaryBuilder.narrate`: prefer `nil` over prose that only restates event metadata.
- **`Du` vs `user` in the same message** (found 2026-08-12). The transcript bubble header renders the
  localized speaker class (`Du`) while the provenance footer directly below shows the raw role
  (`user`). Both are as-specified — the header is chrome, the role is content per CLAUDE.md — but on
  screen they read as two different labels for the same speaker. Needs a decision, not a fix.
- **Full Keyboard Access tab order is erratic** (found 2026-08-12). The middle column is not reliably
  reachable without tabbing-and-spacing at random. Pre-existing and app-wide, not specific to the
  loose-end rows whose `accessibilityHidden` guard prompted the check.
- **Multi-source evidence contract.** A grounded citation always renders as identity + verbatim
  wording + a way back to the source, and **only the identity strip and the jump-back may vary by
  source type** — the quote's typography is set once, centrally, so a future source (Linear, browser
  history, mail) can never restyle a quote. Worth adopting as a written invariant when the second
  non-git/session source is built; premature before then.

**Rejected on the evidence: "move Recent Activity into a trailing `.inspector`."** The proposal reads
the empty margin beside the 680pt measure cap as dead space to fill. But the `.inspector` was
**deliberately removed** in the 2026-07-08 inline-provenance rework (`RootView.swift:41-43`) and in-node
find (shipped 2026-08-12) builds on that decision. The underlying complaint — a wide window wastes its
surplus — is legitimate and belongs to slice A as a layout question, but re-adding an inspector is not
the answer.

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

## Follow-ups from the popover + harness session (2026-08-15)

Everything left open by the eight reported menu-bar defects, the freeze fix, the batching change and
the UI harness. The two harness holes have their own entry below; these are the rest.

### Product — the popover's dropped level, deferred with reasons

- **Node-scoped Loose Ends as a real surface.** The genuinely useful version of the drill-in level
  that was specced and dropped: one node's triage queue with the resolve verbs (⌘⏎, undo), rather
  than the cross-node **Loose Ends** bucket, which is all that exists today (`triageItems()` →
  `openAcrossNodes`, and `SidebarSelection.triage` carries no node). Belongs in the main window with
  undo, not a 320 pt popover. **Its own spec** — it needs a new selection state and a middle-column
  mode. *Trigger: the next time burning down a single 299-item project feels like the wrong tool.*
- **Type-select in the popover** (typing jumps to a project). Cheap now that a focus cursor exists;
  five rows do not need it. *Trigger: the row cap rising above ~8.*
- **Tab traversal of the footer.** Spike 2 showed Tab events do reach the popover, so it is possible;
  the ⌘⏎/⌘R/⌘, shortcuts make it unnecessary. *Trigger: a report that Tab stops mid-surface.*

### Verification practice — three things this session demonstrated rather than argued

- **Human-verify carries are a gate, not a handover list.** The keyboard work shipped with a carry
  ledger whose item 4 was literally *"What `Esc` actually does"* — and `Esc` did nothing, because
  nothing had been written for it. The list was correct and was written *and then shipped past*. The
  fix is procedural and free: a carry that can be discharged in the session must be discharged before
  the work is reported complete, and only the ones genuinely needing the user's eyes (taste, German in
  situ, VoiceOver) may be handed over. *Trigger: the next slice that ends with a carry ledger.*
- **A plan's code should be compiled and linted before the plan is called ready.** The UI-harness plan
  was detailed, well-reasoned and correct in design — and its code carried **nine** defects, none of
  them design errors: a type that does not conform to `Error`, three `force_cast`s, three identifiers
  below the length minimum, a 59-line body over a 50-line cap, two wrong `UserDefaults` keys whose
  failure mode is *silent*, and three wrong assumptions about what the accessibility tree contains —
  plus a verification step that greps for a string which never matched. Every one surfaced within
  minutes of actually running it. *Trigger: writing the next implementation plan that contains code
  blocks.*
- **Audit the Kit suite for "asserts membership, not mapping".** `openExcludesConfirmedNoise…` put
  four loose ends on one event and asserted only *which* rows came back, never their dates — so the
  positional-zip batching bug would have passed it. Found only because the batching change went
  looking for what it could break. The shape (assert the set, not the correspondence) is likely to
  recur, and mutation is the only way to find it. *Trigger: the next refactor of a query that returns
  joined rows.*

### Smaller carries

- **Two human-verify items from the popover keyboard work are still open**: VoiceOver reads a row as
  one coherent label, and German in situ. Both need eyes, not a harness.
- **`ClosedLooseEndsRecord`'s `LazyVStack` is reasoned, not measured.** The open section's fix was
  A/B measured (row-render work down 15×); the closed record's identical fix was applied by analogy
  because no node has closed loose ends yet. *Trigger: the first node with a large Done record.*
- **Should `make uitest` run in CI?** It is deliberately outside `make all` because it steals focus
  for ~35 s, which is right for a working session and possibly wrong for a headless runner, where
  nothing would be interrupted. *Trigger: the next CI change.*

---

## Two local-verification traps, both fixed 2026-08-21 — and both hidden by caching

Recorded together because they share one lesson: **`make`'s step caching can report green over a step that
would fail if it actually ran.** Both were found only by forcing (`make -B`), and one of them had been silently
skipped for six days.

**1. `STRING_CATALOG_GENERATE_SYMBOLS` cannot coexist with the hand-authored catalog.** XcodeGen's setting
presets turn it on (it appears in the generated `.pbxproj` but was never in `project.yml`). Symbol generation
derives a Swift symbol per catalog key, and because *the keys ARE the UI strings*, several differ only by case
or trailing punctuation — `Archive`/`archive`, `Delete`/`Delete…`, `New Child`/`New Child…`,
`LLM Provider`/`LLM provider`, `Mark as Done`/`Mark as done`, `None open`/`None open.`, `Idle`/`idle`,
`Merge`/`merge`, `Rename`/`rename`, `Unarchive`/`unarchive` — and each pair collides. 25 hard errors, plus two
keys rejected outright (`Type` is too close to a Swift keyword; `%@` yields no derivable symbol). **Deduplicating
is NOT the fix**: a key must match its Swift literal character-for-character or German silently falls back to
English, so the collisions are load-bearing. Nothing reads the generated symbols — the app uses plain
`Text("…")` — so it is now `STRING_CATALOG_GENERATE_SYMBOLS: "NO"` in `project.yml`, sibling to the existing
`SWIFT_EMIT_LOC_STRINGS: "NO"` and for a closely related reason. **Why it looked intermittent:** the build phase
only runs when the derived symbol file is stale, so the identical tree built clean and then failed 25 minutes
later.

**2. The test suite inherited the developer's commit signing.** `makeCommittedRepo` pinned branch and identity
into each temp repo — its comment even says the point is not to "inherit the machine's git configuration" — but
not signing. This machine sets `commit.gpgsign=true` globally with an SSH signer behind a Secure-Enclave agent
(Secretive), which refuses to sign non-interactively: `Couldn't sign message (signer): agent refused
operation?` → `fatal: failed to write commit object`. So `git commit` failed, `rev-parse HEAD` returned nil,
and **the force-unwrap at `TestSupport.swift:31` raised a fatal error that killed the entire test process** —
the suite died mid-run having printed only unrelated passing tests, with no summary and no named failing test.
Fixed by a shared `configureTestRepo(at:)` in `TestSupport.swift` (used by both repo-creation sites, so they
cannot drift) which also sets `commit.gpgsign false`. Verified both directions: the bare sequence fails, the
pinned sequence commits. Suite now **786 tests in 17 suites passed**.

**Why it hid for six days:** `.make/test` was dated 2026-08-15 and the *inputs* (`Sources`, `Tests`) had not
changed since, so every `make all` and `make run` treated the suite as up to date and skipped it — including
the `make run` that installed to `/Applications`. A green `make all` therefore certified nothing about the
tests. **When verification matters, force it.**

**Left alone deliberately (follow-up):** six further `Git.run(…)!` force-unwraps in the tests
(`StrandBirthTests` ×2, `IngesterTests` ×3, `RefineProjectNamesTests` ×1). With the config fixed they all
succeed, so changing them is out of scope here — but the failure *mode* is bad out of proportion to the bug: any
future git-environment problem kills the whole process instead of failing one named test. Worth converting to a
throwing unwrap in one pass.

---

## The UI harness has two known holes (2026-08-15, recorded at build time)

> **HOLE 2 CLOSED 2026-08-16** — by lifting the debugged tests from the parallel
> `worktree-app-ui-verification` branch, whose work main had never received: main's line
> re-implemented the harness independently on 2026-08-15 and so missed the later fixes. Hole 1
> stands; the branch did not close it either.

Both are in `Tests/PensieveUITests`, because a test that looks like coverage and is not is this
project's recurring defect.

**1. The ordering test cannot cover the defect it was written for.** The motivating bug was slice A
moving the recap *below* the loose ends while the parallel in-node-find branch still emitted the
narration slot first. The recap only exists once narration has run, and the suite disables narration
(`-app.narrationEnabled NO`) because it is an LLM call. `testLooseEndsRenderAboveRecentActivity` pins
the neighbouring always-present boundary instead — mutation-verified, so it is a real assertion, just
not *that* assertion. *Closing it needs a way to render a recap without an LLM call — most likely
seeding the narration cache through the argument domain, which is a test-only path and needs
checking that it is not a production seam.*

**2. ~~`testSidebarShowsFixtureCounts` is weak and probably vacuous.~~ CLOSED 2026-08-16.** It
asserted `application.staticTexts["3"].exists`, and the fixture renders "3" in at least two unrelated
places (the open-loose-end count and the What's Next count), so it would pass with the count feature
broken. Its second assertion — that the archived node stays out of the main tree — turned out to be
worse than vacuous, not sound: `sidebar.archived.expanded` persists across runs, so on a host where
Archived starts *expanded*, "Old Prototype" already exists before the check runs and the bare
`XCTAssertFalse` reports a **false leak** against correct code.

Replaced by two tests: `testLooseEndsCountMatchesFixture` scopes the count to the cell containing
"Loose Ends", and `testArchivedSeparateFromProjectsPersonalReachable` reveals both sections through a
state-derived helper (`revealSidebarSection`, which checks visibility before clicking rather than
blind-toggling) and asserts `frame.minY` against the "Archived" heading — correct regardless of
either section's starting state.

*Revisit trigger:* the next change to detail-pane ordering (hole 1), or to sidebar counts.

---

## Extraction recall has never been measured, and live sessions could supply the gold set (2026-08-15)

**User's idea, recorded before it evaporates** — and it is the missing half of the trust gate, not a
nice-to-have.

Phase 1B validated extraction for **precision**: 0 noise, 0 fabrication across three on-device
acceptance runs, which is what made the make-or-break gate pass. **Recall was never measured, and
there is no instrument for it.** The gate is deliberately built never to fabricate; the price of that
posture is *silent misses*, and a silent miss is invisible by construction — the loose end simply is
not there, and nothing indicates it should have been.

**The proposal:** during real development sessions, loose ends arise organically and are recognised
in the moment. Record them as they occur; after the session's transcript is ingested, check whether
extraction actually produced them; where it did not, find out why. Live use becomes the gold set,
which is the same shape as **P3**'s blocked paraphrase gold set (`backlog.md` § P3) — and has the
same appeal: it is generated by working, not by an authoring chore.

**The trap, and the fix.** Any in-session recording *contaminates the measurement*: stating "this is
a loose end" in chat puts a clean, well-formed statement of it into the transcript, which is the
easiest possible extraction target, so recall scored that way is optimistically biased upward. This
repo already carries a live instance of the self-capture hazard (§ "The `claude -p` self-capture loop
left 427 rows behind"). The fix is a **matching rule, not a capture rule**: count an extraction as a
hit only when **its cited message index precedes the point at which the expectation was recorded**.
Ground truth may then be recorded in-band without inflating the score.

**Open questions, none blocking a spec:**

- **Matching.** An expectation is a paraphrase; an extracted loose end cites a verbatim quote. Exact
  match will not work. Options: BM25 over the transcript window, a model judge, or a human
  confirm-queue shaped like Review Suggestions. Probably the hardest part, and worth measuring before
  choosing.
- **Whose judgement.** "This was a loose end" is itself noisy — arguably it needs the same
  confirm-step the salience labels have.
- **Where it lives.** There is an `EvalTask` registry and `pensieve eval` already
  (`Sources/PensieveKit/Eval/README.md`), so a recall bar has a natural home beside the existing
  extraction / narration / description bars — and adding one would also close part of § "Naming has
  no eval coverage".
- **Denominator.** Recall needs "how many loose ends were really there", which no one can enumerate.
  A per-session recorded set only measures recall *against what was noticed*, which is a floor, not a
  true rate. Worth stating honestly in whatever the harness reports.

*Revisit trigger:* the next extraction-quality question, or any session where a miss is noticed by
hand — that is a free datapoint and currently nothing catches it.

---

## The salience pipeline is built, wired, and has never been run (2026-08-15)

**Two findings, one entry.** Surfaced by two independent adversarial reviews of the menu-bar popover
spec — which proposed reusing the salient-first ordering, and so had to check whether it does
anything. It does not. Both were verified against the live store on 2026-08-15.

**1. `labelSuggestion` is empty on every row, so two shipped features are inert.**

```
labelSuggestion:  '' → 986 rows   (all of them)
label (human):    '' → 864,  noise → 98,  salient → 24
```

`SalienceSuggester` (`Intelligence/SalienceSuggester.swift`) is the only writer, it is **offline and
opt-in** behind `pensieve label-suggest` (`Sources/pensieve/Commands/LabelSuggest.swift:36`), and it
has never been run here. The machinery is not missing — it is unexercised. Two consequences:

- **`openAcrossNodes`'s salient-first tier is dead code in practice** (`LooseEndQueries.swift:40-45`).
  The Loose Ends bucket's headline ordering — chosen on measured grounds over pure oldest-first,
  which its own doc comment calls "grind through three repos" — currently *is* pure oldest-first.
  The burn-down queue has been running in the mode the design rejected.
- **Review Suggestions is structurally empty**, not merely quiet. `SalienceReviewQueries.pending`
  requires `label == unlabeled && labelSuggestion != ""` (`:17`), and the second clause matches
  nothing. The badge count has been an honest zero over a query that cannot return rows.

*Status 2026-08-15:* trialled at `--limit 20` (the first run this pipeline has ever had) and then
**reverted** — the noise calls looked right, the salient calls did not, and a full pass would hand over
a ~986-item audit queue whose ordering is unaudited guesses until worked. Baseline + read:
`measurements/2026-08-15-salience-prompt-baseline/`. Handed to a fresh session to improve the prompt
first: `docs/superpowers/HANDOVER-salience-prompt.md`.

**The unblocker found while trialling it:** the salience eval's gold set is a synthetic 10-quote
starter, but **122 hand-adjudicated labels already sit in `LooseEnd.label`** (24 salient / 98 noise,
all with usable quotes) — which is the ~100–150 real quotes its own README asks for. Prompt iteration
is unmeasurable until those two are connected, and trivially measurable afterwards. Mind the class
imbalance: "everything is noise" scores 80% accuracy, so the metric must be precision/recall on the
salient class. *Open question worth
deciding first:* whether suggestion should stay a manual backfill at all, or run as part of
extraction — 864 of 986 ends are unlabeled, and a one-off backfill leaves every future end unlabeled
again.

**2. `SalienceReviewQueries` holds a second copy of both the comparator and the N+1.**
`:27-28` is byte-identical to `LooseEndQueries.swift:41-42`, and `:21` is its own inlined per-row
`Event` point-query loop — outside the file, so "all four feeds share `attachEvents`" is true of
`LooseEndQueries` only. Extracting one copy and leaving the other is how the two drift. Relevant the
moment the batched-`attachEvents` work lands: **fix both or neither.**

*Revisit trigger:* the batching change, or the first time Review Suggestions is expected to show
anything.

---

## Naming has no eval coverage, and the harness has a silent hole (2026-08-13)

**Two findings, one entry.** Raised by an adversarial review of the slice-5 spec and confirmed
against the code.

**1. Strand naming was never eval-registered.** `eval-config.json` carries three bars —
`extraction`, `narration`, `description` — and `Ingester.nameStrand`
(`Sources/PensieveKit/Ingest/Ingester.swift:366-389`) is not among them, despite being a real
model-backed task with its own prompt that writes a **name and description onto a canonical node**.
So `CLAUDE.md`'s "new LLM-backed tasks must register an `EvalTask`" rule has a pre-existing
exception nobody chose, on the highest-volume naming path in the app (99 of 281 node names).

**Decision for slice 5 (2026-08-13):** its labeler does **not** register a bespoke task. Registering
only the new path would leave the older, higher-volume one uncovered while implying naming is
measured. Its quality is instead pinned by committed probes
(`measurements/2026-08-13-slice5-label-quality/`), which for a single-prompt task is the more
reproducible artifact anyway. **If naming gets a bar, it should cover both call sites at once.**

**2. `CorpusBuilder` has two hardcoded task lists the guardrail does not check.** The
registry↔config test (`Sources/PensieveKit/Eval/EvalTask.swift:22-30`, asserted by
`Tests/PensieveKitTests/EvalConfigConsistencyTests.swift`) only checks that every task has a bar and
every bar has a task. It does **not** check that a registered task can load corpus items — and
`CorpusBuilder` names its tasks by hand in two places. **A task can register, have a bar, pass the
whole suite, and silently load zero items, reporting nothing while looking healthy.** That is a
guardrail with a hole in the exact shape of the mistake it exists to catch.

*Revisit trigger:* the next time an `EvalTask` is added or the harness is touched — fix (2) then
regardless, since it is a few lines and it currently makes (1) harder to close safely.

---

## `TextQuality.shorten` — two weak tests on correct code (2026-08-13)

Parked at the end of the slice-5 run rather than fixed, because the process allows exactly one fix wave
after the whole-branch review and these arrived in its scoped re-review. **Both are test-strength issues;
the shipped implementation was traced correct three times independently.** Together they are ~3 lines.
Recorded because this project has twice shipped vacuous tests and caught them only by mutation.

- **The maximality assertion cannot catch the `+1`-dropped mutant.** `shortenBreaksOnWordBoundariesNeverMidWord`
  gained an assertion that demonstrably kills the first-word-only mutant (mutation-verified both
  directions). But a reviewer hand-traced that with *this* test input, dropping the `+1` for the joining
  space produces a **byte-identical** 56-character output — so the assertion is structurally insensitive to
  it, not merely unverified. *Smallest fix: a second input whose break margin is exactly one character.*
  Failure mode if it regresses: labels come back one word short.
- **`shortenNeverFusesWordsAcrossAnEmbeddedNewline` is vacuous against its own claim.** Its assertions only
  check for the literal absence of `\n`, which its two sibling tests already prove by pinning exact strings.
  A delete-only mutant (`replacingOccurrences(of: "\n", with: "")`) would fuse `agent`+`and` and still pass
  it. *Smallest fix: assert the fused token is absent, or pin the exact string as its siblings do.*

*Revisit trigger:* the next edit to `TextQuality.shorten`'s join arithmetic, or any pass that touches these
tests.

---

## The `claude -p` self-capture loop left 427 rows behind — the BUG is fixed, the RESIDUE is not (2026-08-14)

Measured while re-speccing transcript-passage chunking. **The bug itself is already fixed, twice** —
this entry is only about the rows it left in the store. It was initially filed here as an open capture
defect; that framing was wrong and is corrected below, because acting on it would mean re-fixing
something that already works.

**What is in the store:** 427 of the 1,099 `cc.session` events are Pensieve's own LLM calls. All carry
cwd `/` (hence transcript paths under `~/.claude/projects/-/`, a directory that does not exist),
**423 have exactly 1 prompt**, all are attributed to one node named literally `/`, and their
`workSummary` values are summaries *of other sessions* — one leaking the scaffolding verbatim:
*"The session is already summarized. Here it is in 1-2 sentences:"*.

**Why it cannot recur.** `ClaudeCLIProvider.shellRun` pins `currentDirectoryURL` to
`PensievePaths.llmScratchDirectory()`, and its comment already describes this exact failure —
*"every extraction call became a Claude Code session at the filesystem root, got captured by the
SessionEnd hook, and was re-ingested as 'work' (a feedback loop that produced a phantom project named
'/')"*. `Ingester.ingestSession` then refuses `ProjectResolver.isDegenerateRoot` (`/` or `$HOME`) as a
second line of defense, dropping such a session permanently. Both guards ship. Every one of the 427
events is dated **2026-07**, consistent with the fix, and the `/` node is **archived**.

**What is still open — purging the residue.** Those 427 summaries are in the BM25 corpus today,
reachable under Include Archived, and they are model output *about* Pensieve's internals, which is the
most confusing thing a search for Pensieve's own work can return. They also inflate any
"sessions captured" figure by 39%: the transcript-availability measurement read 36% with them and 59%
without, and the second number is the true one.

Two options, both small:

1. **Leave archived** (status quo). They are out of every normal view; only Include Archived reaches
   them. Costs nothing, keeps a permanent 39% distortion in any count over `cc.session` events.
2. **Purge** — delete the 427 events and the `/` node. There is no delete-events verb and `Ingester`
   is the only canonical writer, so this is a one-off maintenance command rather than a feature. The
   events cascade from the node, so deleting the node may be sufficient; verify before relying on it.

*Revisit trigger:* the next time a count over `cc.session` events matters (a stats surface, a corpus
measurement), or before anything reads archived event summaries into a prompt.

---

## In-node find — highlight/document skew — OPEN, needs thinking (2026-08-12)

Raised by the whole-branch review of `worktree-in-node-find` and **deliberately left unchanged** — the
obvious fix trades the bug for a worse one, so this wants a design, not a patch.

`NodeFindState.runs(for:text:)` takes an `anchor` and **ignores it**: highlighting is derived purely
from the text handed to it. So during the window between a provenance row rendering its transcript and
`noteRenderedProvenance` landing in the document, that row tints matches that are **not** in the "N
matches" count and that ⌘G cannot reach. The count and the highlights disagree, briefly.

**Why the one-line fix was rejected:** gating `runs` on document membership makes the same window show
*no* highlights on text that visibly contains the query — a reader watching the phrase they typed go
unmarked reads as broken, where a slightly-early highlight reads as fine. Missing highlights are the
worse failure, so the skew was kept and flagged.

**The real question is which of two models the pane should hold**, and it isn't a rendering detail:
either the document is the single authority (and rows must not render until they're indexed — needs the
sweep and the mount path to converge, or a placeholder), or highlights are locally derived and the
*count* becomes the approximation (which weakens ⌘G's promise that the count is walkable). Note the
transcript path is only 18 of 122 loose ends on the `Pensieve` node, so the window is rarer in practice
than it looks in the code. *Revisit trigger:* the eyeball pass shows the skew is actually noticeable,
or a future find surface makes the count load-bearing beyond ⌘G.

**Settled at the same time, no work needed:** ⌘F on the Briefing **stays inert**. `FindCommands`
disables it with no focused node and it does not fall back to the global field — that is the intended
behaviour after the keybinding swap, not an oversight.

---

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

# Tier 3 — Parked, trigger-gated

Real ideas waiting on a named trigger. Parked deliberately, none foreclosed. The trigger is the
contract: when it arrives, the entry is picked up — it is not a euphemism for "someday".

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

## Widgets — DEFERRED (2026-07-08), UNBLOCKED (2026-08-21): App Groups provisions

Attempted to pick up Widgets (the first *second process*). Hit a hard prerequisite during brainstorming and
deferred with the user's agreement.

**The blocker.** A macOS **WidgetKit extension is always sandboxed** — it cannot read the canonical store at
`~/Library/Application Support/Pensieve/` (`PensievePaths.supportDirectory()`), which every current writer (git
hooks via CLI, launchd daemon, app) and reader uses. The only way to share the store with the extension is an
**App Group container** (`~/Library/Group Containers/<TeamID>.<group>/`), which on macOS requires the app to be
**signed with a Team ID** and the `com.apple.security.application-groups` entitlement **provisioned**.

**~~Why blocked now.~~ Resolved 2026-08-21.** *(Historical: the app was **ad-hoc signed*** (`CODE_SIGN_IDENTITY:
"-"`, no `DEVELOPMENT_TEAM`)*, so it had no Team ID, and the only signing artifacts on the machine were
corporate MDM/Configurator ones (an "Apple Configurator: Matchory GmbH" identity; a Microsoft Intune MDM Agent
profile, team `UBF8T346G9`) — none carrying App Groups. The free-Personal-Team question is moot: the membership
is paid.)* All four targets now sign with `DEVELOPMENT_TEAM: TH593VRB6W`, so **"needs a Team ID" is satisfied**;
what is still unproven is whether the `com.apple.security.application-groups` entitlement **provisions**.

**Revisit trigger — ✅ FIRED 2026-08-21.** The paid **individual** membership is active on team `TH593VRB6W`
(agreement accepted). *(How it was confirmed, since the obvious signals all misled: **Xcode ▸ Settings ▸
Accounts kept reading "Personal Team" from a stale cache** long after the portal was correct, so that label is
**not** a paid-vs-free signal — the earlier advice to watch it was wrong. The reliable signal is the existence
of `Apple Distribution` and `Developer ID Application` certs, **neither of which a free Personal Team can
mint**; both appeared once the account was re-added. The Team ID is also readable locally, from the dev cert's
`OU` field: `security find-certificate -a -c "Apple Development" -p | openssl x509 -noout -subject`. Note the
personal team was **converted in place** — the same Team ID appears in certs minted both before and after
purchase, so a pre-purchase cert does not imply a free team.)* Team-ID signing and Focus filters are already
done and confirmed (see the Focus-filter entry); **App Groups is HALF open — corrected 2026-08-21, later the
same day, after an initial "PROVEN — GO" that was overstated.** `project.yml` gained a `Pensieve.entitlements`
carrying only `com.apple.security.application-groups = ["TH593VRB6W.me.mazetti.pensieve"]`, signing moved
`Manual → Automatic`, and the Makefile gained `-allowProvisioningUpdates`. What is genuinely true: the
entitlement **signs** — the app reports it under a full `Apple Development → WWDR → Apple Root CA` chain with
`TeamIdentifier=TH593VRB6W` — and the container at
`~/Library/Group Containers/TH593VRB6W.me.mazetti.pensieve` exists and is writable.

**What is NOT true: the entitlement is not honoured.** `secd` and `trustd` log, on every app launch:
`Entitlement com.apple.security.application-groups=("TH593VRB6W.me.mazetti.pensieve") is ignored because of
invalid application signature or incorrect provisioning profile`. No provisioning profile exists —
`~/Library/Developer/Xcode/UserData/Provisioning Profiles/` is empty, `Contents/embedded.provisionprofile` is
absent, and the build log prints `Signing Identity:` but never `Provisioning Profile:`, so
`-allowProvisioningUpdates` created nothing. **The container test could not have caught this**: as the probe
below established, `containerURL(forSecurityApplicationGroupIdentifier:)` performs no entitlement check for an
unsandboxed process, so it resolves whether or not the entitlement is honoured. The app half therefore works by
accident (it is not sandboxed and can write the path directly); **the widget half — the only half that needs the
entitlement — is unproven and currently would fail.**

**Before Widgets, this must be resolved:** obtain a Mac Development provisioning profile that includes the App
Group. `xcodebuild -allowProvisioningUpdates` alone did not produce one in a non-interactive shell; the likely
requirement is an authenticated Xcode account session (Xcode ▸ Settings ▸ Accounts ▸ Download Manual Profiles,
or a first interactive build), or registering the App ID + group in the portal and wiring a downloaded profile.
Until then treat App Groups as **provisionable in principle, not yet functioning**.

**Two claims previously recorded here are WRONG; a probe disproved both.** (1) It said a non-sandboxed app *must*
use the Team-ID-prefixed group id and that the wrong form yields `nil` with no diagnostic. In fact **all three
forms resolved** (`TH593VRB6W.me.mazetti.pensieve`, `group.me.mazetti.pensieve`,
`TH593VRB6W.group.me.mazetti.pensieve`). (2) Worse for anyone using it as a test: the same binary **with the
entitlement stripped entirely still resolved the container**. For an unsandboxed process
`containerURL(forSecurityApplicationGroupIdentifier:)` is effectively path construction — **it performs no
entitlement check**. Consequences: the CLI and the sync agent need **no** entitlement to participate (good, and
it makes the store-migration option cheaper than assumed); but a resolving `containerURL` from an unsandboxed
process is **worthless as a go/no-go** for the sandboxed case. Naming rules and entitlement enforcement only
begin under a sandbox, which cannot be tested without a real widget target. Plan for macOS wanting
`<TeamID>.<name>` and iOS wanting `group.<name>`, and **treat it as unverified until a widget exists**.

**CloudKit was never on this gate — that framing was a conceptual error.** An App Group is a *same-device,
cross-process* mechanism; CloudKit is *cross-device*. They share only the paid membership. Correspondingly, an
**iOS companion shares nothing through the Mac's App Group** — that boundary is CloudKit's. An App Group is how
the iOS app would share with *its own* widget, in a container separate from the Mac's.

**Decision 2026-08-21: publish a snapshot; do NOT move the canonical store (yet).** The store is 37 MB beside a
34 MB search index with a live 1.5 MB WAL, held concurrently by the app, five `pensieve mcp` processes, the
300 s sync agent and every git hook. Against that, moving it in buys little and costs a lot:
- **WAL forces write access.** A WAL-mode database cannot be opened read-only — readers write `-shm` and may
  recover the `-wal`. A "read-only" widget would hold genuine write access to canonical data.
- **Extension budgets.** Widget extensions get seconds of CPU and tight memory (iOS commonly ~30 MB); opening
  and WAL-recovering a 37 MB store per timeline refresh is a jetsam candidate.
- **`0xdead10cc`.** iOS terminates a suspended process still holding a file lock — SQLite locks included — on a
  *shared-container* file. This is the classic app-plus-widget crash, and it bears directly on the companion.
So the app publishes a small digest into the group container and the widget renders something it cannot damage.
`PensievePaths.defaultSupportDirectory()` (`Sources/PensieveKit/Support/PensievePaths.swift`) remains the single
seam and the only place naming `~/Library/Application Support/Pensieve`, so the full migration stays available:
resolve to the group container only once a canonical store exists there, which makes the flip atomic with the
move. **Revisit if a widget needs real queries** — arbitrary search, a node picker over the whole tree, live
BM25 — rather than a precomputed view. Do **not** enable the sandbox or hardened runtime alongside any of this:
the app must keep reading `~/Library/Application Support` and shelling out to `claude -p`.

**The capability set the user intends to reach (drafted 2026-08-21, deliberately NOT shipped yet).** A
hand-written `Pensieve.entitlements` in the `main` checkout — unwired, since `project.yml` there still had
`CODE_SIGN_IDENTITY: "-"` — listed the eventual target: `com.apple.developer.icloud-container-identifiers`
(`iCloud.me.mazetti.pensieve`), `com.apple.developer.icloud-services` (`CloudKit`),
`com.apple.developer.aps-environment` (`development`), `com.apple.developer.ubiquity-kvstore-identifier`,
`com.apple.developer.shared-with-you`, `com.apple.developer.suggested-actions`, and
`com.apple.developer.devicecheck.app-attest-opt-in`. Recorded here and **overridden** in the shipped file,
which carries the App Group alone, for three reasons. (1) The draft used the plain `group.me.mazetti.pensieve`
form where the shipped file uses `TH593VRB6W.me.mazetti.pensieve` — **a different group id is a different
container**, and per the probe above an unsandboxed process resolves either without complaint, so the mismatch
would stay invisible until a widget existed. (2) Wiring `icloud-container-identifiers` under automatic signing
makes the next build **register an iCloud container in the Apple account** — a portal write, for pillar #4,
which is still gated on the unresolved F7 per-device-state decision. Add it *with* the CloudKit spec, not
before. (3) `shared-with-you`, `suggested-actions` and app-attest correspond to nothing Pensieve does today;
every entitlement is attack surface and a provisioning dependency, so they should arrive with the feature that
needs them. The key list above IS the record — reinstate from it when each feature lands, checking the group-id
form against the shipped file first.

**~~A third surface joined this gate on 2026-08-12: background sync itself.~~ Retracted 2026-08-13** — that
outage was a stale LWCR, not a Team-ID problem, and the agent now spawns ad-hoc-signed with
`codeSigningTeamID: ""`. See Archive ▸ "Background sync is dead — launchd won't spawn the agent". This gate covered Focus filters and Widgets only — and is closed as of 2026-08-21. CloudKit was mis-filed here; it needs the paid membership but not an App Group.

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

---

# Archive — shipped work

Dated records of shipped work, newest first, **preserved verbatim** from the pre-2026-08-15 ledger.
Kept because the reasoning — especially the refuted hypotheses, the rejected designs and the
measurement discipline — is the reusable part, and `CLAUDE.md` ▸ Status is the short version.

**Several entries below carry a *"Deferred out of …"* sub-list, and some of those items are still
live.** They were not promoted wholesale: where one still matters it is cross-referenced from a tier
above (e.g. the per-kind ingestion-handler protocol → **F6**). Read the sub-lists when picking up
adjacent work.

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

---

## Custom store location — one relocatable support folder, and a readable Locations pane — DONE (2026-08-15, branch `worktree-custom-store-location`, through `1985efe`)

Shipped a user-settable support folder (one root, persisted in the shared app defaults) and a verified
copy-verify-commit-recycle move, replacing the fixed `~/Library/Application Support/Pensieve` location.
Collapsed four independently-drifting path resolvers into one pure `PensievePaths.supportDirectory(customRoot:)`;
anchored the relocation lock outside the moving directory (inode binding); left git hooks lock-free by
design and recovered anything they wrote during the copy window post-commit; redesigned the Locations
pane Xcode-shape because the real complaint was unreadable, unselectable truncation, not width. Full
detail in `CLAUDE.md` Status. Spec/plan: `{specs,plans}/2026-08-15-custom-store-location*`; execution
ledger `.superpowers/sdd/2026-08-15-custom-store-location/progress.md` — nine tasks, several plan defects
found and fixed in execution (a test that exercised check-and-release semantics the shipped code doesn't
have, a nonexistent `ByteCountFormatStyle` initializer, a 60-line function over the repo's lint cap, a
fixture payload that could not decode, and — the most serious — a Critical preflight hole that would have
deleted or unlinked a user's existing folder or file), plus ten further Important findings across four
of the eight task reviews — all fixed; see the ledger for the full account.

### Deliberately left open by this design

- **Per-file custom paths.** One root only. The store, spool, narration cache, search index and
  translation cache all already derive from `supportDirectory()`, so a single knob moves everything with
  no half-relocated state representable; per-file granularity would only add surface no one has asked
  for. *Revisit trigger:* a real need to keep, say, the search index on a faster disk than the canonical
  store.
- **A custom Logs location.** The launchd helper writes `sync.log` itself at a fixed path
  (`~/Library/Logs/Pensieve`); a second cross-process knob for a directory nothing else reads from buys
  nothing today. *Revisit trigger:* Logs actually needing to move (e.g. disk-space pressure specific to
  that folder).
- **Isolating the defaults domain so the relocation becomes automatable.** `make uitest` isolates the
  SQLite store via a temp path but not `UserDefaults` — `RelocationLauncher` and `StoreRelocator` write
  into the same shared `me.mazetti.pensieve` domain the real 185-project install reads, so no automated
  test may trigger an actual relocation without risking that live install (ruling R9 in the execution
  ledger). A launch-argument override reaches `NSArgumentDomain` for reads, but the relocator's own
  `defaults.set` would still persist past it — genuinely isolating the write path is its own piece of
  work. *Revisit trigger:* wanting real CI coverage of the relocation state machine rather than
  build-and-inspection evidence for Tasks 6 and 8.
- **The stale `.bak` files and the retired `preferences.json`** already sitting in the support directory
  (debris from earlier features) are now copied on every relocation along with everything else. Mentioned
  per surgical-change discipline, not cleaned up — this branch's job was to move the folder faithfully,
  not to tidy its contents.

### Deferred minors from this run (all reviewed, all judged not worth their fix)

- **`flock` is acquired inside an `OSAllocatedUnfairLock` critical section** (`StoreOpen.swift:41-44`,
  `CanonicalWriterGate.admit`) — a documented anti-pattern for unfair locks, since the `open`/`flock`
  syscalls can take real time under an unfair lock meant only for cheap, bounded critical sections.
  Judged low-impact: `LOCK_NB` never blocks, and the syscalls run at most once per process instance,
  behind the `nil` fast path on every later call. *Revisit trigger:* `admit()` ever moving onto a hot
  path.
- **`make test` now creates and holds `~/Library/Caches/me.mazetti.pensieve/relocation.lock` SHARED for
  the whole test process**, because the pre-existing `openCanonicalHonorsDBOverride` test calls
  production `openCanonical()`. Consequence: a relocation attempted during a test run is refused ("try
  again"), and a test run started during a relocation fails. Honest and recoverable, but worth deciding
  whether the test suite ought to be gate-free before this surprises someone.
- **`StoreRelocator.swift:110`** — with the read-only-open fix for verification, a source holding a
  spool but NO `pensieve.sqlite` (a repo where git hooks ran before the app ever opened the canonical
  store) aborts with a raw GRDB `SQLITE_CANTOPEN` rather than a typed `RelocationError`. The *outcome* is
  correct (source stays intact, nothing commits); only the error's shape leaks, and the app presents an
  untyped error on that one path.
- **`recoverPendingRows` opens a writable canonical pool (`:210`) and never explicitly closes it.** This
  runs post-commit with no filesystem copy after it, so it's harmless — noted only for symmetry with the
  explicit closes added elsewhere in the same file.
- **Other CLI commands (`Checkpoint`, `Track`, `Ingest`, …) call `openCanonical()` unguarded** and will
  exit non-zero if invoked during a relocation. Correctly out of scope — the brief named only the two
  scheduled/automated processes (`pensieve sync`, the launchd helper) — but worth deciding whether a
  manual command failing loudly mid-relocation (rather than deferring like the two automated callers do)
  is the experience actually wanted.
- **The determinate progress bar sits at a flat 5% for the entire copy step**, so its stated anti-hang
  rationale (showing real progress) isn't actually achieved for the step that takes the most wall time.
- **Shell metacharacter quoting in the relaunch helper** (`RelocationLauncher.relaunch`'s `/bin/sh -c`
  string interpolating the bundle path and PID) is unescaped. Low risk in practice — both values come
  from the OS, not user input — but not defensively quoted.
- **A swallowed spawn failure in the relaunch helper terminates the app silently** if `Process.run()`
  throws — no error surfaced, the app just quits.
- **`recycle:`'s closure returns a success value it cannot actually know**, and calls into AppKit
  (`NSWorkspace`) off the main actor.
- **`String(describing:)` is used as user-facing failure text** for `RelocationError` cases the mapping
  table doesn't cover — plan-mandated, not an oversight; the real fix would be a full `LocalizedError`
  conformance over `RelocationError`, which the spec didn't call for.
- **`AppModel.swift` sits at 396 of the `swiftlint --strict` 400-line cap** after this branch — the next
  line added to it (by any future feature) trips CI. Worth knowing before starting the next app-side
  task, not something this branch could fix without an unrelated refactor.
- **Skipping `configureBackgroundSync()` on the relocating launch** (the fix for the sync-agent race
  above) reduces the self-conflict race rather than eliminating it: a registration surviving from a
  *previous* launch still carries `StartInterval 300` and can fire mid-relocation anyway. Safe either way
  — the relocator either already holds the exclusive lock (agent defers cleanly) or loses with
  `.lockUnavailable` (recoverable via the Continue affordance, not fatal) — but per `CLAUDE.md`, skipping
  the refresh also leaves a stale LWCR for that one session, the documented `EX_CONFIG` spawn-failure
  mode.
- **Corrected:** this entry previously claimed the `"Custom"` catalog entry had no `en`
  localization. Re-checked against `Localizable.xcstrings:782-798` directly: Task 8 already added a
  full `en` entry ("Custom") alongside `de` ("Benutzerdefiniert") — the claim was stale by the time
  it was written here. A confidently wrong doc claim is worse than none, so it is corrected rather
  than left standing.
- **The inspector's byte-size line reads "Zero KB" until the async measurement `.task` completes** —
  cosmetic, self-correcting, and consistent with the app's existing progressive-loading style elsewhere.

### Carries from the review rounds

- **Resolved by the final whole-branch review's fix wave (2026-08-15):** the item previously recorded
  here — `PensieveDefaults.isCustomSupportRoot(_:)` checking only `!raw.isEmpty` while the Kit resolver
  `PensievePaths.supportDirectory(customRoot:)` also requires an absolute path — is fixed. Rather than
  the suggested one-line `!raw.isEmpty && raw.hasPrefix("/")` (which the review caught as still
  insufficient — the resolver trims whitespace *first*, so a leading-whitespace value would still
  disagree), `isCustomSupportRoot` now **delegates** to `PensievePaths.supportDirectory(customRoot:)`
  and compares the resolved directory against the default, making the two paths agree by construction
  rather than by two independently-maintained predicates.
- **An environment incident during Task 4's fix round:** the host disk filled to 100% (679 MB free)
  mid-fix, blocking Bash/Write/Edit and leaving one file in a state the implementer could not revert by
  hand — resolved by freeing space (`make clean` in this worktree, then cleaning ~20 GB of stale
  `.build`/`.build-xcode` across four other worktrees plus 45 leaked temp trees) rather than by discarding
  any uncommitted work. No commits or fixes were lost; recorded here only because a future session
  hitting `ENOSPC` mid-edit in this repo should know it has happened before and how it was recovered.

### Deferred from the final whole-branch review (ship-with-it, 2026-08-15)

- **M2 — an interrupted relocation leaves a partial destination that blocks retrying to the same
  folder.** `preflight` correctly refuses a non-empty destination, and a relocation that dies
  mid-copy leaves exactly that: a partial, non-empty destination directory. The behaviour is correct
  and non-destructive (nothing is lost, nothing commits) but unhelpful — the user must manually clear
  the partial folder before retrying the same destination, with no UI affordance telling them why.
  *Revisit trigger:* a real interrupted-relocation report from actual use.
- **M4 — a missing custom root renders as an empty world with no explanation.** If the custom
  support folder is unreachable at launch (the classic case: it lived on an external disk that is
  now unplugged), `PensievePaths.supportDirectory()` still resolves to the stored path, and every
  read against it comes back empty — the app opens to zero projects, zero loose ends, with nothing
  in the UI saying *why*. Also recorded in the design spec's own "documented rather than engineered
  around" list (`docs/superpowers/specs/2026-08-15-custom-store-location-design.md`). *Revisit
  trigger:* this is the human-verify checklist's item 3 in `CONTINUE.md` — running it is what turns
  this from a predicted gap into a described one.
- **The `relocation-test-*.plist` cleanup is best-effort, not provably complete, because of a real
  OS-level race outside application control.** `StoreRelocatorTests.swift` and
  `StoreRelocatorVerificationAndCommitTests.swift` now `removePersistentDomain(forName:)` **and**
  directly `removeItem` the backing plist in every test's `defer` (closing the literal 51-file litter
  found on this machine — all removed). Measured directly, though: `removePersistentDomain` alone
  never deletes the on-disk file (confirmed with an explicit `synchronize()` immediately after, which
  still left the file in place), and even the combined remove-and-unlink is racing `cfprefsd`'s own
  asynchronous write-back of the *original* `.set()` — a throwaway probe script showed anywhere from
  0/10 to 10/10 of freshly-deleted suite files reappearing after a **3-second** sleep, so this is not
  a timing window any bounded in-test wait can close reliably. Repeated `make -B test` runs after the
  fix showed roughly half of the 8 suite-creating tests still leaving a file behind per run (down from
  8/8 before). A one-time sweep (`rm -f ~/Library/Preferences/relocation-test-*.plist`) was run as
  part of this fix and left the directory clean at the time of writing, but a future session should
  expect to find a handful again, not zero. *Revisit trigger:* if this genuinely needs to hit zero,
  the real fix is to stop giving `StoreRelocator.defaults` a disk-backed `UserDefaults(suiteName:)`
  suite in tests at all (a protocol/mock seam) rather than trying to out-race `cfprefsd` — out of
  scope for this fix wave. The same disk-backed-suite-in-`defer` pattern is already used by
  `PreferencesTests`, `SystemStatusTests`, `DefaultProviderTests` and `TranslationTargetTests`, so this
  is a pre-existing, project-wide limitation, not one specific to this branch.

*Revisit trigger for the whole section:* the human-verify checklist in `CONTINUE.md` — the end-to-end
move has never been run (Tasks 6 and 8 carry build-and-inspection evidence only; see that file's own
"Human-verify carries — custom store location" section for why automation cannot cover it) — so that
checklist is the first real exercise of this feature and may reorder everything above.

---

## Translation settings — pack management, coverage & backfill — DONE (2026-08-14, branch `worktree-translation-settings`, through `1ac2cab`)

Shipped the control surface the on-device translation slice never built: a picker over the **29 targets
this Mac actually offers**, pack status with a download that mounts only while pressed, a link out to
the OS pane that owns pack lifecycle, a coverage readout counted by **distinct text**, and one explicit
**serial, idempotent, resumable, cancellable** backfill. The starting point it exists to expose was
measured, not guessed: **0 of 1,294** translatable texts covered, with `nodeName`/`nodeDescription`
having had **no production writer at all**. `TranslationTarget.supported = ["de"]` is gone — its stated
index-size cost was refuted by its own pre-registered ranking gate (McNemar **p = 1.000**). Trust gate
untouched; no `EvalTask` (nothing here is LLM-backed). Spec/plan:
`{specs,plans}/2026-08-14-translation-settings-coverage*`; full detail in `CLAUDE.md` Status.

**Subsumed, not deferred:** the translation slice's **per-node bulk translation** follow-up
(`specs/2026-08-12-on-device-translation-design.md:241` — "an easy additive follow-up if dogfooding
shows the sparsity") is **closed by the global backfill**. A per-node button would translate a subset of
the same corpus through the same store with a second denominator to keep honest; one global pass over
`TranslatableCorpus` covers every node, and re-pressing it costs only what is missing.

### Deliberately left open by this design

- **An ETA on the backfill.** Needs one observed run's throughput. The eval README logged 1,303
  attempts and 0 nils but **no elapsed time**, so any "~4 min left" would be invented. The readout is
  `318 of 1,294` until a real run has been timed. *Revisit trigger:* the first completed run on real
  hardware — note its wall time, then decide.
- **Concurrent backfill.** Serial on purpose: on-device translation throughput under concurrency is
  unmeasured, and a bulk pass over someone's whole history is not where to find out. *Revisit trigger:*
  a measured serial run that is slow enough to be worth the risk — measurement first, then a decision.
- **RTL layout for translated content.** `ar-AE` is offered because the framework offers it; translated
  node names and loose-end text will render in views built for LTR (chrome is unaffected). *Revisit
  trigger:* an RTL target actually being used.
- **Ambient translation in the sync agent — explicitly rejected, not parked.** The launchd agent stays a
  **reader** of translations, exactly where the translation spec drew the line, so there is one writer
  of `translation-cache.sqlite` and no arbitration between a background slice and a foreground run.
  Reopening this means reopening that boundary, not adding a feature.
- **Pruning a previous language's rows after a switch.** Switching languages costs a full pass for the
  new one and leaves the old language's rows on disk. The file is disposable and the index rebuild drops
  their documents (`gather` looks up only the current language), so the only cost is disk. *Revisit
  trigger:* the cache file growing large enough to notice.
- **Coverage is a store lookup per unit** (1,294 reads on Settings open today). Becomes one grouped
  query if it is ever slow enough to feel; deliberately not designed around in advance.

### Deferred minors from this run (all reviewed, all judged not worth their fix)

- **A blank coverage row after an out-of-order re-measure.** The coverage state carries the language it
  was measured for and renders only on a match, so a stale measurement for a superseded language shows
  **nothing** rather than another language's numbers. Bounded: `.task(id:)` also fires on appear, so
  closing and reopening Settings recovers it. Fixing it fully needs the monotonic token the fix
  deliberately did not add — and showing nothing beats showing a number that is not about the selected
  language.
- **A narrow ABA download race.** Press Download for A, switch away, switch back to A before the first
  closure resumes, and both the orphaned and the fresh closure can complete for a genuinely-current A.
  Not a wrong-language write — at worst a redundant `isInstalled` recompute and a no-op nil assignment.
- **The progress bar persists until the in-flight unit returns** after a language switch. Correct
  behaviour on **Stop** (the bar *should* stand until the unit lands); telling "stopped" from
  "superseded" costs state for a sub-second cosmetic window.
- **Endonym sort order under mixed scripts.** The picker sorts by `localizedStandardCompare`, i.e. the
  app locale's collation over Deutsch / 中文 / العربية. A readability quirk of sorting names written in
  different scripts; the alternative (sort by identifier, or group by script) is not obviously better.
- **`TranslationCoverage`'s `off` test pins the observable side effect, not "no store read".** It
  catches the realistic mutation (deleting the `!language.isEmpty` guard makes `total == 4`), but a
  literal read-count assertion would need an injectable store seam that does not exist.
- **The pre-macOS-26 `else` branch is unreachable** at the app's 26.0 deployment target. The spec's
  degradation table calls for it and it mirrors surrounding code, so it stays.

*Revisit trigger for the whole section:* the human-verify checklist in
`plans/2026-08-14-translation-settings-coverage.md` — **nothing in the app half has executed yet** (no
app unit tests; the documented smoke-launch renders no view body), so that checklist is the first real
exercise of this feature and may reorder everything above.

### Carries from the final whole-branch review (recorded, not fixed)

- **`TranslatedCorpusDumpGenerator.swift:50-58` restates corpus eligibility a third time and has already
  drifted.** It filters `LooseEnd.isOpen` under a comment claiming it "mirrors gather's own eligibility
  exactly", but the corpus has used `label != noise` (open **and closed** ends) since the loose-end-
  resolution branch. Pre-existing and outside this branch's diff, but this branch built the type
  (`TranslatableCorpus.gather`) that would replace those nine lines. Consequence: the spec's claim that
  this feature produces "precisely the treated arm the ranking gate already measured" is slightly
  overstated — the gate's German arm predates closed loose ends, so the shipped backfill translates a
  marginally wider set than was measured. Directionally identical, low risk.
- **The downloadable-language marker is a bare `⤓` glyph**, with no label or accessibility text, where
  the spec said rows should label installed vs downloadable.
- **`%lld of %lld translated` renders with no grouping separator** ("0 of 1294"), where the spec's own
  example writes "1,294" (German would want "1.294").
- **The coverage readout does not say what it covers.** "1294 von 1294 übersetzt" can read as "the app
  is German now" while the tree stays English (see the search-only note above) — a clarifying word in
  the label or the section footer would close it. Deferred to in-situ judgement since nothing here has
  been seen running.
- **The nine new catalog keys were inserted where `Prepare translation` sat**, so the file is no longer
  alphabetically sorted and the next Xcode edit will re-sort it into a large reformat diff.

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

## Background sync is dead — launchd won't spawn the agent — ✅ RESOLVED (2026-08-13)

**Status: CLOSED. The agent has run every ~5 minutes since 2026-08-13T11:18:25Z** (`launchctl print`:
`runs = 5`, `last exit code = 0`, `state = not running` — correct, the helper exits between runs), after
35 h of silence from `2026-08-11T23:29:36Z`. It resumed the moment the *installed* bundle was launched.

**Root cause: a stale LWCR that nothing refreshed, because the app being launched was never the installed
one.** `make install` replaces `/Applications/Pensieve.app` and mints a new helper cdhash; only launching
*that* bundle runs `registerIfNeeded()` → `unregister()` + `register()`, which rebuilds the LWCR against the
current binary. The app being launched was a **2026-07-10 DerivedData copy** picked by Spotlight out of
eleven bundles registered under `me.mazetti.pensieve` — a build that predates the sync agent entirely (no
`Contents/Library/LaunchAgents/`, no `Contents/Helpers/`), so it could not refresh anything. Install after
install drifted the cdhash away from a registration no launch ever healed. See the `make run` note below.

**`BackgroundSyncService.register()`'s doc comment (`BackgroundSyncService.swift:20-28`) described this
exactly** — "a registration from a previous build keeps spawn-failing (`EX_CONFIG` / 'Launch Constraint
Violation' kills) on every interval" — and is **vindicated, not in need of correction.** Hypothesis 5 below
recorded that cycle as refuted; today's evidence contradicts that, so the refutation is the entry that was
wrong. Best guess at why the 2026-08-12 toggle test appeared to fail: it exercised the toggle in some
*other* copy of the app, which registers that copy's helper, not the installed one.

**Two hypotheses this run killed:**
- **8. *Duplicate LaunchServices registrations were the cause* (proposed 2026-08-13). REFUTED, and this is
  the decisive datum.** The nine stale registrations were deleted first, and a spawn attempt **after** that
  cleanup still died: `PensieveSyncAgent-2026-08-13-131026.ips`, `procPath
  /Applications/Pensieve.app/Contents/Library/Helpers/PensieveSyncAgent`, `"namespace":"CODESIGNING",
  "indicator":"Launch Constraint Violation"` — the documented signature, unchanged. The duplicates explain
  why the *wrong app* kept getting launched; they are not what launchd was rejecting.
- **The Team-ID gate is NOT the blocker for this.** The agent now spawns with `codeSigningTeamID: ""` and
  `codeSigningValidationCategory: 10` — the same ad-hoc identity that was failing. **Ad-hoc signing is not
  categorically incompatible with a bundled `SMAppService.agent`.** This does not touch the Focus-filter /
  Widgets / CloudKit gate above, which is a separate, still-real Team-ID requirement.

**What is still not proven.** `make run` did two things between the 13:10 failure and the 13:18 success —
a fresh `rm -rf` + `ditto` of the bundle, and the launch that triggers `registerIfNeeded()`. The doc
comment's mechanism says the launch is what mattered, and the timing fits, but the clean experiment
(reinstall, launch a *different* copy, confirm it dies again) was not run and is not worth running.

**The durable fix is `make run`** (added 2026-08-13, `785d500`): it is the only path that installs *and*
relaunches the installed bundle, so the cdhash and the registration cannot drift apart. Installing without
launching `/Applications/Pensieve.app` is what created this outage; `make install` still prints the
"launch it once" note for the same reason.

<details>
<summary>Original investigation (2026-08-12) — seven refuted hypotheses, kept as record</summary>

**Symptom.** The agent last ran at `2026-08-11T23:29:36Z` and has not run since. `launchctl print` shows the
job registered and `enabled`, with `runatload` set, `run interval = 300 seconds`, and
`pended nondemand spawn` — a spawn launchd wants to perform and never performs (`runs = 0`). Forcing it with
`launchctl kickstart` produces:

```
xpcproxy exited due to OS_REASON_CODESIGNING | Launch Constraint Violation,
error info: c[5]p[1]m[1]e[0], (Constraint not matched) launch type 0
```

with `codeSigningTeamID` empty and `codeSigningValidationCategory: 10` in the `.ips` report. So the pending
spawn and the forced kill are the same rejection seen from two sides.

**The helper itself is fine.** Run directly it does real work
(`/Applications/Pensieve.app/Contents/Library/Helpers/PensieveSyncAgent` → a normal `sync.log` line).
`codesign -v --deep --strict` passes on the bundle. This is launchd refusing to start a working binary.

**Refuted, with the evidence — do not re-test these:**
1. *Caused by reinstalling the app.* No — it stopped 11 h before that day's install, with `last exit code = 0`.
2. *The overnight gap was sleep.* No — `pmset -g log` has **zero** Sleep/Wake transitions on 2026-08-12.
3. *Ad-hoc signing is categorically incompatible.* No — `sync.log` shows 12 runs/hour through all of
   2026-08-11 under this identical ad-hoc scheme. It worked, then stopped.
4. *Needs Login Items approval.* No — `sfltool dumpbtm` says `[enabled, allowed, notified]`, and
   `launchctl print-disabled` says `enabled`.
5. *`unregister()` + `register()` heals a stale LWCR* (what `BackgroundSyncService`'s doc comment claims).
   No — done via the Settings toggle, no spawn followed. **That comment is now known to be at least
   incomplete; it describes a heal that no longer works.**
6. *The BTM record was stale/corrupt.* No. `unregister()` **demotes rather than deletes** — the record
   survived every cycle with a stable UUID (`FD0B5CD7…`), only flipping disposition `0xb ↔ 0xa` and bumping
   its generation. So the label was renamed to force a genuinely fresh record (`23A69ABB…`) — **identical
   failure**. The rename was then reverted; it bought nothing.
7. *The parent app's BTM record being `disabled` blocks the child.* No — `WeatherMenu`,
   `PasswordsMenuBarExtra` and `Podcasts` all run with exactly that parent state.

**What points at the Team-ID gate.** Every other third-party background item in `sfltool dumpbtm` belongs to
a Developer-ID-signed app. Pensieve is the only ad-hoc one, and the only one launchd refuses. The failure is
literally a *launch constraint* on a binary with no Team ID. **Unexplained by this theory:** why it worked
all of 2026-08-11 — best guess is a cached validation that expired, and it is only a guess.

**Impact is smaller than it looks.** The app self-drains whenever it is open (FSEvents spool watch →
`drainThenRefresh`), so capture and extraction keep running. Only the unattended path is lost.

**A fallback exists if it ever becomes urgent** (deliberately NOT built): `sync.log` starts `2026-07-05`,
eleven days of successful runs under the hand-installed `com.pensieve.sync` LaunchAgent before the
2026-07-16 move to `SMAppService`. A plain `~/Library/LaunchAgents` plist running `~/.local/bin/pensieve
sync` is not a bundled helper and carries no launch constraint; `DaemonInstaller` is still in the tree.
That architecture demonstrably worked on this machine.

**Litter this investigation left:** two orphaned BTM records (`me.mazetti.pensieve.sync` from before, and
`me.mazetti.pensieve.backgroundsync` from the rename experiment), both inert and `disabled`. macOS prunes
them when the app is removed; `sfltool resetbtm` would clear them but is system-wide and not worth it.

*Revisit trigger:* ~~the paid Apple Developer membership lands~~ — **fired 2026-08-21, and this entry does NOT
close.** The app was team-signed (`TH593VRB6W`) and installed to `/Applications`, and the agent **still did not
spawn**: `launchctl print gui/$UID/me.mazetti.pensieve.sync` reports `job state = uninitialized`, `last exit code
= (never exited)`, `active count = 0`, and `~/Library/Logs/Pensieve/sync.log` stops at **2026-08-17T23:36Z**.
Note the log gap **predates the re-sign by four days**, so the Team ID neither caused nor fixed this — it is a
separate outage that happens to have been masked by this trigger. Next suspect, untested: switching the helper's
identity from ad-hoc to team-signed can make macOS treat it as a **new** login item, so check System Settings ▸
General ▸ Login Items & Extensions before anything else. Capture is unaffected (git hooks do not need the
agent) — only the 300 s auto-drain is.

**Investigated 2026-08-21 (later same day). Not fixed. Root cause narrowed to a Launch Constraint Violation;
four hypotheses eliminated.** The failure is precise and reproducible: `launchctl kickstart` spawns the helper,
which is `SIGKILL`ed in ~57 ms with `EXC_CRASH / SIGKILL (Code Signature Invalid)` and
`termination {namespace: CODESIGNING, code: 4, indicator: "Launch Constraint Violation"}`. launchd logs
`error info: c[5]p[1]m[1]e[0], (Constraint not matched) launch type 0, failure proc [vc: 3]`.

**Why the log simply stopped instead of filling with errors** — the thing that made this look like "the agent
never ran": launchd logs `removing service since it exited with consistent failure` and **deletes the job**.
Once removed it never retries, so `StartInterval 300` produces nothing and `runs = 0` /
`job state = uninitialized` is what a fresh `launchctl print` shows. An empty log here means *removed*, not
*idle*. Re-registration (relaunching the app) brings the job back, and it fails again on first spawn.

**Eliminated, with evidence — do not re-test these:**
1. *Login-item approval.* `sfltool dumpbtm` shows `Disposition: [enabled, allowed, not notified]` and
   `launchctl print-disabled` shows `enabled`. This was the entry's own "next suspect"; it is wrong.
2. *Stale LWCR.* `properties` does show `needs LWCR update` after a failure (launchd logs
   `Requesting LWCR update on next spawn`), but a full `launchctl bootout` + app relaunch produces a job with a
   **fresh** LWCR and no `needs LWCR update` — and the very next spawn still dies the same way. So
   `registerIfNeeded()`'s unregister-then-register is working as documented; a stale LWCR is not the cause.
3. *Duplicate LaunchServices registrations.* `lsregister -dump` listed **five** bundles claiming
   `me.mazetti.pensieve` (`/Applications` plus four build products across DerivedData and three worktrees) —
   exactly the hazard `CLAUDE.md` warns about, and a plausible way for smd to resolve
   `parent bundle identifier` to the wrong app. Unregistered all four, leaving only `/Applications`;
   re-registered; still fails. Worth keeping clean regardless.
4. *Helper signing-identifier mismatch.* The helper's code-signing identifier is `PensieveSyncAgent` (a `tool`
   target has no Info.plist, so codesign falls back to the file name) while the launchd `Label` is
   `me.mazetti.pensieve.sync`, and `PRODUCT_BUNDLE_IDENTIFIER: me.mazetti.pensieve.sync` in `project.yml` does
   **not** change it. Re-signed the installed helper in place with `-i me.mazetti.pensieve.sync` (deep verify
   OK); still fails. The mismatch is real and arguably worth fixing on its own, but it is not this bug.

**Leading untested hypothesis.** The app's App Group entitlement is unbacked by a provisioning profile, and
`secd`/`trustd` already declare it *"ignored because of invalid application signature or incorrect provisioning
profile"* (see the Widgets entry). If the OS treats the parent app's signature as invalid for entitlement
purposes, an LWCR requiring a validly-signed `me.mazetti.pensieve` parent could fail for that reason. **The
decisive experiment** is to build and install with `CODE_SIGN_ENTITLEMENTS` removed and re-test the spawn — one
variable, one build. Note this cannot be the *original* cause: `sync.log` stops 2026-08-17T23:36Z, days before
either the team-signing or the entitlement change, and the machine has not rebooted since 2026-08-13 and had no
OS update (macOS 26.6.1 installed 2026-08-02). So expect **two** causes — whatever stopped it on 08-17, plus
whatever real team signing now introduces by creating an enforceable LWCR where ad-hoc signing created none.

**Unrelated defect found in passing, worth its own entry:** the 88 undrained spool rows are not merely waiting
on the agent — they fail on ingest with `IngestError.unattributableSession`
(`me.mazetti.pensieve:ingest` logs `Spool row NNNNN failed: …unattributableSession` in bulk). They would keep
failing with the agent healthy, so auto-drain being dead is not the whole story behind the arrears.

</details>

**Superseded by the resolution above (2026-08-13).** The Team-ID revisit trigger no longer applies to this
item — the agent spawns ad-hoc-signed. Hypotheses 1–4, 6 and 7 stand as refuted; 5 is itself refuted by the
fix. The litter noted above (two orphaned BTM records) is unchanged and still inert.

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

