# Transcript Reading C1 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove two of the three nested fills from the provenance transcript, move speaker identity onto a rail, make the bubble mean exactly "a person typed this", compress a quoted type scale that outranks the app's own headings, and delete a meta-line field that is provably constant.

**Architecture:** App-target only — five files, no PensieveKit change, no query, no parser, no model. `TranscriptMessageView` gains a fixed-width leading gutter in the non-compact path and keeps today's stacked layout in the compact path. `TranscriptSegmentView` loses the harness card's fill and compresses `transcriptProse()`'s six heading sizes to two. `LooseEndRow` drops the `role` field from its meta line and lets `previewRow` inherit the row's own `compact` instead of hardcoding it.

**Tech Stack:** Swift 6, SwiftUI, MarkdownUI 2.4.1 (vendored), XcodeGen, SwiftLint, Swift Testing.

**Spec:** `docs/superpowers/specs/2026-08-24-transcript-reading-c1-design.md`

## Global Constraints

- **Branch `worktree-transcript-reading`, worktree `/Users/moritz/Projects/pensieve/.claude/worktrees/transcript-reading`, based on `main` at `127c52a`.** `cd` there and confirm with `git branch --show-current` before any git command. **The primary checkout at `/Users/moritz/Projects/pensieve` is on `siri-answering-intents` and is being committed to by another session — never run git there, never edit files there.**
- **Use the `make` targets.** `make lint` · `make build` · `make test` · `make all` (= lint + test + build + smoke, CI's order). `make generate` is required **only** if a file is added or removed — Task 5 does not add one, so no `generate` is needed in this plan. **`swift run pensieve` / `swift run PensieveApp` do not exist.**
- **This slice has no automated coverage and the plan does not pretend otherwise.** `Sources/PensieveApp` is an Xcode app target outside `PensieveKitTests`; every change here is visual. The per-task cycle is therefore **lint → build → named visual check → commit**, not red-green-refactor. Do not write a test that asserts a view property equals the literal you just typed — that is the vacuous-test failure this project has shipped twice. The one exception is Task 5, which *is* covered, by `CatalogCoverageTests`.
- **`Localizable.xcstrings` is hand-authored** and `CatalogCoverageTests` checks **both directions**: a literal with no key renders English under German, *and* a key with no literal fails as dead weight. Task 5 depends on this.
- **Captured content is never localized** — transcript text, quotes, node names, loose-end text. Chrome is.
- **Name things explicitly — no abbreviations.** `message`, `segment`, `speaker`, `ordinal`. Not `msg`, `seg`, `sp`. (`msg` appears in existing signatures; do not rename existing parameters in this slice — match the call, don't widen the diff.)
- **SwiftLint `--strict`**: types nested at most 1 level deep, **400-line file cap** (no `file_length` override in `.swiftlint.yml`, so the default 400 *warning* fails a strict run).
- **Commits:** `git commit --no-gpg-sign` (TCC blocks the signing key from this shell). **Never push** — Moritz pushes.

---

## File Structure

**Modify only. No file is created or deleted in C1.**

| File | Lines now | Responsibility after |
|---|---|---|
| `Sources/PensieveApp/TranscriptSegmentView.swift` | 205 | One segment's look. Loses the harness fill; owns the compressed type scale. |
| `Sources/PensieveApp/TranscriptMessageView.swift` | 100 | One message. Gains the rail; owns the one-meaning bubble rule. |
| `Sources/PensieveApp/LooseEndRow.swift` | 387 | The row. Loses `role` from the meta line; `previewRow` stops hardcoding `compact`. |
| `Sources/PensieveApp/Localizable.xcstrings` | — | Loses the orphaned `"captured"` key. |

### The 400-line split is NOT performed in C1, and here is the measurement

The spec names `LooseEndRow+Provenance.swift` as a pre-agreed seam because `LooseEndRow.swift` sits at 387 of 400. **C1's measured delta to that file is −2 lines:** Task 5 removes the `let roleText = …` binding and folds its interpolation out of the `Text(…)`, and Task 4 changes one argument in place. The rail is added to `TranscriptMessageView`, not here. So the file ends at **385** and the cap is not at risk.

**Do not perform the split.** It is unnecessary work in this slice and would inflate the diff. The seam stays documented in the spec for C2/C3, which do add to this file. If an executor's implementation somehow pushes `LooseEndRow.swift` past 395, stop and report rather than improvising a different seam.

---

## Task 1: Compress the quoted type scale

A transcript H1 renders at 22pt against the detail pane's own 13pt section headers, making *quoted* content the second-largest text on screen. Six heading sizes become two: h1 15, h2–h6 14, all semibold, **margins unchanged**.

`Theme.basic`'s margins drive every inter-block gap in MarkdownUI — `BlockSequence` derives inter-block spacing from them, so dropping `.markdownMargin` collapses the space after a heading to zero. The existing code carries that comment; keep it true.

The six `.markdownBlockStyle` calls stay six calls. MarkdownUI exposes each heading as its own key path (`\.heading1` … `\.heading6`) with distinct types, so they cannot be looped; the repetition is the API's, not a smell to fix.

**Files:**
- Modify: `Sources/PensieveApp/TranscriptSegmentView.swift:178-201` (the six heading blocks inside `transcriptProse()`)

**Interfaces:**
- Consumes: nothing.
- Produces: nothing new. `transcriptProse()` keeps its signature `func transcriptProse() -> some View`.

- [ ] **Step 1: Read the current scale and confirm the starting values**

Run:
```bash
cd /Users/moritz/Projects/pensieve/.claude/worktrees/transcript-reading
grep -n 'FontSize(' Sources/PensieveApp/TranscriptSegmentView.swift
```

Expected: `FontSize(14)` on line 176 (the body, **leave it alone**), then `FontSize(22)`, `FontSize(18)`, `FontSize(16)`, `FontSize(15)`, `FontSize(14)`, `FontSize(14)` for h1–h6.

- [ ] **Step 2: Change h1 to 15 and h2–h4 to 14**

In `Sources/PensieveApp/TranscriptSegmentView.swift`, inside `transcriptProse()`, change **only** the `FontSize` values in the heading blocks. h5 and h6 are already 14 and need no edit.

```swift
      .markdownBlockStyle(\.heading1) {
        $0.label.markdownMargin(top: .rem(1), bottom: .rem(0.5))
          .markdownTextStyle { FontSize(15); FontWeight(.semibold) }
      }
      .markdownBlockStyle(\.heading2) {
        $0.label.markdownMargin(top: .rem(1), bottom: .rem(0.5))
          .markdownTextStyle { FontSize(14); FontWeight(.semibold) }
      }
      .markdownBlockStyle(\.heading3) {
        $0.label.markdownMargin(top: .rem(1), bottom: .rem(0.5))
          .markdownTextStyle { FontSize(14); FontWeight(.semibold) }
      }
      .markdownBlockStyle(\.heading4) {
        $0.label.markdownMargin(top: .rem(1), bottom: .rem(0.5))
          .markdownTextStyle { FontSize(14); FontWeight(.semibold) }
      }
```

- [ ] **Step 3: Update the doc comment above `transcriptProse()` so it does not lie**

The comment currently reads `/// The transcript type scale: h1 22 · h2 18 · h3 16 · h4-h6 15/14/14 semibold · body 14/ls 4.` Replace that first line with:

```swift
  /// The transcript type scale: h1 15 · h2-h6 14 semibold · body 14 / line-spacing 4. Two heading
  /// sizes, not six, and deliberately close to body size: a heading inside a QUOTED transcript is
  /// emphasis within the quote, not document structure. At MarkdownUI's defaults (h1 near 28 against
  /// 14pt body) it outranked the detail pane's own 13pt section headers, so captured content was the
  /// second-largest text on screen after the node name.
```

- [ ] **Step 4: Verify exactly two heading sizes remain (success criterion 4)**

Run:
```bash
grep -A2 'markdownBlockStyle(\\.heading' Sources/PensieveApp/TranscriptSegmentView.swift | grep -o 'FontSize([0-9]*)' | sort -u
```
Expected, exactly:
```
FontSize(14)
FontSize(15)
```

- [ ] **Step 5: Lint and build**

Run: `make lint && make build`
Expected: both succeed. SwiftLint silent.

- [ ] **Step 6: Commit**

```bash
git add Sources/PensieveApp/TranscriptSegmentView.swift
git commit --no-gpg-sign -m "fix(app): stop quoted headings outranking the app's own

A transcript H1 rendered at 22pt against the detail pane's 13pt section
headers, making captured content the second-largest text on screen after the
node name. Six heading sizes become two, close to body size, because a
heading inside a quote is emphasis within the quote and not structure."
```

---

## Task 2: The harness card loses its fill

Layer 3 of the three nested surfaces. The kind label, the monospace body, the `lineLimit(12)` cap and the highlighted-path `lineLimit` drop all stay — machine output stays distinguishable by label + monospace + secondary colour, which is what actually distinguishes it. The card was redundant with those, not load-bearing over them.

**`CalloutView` keeps its background.** That fill is severity chrome carrying meaning (orange = caution, accent = important), not a nesting surface. Do not touch it.

**Files:**
- Modify: `Sources/PensieveApp/TranscriptSegmentView.swift:80-112` (`HarnessCardView`)

**Interfaces:**
- Consumes: nothing.
- Produces: nothing. `HarnessCardView` keeps its `init(block:highlight:)` shape.

- [ ] **Step 1: Remove the fill and its padding from `HarnessCardView`**

The three trailing modifiers on the `VStack` currently read:

```swift
    .padding(8)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 6))
    .fixedSize(horizontal: false, vertical: true)
```

Replace with — dropping `.padding(8)` and `.background(…)`, keeping the other two:

```swift
    .frame(maxWidth: .infinity, alignment: .leading)
    .fixedSize(horizontal: false, vertical: true)
```

- [ ] **Step 2: Update the type's doc comment**

It currently says `/// A machine envelope, rendered as a quiet card so it reads as "the harness", not "a person".` Replace with:

```swift
/// A machine envelope. Reads as "the harness" rather than "a person" through its kind label,
/// monospace body and secondary colour — NOT through a fill. It had a gray card until C1, which made
/// it the third of three nested surfaces (provenance box → message bubble → this) all within 3% of
/// each other's opacity. The label is what tells the reader what the block is; the card only told
/// them there was a box.
```

- [ ] **Step 3: Confirm the callout's background survived**

Run:
```bash
grep -n 'background' Sources/PensieveApp/TranscriptSegmentView.swift
```
Expected: exactly one hit, the callout's `.background(callout.severity.tint.opacity(0.10), …)`. If `Color.secondary.opacity(0.07)` still appears, Step 1 was not applied.

- [ ] **Step 4: Lint and build**

Run: `make lint && make build`
Expected: both succeed.

- [ ] **Step 5: Commit**

```bash
git add Sources/PensieveApp/TranscriptSegmentView.swift
git commit --no-gpg-sign -m "fix(app): the harness envelope stops being a third gray card

Provenance box, message bubble and harness card were three fills within 3% of
each other's opacity, nested. This drops the innermost. Label, monospace and
secondary colour already say 'the harness'; the card only said 'a box'. The
callout keeps its fill, which carries severity rather than nesting."
```

---

## Task 3: Speaker identity moves to a rail, and the bubble means one thing

The substantive task. Two changes to one view that a reviewer would accept or reject together, because they interact: the rail supplies the leading structure that the old stacked caption provided, and the bubble rule decides which messages get a fill inside it.

- **The rail** — a fixed 58pt leading gutter carries the speaker; the content column carries the message. Non-compact only; compact keeps today's stacked caption because 58pt of a ~180pt column is not available.
- **The bubble** — `bubbled` goes from `!compact && speaker != .system` to `!compact && speaker == .you`. Claude renders as free prose. The bubble now says exactly *a person typed this*.

**The cited marker must not regress.** `ProvenanceQueries.swift:46` passes `requireUserPrompt: true` into `TranscriptWindow.slice`, so the cited message is always `isUserPrompt` ⇒ always `.you` ⇒ always bubbled in the wide pane. The existing overlay keeps working untouched. **The bar attaches to the content column, never to the rail** — which falls out of putting the overlay on `content`, not on the `HStack`.

**Do not write `Text("")` for a suppressed rail label.** An empty string literal at a `Text(…)` site is a localizing site as far as `CatalogCoverageTests` is concerned, and would demand a catalog key for the empty string. Use an empty `Group` with the fixed-width frame instead — it reserves the gutter without a literal.

**Files:**
- Modify: `Sources/PensieveApp/TranscriptMessageView.swift:36-85` (the `body` at `:36`, the `bubbled` property at `:84`)

**Interfaces:**
- Consumes: `SpeakerClass.of(_:segments:)` and `SpeakerClass.label` (both already exist, unchanged); `TranscriptSegmentView(segment:highlight:)`; `OptionalFindSite(anchor:find:)`.
- Produces: `TranscriptMessageView` keeps **exactly** its current member-wise signature — `init(message:segments:compact:showsRoleLabel:highlights:anchorForSegment:find:)`. Task 4 depends on that being unchanged.

- [ ] **Step 1: Add the rail width constant and split the body into `content` plus two layouts**

Replace the whole `body` and the `bubbled` property in `Sources/PensieveApp/TranscriptMessageView.swift` with:

```swift
  /// The rail's width. Fixed rather than intrinsic so every message's content column starts at the
  /// same x — an intrinsic width would make "You" and "Claude" indent their bodies differently, which
  /// is the misalignment the rail exists to remove.
  private static let railWidth: CGFloat = 58

  var body: some View {
    Group {
      if compact { stacked } else { railed }
    }
    .opacity(speaker == .system ? 0.75 : 1)
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityElement(children: .contain)
    .accessibilityLabel(speaker.label)
  }

  /// Wide layout: a fixed leading gutter carries the speaker, so the caption reads as attribution for
  /// the message instead of a caption on the box around it — which is what it was until C1, sitting
  /// outside the message bubble but inside the provenance card.
  private var railed: some View {
    HStack(alignment: .top, spacing: 12) {
      Group {
        if showsRoleLabel {
          Text(speaker.label)                     // chrome → localized, and already resolved
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
        }
      }
      // An empty Group still reserves the gutter, which is what keeps a suppressed caption from
      // shifting its content column. Deliberately NOT `Text("")`: an empty literal at a Text site is
      // a localizing site to CatalogCoverageTests and would demand a catalog key for "".
      .frame(width: Self.railWidth, alignment: .trailing)
      .padding(.top, 3)                           // optical alignment with the body's first line
      content
    }
  }

  /// Compact layout: today's stacked caption. The rail costs 58pt of a ~180pt usable column, so the
  /// middle column cannot have it.
  private var stacked: some View {
    VStack(alignment: .leading, spacing: 4) {
      if showsRoleLabel {
        Text(speaker.label)
          .font(.system(size: 11, weight: .semibold))
          .foregroundStyle(.secondary)
      }
      content
    }
  }

  /// The message's segments, with the bubble, the cited marker and the padding that pairs with them.
  /// Shared by both layouts so the marker cannot diverge between them.
  private var content: some View {
    VStack(alignment: .leading, spacing: 8) {
      ForEach(Array(segments.enumerated()), id: \.offset) { ordinal, segment in
        TranscriptSegmentView(segment: segment, highlight: highlights[ordinal])
          .modifier(OptionalFindSite(anchor: anchorForSegment?(ordinal), find: find))
      }
    }
    .padding(bubbled ? 10 : 0)
    // The unbubbled leading inset matches the bubble's own, so a bubbled and an unbubbled message
    // start their text at the same x — and it leaves the cited bar somewhere to sit.
    .padding(.leading, bubbled ? 0 : 10)
    .background {
      if bubbled {
        RoundedRectangle(cornerRadius: 12).fill(Color.secondary.opacity(0.10))
      }
    }
    .overlay {
      // The cited-provenance marker. `ProvenanceQueries.swift:46` passes `requireUserPrompt: true`
      // into `TranscriptWindow.slice`, so the cited message is ALWAYS the `.you` class — which since
      // C1 is also the only bubbled class, so the bar and the border always land together in the wide
      // pane. The bar is clipped in the bubble's coordinate space, so its ends follow the corner
      // curve instead of poking out square-cornered past the rounded border. It rides `content`, never
      // the rail: a bar through the speaker caption would read as marking the speaker, not the quote.
      if message.isCited {
        ZStack {
          if bubbled { RoundedRectangle(cornerRadius: 12).strokeBorder(.orange.opacity(0.5)) }
          Rectangle().fill(.orange).frame(width: 3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .clipShape(RoundedRectangle(cornerRadius: bubbled ? 12 : 0))
        }
      }
    }
    .fixedSize(horizontal: false, vertical: true)
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  /// One meaning, since C1: **a person typed this**. It was `speaker != .system` — the readability
  /// spec's pre-committed fallback, taken because trailing-aligned bubbles inside a `List` row were
  /// unverified — which bubbled You and Claude alike and so distinguished nothing.
  private var bubbled: Bool { !compact && speaker == .you }
```

- [ ] **Step 2: Delete the now-stale fallback comment**

The block comment above the old `bubbled` (`/// **Pre-committed fallback taken (spec §Risks).** …`) is replaced by the new doc comment in Step 1. Confirm it is gone:

```bash
grep -n 'Pre-committed fallback taken' Sources/PensieveApp/TranscriptMessageView.swift
```
Expected: no output.

- [ ] **Step 3: Lint and build**

Run: `make lint && make build`
Expected: both succeed. If SwiftLint reports `type_body_length` on `TranscriptMessageView`, stop and report — the file was 100 lines and should land near 150, well inside every cap.

- [ ] **Step 4: Verify on screen — this is the task's real test**

The app target has no unit tests, so the deliverable is verified by looking at it. Install and launch, then check the detail pane on a node whose loose ends have surviving transcripts:

```bash
make run
```

Confirm all five, and **write the outcome into the commit message**:
1. Speaker names sit in a left gutter, right-aligned, with every message's body starting at the same x.
2. Only *your* messages have a gray bubble; Claude's replies sit on the page.
3. The cited message still shows its orange leading bar **and** its tinted border.
4. A run of same-speaker messages shows the name once, and the gutter stays reserved for the rest.
5. The middle column (select a leaf node with open loose ends) is unchanged — stacked caption, no gutter, no bubbles.

If (3) fails, the pre-committed fallback from the spec applies: reinstate a hairline rule between messages and report — do not improvise a new marker.

- [ ] **Step 5: Commit**

```bash
git add Sources/PensieveApp/TranscriptMessageView.swift
git commit --no-gpg-sign -m "feat(app): the speaker gets a rail, and the bubble gets a meaning

The caption sat outside the message bubble but inside the provenance card, so
it read as a label on the box rather than attribution for the message. A fixed
58pt gutter carries it instead, and every body starts at the same x.

And the bubble means one thing now. It was 'not system', which bubbled You and
Claude alike and therefore distinguished nothing — the readability spec's own
pre-committed fallback, taken when trailing-aligned bubbles in a List row went
unverified. Now it is exactly '.you': a person typed this.

The cited marker rides the content column, never the rail, so the bar marks the
quote rather than the speaker. Verified on screen: <fill in Step 4's outcome>."
```

---

## Task 4: The collapsed preview joins the same layout mode

`previewRow` hardcodes `compact: true` regardless of the row's own flag, and it is the **default** state in the detail pane whenever `context.messages.count > 1`. So the same message renders compact when collapsed and railed when expanded — a layout jump on "Show more". The gutter is 58pt and the preview is one three-line segment, so it fits; consistency between two states of one disclosure is worth more than the width.

This is the one place C1 changes a call site rather than a view.

**Files:**
- Modify: `Sources/PensieveApp/LooseEndRow.swift:314-317` (`previewRow`)

**Interfaces:**
- Consumes: `TranscriptMessageView(message:segments:compact:)` from Task 3 — signature unchanged, which is why this is one argument and not a rewrite.
- Produces: nothing.

- [ ] **Step 1: Pass the row's own `compact` instead of hardcoding it**

```swift
  /// Collapsed preview: the cited message's first renderable segment, capped to a few lines.
  ///
  /// `compact` is the ROW's, not hardcoded `true`. It was hardcoded until C1, which meant the detail
  /// pane previewed a message in the compact layout and then re-rendered it railed on "Show more" —
  /// one disclosure, two layout modes, for the message that is collapsed by default whenever the
  /// window holds more than one.
  @ViewBuilder private func previewRow(_ message: ProvenanceMessage) -> some View {
    TranscriptMessageView(message: message, segments: previewSegments(for: message),
                          compact: compact)
      .lineLimit(3)
  }
```

- [ ] **Step 2: Confirm no other hardcoded `compact: true` remains in this file**

```bash
grep -n 'compact: true' Sources/PensieveApp/LooseEndRow.swift
```
Expected: no output. (`compact: compact` at `messageRow` is correct and stays.)

- [ ] **Step 3: Lint and build**

Run: `make lint && make build`
Expected: both succeed.

- [ ] **Step 4: Verify the jump is gone**

With the app running (`make run` if not already up), open a loose end in the detail pane whose provenance has more than one message — it opens collapsed. Confirm the preview already shows the rail and the bubble, and that clicking **Show more** adds messages *without* the first one shifting or changing shape.

- [ ] **Step 5: Commit**

```bash
git add Sources/PensieveApp/LooseEndRow.swift
git commit --no-gpg-sign -m "fix(app): stop the collapsed preview rendering in the other layout

previewRow hardcoded compact: true whatever the row's own value, and it is the
default state in the detail pane whenever the provenance window holds more than
one message. So the same message was compact collapsed and railed expanded — a
shape change on Show more, in the one state a reader sees first."
```

---

## Task 5: Delete the role field and the catalog key it was holding up

`LooseEndRow.swift:99` binds `view.looseEnd.role` and `:105` renders it into the meta line — untranslated, directly beneath a localized speaker caption. That is the slice-D "`Du` vs `user`" clash, and the rail makes it more prominent by promoting speaker identity.

The field is a constant. Measured: all 1,076 loose ends carry `role = "user"`, and structurally cannot carry otherwise — `LooseEndVerifier.swift:28` guards `message.isUserPrompt`, and `TranscriptParser.swift:45` sets `isUserPrompt` only for `type == "user"`.

**This task IS covered by a test**, unlike the other four. `String(localized: "captured")` on line 99 is the **only** use of that key, so removing the line orphans it — and `everyCatalogKeyIsRenderedBySomeLiteral` fails on a key with no literal just as `everyRenderedLiteralHasACatalogKey` fails on a literal with no key. The catalog entry goes in the same commit.

**Do not use the `allowedDeadKeys` escape hatch.** That list exists for keys reached through a runtime lookup, where the literal genuinely is not in the source. This key is reached from nowhere at all — the honest fix is deletion, and adding it to an allowlist would leave a German string in the catalog that nothing can ever render.

**The `LooseEnd.role` column is untouched.** This is a rendering change. The two CLI renderers that also print it (`Sources/pensieve/Commands/LooseEnds.swift:29`, `Status.swift:21`) are **deliberately left alone** — bundling a CLI change into an app-rendering slice is how slices grow; the spec records the temporary inconsistency.

**Files:**
- Modify: `Sources/PensieveApp/LooseEndRow.swift:98-111`
- Modify: `Sources/PensieveApp/Localizable.xcstrings` (remove the `"captured"` entry)

**Interfaces:**
- Consumes: `NodeMeta.separator`, `View.metaText()` — both already exist.
- Produces: nothing.

- [ ] **Step 1: Confirm the key really is orphaned before deleting it**

```bash
grep -rn '"captured"' Sources/ --include=*.swift
```
Expected: exactly one hit, `LooseEndRow.swift:99`. If there is a second, **stop** — the catalog entry must stay and only the meta-line use is removed.

- [ ] **Step 2: Remove the binding and the interpolation**

In `Sources/PensieveApp/LooseEndRow.swift`, the `if expanded {` block currently opens with a `let roleText = …` line. Delete that line, and drop `roleText` from the `Text(…)`:

```swift
      if expanded {
        VStack(alignment: .leading, spacing: 8) {
          provenanceBody
          // Was a hand-built `%lldd ago` whose catalog key said `%@d ago`, so it never matched and
          // rendered English inside a German window. Foundation formats the date instead — no
          // interpolated Int, no key, no way to mis-author it.
          //
          // The cited message's `role` used to lead this line. It was deleted in C1: all 1076 loose
          // ends carry "user" and structurally cannot carry otherwise (LooseEndVerifier guards
          // isUserPrompt), so it spent a word — untranslated, under a localized speaker caption —
          // restating what the rail already says and could never contradict.
          Text(view.occurredAt.formatted(.dateTime.year().month().day())
            + NodeMeta.separator
            + view.occurredAt.formatted(.relative(presentation: .named)))
            .metaText()
        }
```

- [ ] **Step 3: Run the catalog test and watch it FAIL**

This is the one place in the plan with a real red-green cycle, and it runs in this direction: the code change *creates* the failure, and deleting the key fixes it.

Run: `make test FILTER=everyCatalogKeyIsRenderedBySomeLiteral`
Expected: **FAIL**, naming `captured` as a catalog key with no corresponding Swift literal.

If it PASSES, stop and report — it means the coverage test does not check the orphan direction after all, and this task's premise (and the spec's) needs revisiting.

- [ ] **Step 4: Delete the orphaned catalog entry**

Remove the whole `"captured"` object from `Sources/PensieveApp/Localizable.xcstrings` — the key, its `extractionState`, its `localizations` with the German `"erfasst"`, and the trailing comma placement left valid. It sits between `"capture…"` neighbours; the entry is:

```json
    "captured" : {
      "extractionState" : "manual",
      "localizations" : {
        "de" : {
          "stringUnit" : {
            "state" : "translated",
            "value" : "erfasst"
          }
        }
      }
    },
```

- [ ] **Step 5: Confirm the JSON is still valid and the test goes green**

```bash
jq . Sources/PensieveApp/Localizable.xcstrings > /dev/null && echo "valid JSON"
make test FILTER=everyCatalogKeyIsRenderedBySomeLiteral
```
Expected: `valid JSON`, then PASS. (`plutil -lint` does NOT work on `.xcstrings` — it rejects the file outright, even renamed to `.json`. `jq` is installed at `/opt/homebrew/bin/jq`.)

- [ ] **Step 6: Full suite, lint, build**

Run: `make all`
Expected: green. (`make all` runs the whole suite, so it also proves nothing else depended on the key.)

- [ ] **Step 7: Verify on screen**

With the app running, expand a loose end. The meta line reads date + relative date — `14 Aug 2026 · 9 days ago` — with no leading `user`. Switch the app to German and confirm the line is fully German with no English fragment where `user` used to be.

- [ ] **Step 8: Commit**

```bash
git add Sources/PensieveApp/LooseEndRow.swift Sources/PensieveApp/Localizable.xcstrings
git commit --no-gpg-sign -m "fix(app): drop a meta-line field that could only ever say one thing

The meta line led with the cited message's raw role, untranslated, directly
under a localized speaker caption — two labels for one speaker, and the rail
makes that clash louder by promoting identity. It is also a constant: all 1076
loose ends carry \"user\", and structurally cannot carry otherwise, since the
verifier only accepts a message that isUserPrompt.

Deleting the line orphans the \"captured\" catalog key, which CatalogCoverage
fails on in that direction too, so the entry goes with it. The LooseEnd.role
column is untouched — this is rendering. The two CLI renderers still print it;
that inconsistency is recorded in the spec rather than fixed here."
```

---

## Task 6: Whole-slice verification against the spec's criteria

C1 carries no automated coverage, so the verification pass **is** the deliverable's proof. Record the outcome in a file rather than in a chat message, because the spec's criteria are what a future reader will check against.

**Files:**
- Create: `docs/superpowers/verify/2026-08-24-transcript-reading-c1-human-verify.md`

**Interfaces:**
- Consumes: everything from Tasks 1–5.
- Produces: the verification record referenced when C1 is marked done in `backlog.md`.

- [ ] **Step 1: Run the full gate**

```bash
make all
make uitest
```
Expected: `make all` green. `make uitest` green — it does not cover this slice (the fixture writes no transcript, which is why C2 has to build one), but a regression in the nine existing tests would matter.

- [ ] **Step 2: Confirm the file-length criterion with a number, not a hope**

```bash
wc -l Sources/PensieveApp/LooseEndRow.swift Sources/PensieveApp/DetailView.swift Sources/PensieveApp/TranscriptMessageView.swift Sources/PensieveApp/TranscriptSegmentView.swift
```
Expected: `LooseEndRow.swift` at **385** (was 387), every file under 400. If `LooseEndRow.swift` is over 395, stop and report rather than improvising a split.

- [ ] **Step 3: Walk the matrix**

Five rendering sites × two languages × collapsed and expanded. Switch language via System Settings and relaunch with `make run`.

| Site | How to reach it |
|---|---|
| Detail pane | select a node with open loose ends, expand one |
| Closed record | same node, expand **Completed** |
| Leaf's own loose ends | select a childless leaf in the tree |
| Review Suggestions | sidebar ▸ Review Suggestions |
| Search results | ⌥⌘F, query a word you know is in a quote |

- [ ] **Step 4: Write the record**

Create `docs/superpowers/verify/2026-08-24-transcript-reading-c1-human-verify.md` with one line per spec criterion — **pass, fail, or fallback-taken**, and for anything not verifiable by a harness, say what you actually looked at:

```markdown
# C1 human-verify — 2026-08-24

Spec: `specs/2026-08-24-transcript-reading-c1-design.md`. Branch `worktree-transcript-reading`.

| # | Criterion | Outcome | How checked |
|---|---|---|---|
| 1 | At most one fill nests, and only for `.you` | | read the diff + detail pane at 1400pt |
| 2 | Bubble iff `.you` and not compact | | detail pane vs middle column |
| 3 | Cited marker preserved | | both widths, both languages, collapsed + expanded |
| 4 | `transcriptProse()` defines exactly two heading sizes | | `grep` from Task 1 Step 4 |
| 5 | Preview and expanded render the same layout mode | | Show more on a multi-message window |
| 6 | `make all` green, `--strict` clean, no file over 400 | | `make all`; `wc -l` |
| 7 | Middle column still works at ~180pt | | leaf node, both languages |

## Defects found
## Fallbacks taken
## Not verifiable by any existing harness
Heading point sizes and background fills have no AX identity, so 1, 2 and 4 are
diff-read plus eyeball rather than machine-checked. C2's fixture work is the
prerequisite for automating any of it.
```

- [ ] **Step 5: Commit**

```bash
git add docs/superpowers/verify/2026-08-24-transcript-reading-c1-human-verify.md
git commit --no-gpg-sign -m "docs: record C1's verification against the spec's criteria

The slice touches only the app target, which has no unit tests, so the
verification pass is the proof rather than a formality. Records which criteria
a harness cannot reach and why, so a later reader does not mistake an eyeball
check for coverage."
```

---

## Self-Review

**Spec coverage.** Decision 1 (rail) → Task 3. Decision 2 (bubble) → Task 3. Decision 3 (two fills die) → Task 2 for layer 3, Task 3 for layer 2-on-Claude. Decision 4 (type scale) → Task 1. Decision 5 (`role`) → Task 5. "One nested fill survives" → Task 6 criterion 1. The six-call-site table's `previewRow` decision → Task 4. Criterion 6's split → resolved by measurement in *File Structure* and re-checked in Task 6 Step 2. Risks' fallbacks → named at Task 3 Step 4. Nothing in the spec is unassigned.

**Placeholders.** None. Every code step carries the actual code; every verification step carries the command and its expected output. The one `<fill in …>` is Task 3's commit message, which is a deliberate instruction to record a real observation rather than a placeholder for the plan.

**Type consistency.** `TranscriptMessageView`'s member-wise init is unchanged by Task 3 and Task 4 relies on that — stated in both tasks' Interfaces blocks. `railWidth` is declared and used only in Task 3. `content`, `railed`, `stacked` are introduced together in one step. `previewRow`'s parameter is renamed `msg` → `message` inside Task 4's own body only, which is local and does not affect its two callers' argument labels (it is an unlabelled positional parameter at `previewRow(cited)`).

**One deviation from the spec, recorded deliberately:** the spec says C1 "adds to `LooseEndRow`" and pre-commits a split. Measured, C1 *removes* two lines from it. The split is therefore not performed; see *File Structure*.
