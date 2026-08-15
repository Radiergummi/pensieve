# Menu-bar popover — keyboard access, and why the drill-in level was dropped

**Date:** 2026-08-15
**Status:** **revised after two independent adversarial reviews.** The drill-in second level this
document originally specified is **dropped**; what remains is keyboard access to the single-level
popover, plus two changes that were split out of it.
**Track:** C / findability & OS-integration — the menu-bar surface (`specs/2026-07-06-menu-bar-deeplinks-design.md`)
**Origin:** items 4 and 8 of a batch of eight reported popover defects (2026-08-15). Items 1, 2, 3, 5
and 6 shipped as a chrome pass (`5c6fa13`); item 7, a ~3 s app freeze, was a separate root-cause fix
(`ac212d0`).

**Store measurements are dated 2026-08-15 and the store is live** — it grew from 981 to 986 open
loose ends during the review itself. Re-measure before relying on any absolute number here.

## What the reviews changed

The first draft specified a second level inside the popover: drill into a What's Next row, see that
node's top 5 open loose ends. Two independent adversarial reviews — one on factual correctness, one
on design soundness — killed it, on three grounds that survived verification:

**1. Its ordering premise was dead.** The new `openTop` query was justified as reusing
`openAcrossNodes`'s salient-first-then-oldest comparator "so level 2 cannot disagree with the feeds".
That comparator ranks on `LooseEnd.labelSuggestion` (`LooseEndQueries.swift:41-42`). Measured:

```
labelSuggestion:  '' → 986 rows   (every row in the store)
label (human):    '' → 864,  noise → 98,  salient → 24
```

**Nothing has ever written `labelSuggestion`.** The 122 real salience labels live in `label`, the
human column, which the comparator does not read. So `openTop` would have produced pure oldest-first
— the ordering `openAcrossNodes`'s own doc comment rejects on measured grounds — and the moment
`labelSuggestion` *is* populated it would have started disagreeing with the detail pane, which sorts
oldest-first via `open(nodeID:)` (`LooseEndQueries.swift:21`). The query was justified by a guarantee
it inverted.

**2. Its content was a weaker copy of a surface that shipped two days earlier.** `whatsNext` ranks on
`groundedScore = openLooseEnds * 2 + daysDormant` (`NextQueries.swift:53`), so the five rows the
popover shows are structurally the highest-loose-end nodes. Level 2 would have shown **5 of 299** for
the top row, in a 320 pt panel, with no resolve verbs, no undo and no provenance — against the
**Loose Ends** sidebar bucket (2026-08-13), which handles the same queue cross-node with ⌘⏎ triage
and undo. And the spec's own answer for nodes with no open ends was a recent-activity fallback,
i.e. **the feature's content was designed to decay into a copy of the detail pane's timeline exactly
as the burn-down succeeds.**

**3. It had no lifecycle.** `refreshGlance()` (`AppModel.swift:341-346`) writes only `snapshot` and
`lists` — not `allNodes`, not `nodeRowFacts`. `loadNodeRowFacts` carries an explicit warning
(`:331-334`): *"Anything added to the popover that reaches for `nodeRowFacts` will read a map the
glance path never refreshes."* Level 2's meta line did exactly that. Nor did the spec say what
happens when the drilled node is archived, merged away or Focus-filtered out mid-drill.

**Also dropped as unfounded:** the "same height at both levels" constraint. Its stated purpose was
that the surface must not resize under the pointer, but a `MenuBarExtra` popover is anchored at the
status item, so height changes extend the *bottom* edge, away from where the user just clicked.
macOS's own menu-bar surfaces resize freely.

**Two reviewer claims were checked and rejected:** that the 61.3 ms timing was a cross-node
measurement (it was per-node — 288 active nodes and 288 rows returned for one node is a coincidence
collision), and that the store has 286 active nodes (it has 288; 289 total, 1 archived).

### What replaced level 2

Item 8's complaint was that `chevron.right` promises a level below, inside the surface, while the row
leaves for the main window. With the level dropped, the honest fix is to stop making the promise:
the glyph becomes **`arrow.up.forward`**, the macOS idiom for leaving the surface. One line, no new
surface, and the one-click path into the app is preserved — which matters, because a drill-in level
would have doubled the cost of the most common action for the 254-of-288 nodes with no loose ends.

## The measurements this design rests on

### The popover can take keyboard focus — and this was measured twice

Spike 1 dumped `NSApplication.shared.windows` from the popover's `.task`:

```
window=MenuBarExtraWindow<AnyView>  canBecomeKey=true  isKey=true
                                    canBecomeMain=false  level=101  styleMask=32896
```

`styleMask 32896` = `.nonactivatingPanel | .fullSizeContentView` (verified against the SDK headers:
`1<<7` + `1<<15`); `level 101` = `NSPopUpMenuWindowLevel`.

A review correctly objected that **key window ≠ SwiftUI focus engaged**, that the probe never pressed
a key, and that macOS suppresses focus rings in an inactive app — which a nonactivating panel might
well be. That was the one premise in the document with no fallback, so spike 2 measured it:

```
SPIKE2 popover appeared …                      appActive=true
SPIKE2 after requesting focus, probeFocus=true appActive=true
SPIKE2 onKeyPress fired key=""                 appActive=true    ← ↓ / ↑
SPIKE2 onKeyPress fired key="\t"               appActive=true    ← Tab
```

All three doubts resolve in favour of building it: **`.onKeyPress` fires** inside the nonactivating
panel, **`NSApp.isActive` is true** so focus rings are not suppressed (confirmed visually — a ring
rendered), and **SwiftUI accepts a programmatic focus request**.

**A conclusion drawn here was wrong, and the build caught it.** Spike 2 logged `key=""` for arrows
and this spec read that as "arrows arrive, they just carry no character — so match on
`.onKeyPress(.upArrow)`". They do **not** arrive: the probe's handler sat on a `.focusable()`
container that had focus itself, whereas the shipped rows hold focus and arrow keys are consumed as
*move commands* before `onKeyPress` sees them. The correct binding is `.onMoveCommand`; `.onKeyPress`
keeps only `Return`. See the risk table below.

### Why the design is arrows-first, not Tab-first

macOS Full Keyboard Access is off by default, so Tab does not traverse to buttons for most users.
Spike 2 shows Tab *events* do reach the popover, so traversal could be hand-built — but arrows over
an explicit selection are simpler and always work. This is also the honest resolution of the "Full
Keyboard Access tab order is erratic" item in `backlog.md:340`: the fix is not to repair a tab order
most users cannot reach, it is to put navigation somewhere that always works.

## Design — keyboard access to the single-level popover

**Rows gain an explicit selection.** The existing `VStack` of `MenuBarRow` buttons stays; each row
becomes focusable, with an `@FocusState` cursor over the row identity. **Deliberately not a
`List`** — the first draft proposed one for its free arrow handling, which `.onMoveCommand` supplies
without the list chrome on the glass material or a sizing fight with a popover that self-sizes. Five
uniform rows do not need it. (The reason recorded here originally — "spike 2 shows `.onKeyPress`
works" — was wrong for arrows; the conclusion happens to survive on the better reason.)

| key | behaviour |
|---|---|
| `↑` / `↓` | move the row cursor (clamped, no wrap — five rows do not need wrap-around) |
| `↩` | open the focused node in the app (today's row action) |
| `⌘↩` | Open Pensieve (the footer primary) |
| `⌘R` | Refresh — already the app's shortcut (`PensieveApp.swift:56`) |
| `⌘,` | Settings, via the shipped `SettingsLink` |
| `Esc` | close the popover — **implemented**, via `.onExitCommand`; not system behaviour |

**The footer is reached by shortcut, not by traversal.** This closes a self-contradiction the reviews
caught in the first draft, which dismissed Tab as unreachable and then placed a primary action in the
footer with no keyboard route. Shortcuts are also the platform-native answer for a menu-bar surface.

**Focus is placed on the first row when the popover opens**, so it is usable without the mouse.

**Empty state:** when What's Next is empty the popover renders "Nothing queued" as plain text
(`MenuBarView.swift:78`) and there is no row to focus. Focus placement must tolerate that rather than
assume a first row exists.

**VoiceOver:** rows are already `Button`s and so are reachable; each gains an `.accessibilityLabel`
combining the node name with its meta line, since the two-line visual layout reads as two unrelated
fragments otherwise. No level change means nothing to announce.

## Split out of this spec

**Batch `attachEvents` — its own Kit-only change, not gated on this UI work.** It issues one `Event`
point query per loose end (`LooseEndQueries.swift:133-141`) and is shared by all four
`LooseEndQueries` feeds, so it is independently valuable to surfaces shipping today. Measured
per-node cost on the largest node: **61.3 ms for 288 rows** (vs 24.8 ms / 136 and 10.0 ms / 57).

Two things the reviews established that must carry into that change:

- **Deduplicate.** 986 open loose ends resolve to only **337 distinct** `sourceEventID`s — ~2.9×
  redundant. The batch must bind a `Set`, not the raw array.
- **The first draft's test plan was impossible.** It prescribed a mutation test that "fails if the
  batching is deleted". Batching is a pure refactor; reverting it restores byte-identical output, so
  an equivalence test *cannot* fail. The honest plan: existing feed tests cover equivalence, a new
  test covers deduplication and the drop-on-missing-event rule, and the performance claim is
  **measured before/after**, not asserted by a test.
- **A fifth copy exists outside the file.** `SalienceReviewQueries.pending` has its own inlined
  per-row point-query loop *and* a byte-identical copy of the salient comparator. Extracting one and
  leaving the other is how the two drift.

**`openTop` is not built.** See "What the reviews changed".

## Risks — all four resolved in build, by a third trace

The first implementation shipped with four defects. None were caught by a green build; all four were
found by using it and then instrumenting, not by re-reading the code.

| risk as written | what actually happened |
|---|---|
| `.defaultFocus` does not take on first open | Non-issue. Setting focus from `.task` works. |
| `Esc` may be consumed by the panel before SwiftUI sees it | It is **not** consumed — `.onExitCommand` receives it. The bug was that nothing was implemented for it, which the risk row obscured by framing it as an availability question. |
| A focus ring on a row may read poorly against the popover's glass | Correct, but the fix was insufficient: styling the row drew the fill **in addition to** the system ring, which read as a permanent stray outline on the pre-focused first row. `.focusEffectDisabled()` is what makes the fill a replacement. |
| — (not anticipated) | **Arrows were bound to the wrong API.** `.onKeyPress` never receives them: arrow keys are consumed as *move commands* first. The trace showed the handler receiving `\r` and never once an arrow, while `.onExitCommand` fired in the same session — which is what proved command propagation reaches the container, and therefore that `.onMoveCommand` would work. |

### And one pre-existing bug this surfaced, affecting far more than the popover

`applyDeepLink` called `NSApplication.shared.activate()`, the macOS 14 **cooperative** form, which
**declines when another app is frontmost** — exactly the case where fronting is the point. Measured by
logging window state through the function: identical activations alternated between raising the
window and merely giving it key status behind other apps, tracking only whether Pensieve was already
active.

This is the **single navigation entry point for every surface** — menu-bar clicks, external
`pensieve://` opens, Spotlight taps, App Intents, Siri and Shortcuts. All of them have had it. Fixed
with `NSRunningApplication.current.activate(options: [.activateAllWindows])`, which is not deprecated
(`.activateIgnoringOtherApps` is) and actually raises rather than merely focusing.

### Dismissing the popover has no first-party route

Verified against the SwiftUI `.swiftinterface` for MacOSX26.5: `MenuBarExtra`'s `isInserted:` binding
controls whether the item **exists**, not whether it is presented, and there is no presentation
binding at all. The first attempt closed the `NSPanel` directly; that worked visually and was wrong —
SwiftUI still believed the popover was presented, so the status item kept its highlight and the next
click was spent resyncing instead of opening, costing one dead click every time.

The shipped version clicks the `NSStatusBarButton` instead, which lets SwiftUI toggle the state that
was out of sync. `NSStatusBarButton` is public AppKit, unlike the private `MenuBarExtraWindow<AnyView>`
the first version had to identify by window level, and the button's `.on` state doubles as the "is it
open" test and the no-op guard for external opens.

## Human-verify — done 2026-08-15, all passing

Every item below was verified against the installed app. Items 1–4 **failed on the first build** and
are the reason the risk table above is now a record rather than a forecast.

1. ✅ `↑`/`↓` move a visible row highlight; `↩` opens that node.
2. ✅ `⌘↩`, `⌘R`, `⌘,` fire from the popover without the mouse. (`⌘↩` initially read as "no effect" —
   it was firing all along, but hit the activation bug, so the window never came forward.)
3. ✅ Focus lands on the first row on open.
4. ✅ `Esc` closes the popover, **and a single click reopens it** — the second half is the one that
   caught the stale-presentation-state bug, and a check for "does Esc close it" alone would have
   passed the broken version.
5. Outstanding: VoiceOver reads a row as one coherent label.
6. Outstanding: German in situ.

**Method note worth keeping.** Four defects shipped through a green build, zero lint violations and a
passing suite. Every one was found by using the surface and then *instrumenting the paths* — logging
which handler fired, with which key and modifiers, and what the window state was before and after.
Reasoning about the code found none of them, and twice produced confident wrong diagnoses (an
Enter-vs-click distinction that did not exist, and a "regression" in a path that had always been
broken).

## Deferred, not foreclosed

- **Node-scoped Loose Ends as a real surface** — one node's triage queue with the resolve verbs,
  rather than the cross-node bucket. This is the genuinely useful version of what level 2 gestured
  at, and it belongs in the main window with undo, not in a 320 pt popover. Its own spec.
- **Type-select** in the popover. Five rows do not need it.
- **Tab traversal** of the footer. Spike 2 shows the events arrive, so it is possible; the shortcuts
  above make it unnecessary.
