# Transcript reading — one rail, no nested cards (Claude Design slice C)

**Date:** 2026-08-24
**Status:** design, ready for review
**Scope:** the provenance transcript's visual hierarchy — collapse three nested surfaces to one, give
speaker identity a rail, fold the harness envelopes, compress the quoted type scale, and let the
expanded transcript break out of the loose-end card at full detail-pane width. Plus one measurement:
whether a find match can keep its rendered Markdown instead of flattening to raw syntax.

**Closes:** Tier 2 ▸ "Claude Design review of the shipped app — slice C" (*trigger: live now*), and the
slice-D item "`Du` vs `user` in the same message" — as a deletion, on evidence.

Deliberately excluded, each filed with its own entry: the transcript in a **separate window**; a
**retry of the trailing `.inspector`**; chipping the **skill document body** (unreachable — see
*The skill chip is smaller than it looked*); syntax highlighting and Mermaid/DOT rendering (already
parked); Writing Tools; any change to `TranscriptMarkup`'s parse algorithm, the vocabulary, the
`ProvenanceQueries` kernel, or the trust gate.

All line references are against `main` at `127c52a`.

## Problem

`ProvenanceQueries` produces the evidence behind every loose end, and the app renders it by nesting
three near-identical gray surfaces:

| Layer | Site | Treatment |
|---|---|---|
| 1 — provenance card | `LooseEndRow.swift:114` | `Color.secondary.opacity(0.08)`, radius 12, padding 12 |
| 2 — message bubble | `TranscriptMessageView.swift:53` | `Color.secondary.opacity(0.10)`, radius 12, padding 10 |
| 3 — harness card | `TranscriptSegmentView.swift:109` | `Color.secondary.opacity(0.07)`, radius 6, padding 8 |

Three fills within 3% of each other, three corner radii, three paddings — and the speaker label
(`TranscriptMessageView.swift:39`, 11pt) sits *outside* layer 2 while *inside* layer 1, so it reads as
a caption for the card rather than as attribution for the message. The result reads as a log, not a
conversation, which is the opposite of what a reload-context surface is for.

Two further defects, both measured rather than asserted:

- **Quoted content outranks the app's own chrome.** `TranscriptSegmentView.swift:180` renders a
  transcript H1 at **22pt**. The detail pane's own node name is `.largeTitle` (`DetailView.swift:44`,
  26pt) and its section headers are 13pt semibold uppercase (`ProseStyle.swift`). A markdown heading
  inside a *quoted transcript* is therefore the second-largest text in the pane.
- **The bubble rule was never actually decided.** `TranscriptMessageView.swift:84` reads
  `bubbled = !compact && speaker != .system` — the readability spec's *pre-committed fallback*, taken
  because trailing-aligned bubbles inside a `List` row were unverified. Both You and Claude are
  bubbled today, so the bubble distinguishes nothing.

## Decisions

From brainstorming, in order taken:

1. **The flatten-on-match trade-off is in scope, measure-first** — a bounded spike with a
   pre-committed fallback, not an open-ended renderer project.
2. **Structure A — the speaker rail.** A fixed leading gutter carries identity; only *you* are
   bubbled; Claude sits free on the page as prose.
3. **Venue: full-width inline breakout**, not a panel. Rejected alternatives are recorded below with
   the evidence that decided them.
4. **Harness policy: fold everything; two named exceptions** — `toolUseError` stays visible,
   `skillPreamble` becomes a chip.
5. **Fold state resets** on re-expand; it is never persisted.
6. **A folded or chipped block auto-opens on a find match** — non-negotiable, see *The one
   correctness rule*.
7. **The meta line's `role` is deleted**, on evidence that it is a constant.
8. **Type scale compresses to two sizes** — h1 15, h2–h6 14 semibold.

## The venue: why inline, and what was rejected

The Claude Design prototype implies a right-hand floating panel, and the intuition behind it is
correct: the transcript should have its own surface rather than being a guest inside two others. The
disagreement is only about mechanism.

**Rejected — a trailing `.inspector`.** Retired on 2026-07-08 (`backlog.md`, "App layout + inline
provenance rework") after **three failed patches and an AppKit crash** —
`_updateSidebarPositionIfNeeded` → `_tileTitlebarAndRedisplay`, triggered by toggling the sidebar with
the inspector open. The root cause recorded then was structural: *four resizable regions (3-column
split + `.inspector`) is more than macOS reliably fits/tiles.*

That decision deserves a caveat rather than permanent finality, and it gets its own backlog entry:
the session that made it was **bug-fix-driven, not design-driven** (no spec, no plan, an architecture
pivot under crash pressure), and three things have changed since — the app now has a **macOS 26.0
floor**, the inspector was attached at **window level** rather than scoped to the detail column, and
the crash trigger was one specific interaction. `.inspector` remains the platform-suggested answer to
this layout problem. It should be retried deliberately, with research, and not inside a readability
slice.

**Deferred — the transcript in its own window.** `RecallWindowView` and ⌘⌥N already open secondary
recall windows, so "open this transcript in its own window" is a small verb on shipped machinery with
no tiling risk. It is attractive and cheap, but it is a *navigation* feature; folding it in would turn
slice C into an IA change. Filed.

**Chosen — full-width inline breakout.** The expanded transcript stops being a guest inside the
loose-end card and becomes its own top-level surface spanning the detail pane's full width, while the
surrounding prose stays capped at `Prose.measure` (760). This uses the wide window's surplus — the
legitimate complaint underneath the rejected inspector proposal — while:

- keeping the 2026-07-08 inline-provenance decision that later work builds on;
- leaving ⌘F's reach intact (see below);
- adding **no** resizable region to a split view that has already crashed with four;
- degrading correctly in the middle column, where no panel could exist anyway.

**Why a panel would have cost more than it looks.** `NodeFindDocument` indexes the transcript segments
of *every* loose end in a node and force-expands rows to reveal matches
(`LooseEndRow.swift`, `forcedExpansions`). ⌘F today finds text inside a transcript the user never
opened. A panel showing one transcript at a time either loses that reach or must drive the panel
per match — a much larger design. And three of `LooseEndRow`'s **five** call sites are the middle
column at ~180pt usable, where a panel cannot exist; the nesting would still need fixing inline, so a
panel *adds* a surface rather than replacing one.

**The five call sites** — the readability spec recorded three; the burn-down surfaces (2026-08-13)
added two more, and any change here must reach all of them:

| Site | Column | `compact` |
|---|---|---|
| `ContentListView.swift:165` — a focused leaf's own loose ends | middle | `true` |
| `ContentListView.swift:201` — Review Suggestions | middle | `true` |
| `ContentListView.swift:247` — search results | middle | `true` |
| `DetailView.swift:69` — the detail pane | detail | `false` (default) |
| `ClosedLooseEndsRecord.swift:37`, via `DetailView.swift:122` | detail | `false` (default) |

`compact` defaults to `false` (`LooseEndRow.swift:36`), so the two detail-pane sites get the rail,
the bubble and the breakout, and the three middle-column sites are explicitly opted out. Verified
call-by-call rather than assumed.

## Part 1 — Kit (tested)

**File:** `Sources/PensieveKit/Transcript/TranscriptSegment.swift`. No parser change, no vocabulary
change, no new harness kind.

### `HarnessKind.presentation`

The fold policy is a *rule*, not chrome, so it lives in Kit where it can be tested and where kind #12
must make an explicit choice rather than inherit one by omission.

```swift
public enum HarnessPresentation: Equatable, Sendable {
  case visible   // rendered in full, never collapsed
  case chip      // a one-line pill; body reachable on demand
  case folded    // a disclosure line: label + line count
}

extension HarnessKind {
  public var presentation: HarnessPresentation { … }
}
```

| Presentation | Kinds | Why |
|---|---|---|
| `.visible` | `toolUseError` | An error is frequently *why* the session went sideways — the thing a reload-context surface exists to resurface. |
| `.chip` | `skillPreamble` | Its `displayBody` is a filesystem path (`TranscriptSegment.swift:83`, returned at `:127`). A full card around one path is absurd. |
| `.folded` | the other nine | Bulk. Label answers *what this is*; the body is one disclosure away. |

`interrupted` is `.folded` and needs no special case: its `displayBody` is already `nil`, so it renders
as a label with nothing to disclose.

### `HarnessBlock.lineCount`

Feeds the "· 34 lines" affordance on the folded line. Derived from `displayBody`, so it counts what
*renders* rather than what `raw` holds — the same discipline `findableText` already documents.

### Tests

- `presentation` returns the specified case for **all eleven** kinds — an exhaustive switch in the
  test, so adding a kind fails the suite rather than defaulting silently.
- `lineCount` over: empty body, single line, trailing newline, multi-line, and a `nil` body.
- Mutation-check both: delete the clause under test, confirm red.

## Part 2 — Rendering (app, thin)

### The rail

`TranscriptMessageView` becomes a two-column grid: a fixed leading gutter (~58pt) carrying the
speaker, and the content column. The role caption moves *into* the rail, which is what makes it read
as attribution instead of as a card caption.

`bubbled` changes from `!compact && speaker != .system` to **`!compact && speaker == .you`**. Claude's
replies lose their bubble and sit as prose. The bubble now means exactly one thing — *a person typed
this* — which is the distinction the reader is hunting for.

**The cited marker is preserved and unchanged in behaviour.** `ProvenanceQueries` hard-guards
`citedMessage.isUserPrompt`, so the cited message is always `.you`, which is always the bubbled class
in the wide pane: the existing leading bar + tinted border (`TranscriptMessageView.swift:64-67`) keeps
working as-is. The bar attaches to the content column, never to the rail.

### Harness rendering

`TranscriptSegmentView`'s `.harness` branch switches on `presentation`:

- `.folded` → a disclosure line, `▸ <label> · <n> lines`, expanding to today's body treatment.
- `.chip` → a pill carrying the label and the skill name derived from the path.
- `.visible` → today's body, minus the card.

The gray card at `:109` goes away in all three. The label survives in all three — it is what tells the
reader *what* the block is, and the readability spec's Decision 4 (all kinds bespoke) still holds.

### The one correctness rule

**A folded or chipped block expands whenever `highlight != nil`.**

This is not polish. `NodeFindDocument` indexes harness bodies through `findableText` and counts those
matches; `TranscriptSegmentView.swift:92` already drops its `lineLimit` while highlighting for exactly
this reason, with the reasoning written down: *"the body is indexed in FULL, so a phrase past line 12
would otherwise be a counted match clipped out of view — a match the bar promises and the pane never
shows."* Folding without auto-open would reintroduce that hole and make it worse, since a folded block
hides everything rather than a tail.

The signal is already in scope in the view, so this is a condition, not new plumbing. A chip is a
collapsed *affordance*, never a hidden body.

### Type scale

`transcriptProse()` compresses from six sizes to two: **h1 15 semibold, h2–h6 14 semibold**, margins
unchanged (`Theme.basic`'s margins drive all inter-block spacing — dropping them collapses the space
after a heading to zero, as the existing comment records). Quoted headings become emphasis inside a
quote rather than document structure competing with the pane's own hierarchy.

### The breakout

In `LooseEndRow`, the expanded transcript renders as its own surface spanning the detail pane's full
width — negative horizontal insets against the row's padding, its own fill, hairline top and bottom —
while the loose-end text and meta line stay within the measure. **Compact is unchanged here:** no
breakout, no rail, no bubbles, today's stacked layout. Compact still gets the folds, the chip and the
capped type scale, which is where most of its win is at ~180pt.

### The `role` deletion

`LooseEndRow.swift:99` renders `view.looseEnd.role` into the meta line, untranslated, directly beneath
a localized speaker label — the slice-D "`Du` vs `user`" clash, which the rail makes more prominent by
promoting speaker identity.

Measured on the live store:

```
sqlite> select role, count(*) from looseEnds group by role;
user|1076
```

All 1,076 loose ends carry `role = "user"`, and that is structural rather than incidental:
`LooseEndVerifier.swift:31` takes the role from the cited message and `ProvenanceQueries` hard-guards
`citedMessage.isUserPrompt`. The field cannot say anything else. It is deleted from the meta line,
which becomes date + relative date. The `LooseEnd.role` **column is untouched** — this is a rendering
change, not a model change.

## Part 3 — The flatten-on-match measurement

**Today's behaviour.** When a segment matches, its body renders as plain highlighted text instead of
Markdown, because MarkdownUI 2.4.1 exposes no way to style a substring inside a rendered block (its
AST types are internal — verified against the vendored checkout). The cost is visible raw syntax until
the find bar closes.

**Hypothesis to falsify.** A matched segment whose markdown contains only *inline* constructs (bold,
italic, code spans, links) can render through `AttributedString(markdown:)` with the matched phrase
tinted via attribute ranges — keeping its formatting. Block constructs (lists, headings, fences)
continue to flatten.

**Pre-committed fallback.** Today's flatten, unchanged, with the finding recorded in the backlog.
Both outcomes close the question; only one changes code. The plan time-boxes this so it cannot become
a renderer project, per the precedent this spec's predecessor set (`RootView.swift:34-37`, the
`.searchScopes` carry that resolved negatively and cost only a swap because the fallback was named in
advance).

**What must hold either way:** the highlight runs and current-match offset come from the same
`FindRun` data as today, and the match count cannot change. A rendering change that alters what
`findableText` sees is out of scope by construction — this touches display only.

## The skill chip is smaller than it looked

The design review's item reads "attached skill documents become a chip, not an embedded article."
Only half of that is reachable here.

`HarnessKind.skillPreamble(path:)` captures the *preamble line* ("Base directory for this skill: …")
and its `displayBody` returns the path alone. There is no article inside the harness block to chip —
the chip is worth doing because a card around a bare path is silly, not because it collapses bulk.

The actual embedded article is skill **content arriving as ordinary markdown**, in no harness tag at
all. The render layer cannot reach it; identifying it would need a parser change, and detection would
have to be heuristic on content rather than allowlisted on tags — which is precisely what
`TranscriptVocabulary` is structured to avoid, and it sits adjacent to the trust gate. **Filed as its
own item, not smuggled in here.**

## Testing

**Kit** — the two new properties, per Part 1, mutation-checked.

**App** — `Sources/PensieveApp` has no unit tests by construction. Verification goes through
`make uitest` and `uiprobe` per the `verify-app-ui` skill, plus a human-verify checklist. Do not claim
coverage this target cannot have.

The must-pass item is **find auto-open**, because it is the one *behavioural* claim in this spec
rather than a visual one: with ⌘F open and a query matching only inside a harness body, the block
renders expanded and the highlighted phrase is on screen. Everything else is eyeball verification.

Human-verify matrix: the two detail-pane sites and the three middle-column sites × English and German ×
find open and closed.

## Risks

- **The breakout's negative insets** are an app-side visual claim of exactly the kind this project has
  seen SwiftUI decline before. *Pre-committed fallback:* the transcript keeps the row's normal width
  and drops only the nesting — surfaces 2 and 3 still go, which is the majority of the win.
- **The rail at unusual dynamic-type settings** may crowd the content column. *Pre-committed
  fallback:* the stacked caption (today's layout) above a threshold.
- **Fold hides something the reader wanted.** Mitigated by the label surviving, by the line count, and
  by auto-open on match. If it still bites, the policy is one Kit property away from changing.
- **`presentation` drifts from what the view does.** Mitigated by the exhaustive-switch test — the one
  place the policy lives.

## Success criteria

1. No transcript surface nests inside another. The provenance card's fill is the only one in the
   expanded row (or the breakout's, which replaces it).
2. A bubble appears if and only if the speaker is `.you` in the wide pane.
3. The cited-provenance marker is preserved, verified in both widths and both languages.
4. No transcript heading renders above 15pt.
5. With ⌘F open on a query matching only a harness body, the block is expanded and the phrase visible
   — verified by running it, not by reasoning about it.
6. `make all` green; SwiftLint strict clean; no file over the 400-line cap.
7. The flatten-on-match question is closed — either by a shipped change or by a recorded finding and
   the fallback taken. An open question is a failed criterion.
8. The middle column keeps working at ~180pt: no rail, no bubbles, no breakout, folds present.
