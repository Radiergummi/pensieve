# CONTINUE — session handoff

**Last refreshed: 2026-08-13 23:30, against `main` at `fb5e40b` (684 tests).** If `git log -1` shows
commits newer than that, treat every "next" and "not yet" claim below as suspect until checked — the
previous refresh went stale within a day and sent a session off to build a slice that had already
shipped.

Self-contained pickup for a fresh agent. Read `CLAUDE.md` first (project rules + the full shipped
changelog in **Status**), then this. **`docs/superpowers/backlog.md`** is the durable long-term list
(Roadmap + deferred ledger with revisit triggers); this file is the per-session handoff.

**Precedence when these disagree:** `git log` > `CLAUDE.md` Status > `backlog.md` > this file. This one
is the most useful and the first to rot.

## Where things stand

**684 tests** (verified by a full `swift test` run, not a cache hit), with `make test` (`make all` =
lint + test + build + smoke, in CI's order). The full
loop is **LIVE and dogfooded**: capture → ingest → auto-extract runs unattended via the bundled
background-sync agent; the app is a real `Pensieve.app` bundle (Xcode/XcodeGen) with the `pensieve` CLI
embedded inside it. The core intelligence gate passed long ago. The hard part is done — remaining work
is feature breadth, not foundations.

**Nothing is in flight. `main` (`fb5e40b`) is clean and every branch is merged** except the abandoned
`worktree-retrieval-bm25` noted below. **Four features landed on 2026-08-12/13** — in rough order:
**on-device translation** (2026-08-12), **in-node find** and **"where was I"** (design slice A, both
merged 2026-08-12), **the macOS 26 floor + Liquid Glass chrome pass** (design slice B, merged `c356bc6`
2026-08-13 01:00), **loose ends can end** (`open`/`done`/`dropped`, merged `a1c649a`, plus `ecd96ff`),
and **talk-to-system slice 5** (merged through `8d2ba0b`, 18:11).

> ⚠️ **The previous handoff was materially stale and cost this session real time.** It offered design
> slice B as the recommended *next* track when B had already shipped 17 hours earlier, and it never
> mentioned on-device translation or slice 5's merge at all. **Trust `backlog.md` over this file for
> what is done** — its "Claude Design review" header carries the live slice status (currently
> "A and B done, C live, D parked"), and `CLAUDE.md` Status is the authoritative changelog. If you are
> about to start a track named here, confirm against `git log` first; it takes one command.

**`main` is 132 commits ahead of `origin/main` and has never been pushed.** That is the
long-standing state, not a new one — but if you expect a remote to be current, it is not.

Stale leftovers on disk: `.claude/worktrees/loose-end-resolution` (branch
`worktree-loose-end-resolution`, **fully merged** — safe to remove) and `.claude/worktrees/retrieval-bm25`
(branch `worktree-retrieval-bm25`, **8 commits NOT in `main`** — abandoned two-path work, so removing it
discards those commits; that is a decision, not cleanup).

**Counts that used to only grow now shrink.** A loose end has a lifecycle, so "Als Nächstes"/"Ruhend"
mean something, a project with no open ends **leaves What's Next but stays in Dormant** (finished, not
neglected), and there are two new sidebar buckets — **Loose Ends** (the burn-down queue, badged with a
count) and **Completed** (deliberately uncounted: it grows without bound and a number there reads as a
score). **976 open loose ends** are waiting in that queue (checked directly against the live store on
2026-08-13; 968 when the plan measured them — capture keeps adding), and **not one is closed yet**
(`select status, count(*) from looseEnds group by status` returns a single `open` row). The per-node
bulk close exists because 288 of them sit on a single node.

**BM25/FTS5 shipped and is the only retrieval path.** `worktree-retrieval-bm25-single-path` merged to
`main`, and the vector stack it replaced was then deleted outright (see the vector-removal ship below) —
there is no second engine left to reconcile against.

**✅ Reinstall done — `/Applications/Pensieve.app` is current as of 2026-08-13 22:56**, built from
`8d2ba0b` by `make run` after a green `make all`. It now has loose-end resolution *and* slice 5
(verified by localized-key probe: `Loose Ends`, `Completed`, `Done · %lld`, `Description` all present in
`Contents/Resources/en.lproj/Localizable.strings`), and its bundled `pensieve mcp` carries `search`'s
`closed` flag. `~/.local/bin/pensieve` is still the symlink. **It was reinstalled again at 23:41 for
slice B's two carries, and that install left background sync DOWN with no remedy found — see the LIVE
deployment state section, which is the first thing to deal with next session.**

**Note on version probes:** `strings`/`nm` on the app binary do **not** surface Swift type names like
`LooseEndStatusMenu` — a freshly-built binary that certainly contains that code reads ABSENT too, so
that probe produces false "stale" verdicts. Probe the **localized keys** in
`Contents/Resources/en.lproj/Localizable.strings` instead.

**`xcodegen generate` is required whenever a merge adds or removes an app file** — the project is
generated and gitignored, so a build without it fails with `cannot find 'SomeNewType' in scope`, which
reads like a code error and is not one. (The recent examples: the loose-end merge added
`AppModel+Middle.swift`, `LooseEndStatusMenu.swift`, `ClosedLooseEndsRecord.swift`; the in-node-find
merge added `FindCommands.swift` and four siblings.) **`make build` regenerates automatically — a bare
`xcodebuild` does not.**

**No open defects on the retrieval path.** **FTS5/BM25 is the only retrieval path** — the vector stack
(embedder, `vec0` store, indexer, `SemanticQueries` and its inert `0.25` floor, the vendored `sqlite-vec`
C target, the Settings toggle, the ⌘F "Related" section, the MCP `engine` field) was **deleted on
2026-08-11**, so there is no longer a toggle whose persisted `true` can reinstate the old behaviour. The
`app.semanticSearch` key is inert; clear it with `defaults delete me.mazetti.pensieve app.semanticSearch`.
See `backlog.md`, "Semantic relevance floor — CLOSED by removing the engine".

## Most recent ships (newest first)

Brief — the exhaustive per-feature record lives in `CLAUDE.md` **Status**; deferred follow-ups + human
carries live in the matching `backlog.md` entries.

- **Talk to the system, stage 1 — design slice 5** (2026-08-13, merged through `8d2ba0b`). Describe a
  strand in a sentence, get a node — the app's first write path where the **user**, not the model,
  authors identity. `NodeLabeler.label(for:provider:)` routes by detected language
  (`NLLanguageRecognizer`): **English goes to the on-device model; every other language takes a
  deterministic word-boundary shortening**. That routing is **measured, not assumed** — the model
  *translates* non-English input rather than labelling it (a German delayed-train complaint came back
  "Train Advertisement Claim", and an explicit "do not translate" instruction made it *worse*);
  evidence in `measurements/2026-08-13-slice5-label-quality/`. `NodeFields.description` is now
  compulsory (no default — a default would silently blank an existing description on every `update`),
  and a new node finally lands **under the current selection** rather than at top level. **The
  whole-branch review returned NOT READY on one Important** — an embedded newline could reach
  `nodes.name` — fixed by collapsing every whitespace run before the gate check (`e45f57d`). Three
  further findings were judged benign and recorded as decisions, not changes; they are in the
  slice-5 carries section near the bottom of this file.
- **The macOS 26 floor + Liquid Glass chrome — design slice B** (2026-08-13 01:00, merged `c356bc6`).
  `project.yml` pins `deploymentTarget.macOS: "26.0"`, so macOS 26 APIs need no `if #available`
  scaffolding at the call site. Scroll-edge material (`.scrollEdgeEffectStyle(.soft, for: .top)`) so
  content stops bleeding through chrome; the sidebar status footer revisited; and **the menu-bar
  popover rebuilt** — it was the worst-looking surface in the app, node rows with no per-item action.
  Its footer is now a full-width primary button plus an ellipsis `Menu` holding Refresh and Quit at a
  320pt popover, which is what fixes the `Pensieve öffnen` → `Pensieve öf…` truncation slice A's
  verify pass found: **the string was always correct, the row was too narrow.** Two adversarial spec
  reviews notably *"strip the glass out of the glass slice"* (`e7f124d`) — worth reading before
  proposing more chrome. **Two carries stayed open; see the next-action section.**
- **On-device translation** (2026-08-12). Generated text read in German, stored as an indexed alternate
  stream: a `Translator` seam over the macOS 26 headless `TranslationSession`, a disposable
  `TranslationStore`, and a translation **target that is a setting, not the runtime locale**. Applies to
  text Pensieve's own models produced — narration, loose-end summaries, node names — and is indexed
  alongside the English original **so the German you read is also the German you can find**.
  Deliberately excluded: captured content of every kind, and loose-end **quotes** or transcript windows
  in any circumstance (a quote that no longer matches its transcript is a broken citation). Spec/plan:
  `{specs,plans}/2026-08-12-on-device-translation*`.

- **Loose ends can end — `open` / `done` / `dropped`** (2026-08-13, merged to `main` `a1c649a`; the
  suggester follow-up is `ecd96ff`). The backlog's "single highest-value idea", and a data-model change
  rather than chrome. `LooseEndStatus` over the `status` column that shipped in Phase 1B and that
  **nothing had ever written** (968 rows, all `open`); the stored strings are unchanged, so **v12 adds
  only a nullable `resolvedAt`**. **`isOpen` was not edited** beyond retyping its literal — that is what
  carries resolution into the detail view, the menu-bar count, App-Intents facts, What's-Next ranking,
  the search corpus and Spotlight for free. New: one `resolve` verb (+ per-node `resolveAllOpen`), three
  feeds, `isActionable` at the three "what should I pick up next" surfaces, index **schema v4** with one
  allow-list rendered into both the SQL filter and the canonical re-check, closed ends in the corpus,
  and the app surfaces (verbs with undo, two sidebar buckets, Done · N record, widened ⌥⌘F scope, bulk
  close). **`isActionable` is two-part on measured grounds** (`openLooseEnds > 0 || closedLooseEnds == 0`):
  123 of 162 active nodes are git-only and can never produce a loose end, so the naive predicate would
  have emptied What's Next of 130 nodes on day one.
  **What the two reviews caught, and what it cost:** resolving updated **no list until ⌘R** (the feeds
  key on `refreshToken`, which `refresh()` never bumps — now a dedicated `looseEndRevision`), and bulk
  close **closed more than its dialog counted** (`status`-only vs `isOpen`, stranding 👎 ends on no
  surface). Both were invisible to the test suite because the app target has none.
  **A false premise the spec, the plan and three comments shared:** a stale search index does **not**
  shrink the result page — `SearchQueries` over-fetches ×8 and grows `k`, so it backfills around the row
  the resolver drops. The real hole is the **reopen** direction, where a stale `done` excludes live work
  in SQL and the resolver never sees a candidate. Found by *running* the mutation: the plan's
  index-freshness test **and my first replacement for it** both passed with `updateStatus` deleted.
  Lesson worth keeping: a test for a staleness bug must be asserted at the layer where staleness is
  observable (here the store), not through a query path designed to paper over it.
- **"Where was I" — design slice A, the reload-context pass** (2026-08-12, merged to `main`;
  human-verified the same day, outcome in `docs/superpowers/verify/2026-08-11-where-was-i-human-verify.md`).
  Detail pane leads with an **adaptive state line** (`NodeMetaLine`) instead of the repeated kind/state
  pair, **cited loose ends now come BEFORE the recap** and the recap is a headerless closing paragraph
  (a caps header announces a slot, and narration is allowed to be nil); middle-column rows carry
  **recency + open count** instead of "Projekt / Projekt / Projekt"; Briefing **weights moved work and
  collapses the quiet**; thumbs moved off the permanent row onto hover. Kit grew `lastActivityAt` on
  `NodeFacts`/`BriefingCard` and a batched `NodeRowFacts` (two grouped aggregates). The verify pass found
  **one real defect, fixed**: hover-revealed thumbs were unreachable because the `Spacer()` between text
  and thumbs is dead space to hit-testing (`.contentShape(Rectangle())`). Four findings that belong
  elsewhere were logged to `backlog.md` — see "What the verify pass turned up" below.
- **In-node find (⌘F)** (merged to `main` 2026-08-12; built 2026-08-11 on `worktree-in-node-find`). The
  detail pane got its own find
  bar, and **the keybindings swapped: ⌘F is now find-within-the-open-node, ⌥⌘F is search-everything.**
  Literal substring search over everything the pane renders — name, description, narration, loose-end
  text, and the **transcript windows behind collapsed provenance rows** — highlighted in place, ⌘G/⇧⌘G
  in on-screen order. `FindMatcher` is now the **single** definition of Pensieve's compare options
  (`SnippetMaker` reads it); `NodeFindDocument` fills a **pre-allocated slot per loose end in place** so
  the async sweep can't reorder ⌘G, and resolves to transcript units **XOR** the quote; `FindSession`
  tracks the current match by **identity, not ordinal**; `ProvenanceLoader` parses each transcript **once**
  and invalidates on `(size, mtime)` — **not** `refreshToken`, which never bumps on the watch path.
  Accepted trade-off: **flatten-on-match** (a matched transcript segment shows raw Markdown syntax while
  the bar is open — MarkdownUI 2.4.1's AST is `internal`). Trust gate untouched; read-only throughout.
  **The merge with slice A was not mechanical, and one defect existed only in the combination:** slice A
  moved the recap below the loose ends, but `NodeFindDocument.make` still emitted the narration slot
  *before* them. ⌘G walks document order and the type's own contract is "order matches on-screen order",
  so the slot moved and `documentOrderFollowsOnScreenOrder` now pins the new order. Neither branch could
  have caught it alone. The merge also pushed `AppModel.swift` to 404 lines (`swiftlint --strict`, which
  CI runs, caps files at 400), so `commitNewNode`/`updateNode` moved into `AppModel+Organizing.swift`
  where the rest of the organizing writes already live.
- **Retrieval P1 + P2′ — BM25 replaces the search engine** (2026-08-11, merged to `main`). Closed the
  inert-floor defect by discarding its diagnosis: a **ranking** failure, not a **scale** failure, so no
  floor could ever have fixed it.
  FTS5 + `bm25()` (`SearchIndexStore`, schema v2, hash-guarded whole rebuild) + a pure `FTSQueryBuilder`
  (**raw input never reaches `MATCH`**) replaced **both** the substring matcher **and** the vector index
  as the default engine; vector is retained, tested, default-**OFF**. **The floor is gone, not retuned**
  — a rank cap is not a relevance threshold. File paths joined the corpus in their **own** FTS5 table,
  because the pre-registered gate **rejected** sharing one (FTS5 normalises `bm25()` by the row's TOTAL
  token count across columns; McNemar p = 0.017 at n=1500). One ranked list + pinned Top Hit across ⌘F
  and MCP, plus an `index_state` so an unbuilt index ≠ a real miss. BM25 P@1 **0.395** vs vector
  **0.255**. Grounding unchanged (one shared `SearchHitResolver`, one `NodeState.searchable` allow-list
  rendered into both the SQL filter and the re-check); **trust gate untouched**. **576 tests.** Two Opus
  reviews (whole-branch + a focused pass over Tasks 8–13, which had shipped with **no** per-task review)
  → 0 Critical, and the whole converged fix wave applied — most seriously an index path that ignored
  `PENSIEVE_DB`, which made the project's own smoke-test recipe wipe the **live** index. Spec/plan:
  `{specs}/2026-07-28-retrieval-eval-harness-design.md` + `{plans}/2026-08-03-retrieval-bm25-single-path.md`.
- **Transcript readability — chat rendering + harness vocabulary + type scale** (2026-07-26, merged
  `4b184a3`). The inline provenance view renders a transcript window as readable chat instead of a flat
  list of raw-tagged text. **Kit (tested, pure):** `TranscriptVocabulary` — **two members, not one list**:
  renderer tag names vs a **FROZEN** `injectionMarkers` (moved verbatim out of `isInjectedOrCommand`,
  pinned by test) so a tag added for *display* can never silently change *extraction*; `TranscriptMarkup`
  — one left-to-right scan where the outermost construct wins (precedence code → callout → harness →
  placeholder → orphan close → prose, CommonMark-pinned code protection, forward-only pairing, no-loss);
  `SpeakerClass.of` is **conjunctive on purpose** (309 genuine user records in this repo's transcripts
  contain envelope markers — a disjunctive rule would have the app assert you didn't write what you did).
  **App (thin):** `TranscriptSegmentView` + `TranscriptMessageView`; `LooseEndRow`'s two paths gain
  `compact:`, threaded through three call sites. Chrome localized en+de; message text/quotes/tag names
  stay verbatim. **Trust gate untouched.** **524 tests** (+59 Kit). **Human-verify:** the Task 8 eyeball
  matrix (needs the reinstall above). Spec/plan: `{specs,plans}/2026-07-19-transcript-readability*`.
- **App-quality cleanup pass** (2026-07-19). Three carries: `NodeKind`/`NodeState` → real
  `RawRepresentable` enums (**on-disk format byte-identical**, no migration); `AppModel.pruneNarrationCache`
  bounds the cache against the **FULL** node set (Focus-muted/archived keep theirs); `AppModel` →
  `@Observable`. An Opus review caught `allNodes` wrongly `@ObservationIgnored` (broke cold-restore recall
  windows) — fixed. **Human-verify:** the invalidation eyeball list, esp. cold-restore ⌘⌥N.
- **Archived content in the semantic index / "Related"** (2026-07-19). Closed the deferred item below:
  `EmbeddableCorpus.gather` now indexes archived nodes/loose ends/events tagged with live `state`;
  `knn`/`search` grow an allow-list `includeArchived` (defaulted `false`) with `resolve`'s canonical
  re-check widened in lockstep; hits carry `isArchived`. The ⌘F Include Archived scope now drives **both**
  halves; MCP `search` passes the flag through to semantic results (a final review caught it dropped at
  the MCP boundary). **465 tests.**
- **Spotlight loose-end indexing — Track C 1b** (2026-07-19, merged `c60e624`). Open loose ends are indexed
  into macOS Spotlight (previously nodes only) — a phrase from a loose end's text **or its cited quote**
  returns that item and opens Pensieve at it. New `DeepLink.looseEnd(UUID)` + `LooseEndFacts` (searchable
  corpus = open ends in active nodes; degrade-safe any-state by-id quarantined to tap resolution);
  `LooseEndEntity` **must be registered in `PensieveShortcuts`** or Spotlight never surfaces it. **445 tests.**
- **Semantic-recall hardening + include-archived ⌘F search** (2026-07-19, merged `3ece8b5`). Four small
  items over the shipped semantic stack. **(A)** Include-archived toggle for **exact** ⌘F (defaulted
  `SearchQueries.search(includeArchived:)` + a native `.searchScopes` bar); semantic "Related" stayed
  active-only **at the time** because the index held no archived content — **since closed**, see the
  archived-semantic-index ship above. **(B)** A regression test pinning the
  same-version rebuild invariant (no prod change — the guard already ships and is race-safe; the planned
  transaction fix was proven a no-op by review). **(C)** MCP `PensieveMCP` caches its embedder+store in
  `static let` instead of per-call. **(D)** `SemanticQueries.search` expand-and-retry under Focus-muting
  with a floor-aware early exit (extracted `buildHits`, all grounding guards preserved). Trust gate
  untouched. Tasks 1–4 subagent-driven (Opus whole-branch = READY-TO-MERGE); Task 5 (app toggle) inline.
  **448 tests.** **Post-merge carry:** rebuild + reinstall to `/Applications` (Part C + the app toggle).
  **Human-verify:** the `.searchScopes` bar renders under `.sidebar` (fallback = header Picker, in the
  plan); toggle includes/excludes archived; German in-situ. Spec/plan: `{specs,plans}/2026-07-19-semantic-recall-hardening*`.
- **Semantic / vector recall — Track C #2** (2026-07-18, merged `e640645`) — **REMOVED 2026-08-11** after
  measuring worse than BM25; kept here as a record of what happened. "Find without exact words"
  across ⌘F ("Related" section) and a unified MCP `search` tool, over one shared Kit kernel. Native
  `NLContextualEmbedding` + vendored `sqlite-vec` (registered **per-connection** — Apple disables the
  process-global path) in a **separate, rebuildable, never-synced `semantic-index.sqlite`**; incremental
  membership-driven indexer runs in the daemon + app sync paths; KNN over-fetch + a canonical join that
  re-applies the live predicate (grounded-retrieval-only; on-device only). Default-on Settings toggle.
  **439 tests.** **Post-merge carry:** rebuild + reinstall the app to `/Applications` so the bundled
  `pensieve mcp` exposes `search`. Spec/plan: `docs/superpowers/{specs,plans}/2026-07-18-semantic-vector-recall*`.
- **Bundle the `pensieve` CLI into the app** (2026-07-17, through `3a9092c` 2026-07-18). The CLI is now
  an embedded Xcode **tool target** (`PensieveCLI`, `PRODUCT_NAME=pensieve`) at
  `Pensieve.app/Contents/Helpers/pensieve`; `~/.local/bin/pensieve` is an **app-managed symlink** to it,
  auto-created on launch (guarded off `.build`) and installable/repairable/replaceable via **Settings ▸
  General ▸ Command-line tool**. Tested `CLIToolInstaller` kernel. **Updating the app now updates the
  CLI** — the old "rebuild + reinstall the release CLI" step is retired. **`swift run pensieve` no longer
  exists** — build via `xcodebuild -scheme PensieveCLI` (or the app scheme, which embeds it). Spec/plan:
  `{specs,plans}/2026-07-16-bundle-cli-into-app-design.md` + `2026-07-17-bundle-cli-into-app.md`.
- **Background sync via a bundled `SMAppService.agent`** (2026-07-16). Retired the hand-installed
  `com.pensieve.sync` LaunchAgent for a code-signed agent (`me.mazetti.pensieve.sync`) bundled inside the
  app, running the same `SyncRunner` every 300 s independently of the GUI. `BackgroundSyncService`
  (register/unregister/status), guarded off `.build`. **Gotcha:** must run from `/Applications/Pensieve.app`
  (SMAppService pins path + cdhash); `registerIfNeeded()` does unregister+register to survive ad-hoc
  cdhash churn. Approve once in System Settings ▸ Login Items.
- **App Settings v2 + organizing-writes error surfacing** (2026-07-14). Native tabbed Settings
  (**General · Intelligence · Advanced**) over a tested `SystemStatus` kernel; first-party About panel.
  The six organizing writes (create/rename/move/merge/delete + loose-end label) **no longer `try?`-swallow**
  — each classifies into a **refusal** (non-success return = stale state → refresh + gentle alert) or a
  **failure** (a throw → alert, no refresh) via `AppError`/`presentedError` → one `.alert` in `RootView`.
  **This closed Track B.**
- **Archive nodes** (2026-07-14). The escape hatch for stale work `delete` refuses. Archive/unarchive a
  whole subtree; archived nodes leave every normal view into a collapsed **Archived** sidebar section; new
  git/session activity resurfaces the node **and its ancestor chain** (ingest path only).
- **MCP `recall` tool** (2026-07-11). Loose-end-keyed read-only MCP tool → the surrounding transcript
  window via the tested `ProvenanceQueries` kernel (verbatim, inside the trust gate). Closed the
  "pointers, not passages" ceiling that `pensieve mcp` first exposed.

## THE NEXT ACTION — pick a track (each its own brainstorm→spec→plan)

**The install carry is CLOSED** (2026-08-13 22:56 — see "Where things stand"), and background sync is
confirmed running. **Nothing mechanical is owed.** What remains is the part no agent can do: walk the
**human-verify carries** at the bottom of this file. There are now **four unrun lists** — retrieval/BM25,
in-node find, loose-end resolution, and slice 5 — plus two verify documents with blank outcome lines,
`verify/2026-08-12-macos26-floor-human-verify.md` (slice B) and the completed
`verify/2026-08-11-where-was-i-human-verify.md` (slice A, the one that *was* run, and which found a real
defect). **The backlog of unverified GUI work is now the largest standing risk in the project** — the app
target has no unit tests, and every defect the last two whole-branch reviews caught was invisible to the
suite for exactly that reason.

**THEN — the honest shortlist.** Nothing is half-built, so the next move is a genuine choice:

- **Design slice C — transcript reading: one rail, no nested cards.** *(The recommended next design
  slice — A and B are done and the backlog marks C "live now".)* The provenance transcript nests three
  near-identical gray surfaces (message card inside system card inside HINWEIS/BEFEHL card) with the
  speaker as an 11pt label **outside** the outermost one, so it reads as a log, not a conversation.
  Proposal: a **speaker column** carries the structure; only user messages get a filled bubble (they are
  the minority and the thing being hunted for); assistant replies sit free on the page as prose; harness
  events collapse to one folded `DisclosureGroup`; attached skill documents become a chip, not an
  embedded article; Markdown H1 inside a transcript never renders larger than the app's own headings.
  It was sequenced *behind* in-node find because both rewrite `LooseEndRow.swift` and
  `TranscriptSegmentView.swift`; that block cleared on 2026-08-12, and in-node find's accepted
  **flatten-on-match** trade-off lives in exactly those two files, so C is the natural place to revisit
  it.
- **Slice B's two open carries** — small, well-specified, and both parked on a trigger that has now
  arrived (`backlog.md` ▸ "B's two open carries"):
  - **Scroll-edge material covers 4 of ~9 scroll surfaces.** `.scrollEdgeEffectStyle(.soft, for: .top)`
    sits on `SidebarView`, `ContentListView`, `BriefingView`, `DetailView`. Untreated: the three Settings
    `Form`s, `MovePicker`/`MergePicker` (lists scrolling under a `navigationTitle` — the textbook case),
    the `NodeEditor` `Form`, and both `IconPicker` grids. The four shipped sites already rely on the
    modifier propagating down a subtree, which is the argument it can be **hoisted to one call per scene**
    (`RootView`, `RecallWindowView`, `SettingsView`) — closing the gap *and* making later scroll views
    inherit it. **Needs a GUI session, not a green build:** propagation into sheet-presented content is
    the unverified part, and getting it wrong silently removes the effect from surfaces slice B
    deliberately treated.
  - **`NextItem` lacks `lastActivityAt`,** so the popover buys its second line with two whole-database
    aggregates. `NextQueries.ranked` *already* fetches the latest `Event` per project and discards the
    `Date`, keeping only `daysDormant`; `NodeFacts` wrote down exactly the right pattern (carry the
    `Date` beside the `Int`, views read the `Date`, ranking reads the `Int`). Adding the field lets the
    row render from the item it already holds and deletes a query from `refreshGlance()`. Adjacent and
    **pre-existing**: `ranked` runs `2N` queries per refresh and `looseEnds` has no index on `nodeID`.
- **Use loose-end resolution in anger.** 976 open ends, 288 on one node, **zero closed**. The queue and
  the bulk close were built for exactly this. Two design questions can only be answered by walking it:
  whether the **triage feed's ordering** survives contact with real burn-down (suggested-salient first,
  then oldest — measured, but nobody has actually walked it), and whether **Review Suggestions** wants a
  `status` scope control now that it deliberately keeps closed items.
- **Transcript-passage chunking** — **the shortest path to shipping**, because the spec is already
  written (`specs/2026-07-19-transcript-passage-chunking-design.md`, committed `35b0ed1`) and only a
  plan is missing. The next corpus increment for BM25.

**AND — P3, the paraphrase harness, is the one open retrieval question, and it is blocked on YOU.**
Both engines fail "find without remembering the words" (`vector` ≈0/8, `bm25` ≈2/8 on short paraphrase
queries), and the gold set that produced BM25's headline win uses **full documents as queries**, which
flatters lexical matching in a way real typed queries do not. Unblocking it needs **30–50 paraphrase
queries you write**, each naming what it should find — deliberately yours, because as sole user your
queries *are* the ground truth. Design is already written (spec §P3): two files, per-query-normalised
operating points, an explicit `NO VIABLE THRESHOLD` verdict, and a pre-registered absolute floor so the
report can conclude "the incumbent is unusable".

**Track A — the three-pane app (the product spine).** Everything through Share-recall, archive,
error-surfacing and now **slice 5 (talk-to-system, merged 2026-08-13)** has shipped. Next: **slice 6
(forks)** — **gated on the unbuilt fork-capture backend, so brainstorm that backend first**; the slice
cannot start until there is something capturing forks to display. Design:
`specs/2026-07-05-pensieve-app-three-pane-design.md`. Also left open by slice 5, deferred **by
measurement rather than argument**: model-assisted *parenting*. The original design had BM25 shortlist
candidate parents from the typed sentence, but `FTSQueryBuilder` AND-joins every term, so a realistic
quick-add sentence retrieves **zero** rows. The alternative that does work (OR-aggregating across all
three hit kinds) is gated on its own committed measurement — `backlog.md` ▸ "Deferred, with triggers".

**Track B — DONE.** Both threads shipped: the cloud/API `LLMProvider` (2026-07-09) and organizing-writes
error surfacing (2026-07-14). Nothing open. (Spec 2's deferred source-management GUI + daemon-interval
editing remain parked in `backlog.md`, not part of Track B.)

**Track C — findability / OS-integration.** The global search field (now **⌥⌘F**), the menu-bar item,
`pensieve://`, App
Intents + Spotlight, Focus filters, **Spotlight loose-end indexing (1b, 2026-07-19)**, **transcript
readability (2026-07-26)**, **retrieval P1+P2′ / BM25 (2026-08-11)**, **in-node find (⌘F,
2026-08-12)** and **on-device translation (2026-08-12 — translated text is indexed, so the German you
read is the German you can find)** are live. **Semantic/vector
recall (#2) and its two 2026-07-19 follow-ups were built, measured worse than BM25, and removed on
2026-08-11** — they hardened an engine that no longer exists. Remaining:
- **Transcript-passage chunking** — the next corpus increment. **The spec is already written**
  (`specs/2026-07-19-transcript-passage-chunking-design.md`, committed `35b0ed1`) — **no plan yet**, so
  this is the shortest path to shipping. Would also make the Part D `maxFetch=2000` cap worth revisiting.
- **Newly-live revisit triggers** from the readability spec's parked siblings (`backlog.md:245`): rich
  code blocks (syntax highlighting + diagrams — corpus evidence says **Graphviz DOT, not Mermaid**, so a
  Mermaid-only renderer may buy nothing) and macOS Writing Tools on loose ends (**spike feasibility
  first** — MarkdownUI's custom views may put it out of reach entirely).

**Blocked — do not start:** Widgets + CloudKit need a **paid Apple Developer team** (App Groups / Team-ID
entitlement). That single gate unblocks the whole extension family at once (Focus filters too); revisit only
when a paid membership is in hand **and active** — *purchased 2026-08-15, but not yet showing in Xcode ▸
Settings ▸ Accounts or on the Membership page, so the gate is still closed*. See `backlog.md`
"Widgets — DEFERRED".

## LIVE deployment state

- **CLI:** bundled inside `Pensieve.app` at `Contents/Helpers/pensieve`; `~/.local/bin/pensieve` is the
  app-managed symlink external callers (git hooks, `~/.claude/settings.json`, `claude mcp add`) resolve.
  Keep `~/.local/bin` on `PATH`. No manual CLI rebuild/reinstall anymore — updating the app updates it.
- **Background sync: ❌ DOWN since 2026-08-13T21:41Z (an install broke it, and no known remedy fixed
  it).** The bundled `SMAppService.agent` `me.mazetti.pensieve.sync` spawn-fails with
  `needs LWCR update` in its launchd `properties`, `job state = spawn failed`, and
  `OS_REASON_CODESIGNING` then `EX_CONFIG`. **This recurs on every install** — it also happened at the
  22:56 install the same evening, where a quit + relaunch cleared it on the first try. That remedy then
  failed three times in a row after the 23:41 install, so **treat "quit and relaunch" as worth trying,
  not as a fix.** Watch: `tail -f ~/Library/Logs/Pensieve/sync.log`, or
  `launchctl print gui/$(id -u)/me.mazetti.pensieve.sync | grep -E 'runs|last exit|properties'`.
  A healthy agent reads `job state = running` with **no** `needs LWCR update`, and writes a `sync.log`
  line within 300 s.

  **What is NOT broken, established by running it:** the helper binary executes fine when invoked
  directly (`/Applications/Pensieve.app/Contents/Library/Helpers/PensieveSyncAgent` → exit 0, real work,
  a `sync.log` line). So the binary and its ad-hoc signature are sound and **no data is at risk** —
  capture still spools and the app still drains on launch and on the watch path. What is lost is
  unattended sync while the GUI is closed. **A manual run of that binary is a working stopgap.**

  **Refuted tonight (add to the eight in `backlog.md` ▸ "Background sync is dead"):**
  *competing LaunchServices registrations are not the cause.* Four bundles were registered under
  `me.mazetti.pensieve` (`/Applications`, the repo's `.build-xcode`, and two worktree copies — one
  whose worktree no longer exists, since every `xcodebuild` runs `lsregister -f -R -trusted`). Dropping
  all three non-`/Applications` entries with `lsregister -u` left exactly one registration and the
  agent **still** spawn-failed unchanged. Worth knowing the entries accumulate; it is not this bug.

  **Not yet tried:** unregister/re-register through the GUI (Settings ▸ General), which is the one path
  that exercises `BackgroundSyncService.register()` with a user gesture rather than at launch; and a
  reboot, which is the crude test of whether the constraint is cached in a daemon's memory.
- **Hooks** in `~/.claude/settings.json`: SessionStart (`capture-session-start` + `pensieve prime`) +
  SessionEnd. **MCP:** `pensieve mcp` registered at user scope (`claude mcp get pensieve` → Connected).
- **Real stores:** `~/Library/Application Support/Pensieve/{pensieve,capture}.sqlite`.

## How we work here (follow this exactly)

Design-first, subagent-driven. The proven loop, per feature:
1. `superpowers:brainstorming` → clarify → spec under `docs/superpowers/specs/`.
2. **Adversarial spec review before coding** (new feature/backend): 1–2 independent Opus subagents review
   the spec against the real code; fold findings back in.
3. `superpowers:writing-plans` → task-by-task plan with full code under `docs/superpowers/plans/`.
4. `superpowers:subagent-driven-development` → **isolated git worktree**, fresh ledger at
   `<worktree>/.superpowers/sdd/progress.md`, one implementer + one task-reviewer per task, an **Opus**
   whole-branch review, fix waves, then `superpowers:finishing-a-development-branch` (user merges to main
   locally; then remove the worktree + delete the branch).
- **Model choice:** implementers + task-reviewers = **Sonnet**; whole-branch review = **Opus**. Avoid
  Haiku implementers (they've edited shared/production code to satisfy a test assertion).
- Skill helper scripts: `scripts/task-brief PLAN N [OUT]` and `scripts/review-package BASE HEAD [OUT]`
  under the subagent-driven-development skill dir. Hand subagents **file paths**, not pasted text.
- **App verification is headless-ish:** `xcodebuild` build + a non-blocking smoke-launch of the inner
  binary (`./.build-xcode/Build/Products/Debug/Pensieve.app/Contents/MacOS/Pensieve`, background + `kill`,
  throwaway `PENSIEVE_DB`/`PENSIEVE_CAPTURE_DB`). Interactive layout / OS-integration checks (Spotlight,
  Siri, Focus, Login Items) are the user's to run — the accessibility sandbox blocks scripting them.

## Gotchas

**Process / environment**
- **`log` is shadowed by a shell function here — always use `/usr/bin/log`.** A bare
  `log show --predicate …` fails with `(eval):log:1: too many arguments` and prints **nothing**, which
  reads exactly like "no matching events". This cost a wrong conclusion during the background-sync
  investigation (2026-08-12): the code-signing kills were in the log the whole time. The commands in
  the **Observability** section of `CLAUDE.md` are affected — prefix them.
- **`xcodebuild … | tail` reports `tail`'s exit code, not the build's.** `echo "exit=$?"` after a pipe
  is meaningless; a failed build looked successful this way (2026-08-12). Redirect to a log, check `$?`
  unpiped, and grep for the `** BUILD SUCCEEDED **` marker.
- **Work each feature in an isolated `git worktree`** (`git worktree add ../pensieve-<slice> -b feat/<name>`);
  remove on merge. Two efforts in the *same* checkout collided badly once. Confirm no stray `claude`
  process before subagent-driven runs in a shared worktree (a ghost SDD controller once ran a plan in
  parallel — harmless that time, but a reminder).
- Merging a branch that adds files existing **untracked** in the main checkout can abort a fast-forward;
  back the untracked copy aside, then merge.
- **Commit messages: backticks in a double-quoted `git commit -m "..."` get shell-executed** — use
  `git commit -F <heredoc with quoted 'EOF'>`. Keep the `Co-Authored-By:` + `Claude-Session:` trailers.
- **Do NOT set `PENSIEVE_DB` / `PENSIEVE_CAPTURE_DB` when touching the LIVE store.** App/CLI smoke tests
  SHOULD set them (to a `/tmp` path) to avoid perturbing real data.
- The app **must run from `/Applications/Pensieve.app`** for SMAppService — `rm -rf .build-xcode` would
  delete a registered bundle. `xcodebuild` + SPM macros: first build on a fresh machine needs the macro
  fingerprints trusted (Xcode "Trust & Enable", or the two `defaults write …IDESkip{PackagePlugin,Macro}
  FingerprintValidation` per-machine flags).
- On a SwiftSyntax/macro **linker error**, `rm -rf .build` and retry (recurs intermittently).
- **The CLI symlink auto-create does NOT overwrite a stale real binary.** Found 2026-07-19: a pre-bundling
  `pensieve` *binary* (Jul 11) was still sitting at `~/.local/bin/pensieve`, so the launch-time auto-create
  — which only fires when the path is **absent** — silently never ran. The registered MCP server and the
  `prime` SessionStart hook had been running 8-day-old code since the CLI-bundling ship. After installing a
  new app, verify with `ls -l ~/.local/bin/pensieve` that it is a **symlink** into
  `/Applications/Pensieve.app/Contents/Helpers/`; if not, use Settings ▸ General ▸ Command-line tool ▸
  Replace (`forceLink`) or relink by hand.

**Swift / SwiftUI**
- Predicates: `.eq(x)` NOT `== x`. Reuse `SourceKind`/`CaptureKind` constants. No shared mutable
  `static ISO8601DateFormatter` (Swift 6).
- **The app (`Sources/PensieveApp/`) has no unit tests** — put derivation logic in tested PensieveKit,
  keep views thin. App reads are read-only; the only canonical writer is `Ingester.drain()`.
- **The app is built by XcodeGen + Xcode** (`project.yml` is the source of truth; single SwiftUI `Window`
  scene). Build: `xcodegen generate` → `xcodebuild -project Pensieve.xcodeproj -scheme Pensieve
  -configuration Debug -derivedDataPath ./.build-xcode build`; app at
  `./.build-xcode/Build/Products/Debug/Pensieve.app`. `Pensieve.xcodeproj/` + `.build-xcode/` are
  gitignored. Prefer first-party primitives (`.commands`, scene restoration) — see "Platform primitives
  first" in `CLAUDE.md`.
- Foundation Models (on-device) is the default extractor; `claude -p` is the fallback (no API key). Cloud
  serves narration only; **extraction always stays on-device** (trust gate).

## Long-term vision (don't lose this)

The full, still-intended vision — none foreclosed — lives in `docs/superpowers/backlog.md` (Roadmap +
deferred ledger) and `docs/superpowers/specs/2026-07-03-pensieve-mvp-design.md`. Pillars beyond today:
CloudKit sync + iOS companion; more OS-integration surfaces (widgets, deeper Spotlight/semantic search,
Siri/Shortcuts depth); FSEvents real-time capture; additional non-git source types (Notion, Entra,
browser); analytics (dependency graphs, token-spend). Forward ideas: **forks as first-class**, **talk to
the system** (slice 5), statistical **theme discovery**, proactive project suggestion.

North star throughout: **grounded-with-provenance** — every AI-surfaced item cites real captured text or
it doesn't appear. The trust gate is sacred; the capture path must never block a git commit.

## What the slice-A verify pass turned up (2026-08-12) — all four filed in `backlog.md`

None of these blocked the slice; each wants its own decision, and they are easy to lose because they
were found by eye, not by a test.

- **Narration can still emit a facts-dump.** A real recap read *"Recent work on the cetacean project
  consisted of eight `cc.session` sessions. The sessions included 41, 54, 107, 41, 349, 28, and 410, and
  1 prompts."* No fabrication and no trust-gate issue — but slice A just promoted the recap to the
  closing paragraph of the detail pane, so the bar is higher. Wants a quality gate in
  `SummaryBuilder.narrate`: **prefer `nil` over prose that only restates event metadata.**
- **`Du` vs `user` in the same message.** The transcript bubble header renders the localized speaker
  class while the provenance footer directly below shows the raw role. Both are as-specified (header is
  chrome, role is content) — on screen they read as two labels for one speaker. **Needs a decision, not
  a fix.**
- **`Pensieve öffnen` truncates to `Pensieve öf…`** in the menu-bar popover. The string is correct; the
  three-button row is too narrow for German. Folded into design slice B, which rebuilds that surface.
- **Full Keyboard Access tab order is erratic** — the middle column is not reliably reachable.
  Pre-existing and app-wide, not specific to slice A.

**Two process notes from the same pass, worth not re-learning:** (1) `open ./.build-xcode/…` from the
main checkout launches **main's** app, not a worktree's — confirm with
`pgrep -lf Pensieve.app/Contents/MacOS/Pensieve` before concluding a branch regressed. (2) String
Catalog coverage is checkable **without eyes and more thoroughly** — parse `Localizable.xcstrings` for
keys missing a `de` value, compare format specifiers between `en` and `de`, and diff the localizable
Swift literals against the catalog's keys. That covers all 219 keys instead of five surfaces, and it is
what would have caught the six mis-keyed entries before they shipped. Forced-locale launch is still
worth doing for **layout**, just not for key coverage.

## Human-verify carries — the standing backlog (READ THIS FIRST)

**Five lists, four of them entirely unrun.** The app target has no unit tests, so this *is* the gate on
GUI work, not a formality — the last two whole-branch reviews each caught a defect that broke a feature
in ordinary use and was invisible to all 684 tests. The installed app is current (2026-08-13 22:56), so
every item below is runnable right now.

| Slice | Where | State |
|---|---|---|
| "Where was I" (slice A) | `verify/2026-08-11-where-was-i-human-verify.md` | ✅ **run 2026-08-12** — found 1 real defect (unreachable hover thumbs) + 6 mis-keyed catalog entries |
| macOS 26 floor / Liquid Glass (slice B) | `verify/2026-08-12-macos26-floor-human-verify.md` | ❌ unrun — blank outcome lines |
| retrieval / BM25 | this file, below | ❌ unrun |
| in-node find (⌘F) | this file, below | ❌ unrun |
| loose-end resolution | this file, below | ❌ unrun |
| talk-to-system slice 5 | this file, bottom | ❌ unrun |

**Slice B's list deserves one callout, because it is the one that can pass while being wrong:** its
first check asks you to toggle `.soft` ↔ `.hard` in the source and confirm the top band *visibly
changes*. "Material is visible at the top" **passes even when the modifier landed on the wrong view or
never applied at all** — the default is `.automatic`, which also looks like something. A comparison is
the only honest test.

## Human-verify carries — retrieval / BM25 (needs the reinstalled app + the real store)

From the plan's Post-merge carries plus the review fix wave. None of these can be checked headlessly.

- ⌘F a common term (`sync`, `app`) — does the **Top Hit** pin the node you meant, even when events fill
  the list? And does it never show a node the list itself would have excluded?
- ⌘F a multi-word query with no verbatim occurrence (`focus filter spotlight`) — the old matcher returned
  **nothing** here; it should now return real work.
- ⌘F a file path (`SemanticQueries.swift`) — do the commits that touched it come back? Note a *bare*
  filename works via the path probe, while `query` + `file` together mean **both must match**.
- **Every result row should visibly show why it matched** — this was a review finding. Especially a loose
  end that matches only inside its cited quote, and a German term typed without umlauts (`losung`
  matching `Lösung`) — both used to render with nothing highlighted.
- Type an apostrophe, a colon, `C++`, an unbalanced quote — no crash, no error, no empty-because-broken.
- Delete `search-index.sqlite` with the app closed, relaunch, search immediately — do you get
  "building"/"not built" rather than a bare "no results"?
- **Index freshness (review fix):** with the app open, make a commit in another window and wait for the
  watcher; the new work should become findable in ⌘F **without** pressing ⌘R.
- Does the `.searchScopes` bar render under `.sidebar` placement? (Carried from the previous batch;
  fallback = a segmented Picker in the results header, pre-specified in that plan.)
- German in-situ (`-AppleLanguages '(de)'`) for the new search strings.
- `pensieve mcp` from a Claude Code session: `search` returns `items` + `index_state`, the `file`
  parameter works, and a bare `file` with no `query` now works too.
- **Confirm the smoke-test fix holds:** run `PENSIEVE_DB=/tmp/x.sqlite pensieve sync`, then check
  `~/Library/Application Support/Pensieve/search-index.sqlite` is **untouched** (a sibling
  `/tmp/x-search-index.sqlite` should appear instead). This is the bug that used to wipe the live index.

> **Note:** every "⌘F" above means the *global* search field, which is now on **⌥⌘F** — see the in-node
> find carries below.

## Human-verify carries — in-node find (⌘F) (needs the built app + the real store)

The app target has no unit tests, so all of this is eyeball-only. The 122-open-loose-end `Pensieve` node
is the realistic fixture; only **18** of those have a live transcript, so pick a *recent* loose end when
testing the transcript path — an old one will correctly fall back to its stored quote.

- **The collapsed-transcript case** (the feature's whole point): ⌘F a phrase that exists only inside a
  transcript window behind a **collapsed** loose-end row. ⌘G should force-expand that row, scroll to the
  segment, and highlight the phrase in place. Then ⌘G past it and back — the position must not jump.
- **A late fill must not move you.** Type a query that matches early (name/description) while the sweep
  is still running (the bar shows `… searching transcripts N/M`). As transcript matches land *ahead* of
  you, the count grows and your ordinal renumbers, but you must stay on the **same** match.
- **Cross-window non-contamination:** ⌘⌥N a recall window, run a different find in each. Each window's
  bar, count and **force-expanded rows** must be independent — a find in one must not expand rows in the
  other. Then check Edit ▸ Find acts on whichever window has focus.
- **The three shipped `scrollTo(UUID)` landings still work** (they share the pane with the new
  `.id(FindAnchor)` sites): a Spotlight loose-end tap, a `pensieve://looseend/<uuid>` deep link, and an
  in-app ⌥⌘F result click all still land on and expand the cited row.
- **Flatten-on-match, deliberately:** ⌘F a word inside a message containing **bold** or a code fence. The
  matched segment flattens to raw syntax with the phrase highlighted; sibling segments stay Markdown;
  **closing the bar restores full Markdown everywhere.**
- **The cited-provenance orange bar still marks the correct message** in all three speaker classes while
  a find is open.
- **⌥⌘F muscle memory:** the global field still opens on ⌥⌘F, `Go ▸ Search Everything` reads right, and
  ⌘F inside the *global* search field still does something sane rather than fighting it.
- **Edit ▸ Find placement:** the submenu lands in the **Edit** menu (`CommandGroup(after: .textEditing)`),
  with Find / Find Next / Find Previous correctly enabled and disabled.
- **German in situ** (`-AppleLanguages '(de)'`), especially the **two interpolated** count strings —
  `N of M` and the sweep-progress line — plus "Keine Treffer" and the field placeholder.
- **Diacritic folding in the pane:** typing `losung` must highlight `Lösung` (same rule as the FTS5
  tokenizer), and `showsLooseEnds` behaviour: on a childless focused strand (loose ends live in the
  middle column) find must report **no** loose-end matches rather than matches with nowhere to scroll.
- **Watch for highlight/count skew** while doing the above — a row can briefly tint matches the count
  doesn't include and ⌘G can't reach (open, by decision; see `backlog.md` ▸ "In-node find —
  highlight/document skew"). Whether it's noticeable in practice is the revisit trigger.

## Human-verify carries — loose-end resolution (needs the reinstalled app + the real store)

Entirely unrun. The app target has no unit tests, and the two defects the reviews caught were both
invisible to the suite for exactly that reason — so this list is the real gate, not a formality. The
first item is the whole feature.

- **The burn-down loop itself.** Select **Loose Ends**, walk it with ↑↓, close several with the swipe,
  the context menu and ⌘⏎. As you go: does the **sidebar count drop**, does the **row leave the list**
  (the defect the review caught was that it did not, until ⌘R), does the **detail pane follow the cursor**
  onto each row's node with the cited row expanded, and does the queue **keep your place** in the middle
  column rather than navigating away from it?
- **⌘Z after a mis-key** restores the previous status *and* puts the row back in the queue. Then ⇧⌘Z
  redoes it, and ⌘Z again undoes it — the toggle must survive more than one cycle (it did not, before the
  fix wave).
- **A project actually finishes.** Close every open end on one small node: it must leave **What's Next**
  and stay in **Dormant**. `pensieve next` must agree with the app.
- **Bulk close says what it does.** On a node with 👎-labelled open ends, the confirmation's count must
  equal the number that actually close (this was wrong: it said 1 and closed 4). Then ⌘Z reopens exactly
  that set — not ends closed weeks earlier.
- **The per-node record.** "Done · N" appears only on nodes with closed ends, renders **last** in the
  pane, and reopening from inside it moves the row back up into Loose Ends.
- **Completed ordering** is genuinely most-recently-closed-first, and the done/dropped badges are right.
  Then undo a *done → dropped* flip and confirm the row does **not** jump to the top (the restored
  `resolvedAt` is what prevents that).
- **⌥⌘F, both scopes.** A phrase that exists only in a closed loose end returns nothing under **Active**
  and returns the **badged** row under **Include Archived & Closed** — and clicking that result opens the
  node with the record **expanded on the cited row** (it opened showing nothing, before the fix wave).
- **A reopened end becomes findable again** without ⌘R or a relaunch. This is the one place a stale index
  is a correctness bug rather than wasted work.
- **Spotlight does NOT return closed ends** — that is spec D8, deliberate.
- **MCP from a real session** (after reinstalling): `search` with `include_archived: true` returns items
  carrying `"closed": true`, and `whats_next` no longer lists projects with no open ends.
- **Review Suggestions keeps closed items, and badges them** (spec D9 — a closed end is still labellable),
  and the suggester now proposes for closed ends too, so `pensieve suggest` has more candidates than
  before. Sanity-check the count before spending on-device calls.
- **German in situ** (`-AppleLanguages '(de)'`): the two sidebar rows ("Lose Enden" / "Abgeschlossen" —
  note the catalog's established vocabulary is *Enden*, not *Fäden*), both badges, "Erledigt · N", the
  widened scope option, the **plural** confirmation ("Ein loses Ende abschließen?" for exactly one), and
  the undo action name in the Edit menu.
- **Focus scoping:** with a Work focus active, both new buckets show only work nodes' ends.
- **Idle cost:** the sidebar count is now a count query rather than a feed build, but `refresh()` still
  runs on every debounced watch event. If the app feels heavier while a drain is running, that is where
  to look.

## Talk-to-system slice 5 — whole-branch review carries (2026-08-13, decisions not code changes)

The review returned NOT READY on one Important (an embedded newline could reach `nodes.name` —
**fixed**, see `TextQuality.shorten`/`sanitizeLabel` now collapsing every whitespace run to one space
before either the length check or the gate check, on this branch). Three further findings were judged
benign and are recorded here rather than changed:

1. **Spec deviation, recorded.** Spec line 195 says *"The task is held in `@State` and cancelled on
   dismiss."* The shipped code launches a bare `Task { await suggestName() }`. Judged benign —
   `commit()` snapshots `name` before `dismiss()`, and the orphaned task writes to a torn-down view's
   `@State`. The residue is a stray in-flight provider call outliving the sheet.
2. **Edit-save writes `description` from a stale snapshot.** `NodeEditRequest.mode = .edit(node)`
   captures a `Node` value at menu-click; a concurrent background write (realistically
   `Ingester.nameStrand`, which writes name AND description from the 300 s agent) is silently reverted
   on Save. Low likelihood; `name`/`kind`/`icon` already had this exposure, so it extends an existing
   pattern rather than creating a new class.
3. **Taxonomy gap.** `defaultKind(under:)` returns `.project` under a `strand`, so pressing "+" while
   reading a strand nests a project inside a strand. The spec's decisive 281/281 "kind is a pure
   function of parent" measurement was taken on a store where NO node has a strand parent, so
   selection-parenting now reaches a region that measurement never covered. Nothing breaks and the Type
   picker can correct it.

## Human-verify carries — talk-to-system slice 5 (needs the built app + the real store)

Mirrors the plan's own ledger (`docs/superpowers/plans/2026-08-13-talk-to-system-slice5.md`), with the
Return-key item promoted to the top per the review — it is a keystroke away, not an edge case, because
the sheet's Save owns `.keyboardShortcut(.defaultAction)` and the Description field is
`axis: .vertical`.

- **Pressing Return in the Description field must not trigger Save** — a half-typed multi-line
  description must never save on a stray Return.
- Type an **English** sentence, press Suggest — a terse readable label appears in Name, and the
  sentence stays in Description untouched.
- Type a **German** sentence, press Suggest — the name comes back **in German**, never translated.
  This is the whole reason the routing exists.
- Press Suggest, then immediately type in Name — your text survives; the suggestion is discarded.
- Select a cloud provider with no API key, press Suggest — a name still appears (the deterministic
  shortening), no error, and Save is enabled.
- Type a description with an embedded line break (paste a two-line note), press Suggest, then Save —
  the stored name must render as one line everywhere (sidebar, `NodeTree.render`, search snippets,
  Spotlight), never with the break intact.
- Edit an existing node: its description loads, edits save, and editing only the *name* leaves the
  description intact.
- ⌘N with a project selected creates **under it**; with an archived node selected, at top level.
- `pensieve list` shows the node where the app said it would.
- German in situ: `open -a Pensieve --args -AppleLanguages '(de)'` — check "Beschreibung",
  "Namen vorschlagen", "Worum geht es?" and that none of them truncate.

## Human-verify carries — custom store location (needs the built app installed at `/Applications` + the real store)

**The end-to-end move is UNVERIFIED BY AUTOMATION, and this is not a gap that could have been closed
cheaply.** `make uitest` isolates the SQLite store behind a temp path, but it does **not** isolate
`UserDefaults` — `RelocationLauncher.requestRelocation` writes `pendingRelocationDestination` and
`StoreRelocator` writes `customSupportRoot` into the same shared `me.mazetti.pensieve` domain the real,
185-project install reads. An automated test that actually triggered a relocation would repoint that
live install at a temp folder the moment the test ran, and setting the pending key on the live app would
start a real relocation at its *next* ordinary launch. So the execution ledger drew a hard line
(ruling R9): **Task 7** (the Locations-pane redesign — pure presentation, read-only) has real
accessibility-tree evidence from a scratch-built `uiprobe` against its own throwaway store. **Tasks 6**
(launch-time relocation gating) **and 8** (the ⓘ inspector, folder picker, confirmation dialog) have
**build-and-inspection evidence only** — no view body in either has ever executed. Making the relocation
path itself automatable needs the defaults domain isolated first (a launch-argument override reaches
`NSArgumentDomain`, but the relocator's own `defaults.set` would still persist past it) — that is real
work, filed in `backlog.md`, not done here. Everything below is therefore the *first* real exercise of
this feature, not a confirmation of something already checked:

- **The pane reads better.** Each location's path is on its own line, legible, non-monospaced,
  selectable (no more `.truncationMode(.middle)` swallowing the middle of `/Users/…nsieve/pensieve.sqlite`
  into a tooltip-only string); the `arrow.right` reveals the *correct* file in Finder for each of Support
  Folder / Canonical Store / Capture Spool / Logs; switching between Settings tabs never jumps the window
  (width stays pinned at 460 on all four tabs).
- **A same-volume move** (e.g. to `~/Documents`) completes, relaunches, and shows the same project count
  and loose-end count as before.
- **A cross-volume move** (an external disk) does the same. **This is the case the lock exists for** —
  a same-volume move alone cannot exercise the inode-binding hazard `StoreRelocationLock`'s anchor was
  placed outside the support folder to avoid.
- **The old folder is in the Bin, not gone** — `StoreRelocator` recycles via `NSWorkspace`, never
  `unlink`.
- **`pensieve list` (the freshly built CLI, not the stale `~/.local/bin` symlink) agrees with the app**
  after the move — the cross-process proof that a separate process actually reads the defaults key
  rather than a cached in-process value.
- **`tail -f ~/Library/Logs/Pensieve/sync.log`** shows the launchd `PensieveSyncAgent` resuming against
  the new location within ~300 s. **This closes the one open risk stated in the spec itself:**
  `PensieveDefaults.shared()`'s cross-process reads are proven from a CLI context (translation settings,
  `llmProvider`) but had never been verified from a **launchd-spawned helper** specifically until this
  check runs for real.
- **A `git commit` DURING the move** still shows up afterward — the step-6 property
  (`StoreRelocator.recoverPendingRows`) in situ: commit mid-copy, let the relocation finish, confirm the
  event isn't lost and isn't duplicated.
- **Reverting to Default** (via the ⓘ inspector's Location picker) moves the data back to
  `~/Library/Application Support/Pensieve` the same verified way.
- **German in situ** for the ~23 new keys (measured against `main` by diffing `Localizable.xcstrings`,
  not guessed): the pane's "Default"/"Custom" status, the ⓘ modal's "Location"/"Choose", the confirmation
  dialog's "Move and Relaunch" and its body copy, the progress window's "Moving Pensieve's data…" and
  failure text, and all nine `RelocationError` case messages (not writable, inside the source, is the
  source, not empty, already exists, not a directory, insufficient space, sync in progress, verification
  failed).
- **A refused relocation reports its specific reason**, not a generic failure — try moving onto the
  current root, onto a non-empty folder, and onto a read-only destination and confirm each gets its own
  message rather than one shared string.
- **Menu-bar-only flow:** with the main window never opened this session (`.accessory`/hide-Dock mode),
  request a move from Settings reached via the menu-bar item, and confirm the app still relaunches and
  completes rather than getting stuck with a dead menu bar and no window.
