# Pensieve.app — three-pane slice 3b: liveness · inspector · recall windows (Design)

**Date:** 2026-07-06
**Status:** Brainstormed & approved (Moritz), awaiting spec review → plan.
**Parent design:** `2026-07-05-pensieve-app-three-pane-design.md` (slice 3 = "inspector + polish").
**Predecessor:** slice 3a (LLM "Last Work Done" narration) — shipped, `docs/superpowers/{specs,plans}/2026-07-06-three-pane-slice3a-last-work-done*`.
**Audience:** Personal single-user tool (Moritz). Not a product.
**Adversarial spec review (2026-07-06):** two independent Opus reviewers (feasibility + grounding/scope)
checked this spec against the real code; verdict "sound enough to plan from, fix-first lightly." Their
findings are folded in below (spool `-wal` watch, app-lifetime watch teardown, `isUserPrompt`-hardened
provenance resolution, the shared-`inspectedLooseEndID` cross-window fix, task reorder with liveness
last, semantic-color scope). ValueObservation is **kept** by explicit decision (Moritz) though the
review found it redundant with the canonical file-watch — the two watches are the coverage backbone.

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
2. **FSEvents watch on the spool → `drain()`.** When a git hook or a `SessionEnd` writes the spool,
   the app drains it **itself** (its own connection, `Ingester.drain()`, spool → events only, no LLM)
   → canonical changes → signal 1 fires → UI updates. This is what makes new activity appear live
   while the window is open. **The spool is WAL** (`CaptureSpool.swift` `PRAGMA journal_mode = WAL`),
   so appends land in `capture.sqlite-wal`, *not* the main file, until a checkpoint — the watch MUST
   cover `capture.sqlite-wal` too. Use an `FSEventStream` on the spool's **parent directory** (path-
   based) rather than a per-file vnode `DispatchSource`: robust to SQLite recreating `-wal`/`-shm` on
   checkpoint, and covers both files in one source. *(Review F1/F6.)*
3. **FSEvents watch on the canonical store's directory → `refresh()`.** Catches the **daemon's
   external canonical writes** — specifically its `ExtractionRunner` loose-end extraction, which the
   app never performs itself and which `ValueObservation` is blind to (cross-process). (This watch
   also fires on the app's *own* writes — the OS reports own-process changes — which is precisely why
   the review judged `ValueObservation` redundant; kept per decision, treated as non-load-bearing.)
   Same directory-based `FSEventStream` covering `pensieve.sqlite` + `-wal`.

All three funnel into a single **debounced `refresh()`** (~150 ms coalescing window) so the common
case — the app's own drain trips both signal 1 and signal 3 — refreshes exactly once. `refresh()`
stays idempotent and cheap-on-no-change (it already rebuilds the forest only when the node set
actually changed); every FSEvents fire is treated as "something *maybe* changed → drain/refresh,"
so spurious or coalesced fires are harmless.

**`start()` becomes:** open the canonical DB (as today) → initial `drain()` + `refresh()` (as
today) → install the `ValueObservation` + the two directory watches → **no timer.** **Watch lifetime
is app-lifetime, tied to `AppModel`** (an App-owned `@StateObject` that effectively never deinits) —
**not** scene/window disappearance. This is a windowless-capable menu-bar app: if the watches died
when the main `Window` closed, the always-mounted menu-bar glyph would go stale. *(Review F3.)*

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

**Concurrent-writer hardening (small PensieveKit change).** Event-driven self-drain makes the app
drain far more often, so it races the launchd daemon's drains more than the old timer did. This is
safe — `Ingester.drain()` tolerates `SQLITE_BUSY` (per-row `continue`, retries next fire; fingerprint
dedup + `markIngested` keep it idempotent) — but the canonical store today opens with a bare
`Configuration()` (no busy timeout), unlike the spool which sets `.timeout(5)`. Add a busy
`.timeout` to `CanonicalStore.openCanonicalDatabase`'s `Configuration` so writer-vs-writer contention
waits briefly instead of throwing immediately. *(Review F4 + grounding-#8.)*

**Menu-bar popover unaffected.** Removing the timer does **not** break the popover: `MenuBarView`
refreshes on popover-open via its own `.task { model.refreshGlance() }`, and the always-mounted label
glyph reads `@Published snapshot`, which the file-watch-driven `refresh()` still updates on real
activity (strictly better than a 3 s poll). *(Review F5 — verify the label stays live in the
windowless smoke test.)*

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
`transcriptPath` → `TranscriptParser.parse(fileURL:)` → find the cited message by **identity, not bare
position**: `let cited = messages.first { $0.index == looseEnd.sourceMessageIndex }`. (Verified
alignment: `TranscriptParser` assigns `index` sequentially so `index == array position` *within one
parser version*; resolving by `index` and validating below is robust to that assumption drifting.)
Take the `radius`-wide window around the cited message's position, flagging it as cited.

**Degrades honestly — the trust gate at work:**
- Transcript file missing / unreadable → `transcriptAvailable = false`, `messages = []`. UI shows the
  stored verbatim `quote` + "source transcript no longer on disk."
- No message with `index == sourceMessageIndex` (transcript compacted/rewritten) → same honest fallback.
- **Two-part defensive check so the "never a wrong highlight" promise actually holds** *(review
  grounding-#4 + F7)*: the cited message must (a) contain `looseEnd.quote` **and** (b) have
  `isUserPrompt == true`. Every verified loose end came from a user prompt (`LooseEndVerifier` stamps
  `sourceMessageIndex = m.index` off a user message), so requiring `isUserPrompt` excludes a
  same-phrase false-match against a `tool_result`/injected echo (those live in `messages` too, flagged
  `isUserPrompt == false`). Fail either → honest "gone/changed" fallback, never a wrong highlight. (In
  the normal case transcripts are append-only, so earlier indices stay valid — noted, not relied on.)

**Surrounding context is raw captured text, not machine-filtered** *(review grounding-#5)*: the radius
window can include `tool_result` / `<system-reminder>` / injected-command bodies (`TranscriptParser`
keeps any non-empty text, flagging non-prose `isUserPrompt == false`). For a single-user tool over the
user's own transcripts this is acceptable and **not** a grounding violation (it is context, not an
AI-derived claim; loose ends stay cited). The inspector **dims/labels** non-user (`isUserPrompt ==
false`) messages so the cited user prompt reads as the source and envelopes read as context.

Never fabricates; never shows anything but real captured text or an honest note. Unit-tested against
a synthetic transcript fixture: happy path, missing file, out-of-bounds index, quote-mismatch.

### UI

- **`.inspector(isPresented:)` modifier** on the detail column, toggled by a **⌘⌥I** menu command
  under "Go ▸ Inspector" (a `showInspector` bool on `AppModel`, so the menu command can toggle it —
  consistent with the `showPalette` pattern).
- **Selection — gated per window** *(review grounding-#1)*: `DetailView` takes an `allowsInspector:
  Bool` init param. Tapping a loose-end row (the existing inline chevron still expands the quick quote)
  sets `AppModel.inspectedLooseEndID` **only when `allowsInspector == true`**. The main three-pane
  passes `true`; the recall window (Part 3) passes `false`, so a tap there never writes shared inspector
  state. This is the fix for the otherwise-real cross-window bug: `inspectedLooseEndID` lives on the
  shared `AppModel` but has two potential writers (both `DetailView` instances) and one presenter (the
  main window) — the gate makes the recall window a non-writer. (The `showPalette` analogy is imperfect
  precisely because `showPalette` has a single writer; hence the explicit gate here.)
- The inspector renders the inspected loose end's `ProvenanceContext`: source event header, surrounding
  messages scrollable, the **cited** message highlighted with the same orange rule used inline,
  non-user messages dimmed. Empty state ("Select a loose end to see its source") when nothing selected;
  honest "gone" state when `transcriptAvailable == false`. `AppModel` gains a `provenance(for:)`
  accessor mirroring the existing `narration(for:)`; loading happens off the main actor in a
  `.task(id:)` (like slice-3a's narration), rendered when ready — the parse is file I/O.
- **`inspectedLooseEndID` clears at the `AppModel` level when `selectedNodeID` changes** — NOT inside
  a per-instance `DetailView.task` *(review grounding-#2)*. A recall window only carries its own node
  UUID and never touches `selectedNodeID`, so it can't wrongly clear the main window's inspector
  selection; and this avoids the `.task(id:)` (which also keys on `refreshToken`) clearing on a ⌘R.
- **Main-window feature.** The inspector attaches to the main three-pane's detail column only. The
  recall window reuses `DetailView`'s inline provenance but carries no inspector.

## Part 3 — Secondary recall `WindowGroup` (⌘⌥N + native tabbing)

Deliver the parent design's "open project in new window … so two projects can sit side by side for
cross-referencing recall" and "native window tabbing" — **without disturbing** the single-`Window`
deep-link/intent bridge.

- Main three-pane **stays** `Window("main")`. The `AppDelegate` → `pendingDeepLink` → `MenuBarExtra`
  bridge and the App-Intents `perform()` path are **untouched**.
- Add **`WindowGroup(id: "recall", for: UUID.self)`** presenting a focused **recall view for one
  node** — reuses `DetailView` (with `allowsInspector: false`) in lightweight chrome (title + the recall
  sections). The shared App-owned `AppModel` is **passed into** the recall root (the same way `RootView`
  / `DetailView` already take `model` as an explicit param — they are not `@EnvironmentObject`
  consumers), so the recall window reads the same store, the same narration cache (a project narrated in
  the main window is instant here), and the same queries. *(Review F12 wording.)*
- **⌘⌥N** — "File ▸ Open in New Window," enabled when a node is selected — calls
  `openWindow(id: "recall", value: node.id)`. Each window carries its own node `UUID`, i.e.
  **independent per-window selection**, with value-based state restoration for free. This is the
  platform-primitive path (no AppKit window management, no per-window model split). **Native window
  tabbing is available but system-preference-dependent** (macOS "Prefer tabs when opening documents"
  defaults to "In Full Screen Only") — same-`WindowGroup` recall windows *can* tab; the reliably-true
  behavior we verify is "⌘⌥N opens a second recall window on the selected node." *(Review F11 — don't
  over-promise auto-tabbing.)*
- **Cold-restore wiring:** a recall window can be restored before the main window mounts, so its root
  also calls `model.start()` (idempotent — guarded in `AppModel`). `model.node(id)` reads the private
  `allNodes`, which is populated only after the async initial `drainThenRefresh()` completes, so a
  restored window may briefly resolve `nil`. The recall view must **observe a `@Published` property**
  (it already does via `@ObservedObject model` → `forest`/`allNodes` refresh) so it **re-evaluates
  `node(id)` when the store loads** — the first `nil` is transient, not permanent. Show
  `ContentUnavailableView` while unresolved; a genuinely deleted node stays unavailable. *(Review F12.)*

## Part 4 — Light materials / semantic-color polish (tight, YAGNI)

Not a redesign — just make state legible and native, in both appearances.

- A small shared **state-style helper** mapping a node's state → a **system semantic color role** (not
  hand-tuned per-appearance hex — the system roles auto-adapt to light/dark and avoid the "verify hex
  in both modes" rabbit hole) + **SF Symbol**. Applied consistently in the sidebar smart-list rows and
  the detail header. **Scope the helper to states the app actually surfaces today** — the smart-list
  buckets `whatsNext` / `dormant` / `recentlyActive`; do **not** build styling for `blocked` /
  `orphaned`, which are gated/unbuilt per the parent design (mild YAGNI otherwise). *(Review
  grounding-#6.)* App-layer (since `Color` is SwiftUI); one small file, single source of truth.
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

Each task independently verifiable and independently useful. **Liveness is ordered last** *(review
grounding-#3)*: it is the one genuinely uncertain part (FSEvents-on-WAL, cross-process), is really
slice-1 debt folded in here, and is the most isolatable/degradable — so it must not block the two
low-risk deliverables (inspector, recall windows). Ordering: kernel → inspector → recall+polish →
liveness.

1. **`ProvenanceContext` kernel + tests** — pure PensieveKit, no app changes. Takes `any
   DatabaseReader`. *Verify:* unit tests pass (happy path; missing file; no-match index; quote
   mismatch; `isUserPrompt == false` same-phrase false-match rejected).
2. **⌘⌥I inspector** — `.inspector(isPresented:)` UI + ⌘⌥I command + the `allowsInspector`-gated
   `inspectedLooseEndID` selection + `AppModel.provenance(for:)` + clear-on-`selectedNodeID`-change,
   rendering `ProvenanceContext` (cited highlighted, non-user dimmed). *Verify:* smoke-run — select a
   loose end, ⌘⌥I shows surrounding transcript with the cited message highlighted; a loose end whose
   transcript is absent shows the honest note.
3. **Recall `WindowGroup`** (⌘⌥N) **+ Part 4 polish.** *Verify:* smoke-run — ⌘⌥N on a selection opens
   a recall window on that node; a loose-end tap there does NOT change the main window's inspector;
   open a second recall window, each keeps its own node; light/dark legible.
4. **Liveness** — add `ValueObservation` + the two directory FSEvents watches (spool incl. `-wal`;
   canonical incl. `-wal`) + the ~150 ms debouncer, app-lifetime; add the canonical busy `.timeout`;
   fold Spotlight re-index into the debounced refresh; **remove the 3 s Timer.** *Verify:*
   debounce/coalesce logic unit-tested; smoke-run the built app against a throwaway store, write to the
   spool out-of-band, confirm the UI updates without ⌘R and the menu-bar label stays live; confirm no
   3 s churn when idle.

## Out of scope (this slice)

Converting the main window to a `WindowGroup` / splitting `AppModel` into shared-store + per-window
nav (rejected in brainstorming — higher risk to the shipped deep-link bridge); an inspector in the
recall window; broader visual redesign / custom materials / animation; in-app organizing writes
(slice 4); talk-to-system (slice 5); forks (slice 6, backend-gated). **Also deferred from the parent
slice-3 list** *(review grounding-#7)*: a native toolbar with a search field, view toggles, and
"＋ new strand," plus arrow-key list navigation — search overlaps the ⌘K palette, "＋ new strand" is
slice-4 organizing-writes, and arrow-key nav is a later polish pass. None foreclosed.

## Risks / open concerns

- **FSEvents on SQLite `-wal` is fiddly** (WAL checkpoints, coalescing, file re-creation on
  checkpoint). Mitigated by: **directory-based `FSEventStream`** covering the DB **and** `-wal` (path-
  based, so it survives SQLite recreating `-wal`/`-shm` — more robust than per-file vnode sources),
  debounce, and treating every fire as "maybe-changed → idempotent drain/refresh." The plan isolates
  and tests the debounce logic; the watch wiring is verified by the out-of-band smoke test in task 4.
  If FSEvents proved unreliable in practice, the fallback is a slow (20–30 s) drain+reread timer (the
  brainstorm's option B) — a one-line change, not a redesign.
- **`ValueObservation` cannot see the external daemon** — confirmed correct by review; it is kept by
  decision but is non-load-bearing (the canonical directory watch is what catches external writes).
- **Concurrent-writer contention** now that the app self-drains far more often — `Ingester.drain()`
  is idempotent and `SQLITE_BUSY`-tolerant; the added canonical busy `.timeout` reduces the noise.
- **Stale `sourceMessageIndex`** if a transcript is compacted/rewritten — handled by the two-part
  (`quote`-contains **and** `isUserPrompt`) defensive check in `ProvenanceContext` (honest fallback,
  never a wrong highlight).
- **Recall window before store open** (cold restore) — handled by idempotent `model.start()` from the
  recall root and the recall view re-evaluating `node(id)` on the next `@Published` refresh (first
  `nil` is transient); `ContentUnavailableView` while unresolved.
