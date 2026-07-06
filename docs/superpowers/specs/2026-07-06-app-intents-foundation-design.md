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
is `IndexedEntity`, which is **macOS 15+**. Pinning at 14 would force a hand-rolled `CSSearchableItem`
schema now and a migration onto `IndexedEntity` later (the exact duplication this pillar avoids). The
machine runs 15.6; for a personal single-user tool the bump is zero-cost. (`AppEntity`, `AppIntent`,
`AppShortcutsProvider`, `OpenIntent` are all ≤ macOS 13, so 15 covers everything.) Regenerate the
project (`xcodegen generate`) and rebuild after the bump.

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
  /// All non-archived nodes with their grounded facts. Read-only.
  public static func all(_ db: any DatabaseWriter, now: Date) throws -> [NodeFacts]
}
```

The dormancy + open-loose-end logic mirrors `NextQueries.ranked` exactly (latest `Event.occurredAt`
→ `Calendar` day delta; `LooseEnd` where `nodeID.eq(id) && status.eq("open")` count). This **retires
one queued slice-2 carry** — the shared per-node "latest event + dormancy + open-loose-end-count"
helper. Scope discipline: this spec **uses** `NodeFacts` in the new indexing/query path but does
**not** force-refactor `NextQueries` / `MonitorSnapshot` / `BriefingQueries` onto it (surgical; that
adoption is a trivial noted cleanup for later). `all` returns nodes where `state != "archived"`
(i.e. `"active"` and `"muted"`) so muted-but-live areas remain findable; archived nodes are excluded.

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
  `openCanonicalDatabase(at: Stores.canonicalURL)` (honors `PENSIEVE_DB`; WAL/multi-process, safe
  alongside the daemon):
  - `entities(for ids: [UUID]) -> [NodeEntity]` — fetch by id.
  - `suggestedEntities() -> [NodeEntity]` — active nodes (small, stable list for the Shortcuts picker).
  - `entities(matching string: String) -> [NodeEntity]` — nodes whose **name** contains `string`
    (case-insensitive). Backed by a PensieveKit fetch; keeps derivation testable.

- **`OpenNodeIntent: OpenIntent`** — `@Parameter var target: NodeEntity`. `openAppWhenRun = true`.
  `perform()` routes `DeepLink.node(target.id)` through the navigation bridge (below). This is what a
  Spotlight-result tap and a Shortcuts "Open Node" step invoke.

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
wired → buffered → flushed on `model` set). Intents reach the delegate via
`NSApp.delegate as? AppDelegate` on the main actor.

**Rejected alternative:** have `perform()` re-open a `pensieve://` URL through `NSWorkspace` — a
Launch-Services round-trip for no benefit. Direct `pendingDeepLink` reuse is tighter and already
proven at runtime (v0.2 C1).

### Spotlight indexing (judgment call #2)

An app-side **`SpotlightIndexer`** builds `[NodeEntity]` from `NodeFactsQueries.all` and calls
`CSSearchableIndex.default().indexAppEntities(_)` (the `IndexedEntity` donation API).

- **Trigger:** on launch **after the existing spool drain**, and after `AppModel.refreshNow()`
  (⌘R / sync). Wired from `AppModel.start()` / `refreshNow()`; the indexer itself is a small
  stateless helper.
- **Full re-index each time** (upsert by `id`). Nodes are few and stable — no diffing, no
  incremental bookkeeping (YAGNI).
- **Deletion caveat:** a deleted node leaves a **stale** Spotlight entry until the next reindex.
  Tapping a stale entry resolves to "node not found" → **`OpenNodeIntent` falls back to
  `DeepLink.briefing`** rather than dead-ending. Full stale-cleanup (`deleteAppEntities` on vanished
  ids) is a **noted later refinement**, not skeleton work.
- Indexing failures are best-effort/logged, never fatal (mirrors the capture-path discipline: a
  glance surface must never break the app).

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
  1. A node appears as a **Spotlight** hit (search its name) → tap → app opens its recall view.
  2. **Shortcuts app** shows "Open Node" and "Show Pensieve List" (list picker resolves).
  3. **Siri** phrase for "Show Pensieve List" opens the correct list.
  4. Deleting a node then searching its stale entry → tap → **falls back to Briefing** (no dead-end).

## Roadmap entries to add to `backlog.md`

1. **Focus filters (`SetFocusFilterIntent`) — HIGH VALUE.** A "personal" Focus surfaces free-time
   side-project strands. Needs a filtering model + app-state plumbing; builds directly on this
   foundation. Own spec.
2. **Loose-end full-text + semantic / vector search.** Index remaining thread text; evaluate
   `sqlite-vec`, on-device embeddings (`NLContextualEmbedding` / Foundation Models SDK), and native
   Spotlight semantic indexing on macOS 15+ (recall without exact words). Links to the existing
   `NLEmbedding` theme-discovery spike.
3. **(minor) Spotlight stale-entry cleanup** — `deleteAppEntities` for nodes removed since last
   index; and live `ValueObservation`-driven re-indexing (folds into slice-3 liveness).

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
