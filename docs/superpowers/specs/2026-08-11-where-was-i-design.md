# "Where was I" — the reload-context pass (slice A)

**Status:** approved design, ready for a plan
**Slice:** A of four, from the Claude Design review filed in `backlog.md` (2026-08-11)
**Scope:** `Sources/PensieveApp/` + three additive `Sources/PensieveKit/Query/` changes. No writes, no
schema change, no migration, no trust-gate contact.

## Why

Pensieve exists to answer one question fast: *where does this project stand?* The shipped app answers
it slowly. Opening a node shows the node's name, then a kind label, then LLM prose, and only then the
cited loose ends — so the first 200pt of the reading column carry no fact you could act on. The middle
column repeats the word "Projekt" down every row. The Briefing gives a project that moved and five that
did not exactly the same visual weight. And the elapsed-time strings — the single most load-bearing
fact on every one of those surfaces — are wrong, untranslated, or both.

This slice is information design. It adds no capability. Every change either promotes a fact that was
buried, deletes a fact that was noise, or makes a fact honest.

### The mockups are intent, not a specification

The Claude Design proposal arrived as rendered mockups. They are treated here as **medium-resolution
intent**: the outcomes are adopted, the pixels are not. Where a mockup reaches an outcome through a
custom surface, this spec reaches it through a platform primitive instead. Two of its proposals are
deliberately not implemented, and the reasons are recorded in "Rejected" below.

## The root cause of the time problem

Not a formatting bug. **The Kit never gives the view a date.**

`NodeFacts`, `BriefingCard`, `NextItem` and `SessionContextQueries` all carry `daysDormant: Int`. Each
computes `Calendar.dateComponents([.day], from: latestEvent.occurredAt, to: now)` and discards the
timestamp. A view holding an `Int` cannot render a relative date, so the app interpolates the integer
into an English sentence fragment by hand. That produces, verbatim in the shipped app:

| Site | Renders | Runtime key | Catalog key |
|---|---|---|---|
| `BriefingView.swift:45` | `dormant 0d` | `dormant %lldd` | `dormant %@d` |
| `BriefingView.swift:44` | `1 since last visit` | `%lld since last visit` | `%@ since last visit` |
| `LooseEndRow.swift:60` | `39d ago` | `%@ · %@ · %lldd ago` | `%@ · %@ · %@d ago` |
| `MenuBarView.swift:67` | `0d dormant` | `%lld open · %lldd dormant` | `%@ open · %@d dormant` |
| `MenuBarView.swift:51` | `868 open` | `%lld open` | `%@ open` |

The keys **do exist** in `Localizable.xcstrings` and **are** translated into German. They never match
at runtime: SwiftUI's `LocalizedStringKey` interpolation renders an `Int` as `%lld`, and every one of
these entries was hand-authored with `%@`. A key that doesn't match falls back to the literal, so the
app renders English inside an otherwise German window.

This is exactly the trap `CLAUDE.md` already documents — *"`xcodebuild` does not auto-populate the
source `.xcstrings` (IDE-only) — author/reconcile keys by hand against the Swift literals (`%lld`/`%@`);
a mis-keyed `de` value silently falls back to English."* It bit every integer-bearing string in the
app, and every integer-bearing string in the app is a time or a count.

**Fix:** carry the timestamp. `Date` formats itself, in the user's locale, with correct plurals and
**no interpolated `Int` at all** — so four of the five sites lose the mis-keyable construct rather than
having it corrected. The fifth (a bare count) is corrected to `%lld` by hand.

Note the two `MenuBarView` sites: the menu-bar popover's *redesign* is slice B, but this defect is not
a redesign — it is the same one-character key bug, and leaving two known-broken strings in place to
honour a slice boundary would be pedantry. The keys are fixed here; the popover's structure is not
touched.

## Design

### 1. Kit — additive `lastActivityAt`

`NodeFacts` and `BriefingCard` gain **`lastActivityAt: Date?`** (nil when the node has no captured
events). `daysDormant` is **retained unchanged** on both.

Retaining it is the load-bearing decision. `daysDormant` is not only a display value — it is an input
to `groundedScore(openLooseEnds:daysDormant:)` and to the `SmartLists.dormant` / `.recentlyActive`
thresholds. Replacing it with a `Date` would silently re-rank What's Next and re-partition the smart
lists, which is a behaviour change wearing a formatting change's clothes. So: **the app reads the
`Date`, ranking keeps reading the `Int`.** They derive from the same `latestEvent.occurredAt` and
cannot disagree.

Both initializers gain the parameter. Existing call sites are updated; no call site changes meaning.

`NextItem` and `SessionContextQueries` also carry `daysDormant` and are **not** touched here. Nothing
in this slice reads them — they feed the CLI and MCP surfaces, which are listed under "Out of scope"
for the same reason `ProjectContextRender` is.

### 2. Kit — one batched facts query for the middle column

The middle column needs recency and open-count for every visible node, and both existing paths are
N+1:

- `NodeFactsQueries.facts(for:)` issues two queries **per node** (latest event, open count).
- `BriefingQueries.cards` is worse — it `fetchAll`s *every event row* per node merely to count the
  ones after `since`.

At the real store's 178 projects that is ~356 round trips per selection change, on the main path of
the most-used interaction in the app. So this slice adds a batched entry point returning
`[UUID: (lastActivityAt: Date?, openLooseEnds: Int)]` computed with **two grouped aggregates** inside
one `database.read` — `MAX(occurredAt) GROUP BY nodeID` over events, and a `COUNT(*) GROUP BY nodeID`
over open loose ends — rather than a loop.

If SQLiteData 1.6.6 cannot express a grouped aggregate over the `LooseEnd.isOpen` predicate, the
fallback is **one** fetch of the (nodeID, isOpen-relevant columns) projection folded in Swift — still
two queries total, still not N+1. What is not acceptable is shipping the loop.

A test pins **batch output == per-node output** for the same fixture, so the fast path cannot drift
from the slow one that Spotlight and ranking still use.

The middle column loads this off-`body` in the existing `.task(id: MiddleLoadKey…)`, never in `body` —
the established rule in this app is that no view body touches the database.

### 3. Detail — an adaptive state line, and a new section order

**Header.** The name keeps `.largeTitle`. Beneath it, one meta line assembled on a **mark-the-exception
rule**: a fact renders only when it is not the unmarked default.

- **Kind** renders only when it is not `.project`. A project is the norm; a strand, area or checkpoint
  announces itself.
- **State** renders only when it is not `.active`. An archived node says so; a live one does not need a
  green dot repeating "yes, this exists".
- **Relative recency** always renders (`zuletzt gestern, 22:40` / `vor 3 Wochen`), from
  `lastActivityAt`. A node with no events says so honestly rather than claiming `0d`.
- **Open loose-end count** always renders, plural-aware.
- **`branchKey`** renders only when set — which, structurally, is only ever on an auto-birthed strand.

```
🟢  Pensieve
    zuletzt gestern, 22:40 · 14 offen
    Pensieve is a personal native macOS tool that captures…

🟢  feature/cms-substrate
    Strang · vor 3 Wochen · 6 offen · feature/cms-substrate
```

This is why the header is a **line, not a grid**. The mockup's boxed `LabeledContent` grid has a fixed
column per fact, so a project — having no branch — renders with an empty cell or a differently-shaped
box than the strand above it. A line simply omits what is absent.

**Section order** becomes:

```
header (name · state line · description)
  ↓
LOOSE ENDS          ← cited, verbatim, actionable
  ↓
recap paragraph     ← no caps header
  ↓
RECENT ACTIVITY     ← the raw log
```

Descending specificity: what is unfinished and cited; then prose about it; then the events it was
derived from. Today the LLM recap sits above the cited loose ends, which inverts the app's own trust
ordering — grounded content should outrank best-effort content on the page as it does in the
architecture.

**The recap loses its section header.** `LAST WORK DONE` in caps announces a slot, so an empty slot
reads as a failure. As an unheaded closing paragraph, an absent recap reads as nothing at all — which
is correct, because narration is explicitly best-effort and returns `nil` on provider failure.

**The `✦ Generated summary` attribution line stays, unconditionally.** It is a trust marker separating
best-effort prose from cited content, not decoration. Removing or hiding it is out of scope for any
visual argument.

When `showsLooseEnds == false` (the middle column is already showing this node's loose ends — the
one-home rule), the order is simply `header → recap → RECENT ACTIVITY`.

### 4. Middle column — recency replaces the repeated kind

`ContentListView.swift:120` currently renders `kindLabel(node.kind)` as each row's only second line,
so a column of projects reads `Projekt / Projekt / Projekt / …` — a label with zero discriminating
power, occupying the one line per row available for saying something.

It becomes `vor 3 Wochen · 14 offen`.

Commit and session counts stay out. A 300pt column has room for recency and volume, not four facts;
the finer breakdown belongs to the wider detail header. This is a deliberate narrowing of the
mockup, which shows `24 Prompts, 3 Commits` in a column that is drawn wider than the real one.

Only the `.nodes` middle kind changes. `.looseEndsOf` and `.reviewSuggestions` render loose ends and
are untouched.

### 5. Briefing — weight tracks importance

`BriefingView.swift:23-28` renders `moved` and `quiet` with an identical card body, so five dormant
projects outweigh the one that actually moved. Visual mass currently tracks *count*, not *importance*.

- **Moved** keeps full cards, unchanged in structure.
- **Quiet** collapses into a `Section(isExpanded:)` of one-liners: node name leading, relative dormancy
  trailing (`seit 2 Tagen ruhend`), `.monospacedDigit()` so the trailing column aligns. Collapsed by
  default, expansion persisted in `@AppStorage` like the sidebar's existing section states.
- `dormant 0d` and `N since last visit` are replaced by String Catalog keys with plural variants.

The `moved` / `quiet` partition itself (`movedSince > 0`) is unchanged.

### 6. Loose-end thumbs — hover and context menu, with one exception

Two thumb buttons render permanently on every loose-end row, roughly fifteen times per screen, next to
content the user is trying to read. They become hover-revealed, plus a `.contextMenu` on the row so
they remain reachable without a pointer.

**Exception, and it matters: a thumb whose label is already set stays visible unconditionally.** A
confirmed 👍 or 👎 is recorded user state, not an affordance. Hiding it behind hover would make the app
appear to forget a decision the user made — the opposite of what Pensieve is for. The rule:

| Row state | Non-hovered | Hovered |
|---|---|---|
| `currentLabel` set (user decided) | **visible, filled** | visible |
| `labelSuggestion` only (machine guess) | hidden | visible, pre-highlighted |
| unlabeled | hidden | visible |

The machine's *suggestion* is a guess awaiting confirmation and does not earn permanent pixels; the
user's *decision* does.

Space is reserved in both states so hover does not reflow the row.

### 7. Localization

Every new string is chrome and goes into `Localizable.xcstrings` in en + de. Relative dates come from
`Text(_, format: .relative(presentation: .named))` and are localized by Foundation **with no key at
all** — which is the point of carrying a `Date`.

Counts keep an interpolated `Int` and therefore keep a key, which must be authored as **`%lld`, not
`%@`** — see the table above for what happens otherwise. The five stale `%@` keys are corrected in
place, not left beside their replacements.

Neither `open`/`offen` nor `new`/`neu` inflects for plural in either language, so those need no plural
variants. The Briefing's quiet one-liners deliberately carry a **bare relative date** and no "dormant
for N days" phrasing — which sidesteps the only construct here that *would* have needed plural rules
(English `1 day` / `2 days`) while saying the same thing under a section already headed *Quiet*.

Content is never localized: node names, descriptions, loose-end text, quotes, `branchKey`, event
summaries.

**`xcodebuild` does not populate the String Catalog** (that extraction is IDE-only). Keys are authored
by hand against the Swift literals, and a mis-keyed `de` value falls back to English *silently* — so
verification includes a forced-locale launch, not just a build.

## Rejected

**Dormancy encoded as icon-tint desaturation.** Proposed as one of the review's top five ("the column
is a decay map you scan"). Not adopted. The badge tint is identity the user chose in the icon picker,
and the real store has 112 dormant nodes against 178 — desaturating by staleness would gray out most
of the sidebar, destroying tint as an identity channel, in order to state a fact the relative date now
states honestly, accessibly, and in words. The proposal is also internally inconsistent on this point:
mockup 1c desaturates tints while 2b explicitly says "dormancy via row opacity, **not** tint
saturation". Dormancy is encoded in text only.

**Recent Activity moved into a trailing `.inspector`.** Not adopted. The inspector was *deliberately
removed* in the 2026-07-08 inline-provenance rework (`RootView.swift:41-43`), and the queued in-node-find
plan builds on its absence. The complaint behind it — a wide window wastes its surplus — is real and
was considered on its own terms; the decision is to **keep the capped, centered column** (`Prose.measure`
= 760). Mail, Notes and Xcode's documentation viewer all leave that margin empty. It is the price of a
readable measure, not a bug.

## Out of scope

- **The `Continue` / `Fortsetzen` action** on Briefing cards, menu-bar rows and the detail toolbar →
  backlog slice D. What it should *do* is unresolved, and the plausible answer (launch a session at the
  node's source path) is a new capability, not polish.
- **Liquid Glass and the macOS 26 deployment floor** → backlog slice B.
- **`ProjectContextRender`'s `0d dormant`**, which leaks the same defect into MCP and the CLI SessionStart
  hook. Same root cause, different consumer, and changing agent-facing output deserves its own decision
  about whether relative prose is even right there.
- The sidebar tree rows, which show a name and no metadata. Left alone.

## Verification

**Kit** — Swift Testing, run with `./scripts/test.sh`:

- `lastActivityAt` equals the latest event's `occurredAt`; is `nil` for a node with no events.
- `lastActivityAt` and `daysDormant` derive consistently from the same event.
- Batched facts output equals per-node `NodeFactsQueries` output over the same fixture.
- Existing `SmartLists`, `NextQueries` and `groundedScore` tests must pass **unchanged** — that is the
  evidence that retaining `daysDormant` preserved ranking.

**App** — `Sources/PensieveApp/` has no unit tests. `xcodegen generate`, then `xcodebuild -project
Pensieve.xcodeproj -scheme Pensieve -configuration Debug -derivedDataPath ./.build-xcode build`, then a
**non-blocking smoke launch of the inner binary** (`…/Pensieve.app/Contents/MacOS/Pensieve`, backgrounded
then killed, with throwaway `PENSIEVE_DB` / `PENSIEVE_CAPTURE_DB`) — never the bundle, which would touch
the real store and real Login Items. Discard transient `Package.resolved` churn afterwards; MarkdownUI is
an xcodebuild-only dependency and `swift test` must stay unaffected.

**Human eyeball**, on the real store, requires the built app:

1. A node with events today, one dormant for weeks, and one with **no events at all** — all three
   render an honest recency, and none renders `0d`.
2. A project and a strand side by side — the project shows no kind token and no branch; the strand
   shows both.
3. An archived node shows its state; an active one does not.
4. Middle column reads as recency, not as `Projekt` repeated.
5. Briefing: moved cards carry the weight, quiet collapses, and no English fragment survives.
6. A loose end with a confirmed thumb keeps it visible when the pointer is elsewhere.
7. **Forced-locale German** (`-AppleLanguages '(de)'`) and English. This is the only check that catches
   a mis-keyed catalog entry, and given that five such entries shipped undetected, it is not optional:
   every count and date must render German, including the two menu-bar strings.

## Risks

- **Silent ranking regression** if `daysDormant` is refactored away mid-implementation. Mitigated by
  the unchanged-tests requirement above; treat any edit to `groundedScore` or the `SmartLists`
  thresholds as out of scope for this slice.
- **Middle-column latency** if the batched query is implemented as a loop after all. The batch-equals-
  per-node test proves correctness, not speed — check the query count, not just the output.
- **Silent German fallback** from a mis-keyed catalog entry. Only the forced-locale launch catches it.
- **Merge pressure against the queued in-node-find plan**, which also modifies `DetailView.swift` and
  `LooseEndRow.swift`. Sequence the two; do not run them concurrently.
