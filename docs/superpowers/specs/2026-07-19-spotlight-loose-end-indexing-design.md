# Spotlight loose-end indexing (Track C 1b) — design

**Date:** 2026-07-19
**Status:** approved (brainstorm complete), ready for plan
**Track:** C (findability / OS-integration), sub-project **1b**
**Builds on:** App Intents foundation + Spotlight (`{specs,plans}/2026-07-06-app-intents-foundation*`),
in-app find 1a (`2026-07-10-in-app-find-design.md`), the `pensieve://` DeepLink router
(`{specs,plans}/2026-07-06-menu-bar-deeplinks*`).

## Context

Pensieve's find surfaces now cover a lot: in-app ⌘F (lexical, 1a) + a "Related" section and MCP
`search` (semantic, #2). The one gap left in the search story is the **OS index**: macOS Spotlight
indexes **nodes only** — `NodeEntity` exposes name + description
(`Sources/PensieveApp/AppIntents/{NodeEntity,SpotlightIndexer}.swift`). A phrase from a loose end's
text or its cited quote is invisible to a system-wide Spotlight search. 1b closes that: index loose
ends into Spotlight so the OS surfaces them, and tapping a hit opens the node with the row expanded.

This is pure **lexical OS-index coverage** — the counterpart to 1a at the OS level. Semantic recall
(#2) already shipped in-app + over MCP; it is out of scope here.

## Goal

A macOS Spotlight search for a phrase from an open loose end's text or cited quote returns that
specific loose end; selecting it opens Pensieve at the loose end's node with the cited row expanded —
honoring the active Focus filter and the grounded-with-provenance north star.

## Non-goals

- Semantic / vector / OS-embedding indexing (that is #2, shipped in-app + MCP).
- Indexing event summaries, transcripts, or narration into Spotlight (only nodes + open loose ends).
- A Siri conversational phrase over loose-end *content* (a minimal intent phrase is required only to
  surface the entity in Spotlight — see Decisions).
- Any new capture, schema, migration, or deployment-target change (target is already macOS 15 for
  `IndexedEntity`, from the App-Intents foundation). This is read-only indexing + navigation.

## Decisions (locked in brainstorm)

- **Granularity: one Spotlight item per open loose end** (a dedicated entity), NOT loose-end text
  folded into the node's searchable body. The payoff of indexing loose-end text is finding the
  *specific* item, so hits are per-loose-end.
- **Tap opens the node with the loose-end row expanded** (reusing the ⌘F "land on the cited row"
  machinery — `expandedLooseEndID`), not just the node.
- **New deep-link form `pensieve://looseend/<uuid>`** — additive to the existing scheme.
- **Corpus discipline matches every other surface:** open loose ends only (`LooseEnd.isOpen`), in
  **active** nodes, **Focus-scoped** to the visible set — identical to how `SpotlightIndexer` already
  scopes nodes.
- **Mirror the proven `NodeEntity` path** (`AppEntity` + `IndexedEntity` + `EntityQuery` +
  `OpenIntent` registered in `AppShortcutsProvider`, routed through the `DeepLink` →
  `AppDelegate.receive` → `pendingDeepLink` bridge). No new navigation mechanism.

## Architecture

Five components (two tested Kit, three thin app), each mirroring an existing counterpart.

### Kit (tested, SwiftUI-free)

1. **`DeepLink.looseEnd(UUID)`** — a new case on the existing `DeepLink` enum
   (`Sources/PensieveKit/Support/DeepLink.swift`). Grammar `pensieve://looseend/<uuid>`; `init?(url:)`
   parses it (segments count 1, valid UUID) and `.url` serializes it, preserving the invariant
   `DeepLink(url: link.url) == link`. Fully unit-tested like the existing cases.

2. **`LooseEndFacts` + `LooseEndFactsQueries`** (new file under `Sources/PensieveKit/Query/`, mirrors
   `NodeFacts`/`NodeFactsQueries`):
   - `struct LooseEndFacts: Sendable { let looseEndID: UUID; let nodeID: UUID; let nodeName: String; let text: String; let quote: String }`
   - `static func all(_ db: any DatabaseReader) throws -> [LooseEndFacts]` — every open loose end
     (`LooseEnd.isOpen`) whose node is `state == "active"`, joined to its node name. (Focus scoping is
     applied by the app-side indexer against the returned set, exactly as `SpotlightIndexer` already
     does for nodes — the Kit query stays Focus-agnostic.)
   - `static func facts(for ids: [UUID], _ db: any DatabaseReader) throws -> [LooseEndFacts]` — by-id
     resolution for a Spotlight tap. Degrade-safe: a loose end that still exists resolves (so a tap
     opens its node); an unknown id is dropped.
   Read-only; opens nothing itself (takes an injected reader).

### App (thin — no unit tests; verified by build + smoke-launch)

3. **`LooseEndEntity: AppEntity, IndexedEntity`** + **`LooseEndEntityQuery: EntityQuery,
   EntityStringQuery`** (mirror `NodeEntity`/`NodeEntityQuery`):
   - Fields: `id` (loose-end UUID), `text`, `nodeName`, `quote`.
   - `attributeSet`: `title` / `displayName` = `text`; `contentDescription` = `text` + the cited
     `quote` (the searchable body — this is what makes a quote phrase findable).
   - `displayRepresentation`: title = `text`, subtitle = `nodeName`.
   - `LooseEndEntityQuery`: `entities(for:)` via `LooseEndFactsQueries.facts(for:)`;
     `suggestedEntities()` + `entities(matching:)` via `.all` (filter `text`/`quote` substring in
     Swift — loose ends are few/single-user, no fragile `LIKE`), opening the canonical store
     **read-only**, degrading to empty if absent (an intent surface never creates/migrates the store).

4. **`OpenLooseEndIntent: OpenIntent`** (`@Parameter target: LooseEndEntity`) → `perform()` calls
   `PensieveIntentBridge.route(.looseEnd(target.id))`. **Registered in `PensieveShortcuts`**
   (`AppShortcutsProvider`) with a minimal phrase (`"Open a loose end in \(.applicationName)"`,
   mirroring "Open a node") — load-bearing: an `IndexedEntity` is only Spotlight-surfaced when
   referenced as an App Shortcut.

5. **`SpotlightIndexer.reindex`** — the existing clear-then-index pass gains a second entity set: gather
   `LooseEndFactsQueries.all`, filter to the Focus-visible active nodes (`NodeContextResolver
   .visibleNodeIDs`, reusing the same `visible` set already computed for nodes), map to
   `LooseEndEntity`, and `indexAppEntities` them alongside the node entities in the same pass
   (`deleteAllSearchableItems()` still clears exactly Pensieve's set — now nodes + loose ends).

6. **Navigation** — `applyDeepLink` (`Sources/PensieveApp/DeepLinkNavigation.swift`) handles
   `.looseEnd(id)` via a new **`AppModel.openLooseEnd(_ id: UUID)`**: resolve the loose end → its node
   (read-only DB lookup), front the main window, set `sidebarSelection`/`selectedNodeID` to the node
   and `expandedLooseEndID` to the loose end (the same state ⌘F's `selectSearchLooseEnd` sets). If the
   loose end no longer resolves, degrade — open the node if known, else briefing; never crash. The
   `DeepLink → PaletteDestination` exhaustive-switch no-drift guard is preserved (the loose-end case is
   handled in `applyDeepLink` before/instead of the nav-only `PaletteDestination` mapping; adding the
   enum case forces a compile error anywhere the switch isn't updated).

## Grounding (north star intact)

Only real, cited content is indexed: a loose end's `text` and verbatim `quote`, both already stored
and provenance-bearing. Open + active + Focus-scoped, identical to every other surface. A Spotlight
tap resolves through the tested by-id query and lands on the real row; a stale entry (loose end since
closed, noise-labeled, re-homed, or its node archived) **degrades honestly** rather than surfacing
wrong/dead content. Indexing is best-effort and read-only — a failure is silently dropped and can
never break the app or the capture/ingest path. No LLM, no fabrication.

## Testing

- **Kit unit tests:**
  - `DeepLink` looseEnd round-trip (`init?(url:)`/`.url`, `==` invariant) + a malformed-URL rejection.
  - `LooseEndFactsQueries.all` — returns open loose ends in active nodes; **excludes** closed
    (`status != "open"`), noise-labeled (`label == "noise"`), and loose ends whose node is archived;
    carries the correct node name. `facts(for:)` — resolves known ids, drops unknown.
- **App target** (no unit tests, per convention): `xcodebuild -scheme Pensieve build` +
  non-blocking smoke-launch of the inner binary with throwaway `PENSIEVE_DB`/`PENSIEVE_CAPTURE_DB`.
- **Human-verify** (needs the built app + real store + a normal `open`; can't be asserted headlessly):
  Spotlight-search a phrase from a loose end's text → the loose end appears → selecting it opens
  Pensieve at its node with the row expanded; a phrase only in the cited **quote** also finds it; a
  Work/Personal Focus hides the muted context's loose ends; a since-closed loose end's stale Spotlight
  entry degrades (opens the node or briefing, no crash); German entity type name in situ
  (`-AppleLanguages '(de)'`).

## Open items for the plan

- The exact `applyDeepLink`/`PaletteDestination` switch restructure that keeps the no-drift guard while
  routing `.looseEnd` through `AppModel.openLooseEnd` (the loose-end case can't produce a nav-only
  `PaletteDestination`).
- Whether `LooseEndEntity.attributeSet.contentType` should be `.content` (as `NodeEntity` uses) or a
  more specific UTType — default to matching `NodeEntity` unless a reason emerges.
- German string(s): the `LooseEndEntity` `typeDisplayRepresentation` name; confirm whether the intent
  phrase/shortTitle are localized (match how `OpenNodeIntent` is handled today).
