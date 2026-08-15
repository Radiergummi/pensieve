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

**Implementation consequence, earned by the log:** arrows report `key=""` because they carry no
character. Match on `.onKeyPress(.upArrow)` / `.onKeyPress(.downArrow)`; never inspect
`press.key.character`.

### Why the design is arrows-first, not Tab-first

macOS Full Keyboard Access is off by default, so Tab does not traverse to buttons for most users.
Spike 2 shows Tab *events* do reach the popover, so traversal could be hand-built — but arrows over
an explicit selection are simpler and always work. This is also the honest resolution of the "Full
Keyboard Access tab order is erratic" item in `backlog.md:340`: the fix is not to repair a tab order
most users cannot reach, it is to put navigation somewhere that always works.

## Design — keyboard access to the single-level popover

**Rows gain an explicit selection.** The existing `VStack` of `MenuBarRow` buttons stays; each row
becomes focusable, with an `@FocusState` cursor over the row identity. **Deliberately not a
`List`** — the first draft proposed one for its free arrow handling, but spike 2 shows `.onKeyPress`
works, so a `List` would buy arrow handling at the price of list chrome on the glass material and a
sizing fight with a popover that currently self-sizes. Five uniform rows do not need it.

| key | behaviour |
|---|---|
| `↑` / `↓` | move the row cursor (clamped, no wrap — five rows do not need wrap-around) |
| `↩` | open the focused node in the app (today's row action) |
| `⌘↩` | Open Pensieve (the footer primary) |
| `⌘R` | Refresh — already the app's shortcut (`PensieveApp.swift:56`) |
| `⌘,` | Settings, via the shipped `SettingsLink` |
| `Esc` | close the popover (system behaviour; see risks) |

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

## Risks

| risk | fallback |
|---|---|
| `.defaultFocus` does not take on first open | Set focus explicitly from `.task` — spike 2 shows programmatic focus is accepted. |
| `Esc` may be consumed by the panel before SwiftUI sees it | Unverified, and low-stakes: if it cannot be observed, the system keeps whatever it already does. Not worth fighting the panel for. |
| A focus ring on a row may read poorly against the popover's glass | Style the focused row with the same `.quaternary` fill the hover state already uses, rather than relying on the system ring. |

## Human-verify carries

Need the installed app; a green build catches none of these.

1. `↑`/`↓` move a visible row highlight; `↩` opens that node.
2. `⌘↩`, `⌘R`, `⌘,` fire from the popover without the mouse.
3. Focus lands on the first row on open — and does **not** crash or trap when What's Next is empty.
4. What `Esc` actually does.
5. VoiceOver reads a row as one coherent label.
6. German in situ.

## Deferred, not foreclosed

- **Node-scoped Loose Ends as a real surface** — one node's triage queue with the resolve verbs,
  rather than the cross-node bucket. This is the genuinely useful version of what level 2 gestured
  at, and it belongs in the main window with undo, not in a 320 pt popover. Its own spec.
- **Type-select** in the popover. Five rows do not need it.
- **Tab traversal** of the footer. Spike 2 shows the events arrive, so it is possible; the shortcuts
  above make it unnecessary.
