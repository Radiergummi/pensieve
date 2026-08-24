# C1 human-verify — 2026-08-24

Spec: `specs/2026-08-24-transcript-reading-c1-design.md`. Plan: `plans/2026-08-24-transcript-reading-c1.md`.
Branch `worktree-transcript-reading`, commits `127c52a..492e963`.

**Status: AWAITING THE HUMAN PASS.** Every code task is implemented, reviewed and green
(`make all`: 802 tests, 0 lint violations, build + embedded-CLI smoke). Nothing below marked
"outcome" has been observed by anyone — the app was deliberately never launched during execution,
because `make run` replaces `/Applications/Pensieve.app` with a worktree build and steals focus, and
because a subagent cannot see a screen. This file is the checklist, not a record of a pass.

## Why no harness covers this

`Sources/PensieveApp` is an Xcode app target outside `PensieveKitTests`, so it has no unit tests by
construction. `make uitest` cannot help either, and not incidentally: `UITestFixture` writes **no
`.jsonl` transcript**, so every fixture loose end resolves `transcriptAvailable == false` and degrades
to `quoteFallback`. The suite has never rendered a transcript message. Building that fixture is
recorded as a prerequisite of C2.

## The checklist

Run `make run` (installs to `/Applications` and launches), then walk this.

| # | Criterion | Outcome | How to check |
|---|---|---|---|
| 1 | At most one fill nests inside the provenance card, and only for `.you` | | Expand a loose end in the detail pane. Claude's replies should sit on the page with no gray box; harness blocks should have a label and monospace but no card. |
| 2 | Bubble iff `.you` and not compact | | Same view: only your own prompts carry a gray bubble. |
| 3 | **Cited marker preserved** — the one invariant | | The cited message shows its orange leading bar **and** its tinted border. Check collapsed and expanded, both languages, both widths. |
| 4 | `transcriptProse()` defines exactly two heading sizes | | Code-level, already verified: `TranscriptSegmentView.swift:185` (15) and `:189/193/197/201/205` (14). AX exposes no font size, so this cannot be checked on screen. |
| 5 | Preview and expanded render the same layout mode | | Open a loose end whose provenance holds several messages — it opens collapsed. The preview should already show rail + bubble, and **Show more** should add messages without the first one changing shape. |
| 6 | `make all` green, `--strict` clean, no file over 400 | ✅ | Verified at `492e963`. `LooseEndRow.swift` is at **exactly 400** — see the warning below. |
| 7 | Middle column still works at ~180pt | | Select a childless leaf with open loose ends. No gutter, no bubbles, stacked caption — i.e. unchanged from before this branch. |

## The one question that can fail this slice

**Can you tell where one Claude message ends and the next begins?**

The final review caught this and it is the only finding that was a genuine regression rather than a
nitpick. Narrowing the bubble to `.you` removed the only boundary cue Claude's turns had, while the
caption-suppression rule (one caption per same-speaker run) assumes such a cue exists. A typical
provenance window is `you → claude → claude → claude`, so this is the common case, not an edge.

It was fixed by raising the inter-message gap to **18pt**, clearing MarkdownUI's 14pt paragraph
margin so the hierarchy reads within-paragraph < between-paragraphs < between-messages
(`LooseEndRow.swift:91-95`). **Whether 18pt is enough is a perceptual question and has not been
tested.** The spec pre-authorised a stronger fallback — a hairline rule between messages, a separator
rather than a fill — so if spacing alone does not do it, take that.

⚠️ **`LooseEndRow.swift` is at exactly 400 lines, SwiftLint's cap.** Lint passes (the rule fires above
the threshold, not at it), but there is **zero headroom**, and the hairline fallback would land in
that file. If this check fails, split the file first — the seam is already chosen and recorded as
Prerequisite 0 of C2: `LooseEndRow+Provenance.swift`, taking `provenanceBody`, `quoteFallback`,
`previewRow`, `messageRow` and the transcript-helper extension.

## Also worth a glance

- **German.** The meta line lost its leading `user` and is now date + relative date, both
  Foundation-formatted with no catalog key. Confirm no English fragment remains where `user` was.
- **The rail caption's vertical alignment.** It was misaligned by ~7pt on bubbled messages — which is
  every cited message — and was fixed at `TranscriptMessageView.swift:69`
  (`.padding(.top, bubbled ? 13 : 3)`). Confirm captions line up with the first line of body text on
  both bubbled and unbubbled messages, since they sit adjacent in the same view.
- **`make uitest`** has not been run on this branch. Nothing in it asserts the meta line or `role`, so
  it should pass, but it is unverified.

## Defects found

## Fallbacks taken

## Not verifiable by any existing harness

Heading point sizes, background fills and the orange marker have no accessibility identity, so
criteria 1, 2, 3 and 4 are diff-read plus eyeball rather than machine-checked. C2's fixture work is
the prerequisite for automating any of it.
