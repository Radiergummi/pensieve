# Focus filters (`SetFocusFilterIntent`) — Work / Personal context — design

**Date:** 2026-07-07
**Status:** approved (brainstorm complete), pre-plan
**Pillar:** OS-integration surface (App-Intents family), from `docs/superpowers/backlog.md` §B —
⭐ **user-flagged HIGH VALUE**. Builds directly on the **live App-Intents foundation**
(`{specs,plans}/2026-07-06-app-intents-foundation*`); deferred out of that skeleton because it needs
its own *filtering model* + *app-state plumbing* (this spec).

## Goal

When a macOS **Focus** is active (e.g. "Personal" in free time, "Work" during the day), Pensieve
restricts what it surfaces to the matching slice of your work — so the app reflects the same
context switch the OS already knows about. Concretely: a **Personal** Focus surfaces your free-time
side projects and mutes work; a **Work** Focus does the reverse. This directly serves the parallel
work/personal-project workflow the whole tool exists for.

The mechanism is Apple's `SetFocusFilterIntent`: you attach the Pensieve filter to a Focus in
**System Settings → Focus → (a Focus) → Add Filter → Pensieve**, choose a context, and the app
reacts when that Focus turns on/off.

## Decisions locked during brainstorming

1. **Filtering model = a `context` attribute on nodes, referenced by the Focus filter** (not a
   per-Focus node picker). You classify a project once in the app; each Focus maps to a context, so
   new projects flow into the right Focus automatically — no per-Focus node list to maintain.
2. **Context shape = fixed enum: `work` | `personal` | *unset*.** Matches the stated need exactly;
   gives a plain picker in the app and a static `AppEnum` filter parameter (no dynamic-options
   plumbing). A third bucket later is a small code change. (`unset` is the empty string `""`.)
3. **Inheritance = yes, down the subtree.** Context set on a node applies to all descendants; the
   **nearest ancestor with a non-empty context wins**; a child may override. Tag a top-level project
   once and its (incl. auto-birthed) strands are covered.
4. **Filter semantic = "mute the opposite explicit context; `unset` always shows."** Personal Focus
   shows `personal` + `unset`, hides `work` (and vice-versa). Forgiving — uncategorized work never
   silently vanishes; you only mute what you've explicitly classified.
5. **Surfaces filtered = the main window + Spotlight.** Menu-bar popover stays unfiltered in v1
   (near-free later add — same kernel). (User's explicit choice.)
6. **Deactivation handled via an *optional* filter parameter** — see Architecture §4. On Focus
   deactivation the system re-runs `perform()` with the parameter **nil**; that is the revert signal.

## Non-goals (deferred → backlog ledger)

- **Menu-bar popover filtering.** Trivial follow-up (reads the same filtered kernel); left out per
  the surface choice.
- **A bulk / right-click "Set Context" action.** The New/Edit modal picker suffices for v1. *(If
  classifying many existing nodes feels tedious in dogfooding, add a context-menu action then.)*
- **More than two contexts** (clients, learning, …). YAGNI; the fixed enum is a small change to grow.
- **Notification muting** ("mute personal nudges"). Moot until notifications exist; noted for when
  that surface lands.
- **CloudKit / App Group / a second process.** Everything here runs **in the app process**;
  filter state is plain `UserDefaults` (like `lastOpenedAt`). No shared container.
- **App Intents / Shortcuts phrases for context** and the CLI. Chrome-and-Focus only.

## Architecture

Standing rule holds: **all derivation lives in tested PensieveKit; the app target stays thin.** The
filter is *one tested predicate* applied at each read boundary — no query is re-derived or
re-ranked, so the grounded/north-star discipline is untouched.

### 1. Model + migration (PensieveKit, tested)

- **Migration v9 (additive, STRICT-safe), mirroring v8:**
  ```swift
  migrator.registerMigration("v9-node-context") { db in
    try #sql(#"ALTER TABLE "nodes" ADD COLUMN "context" TEXT NOT NULL DEFAULT ''"#).execute(db)
  }
  ```
- **`Node.context: String`** added to the `@Table` model (default `""`), placed alongside
  `icon`/`colorTag`. Column name matches the property exactly (STRICT table rule).
- **`NodeContext` string constants** (mirrors `NodeKind`): `work = "work"`, `personal = "personal"`,
  `unset = ""`; plus `all: [String]` of the user-selectable values for the picker.

### 2. Resolution + predicate (PensieveKit, pure, tested)

A small `NodeContextResolver` (new file `Sources/PensieveKit/Query/NodeContext.swift`), operating on
an in-memory `[Node]` (the app already holds `allNodes`; no DB round-trip):

- `resolve(_ nodeID: UUID, in nodes: [Node]) -> String` — walk `parentID`→root, return the first
  non-empty `context`; none ⇒ `""` (unset). Cycle-safe (bounded by a visited set, consistent with
  the tree's walk-to-root guard).
- `visibleNodeIDs(for active: String, in nodes: [Node]) -> Set<UUID>` — the filter predicate. For
  `active == ""` (no Focus / unfiltered) return **all** ids. Otherwise a node is visible iff its
  resolved context is `active` **or** `unset`; i.e. hide only nodes resolving to the *opposite*
  explicit context. (Generalizes correctly if a third context is ever added: "show active + unset,
  hide every other explicit context.")

**Tests:** inheritance (set on ancestor → descendant inherits; child override wins; multiple levels;
unset everywhere → unset); predicate (mute-opposite, always-show-unset, unfiltered passthrough,
subtree hidden with its parent); migration v9 additive (existing rows default to `""`).

### 3. Applying the filter (app target, thin)

`AppModel` gains an active-context property and applies `visibleNodeIDs` at each already-existing read
boundary in `refresh()` (and `refreshGlance()`), post-computation:

- **Smart lists:** filter each `NextItem` list to items whose `nodeID` ∈ visible set.
- **Briefing cards:** filter to visible set.
- **Node tree:** build `NodeForest` from the visible `allNodes` subset (a hidden work project takes
  its whole subtree with it — consistent with inheritance; the forest builder already drops nodes
  whose parent is absent).
- **Spotlight:** `SpotlightIndexer.reindex()` becomes filter-aware — it clears and re-indexes only
  the **visible** active nodes, and is re-run when the active context changes. *(Accepted
  trade-offs, per surface choice: a reindex per Focus switch; while in Personal you won't find a
  Work node by name in Spotlight.)*

`allNodes` itself stays the full set (organizing writes, `node(_:)` lookups, pickers must see
everything); only the *derived, surfaced* collections are filtered.

### 4. The Focus-filter intent + app-state plumbing (app target)

New `Sources/PensieveApp/AppIntents/PensieveFocusFilter.swift`:

- **`FocusContextOption: AppEnum`** — `work` / `personal`, `caseDisplayRepresentations` "Work" /
  "Personal", mapping to `NodeContext` constants (exhaustive switch → no drift, mirrors
  `PensieveListOption`).
- **`PensieveFocusFilter: SetFocusFilterIntent`** with an **optional** parameter:
  ```swift
  @Parameter(title: "Context") var context: FocusContextOption?
  ```
  - `displayRepresentation` (instance) describes the configured filter ("Show Work" / "Show
    Personal") for the System Settings row.
  - `perform()` (main actor) persists the active context to `UserDefaults` and returns `.result()`.
    **On activation** the system sets `context`; **on deactivation** the system re-runs `perform()`
    with `context == nil` — persist `""` (unfiltered). *(The optional parameter is load-bearing: a
    non-optional parameter is only delivered on activation, so the app can never learn it was turned
    off. Verified against Apple's `SetFocusFilterIntent` behavior.)*
- **State + observation:** a `UserDefaults` key `pensieve.activeFocusContext` (String). `AppModel`
  reads it on launch and observes `UserDefaults.didChangeNotification` (like the existing
  `lastOpenedAt` pattern) → on change: recompute the filtered collections + trigger a Spotlight
  reindex. When the app isn't running, the system still runs the intent in the background, so the
  persisted value stays current for the next launch. *(Edge case — focus changes while the app is
  fully quit and the intent doesn't run — is acceptable for a single-user tool; the value refreshes
  on the next `perform()` or launch read.)*

`SetFocusFilterIntent` does **not** go in `AppShortcutsProvider` — it surfaces automatically in the
System Settings → Focus filter list.

### 5. Setting a node's context (app UI)

- Extend **`NodeCommands.add`** and **`NodeCommands.update`** with a `context: String = ""` parameter
  (persisted on the `Node`), alongside `icon`/`colorTag`. Tested in Kit.
- Add a **Context picker (Work / Personal / Unset)** to the **New/Edit modal** (`NodeEditor`, just
  rebalanced in the chrome batch — the natural home), on the left form zone under Type. Writes go
  through `AppModel.commitNewNode` / `updateNode` (extend those thin wrappers with `context`).
- The picker shows the node's **own** context (not the resolved/inherited one) so "Unset (inherit)"
  is an explicit, honest choice; the modal may show the *resolved* context as secondary help text.

### 6. Localization

New chrome strings (en + de, by hand — xcodebuild won't auto-populate): "Context", "Work",
"Personal", "Unset" (de: "Kontext", "Arbeit", "Persönlich", "Nicht festgelegt"), plus the filter
title/parameter ("Show Work"/"Show Personal" → "Arbeit anzeigen"/"Persönliches anzeigen"). Context
**values stored on nodes are constants, not localized** (they're queryable data, like `kind`); only
the chrome labels are localized. Impersonal/infinitive German.

## Testing & verification

- **Kit (real tests):** resolution + predicate (§2) and migration v9. `NodeCommands.add/update`
  round-trip `context`.
- **App target (no unit tests):** `xcodebuild` **BUILD SUCCEEDED** + non-blocking smoke-launch of the
  inner binary with throwaway `PENSIEVE_DB`/`PENSIEVE_CAPTURE_DB`.
- **Human-verify carries** (need the built app + real store + System Settings; can't be asserted
  headlessly):
  1. Add the Pensieve filter to a "Personal" Focus in System Settings, set it to Personal; activate
     the Focus → main window smart lists / briefing / tree show only personal + unset nodes; Work
     nodes are hidden. Deactivate → everything returns.
  2. A "Work" Focus set to Work mutes personal nodes; unset nodes stay visible in both.
  3. Spotlight (while a Focus is active) surfaces only the visible subset; switching Focus re-indexes.
  4. The New/Edit modal Context picker sets a node's context; a child with unset context inherits its
     parent's; `pensieve list` unaffected (context isn't shown by the CLI in v1).
  5. German renders in situ (`-AppleLanguages '(de)'`).

## Risks / open items

- **Deactivation delivery** relies on the optional-parameter behavior (verified via Apple docs +
  developer-forum guidance). Confirm on-device during human-verify; if the OS ever fails to re-run
  `perform()` on deactivate, the fallback is a launch/foreground re-read of current focus state.
- **Spotlight reindex churn** on every Focus switch — acceptable at single-user node counts
  (clear-then-index is already the launch/⌘R behavior); revisit only if it feels slow.
- **`context` on `NodeCommands.add`** inserts a positional parameter into an existing signature —
  keep it defaulted (`= ""`) and last, so existing callers (CLI `add-node`, tests) are unaffected.

## Out of scope (own specs / later)
- Menu-bar filtering; bulk set-context; >2 contexts; notification muting; CLI `--context`; App
  Intents phrase for setting context. All noted above; none foreclosed.
