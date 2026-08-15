# Menu-bar popover — drill-in navigation and keyboard access

**Date:** 2026-08-15
**Status:** design approved in chat; awaiting spec review
**Track:** C / findability & OS-integration — the menu-bar surface (`specs/2026-07-06-menu-bar-deeplinks-design.md`)
**Origin:** items 4 and 8 of a batch of eight reported popover defects (2026-08-15). Items 1, 2, 3,
5 and 6 shipped as a chrome pass; item 7 (a ~3 s app freeze) was a separate root-cause fix. This
document covers only the two that are a *feature*, and they are one feature: a second level needs a
focus model, and a focus model needs to know what the levels are.

**Code references are to the working tree at `60ae8e8` plus the uncommitted popover-polish pass**
(footer re-layout, status tint, `isRefreshing`), not to `HEAD` alone.

## Purpose

The popover's rows carry a `chevron.right` (`MenuBarView.swift:176`) and it lies: the chevron
promises somewhere to go, and clicking the row leaves the popover entirely for the main window.
Give the chevron the meaning it already claims — a second level *inside* the popover — and, while
the interaction model is being defined anyway, make the whole surface reachable from the keyboard,
which today it is not at all.

## What already exists

- `MenuBarView` (`MenuBarView.swift:36`) renders a heartbeat header, `maxRows = 5` What's Next rows
  (`:40`, `:76`), and a footer. Rows are `Button`s in a `VStack`; the row action calls
  `applyDeepLink(.node(id))` (`:82`).
- `applyDeepLink` (`DeepLinkNavigation.swift:33`) opens the main window, activates, and applies a
  `PaletteDestination`. It is the single navigation entry point for internal clicks and external
  `pensieve://` opens alike.
- `DeepLink.looseEnd(UUID)` (`DeepLink.swift:22`) and `AppModel.openLooseEnd` already ship, from the
  Spotlight loose-end indexing work. **Level 2 reuses this route rather than adding one.**
- `LooseEndQueries.open(nodeID:)` (`LooseEndQueries.swift:12`) returns *every* open end for a node.
- `LooseEndQueries.openAcrossNodes` (`:37`) documents the ordering the feeds settled on:
  suggested-salient first, then oldest source — chosen on measured grounds, because oldest-first on
  this corpus is "grind through three repos".

## Evidence gathered before designing

### The popover panel can take keyboard focus

The design hinged on whether `MenuBarExtra(.window)` can be focused at all, or whether keyboard
access would force `.menuBarExtraStyle(.menu)` and the loss of the custom layout. Measured with a
throwaway probe that dumped `NSApplication.shared.windows` from the popover's `.task`, driven by
`osascript` clicking the status item:

```
window=MenuBarExtraWindow<AnyView>  canBecomeKey=true  isKey=true
                                    canBecomeMain=false  level=101  styleMask=32896
keyWindow=MenuBarExtraWindow<AnyView>
```

`styleMask 32896` = `.nonactivatingPanel | .fullSizeContentView`. The panel never steals app
activation **and is nonetheless key window**, so key events reach it and `@FocusState`,
`.focusable()`, `.onKeyPress` and `.defaultAction` are all available.

**Nothing is keyboard-reachable today for a mundane reason: the popover declares no focus targets,
no arrow handling and no default action.** The panel was never the obstacle.

### Most active nodes have no loose ends, and that shapes level 2

```
active nodes:                    288
nodes with ≥1 open loose end:     34
```

`SmartLists.whatsNext` (`SmartLists.swift:22`) filters on `isActionable`
(`NextQueries.swift:46` — `openLooseEnds > 0 || closedLooseEnds == 0`), which
deliberately keeps git-only nodes in the queue (123 of 162 active nodes were git-only when that rule
was written, and can never produce a loose end). The ranking does sort loose-end-bearing nodes
first — `pensieve next` puts the first zero at **rank 17**, and the popover shows only the top 5 —
so an empty level 2 is rare *today*.

It stops being rare exactly as the queue is burned down, which is what the loose-end resolution
feature shipped for two days ago. **Level 2 therefore has a designed non-empty fallback, not an
empty state.**

### The per-loose-end query cost is real but was not the freeze

Measured against a copy of the live store (the same probe that refuted the freeze hypothesis):

| call | time | n |
|---|---|---|
| `ProjectQueries.status(limit: 15)` | 1.5 ms | 15 |
| `LooseEndQueries.open` | **61.3 ms** | 288 |
| `LooseEndQueries.closed` | 0.3 ms | 0 |
| `RecallMarkdown.render` | 1.2 ms | 16 823 chars |

61 ms is not a 3 s freeze (that was a non-lazy `VStack`, fixed separately) but it *is* too much for
a glance surface that wants five rows.

## Design

### Shape

Two levels in the existing fixed 320 pt popover, rendered at the **same height** so the surface does
not resize under the pointer.

**Level 1** — unchanged content: heartbeat header, up to 5 What's Next rows, footer. Activating a
row pushes to level 2 instead of leaving for the main window.

**Level 2** — a `‹` back affordance and the node name; a `NodeRowMeta` line (recency · open count);
up to 5 open loose ends rendered as their stored `text`, truncated; the same footer, whose primary
button now opens *that node* rather than the briefing.

**When the node has no open loose ends, level 2 shows its last ~5 events instead.** Same
mark-the-exception spirit as `NodeMetaLine`: render what the node actually has, rather than an empty
slot announcing a failure.

**Reopening the popover always returns to level 1.** It is a glance surface; a remembered drill-in
would be a small surprise on every open. Drill state is therefore `@State` local to the popover
view, never on `AppModel`.

### Keyboard

Primary navigation is **arrow keys, and deliberately not Tab.** macOS Full Keyboard Access is off by
default, so Tab does not reach buttons for most users, while arrow keys inside a `List` work
regardless. This is also the honest resolution of the "Full Keyboard Access tab order is erratic"
item already filed in `backlog.md`: the fix is not to repair a tab order nobody can reach, it is to
put navigation somewhere that always works.

| key | level 1 | level 2 |
|---|---|---|
| `↑` / `↓` | move row selection | move loose-end selection |
| `→` or `↩` | drill into the selected node | open the selected loose end in the app |
| `←` | — | back to level 1 |
| `Esc` | close the popover | close the popover |

Focus lands on the list when the popover opens, so the surface is usable without the mouse.

`↩` on a loose end routes through the shipped `DeepLink.looseEnd` → `AppModel.openLooseEnd` path.
No new navigation path is introduced by this spec.

### Kit (tested)

Two changes, both in `LooseEndQueries.swift`.

**1. Batch `attachEvents` (`:133`).** It currently issues one `Event` point query *per loose end*,
which is where the 61 ms above goes. It becomes a single `Event.where { $0.id.in(ids) }` plus a
dictionary lookup — the `.in(Array(…))` pattern `openCountAcrossNodes` (`:56`) already uses. The
function's contract is unchanged, including its rule that an end whose source event has vanished is
dropped. All four feeds share it, so all four get the improvement, including the detail gather.

**2. `LooseEndQueries.openTop(nodeID:limit:now:)`.** A capped node-scoped feed reusing
`openAcrossNodes`'s salient-first-then-oldest ordering, so level 2 cannot disagree with the feeds
about which loose end matters most. Not a new ordering — the existing comparator, extracted.

### App (thin)

- `MenuBarView.swift` splits: level 1 stays, level 2 becomes `MenuBarNodeView`.
- One new `AppModel.popoverLooseEnds(nodeID:)` over the capped query.
- New String Catalog keys are **chrome only**. Node names, loose-end text and event summaries are
  content and stay verbatim, per the localization rule.

### Trust gate

**Untouched.** Level 2 renders stored `LooseEnd.text` and stored `Event.summary`. No LLM call, no
narration, read-only throughout. Nothing here can reach `TranscriptVocabulary.injectionMarkers` or
`isUserPrompt`.

## What this is deliberately NOT

- **Not a second detail pane.** Level 2 is five lines and a button. Loose-end provenance expansion,
  resolve verbs, translation and find all stay in the main window.
- **Not `.menuBarExtraStyle(.menu)`.** The spike showed `.window` can take focus, so there is no
  reason to trade the custom layout away.
- **Not a third level.** Loose end → app, not loose end → transcript-in-popover.
- **Not a change to `applyDeepLink` or the `pensieve://` contract.** External opens behave exactly
  as they do today.

## Risks, with fallbacks pre-specified

| risk | fallback |
|---|---|
| `List` chrome sits badly on the popover's glass material | `@FocusState` over the existing button `VStack`, keeping the same arrow handling. Costs the free selection highlight, not the keyboard model. |
| `.defaultFocus` does not take on first open in a nonactivating panel | Set focus explicitly from the popover's `.task`. |
| `Esc` closing the popover is **unverified** — the panel may consume it before SwiftUI sees it | If it cannot be observed, `←` remains the back affordance and `Esc` keeps whatever the system does. Not worth fighting the panel for. |
| A fixed list height clips at large Dynamic Type | Level content scrolls within the fixed height rather than growing the popover. |

## Testing

- **Kit:** batched `attachEvents` gets a test pinning that it returns the same views in the same
  order as the per-row version, including the drop-on-missing-event rule; `openTop` gets ordering
  and cap tests. Both are mutation-verified — delete the batching, or the cap, and the test must
  fail. (The loose-end resolution work found *two* vacuous tests by running the mutation rather than
  by reasoning; that is now the local standard.)
- **App:** no unit tests exist for the app target. Verified by build, smoke, and an eyeball matrix.

## Human-verify carries

Need the installed app and a real store; none of these can be checked by a green build.

1. Arrow keys move selection at both levels with a visible focus ring, mouse untouched.
2. `→` / `↩` drills, `←` returns, and the popover height does not change between levels.
3. `↩` on a loose end opens the main window with that loose end expanded.
4. What `Esc` actually does.
5. A node with **zero** open loose ends shows the activity fallback, not an empty pane.
6. German in situ — level 2's header and back affordance, and that node names and loose-end text are
   **not** translated.

## Deferred, not foreclosed

- **Type-select** in level 1 (typing jumps to a project). Cheap once a `List` selection exists, but
  five rows do not need it.
- **Resolve verbs in the popover** (`⌘↩` to close a loose end from level 2). The keyboard model
  would support it; whether triage belongs on a glance surface is a separate question.
- **Remembering the last drill-in** across opens, if the always-level-1 rule turns out to annoy in
  daily use. Trigger: noticing it, not arguing about it.
