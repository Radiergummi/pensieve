# In-node find — ⌘F within the open node, highlighted in place

**Date:** 2026-08-11
**Status:** design, revised after two independent adversarial reviews
**Scope:** the detail column's own find bar, plus the keybinding correction it forces
(⌘F → in-node find, ⌥⌘F → the existing search-everything field). Adjacent ideas deliberately
excluded: scoping the BM25 engine to one node (own spec), transcript-passage chunking (deferred item
in `backlog.md`), find in the middle column, regex/whole-word toggles.

**Revision note (2026-08-11).** Two independent Opus reviews (feasibility-verified-against-code, and
integration/regression) produced 4 convergent Critical findings plus ~14 Important/Minor. This
document is a rewrite, not a patch. What changed materially:

- **The cost table was wrong by ~5.5×, and the number that decides the feature's value was missing.**
  Re-measured (§Measured cost).
- **The anchor-scroll mechanism did not work**, and the "already established two-phase pattern" it
  cited did not exist. Redesigned around a mount-driven pending scroll (§Reaching a match).
- **`.id(anchor)` would have broken three shipped landing paths** by taking the row's only `.id`
  slot. Anchors now sit on inner views (§Reaching a match).
- **The trust-gate claim was false** — `ProvenanceQueries` reads `isUserPrompt` as half of the
  "never a wrong highlight" guard, and the batch loader would have made a second copy of it. Fixed
  with a shared session-taking overload (§Provenance loading).
- **`showsLooseEnds` was unmodelled**, and it is the *default* state for a childless strand
  (§Document scope).
- **Cache invalidation named a signal that never fires** on the watch path (§Provenance loading).
- **`FindMatcher`/`FindRun`/`HighlightedText` were a second implementation** of
  `Snippet`/`SnippetMaker`/`SnippetText`; unified instead (§Kit kernel).

The reviews were also handed a false premise by the author — that this work sits on a
`remove-vector-search` branch. Both rejected it: that branch merged to `main` mid-session
(`6737d82`), along with `fix/bounded-absent-transcript-retry` (`99a5449`). All measurements and line
references below are against `main` at `c645e8e`.

## Problem

Opening a project or strand in the detail pane surfaces a lot of text — the node name and
description, the generated "Last Work Done" recap, every open loose end with its cited quote, a
±4-message transcript window behind each one, and the activity timeline. There is no way to find a
phrase *inside* what is already on screen. The natural chord, ⌘F, is bound to the global
`.searchable` field (`PensieveApp.swift:50-51` → `RootView.swift:66-68` → `:39`), so the feature looks
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

⌥⌘F is free: the app declares only ⌘N, ⌘⌥N, ⌘F, ⌘R (`PensieveApp.swift:44,46,51,54`) plus
`SidebarCommands()`'s ⌃⌘S, and macOS does not reserve it — it is Mail's and Notes' own search chord,
which is the convention being copied.

The platform primitive behind the convention is AppKit's `NSTextFinder` and the standard Edit ▸ Find
menu (⌘F / ⌘G / ⇧⌘G). SwiftUI exposes it as `.findNavigator(isPresented:)`, but **only for
text-editing views** — verified against the macOS 26.5 SDK SwiftUI interface, where it sits beside
`findDisabled`/`replaceDisabled` and is scoped to `TextEditor`. It cannot wrap the detail pane. Per
"platform primitives first": the native mechanism was evaluated and is genuinely insufficient; this
design reuses its *interaction grammar*, not its implementation.

## Measured cost

`ProvenanceQueries.context` parses the **entire** JSONL transcript per call
(`ProvenanceQueries.swift:39`), and `LooseEndQueries.open` applies no limit, so a node's every open
loose end becomes a rendered row. Measured on the live store, against the `Pensieve` node:

| | Value |
|---|---|
| Loose ends on the node | 184 |
| **Open** (`status = 'open' AND label <> 'noise'`, per `LooseEnd.swift:31-33`) | **122** |
| Distinct source transcripts behind the open set | 37 |
| **Of those, still present on disk** | **13 (24 are gone)** |
| Bytes actually parseable | **18 MB** |
| **Open loose ends whose transcript still exists** | **18 of 122 (15%)** |

**Methodology** (a prior spec in this repo was invalidated by a bad glob, so this is stated
explicitly): open-ness applies `LooseEnd.isOpen`'s real predicate in SQL, not a raw column;
transcript paths come from `json_extract(events.detailJSON,'$.transcriptPath')`, the same key
`ProvenanceQueries.swift:35` decodes; liveness is a per-path `test -f`, mirroring the `fileExists`
short-circuit at `ProvenanceQueries.swift:36`.

The first draft claimed "~48 files / ~100 MB". Both numbers were wrong: 48 counted the 62 noise rows
the detail view never renders, and ~100 MB is the size of the *whole* transcript directory, not the
referenced set.

**Two consequences, in opposite directions, and both belong in the record:**

1. **The progressive sweep survives on cost.** 18 MB of per-line JSON decoding on the main actor
   would hitch the UI, and 24 dead paths are rejected by a `stat` before any parse — so the sweep is
   cheap *and* still necessary. Decision 4 stands.
2. **The sweep buys less than the first draft implied.** 104 of 122 open loose ends (85%) have no
   transcript and degrade to the stored quote, so the `ProvenanceLoader` + slot-fill + progress +
   identity-tracking apparatus — the most complex third of this design — buys in-place transcript
   findability for **18 rows** on the measured node. The just-merged
   `fix(ingest): bound the retry for a vanished session transcript` (`99a5449`) is independent
   confirmation that transcripts vanishing is normal here, not an anomaly.

This ratio was put to the author with a proposed decomposition (ship find without the sweep first).
**Decision: keep one spec, full scope, all findings fixed.** The trade-off accepted with that choice
is that a keybinding change, a grounding-guard refactor and a MarkdownUI rendering-mode switch land
in one review, and the least valuable slice can block the most valuable.

Note that the ratio improves for recent work: transcripts rotate away with age, so the loose ends
with live provenance are the newest ones — which are also the ones most likely to be searched.

## Decisions

1. **Scope = everything the detail pane can render for this node**, including transcript windows
   behind rows that are currently collapsed. Not: content the pane does not render (§Document scope).
2. **Highlight fidelity: flatten matched segments while find is active.** MarkdownUI 2.4.1 offers no
   way to style a substring inside a rendered block — verified against the vendored checkout, where
   `InlineNode`, `BlockNode` and `MarkdownContent.blocks` are all `internal` and the public surface
   is `init(String)` / `renderMarkdown` / `renderHTML` / `renderPlainText` / `childContent`. There is
   no AST access and no substring theming hook. So a segment *containing* a match renders as plain
   text with its matched runs highlighted (exact offsets, true Safari-style); segments without
   matches, and everything with the bar closed, keep the untouched MarkdownUI path. Accepted cost:
   inside a matched segment, raw syntax (`**bold**`, ``` fences) is visible until the bar closes.
   Rejected: message-level tint only (you still hunt by eye inside a long message — fails the actual
   request); an `AttributedString` markdown path (a second markdown code path, and block structure
   flattens anyway).
3. **⌘F local, ⌥⌘F global**, with the full Find grammar (⌘G, ⇧⌘G, Esc).
4. **Transcript loading: progressive sweep, deduped by path, cached** (§Provenance loading).
5. **Matching is literal substring, case- and diacritic-insensitive.** No regex, no whole-word, no
   stemming — Safari semantics. Diacritic folding is not cosmetic: it is why typing `losung`
   highlights `Lösung`, and it agrees with the FTS5 `remove_diacritics 2` tokenizer.

## Kit kernel

**One matcher, not a second one.** The repo already has `Snippet` (`leading`/`match`/`trailing`,
`Snippet.swift:7-14`), `SnippetMaker` (`range(of:options:)` with
`[.caseInsensitive, .diacriticInsensitive]`, `Snippet.swift:28`) and `SnippetText`
(`ContentListView.swift:189-197`). `Snippet` is literally the N=1 case of what find needs, and
`Snippet.swift:47-50` already carries a scar comment about two code paths disagreeing on their
comparison options. The most recent search commit is titled *"one definition each for the hash, the
resolver, and the query shape"*. So find **generalizes** these rather than duplicating them:

- **`FindOptions`** — one shared `String.CompareOptions` constant
  (`[.caseInsensitive, .diacriticInsensitive]`). `SnippetMaker` stops declaring its own.
- **`FindMatcher`**
  - `ranges(in:query:) -> [Range<String.Index>]` — *all* occurrences, unicode-safe, non-overlapping,
    left-to-right.
  - `runs(in:ranges:) -> [FindRun]` where `FindRun` is `.plain(String)` / `.match(String)`.
    Invariant: concatenating all runs reproduces the source exactly.
  - `SnippetMaker.make` is re-expressed as *first range + windowing* over `FindMatcher`, so the two
    can no longer drift. `Snippet`'s three-run shape stays — it is the search-results contract.
- **`FindAnchor`** — a `Hashable` enum naming *where* a unit lives; the single vocabulary Kit and the
  app share for "where is this match", and simultaneously the scroll target and the expansion
  instruction:

```
.nodeName
.description
.narration
.looseEndText(UUID)
.looseEndQuote(UUID)
.transcriptSegment(looseEndID: UUID, messageIndex: Int, segment: Int)
.event(UUID)
```

- **`NodeFindDocument`** — an ordered `[FindUnit]` (`anchor` + `text`), with
  `make(node:narration:looseEnds:events:showsLooseEnds:)` fixing document order once to match
  on-screen order: What It Is (name, description) → Last Work Done → Loose Ends (each row's text,
  then its provenance slot) → Recent Activity. `matches(query:) -> [FindMatch]` (anchor + range +
  ordinal) produces "3 of 17" and makes ⌘G a pure index step.
- **`TranscriptSegment.findableText`** — the projection that decides what text a transcript unit
  contributes. It must be **what the app displays**, never `raw`: `raw` is the exact source substring
  (pinned by the no-loss property, `TranscriptSegment.swift:3-5,11-18`) and includes tag markup and
  unrendered children, so indexing it would match invisible bytes and inflate the count. Rules:
  `.markdown` → its text; `.callout` → `body` only (the `tagName` renders as chrome, not content);
  `.harness` → `HarnessKind.displayBody`, which is `nil` for `.interrupted` and therefore contributes
  no unit. `HarnessBlock.unrecognisedChildren` is deliberately lossless in the parse but **never
  rendered**, so it is not findable — consistent with "highlight only what is on screen".
  - This requires **moving `HarnessKind.displayBody` from the app target into Kit**, beside
    `HarnessKind` (`TranscriptSegment.swift:70`). It is already documented *"Content — verbatim, never
    localized"* (`TranscriptSegmentView.swift:120`), so it belongs in Kit; the localized `label` in
    the same extension stays in the app. This is a move, not a rewrite, and it is what makes the
    document and the view agree on findable text by construction.

## Document scope — what find may and may not see

The find bar mounts on the **detail column**, so the document contains exactly what that column can
render. Three gates, all previously unmodelled:

1. **`showsLooseEnds`.** `RootView.swift:15` passes `model.detailShowsLooseEnds`, false whenever the
   focused leaf's loose ends already live in the middle column (`AppModel.swift:340-346` — the
   one-home rule). That is the **default for a childless strand**, not an edge case. So
   `make(…showsLooseEnds:)` omits every loose-end unit (text, quote, transcript) when it is false;
   ⌘F then finds name, description, narration and events only. **Pre-committed fallback** if this
   reads as broken in dogfooding: mount the find bar over the content column too — its own spec, not
   a silent widening of this one. (Note `detailShowsLooseEnds` returns true while the *global* search
   is active; in-node find is not that state, so the one-home rule applies.)
2. **Narration toggle.** `DetailView.swift:45` gates the section on `narrationEnabled`
   (`AppDefaults.narrationEnabledKey`) **and** `loadedNodeID == node.id`. A `.narration` unit is
   supplied only when the section actually renders — the Settings-surface review already caught one
   leak of disabled narration into Share.
3. **Quote vs transcript — never both.** `LooseEnd.quote` is rendered **only** in the
   transcript-unavailable fallback (`LooseEndRow.swift:105`); when the transcript is available the row
   renders messages and the quote is never shown. Since the quote is by construction a substring of
   the cited message, indexing both would double-count the same text *and* point one match at a site
   that does not exist. So a loose end's provenance slot resolves to **either** transcript units
   **or** a single `.looseEndQuote` unit — decided when the slot fills, never before.

## Provenance loading

**`ProvenanceQueries` gains a session-taking overload.** Today `context(_:looseEnd:radius:)` is
monolithic: fetch event → decode path → `fileExists` → `TranscriptParser.parse(fileURL:)` → resolve
`citedPos` by identity → the **two-part guard** → slice the window. The guard is the reason the
surface can claim it never highlights a wrong message (`ProvenanceQueries.swift:19-22,44-52`), and
`TranscriptMessageView.swift:45` leans on it by name to justify drawing the cited bar.

A batch loader that parsed once and sliced windows itself would have to either re-read
`isUserPrompt` or skip the guard — i.e. make a **second copy of a grounding guard**. So instead:

```
context(session: ParsedSession, looseEnd: LooseEnd, event: Event, radius: Int) -> ProvenanceContext
context(_ database:, looseEnd:, radius:) -> ProvenanceContext   // one-shot wrapper over the above
```

Lines 41-59 are reused verbatim by both paths. **The earlier claim that this feature neither reads
nor writes `isUserPrompt` was false and is withdrawn**: find reads it, transitively, through the
guard that is *supposed* to gate provenance. What it must not do is own a second copy, and it doesn't.
Nothing here touches `injectionMarkers`, `TranscriptParser.isInjectedOrCommand`, or extraction — find
changes only which real captured text is highlighted, never what may be said about it.

**`ProvenanceLoader`** (`actor`) caches `looseEndID → (ProvenanceContext, [[TranscriptSegment]])`.

- Keying on **loose-end ID is safe**, and specifically dodges the hazard `LooseEndRow.swift:26-29`
  warns about: that comment is about caching segments keyed on `ProvenanceMessage.index`, which is
  per-session and collides across sessions. A loose end has exactly one `sourceEventID`, hence one
  session, so it cannot serve session A's data for session B.
- **It caches the parsed segments too, not just the context** — this is what makes the document's
  `segment` ordinal and the view's rendered segment ordinal identical *by construction*, instead of
  two `TranscriptMarkup.parse` calls that could disagree. `LooseEndRow` stops parsing locally
  (`LooseEndRow.swift:72-79`) and reads both from the loader.
- `load(all:)` groups by transcript path, `stat`s each path first (24 of 37 are gone — rejected before
  any parse), parses each survivor once, slices every window out of it via the new overload, then
  drops the `ParsedSession`. `TranscriptParser` builds each message's `text` as an independent String,
  so dropping the session genuinely releases the non-windowed messages.
- **Retained memory, stated honestly:** one window per loose end, with heavy duplication between
  loose ends from the same session. On the measured node that is 18 live contexts over 786 KB of
  parser-visible text — small, but the earlier claim that it is "the windows the app renders anyway"
  was false (the app renders the expanded rows, typically one). Bound it: LRU cap of 200 entries.
- **Invalidation is per-entry `(size, mtime)` validation on read, not an app refresh signal.** The
  first draft named `refreshToken`, which is bumped in exactly one place (`AppModel.swift:195`, inside
  `drainThenRefresh`) and — per its own comment at `AppModel.swift:98-99` — **never** on the
  FSEvents watch path. So the growing live session, the one case cited to justify having no TTL, was
  precisely the case that would have gone stale until ⌘R. A `stat` per cache read is cheap,
  self-correcting, and independent of app plumbing. It also removes the "clear on node change" rule,
  which would have evicted entries the cross-node Review Suggestions list
  (`ContentListView.swift:151`) and open recall windows still need.
- Fixing the pre-existing repeat-parse (five rows from one session parse that file five times) falls
  out of this for free.

**The sweep** is one cancelable `Task` per find session, carrying a **generation token** (node ID +
document epoch). It reports `(sessionsDone, sessionsTotal)` for the bar, cancels on query change,
Esc, or node change, and a late result whose generation differs is dropped — the same discipline as
the `Task.isCancelled` guard at `DetailView.swift:121`.

## Slot-fill ordering and match identity

The sweep completes in file order; the document must stay in on-screen order. So each loose end has a
**pre-allocated provenance slot** the sweep fills in place, never appends to. Consequences, each with
a stated rule:

1. The match **count grows** during a sweep — shown as progress
   ("17 matches · searching transcripts 12/37…"), so a rising number reads as progress.
2. A fill must never **renumber the user's position**. The bar tracks the current match's
   **identity** (anchor + offset), not its ordinal, recomputing the ordinal after each document
   update.
3. **When the current match's anchor disappears**, the bar re-anchors to the nearest *following*
   match in document order, else the first, else no-match. Reachable in three ways: a re-parsed
   transcript now fails the two-part guard (slot → quote unit), ⌘R replaces the narration with
   different prose (`DetailView.swift:120`, `force: isRefresh`) so `.narration` + offset designates
   unrelated bytes, or the query changed. `.narration` is *not* a stable identity across a refresh
   and this rule is how that is handled, rather than pretending otherwise.
4. **Find state resets on node change.** `DetailView`'s structural identity persists across node
   changes — which is why the existing code is littered with `loadedNodeID == node.id` guards
   (`DetailView.swift:45,54,101,160,175`, hardening that CLAUDE.md records as the product of three
   reviews). `NodeFindState` carries the same guard and clears query, matches and current identity on
   a node change; without it the bar would report "3 of 17" against the previous node's document.

## Reaching a match

The first draft claimed `.id(anchor)` on findable sites plus "the two-phase expand-then-scroll pattern
already established at `DetailView.swift:111`". Both halves were wrong:

- **There is no such pattern.** `DetailView.swift:70` puts `.id(view.looseEnd.id)` on the **outer
  row**, which exists whether or not the row is expanded, so today's `scrollTo` has never had to
  reach an id that appears only after expansion. `DetailView.swift:111` and `:127-130` are two
  independent, unordered reactions to `expandedLooseEndID`, not a sequence.
- **`.id(anchor)` would have broken shipped behavior.** A view has one `.id`. Replacing the row's
  `.id(UUID)` makes `scrollTo(UUID)` resolve nothing, silently breaking the "land on the cited row"
  landing used by ⌘F search hits, Spotlight loose-end taps (`AppModel+Search.openLooseEnd`) and
  `pensieve://looseend/<uuid>`.

A transcript anchor's site is behind three gates, all inside `if expanded` (`LooseEndRow.swift:56`):
`expanded`, then a non-nil `context` (loaded by an `await`ing `.task`, `LooseEndRow.swift:72-79`),
then `provenanceExpanded` (`:89-97`). `scrollTo` on an absent id is a silent no-op. So:

**Anchors go on inner views, never on the row.** The row keeps `.id(view.looseEnd.id)`. Section
views, message views and segment views carry `.id(FindAnchor)`. `UUID` and `FindAnchor` are distinct
`AnyHashable`s in the same `ScrollViewReader` namespace, so both landing paths coexist.

**Navigation is mount-driven, not timed.** `NodeFindState.pendingScroll: FindAnchor?`. Navigating to
a match (a) sets the expansion intent for the owning row, (b) sets `pendingScroll`. Each findable site
reports `.onAppear { state.siteMounted(anchor) }`; when a mounted anchor equals `pendingScroll`, the
state clears it and publishes a scroll target that `DetailView` turns into `proxy.scrollTo`. No
`Task.yield()`, no frame guessing, no timeout — and it is **deterministic**, because a transcript unit
is only ever in the document if the sweep already loaded and guarded it, so the site *will* mount once
expansion is set (the row's `.task` resolves from the loader cache, no file I/O).

**Expansion intent is per-window.** The only existing channel for driving expansion from outside a row
is `AppModel.expandedLooseEndID` (`AppModel.swift:120`), which is app-wide and read by `DetailView` in
*every* window. Reusing it would force-expand the same row in every open recall window on that node
and clobber the pending search/Spotlight landing state. So find gets a **new per-window parameter**
threaded `DetailView → LooseEndRow`, alongside `expandedLooseEndID`, not replacing it. (Row expansion
itself is already per-window: `LooseEndRow.expanded` is instance `@State`.)

**Any transcript match opens "Show more".** The first draft's rule — open it only when the match sits
outside the cited message — is insufficient: the collapsed preview renders **one** segment (the first
non-empty `.markdown`/`.callout`, explicitly skipping `.harness`) under `.lineLimit(3)`
(`LooseEndRow.swift:156-159,186-196`). A match in the cited message's second segment, in any harness
segment, or past three lines is invisible there. So find navigation always sets `provenanceExpanded`,
and the preview path is never a navigation target.

## App layer

- **`NodeFindState`** (`@Observable`, per window, owned by `DetailView`): query, document, matches,
  current identity, `pendingScroll`, sweep progress, presented flag, plus the `loadedNodeID`
  generation guard. Published with the **Observable** `focusedSceneValue(_:)` overload (not the
  keyPath form) so menu-item enablement — "Find Next" disabled at zero matches — participates in
  observation.
- **`FindCommands: Commands`** — a separate `Commands` struct, because `@FocusedValue` is a property
  wrapper and cannot be declared inside `PensieveApp.body`'s inline `.commands { … }`. It contributes
  `Menu("Find")` inside `CommandGroup(after: .textEditing)` — the only Edit-menu region placement the
  SDK offers (there is no `.find` placement; verified). Items: Find (⌘F), Find Next (⌘G), Find
  Previous (⇧⌘G). Verify at runtime that it lands under Edit and not in an overflow.
- **Find bar** at the top of the detail column: field, "3 of 17", ‹ ›, Done. Styled with the
  `.background(.bar)` + hairline idiom the sidebar status bar already uses. Esc dismisses. ⌘F is
  disabled when no node is selected (Briefing).
- **`HighlightedText(runs:)`** — one renderer over `FindRun`. `SnippetText` is re-expressed as a thin
  wrapper mapping `Snippet`'s three runs onto it, so there is one highlight renderer, not two.
- **`TranscriptSegmentView`** takes an optional highlight (decision 2). The parameter crosses
  **`TranscriptMessageView`** (`LooseEndRow.swift:157,163`) — the intermediate the first draft failed
  to name — and `LooseEndRow` threads it through **both** render paths. Note `compact:` has exactly
  three call sites (`DetailView.swift:69`, `ContentListView.swift:135`, `:151`); a new parameter must
  be checked against all three.
- **`Go` menu** keeps Refresh, loses Find; the global item is relabeled **Search Everything** on
  **⌥⌘F**. In a key recall window there is no `.searchable` field to focus (it exists only in
  `RootView`'s content column), so ⌥⌘F there must front the main window first rather than silently
  focusing a field in a background window — a pre-existing wart under today's ⌘F that this
  formalizes.
- **Localization.** Keys to author by hand in `Localizable.xcstrings` (`xcodebuild` will not populate
  them, and a mis-keyed `de` value falls back to English silently): reuse the existing `"Find"`
  (line 985, currently `"Suchen"`) for the **local** item; add `"Search Everything"` →
  `"Alles durchsuchen"` for the relocated global item, disambiguating it from the existing
  `"Search"` → `"Suchen"` (line 2001); add the match-count format (`%lld of %lld`), `"Done"`, and the
  sweep-progress format (`%lld matches · searching transcripts %lld/%lld`). Find-bar chrome only —
  node names, quotes, transcript text and event summaries stay verbatim content.
- **`README.md:101`** describes "⌘F search across both exact and semantic recall" and "a provenance
  inspector". The ⌘F clause is in scope here. The other two staleness items on that line (semantic
  recall was removed in `6737d82`; the inspector was retired when provenance went inline) are
  pre-existing and flagged, not silently rewritten.

## Degradation

- Transcript gone (the 85% case) → the row degrades to the stored quote as it does today, and the
  slot resolves to a `.looseEndQuote` unit.
- Sweep canceled, or a parse fails → cheap matches remain valid, progress resolves, no error is
  surfaced. Find is best-effort and never blocks capture, ingest, or the UI.
- Empty query → no matches, no highlighting, bar stays open.
- Current match vanishes → the re-anchor rule above.

## Testing

Kit, under `swift test`:

- **`FindMatcher`** — unicode boundaries, diacritic folding (`losung` → `Lösung`), adjacent and
  overlapping candidates, empty query, runs round-trip (`runs` concatenate to the source), and that
  `SnippetMaker.make`'s output is unchanged after being re-expressed over it (a regression pin on the
  shipped search-results highlight).
- **`NodeFindDocument`** — document order fixed and matching section order; slot-fill preserves order;
  `showsLooseEnds: false` omits every loose-end unit; quote-XOR-transcript per slot; narration omitted
  when disabled; ordinal recomputation keeps the current identity stable across a fill; the
  re-anchor-to-following rule when an anchor disappears.
- **`TranscriptSegment.findableText`** — `.markdown`/`.callout`/`.harness` projections; `.interrupted`
  contributes nothing; `raw` markup is never indexed.
- **`ProvenanceQueries.context(session:…)`** — byte-identical results to the one-shot path (the
  guard is shared, so this pins that it stays shared); a dead path is rejected before parse.
- **`ProvenanceLoader`** — one parse per transcript path for N loose ends sharing it; cache hit on
  re-request; `(size, mtime)` change invalidates; LRU bound holds.

App target: `xcodebuild` build + non-blocking smoke-launch of the inner binary with throwaway
`PENSIEVE_DB`/`PENSIEVE_CAPTURE_DB`, plus an eyeball matrix — highlight in all three speaker classes;
navigation into a *collapsed* row's transcript actually lands (the C1 case); the shipped `scrollTo`
landings (⌘F hit, Spotlight tap, `pensieve://looseend/…`) still work; a find in the main window does
**not** expand rows in an open recall window; ⌥⌘F still opens global search; German in situ. Per
project convention the app target has no unit tests.

## Out of scope

Regex and whole-word toggles; find in the middle column (pre-committed fallback for gate 1 above, own
spec); find in the Briefing; scoping BM25 to one node; indexing transcript passages into FTS
(deferred, own spec) — which would later make the sweep unnecessary without changing any interface
described here.
