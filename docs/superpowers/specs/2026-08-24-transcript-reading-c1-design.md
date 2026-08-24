# Transcript reading, C1 — one surface, one rail

**Date:** 2026-08-24
**Status:** design, ready for review (rewritten after adversarial review — see *What the review changed*)
**Scope:** the provenance transcript's visual hierarchy, and nothing else. Remove two of the three
nested fills, give speaker identity a rail, make the bubble mean one thing, compress the quoted type
scale, and delete a meta-line field that is provably constant.

**App-target only.** No PensieveKit change, no new query, no parser change, no model change.

**Closes:** the *hierarchy* half of Tier 2 ▸ "Claude Design review — slice C", and the slice-D item
"`Du` vs `user` in the same message" — as a deletion, on evidence.

**Explicitly deferred to C2 and C3**, both filed in `backlog.md` with the evidence that sized them:
harness folding (C2 — wants corpus measurement and UI-fixture work first) and the transcript's venue
(C3 — wants the `DetailView` measure-cap restructure first). Flatten-on-match is **not** a separate
question and is folded into the existing skew defect; see *What the review changed*.

All line references verified against `main` at `127c52a`.

## Problem

`ProvenanceQueries` produces the evidence behind every loose end, and the app renders it by nesting
three near-identical gray surfaces:

| Layer | Site | Treatment |
|---|---|---|
| 1 — provenance card | `LooseEndRow.swift:114` | `Color.secondary.opacity(0.08)`, radius 12, padding 12 |
| 2 — message bubble | `TranscriptMessageView.swift:53` | `Color.secondary.opacity(0.10)`, radius 12, padding 10 |
| 3 — harness card | `TranscriptSegmentView.swift:109` | `Color.secondary.opacity(0.07)`, radius 6, padding 8 |

Three fills within 3% of each other, three radii, three paddings — and the speaker label
(`TranscriptMessageView.swift:39`, 11pt) sits *outside* layer 2 while *inside* layer 1, so it reads as
a caption for the card rather than as attribution for the message. It reads as a log, not a
conversation, which is the opposite of what a reload-context surface is for.

Two further defects, both measured:

- **Quoted content outranks the app's own chrome.** `TranscriptSegmentView.swift:180` renders a
  transcript H1 at **22pt**, against the pane's own `.largeTitle` node name (`DetailView.swift:44`)
  and 13pt semibold uppercase section headers (`ProseStyle.swift`). A heading inside a *quoted
  transcript* is the second-largest text in the pane.
- **The bubble rule was never decided.** `TranscriptMessageView.swift:84` reads
  `bubbled = !compact && speaker != .system` — the predecessor spec's *pre-committed fallback*, taken
  because trailing-aligned bubbles in a `List` row were unverified. Both You and Claude are bubbled,
  so the bubble distinguishes nothing.

## Decisions

1. **The rail.** A fixed leading gutter (~58pt) carries the speaker; the content column carries the
   message. Attribution stops being a caption on a card.
2. **One meaning for the bubble.** `bubbled` becomes `!compact && speaker == .you`. Claude renders as
   free prose. The bubble now says exactly *a person typed this*.
3. **Two fills die** — layer 2 for Claude, layer 3 entirely. Layer 1 stays and is the single surface.
4. **Type scale compresses** from six sizes to two: h1 15, h2–h6 14, all semibold; margins unchanged.
5. **The meta line's `role` is deleted**, on measurement.

### One nested fill survives, deliberately

With layer 3 gone and layer 2 kept only for `.you`, an expanded row is *provenance card → one bubble
on user messages*. That is two levels, not three, and the remaining bubble carries meaning rather than
decorating every message. Naming it here so it does not read as an oversight: **at most one fill may
nest inside the provenance card, and only for `.you`.** That is success criterion 1.

## The rendering changes

### The rail

`TranscriptMessageView` becomes a two-column layout: a fixed leading gutter carrying the speaker, and
the content column. The role caption moves *into* the rail. `showsRoleLabel` keeps its current
meaning (suppressed on speaker change — predecessor Decision 6); a suppressed label leaves the gutter
empty, which is what makes a run of same-speaker messages read as one turn.

**The cited marker is unchanged in behaviour.** `ProvenanceQueries.swift:46` passes
`requireUserPrompt: true` into `TranscriptWindow.slice`, so the cited message is always `isUserPrompt`
⇒ always `.you` ⇒ always the bubbled class in the wide pane. The existing leading bar + tinted border
(`TranscriptMessageView.swift:64-67`) keeps working. **The bar attaches to the content column, never
to the rail.**

### Harness blocks lose their card, and nothing else

The fill at `TranscriptSegmentView.swift:109` goes. The kind label, the monospace body, the
`lineLimit(12)` cap and the highlighted-path `lineLimit` drop (`:92`) all stay exactly as they are.
Machine output remains distinguishable by label + monospace + secondary color, which is what
distinguishes it today; the card was redundant with those, not load-bearing over them.

**No folding in C1.** Folding is a behaviour change with a find-correctness rule attached and no
evidence yet for its policy — C2.

### Type scale

`transcriptProse()` goes from six heading sizes to two: **h1 15 semibold, h2–h6 14 semibold**, margins
unchanged (`Theme.basic`'s margins drive all inter-block spacing; dropping them collapses the space
after a heading to zero, as the existing comment records).

### The `role` deletion

`LooseEndRow.swift:99` binds `view.looseEnd.role` and `:105` renders it into the meta line,
untranslated, directly beneath a localized speaker label — the slice-D "`Du` vs `user`" clash, which
the rail makes more prominent by promoting speaker identity.

```
sqlite> select role, count(*) from looseEnds group by role;
user|1076
```

All 1,076 loose ends carry `role = "user"`, and structurally cannot carry otherwise:
`LooseEndVerifier.swift:28` guards `message.isUserPrompt`, and `TranscriptParser.swift:45` sets
`isUserPrompt` only for `type == "user"`. The field cannot say anything else. It leaves the meta line,
which becomes date + relative date.

**The `LooseEnd.role` column is untouched** — this is a rendering change, not a model change. Two CLI
renderers also print it (`Sources/pensieve/Commands/LooseEnds.swift:29`, `Status.swift:21`, both
`[\(looseEnd.role), \(ageDays)d]`). They are **left alone in C1 and filed**: the app and CLI briefly
disagree about whether the field is worth showing, which is a cosmetic inconsistency in a
single-user tool, and bundling a CLI change into an app-rendering slice is how slices grow.

*Note for a reader who checks the predecessor:* its revision note (m2) says "`role` is **not** a
closed set." That is about `ProvenanceMessage.role` — any message in the window. This is
`LooseEnd.role` — the cited, `isUserPrompt`-gated one. Different scopes; no contradiction.

## The six call sites

The predecessor recorded three; the burn-down surfaces (2026-08-13) added two, and `previewRow`
is a sixth rendering mode that a call-site table alone misses:

| Site | Column | `compact` |
|---|---|---|
| `ContentListView.swift:165` — a focused leaf's own loose ends | middle | `true` |
| `ContentListView.swift:201` — Review Suggestions | middle | `true` |
| `ContentListView.swift:247` — search results | middle | `true` |
| `DetailView.swift:69` — the detail pane | detail | `false` (default) |
| `ClosedLooseEndsRecord.swift:37`, via `DetailView.swift:122` | detail | `false` (default) |
| `LooseEndRow.swift:315` — **`previewRow`** | either | **`true`, hardcoded** |

`previewRow` passes `compact: true` regardless of the row's own flag, and it is the *default* state in
the detail pane whenever `ctx.messages.count > 1` (`:228-235`). So the detail pane's collapsed preview
gets the compact treatment and its expanded form gets the rail — **the same message changes layout
mode on "Show more".**

**Decision: `previewRow` gets the rail too.** The gutter is 58pt and the preview is a single
three-line segment, so it fits; consistency between the two states of one disclosure matters more than
the width. This is the one place C1 changes a call site rather than a view.

## Risks, each with a pre-committed fallback

| Risk | Fallback |
|---|---|
| The rail crowds the content column at large dynamic-type sizes | Stacked caption (today's layout) above a threshold |
| The rail is too wide for `previewRow` inside a middle-column row | `previewRow` reverts to stacked; the detail pane keeps the rail, and the mode change is recorded as accepted |
| Removing Claude's bubble makes a long assistant turn hard to bound | Reinstate a hairline rule between messages — a separator, not a fill |

## Testing

**No Kit change, therefore no new Kit tests, therefore no automated coverage of this slice.** Stated
plainly rather than dressed up: `Sources/PensieveApp` has no unit tests by construction, C1 touches
only that target, and every change here is visual. `make all` must stay green (it proves nothing about
this slice beyond compilation and lint).

Verification is `make uitest` for what it can reach, `uiprobe` per the `verify-app-ui` skill, and a
human-verify pass across the two detail-pane sites and the three middle-column sites × English and
German × collapsed and expanded.

**What no harness here can check**, so it is checked by reading the diff: heading point sizes (AX
exposes no font size), background fills and the orange marker (no AX identity). Criterion 4 is
therefore written as a code-level assertion rather than a rendering one.

## Success criteria

1. At most one fill nests inside the provenance card, and only for `.you`. Layers 2-for-Claude and 3
   are gone.
2. A bubble appears if and only if the speaker is `.you` and the site is not compact.
3. The cited-provenance marker is preserved — verified in both widths, both languages, collapsed and
   expanded.
4. `transcriptProse()` defines exactly two heading sizes, 15 and 14. *(Code-level: AX cannot see font
   size, so a rendering criterion here would be unverifiable theatre.)*
5. `previewRow` and the expanded form render the same layout mode — no jump on "Show more".
6. `make all` green, SwiftLint `--strict` clean, **no file over 400 lines** — see the note below.
7. The middle column still works at ~180pt: no rail crowding, no bubbles, content legible.

### Criterion 6 needs budgeted work, not luck

`LooseEndRow.swift` is at **387** lines and `DetailView.swift` at **385**, against SwiftLint's default
`file_length` warning of 400 with no override in `.swiftlint.yml` and CI running `--strict`. C1 adds
to `LooseEndRow` (the rail reaches `previewRow`) while removing only the two `role` lines.

**The split is named in advance**: `LooseEndRow+Provenance.swift`, taking `provenanceBody`,
`quoteFallback`, `previewRow`, `messageRow` and the existing transcript-helper extension. The seam is
already implied by the comment at `LooseEndRow.swift:336`, which records that the helpers were moved
to an extension to stay under `type_body_length`. Do not discover this at lint time and pick a seam
under pressure.

## What the review changed

An adversarial review of the first draft (2026-08-24) produced thirteen findings. Four were
load-bearing and independently verified against the source before being accepted:

1. **The flatten-on-match spike was foreordained, not a measurement.** `findableText` for `.markdown`
   returns the **raw markdown source** (`TranscriptSegment.swift:145`), and `HighlightedText`
   (`:39-52`) does no index math — it works only because the indexed and displayed strings are
   byte-identical. `AttributedString(markdown:)` consumes syntax characters and Foundation exposes no
   source-range mapping, so tinting the right characters requires re-running the matcher against the
   *rendered* text — computing the highlight on one string and the count on another. **That is the
   open Tier 2 "in-node find — highlight/document skew" defect, not an independent question.** Part 3
   is deleted and the finding is filed against that item, which now has a second motivation and a
   concrete framing: the real question is what `findableText` must become, and what that does to the
   count.
2. **The breakout could not reach full width by the specified mechanism.** `DetailView.swift:127-129`
   caps the whole section stack at `Prose.measure` and then centers it, so the distance to the pane's
   leading edge is `(paneWidth − 760)/2 + 54` — not a constant. A fixed negative inset under-reaches
   on a wide window and **clips on a narrow one**, where the ~420pt detail floor leaves the cap
   inactive and no surplus at all. Moved to C3, which must restructure the cap first.
3. **The must-pass find criterion could not be run.** `UITestFixture` writes no `.jsonl` and its
   events carry `{"files":[…]}`, so every fixture loose end resolves `transcriptAvailable == false`
   and degrades to `quoteFallback`. `make uitest` cannot render a transcript message at all. The
   fixture work is a real prerequisite and is budgeted into C2, where the find rule lives.
4. **Scope.** Nine deliverables across four independent design questions, for a slice whose stated
   purpose was "stop nesting three cards". Split into C1 / C2 / C3.

Also accepted and applied: `HarnessPresentation` in Kit bought nothing Swift's exhaustive switch does
not already give, and its prescribed mutation check was not executable (deleting a case from an
exhaustive switch is a compile error, not a red test) — dropped with the folding work. The
`previewRow` sixth site, the `LooseEndVerifier:28` and `LooseEndRow:99,105` reference fixes, and the
`ProvenanceQueries:46` → `TranscriptWindow` guard correction are all folded in above.
