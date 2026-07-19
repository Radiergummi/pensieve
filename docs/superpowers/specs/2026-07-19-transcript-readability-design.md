# Transcript readability — chat rendering, harness-tag vocabulary, type scale

**Date:** 2026-07-19
**Status:** design, revised after two adversarial reviews + a corpus re-measurement
**Scope:** sub-project #1 of 3 split out of one dogfooding report. Siblings (rich code blocks;
Writing Tools) are parked in `backlog.md` → "Transcript rendering — deferred siblings".

**Revision note.** The first draft was reviewed by two independent Opus agents (parser-safety and
integration lenses), producing 3 Critical and ~10 Important findings. Re-measuring the corpus then
invalidated the evidence base of the draft *and* of both reviews — see §Corpus evidence. This
document is a rewrite, not a patch.

**Revision 2 (2026-07-19).** A third review, verified against the code rather than the document,
found: **(C1)** the "one shared vocabulary constant" would have given the renderer a write path into
`isUserPrompt` and therefore into loose-end extraction and the trust gate — split into two members
(§Prior art); **(I1)** three `LooseEndRow` call sites, not two; **(I2)** the `.searchScopes`
precedent in `RootView.swift:34-37` shows the Kit/app split is insufficient mitigation on its own —
Part 2 now pre-commits fallbacks (§Risks); **(m1)** test baseline 448 → 465; **(m2)** `role` is not a
closed set, so speaker classification needs an explicit fallback. Separately, `CalloutSeverity` was
narrowed 6 → 3 cases on this document's own corpus evidence.

## Problem

The inline provenance view renders a Claude Code transcript window as a flat list. Every message —
typed by the user, written by Claude, or injected by the harness — gets the same treatment: a raw
lowercase role caption, `Markdown(msg.text)` at `FontSize(14)`, and `opacity(0.7)` when
`!isUserPrompt` (`LooseEndRow.swift:156-170`).

1. **Role labels** are tiny, lowercase, unlocalized, impersonal.
2. **XML-ish tags render raw** — `<HARD-GATE>`, `<command-name>`, `<task-notification>` appear as
   literal angle brackets mid-prose.
3. **Heading scale is too loud** — MarkdownUI's defaults put `h1` near 28pt against 14pt body.
4. Code blocks unhighlighted, diagrams unrendered — **deferred, see backlog.**

## Corpus evidence

**Methodology matters more than the numbers, because the first draft got this wrong twice.**

The draft grepped `~/.claude/projects/*/*.jsonl` — a single-level glob matching **898 of 5124**
files, i.e. 17.5% of the corpus. Both adversarial reviews then re-grepped recursively and produced
different (larger) numbers, but still over **raw JSONL**, which counts tag text inside
`toolUseResult`, thinking blocks, and tool *inputs* — none of which reach the parser.

`TranscriptParser.extractText` (`TranscriptParser.swift:59-65`) surfaces only `message.content`,
either as a string or the `{type:text}` blocks joined by newlines. The numbers below were produced
by decoding every line with `jq` and reproducing exactly that extraction — **the text the parser
actually receives**. Any future re-measurement must use this method.

**Consequence: the callout feature was designed around tags that barely exist in parser input.**

| Tag | Raw JSONL (misleading) | **Parser-visible** |
|---|---|---|
| `SUBAGENT-STOP` | 1785 open | **1 open / 3 close** |
| `EXTREMELY-IMPORTANT` | 1785 open | **1 open / 3 close** |
| `EXTREMELY_IMPORTANT` | 1784 open | **0 open / 2 close** |
| `HARD-GATE` | 200 open | **154 open / 150 close** |
| `<string>` (code content) | 12210 | **132** |
| `<span>` (code content) | 2711 | **60** |

`EXTREMELY-IMPORTANT` and `SUBAGENT-STOP` live in system-prompt/skill-injection channels that never
become `message.content`. Only `HARD-GATE` is genuinely present, because the brainstorming skill
body *is* delivered as a user message.

**Orphan closing tags are the dominant shape, not an edge case.** In parser-visible text the true
orphans are `</FUTURE-SKILL-TAG>` 8, `</SUBAGENT-STOP>` 2, `</TAG>` 2, `</HARD_GATE>` 1 — and
`SUBAGENT-STOP` has *more closes than opens*. A design that only handles matched pairs and unmatched
*opens* mishandles the commonest real case.

**Harness tags, parser-visible:**

| Tag | Count | | Tag | Count |
|---|---|---|---|---|
| `task-notification` | 969 | | `local-command-caveat` | 457 |
| `tool_uses` | 759 | | `system-reminder` | 157 |
| `command-name` | 649 | | `local-command-stdout` | 124 |
| `command-message` | 638 | | `bash-input` / `bash-stdout` | 23 / 23 |
| `command-args` | 532 | | `local-command-stderr` / `tool_use_error` | 3 / 2 |

`<summary>` 958 against `task-notification` 969 is near 1:1, so summary is overwhelmingly a child of
the envelope rather than standalone HTML. (The reviews claimed summary *outnumbers*
task-notification; that holds only in raw JSONL.) Child-scoping is still specified below as a
defensive measure, but it is not the urgent hazard the reviews described.

**Code-content collision is real but ~100× smaller than the draft claimed**: `<string>` 132,
`<span>` 60, `<code>` 25. The allowlist discipline stands; the justification is proportionate now.

## Prior art in the codebase — reuse, don't duplicate

`TranscriptParser.isInjectedOrCommand` (`TranscriptParser.swift:81-92`) **already** maintains an
envelope marker list, and it is a superset of the draft's allowlist:

```
<command-name> <command-message> <command-args> <local-command-stdout> <local-command-stderr>
<bash-input> <bash-stdout> <system-reminder> <task-notification> </tool_uses> <subagent
"[Request interrupted"  "Base directory for this skill:"
"Caveat: The messages below were generated by the user while running local commands"
```

Two consequences, both binding on this design:

- **One source of truth — but two members, not one list.** A single flat constant shared verbatim
  between the two consumers is **unsafe**, for two independent reasons.

  *The shapes are not the same concept.* The marker list is not a tag list: `</tool_uses>` is a
  closing tag only, `<subagent` is a prefix, and `[Request interrupted` / `Caveat: The messages
  below…` are prose. `TranscriptMarkup` needs **open-tag names** to scan forward from; feeding it
  these entries is meaningless, and reshaping the list to suit the parser changes the gate.

  *And `isInjectedOrCommand` is upstream of the trust gate.* It gates `isUserPrompt`, which gates
  `LooseEndExtractor.swift:42` (what is eligible to become a loose end at all) and
  `LooseEndVerifier.swift:28` (`guard m.isUserPrompt else { return nil }`). A shared mutable list
  means a tag added for **rendering** silently changes **which loose ends are extractable** — the
  exact drift the sharing was meant to prevent, pointed the wrong way. This spec asserts the trust
  gate is untouched; that assertion is only true if the renderer has no write path into extraction.

  **Therefore:** a `TranscriptVocabulary` enum with two explicit members —
  `harnessTagNames: [String]` (bare names, parser input) and `injectionMarkers: [String]` (gate
  input: derived from `harnessTagNames` where derivable, explicit where not) — plus a Kit test
  pinning that every `harnessTagNames` entry has corresponding gate coverage. Non-drift without
  coupling. **`injectionMarkers` must stay byte-identical to today's list** at merge; any change to
  it is a trust-gate change and out of scope for this feature.
- **`local-command-caveat` is matched upstream as prose**, not as a tag — via the literal "Caveat:
  The messages below…". The tag form does exist in parser input (457), so both forms must be
  recognized.

## Decisions

From brainstorming: (1) machine envelopes are a **third visual class**, not user bubbles;
(2) **keyword severity** for callouts; (3) placeholders as monospace runs; (4) **all harness kinds
bespoke**; (5) type scale **moderate** (22/18/16 on 14pt body); (6) role label **on speaker change**,
small and subtle; (7) **approach A** — tested Kit parser, thin views.

Added after review 1: (8) **the work splits into two sequenced parts** at the Kit/app seam;
(9) success criteria are **rescoped** to what is actually reachable.

Added after review 2: (10) the harness vocabulary is **two members, not one list**, so rendering
cannot reach the trust gate; (11) `CalloutSeverity` ships **3 cases**, grown on evidence;
(12) Part 2 **pre-commits fallbacks** for its two unprovable visual claims.

## Part 1 — `TranscriptMarkup` (PensieveKit, tested)

**New file:** `Sources/PensieveKit/Transcript/TranscriptMarkup.swift`. No changes to
`ProvenanceQueries`, the stores, extraction, or the trust gate.

### Types

Every case carries `raw` — the exact source substring — which is what makes the no-loss invariant
executable rather than aspirational (see I2).

```swift
public enum TranscriptSegment: Equatable, Sendable {
  case markdown(String)                       // raw == the string itself
  case callout(TranscriptCallout)
  case harness(HarnessBlock)

  public var raw: String { … }                // exact source text of this segment
}

public struct TranscriptCallout: Equatable, Sendable {
  public let severity: CalloutSeverity
  public let tagName: String    // verbatim, e.g. "HARD-GATE" — CONTENT, never localized
  public let body: String       // markdown; rendered per I5
  public let raw: String
}

public enum CalloutSeverity: String, Equatable, Sendable {
  case caution, important, neutral   // closed set → localizable chrome
}

public enum HarnessBlock: Equatable, Sendable {
  case command(name: String, message: String?, args: String?)
  case taskNotification(TaskNotificationBlock)
  case systemReminder(String)
  case commandCaveat(String)
  case commandOutput(String)          // local-command-stdout / stderr
  case bashIO(input: String?, output: String?)
  case toolUses(String)
  case interrupted                    // "[Request interrupted…"
  case skillPreamble(path: String)
  case unknown(tag: String, body: String)   // allowlisted-shape but unrecognised

  public var raw: String { … }
}

public struct TaskNotificationBlock: Equatable, Sendable {
  public let taskID, toolUseID, outputFile, status, summary, note: String?
  public let unrecognisedChildren: [String: String]   // nothing is silently dropped
  public let raw: String
}
```

### Parse algorithm

**A single left-to-right scan in which the outermost construct wins.** The draft's numbered rule
list implied a multi-pass pipeline, which review showed to be self-contradictory: harness-before-
callout splits a callout containing a `<system-reminder>` into two unpaired fragments, both then
demoted to raw text, and the callout vanishes.

At each position, in this precedence:

1. **Code (highest).** A fenced block or inline code span consumes to its close and emits
   `.markdown` verbatim. **CommonMark rules, pinned:** an opening fence is ≥3 identical `` ` `` or
   `~` with ≤3 leading spaces; it closes only on ≥N of the *same* character; an unterminated fence
   runs to end of message. 4-space-indented code blocks are **also** protected — MarkdownUI renders
   them as code, so transforming them would violate I3 from the reader's point of view even if not
   by its letter.
2. **Callout open** — a paired ALL-CAPS tag, matched forward to the **nearest** matching close in
   the same message. Its interior is emitted per I5.
3. **Harness open** — an allowlisted tag, matched forward to its nearest close.
4. **Placeholder** — an ALL-CAPS tag that is not an open of a matched pair (see guards below).
5. **Orphan close** — `</ANYTHING>` with no open. Treated exactly like a placeholder: rendered as a
   monospace run, never as markup, never paired backwards. Backward scanning is **forbidden**: an
   orphan close pairing with a distant earlier open would swallow unrelated content, which is
   precisely the failure I4 exists to prevent.
6. **Otherwise** — accumulate into `.markdown`.

`task-notification` children (`task-id`, `tool-use-id`, `output-file`, `status`, `summary`, `note`)
are recognised **only within** a matched `<task-notification>`…`</task-notification>` span, never at
top level. Unrecognised children are preserved in `unrecognisedChildren`.

### Placeholder guards

The rewrite `<NAME>` → `` `NAME` `` is **suppressed** when the immediately preceding character is an
identifier character, `(`, or `[`. This kills two real hazards in one predicate:

- **Swift generics in prose** — `Optional<NSError>` must not become `` Optional`NSError` ``. These
  are Swift-project transcripts; this is common, not theoretical.
- **Link destinations** — `[docs](<PROJECT>/readme)` must not get a code span inside a destination.

Inline-span detection pairs backticks left-to-right; a trailing unbalanced backtick protects
nothing. A placeholder adjacent to existing backticks must not produce unbalanced delimiters.

### Severity mapping — token-based, not substring

The tag name is split on `[-_]` and keywords are matched against **whole tokens**. Substring
matching produces wrong severities on real names: `GATE` would fire `.caution` inside
`AUTHGW_RESOLVE_KEY_URL`, `STOP` inside `NON-STOP`, `TIP` inside `MULTIPLE-TIPS`.

| Severity | Tokens | Known |
|---|---|---|
| `.caution` | `STOP` `GATE` `CRITICAL` `DANGER` `NEVER` `WARNING` `CAUTION` | `HARD-GATE` (154), `SUBAGENT-STOP` (1) |
| `.important` | `IMPORTANT` `MUST` `REQUIRED` | `EXTREMELY-IMPORTANT/_IMPORTANT` (1) |
| `.neutral` | fallback | everything else, incl. future tags |

Precedence is table order; first match wins. `-` and `_` are equivalent.

**Three cases, not six — YAGNI applied to our own evidence.** The draft specified `.warning`,
`.tip`, and `.note` alongside these. Parser-visible counts justify none of them: the corpus contains
exactly one meaningfully-present callout tag (`HARD-GATE`), and the other two known names appear
once each. Shipping six severities means four with zero instances — four sets of colors, icons, and
localized labels designed against no evidence, all of which must be maintained and eyeballed in two
languages. `.warning` folds into `.caution` (same visual register); `.tip`/`.note` fold into
`.neutral`. The enum is the cheap thing to grow: adding a case later is additive, exhaustive
`switch`es make every render site a compile error until handled, and the token table is one row.
Grow it when a real tag appears, not before.

### Invariants

- **I1 — Passthrough.** Input with no recognised construct returns `[.markdown(input)]`,
  byte-identical.
- **I2 — No loss, executable.** `segments.map(\.raw).joined() == input`, with **one** documented
  exception: the placeholder rewrite, whose exact output shape is pinned by its own test. Because
  every case carries `raw`, this is a literal property test rather than an aspiration. *This is the
  load-bearing invariant: it makes "the parser ate my message" a test failure.*
- **I3 — Code is sacred.** No transformation inside fenced blocks, inline spans, or 4-space-indented
  blocks.
- **I4 — Unmatched tolerance.** An unmatched open **or close** stays inert and never swallows to
  end-of-message. Justified by 4 unmatched `HARD-GATE` opens and 13 orphan closes in parser input.
- **I5 — Flat nesting.** A callout body renders as markdown only; harness tags inside a callout are
  not recursively parsed. Deliberate.

## Part 2 — Rendering (app, thin)

Depends on Part 1 being merged and green.

### Speaker classification — conjunctive, not disjunctive

The draft quoted `isUserPrompt` incorrectly. The real definition (`TranscriptParser.swift:43-44`):

```swift
let isUserPrompt = (type == "user") && !isMeta && !isToolResult(content)
  && !isInjectedOrCommand(text) && !text.isEmpty
```

`isInjectedOrCommand` is a bare `text.contains(marker)`. **A genuine user message that merely
*quotes* an envelope therefore already scores `isUserPrompt == false`** — 309 such `"type":"user"`
records exist in this project's transcripts alone, because debugging this very feature means pasting
envelopes into chat.

Under the draft's disjunctive rule (`system ← !isUserPrompt OR …`) those messages would render as
full-width "not a person talking" strips — **the app asserting the user did not write something they
did write**, an inversion of Decision 1's own principle. Today the cost is only `opacity(0.7)`.

```
system  ←  !isUserPrompt  AND  the parse yields no non-empty .markdown or .callout segment
you     ←  role == "user" and not system
claude  ←  role == "assistant"
system  ←  any other role (fallback)
```

A pasted envelope surrounded by human prose keeps its user bubble; a purely injected envelope still
classifies as system.

**The fallback is load-bearing, not defensive boilerplate.** `role` is
`(message?["role"] as? String) ?? (type ?? "unknown")` (`TranscriptParser.swift:34`), so it is **not**
a closed set — it can be `"unknown"`, `"system"`, or any future `type` value. Today `previewRow`
renders `Text(msg.role)` raw, so an unexpected value degrades to a stray caption; under a three-class
bubble layout an unhandled role has no branch to land in. Unknown roles classify **system** — the
honest reading, since we cannot assert a person wrote something whose role we cannot identify.

### Both row states are in scope

`LooseEndRow` renders two paths, and the draft only addressed one:

- `messageRow` (`:156`) — expanded, uses `Markdown`.
- `previewRow` (`:146`) — **the collapsed default** whenever `ctx.messages.count > 1`
  (`:81-87`), and it renders raw `Text(msg.text)`, not Markdown. Tags appear as literal brackets
  here regardless of anything done to `messageRow`.

`previewRow` renders the first `.markdown` segment (or a callout's severity label) at `lineLimit(3)`
with the same mapped role label.

### Three call sites at two very different widths

`LooseEndRow` has **three** instantiations, not the two the draft listed:

| Site | Column | Width |
|---|---|---|
| `ContentListView.swift:145` (search results) | middle | `min 240 / ideal 300 / max 420` |
| `ContentListView.swift:160` (node loose ends) | middle | same |
| `DetailView.swift:67` | detail | `min 360 / ideal 800`, no max |

The middle column is clamped by `RootView.swift:29-33`. Net of padding, ~180pt is usable — bubbles
and 22pt headings do not work there, and left/right alternation carries no information.

The `compact: Bool` threading below must reach **all three** sites; the draft's "two consumers"
framing would have left `DetailView` unspecified.

`LooseEndRow` takes a `compact: Bool`. Compact keeps today's full-width stack with the new parsed
rendering (callouts, harness cards, chips, type scale) but **no bubbles**. Bubble max width is
`0.95 × min(container, Prose.measure)` so it stays sane in a wide detail pane too.

### The cited highlight — specified per class

`ProvenanceQueries.swift:50-52` hard-guards `citedMessage.isUserPrompt`, so **the cited message is
always a user prompt** ⇒ always the "you" class ⇒ always a *trailing*-aligned bubble. Today's marker
is a leading `.overlay` + `.padding(.leading, 10)` (`:163-166`), which has no leading edge to attach
to. The sacred invariant had nowhere to land in the draft.

| Class | Cited treatment |
|---|---|
| you (trailing bubble) | trailing accent bar inside the bubble + tinted border |
| claude (leading bubble) | leading accent bar, as today |
| system (strip) | leading accent bar |

All three are separate eyeball-checklist items.

### Type scale

Via `.markdownBlockStyle(\.heading1…6)`. Verified against the vendored 2.4.1 checkout: styles exist
for `heading1…6`, `paragraph`, `blockquote`, `codeBlock` (`Theme.swift:127-169`); there is **no**
native GitHub-alert support, so callouts are hand-drawn; `BlockStyle<CodeBlockConfiguration>`
(`:169`) is the seam deferred syntax highlighting will use.

h1 22 · h2 18 · h3 16 · h4–h6 15/14/14, all semibold · body 14 regular, lineSpacing 4.

### Placeholders render as tinted monospace runs, not pills

`.markdownTextStyle(\.code)` composes `FontFamilyVariant(.monospaced)`, `FontSize`, and
`BackgroundColor` (`TextStyle/Styles/BackgroundColor.swift:4`). `TextStyle` emits `AttributedString`
attributes only, so the background is a **flat rectangle behind the glyphs** — no corner radius, no
padding. A rounded pill is unreachable through this API; "chip" in the brainstorm meant the pill, so
this is a deliberate, recorded downgrade. Real pills would require lifting placeholders into inline
views, which the block-level segment model does not support.

Consequence: a placeholder and genuine inline code look identical. Accepted — both are tokens, and
the alternative is a sentinel that could collide with content.

### Localization

**Severity labels are localizable chrome** (closed enum: "Caution"/"Achtung", "Important"/"Wichtig").
**Tag names are content** and render verbatim, unlocalized, as a secondary token. The draft claimed
callout *titles* were localized while also deriving them from arbitrary tag names — those cannot both
be true, since a String Catalog key cannot exist for a tag invented next month.

Harness block labels and role display names are chrome and localized; message text, quotes, command
names, and task summaries are content and are not.

**CLAUDE.md:** the roles-are-never-localized text sits at line 22 *inside a historical
shipped-feature bullet*, not in a rules section — so it is **not edited**. The clarification is
recorded in this feature's own status bullet when it ships. Precedent already exists in shipped code:
`LooseEndRow.swift:54` uses `String(localized: "captured")` as a role display fallback, so
role-derived display chrome is localized today.

### Accessibility

`.accessibilityElement(children: .contain)` with an `accessibilityLabel` naming only the class
("You"/"Claude"/"System"), leaving segments as navigable children. Labelling the container with the
full text would either compose unpredictably over MarkdownUI's view tree or, with `.ignore`, flatten
a multi-segment message into one unnavigable string — losing per-paragraph rotor navigation that
today's flat `Markdown(msg.text)` provides.

### Parsing happens once, not memoized

Parse all messages where `context` is assigned (`LooseEndRow.swift:69`) into a parallel array held in
the same `@State`. No cache key, no invalidation, no cross-session collision — `ProvenanceMessage.index`
is per-session, so a shared index-keyed cache could serve session A's segments for session B.

### Shared container modifiers

All three segment views share one modifier set — `.fixedSize(horizontal: false, vertical: true)` and
`.frame(maxWidth: .infinity, alignment: .leading)`. A `CalloutView` missing `.fixedSize` truncates
vertically inside `ContentListView`'s `List`. Intra-message segment spacing: 8pt; between bubbles
8pt; across a speaker change 16pt.

## Testing

**Part 1 (Kit)** — `Tests/PensieveKitTests/TranscriptMarkupTests.swift`, ~28 cases:

- I1 passthrough; **I2 as a property test** (`segments.map(\.raw).joined() == input`) over a mixed
  fixture, plus the pinned placeholder-rewrite exception.
- I3: fences of length 3 and 4; `~~~`; ≤3-space-indented; 4-space-indented block; unterminated fence;
  a tag inside each.
- I4: unmatched `<HARD-GATE>` open; bare `</FUTURE-SKILL-TAG>` orphan close; `</TAG>`.
- Nearest-match pairing; explicit test that an orphan close does **not** pair backwards.
- Callout containing a `<system-reminder>` → callout survives whole (I5 + outermost-wins).
- Placeholder guards: `Optional<NSError>`, `[docs](<PROJECT>/readme)`, backtick adjacency,
  unbalanced trailing backtick.
- `<summary>x</summary>` at top level → untouched; inside `task-notification` → a child; an
  unrecognised child lands in `unrecognisedChildren`.
- Command group: full trio, `command-name` alone, empty `command-args`.
- Severity: token vs substring (`AUTHGW_RESOLVE_KEY_URL → .neutral`, **not** `.caution` via a
  `GATE` substring inside `AUTHGW`; `NON-STOP → .neutral`); `-`/`_` equivalence; fallback.
- **Vocabulary split:** every `TranscriptVocabulary.harnessTagNames` entry has gate coverage, and
  `injectionMarkers` is byte-identical to the pre-change `isInjectedOrCommand` list — the test that
  makes a rendering-driven trust-gate change fail loudly.
- Skill preamble anchored with `hasPrefix`, not `contains` (mid-message occurrence → not a preamble).
- Empty message; tag-only message.

**Part 2 (App)** — no unit tests by convention. Verification is an enumerated matrix, written into
the plan: detail pane wide · detail pane at the 860pt min window · middle column at 240pt · recall
window at 480pt × {you, claude, system} × {cited, not cited} × {en, de}.

## Risks

- **Parser swallowing content** — mitigated by I2 as an executable property over `raw`.
- **Vocabulary drift** — mitigated by sharing one Kit constant with `isInjectedOrCommand`.
- **Allowlist staleness** — unknown tags fall through to `.unknown` / plain text; raw brackets
  reappearing is the signal to update. This is *designed* behaviour, which is why success criterion 1
  is scoped rather than absolute.
- **Segmentation splits markdown constructs** — an ordered list straddling a tag boundary restarts
  numbering. Accepted; these tags wrap whole blocks.
- **Text selection** — whole-message select-and-copy does not work today (no `textSelection` anywhere
  in the app, none in MarkdownUI), so segmentation regresses nothing. It does foreclose adding it
  later without a separate copy affordance.
- **Part 2 has no automated coverage** while being a full rewrite of the rendering path. The
  Kit/app split exists so the half that *can* be proven is proven independently. **This is not
  sufficient mitigation on its own** — see the precedent below.

### Precedent: SwiftUI declining an app-side visual claim

`RootView.swift:34-37` carries a comment from the semantic-recall-hardening batch:

> `.searchScopes` is deliberately NOT used — under `.sidebar` placement SwiftUI rendered the scope
> bar twice (sidebar + content column), overlaying content, and left it mounted after the field
> cleared. The plan's pre-committed fallback (a segmented Picker in the results header) is used
> instead.

That is a human-verify carry resolving **negatively**, and it is the closest structural analogue to
Part 2: an unprovable app-side visual claim that SwiftUI simply did not honor. What saved that batch
was not the Kit/app split — it was that the **plan named the fallback in advance**, so discovering
the problem cost a swap, not a redesign mid-execution.

**Therefore Part 2's plan must pre-commit a fallback for its two riskiest claims:**

| Claim | Risk | Pre-committed fallback |
|---|---|---|
| Trailing-aligned bubbles inside a `List` row | Bubble alignment/width inside `List` + `fixedSize` is unverified; the cited message is *always* this class (`ProvenanceQueries.swift:50`), so failure hits the sacred highlight | Full-width stack for all three classes (today's layout) + the new parsed rendering; class conveyed by role chip + background tint only |
| Trailing accent bar inside the "you" bubble | No leading edge to attach to; `.overlay(alignment:)` behavior inside a tinted rounded shape unverified | Tinted border on the bubble + the existing leading bar retained on the *row*, outside the bubble |

Both fallbacks preserve the cited highlight, which is the one thing that may not regress.

## Out of scope

Syntax highlighting, Mermaid/Graphviz rendering, Writing Tools — all in `backlog.md` with revisit
triggers.

## Success criteria

Rescoped: "zero raw angle brackets" is unreachable and contradicts the allowlist-staleness risk.

1. Every construct in the reported screenshot renders without raw angle brackets, **and** every tag
   in `TranscriptVocabulary.harnessTagNames` is handled. Tags outside it (`<result>`,
   `<subagent_tokens>`, `<duration_ms>`) are **known-unhandled** and recorded as such.
2. Nothing the user did not write is attributed to them; a message quoting an envelope keeps its
   user bubble; an unknown role classifies as system rather than as a person.
3. The cited-provenance highlight is preserved and specified for all three speaker classes.
4. `./scripts/test.sh` green at **465** + Part 1's ~28 Kit tests; `xcodebuild` clean; smoke launch
   survives. (465 is the measured baseline on `main` at 2026-07-19 — the draft's 448 predated the
   archived-semantic-index merge. CLAUDE.md's "window min 900×480" is likewise stale; the real floor
   is `860×480`, `PensieveApp.swift:32`.)
5. The verification matrix passes at all four widths in both languages — or a pre-committed fallback
   is taken and recorded, which counts as a pass.
6. `injectionMarkers` is unchanged, so `isUserPrompt` — and therefore loose-end extraction and the
   trust gate — behaves identically before and after. Verified by the vocabulary test, not by
   inspection.
