# Transcript readability — chat rendering, harness-tag vocabulary, type scale

**Date:** 2026-07-19
**Status:** design, awaiting approval
**Scope:** sub-project #1 of 3 split out of one dogfooding report. Siblings (rich code blocks;
Writing Tools) are parked in `backlog.md` → "Transcript rendering — deferred siblings".

## Problem

The inline provenance view renders a Claude Code transcript window as a flat list. Every message —
whether the user typed it, Claude wrote it, or the harness injected it — gets the same treatment:
a raw lowercase role caption, `Markdown(msg.text)` at `FontSize(14)`, and `opacity(0.7)` if
`!isUserPrompt`. All of it lives in one 15-line function, `messageRow` (`LooseEndRow.swift:156`).

Four concrete complaints from dogfooding:

1. **Role labels** are tiny, lowercase, unlocalized, impersonal.
2. **XML-ish tags render raw.** `<HARD-GATE>…</HARD-GATE>`, `<local-command-caveat>`,
   `<command-name>/clear</command-name>`, `<task-notification>` blocks all appear as literal angle
   brackets in the middle of prose.
3. **Heading scale is too loud.** MarkdownUI's default multipliers put `h1` near 28pt against 14pt
   body, so a skill doc's title dominates the pane.
4. Code blocks are unhighlighted and diagrams unrendered — **deferred, see backlog.**

## Corpus evidence

Measured across `~/.claude/projects/*/*.jsonl` before designing. This drove every detection rule.

**Paired ALL-CAPS tags** (open count == close count) — the semantic ones, and there are only four:

| Tag | Open | Close |
|---|---|---|
| `EXTREMELY-IMPORTANT` | 1786 | 1786 |
| `EXTREMELY_IMPORTANT` | 1786 | 1786 |
| `SUBAGENT-STOP` | 1786 | 1786 |
| `HARD-GATE` | 144 | **143** |

**Never-closed ALL-CAPS tags** — placeholders, not markup: `<UUID>` 255, `<VAR>` 169,
`<SECRET_NAME>` 62, `<REDACTED>`, `<PROJECT>`, `<DB_BACKUPS_PROJECT_ID>`, `<FOLDER_ID>`, `<TAB>`,
`<ORG>`, `<LIB>`. Zero closing tags for any of them.

**Lowercase tags** split into two very different groups. Harness envelopes:
`task-notification` 3224 (+ children `task-id`, `tool-use-id`, `output-file`, `status`, `summary`,
`note`), `command-name` 761, `command-message` 704, `command-args` 581, `local-command-stdout` 520,
`local-command-caveat` 464, `system-reminder` 462. And **code content that must never be touched**:
`<string>` 2077, `<name>` 1216, `<span>` 886, `<code>` 774, `<void>` 718, `<key>` 433.

Three conclusions:

- **Pairing separates placeholders from markup.** Placeholders never close.
- **Uppercase can stay open-ended** — pairing alone is a sufficient filter, so tags invented by
  future skills are handled without maintenance.
- **Lowercase must be an explicit allowlist.** That namespace collides with real code content;
  accepting arbitrary lowercase tags would eat `<string>` and `<span>` out of code samples.

## Decisions

Settled during brainstorming:

1. **Machine envelopes are a third visual class**, not user bubbles. Rendering an injected
   `<command-name>` as a right-aligned user bubble would assert the user said something they didn't.
2. **Callout severity by keyword heuristic**, with a neutral fallback.
3. **Placeholders render as monospace chips.**
4. **All six harness kinds get bespoke rendering.**
5. **Type scale: moderate** — h1 22 / h2 18 / h3 16 against 14pt body (down from ~28).
6. **Role label on speaker change only**, small and subtle.
7. **Approach A** — a tested Kit parser producing typed segments; thin app views.

## Architecture

```
ProvenanceMessage.text  ──▶  TranscriptMarkup.parse(_:)  ──▶  [TranscriptSegment]
   (raw transcript)            PensieveKit, pure, tested        │
                                                                ▼
                                                        MessageBubble (app, thin)
                                                        ├─ .markdown → Markdown(…) + theme
                                                        ├─ .callout  → CalloutView
                                                        └─ .harness  → HarnessBlockView
```

Parsing is pure PensieveKit and fully unit-tested; the app maps segments to views and owns styling
only. This follows the standing rule — derivation in tested Kit, views thin — and is the only
approach that supports bespoke structured cards.

**New Kit file:** `Sources/PensieveKit/Transcript/TranscriptMarkup.swift` (alongside the existing
`TranscriptParser.swift`). No changes to `ProvenanceQueries`, the trust gate, or any store.

### Types

```swift
public enum TranscriptSegment: Equatable, Sendable {
  case markdown(String)
  case callout(TranscriptCallout)
  case harness(HarnessBlock)
}

public struct TranscriptCallout: Equatable, Sendable {
  public let severity: CalloutSeverity
  public let title: String        // prettified: "HARD-GATE" → "Hard Gate"
  public let body: String         // markdown, rendered recursively as markdown only
}

public enum CalloutSeverity: Equatable, Sendable {
  case caution, warning, important, tip, note, neutral
}

public enum HarnessBlock: Equatable, Sendable {
  case command(name: String, message: String?, args: String?)
  case taskNotification(TaskNotificationBlock)
  case systemReminder(String)
  case commandCaveat(String)
  case commandOutput(String)
  case skillPreamble(path: String)
}

public struct TaskNotificationBlock: Equatable, Sendable {
  public let taskID: String?
  public let toolUseID: String?
  public let outputFile: String?
  public let status: String?
  public let summary: String?
  public let note: String?
}
```

### Parse rules, in order

1. **Protect code.** Fenced blocks (` ``` `, `~~~`) and inline code spans are located first and
   never transformed. Everything inside passes through as `.markdown` verbatim. This is what keeps
   `<string>` and `<span>` in code samples intact.
2. **Harness allowlist** (lowercase, exact names only): `task-notification`, the
   `command-name`/`command-message`/`command-args` group, `system-reminder`, `local-command-caveat`,
   `local-command-stdout`. A matched pair becomes `.harness`.
3. **Skill preamble** — the plain-text prefix `Base directory for this skill: <path>` becomes
   `.skillPreamble`. *Not tag-detected; the lowest-confidence rule in the design, isolated so it can
   be dropped without touching anything else.*
4. **Paired ALL-CAPS tags** (`<[A-Z][A-Z0-9_-]{2,}>` with a matching close) become `.callout`.
5. **Unpaired ALL-CAPS tags** are rewritten to inline code spans so they render as monospace chips.
6. **Everything else** stays `.markdown`, byte-identical.

### Severity mapping

Checked in this precedence order against the uppercased tag name; first match wins:

| Severity | Matches on | Known corpus tags |
|---|---|---|
| `.caution` | `STOP`, `GATE`, `CRITICAL`, `DANGER`, `NEVER` | `HARD-GATE`, `SUBAGENT-STOP` |
| `.warning` | `WARNING`, `CAUTION` | — |
| `.important` | `IMPORTANT`, `MUST`, `REQUIRED` | `EXTREMELY-IMPORTANT`, `EXTREMELY_IMPORTANT` |
| `.tip` | `TIP`, `HINT` | — |
| `.note` | `NOTE`, `INFO` | — |
| `.neutral` | fallback | any future tag |

Hyphen and underscore are equivalent, so `EXTREMELY-IMPORTANT` and `EXTREMELY_IMPORTANT` map
identically. Titles prettify by replacing separators with spaces and title-casing.

### Parser invariants (the safety contract)

The parser runs over arbitrary transcript text; a bug here could silently swallow captured content,
which matters more than any styling. Each invariant gets a test:

- **I1 — Passthrough.** Input containing no recognized construct returns exactly
  `[.markdown(input)]`, byte-identical.
- **I2 — No loss.** Reassembling every segment reproduces the input exactly, with **one documented
  exception**: the placeholder rewrite of rule 5 (`<NAME>` → `` `NAME` ``). That exception is pinned
  by its own test asserting the exact output shape, so it cannot widen silently. This is the
  load-bearing property; it makes "the parser ate my message" a test failure.
  *Edge case to cover:* a placeholder adjacent to existing backticks must not produce unbalanced
  code-span delimiters.
- **I3 — Code is sacred.** No transformation inside fenced blocks or inline code spans.
- **I4 — Unmatched tolerance.** An opening tag with no close stays plain text and never swallows to
  end-of-message. Directly motivated by the observed `HARD-GATE` 144/143 mismatch.
- **I5 — Flat nesting.** A callout body is rendered as markdown only; nested harness tags inside a
  callout are not recursively parsed in v1. Deliberate simplification, not an oversight.

## Rendering

### Speaker classification

Three classes, derived from the parse rather than the flag alone:

```
system  ← !isUserPrompt, OR the message body is entirely harness blocks
you     ← role == "user" and not system
claude  ← role == "assistant"
```

`isUserPrompt` is `(type == "user") && !isMeta && !isToolResult(content)`
(`TranscriptParser.swift:43`). A command envelope arriving without the meta flag would otherwise be
classified as *you*; folding the parse result into the decision makes the classification
self-correcting.

### Bubbles

- **You** — trailing-aligned, accent-tinted fill, max width 95% of the container.
- **Claude** — leading-aligned, neutral fill, same max width.
- **System** — no bubble. Full-width, centered, dimmed strip or card; the shape itself says
  "not a person talking".
- Corner radius 12, padding 10 vertical / 12 horizontal, 8 between bubbles, 16 across a speaker
  change.
- **The cited-message highlight survives unchanged** — the orange leading bar still marks
  `msg.isCited`. This is provenance, not decoration, and no restyling may drop it.
- Role label appears **only on the first bubble of a run**, 11pt secondary, aligned to the bubble's
  side.

### Harness block rendering

| Kind | Rendering |
|---|---|
| `command` | `⌘ /clear · clear` — glyph, command name, message when present. Missing `command-message`/empty `command-args` must not break the layout (`/simplify` appears with `command-name` alone). |
| `taskNotification` | Status dot + summary as the headline; output-file basename as a secondary line; ids demoted or hidden. |
| `systemReminder` | ⓘ label + prose. |
| `commandCaveat` | ⚠ label + prose. |
| `commandOutput` | Monospace block, visually a code block. |
| `skillPreamble` | Compact one-liner naming the skill. |

### Type scale

Applied via `.markdownBlockStyle(\.heading1…6)` — MarkdownUI 2.4.1 exposes styles for
`heading1…6`, `paragraph`, `blockquote`, `codeBlock` (verified in the vendored checkout; it has
**no** native GitHub-alert support, which is why callouts are drawn by us).

| Element | Size | Weight |
|---|---|---|
| h1 | 22 | semibold |
| h2 | 18 | semibold |
| h3 | 16 | semibold |
| h4–h6 | 15 / 14 / 14 | semibold |
| body | 14 | regular, lineSpacing 4 (existing `prose()`) |

### Localization

Chrome is localized (en + de String Catalog): callout severity titles, harness block labels, role
display names, accessibility labels. Content is never localized: message text, quotes, command
names, task summaries, transcript prose.

**Recorded rule change:** CLAUDE.md's localization section lists `roles` among never-localized
content. That still holds for the stored role *string* — we never render it raw. A mapped display
label ("You"/"Du", "Claude") is chrome derived from the role, not the content itself. CLAUDE.md
gets a one-line amendment saying so, rather than being silently contradicted.

### Accessibility

Bubbles carry an `accessibilityLabel` of "<localized role>: <text>" so the speaker survives for
VoiceOver even though the label is drawn only on speaker change. System strips announce their kind.
Chips read as their token.

## Testing

**Kit** — `Tests/PensieveKitTests/TranscriptMarkupTests.swift`, ~18 cases:

- I1 passthrough on plain prose; I2 no-loss over a mixed fixture.
- `<HARD-GATE>` and `<string>` inside a fenced block: untouched (I3).
- Inline code span containing a tag: untouched.
- `<HARD-GATE>` with no close: plain text, nothing swallowed (I4).
- `<UUID>`, `<SECRET_NAME>` → chips; `<UUID>` inside a fence → untouched.
- Command group: full trio; `command-name` alone; empty `command-args`.
- `task-notification`: all children; missing children.
- Severity precedence table incl. fallback; `-` vs `_` equivalence.
- Adjacent and nested tags; empty message; tag-only message (→ system classification).

**App** — no unit tests by project convention. Verified by `xcodebuild` build, a non-blocking
smoke-launch of the inner binary with throwaway `PENSIEVE_DB`/`PENSIEVE_CAPTURE_DB`, and an
eyeball checklist against the reported screenshot.

## Risks

- **Parser swallowing content** — the real risk. Mitigated by I2 as an executable property.
- **Allowlist goes stale** as Claude Code changes its envelope format. Mitigation is honest
  degradation: unknown tags fall through to plain text, so raw angle brackets reappear and are
  themselves the signal to update. Recorded as a maintenance expectation, not a defect.
- **Segmentation splits markdown constructs.** A message becomes several `Markdown` views, so an
  ordered list straddling a tag boundary restarts its numbering. Accepted — these tags wrap whole
  blocks in practice.
- **Parse cost per render.** Parse once per message and memoize by message index rather than
  re-parsing in `body`.
- **Placeholder chips are indistinguishable from real inline code**, since both become code spans.
  Accepted: both are tokens, and the alternative is a sentinel that could collide with content.

## Out of scope

Syntax highlighting, Mermaid/Graphviz rendering, and Writing Tools — all in `backlog.md` with
their revisit triggers. `BlockStyle<CodeBlockConfiguration>` is the seam highlighting will use.

## Success criteria

1. The reported screenshot renders with **zero raw angle brackets**.
2. Injected envelopes are visually distinct from user messages; nothing the user did not write is
   attributed to them.
3. The cited-message provenance highlight is preserved exactly.
4. `./scripts/test.sh` green at 448 + new Kit tests; `xcodebuild` clean; smoke launch survives.
5. German renders in situ without layout breakage.
