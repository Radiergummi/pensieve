# CONTINUE — session handoff (2026-08-12)

Self-contained pickup for a fresh agent. Read `CLAUDE.md` first (project rules + the full shipped
changelog in **Status**), then this. **`docs/superpowers/backlog.md`** is the durable long-term list
(Roadmap + deferred ledger with revisit triggers); this file is the per-session handoff.

## Where things stand

**589 tests**, run with `./scripts/test.sh` (thin `swift test` passthrough). The full loop is **LIVE and
dogfooded**: capture → ingest → auto-extract runs unattended via the bundled background-sync agent; the
app is a real `Pensieve.app` bundle (Xcode/XcodeGen) with the `pensieve` CLI embedded inside it. The
core intelligence gate passed long ago. The hard part is done — remaining work is feature breadth, not
foundations.

**Nothing is in flight. `main` is clean and every branch is merged.** The two design slices that were
open at the last handoff both landed: **"where was I"** (design slice A, merged and human-verified
2026-08-12) and **in-node find** (merged 2026-08-12 — see the merge note below, it was not mechanical).
Stale leftovers still on disk: `.claude/worktrees/remove-vector` (branch
`fix/post-vector-removal-cleanup`, fully merged — safe to remove) and `.claude/worktrees/retrieval-bm25`
(branch `worktree-retrieval-bm25`, **8 commits NOT in `main`** — abandoned two-path work, so removing it
discards those commits; that is a decision, not cleanup).

**BM25/FTS5 shipped and is the only retrieval path.** `worktree-retrieval-bm25-single-path` merged to
`main`, and the vector stack it replaced was then deleted outright (see the vector-removal ship below) —
there is no second engine left to reconcile against.

**⚠️ Rebuild + reinstall before trusting the live app.** `/Applications/Pensieve.app` was built
**2026-08-11 13:38**, which is *after* BM25 + the vector removal (so the bundled `pensieve mcp` every
Claude Code session calls is current on retrieval) but *before* **both** design slices. The running app
therefore has none of the "where was I" pass and no in-node find, and its ⌘F is still the **global**
search field rather than the new find-within-node. After reinstalling, check
`ls -l ~/.local/bin/pensieve` is still a symlink (see Gotchas).

**`xcodegen generate` is required after pulling this merge** — the checked-in project is generated and
gitignored, and the in-node-find merge adds five app files. A build without it fails with
`cannot find 'FindCommands' in scope`, which reads like a code error and is not one.

**No open defects on the retrieval path.** **FTS5/BM25 is the only retrieval path** — the vector stack
(embedder, `vec0` store, indexer, `SemanticQueries` and its inert `0.25` floor, the vendored `sqlite-vec`
C target, the Settings toggle, the ⌘F "Related" section, the MCP `engine` field) was **deleted on
2026-08-11**, so there is no longer a toggle whose persisted `true` can reinstate the old behaviour. The
`app.semanticSearch` key is inert; clear it with `defaults delete me.mazetti.pensieve app.semanticSearch`.
See `backlog.md`, "Semantic relevance floor — CLOSED by removing the engine".

## Most recent ships (newest first)

Brief — the exhaustive per-feature record lives in `CLAUDE.md` **Status**; deferred follow-ups + human
carries live in the matching `backlog.md` entries.

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

**Post-merge carry — `xcodegen generate`, then rebuild + reinstall, before doing anything else.** The
in-node-find merge adds five app files to a **generated, gitignored** project, so a build without
`xcodegen generate` fails with `cannot find 'FindCommands' in scope`. `/Applications/Pensieve.app` was
built **2026-08-11 13:38** — current on BM25/vector-removal, but predating **both** design slices, so the
installed app has neither the "where was I" pass nor in-node find, and its ⌘F is still the global search
field. After reinstalling, confirm `ls -l ~/.local/bin/pensieve` is still a symlink into
`Contents/Helpers/`. Run `defaults delete me.mazetti.pensieve app.semanticSearch` — inert now that
nothing reads it, but leaving it invites a future reader to wonder what does. **Expect the background
sync agent to need healing after the bundle swap:** a new helper cdhash makes `SMAppService.register()`
silently no-op (`EX_CONFIG` / "Launch Constraint Violation"). Observed 2026-08-11, and the app's own
unregister+register did **not** heal it. What worked: quit the app →
`launchctl bootout gui/$(id -u)/me.mazetti.pensieve.sync` → relaunch → verify `last exit code = 0` and a
fresh line in `~/Library/Logs/Pensieve/sync.log`. Then walk the **human-verify carries** at the bottom of
this file — in-node find's are entirely unrun, and they need the installed app and the real store, which
no agent can do headlessly.

**THEN — the honest shortlist.** Nothing is half-built, so the next move is a genuine choice:

- **Design slice B — Liquid Glass chrome + the macOS 26 floor** (`backlog.md`, "Claude Design review").
  The backlog's own trigger says *pair with or follow A*, and A just landed. Bump `deploymentTarget.macOS`
  15.0 → 26 (the machine runs 26.6; the 15.0 floor buys a single-user tool nothing and forces
  `if #available` scaffolding at every call site), adopt scroll-edge material, revisit the sidebar status
  footer, and **rebuild the menu-bar popover** — the worst-looking surface in the app, with node rows that
  have no per-item action, plus the `Pensieve öffnen` → `Pensieve öf…` truncation the verify pass found.
- **Design slice C — transcript reading: one rail, no nested cards.** It was explicitly sequenced
  *behind* in-node find because both rewrite `LooseEndRow.swift` and `TranscriptSegmentView.swift`. That
  block is now gone, so C is unblocked — and in-node find's flatten-on-match trade-off lives in exactly
  those files, so C is the natural place to revisit it.
- **Loose ends can end — three verbs (`open`/`done`/`dropped`).** `backlog.md` calls it "the single
  highest-value idea in the whole review", and it is a data-model change, not chrome: today a loose end is
  open forever, so "Als Nächstes 155" and "Ruhend 112" never shrink and neither number means anything.
- **Track A slice 5 — talk-to-system.** Still the product spine (see Track A below).

**AND — P3, the paraphrase harness, is the one open retrieval question, and it is blocked on YOU.**
Both engines fail "find without remembering the words" (`vector` ≈0/8, `bm25` ≈2/8 on short paraphrase
queries), and the gold set that produced BM25's headline win uses **full documents as queries**, which
flatters lexical matching in a way real typed queries do not. Unblocking it needs **30–50 paraphrase
queries you write**, each naming what it should find — deliberately yours, because as sole user your
queries *are* the ground truth. Design is already written (spec §P3): two files, per-query-normalised
operating points, an explicit `NO VIABLE THRESHOLD` verdict, and a pre-registered absolute floor so the
report can conclude "the incumbent is unusable".

**Track A — the three-pane app (the product spine).** Everything through Share-recall, archive, and
error-surfacing has shipped. Next: **slice 5 (talk-to-system** — describe a strand in natural language →
structured create via `LLMProvider`), then **slice 6 (forks** — gated on the unbuilt fork-capture backend;
brainstorm that backend first). Design: `specs/2026-07-05-pensieve-app-three-pane-design.md`.
**Still the product spine — but the design slices above have first claim now that A is verified.**

**Track B — DONE.** Both threads shipped: the cloud/API `LLMProvider` (2026-07-09) and organizing-writes
error surfacing (2026-07-14). Nothing open. (Spec 2's deferred source-management GUI + daemon-interval
editing remain parked in `backlog.md`, not part of Track B.)

**Track C — findability / OS-integration.** The global search field (now **⌥⌘F**), the menu-bar item,
`pensieve://`, App
Intents + Spotlight, Focus filters, **Spotlight loose-end indexing (1b, 2026-07-19)**, **transcript
readability (2026-07-26)**, **retrieval P1+P2′ / BM25 (2026-08-11)** and **in-node find (⌘F,
2026-08-12)** are live. **Semantic/vector
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
entitlement). That single gate unblocks the whole extension family at once; revisit only when a paid
membership is in hand. See `backlog.md` "Widgets — DEFERRED".

## LIVE deployment state

- **CLI:** bundled inside `Pensieve.app` at `Contents/Helpers/pensieve`; `~/.local/bin/pensieve` is the
  app-managed symlink external callers (git hooks, `~/.claude/settings.json`, `claude mcp add`) resolve.
  Keep `~/.local/bin` on `PATH`. No manual CLI rebuild/reinstall anymore — updating the app updates it.
- **Background sync:** the bundled `SMAppService.agent` `me.mazetti.pensieve.sync`, registered from
  `/Applications/Pensieve.app` (approve once in System Settings ▸ Login Items). Watch:
  `tail -f ~/Library/Logs/Pensieve/sync.log`.
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
