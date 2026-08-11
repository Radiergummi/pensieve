# "Where was I" (slice A) — human-verify carries

Everything below needs the built app, a real store, and a pair of eyes. Subagents implemented and
reviewed this branch without a GUI, so no visual or interactive claim was made by anyone. These are
the checks nobody could perform, not a list of suspected problems.

Build and open:

```
xcodegen generate
xcodebuild -project Pensieve.xcodeproj -scheme Pensieve -configuration Debug -derivedDataPath ./.build-xcode build
open ./.build-xcode/Build/Products/Debug/Pensieve.app
```

## 1. The forced-locale pass — do this one first

This is the only check that catches a mis-keyed String Catalog entry, and five such entries shipped
undetected before this branch. `xcodebuild` does not validate catalog keys, so nothing else will
ever warn you.

```
open ./.build-xcode/Build/Products/Debug/Pensieve.app --args -AppleLanguages '(de)'
```

Confirm **no English fragment survives** on:

- **Briefing** — `%lld neu` on moved cards; the Quiet disclosure's relative dates.
- **Middle column** — e.g. `vor 3 Wochen · 14 offen`.
- **Detail header** — kind, state and count tokens.
- **An expanded loose end's footer** — e.g. `vor 1 Monat`.
- **Menu-bar popover** — the heartbeat count (`868 offen`) and a What's Next row
  (`288 offen · 0T ruhend`). These two were the mis-keyed ones; they are the point of the check.

Then relaunch with `-AppleLanguages '(en)'` and confirm English is intact on the same five surfaces.

While you are in German, glance at the node context menu and Settings ▸ Advanced — untouched by this
branch, but adjacent to what changed.

## 2. Detail pane

- A **project** shows no kind token and no branch; a **strand** shows both.
- An **archived** node shows `Archived`; an active one shows no state token.
- The recap sits **below** the loose ends, with no caps header, and its `✦ Generated summary` line
  is present.
- A node whose narration is unavailable shows **no gap** where the recap would be.
- While narration is generating, the spinner now sits beside its `✦ Generated summary` attribution
  rather than floating unlabeled.
- Judgment call worth a look: on a node that has a recap but **zero** loose ends, the Loose Ends
  section renders "None open." and the divided recap follows. Does that divider read right?

## 3. Middle column

- Rows read as recency and counts, not `Project` repeated down the column.
- Scrolling a long list stays smooth — facts come from one batched dictionary, so no query fires
  per row.
- A node with no captured events says so rather than showing a fake zero.

## 4. Briefing

- Moved cards visibly outweigh the collapsed Quiet section.
- Quiet is **collapsed on a fresh launch** (no prior `briefing.quiet.expanded` default).
- It expands to one-liners, each a single line at the chosen font sizes.
- The expansion state **survives a quit and relaunch** — only the `@AppStorage` mechanism was
  verified, not the round trip.
- No `dormant 0d`, anywhere.

## 5. Loose-end thumbs

- Thumbs are invisible until the pointer enters a row, and the row **does not shift** when they
  appear.
- A loose end you rate 👍 or 👎 **keeps its filled thumb visible** after the pointer leaves. This is
  the deliberate exception — a confirmed label is recorded state, not an affordance.
- Right-click offers both verbs, and `Clear rating` appears **only** on an already-rated row.
- The expanded provenance footer reads like `user · 3 July 2026 · 1 month ago`.
- **Full Keyboard Access pass** (flagged by the whole-branch review): hidden thumbs rely on
  `.accessibilityHidden(!showsThumbs)` to stay out of the focus ring — `.allowsHitTesting(false)`
  governs pointer hit testing only. Turn on Full Keyboard Access, tab through a loose-end row, and
  confirm Space cannot silently mark an invisible thumb. A stray 👎 filters that row out of the open
  list on the next reload, so a false negative here is quietly destructive.

## Open design question

The whole-branch review raised one reading of the spec that the code does not currently take: when a
loose end has been rated, **both** thumbs stay visible — the filled one *and* the opposite outline
one. The spec's rationale ("a confirmed thumb is recorded state, not an affordance") arguably applies
only to the thumb that was actually set; the opposite one is pure affordance and could hide until
hover. As shipped, rows you have already dealt with keep half the visual noise this change set out to
remove.

Shipped as-is because the spec's own table says "visible, filled" at the row level, which is
ambiguous. Flipping it is a two-line change: move `.opacity`/`.allowsHitTesting` from the `HStack`
down into `thumb(…)`, gated on `confirmed || hovering`. Layout is fixed-width either way, so no
reflow.
