# "Where was I" (slice A) — human-verify carries

**RUN 2026-08-12 — see "Outcome" at the end. One real defect found and fixed; everything else passed.**

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

## Outcome — run 2026-08-12

Sections 1–4 passed. Section 5 found **one real defect, now fixed**.

**The defect: hover-revealed thumbs were unreachable.** `.onHover` sat on the row's outer `VStack`,
but SwiftUI only hit-tests *rendered* content — the `Spacer()` between the loose-end text and the
thumbs is dead space. Hovering the text revealed the thumbs; moving the pointer horizontally toward
them crossed the gap, hover ended, and they vanished before they could be clicked. The feature was
reachable only by right-click. Fixed with `.contentShape(Rectangle())` above `.onHover`
(`LooseEndRow.swift`). **Still needs one human confirm** — synthetic pointer events do not trigger
SwiftUI hover on an unfocused window, so this fix has not been seen working.

**Two process notes worth keeping:**

- The first English pass tested the **wrong binary** — `open ./.build-xcode/…` from the main checkout
  launches main's app, not the worktree's. It showed `Strand`/`Project` kind labels, `dormant 0d` and
  `2 since last visit`, i.e. exactly the defects this branch fixes, which reads as a total regression.
  Always confirm with `pgrep -lf Pensieve.app/Contents/MacOS/Pensieve` that the path is the worktree's.
- Section 1's substance is checkable **without eyes and more thoroughly**: parse `Localizable.xcstrings`
  for keys missing a `de` value, compare format specifiers between `en` and `de`, and diff the
  localizable Swift literals against the catalog's keys. That covers all 211 keys instead of five
  surfaces, and it is what would have caught the six mis-keyed entries before they shipped. The
  forced-locale launch is still worth doing for layout (see the truncation below), just not for
  key coverage.

**Verified passing:** German Briefing (`BEWEGT`/`RUHIG`, `2 neu`, collapsed on first launch, expansion
survives quit+relaunch, no `dormant 0d`); menu-bar `869 offen` and `288 offen · 1T ruhend` (the two
mis-keyed strings); middle-column recency+count rows; detail state line for strand / project /
archived; `noch nichts erfasst` for a node with no events; no gap when narration is absent; context
menu with `Clear rating` correctly absent on an unrated row; expanded footer
`user · 20. Juli 2026 · vor 3 Wochen`; English intact on the same surfaces.

**Found but out of scope for this branch** (logged in `backlog.md`): the menu-bar popover's
`Pensieve öffnen` truncates to `Pensieve öf…` in German; narration can still emit a facts-dump; the
transcript bubble header is localized (`Du`) while the footer shows the raw role (`user`); Full
Keyboard Access tab order is erratic and the middle column is not reliably reachable.
