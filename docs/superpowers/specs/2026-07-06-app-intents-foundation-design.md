# App Intents foundation (+ Spotlight via `IndexedEntity`) — design

**Date:** 2026-07-06
**Status:** approved (brainstorm complete), pre-plan
**Pillar:** OS-integration surface #2, from the "Platform extension points" menu in
`docs/superpowers/backlog.md`. Chosen over standalone Core Spotlight because App Intents is Apple's
convergent foundation: one entity/intent model lights up Spotlight (content **and** actions), Siri,
and Shortcuts — and Core Spotlight becomes an implementation detail *underneath* `IndexedEntity`
rather than a parallel integration we'd later rework.

## Goal

Build the **App Intents foundation** for `Pensieve.app` and, on top of it, the first content-search
surface — **Spotlight**. Off one `NodeEntity` + a tiny intent set:

- **Spotlight content** — your nodes appear as Spotlight search hits; tapping one opens its recall
  view in the app.
- **Siri + Shortcuts + Spotlight *actions*** — an **Open Node** action and a parameterized **Show
  Pensieve List** action (What's Next / Dormant / Recently Active).

Every surface reads the **already-tested grounded kernel** (`Node` / `NextQueries` / `SmartLists`)
and routes navigation through the **live `pensieve://` deep-link path**. Nothing is re-derived or
fabricated — the north-star discipline holds by construction.

This is the second OS-integration surface (after the v0.2 menu-bar item + `pensieve://`). It is the
foundation every later App-Intents-based surface (Focus filters, Widgets) builds on.

## Non-goals (deferred → backlog ledger)

- **Focus filters** (`SetFocusFilterIntent`). Flagged **high value** by the user (free-time
  side-project workflow), but a distinct feature: it needs a filtering *model* + app-state plumbing.
  Its own spec. Roadmap entry added.
- **`LooseEndEntity`** / indexing loose-end text. Nodes only for now. Loose-end full-text (and the
  semantic/vector-search investigation) is a roadmap entry, not skeleton work.
- **Widgets, CloudKit, App Groups / a shared container.** Everything here runs in the **app process**,
  so no second process and no shared container yet. The first surface that needs a *second* process
  builds the App Group.
- **Live `ValueObservation`-driven re-indexing.** Deferred to three-pane slice 3 (liveness). This
  spec re-indexes on launch + refresh.
- **Semantic / vector search.** Roadmap entry (evaluate `sqlite-vec`, on-device embeddings, native
  Spotlight semantic indexing). Out of scope here.

## Decisions locked during brainstorming

1. **Entity granularity:** **Nodes only.** `NodeEntity` is the nameable Spotlight destination and maps
   1:1 to `pensieve://node/<uuid>`; loose-ends deferred.
2. **Surfaces this spec:** Spotlight **content** + Siri/Shortcuts **actions**. Focus filters deferred.
3. **Action set:** implicit **Open Node** (`OpenIntent`) + a **parameterized** `ShowPensieveListIntent`
   over the three smart lists (chosen over a fixed "Show What's Next" so the **Dormant** "you forgot
   this" signal — central to the ADHD-reload purpose — is a first-class action).
4. **Searchable depth:** **name + `Node.description` only** — clean, nameable destinations; keeps
   captured content out of the OS index (conservative against the grounded/trust north star). The
   grounded *subtitle* is still shown. Loose-end full-text is a later increment.
5. My-call details the user approved: **reuse the `pendingDeepLink` bridge** for intent navigation;
   **full re-index each time** (no diffing) with a **graceful stale-tap fallback** to Briefing.

## Step 0 — deployment target

`project.yml`: macOS **14.0 → 15.0** (and the mirrored `LSMinimumSystemVersion`). Rationale: the whole
premise — Spotlight content indexing as a *conformance on the same entity* used for Siri/Shortcuts —
is `IndexedEntity`, which is **macOS 15+** (verified against Apple docs). Pinning at 14 would force a
hand-rolled `CSSearchableItem` schema now and a migration onto `IndexedEntity` later (the exact
duplication this pillar avoids). The machine runs 15.6; for a personal single-user tool the bump is
zero-cost. (`AppEntity`, `AppIntent`, `AppShortcutsProvider`, `OpenIntent` are all ≤ macOS 13, so 15
covers everything.) Regenerate the project (`xcodegen generate`) and rebuild after the bump.

**Only the app target bumps.** `Package.swift` stays `.macOS(.v14)` — `NodeFacts` uses only
Foundation/SQLiteData. **All `IndexedEntity`/App-Intents code lives in the app target**, so the
package's platform floor is untouched (an implementer must not bump it).

## Architecture

### Layering — thin app over a tested kernel (our standing rule)

**PensieveKit (tested) — one new grounded helper.** The searchable set *and* the grounded result
subtitle both need the same per-node facts. Add:

```swift
// Sources/PensieveKit/Query/NodeFacts.swift
public struct NodeFacts: Sendable {
  public let node: Node
  public let openLooseEnds: Int
  public let daysDormant: Int   // days since latest Event; 0 if none
}
public enum NodeFactsQueries {
  /// Active nodes with their grounded facts. Takes a read-only `DatabaseReader`.
  public static func all(_ db: any DatabaseReader, now: Date) throws -> [NodeFacts]
}
```

The dormancy + open-loose-end logic mirrors `NextQueries.ranked` exactly (latest `Event.occurredAt`
→ `Calendar` day delta; `LooseEnd` where `nodeID.eq(id) && status.eq("open")` count). Signature takes
`any DatabaseReader` (not `Writer`) so it composes with the read-only store opener (below); `.read {}`
is available on `DatabaseReader`.

**Indexed population = active only.** `all` fetches `state.eq("active")` — the *same* live set the
app's smart lists surface (`NextQueries` is active-only). This is deliberate: Spotlight surfaces
exactly what the app considers live, and archived nodes stay out of the index (and get *removed* on
the next reindex — see indexing). `"muted"` has no writer in the codebase today, so there is no
findable-but-not-pushed edge to reason about; if muted writers ever land, whether muted nodes stay
searchable is a one-line decision then. (Note the asymmetry from `entities(for:)` below, which fetches
by id *regardless* of state so a tap on an entry indexed while active still opens after archival.)

This **retires one queued slice-2 carry** — the shared per-node "latest event + dormancy +
open-loose-end-count" helper. Scope discipline: this spec **uses** `NodeFacts` in the new path but
does **not** force-refactor `NextQueries` / `MonitorSnapshot` / `BriefingQueries` onto it (surgical;
that adoption is a noted fast-follow). **Known drift risk:** `NodeFacts` and `NextQueries.ranked` now
hold two copies of the dormancy/loose-end math that must stay identical — the `NodeFacts` test
fixtures (below) assert equivalence to pin it. Perf is a non-issue: `NextQueries.ranked` already runs
this same per-node N+1 every 3 s via the app timer, so a per-launch/`refreshNow` reindex is negligible.

**App target (thin) — `Sources/PensieveApp/AppIntents/`.** New files, no logic beyond wiring:

- **`NodeEntity: AppEntity, IndexedEntity`**
  - `id: UUID` (the `Node.id`).
  - `displayRepresentation` → title = `node.name`; subtitle = the grounded
    `"<kind> · N open loose ends · dormant Nd"` (built from `NodeFacts`).
  - `attributeSet: CSSearchableItemAttributeSet` → `title = node.name`,
    `contentDescription = node.description` (the searchable body — decision #4), plus the subtitle
    facts for display. **Only name + description are matched** by Spotlight.
  - `static var defaultQuery = NodeEntityQuery()`.

- **`NodeEntityQuery: EntityQuery, EntityStringQuery`** — opens the store **read-only** via
  `openCanonicalDatabaseReadOnly(at: Stores.canonicalURL)` (returns `DatabaseReader`; no migrator, can't
  create the file; honors `PENSIEVE_DB`; WAL, safe alongside the daemon). If the store doesn't exist
  yet the read-only open throws → every method **degrades to empty** (mirrors `MonitorSnapshot`), never
  crashes the intent:
  - `entities(for ids: [UUID]) -> [NodeEntity]` — fetch by id, **any state** (so a tap on a node
    indexed while active still opens after it's archived). An **unknown id returns `[]`** — see the
    stale-tap handling under indexing.
  - `suggestedEntities() -> [NodeEntity]` — active nodes (small, stable list for the Shortcuts picker).
  - `entities(matching string: String) -> [NodeEntity]` — nodes whose **name** contains `string`
    (case-insensitive). Backed by a PensieveKit fetch; keeps derivation testable.

- **`OpenNodeIntent: OpenIntent`** — `@Parameter var target: NodeEntity`. (No explicit
  `openAppWhenRun`; `OpenIntent` implies opening the app.) `perform()` routes `DeepLink.node(target.id)`
  through the navigation bridge (below). This is what a Spotlight-result tap and a Shortcuts "Open
  Node" step invoke. **The system resolves `target` via `NodeEntityQuery.entities(for:)` *before*
  calling `perform()`** — so a tap on a *deleted* node (id no longer resolves → `[]`) means `perform()`
  never runs; the tap is a silent no-op. This is why we can't "redirect in `perform()`" and instead
  minimize stale entries at index time (below).

- **`ShowPensieveListIntent: AppIntent`** — `@Parameter var list: PensieveListOption`,
  `openAppWhenRun = true`. `perform()` routes `DeepLink.smartList(list.deepLinkKind)`.
  - `PensieveListOption: String, AppEnum` — cases `whatsNext / dormant / recentlyActive`, **raw
    values matching `DeepLink.SmartList`** so the bridge needs no hand-kept string table. A single
    `switch` maps `PensieveListOption ↔ DeepLink.SmartList`, made **exhaustive** so a future list
    fails to compile here (mirrors the existing `PaletteDestination(_ link:)` pattern — no silent
    drift).

- **`PensieveShortcuts: AppShortcutsProvider`** — declares `AppShortcut`s for `ShowPensieveListIntent`
  (spoken phrases, e.g. *"Show my dormant projects in Pensieve"*) and `OpenNodeIntent`. One
  declaration each surfaces the action in **Siri**, the **Shortcuts app**, and as a **Spotlight
  action suggestion**.

### Navigation bridge — reuse the shipped `pendingDeepLink` path (judgment call #1)

An `AppIntent` struct is instantiated by the system and **cannot reach** SwiftUI's `openWindow`
(needed to raise the main window). So `perform()` reuses the **exact path external `pensieve://`
opens already take**:

```
AppIntent.perform()  →  AppDelegate.receive(link)  →  model.pendingDeepLink  (or buffer, if the
app was cold-launched to service the intent and the model isn't wired yet)  →  the always-mounted
MenuBarExtra label's .onChange  →  applyDeepLink  (openWindow + NSApp.activate + navigate)
```

**Refactor:** factor the current body of `AppDelegate.application(_:open:)` into a shared
`@MainActor func receive(_ link: DeepLink)` that both `application(_:open:)` and the intents call.
The existing buffer/flush machinery already handles cold launch (link arrives before the model is
wired → buffered → flushed when `MenuBarLabel.task` sets `appDelegate.model`). Intents reach the
delegate via `NSApp.delegate as? AppDelegate` — **`perform()` must be `@MainActor`** (or hop via
`MainActor.run`) to legally touch `NSApp` and the delegate.

**Verified sound, with real caveats:**
- App-target intents (no separate `AppIntentsExtension`) run **in the app process**, so `NSApp.delegate`
  *is* the `@NSApplicationDelegateAdaptor` instance — the bridge is legitimate (WWDC22 "Dive into App
  Intents"). If we ever add an `AppIntentsExtension`, this breaks (out-of-process, no `NSApp`); we don't.
- **`perform()` is fire-and-forget w.r.t. navigation.** It only sets `pendingDeepLink`; the window
  raise + view selection happen on a *later* main-actor turn when `MenuBarLabel.onChange` observes the
  change. So `perform()` returns "success" before the user visibly lands on the view (benign for a
  navigation intent; we don't attach a result tied to navigation completing).
- **Cold-launch correctness hinges on the app coming to the foreground.** The flush
  (`MenuBarLabel.task`) and the consumer (`MenuBarLabel.onChange`) only run once the `MenuBarExtra`
  label is mounted. `ShowPensieveListIntent` sets `openAppWhenRun = true`, and `OpenIntent` opens the
  app — both force the foreground that mounts the scene and flushes the buffer. This is load-bearing;
  it gets its **own cold-launch human-verification item** (below), separate from the warm case.

**Rejected alternative:** have `perform()` re-open a `pensieve://` URL through `NSWorkspace` — a
Launch-Services round-trip for no benefit. Direct `pendingDeepLink` reuse is tighter and already
proven at runtime (v0.2 C1).

### Spotlight indexing (judgment call #2)

An app-side **`SpotlightIndexer`** builds `[NodeEntity]` from `NodeFactsQueries.all` and donates them
via the `IndexedEntity` API on `CSSearchableIndex.default()` (`indexAppEntities(_:)`, `async throws`;
exact companion delete API pinned in the plan).

- **Trigger:** on launch **after the existing spool drain**, and after `AppModel.refreshNow()`
  (⌘R / sync). Wired from `AppModel.start()` / `refreshNow()`; the indexer itself is a small
  stateless helper. Opens the store via the **read-only** opener (degrades to empty if absent).
- **Reindex = clear-then-index, not upsert-only.** Each run first removes the previously-donated
  Pensieve node items, then indexes the current **active** set. This keeps the index in exact sync with
  the live set — **archived and deleted nodes drop out on the next reindex**, so stale entries don't
  accumulate. Nodes are few, so a full clear-then-index is trivial (YAGNI over diffing). This folds the
  once-deferred stale-cleanup *into* the skeleton because it's what makes the deletion story honest.
- **Residual stale window (honest):** a node deleted *while the app is running* still has a live
  Spotlight entry until the next launch/refresh. Tapping it → `entities(for:)` returns `[]` → the
  system no-ops (`perform()` never runs; see `OpenNodeIntent`). We cannot gracefully redirect that tap
  — it's a silent miss, not a crash. Acceptable for a single-user tool; the clear-then-index above
  keeps the window small.
- Indexing failures are best-effort/logged, never fatal (mirrors the capture-path discipline: a
  glance surface must never break the app).

**Freshness reality (honest):** because indexing only runs while the app is open, the Spotlight index
is **stale whenever the app isn't running** — and the launchd daemon creates strands headlessly. So a
brand-new strand isn't Spotlight-findable until the next app launch/refresh. Acceptable for the
skeleton (the app is opened often in this workflow); live/background re-indexing is a roadmap item.

**macOS Spotlight *content* is best-effort (risk, stated up front).** Third-party `IndexedEntity`
content surfacing in the *macOS* Spotlight UI is historically less reliable than on iOS, and community
reports on the `IndexedEntity` path note two gotchas: (a) an entity is only surfaced if it is **also
referenced as a parameter in an App Shortcut** — our `OpenNodeIntent` inside `PensieveShortcuts`
satisfies this, so **that coupling is load-bearing** (don't drop `OpenNodeIntent` from the provider);
and (b) some reports say **only the title/`displayName` is matched, not `contentDescription`** — which
would blunt decision #4's "`Node.description` is searchable." Stance: the **Siri/Shortcuts actions are
the reliable win**; Spotlight **content** is a best-effort bonus, and "description is searchable" is
treated as **unverified until the human check**. The plan must not hinge success on content matching
`Node.description`.

### No App Group

Intent `perform()`, `EntityQuery` resolution, and indexing all run **in the app process** — macOS
launches `Pensieve.app` to service app-target intents. No shared container is needed. The canonical
store is already a WAL `DatabasePool` (multi-process), so read-only opens are safe alongside the
launchd sync daemon. App Groups arrive with the first *second-process* surface (Widgets/CloudKit).

## Data flow

```
Spotlight search  →  system reads the CSSearchableIndex Pensieve donated  →  tap result
   →  OpenNodeIntent(target:)  →  AppDelegate.receive(.node(id))  →  pendingDeepLink  →  window + recall view

"Hey Siri, show my dormant projects in Pensieve"  →  ShowPensieveListIntent(list: .dormant)
   →  AppDelegate.receive(.smartList(.dormant))  →  pendingDeepLink  →  window + Dormant list

App launch / ⌘R  →  drain spool  →  NodeFactsQueries.all  →  [NodeEntity]  →  indexAppEntities(…)
```

## Testing

- **PensieveKit (unit):** `NodeFactsQueries.all` — grounded counts/dormancy correct across fixtures
  (no events → 0 dormant; open vs. closed loose ends; archived excluded, muted included). The
  `DeepLink` scheme is already tested.
- **App target (no unit tests — standing constraint):** `xcodebuild` build + a **non-blocking**
  smoke-launch of the inner binary (`…/Contents/MacOS/Pensieve`, throwaway
  `PENSIEVE_DB`/`PENSIEVE_CAPTURE_DB`, background + `kill`). Keep views/intents thin; the
  `PensieveListOption ↔ DeepLink.SmartList` mapping is compile-checked (exhaustive `switch`).
- **Human verification items** (listed in the plan, cannot be asserted headlessly):
  1. A node appears as a **Spotlight** hit (search its **name**) → tap → app opens its recall view.
     *(Also try a word only in its `description` — records whether content-body matching works on
     macOS; a **known-risk** item, not a pass/fail gate.)*
  2. **Cold-launch** (app fully **quit**): invoke "Show Pensieve List" from Shortcuts → the app
     foregrounds and lands on the correct list (exercises `openAppWhenRun` + buffer-flush ordering).
  3. **Shortcuts app** shows "Open Node" and "Show Pensieve List" (list picker resolves).
  4. **Siri** phrase for "Show Pensieve List" opens the correct list.
  5. Delete a node, refresh/relaunch → its stale entry is **gone** from Spotlight (clear-then-index
     worked). *(A tap on an entry for a node deleted mid-session no-ops silently — expected, not a
     dead-end to fix.)*

## Roadmap entries to add to `backlog.md`

1. **Focus filters (`SetFocusFilterIntent`) — HIGH VALUE.** A "personal" Focus surfaces free-time
   side-project strands. Needs a filtering model + app-state plumbing; builds directly on this
   foundation. Own spec.
2. **Loose-end full-text + semantic / vector search.** Index remaining thread text; evaluate
   `sqlite-vec`, on-device embeddings (`NLContextualEmbedding` / Foundation Models SDK), and native
   Spotlight semantic indexing on macOS 15+ (recall without exact words). Links to the existing
   `NLEmbedding` theme-discovery spike.
3. **Live / background re-indexing** — `ValueObservation`-driven re-index (folds into slice-3
   liveness) so headlessly-created strands become Spotlight-findable without an app launch. *(Basic
   stale-entry cleanup is already in the skeleton via clear-then-index; this is the freshness upgrade.)*

## Files

**New**
- `Sources/PensieveKit/Query/NodeFacts.swift` — `NodeFacts` + `NodeFactsQueries.all` (tested).
- `Sources/PensieveApp/AppIntents/NodeEntity.swift` — `NodeEntity` (`AppEntity` + `IndexedEntity`).
- `Sources/PensieveApp/AppIntents/NodeEntityQuery.swift` — `EntityQuery` + `EntityStringQuery`.
- `Sources/PensieveApp/AppIntents/PensieveIntents.swift` — `OpenNodeIntent`, `ShowPensieveListIntent`,
  `PensieveListOption`.
- `Sources/PensieveApp/AppIntents/PensieveShortcuts.swift` — `AppShortcutsProvider`.
- `Sources/PensieveApp/AppIntents/SpotlightIndexer.swift` — `indexAppEntities` driver.
- `Tests/PensieveKitTests/NodeFactsTests.swift`.

**Modified**
- `project.yml` — deployment target 14 → 15 (+ `LSMinimumSystemVersion`).
- `Sources/PensieveApp/AppDelegate.swift` — extract shared `receive(_ link:)`.
- `Sources/PensieveApp/AppModel.swift` — call `SpotlightIndexer` after drain / in `refreshNow()`.
- `docs/superpowers/backlog.md` — the three roadmap entries above.
- `CLAUDE.md` / `CONTINUE.md` — status on completion (at merge, not in the plan).
```
