# CONTINUE — session handoff (2026-08-02)

Self-contained pickup for a fresh agent. Read `CLAUDE.md` first (project rules + the full shipped
changelog in **Status**), then this. **`docs/superpowers/backlog.md`** is the durable long-term list
(Roadmap + deferred ledger with revisit triggers); this file is the per-session handoff.

## Where things stand

Everything is **on `main`**; the tracked tree is clean. **558 tests**, run with `./scripts/test.sh`
(thin `swift test` passthrough). The full loop is **LIVE and dogfooded**: capture → ingest →
auto-extract runs unattended via the bundled background-sync agent; the app is a real `Pensieve.app`
bundle (Xcode/XcodeGen) with the `pensieve` CLI embedded inside it. The core intelligence gate passed
long ago. The hard part is done — remaining work is feature breadth, not foundations.

**⚠️ The installed app is stale.** `/Applications/Pensieve.app` was built **2026-07-19** and is five
ships behind `main` — so the running app has no chat transcript rendering, and the bundled
`pensieve mcp` (which this and every Claude Code session actually calls) is still running the old
**vector** `search` (missing both the widened `include_archived` and the whole BM25 swap).
**Rebuild + reinstall before trusting anything you see in the live app**, then check
`ls -l ~/.local/bin/pensieve` is still a symlink (see Gotchas).

**The semantic-recall defect is closed for P1+P2** (2026-08-02): the diagnosis was a *ranking*
failure, not an inert-threshold one, and ⌘F "Related" + MCP `search` now run on BM25. What stays
open is **P3 — the paraphrase eval harness**, which is **blocked on you writing 30–50 paraphrase
queries** as the gold set. See THE NEXT ACTION below and `backlog.md:211`.

`~/Library/Application Support/Pensieve/semantic-index.sqlite` is now **inert** — nothing reads or
maintains it. Nothing deletes it automatically either; it is safe to remove by hand.

## Most recent ships (newest first)

Brief — the exhaustive per-feature record lives in `CLAUDE.md` **Status**; deferred follow-ups + human
carries live in the matching `backlog.md` entries.

- **Retrieval P1 + P2 — corpus hygiene and BM25 "Related"** (2026-08-02). The semantic-recall defect
  re-diagnosed: a **ranking failure, not a scale failure** — mean-pooled `NLContextualEmbedding` was
  never a sentence-similarity encoder, so no floor placement could have fixed an ordering that was
  already wrong. **P1:** `EmbeddableCorpus.gather` drops `git.checkout` events and exact-duplicate
  texts (2,630 → 2,264 items; BM25 P@1 0.387 → **0.433**). **P2:** a new `TextIndexStore` (FTS5 +
  SQLite's `bm25()` in a separate, rebuildable, never-synced `text-index.sqlite` — kept apart from
  `semantic-index.sqlite` because that store's `prepareDatabase` throws when sqlite-vec can't
  register, and keyword search must not inherit that) + `RelatedQueries` now sit behind ⌘F "Related"
  and MCP `search`, sharing **one** extracted `RelatedResolver` with `SemanticQueries` so the
  grounding guards can't drift between engines. The `0.25` floor is **removed, not retuned**;
  relevance is bounded by rank plus the requirement that a document contain query terms — **a rank
  cap is not a relevance threshold**. The vector stack is retained, tested, and wired to nothing.
  Settings toggle keeps its key + ON default; only the copy changed ("Find related work"). Trust gate
  untouched. **558 tests** (+34). **Post-merge carry:** rebuild + reinstall to `/Applications`.
  Spec/measurements: `specs/2026-07-28-retrieval-eval-harness-design.md`,
  `measurements/2026-07-28-retrieval-recall/`; plan: `plans/2026-08-02-retrieval-p1-p2-bm25.md`.
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
- **Semantic / vector recall — Track C #2** (2026-07-18, merged `e640645`). "Find without exact words"
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

**⚠️ FIRST — P3: write 30–50 paraphrase queries.** This is the one open piece of the retrieval work
and **only you can do it** — it is the gold set the eval harness needs, and no agent can invent it
without inventing the answer too. P1+P2 shipped BM25 behind ⌘F "Related" and MCP `search` (measured
1.7× better P@5 than the vector it replaced), but **neither engine solves "find it without
remembering the words"**: on 8 hand-written short paraphrase queries, `vector` ≈ 0/8 and `bm25` ≈ 2/8.
**A rank cap is not a relevance threshold** — P2 did not earn one; P3 is what would. The harness's
decision rule and its absolute floor are already pre-registered in
`specs/2026-07-28-retrieval-eval-harness-design.md`; the measurements live in
`measurements/2026-07-28-retrieval-recall/` and `backlog.md:211`. Write the queries as things you'd
actually type when you half-remember a piece of work, each paired with the item you'd expect back.
Until that exists, P3 cannot start — so if you don't want to write it now, pick Track A instead.

**Track A — the three-pane app (the product spine).** Everything through Share-recall, archive, and
error-surfacing has shipped. Next: **slice 5 (talk-to-system** — describe a strand in natural language →
structured create via `LLMProvider`), then **slice 6 (forks** — gated on the unbuilt fork-capture backend;
brainstorm that backend first). Design: `specs/2026-07-05-pensieve-app-three-pane-design.md`.
**This is the recommended next feature.**

**Track B — DONE.** Both threads shipped: the cloud/API `LLMProvider` (2026-07-09) and organizing-writes
error surfacing (2026-07-14). Nothing open. (Spec 2's deferred source-management GUI + daemon-interval
editing remain parked in `backlog.md`, not part of Track B.)

**Track C — findability / OS-integration.** In-app find (⌘F), the menu-bar item, `pensieve://`, App
Intents + Spotlight, Focus filters, **semantic/vector recall (#2, 2026-07-18)**, **Spotlight loose-end
indexing (1b, 2026-07-19)**, the **semantic-recall hardening batch (2026-07-19)**, **archived content in
the semantic index (2026-07-19)**, **transcript readability (2026-07-26)**, and **retrieval P1+P2 —
corpus hygiene + BM25 "Related" (2026-08-02)** are all live. Remaining:
- **P3 — the paraphrase eval harness.** Blocked on the gold set above; see the ⚠️ item.
- **Transcript-passage chunking** — the next corpus increment. **The spec is already written**
  (`specs/2026-07-19-transcript-passage-chunking-design.md`, committed `35b0ed1`) — **no plan yet**, so
  this is the shortest path to shipping. Would also make `RelatedQueries`' `maxFetch=2000` cap worth
  revisiting.
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
