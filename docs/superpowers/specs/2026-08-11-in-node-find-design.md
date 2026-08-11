# In-node find — ⌘F within the open node, highlighted in place

**Date:** 2026-08-11
**Status:** design, approved in brainstorm
**Scope:** the detail column's own find bar, plus the keybinding correction it forces
(⌘F → in-node find, ⌥⌘F → the existing search-everything field). Adjacent ideas deliberately
excluded: scoping the BM25 engine to one node (own spec), transcript-passage chunking (already a
deferred item in `backlog.md`), find-in-the-middle-column, regex/whole-word toggles.

## Problem

Opening a project or strand in the detail pane surfaces a lot of text — the node description, the
generated "Last Work Done" recap, every open loose end with its cited quote, a ±4-message transcript
window behind each one, and the activity timeline. There is no way to find a phrase *inside* what is
already on screen. The natural chord for it, ⌘F, is bound to the global `.searchable` field
(`PensieveApp.swift:51` → `model.focusSearchRequested` → `RootView.swift:39`), so the feature appears
blocked on a keybinding conflict.

It isn't. The conflict is the bug.

### Prior art — ⌘F belongs to the document, not the corpus

| App | Local find | Corpus search |
|---|---|---|
| Safari / Chrome | ⌘F find-in-page | ⌘L address/search field |
| Xcode | ⌘F find in file | ⇧⌘F find in workspace |
| VS Code | ⌘F | ⇧⌘F |
| Obsidian | ⌘F current note | ⇧⌘F all files |
| Apple Mail | ⌘F find in message | ⌥⌘F search field |
| Apple Notes | ⌘F find in note | ⌥⌘F search all notes |
| Preview | ⌘F find in document, ⌘G next | — |
| Messages | — (no local find) | ⌘F |

Two families: **Apple's own apps put corpus search on ⌥⌘F**; **developer tools use ⇧⌘F**. Messages is
the lone counter-example, and only because it has no in-document find to compete with. Pensieve is a
Mac app, so it follows Mail and Notes: **⌘F = find in this node, ⌥⌘F = search everything.**

The platform primitive behind the convention is AppKit's `NSTextFinder` and the standard Edit ▸ Find
menu (⌘F / ⌘G / ⇧⌘G). SwiftUI exposes it as `.findNavigator(isPresented:)`, but **only for
text-editing views** (`TextEditor`), not arbitrary view hierarchies — so it cannot wrap the detail
pane. This design reuses its *interaction grammar*, not its implementation. Per "platform primitives
first": the native mechanism was evaluated and is genuinely insufficient here.

## Decisions taken in the brainstorm

1. **Scope = everything in the node, including collapsed transcripts.** Node name/description,
   narration prose, every loose end's text *and* cited quote, event summaries, and the transcript
   window behind each loose end — even rows not currently expanded. A match force-expands the row
   holding it.
2. **Highlight fidelity: flatten matched segments while find is active.** MarkdownUI 2.4.1 has no API
   for styling a substring inside a rendered block. A transcript segment *containing* a match renders
   as plain text with its matched runs highlighted (exact character offsets, true Safari-style);
   segments without matches, and everything with the bar closed, keep the untouched MarkdownUI path.
   Accepted cost: inside a matched segment, raw syntax (`**bold**`, ``` fences) is visible until the
   bar closes. Rejected alternatives: message-level tint only (you still hunt by eye inside a long
   message — fails the actual request), and an `AttributedString` markdown path (a second markdown
   code path to maintain, and block structure flattens anyway).
3. **Keybindings: ⌘F local, ⌥⌘F global**, with the full Find menu grammar (⌘G, ⇧⌘G, Esc).
4. **Transcript loading: progressive sweep, deduped by transcript path, cached.**

### Measured cost — why (4) is not optional

`ProvenanceQueries.context` parses the **entire** JSONL transcript per call
(`ProvenanceQueries.swift:39`). On the live store:

| Measurement | Value |
|---|---|
| Loose ends on the `Pensieve` node | 184 (121 open) |
| Distinct source events (⇒ sessions) behind them | 48 |
| Largest transcript in this project | 3.0 MB |
| Sessions in this project's transcript dir | 35 |

So a naive "search collapsed transcripts too" parses up to ~48 files / ~100 MB of JSONL on every
find-bar open. There is also a **pre-existing** inefficiency this exposes: expanding five rows from
one session parses that file five times, because `LooseEndRow.task(id: expanded)` calls
`loadProvenance` per row with no shared cache.

The FTS index cannot pre-filter this: its corpus is nodes, open loose ends (text + quote), event
summaries and file paths — **transcript passages are not indexed** (that is the deferred
transcript-passage-chunking item). Indexing them would make this cheap, and is the right long-term
answer, but it is a much larger project and is not a prerequisite.

## Architecture

Chosen: **an ordered find-document in Kit, with a thin find bar in the app.**

Rejected alternatives:

- *Environment-driven per-view highlight* — push `findQuery` down the environment, each view
  highlights itself and registers anchors in a shared observable. Cheaper today, but ⌘G traversal
  order becomes emergent from view registration order: untestable, and it drifts the first time a
  section is reordered.
- *Scope the retrieval stack to one node* — reuse FTS/BM25 with a node filter. Returns ranked *rows*,
  not document-ordered *occurrences*, holds no transcript text, and yields a results list rather than
  highlighting in place. A worthwhile separate feature; not this one.

The chosen split matters because `Sources/PensieveApp/` has **no unit tests** (project convention:
derivation lives in tested PensieveKit, views stay thin). Making match *order* data rather than view
structure is what puts ⌘G traversal under `swift test`.

### Kit kernel (new, pure, tested)

**`FindMatcher`**
- `ranges(in: String, query: String) -> [Range<String.Index>]` — *all* occurrences, unicode-safe,
  case- **and diacritic-insensitive**, using the same comparison options as `SnippetMaker.make`
  (`Snippet.swift:26-30`). Agreeing with the FTS5 `remove_diacritics 2` tokenizer is not cosmetic: it is
  why typing `losung` highlights `Lösung`.
- `runs(in: String, ranges: [Range<String.Index>]) -> [FindRun]` where `FindRun` is
  `.plain(String)` / `.match(String)`. Generalizes `Snippet`'s three-run trick from one match to N,
  so views render `Text` concatenations with **zero index math**. Invariant: concatenating all runs
  reproduces the source string exactly.
- Literal substring only. No regex, no whole-word, no stemming — Safari semantics.

**`FindAnchor`** — a `Hashable` enum naming *where* a unit lives, and the single vocabulary Kit and
the app share for "where is this match":

```
.description
.narration
.looseEndText(UUID)
.looseEndQuote(UUID)
.transcriptSegment(looseEndID: UUID, messageIndex: Int, segment: Int)
.event(UUID)
```

It is simultaneously the scroll target (`.id(anchor)`) and the expansion instruction (a
`.transcriptSegment` anchor tells the view which row to open, and whether to open its "Show more").

**`NodeFindDocument`** — an ordered `[FindUnit]` (`anchor` + `text`).
- `make(node:narration:looseEnds:events:transcripts:)` fixes document order once, matching the
  on-screen section order: What It Is → Last Work Done → Loose Ends (each loose end's text, quote,
  then its transcript window inline) → Recent Activity.
- Loose ends whose transcript has not loaded yet get a **pre-allocated slot** that the sweep fills
  **in place** — never appended (see "Slot-fill ordering" below).
- `matches(query:) -> [FindMatch]` (anchor + range + ordinal) — this is what produces "3 of 17" and
  makes ⌘G/⇧⌘G a pure index step.

**`ProvenanceLoader`** (`actor`)
- Caches `looseEndID → ProvenanceContext`; `model.provenance` routes through it, which retires the
  repeat-parse waste described above and makes row expansion after a sweep instant.
- `load(all:)` groups the node's loose ends **by transcript path**, parses each file once into a
  transient local dictionary, slices every window out of it, then **drops the parsed session**.
  Retained memory is therefore the ±4-message windows the app renders anyway (tens of MB), never the
  48 full sessions.
- **Invalidation is the app's existing refresh signal**, not a TTL: live sessions grow, so the cache
  clears on node change and on `refreshToken` bump (⌘R, FSEvents-driven drain). No staleness
  heuristics, no cache-size tuning.

### Slot-fill ordering (the trap this design exists to avoid)

The sweep completes in **file order**; the document must stay in **on-screen order**. Hence
pre-allocated slots filled in place. Two consequences follow, and both are handled explicitly:

1. The match **count grows** while the sweep runs — the bar shows progress
   ("17 matches · searching transcripts 12/48…") so a growing number reads as progress, not a glitch.
2. An earlier slot filling *after* the user pressed ⌘G would **renumber** matches underneath them.
   Therefore the find bar tracks the **current match's identity** (anchor + offset), not its ordinal,
   and recomputes the ordinal after each document update. A background fill must never yank the user
   to a different match.

### App layer (thin)

- **`NodeFindState`** (`@Observable`, one instance per window, owned by `DetailView`): query,
  document, matches, current-match identity, sweep progress, presented flag. Published via
  `.focusedSceneValue(\.nodeFind, …)` so Edit ▸ Find and ⌘G act on the **focused scene** — the main
  window and each ⌘⌥N recall window each own their find, which is the native expectation and matches
  how `DetailView(allowsInspector:)` already avoided cross-window contamination.
- **Find bar** mounts at the top of the **detail column only** — that is the scope it claims. Field,
  "3 of 17", ‹ ›, Done. Styled with the `.background(.bar)` + hairline idiom the sidebar status bar
  already uses.
- **`HighlightedText(runs:)`** — one shared view over `FindMatcher.runs`, replacing plain `Text` for
  the description, narration prose, loose-end text, quote fallback, and event summaries. All matches
  tint lightly; the current match tints strongly (Safari's convention).
- **`TranscriptSegmentView`** gains an optional highlight parameter (decision 2 above). `LooseEndRow`
  threads it through **both** render paths (`previewRow` and `messageRow`) — note the existing
  `compact:` flag has three call sites, so any new parameter must be checked against all of them.
- **Reaching a collapsed match**: every findable site carries `.id(anchor)` inside `DetailView`'s
  existing `ScrollViewReader`, so the scroll target *is* the `FindAnchor`. Navigating to a transcript
  match sets find-driven expansion on the row (plus `provenanceExpanded` when the match sits outside
  the cited message), then scrolls — the two-phase expand-then-scroll pattern already established at
  `DetailView.swift:111` / `LooseEndRow.swift:80-83`.
- **Menu**: a `Find` submenu under Edit — Find (⌘F), Find Next (⌘G), Find Previous (⇧⌘G). SwiftUI has
  no `.find` command placement, so this is a `Menu("Find")` inside a `CommandGroup` anchored in the
  Edit menu; verify at runtime that it lands under Edit and not in an overflow. `Go` keeps Refresh and
  loses Find; the global-search item is relabeled **Search Everything** and moves to **⌥⌘F**. Esc
  dismisses the bar. ⌘F is disabled
  when no node is selected (the Briefing is showing); ⌥⌘F still works there.
- **Localization**: find-bar chrome gets hand-authored en + de keys in `Localizable.xcstrings`
  (`%lld of %lld`, "Done", "Searching transcripts…"). Node names, quotes, transcript text and event
  summaries stay verbatim content, as always. Reminder from prior work: `xcodebuild` does **not**
  auto-populate the source catalog — keys are authored by hand against the Swift literals.

## Trust gate and grounding

Untouched. Find decides only *which real captured text gets highlighted*; it never changes what may
be said about it. No LLM call, no writes, read-only throughout. `injectionMarkers` and
`isUserPrompt` are not read or written by any code in this feature.

## Degradation

- Transcript gone → the row still degrades to the stored quote (existing behavior); it simply
  contributes no transcript units to the document.
- Sweep canceled or a parse fails → the cheap matches remain valid, the progress indicator resolves,
  and no error is surfaced. Find is best-effort and never blocks capture, ingest, or the UI.
- Empty query → no matches, no highlighting, bar stays open.

## Testing

Kit, under `swift test`:

- `FindMatcher` — unicode boundaries, diacritic folding (`losung` → `Lösung`), adjacent and
  overlapping candidates, empty query, and the runs round-trip (`runs` concatenate to the source).
- `NodeFindDocument` — document order is fixed and matches section order; slot-fill preserves order;
  ordinal recomputation keeps the current match's identity stable across a fill.
- `ProvenanceLoader` — one parse per transcript path for N loose ends sharing it; cache hit on
  re-request; cache cleared on invalidation.

App target: `xcodebuild` build + non-blocking smoke-launch of the inner binary with throwaway
`PENSIEVE_DB`/`PENSIEVE_CAPTURE_DB`, plus an eyeball matrix (highlight in all three speaker classes;
collapsed-row navigation; ⌥⌘F still opens global search; German in situ). Per project convention the
app target has no unit tests.

## Out of scope

Regex and whole-word toggles; find in the middle column; find in the Briefing; scoping BM25 to one
node; indexing transcript passages into FTS (deferred, own spec) — which would later make the sweep
unnecessary without changing any interface described here.
