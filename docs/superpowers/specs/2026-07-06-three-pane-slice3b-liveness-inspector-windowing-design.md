# Pensieve.app — three-pane slice 3b: liveness · inspector · recall windows (Design)

**Date:** 2026-07-06
**Status:** Brainstormed & approved (Moritz), awaiting spec review → plan.
**Parent design:** `2026-07-05-pensieve-app-three-pane-design.md` (slice 3 = "inspector + polish").
**Predecessor:** slice 3a (LLM "Last Work Done" narration) — shipped, `docs/superpowers/{specs,plans}/2026-07-06-three-pane-slice3a-last-work-done*`.
**Audience:** Personal single-user tool (Moritz). Not a product.

## Purpose

Slice 3a gave the detail view its LLM recap. Slice 3b is the rest of slice 3 from the
three-pane design: make the app **feel alive** (react to real activity instead of a 3-second
poll), make provenance a **deep-dive** (the ⌘⌥I inspector with surrounding transcript context —
the "why did I flag this" reveal), and let two projects sit **side-by-side** (native recall
windows). Plus a tight materials/semantic-color pass. Four parts, each independently useful; all
read-only over the same tested PensieveKit kernels, the trust gate untouched.

Design values, unchanged from the parent: **native-macOS polish** (platform primitives first —
`ValueObservation`, `.inspector`, `WindowGroup`, FSEvents), **grounded provenance** (the inspector
shows real captured transcript text or an honest "gone" note — never a fabrication), and
**simplicity** (YAGNI — no broader redesign rides along).

## Current state (what this replaces / builds on)

- **Liveness today is a lie.** Despite slice-1's "live `@FetchAll`" claim, `AppModel` runs a **3 s
  `Timer`** calling `refresh()`, which recomputes lists/forest/cards/snapshot every tick whether or
  not anything changed. The canonical store is opened as a GRDB `DatabasePool` (WAL, multi-process)
  — so `ValueObservation` is available.
- **Provenance today is inline-only.** `DetailView` chevron-expands a loose end to show its stored
  `quote` + role + date. There is no surrounding-transcript view. Each `LooseEnd` already carries
  everything the inspector needs: `sourceEventID`, `sourceMessageIndex`, `role`, `quote`. The source
  `cc.session` event's `detailJSON` has `transcriptPath`; `TranscriptParser.parse` returns
  `[TranscriptMessage]` (each with `index`, `role`, `text`).
- **The window is single.** `PensieveApp` is a single `Window("main")` scene owning one shared
  `@StateObject AppModel`. The `pensieve://` + App-Intents deep-link bridge (`AppDelegate` →
  `AppModel.pendingDeepLink` → the always-mounted `MenuBarExtra` label) depends on that single
  shared model. This bridge must not break.

## Part 1 — Liveness (retire the 3 s Timer)

**The hard constraint.** GRDB `ValueObservation` reliably reflects writes made through the app's
**own** database connection, but **not** writes made by another *process*. The launchd
`com.pensieve.sync` daemon is another process. And new git commits / session-ends land in the
**capture spool** first — something must drain spool → canonical for them to surface at all. So
"live" is not "add `ValueObservation`"; it needs a change-detection strategy for external activity.

**Design — three event signals, one debounced `refresh()`:**

1. **`ValueObservation` on the canonical store → `refresh()`.** Covers the app's own drains and
   (future slice-4) in-process organizing writes — instant, typed, no polling. This is the primary
   in-process signal and the platform primitive the parent design names.
2. **FSEvents / `DispatchSource` watch on the spool file → `drain()`.** When a git hook or a
   `SessionEnd` writes the spool, the app drains it **itself** (its own connection, `Ingester.drain()`,
   spool → events only, no LLM) → canonical changes → signal 1 fires → UI updates. This is what makes
   new activity appear live while the window is open.
3. **FSEvents watch on the canonical file → `refresh()`.** Narrowly there to catch the **daemon's
   external canonical writes** — specifically its `ExtractionRunner` loose-end extraction, which the
   app never performs itself, and which `ValueObservation` is blind to (cross-process).

All three funnel into a single **debounced `refresh()`** (~150 ms coalescing window) so the common
case — the app's own drain trips both signal 1 and signal 3 — refreshes exactly once. `refresh()`
stays idempotent and cheap-on-no-change (it already rebuilds the forest only when the node set
actually changed); every FSEvents fire is treated as "something *maybe* changed → drain/refresh,"
so spurious or coalesced fires are harmless.

**`start()` becomes:** open the canonical DB (as today) → initial `drain()` + `refresh()` (as
today) → install the `ValueObservation` + the two file watches → **no timer.** Teardown on the
app model's deinit / scene disappearance cancels the observation and closes the watch sources.

**Live Spotlight re-index, for free.** Slice 3's promised live/background Spotlight re-indexing
folds in here: hang `SpotlightIndexer.reindex()` off the same debounced refresh (it is already a
clear-then-index of active nodes and safe to call repeatedly). It no longer waits for launch/⌘R.

**Watched-file details (for the plan):** watch the DB file **and** its `-wal` sibling (WAL commits
touch `-wal`, and checkpoints touch the main file). Use a `DispatchSource.makeFileSystemObjectSource`
(vnode: `.write | .extend | .rename | .delete`) or `FSEventStreamCreate` on the parent directory;
re-arm on `.rename`/`.delete` (SQLite can recreate files on checkpoint). Coalesce with the shared
debouncer. The exact primitive is an implementation choice; the plan picks one and tests the
debounce/coalesce logic in isolation (the watch wiring itself is app-layer, verified by smoke-run).

**Scope guard.** This part does **not** make the app a general canonical writer. The app draining
its own spool is the already-blessed app-fallback guardrail from slice 1; `Ingester.drain()` remains
the sole canonical **event** writer, and it is idempotent (re-draining spool rows the daemon already
ingested is a no-op). No LLM extraction runs in the app.

## Part 2 — ⌘⌥I provenance inspector

The parent design's "deep dive" reveal: full provenance **plus the surrounding transcript context**,
scrollable — for "why did I flag this." Inline chevron-expand stays as the everyday quick-quote path.

### New tested PensieveKit kernel — `ProvenanceContext`

Read-only. Given a `LooseEnd`, a canonical DB, and a context radius, resolve the surrounding
transcript window:

```
public struct ProvenanceMessage: Sendable {
  public let index: Int
  public let role: String
  public let text: String
  public let isCited: Bool     // the message the loose end was extracted from
}

public struct ProvenanceContext: Sendable {
  public let looseEnd: LooseEnd
  public let sourceEvent: Event
  public let messages: [ProvenanceMessage]   // the window around the cited index; empty if transcript gone
  public let transcriptAvailable: Bool        // false → UI shows the stored quote + an honest "gone" note
}

public enum ProvenanceQueries {
  /// radius = messages of context on each side of the cited message (default 4).
  public static func context(_ db: any DatabaseReader, looseEnd: LooseEnd, radius: Int = 4) throws -> ProvenanceContext
}
```

**Resolution:** load the source `Event` (`looseEnd.sourceEventID`) → decode `detailJSON` for
`transcriptPath` → `TranscriptParser.parse(fileURL:)` → take `messages[max(0, i-radius) ... min(n-1,
i+radius)]` where `i = looseEnd.sourceMessageIndex`, flagging `i` as cited.

**Degrades honestly — the trust gate at work:**
- Transcript file missing / unreadable → `transcriptAvailable = false`, `messages = []`. UI shows the
  stored verbatim `quote` + "source transcript no longer on disk."
- `sourceMessageIndex` out of bounds (transcript compacted/rewritten) → same honest fallback.
- **Defensive quote check:** if `messages[i].text` no longer contains `looseEnd.quote`, the index is
  stale — fall back to the honest "gone/changed" state rather than highlight the wrong message. (In
  the normal case transcripts are append-only, so earlier indices stay valid — noted, not relied on.)

Never fabricates; never shows anything but real captured text or an honest note. Unit-tested against
a synthetic transcript fixture: happy path, missing file, out-of-bounds index, quote-mismatch.

### UI

- **`.inspector` modifier** on the detail column, toggled by a **⌘⌥I** menu command under "Go ▸
  Inspector" (a `showInspector` bool on `AppModel`, exactly like `showPalette` — so the menu command
  can toggle it, consistent with slice-2/GUI-base-state patterns).
- **Selection:** tapping a loose-end row (the existing inline chevron still expands the quick quote)
  also sets `AppModel.inspectedLooseEndID`. The inspector renders that loose end's
  `ProvenanceContext`: the source event header, the surrounding messages scrollable, the **cited**
  message highlighted with the same orange rule used inline. Empty state ("Select a loose end to see
  its source") when nothing is selected; honest "gone" state when `transcriptAvailable == false`.
- `inspectedLooseEndID` clears on node change. Loading `ProvenanceContext` happens off the main actor
  in a `.task(id:)` (like slice-3a's narration), rendered when ready — the parse is file I/O.
- **Main-window feature.** The inspector attaches to the main three-pane's detail column. The
  secondary recall window (Part 3) reuses `DetailView`'s inline provenance but does **not** carry its
  own inspector — avoids per-window inspector state and keeps the recall window lean.

## Part 3 — Secondary recall `WindowGroup` (⌘⌥N + native tabbing)

Deliver the parent design's "open project in new window … so two projects can sit side by side for
cross-referencing recall" and "native window tabbing" — **without disturbing** the single-`Window`
deep-link/intent bridge.

- Main three-pane **stays** `Window("main")`. The `AppDelegate` → `pendingDeepLink` → `MenuBarExtra`
  bridge and the App-Intents `perform()` path are **untouched**.
- Add **`WindowGroup(id: "recall", for: UUID.self)`** presenting a focused **recall view for one
  node** — reuses `DetailView` in lightweight chrome (title + the recall sections). The shared
  `@StateObject AppModel` is injected into both scenes via `.environmentObject`, so the recall window
  reads the same store, the same narration cache (a project narrated in the main window is instant
  here), and the same queries.
- **⌘⌥N** — "File ▸ Open in New Window," enabled when a node is selected — calls
  `openWindow(id: "recall", value: node.id)`. SwiftUI gives these windows **native tabbing** and
  **value-based state restoration** for free; each window carries its own node `UUID`, i.e.
  **independent per-window selection**. This is the platform-primitive path (no AppKit window
  management, no per-window model split).
- **Cold-restore wiring:** a recall window can be restored before the main window mounts, so its root
  also calls `model.start()` (idempotent — guarded in `AppModel`) to guarantee the store is open and
  `allNodes` resolvable for `model.node(id)`. If a restored `UUID` no longer resolves (node deleted),
  the recall window shows a `ContentUnavailableView`.

## Part 4 — Light materials / semantic-color polish (tight, YAGNI)

Not a redesign — just make state legible and native, in both appearances.

- A small shared **state-style helper** mapping a node's state (active / dormant / blocked /
  orphaned) → a **semantic `Color`** + **SF Symbol** that hold in **both** light and dark. Applied
  consistently in the sidebar smart-list rows and the detail header. (App-layer, since `Color` is
  SwiftUI; kept as one small file so there is a single source of truth.)
- Lean on native translucency: `NavigationSplitView`'s sidebar material and `.inspector`'s own
  material — **no** hand-rolled `.background(.regularMaterial)` stacks.
- Verify full light/dark across sidebar, detail, inspector, recall window.

Nothing beyond this — no icon rework, no custom window chrome, no animation pass.

## Data & write path (unchanged principles)

- **Reads only**, over the same PensieveKit kernels. New kernel this slice: `ProvenanceContext`
  (read-only). Liveness reads via `ValueObservation` + re-`refresh()`.
- **The app self-drains its own spool** (Part 1 signal 2) — the slice-1 app-fallback guardrail, now
  event-driven instead of timer-driven. `Ingester.drain()` remains the **sole canonical event
  writer**; idempotent; no LLM in-app.
- **Trust gate untouched.** The inspector shows real captured transcript text or an honest "gone"
  note. Loose ends stay cited. Narration (slice 3a) stays best-effort/outside the gate — not touched
  here.

## Build sequence (one plan, four ordered tasks)

Each task independently verifiable; ordered so later tasks build on earlier ones.

1. **`ProvenanceContext` kernel + tests** — pure PensieveKit, no app changes. *Verify:* unit tests
   pass (happy path, missing file, OOB index, quote mismatch).
2. **Liveness** — replace the 3 s Timer with `ValueObservation` + the two FSEvents watches + the
   debouncer; fold Spotlight re-index into the debounced refresh. *Verify:* debounce/coalesce logic
   unit-tested; smoke-run the built app against a throwaway store, write to the spool out-of-band, and
   confirm the UI updates without ⌘R; confirm no 3 s churn when idle.
3. **⌘⌥I inspector** — `.inspector` UI + ⌘⌥I command + `inspectedLooseEndID` selection, rendering
   `ProvenanceContext`. *Verify:* smoke-run — select a loose end, ⌘⌥I shows surrounding transcript
   with the cited message highlighted; a loose end whose transcript is absent shows the honest note.
4. **Recall `WindowGroup`** (⌘⌥N + tabbing) **+ Part 4 polish.** *Verify:* smoke-run — ⌘⌥N on a
   selection opens a recall window on that node; open a second, they tab; each keeps its own node;
   light/dark legible.

## Out of scope (this slice)

Converting the main window to a `WindowGroup` / splitting `AppModel` into shared-store + per-window
nav (rejected in brainstorming — higher risk to the shipped deep-link bridge); an inspector in the
recall window; broader visual redesign / custom materials / animation; in-app organizing writes
(slice 4); talk-to-system (slice 5); forks (slice 6, backend-gated). None foreclosed.

## Risks / open concerns

- **FSEvents on SQLite `-wal` is fiddly** (WAL checkpoints, coalescing, file re-creation on
  checkpoint). Mitigated by: watch DB **and** `-wal`, re-arm on rename/delete, debounce, and treat
  every fire as "maybe-changed → idempotent drain/refresh." The plan isolates and tests the debounce
  logic; the watch wiring is verified by the out-of-band smoke test in task 2.
- **`ValueObservation` cannot see the external daemon** — the entire reason Part 1 adds the canonical
  file watch. If FSEvents proved unreliable in practice, the fallback is a slow (20–30 s) drain+reread
  timer (the brainstorm's option B) — a one-line change, not a redesign.
- **Stale `sourceMessageIndex`** if a transcript is compacted/rewritten — handled by the defensive
  quote check in `ProvenanceContext` (honest fallback, never a wrong highlight).
- **Recall window before store open** (cold restore) — handled by calling idempotent `model.start()`
  from the recall root and `ContentUnavailableView` on an unresolvable UUID.
