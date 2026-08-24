# Codebase quality sweep — 2026-08-24

Audit only; no code was changed. Scope: all of `Sources/` and `Tests/` (385 Swift files, ~33.6k
lines). Method: ten parallel auditors — eight by subsystem, one dedicated to cross-cutting
duplicated rules, one running real mutations against the test suite in an isolated git worktree —
against a shared evidence bar (read the file, verify the anchor, show both sites for a drift claim,
give a concrete failure scenario for a bug claim). Findings that two auditors reached independently
are marked **converged**; treat those as the highest-confidence items in the document.

Anchors were verified against working-tree `b7dc69a`. Several findings were reproduced against the
**live** store at `~/Library/Application Support/Pensieve/pensieve.sqlite` (306 nodes, 3,110 events,
1,076 loose ends) and against a real FTS5 table; those are marked *measured*.

Detail on every finding, plus each auditor's own "considered and rejected" list, is in
`scratchpad/sweep/{A..J}-*.md` for the session that produced this document. This file is the
synthesis.

---

## 1. Executive summary

1. **Attribution is silently broken today, and the damage is in your live store.** The repo-identity
   key is resolved at *drain* time from a path captured at *commit* time; in a worktree-heavy
   workflow the directory is often already gone, and the fallback **invents a project**. 9 phantom
   nodes hold ~42 events that belong to `Pensieve`; 42 of 198 sources have a key that is not a
   `.git` common-dir. A second, independent split (`pensieve track`) has `Pensieve` and "Pensieve
   Signal Viewer" as two nodes for one repo.
2. **The dominant failure mode across the whole codebase is the silent empty result.** An
   unparseable model reply is "no loose ends" *and advances the watermark*; a punctuation token
   zeroes an entire search; a swallowed store-open error renders an empty pane; a hung sync agent
   stops background ingestion forever with a clean log. In a tool whose job is telling you what you
   were doing, "nothing here" and "it broke" must never look alike — and right now they usually do.
3. **The duplicated-rule wound has moved up a level.** Inside PensieveKit the discipline is genuinely
   good (a long list of rules are already single-sourced and test-pinned). What drifts now is rules
   crossing a *module* boundary — the app target, the CLI's MCP server, and the search-index
   producer each restate a rule the Kit owns. One such pair is already out of sync in production.
4. **`AppModel.refresh()` is the performance and correctness bottleneck, and it is one problem.**
   "Latest event + open count per node" is derived four ways with four different no-events
   semantics; three are N+1; `looseEnds` has no `nodeID` index. ~917 full table scans per refresh —
   and the same refresh re-arms an FSEvents busy-loop the codebase explicitly documents as forbidden.
5. **A previous naming cleanup silently corrupted 24 doc-comment lines in 3 files** — whole-word
   renames rewrote English prose (`a` → `lhs`, `i.e.` → `scanIndex.e.`). In `TranscriptMarkup.swift`
   those comments *are* the parser spec. Lint cannot see it. Read this before doing the category-7
   work, not after.

---

## 2. Findings

Grouped by your categories, ranked within each group. High and medium findings get the full
treatment; low-severity findings are given as one-line rows with their anchor, reason and fix size,
because there are ~120 findings in total and padding the small ones would bury the large ones.

### Category 1 — Duplicated rules that will drift

The project's top interest, so this is the longest section. Every claim below shows both sites.

#### 1.1 "A closed loose end" is defined three ways; the ranking's copy omits the 👎 exclusion — **high / certain / converged**

- **Anchors:** `Sources/PensieveKit/Query/NextQueries.swift:70` (`status.neq(.open)`, no label filter)
  vs `Sources/PensieveKit/Query/LooseEndQueries.swift:99` and `:126` (both also
  `label.neq(LooseEndLabel.noise)`)
- **Wrong:** `NextQueries.ranked` counts 👎-labelled loose ends as *closed work*; both Completed
  feeds exclude them.
- **Why here:** `isActionable` (`NextQueries.swift:48`) is `openLooseEnds > 0 || closedLooseEnds == 0`,
  and its own doc calls the non-actionable case "the narrow, earned case: it HAD open ends and they
  are all closed". A 👎 asserts the opposite — it was never a loose end. Reachable path, verified:
  close a node's ends, then 👎 them from the Completed record
  (`Sources/PensieveApp/ClosedLooseEndsRecord.swift:38` wires `onLabel: model.setLooseEndLabel`, and
  `label`/`status` are orthogonal by design, `LooseEndCommands.swift:14-18`). Result: `open == 0`
  (because `isOpen` excludes noise) and `closed > 0` (because this predicate does not), so the node
  is dropped permanently from **What's Next, the sidebar smart list, the widget digest, MCP
  `whats_next` and `pensieve next`** — all of which funnel through `isActionable` — while appearing
  on no closed feed either. `LooseEndCommands.resolveAllOpen`'s doc (`:53-62`) records this exact
  👎-vs-status asymmetry biting once already.
- **Fix (one file):** add the sibling of `LooseEnd.isOpen` — `isClosedAndReal(_ columns:)` spelling
  `status.neq(.open) && label.neq(.noise)` — and use it at all three sites. Pin it with the
  `NodeFactsTests.looseEndOpenPredicatesAgree` pattern that already exists for `isOpen`.

#### 1.2 `pensieve track` keys a source by worktree root; everything else by git common-dir — **high / certain / measured**

- **Anchors:** `Sources/pensieve/Commands/Track.swift:11` vs
  `Sources/PensieveKit/Discovery/GitSource.swift:18` and `Sources/PensieveKit/Ingest/Ingester.swift:93`
- **Wrong:** two sites implement "the identity key for a git repo". `GitSource.detect` and `Ingester`
  go through `Git.commonDir` (→ `…/repo/.git`); `Track` passes its raw argument to
  `resolver.resolve`, which canonicalizes symlinks but never asks git (→ `…/repo`).
- **Why here:** `Source` has `UNIQUE(key, kind)`, so two spellings are two rows, two `Node`s, and two
  entries in every list — for one repo. Live proof: source `/Users/moritz/Projects/pensieve` → node
  **"Pensieve Signal Viewer"** (1 event, an LLM-invented name) sitting beside
  `/Users/moritz/Projects/pensieve/.git` → node **"Pensieve"** (641 events). `track` a repo before
  its first commit and every later commit lands in a different node than the one `track` printed.
- **Fix (one file):** extract `ProjectResolver.identityKey(forRepoPath:)` and call it from `Track`,
  `GitSource.detect` and the three `Ingester` sites. This also gives 1.3 and 2.1 one place to live.

#### 1.3 Three hand-rolled `claude -p` spawns; only one carries the cwd pin that fixed the phantom-session loop — **high / certain / converged**

- **Anchors:** `Sources/PensieveKit/LLM/ClaudeCLIProvider.swift:43` (sets
  `currentDirectoryURL = PensievePaths.llmScratchDirectory()`, with a 6-line comment explaining why)
  vs `Sources/pensieve/Commands/LabelSuggest.swift:58-64` (no `currentDirectoryURL` at all). Third
  copy, also unpinned: `Tests/PensieveKitTests/SalienceEvalTests.swift:14-27`.
- **Wrong:** the fix exists at one of three sites.
- **Why here:** the comment at `ClaudeCLIProvider.swift:38-42` records the failure that produced it —
  an unpinned child inherits the parent's cwd, becomes a real Claude Code session *in that
  directory*, is captured by the SessionEnd hook, and is re-ingested as work. `pensieve
  label-suggest` is run from a terminal inside a project and issues one `claude -p` per batch over
  the whole unlabeled backlog, so one bootstrap run injects N phantom `cc.session` events attributed
  to whatever repo you were standing in — which then feed extraction and narration for that node.
  `ProjectResolver.isDegenerateRoot` is the documented second line of defence but only rejects roots
  like `/`; a real project path sails through. The `LabelSuggest` copy also drops `stderr`, so a
  `claude -p` diagnostic surfaces as a bare `"claude -p exit 1"`.
- **Fix (one file):** delete `LabelSuggest.claudeRun` and go through the shared provider —
  `ClaudeCLIProvider`'s injected `run` closure exists for exactly this; `shellRun` needs one optional
  model parameter rather than a second implementation. The test copy then calls the same helper.

#### 1.4 "Latest event + open count per node" is derived four ways, three of them N+1, in one refresh — **high / certain / measured**

- **Anchors:** `Query/NodeFacts.swift:77-95` (batched, two grouped aggregates) vs
  `Query/NextQueries.swift:65-72` (per node, 3 queries) vs `Query/BriefingQueries.swift:43-44`
  (per node, **fetches every event row**) vs `Query/NodeFacts.swift:44-49` (per node, 2 queries).
  All four reachable from `Sources/PensieveApp/AppModel.swift:371-387` in a single `refresh()`.
- **Wrong:** one derivation, four statements, four different no-events semantics — `ranked` skips the
  node (`:67 continue`), `cards` skips it (`:45 continue`), `NodeFacts.facts` returns
  `daysDormant: 0, lastActivityAt: nil`, and `rowFacts` omits the key and documents "callers treat a
  miss as no activity, zero open".
- **Why here:** `NodeFacts.swift:67-70` already says the quiet part out loud — *"That N+1 pattern
  still exists elsewhere: `BriefingQueries.cards`, called one line above this in
  `AppModel.refresh()`, fetches every event row per node just to count them."* Measured: `cards`
  materializes all 3,110 `Event` structs (~640 KB of `detailJSON` + 300 KB of `workSummary`) to take
  `.first` and count, then opens **305 separate read transactions** because `LooseEndQueries.open`
  opens its own. Any future change to "latest activity" must be made in four places with four
  different edge cases, and the two feeding `groundedScore` would disagree with the two feeding the
  rendered "Nd dormant" first.
- **Fix (cross-cutting but bounded):** express `movedSince` as a third grouped aggregate and
  `latestSummary` as one indexed join; fold `cards` and `ranked` onto `rowFacts`-shaped aggregates
  and pick **one** no-events rule, stated once. Pairs with 5.1 — one change fixes both.

#### 1.5 The search index's `kind` strings are produced as literals and consumed through an enum — **high / certain**

- **Anchors:** `Search/EmbeddableItem.swift:115`, `:125`, `:131`, `:155`, `:179` (literals
  `"node"` / `"loose_end"` / `"event"` / `"passage"`) vs `Query/SearchQueries.swift:189`
  (`SearchHit.Kind(rawValue:)`)
- **Wrong:** the producer writes the wire value by hand; the consumer parses it through the enum that
  already defines it.
- **Why here:** the project fixed exactly this for one case — `Passage.searchKind` exists with the
  reasoning in a doc comment — and left the other three unfixed **in the same producer**. A typo or a
  renamed case yields rows that index fine and resolve to nothing, i.e. a silent partial search
  (see theme 2).
- **Fix (one file):** produce every `kind` from `SearchHit.Kind.…rawValue`.

#### 1.6 The narration cache is split three ways, and one of them ignores `PENSIEVE_DB` — **medium / certain / converged (4 auditors)**

- **Anchors:** `Support/PensievePaths.swift:52` (narration cache: `supportDirectory()` only) vs `:56`
  and `:62` (search index / translation cache, via `indexURL(named:)` which folds in the override) vs
  `PensieveApp/AppModel+Narration.swift:35` (a third rule: a `UserDefaults` key suffixed with
  `resolvedCanonicalURL().path`). Window mismatch: `AppModel+Recall.swift:11` (15) and
  `Intelligence/SummaryBuilder.swift:63`, `:92` (15) vs `Query/SessionContextQueries.swift:105` (8).
- **Wrong:** three disposable caches derived from the same store resolve their location by three
  different rules, and the one ignoring the override is the one whose `init` **deletes** the file it
  cannot open (`Intelligence/NarrationCache.swift:17`). Separately, the two sides narrate over
  different event windows, so the shared cache key can never match across processes.
- **Why here:** `PensievePaths.swift:64-69` spells out the exact scar the override rule exists for
  ("`PENSIEVE_DB=/tmp/x pensieve sync` … `DELETE FROM documents` on the developer's LIVE index").
  `pensieve prime` (`Commands/Prime.swift:18`) and `pensieve mcp` (`Commands/Mcp.swift:206`) are the
  narration cache's only openers and both use the unscoped path, so a throwaway fixture run reads,
  writes, and can delete your live `narration-cache.sqlite`. It is pollution rather than wrong
  answers today only because `NarrationCacheKey` is built from random event UUIDs that cannot collide
  — the safety is accidental. `PensievePathsTests.swift:32-37` pins the rule for the other two caches
  and `:75` pins only the `in: support` form for narration, so the gap is invisible to `make test`.
  And because the windows differ, **`pensieve prime` stays cold forever** — it never hits a cached
  narration the app wrote.
- **Fix (one line + one decision):** `narrationCacheURL()` → `indexURL(named: "narration-cache.sqlite")`,
  plus an `#expect` beside the existing two. Then pick one narratable window and state it once. If
  the app's UserDefaults copy stays, say in a comment that it is deliberately keyed by store path.

#### 1.7 The `pensieve://` grammar has a second implementation in MCP — and they already disagree — **medium / certain**

- **Anchors:** `Sources/pensieve/Commands/Mcp.swift:24`, `:30`, `:165`, `:169-170` vs
  `Sources/PensieveKit/Support/DeepLink.swift:12-67`
- **Wrong:** MCP builds and parses `pensieve://` URIs with literals and `hasPrefix`/`dropFirst`
  instead of `DeepLink`. It serves `pensieve://smartlist/whats-next`; `DeepLink.SmartList.whatsNext`'s
  raw value — the only segment `DeepLink.init?(url:)` accepts — is `whatsNext`.
- **Why here:** this is not a future risk, it is **broken now**. `DeepLink`'s header calls itself "the
  foundational cross-surface entry point" and the widget does reuse it
  (`PensieveWidget/WhatsNextView.swift:24`). MCP is the one surface that opted out, so a client that
  hands back the URI MCP advertised gets nothing: `DeepLink(url:)` returns nil and `applyDeepLink` is
  never reached.
- **Fix (one file):** `DeepLink.smartList(.whatsNext).url.absoluteString` and `DeepLink(url:)` in
  `handleReadResource`. The advertised URI string changes — a visible contract change for MCP
  clients, worth a moment's thought, but the alternative is two grammars.

#### 1.8 Remaining category-1 findings

| # | Rule restated | Sites | Breaks when one is edited | Sev |
|---|---|---|---|---|
| 1.9 | "Resolve repo identity at capture time" — done for sessions only | `Commands/CaptureSessionStart.swift:26` vs `CaptureCommit.swift:11`, `CaptureCheckout` | git captures keep resolving a dead path at drain (root cause of 2.1) | med |
| 1.10 | `hasMeaningfulSignal` gate before LLM naming | `Ingester.swift:313-314` (omits) vs `Intelligence/NodeDescriber.swift:53-54` (applies) | live nodes named "Weight Transfer Tool" from `wt-550`, "Web Trace Viewer 570" | med |
| 1.11 | "What a loose end is" — three prompts | `LooseEndExtractor.swift:131`, `SalienceClassifier.swift:74`, `FoundationModelsProvider.swift:116` | tighten the definition in one prompt, the other two keep proposing what it now rejects | med |
| 1.12 | Production extraction pipeline vs the eval task that picks its model | `Intelligence/ExtractionRunner.swift:97` vs `Eval/ExtractionTask.swift:18` (omits `CandidateFilter`) | eval measures a pipeline that isn't shipped, so the chosen default model is chosen on the wrong task | med |
| 1.13 | Label cleaning | `Intelligence/NodeDescriber.swift:25` (`sanitize`) vs `Support/TextQuality.swift:21` (has the structured-output reject) | a reject added to `TextQuality` doesn't apply to descriptions | med |
| 1.14 | The node's "top open loose end" ordering | `BriefingQueries.swift:58` + `LooseEndQueries.swift:21` (source-event date) vs `SessionContextQueries.swift:153-158` (`createdAt`, i.e. ingest time) | app and MCP cite **different** loose ends for the same node; `createdAt` is arbitrary within a drain | med |
| 1.15 | FTS5 tokenizer spec | `Search/SearchIndexStore.swift:69`, `:75`, `:90` (3×) + coupled to `Support/FindMatcher.swift:29` | change the tokenizer on one table and in-node find silently stops agreeing with search | med |
| 1.16 | Grow-`k` over-fetch schedule | `Query/SearchQueries.swift:65`, `:75` vs `Query/PassageQueries.swift:50`, `:78` | the sibling constant `maxFetch` *was* deliberately shared, with a comment warning about this exact drift | med |
| 1.17 | Extraction fabrication hard-gate keyed off a literal | `Eval/Scorecard.swift:58` (`"extraction"`) vs `Eval/ExtractionTask.swift:11` (`ScorerKind`) | rename the task id and the trust gate silently stops applying | med |
| 1.18 | Blank/relative store override treated as absent | `PensievePaths.swift:25-30` (guards) vs `Store/StoreOpen.swift:62-67`, `:70-75`, `PensievePaths.swift:84`, `Store/StoreRelocationLock.swift:34-41` (don't) | `URL(fileURLWithPath: "")` is the cwd; under launchd cwd is `/` — verified experimentally | med |
| 1.19 | Widget digest item selection | `Widget/WidgetDigestPublisher.swift:36-42` (via `NextQueries.whatsNext`) vs `AppModel.swift:316`, `:332-337`, `:356` (via `SmartLists.compute` + `filtered`) | two compositions of one rule writing the same file; widget and window disagree | med |
| 1.20 | Dormancy day-count formula | `NextQueries.swift:68`, `BriefingQueries.swift:47`, `NodeFacts.swift:46-48`, `LooseEndQueries.swift:177` | four `Calendar` computations; a timezone/DST fix lands in one | med |
| 1.21 | Relative-date vocabulary | `App/NodeMeta.swift:26` vs `MenuBarView.swift:207`, `Settings/AdvancedSettingsTab.swift:93`, `PassageResultsSection.swift:49`, `LooseEndRow.swift:109` | one site documents getting this wrong before; also a localization surface | med |
| 1.22 | MCP argument names + defaults | `Mcp.swift:46-47`, `:53-54`, `:62-64`, `:77-87` (schema) vs `:108-109`, `:125-126`, `:130-134`, `:151-157` (handler) | 10 wire keys spelled twice with nothing linking them; responses do this correctly via `CodingKeys` | med |
| 1.23 | `@AppStorage` boolean defaults | `App/AppDefaults.swift:21-24`, `:28-31`, `:37-40` vs `DetailView.swift:7`, `IntelligenceSettingsTab.swift:10`, `GeneralSettingsTab.swift:9`, `TranslationSettingsTab.swift:64` | a comment already says "matching the `@AppStorage(...) = true` in the views"; the *values* drift, not the keys | med |
| 1.24 | Review-queue predicate: list vs count | `Query/SalienceReviewQueries.swift:17` and `:28` | badge count disagrees with the list it labels | med |
| 1.25 | Resolve verbs | `LooseEndStatusMenu.swift:5-8` (shared type covers one) vs `LooseEndRow.swift:153-158`, `LooseEndStatusMenu.swift:88-100` | the doc claims context menu and swipe actions are shared; they are not, and a closed row already has no swipe verb | med |
| 1.26 | Provider → label, keyed off raw strings not `ProviderPreference` | `IntelligenceSettingsTab.swift:42-49` vs `AdvancedSettingsTab.swift:81-88` | add a provider case and one tab silently shows a stale label | med |
| 1.27 | Name resolution in `group` rejects UUIDs its siblings accept | `Commands/Group.swift:16` vs `Query/NodeCommands.swift:37` | `pensieve group <uuid>` fails where every sibling command succeeds | med |
| 1.28 | Whitespace-boundary chunker, byte-for-byte twice | `LooseEndExtractor.swift:110-125` vs `SessionSummarizer.swift:78-90` | a chunking fix applies to extraction but not summarization | low-med |
| 1.29 | Path canonicalization, three different rules | `ProjectResolver.swift:12`, `Support/Git.swift:26`, `Discovery/SourceScanner.swift:84-88` | mis-attribution; feeds 1.2 / 2.1 | low |
| 1.30 | Capture heartbeat / sidecar path / spool SQL restated | `MonitorSnapshot.swift:33` vs `:61`; `CaptureSpool.swift:77`/`:100`, `:85`/`:105`; `PensievePaths.swift:84-88` vs `StoreRelocationLock.swift:38-41` | two overloads, two answers for the same fact | low |
| 1.31 | Completed-feed filter and comparator, twice in one file | `LooseEndQueries.swift:99-100` vs `:126`; `:89` vs `:103` | the file already extracted its *other* comparator for this reason | low |
| 1.32 | Heartbeat status → colour; `SMAppService.Status` → label | `MenuBarView.swift:25-31` vs `SidebarView.swift:123-129`; `GeneralSettingsTab.swift:70-78` vs `AdvancedSettingsTab.swift:60-68` | menu bar and sidebar can show different colours for one state | low |
| 1.33 | `AppearanceIcon` stored form written by hand | `IconPicker.swift:67`, `:79` vs `Model/VisualIdentity.swift:23-28` | picker writes a form the model may stop parsing | low |
| 1.34 | `LooseEnd.isOpen` spells the noise label as a literal | `Model/LooseEnd.swift:36`, `:43` vs `Query/LooseEndCommands.swift:10` | the one predicate everything trusts hardcodes the label it excludes | low |
| 1.35 | Canonical store filename; App Group id | `Store/StoreRelocator.swift:253` vs `PensievePaths.swift:37-39`; `PensievePaths.swift:129` vs 3 `.entitlements` | rename the store file and relocation stops cleaning up its sidecars | low |
| 1.36 | `CLI narration setup`; quote-first loose-end renderer; MCP archived-searchability | `Mcp.swift:189` vs `Prime.swift:17`; `Status.swift:19` vs `LooseEnds.swift:28`; `Mcp.swift:270` vs `SearchHitResolver.swift:52` | three small CLI/MCP restatements of Kit rules | low |
| 1.37 | Checkout fingerprint uses raw path while its source uses the canonical key | `Ingester.swift:121` vs `:116` | dedup misses when the path spelling changes | low |
| 1.38 | Widget staleness hardcodes 4× the agent's `StartInterval`; translation key omits the producer | `Widget/WidgetDigest.swift:18-19` vs `sync.plist:9-10`; `TranslationStore.swift:50-54` vs `NarrationCacheKey.swift:19-26` (which deliberately includes it) | change the sync period and the widget's staleness threshold lies | low |
| 1.39 | `SalienceSuggester` re-derives the salience batching cost model | `SalienceSuggester.swift:93` vs `SalienceClassifier.swift:41` | cost estimate and actual batching diverge | low |

### Category 2 — Correctness and concurrency

#### 2.1 The identity-key fallback mints a phantom project for every repo directory gone at drain time — **high / certain / measured**

- **Anchors:** `Sources/PensieveKit/Ingest/Ingester.swift:93` (commit), `:116` (checkout), `:145` (session)
- **Wrong:** `Git.commonDir(in: path) ?? ProjectResolver.canonical(path)` treats "not a git repo" and
  "this directory no longer exists" as the same case, and the fallback invents a `Source` + `Node`
  keyed on the dead path.
- **Why here:** for `git.commit`/`git.checkout` the payload came *from a git hook*, so a nil
  `commonDir` can only mean the directory vanished — never "not a repo". This project's own workflow
  creates and deletes worktrees constantly, the sync agent runs every 300 s, and it was down for days
  in the live log, so the window is wide open. Measured against the live store:

  | source key | node | events |
  |---|---|---|
  | `…/pensieve/.git` | **Pensieve** | 641 |
  | `…/pensieve/.claude/worktrees/feat+llm-eval-harness` | Feature LLM Evaluation Harness | 22 |
  | `…/pensieve/.claude/worktrees/macos26-floor` | MacOS26-Floor | 13 |
  | `…/pensieve/.claude/worktrees/where-was-i` | where-was-i | 1 |
  | `…/pensieve/.claude/worktrees/in-node-find` | in-node-find | 2 |
  | `…/pensieve--loose-end-noise` | Pensieve Loose End Noise | 1 |
  | (+ passage-chunking, translation-settings, custom-store-location) | | 3 |

  None of those directories exist. 42 of 198 sources have a key that is not a `.git` common-dir;
  `laravel-openapi` is split across ~30 of them. This is the "phantom project" failure
  `isDegenerateRoot` was written to prevent, arriving through a different door.
  `IngesterTests.worktreesOfOneRepoShareCommonDir:160` tests the case where the worktree still
  exists; there is no test for it being gone.
- **Fix (one file + a payload field):** resolve the common-dir **at capture time**, where the
  directory is guaranteed to exist — the precedent is already in the codebase (1.9). Add
  `commonDir: String?` to `GitCommitPayload`/`GitCheckoutPayload` (optional keeps old spool rows
  decodable) and prefer it. Keep the raw-path fallback only for `SourceKind.claudeCode`, where a
  non-git cwd is legitimate; for the `gitRepo` kinds, nil-with-no-captured-fallback should **throw
  and retry** rather than invent a node. A separate one-off merge cleans up the 9 existing phantoms.

#### 2.2 An unparseable extraction response is treated as "no loose ends", and the watermark advances — **high / certain**

- **Anchors:** `LLM/LLMProvider.swift:36`, `Intelligence/LooseEndExtractor.swift:153`,
  `LLM/FoundationModelsProvider.swift:38`; watermark advance at
  `Intelligence/ExtractionRunner.swift:145-166`
- **Wrong:** `extractCandidates` returns `[]` both when the model found nothing and when its answer
  could not be parsed, and `insertVerifiedLooseEnds` advances `extractedAt` /
  `extractedMessageCount` / `extractedTranscriptSize` unconditionally.
- **Why here:** concrete scenario — `claude -p` (the fallback provider, and the *only* provider on a
  machine without Foundation Models) answers a chunk with prose: a refusal, a "Here are the loose
  ends:" preamble with no array, a truncated reply. `firstJSONArray` returns nil → `[]` → the runner
  writes the watermark and logs `proposed=0 verified=0 inserted=0`, identical to a clean session. The
  next run's size check (`ExtractionRunner.swift:58`) skips the event, so those messages are **never
  mined again** unless the transcript grows — and then only the new tail (`start =
  event.extractedMessageCount`, `:84`). For a component whose stated contract is "extraction stays
  lossless: every verified loose end is surfaced" (`:100-106`), that is silent, permanent loss.
  Two asymmetries show it is unintended: `classifyGenuineIndices`/`classifyNonSalientIndices`
  (`LLMProvider.swift:40-52`) deliberately **throw** on an unparseable reply, and a *context-overflow*
  error is retried carefully (`LooseEndExtractor.swift:59-72`) while a garbage answer is accepted —
  the cheap failure is handled, the expensive one is not.
- **Fix (one file + one call site):** throw when `firstJSONArray` finds nothing (mirroring the
  index-array methods) and have `FoundationModelsProvider.extractCandidates` throw instead of
  `return []` on a structure mismatch. `ExtractionRunner`'s existing per-session `catch` then does
  the right thing already: log, leave the watermark unadvanced, retry next pass.
  `decodeCandidates` can keep returning `[]` for a genuinely empty array.

#### 2.3 A punctuation-only word silently zeroes the whole result set — **high / certain / measured**

- **Anchors:** `Search/FTSQuery.swift:109-117` (token construction), `:65` (the `AND` join),
  `Search/EmbeddableItem.swift:116`, `:126` (the `" — "` display joiner)
- **Wrong:** a whitespace-delimited word with no `unicode61` token characters (`—`, `-`, `->`, `|`,
  `/`, `+`, `...`) becomes a zero-token quoted phrase, and FTS5 makes the entire `AND` conjunction
  match nothing.
- **Why here:** measured on a real index —

  ```
  document: 'Pensieve — search everything'
  MATCH '"Pensieve" AND "search"'          → 1 row
  MATCH '"Pensieve" AND "—" AND "search"'  → 0 rows
  MATCH '"Pensieve" AND "-" AND "search"'  → 0 rows
  ```

  The trigger is *this project's own display string*: `EmbeddableCorpus.gather` joins a node as
  `name — description` and a loose end as `text — quote` with `" — "`, and the app renders those
  joined strings. Copy a node title out of the UI, paste it into ⌥⌘F, and you get zero hits for a
  document whose indexed text is character-for-character what you pasted. Same for ordinary typing:
  `client -> server`, `fix - ci`, `sync | agent`. Because `SearchIndexStore.fetch` degrades every
  failure to `[]` while `state()` still reports `.ready`, this reads as "you never worked on that" —
  exactly the confusion `SearchIndexState` was introduced to prevent. `FTSQueryTests` covers `*`,
  `+++`, `C++`, `a:b` in isolation but never a punctuation token *alongside* a real term, which is
  the only case that loses rows.
- **Fix (one file):** in `parse`, drop a word that contributes no FTS5 token (keep quoted phrases
  as-is — `"Pensieve — search"` as a phrase *does* match). Then a punctuation-only query alone still
  degrades to `build(...) == nil`, and `hello ---` behaves like `hello`. Add the paste-a-node-title
  case to `FTSQueryTests`.

#### 2.4 `recall`'s `radius` is unclamped and traps in Kit — one malformed argument kills the MCP server — **high / certain**

- **Anchors:** `Sources/pensieve/Commands/Mcp.swift:131`; trap site
  `Sources/PensieveKit/Query/TranscriptWindow.swift:46`
- **Wrong:** `params.arguments?["radius"]?.intValue ?? 8` accepts a negative value, which reaches
  `session.messages[lower...upper]` with `lower > upper`.
- **Why here:** `whats_next` (`Mcp.swift:124`) and `search` (`:156`) both clamp with `max(1, …)` and
  both carry a comment saying exactly why — "`prefix` traps on a negative … would take the whole
  server down mid-session over one malformed argument". `recall` was left out. For *any* negative
  radius `lower > upper` and the `Range` precondition traps. The server is a long-lived stdio
  process, so the client loses Pensieve entirely, not just that call. Concretely:
  `recall {"loose_end_id":"<any live id>","radius":-1}` → process abort.
- **Fix (one line):** clamp in Kit — `radius: max(0, radius)` inside `TranscriptWindow.slice`, which
  is tested and is where the trap lives, so future app callers get the guard too.

#### 2.5 The sync agent has no deadline and logs only on completion — a hung pass stops background sync silently and forever — **high / likely**

- **Anchors:** `Sources/PensieveSyncAgent/PensieveSyncAgent.swift:15-42`;
  `SyncAgent/me.mazetti.pensieve.sync.plist` (`StartInterval 300`, no watchdog);
  `LLM/FoundationModelsProvider.swift:20-24` (no timeout) vs `LLM/ClaudeCLIProvider.swift:26`,
  `:74-79` (120 s cap)
- **Wrong:** every *error* path is handled and logged; a *hang* is handled nowhere. `SyncRunner.run()`
  has no wall-clock bound and the single `SyncLog.append` is at line 42 — after the await.
- **Why here:** the default provider on macOS 26 is Foundation Models (`.auto` → `foundationModels`
  when available), and its `complete`/guided-generation calls just `await session.respond(...)` with
  no cap — unlike `ClaudeCLIProvider`, which was deliberately given a 120 s terminate. Scenario:
  `ExtractionRunner` reaches a session where `session.respond(to:schema:)` stalls (model asset
  reload, resource pressure) → the agent process never exits → **launchd will not start a second
  instance while one is running**, so the 300 s interval silently stops firing → capture keeps
  spooling but nothing is ever ingested again until logout. The only evidence is a frozen `sync.log`
  mtime, which Settings ▸ Advanced renders as a plain "Last sync: 2 days ago" with no error line —
  indistinguishable from "never registered". `tail -f sync.log`, the sanctioned way to watch this,
  shows nothing at all.
- **Fix (one file):** append a `sync: start` line *before* the work (so the log separates "hung
  mid-pass" from "never ran") and wrap `SyncRunner.run()` in a `withThrowingTaskGroup` deadline that
  logs and exits non-zero. A cap in `FoundationModelsProvider` matching `ClaudeCLIProvider`'s is the
  deeper fix.

#### 2.6 `pensieve eval run` aborts the whole sweep when the cloud judge has no API key — **high / certain**

- **Anchor:** `Sources/pensieve/Commands/Eval.swift:86`
- **Wrong:** the judge provider is built up-front and a nil key ends the run, including for
  gold-scored tasks that need no judge.
- **Why here:** you have a Claude subscription and no API key. The project rule is that a new
  LLM-backed task must take its default model from `pensieve eval` — so the command that rule depends
  on cannot run on the machine the rule is written for. Compounding it, `Eval/EvalConfig.swift:5`'s
  `ModelSpec.kind` is `foundationModels|cloud`, so the subscription provider (`claudeCLI`) cannot even
  be *represented* in a roster, and `Runner.runCell` passes `apiKey: nil` for the reference and then
  fails quietly (`Eval/Runner.swift:31`).
- **Fix (one file, then one small feature):** build the judge lazily and skip only judge-scored tasks
  with a loud warning; separately add a `claudeCLI` case to `ModelSpec.kind` so the roster can name
  the provider you actually have.

#### 2.7 Every watch-driven refresh opens fresh store connections in the directory it watches — **high / certain that the rule is violated, likely that the loop fires**

- **Anchors:** `AppModel.swift:309` (→ `AppIntents/SpotlightIndexer.swift:10`) and
  `AppModel+Search.swift:46` (→ `Search/SearchIndexer.swift:32-34`). Rule stated at
  `Query/MonitorSnapshot.swift:54-57`, restated at `AppModel.swift:56-58` and `:360-361`.
- **Wrong:** `refreshFromWatch()` (`AppModel.swift:301-307`) is triggered *by* the support-directory
  watch and then calls `syncSearchIndexes()` → `SearchIndexer.production()` (a brand-new
  `SearchIndexStore` pool, plus a new `TranslationStore` pool when a language is set) and
  `reindexSpotlight()` → `openCanonicalDatabaseReadOnly(...)` (a brand-new canonical connection) —
  all against files in the directory `canonicalWatcher` watches.
- **Why here:** the project already paid for this. `MonitorSnapshot` grew a second `gather` overload
  whose doc reads: "The app **must** use this: its FSEvents watch on the store directory would
  otherwise be re-fired by the `-shm`/`-wal` churn of opening a fresh connection on every refresh,
  spinning a busy-loop." `AppModel` holds `spool` and `database` persistently for the same reason.
  Both fixes are undone downstream in the same call chain. One turn costs a full main-actor
  `refresh()` (5.2), a whole-corpus `EmbeddableCorpus.gather` + hash, and a full Spotlight
  delete-and-reindex; the 0.15 s debouncer bounds it to ~6 turns/second rather than stopping it.
  `SearchIndexStore.open` also runs a `pool.write` (schema check) per construction, so this is a
  **write** to the watched directory.
- **Fix (one file):** pass the already-open reader into Spotlight
  (`SpotlightIndexer.reindex(database:activeContext:)`) — read-only work, and the
  `MonitorSnapshot.gather(canonical:spool:)` overload is the precedent. Build the indexer from the
  model's long-lived stores instead of `.production()`, reproducing `.production()`'s language rule
  explicitly. Confirm with one `/usr/bin/log stream --predicate 'category == "app"' --level debug`:
  a steady drip of "Canonical watcher fired -> refresh" with no git activity is the loop.

#### 2.8 Remaining correctness and concurrency findings

| # | Defect | Anchor | Failure scenario | Sev |
|---|---|---|---|---|
| 2.9 | `userPromptCount` counts tool results | `Transcript/TranscriptParser.swift:44`; `Ingester.swift:154`, `:177` | measured: 362 `type:"user"` records of which 331 are `tool_result` → app renders "session (207 prompts)" for ~20 human turns. `SummaryBuilder`'s comment already quotes the damage; the workaround went downstream instead of fixing the count | med |
| 2.10 | An undecodable spool row is retried forever; permanent and transient are indistinguishable | `Ingester.swift:54-62`, `:91` | one malformed payload re-attempted every 300 s indefinitely; nothing surfaces it | med |
| 2.11 | The capture path can fail and lose the capture with no record | `Store/StoreOpen.swift:6-8`, `Store/CaptureSpool.swift:18-31` | `openSpool()` opens with a `CREATE TABLE` write txn and a 5 s busy timeout; a throw loses the capture silently, contradicting the comment above it. (`git commit` itself is safe — the hook's `&` + `exit 0` was traced end to end) | med |
| 2.12 | Nothing anywhere knows about `core.hooksPath` | `Capture/HookInstaller.swift:41-68` | a repo (or global config) setting `core.hooksPath` renders every installed hook inert, and `pensieve` reports the hooks as installed | med |
| 2.13 | Cancellation never reaches the `claude -p` child; the task-group timeout is defeated | `LLM/ClaudeCLIProvider.swift:17`; `Query/SessionContextQueries.swift:203` | `narrateWithin(3.0)` returns after 3 s but the child runs to its 120 s cap holding the slot | med |
| 2.14 | `StructuralNoiseFilter` can drop the user's own long design messages | `Intelligence/StructuralNoiseFilter.swift:42` | a message with `"Do not "` plus two bold labels and ≥800 chars is classified as harness noise — i.e. exactly a long design brief | med |
| 2.15 | Two paths report success for a write that may not have happened | `Intelligence/NodeDescriber.swift:59`, `Intelligence/SalienceSuggester.swift:74` | `try? await database.write` fails, the function still returns `.wrote`; caller logs success | med |
| 2.16 | `NarrationTask`/`DescriptionTask` report provider failures as successful empty output | `Eval/NarrationTask.swift:12`, `Eval/DescriptionTask.swift:12` → `Intelligence/SummaryBuilder.swift:121` | defeats the protection `CellScoring` documents at its top: a dead provider scores as a bad model, not a failed run | med |
| 2.17 | Event text-dedup drops the later commit's file paths | `Search/EmbeddableItem.swift:154`, `:156` | two commits with the same message → the second's file paths are never indexed, so path search misses those files | med |
| 2.18 | `searchTask?.cancel()` cannot stop the work it claims to cancel | `AppModel+Search.swift:80-141` (`:81`, `:121`, `:131`) | `Task.detached` body never checks cancellation → up to 4 detached searches in flight per tick; the sibling `AppModel+Translation` documents this as load-bearing | med |
| 2.19 | Canonical-store open failure swallowed → empty pane, no log | `AppModel.swift:215` | a corrupt or permission-denied store renders as "no projects yet" with nothing in the log | med |
| 2.20 | `try? openCanonicalReadOnly()` conflates "no store" with "store broken" (MCP) | `Commands/Mcp.swift:263` | MCP answers `project_context` as if you had never used Pensieve | med |
| 2.21 | A malformed `node_id` silently becomes "the cwd's project" | `Commands/Mcp.swift:110` | a typo'd UUID returns confident context for a *different* project | med |
| 2.22 | Corrupt `eval-config.json` swallowed and misreported as a roster problem | `Commands/Eval.swift:11` | `try?` → defaults; the user debugs the roster instead of the JSON | med |
| 2.23 | `pensieve eval`'s registry↔config guard doesn't cover registry↔corpus | `Eval/CorpusBuilder.swift:39`, `:59` + `Eval/EvalTask.swift:22-30` | a newly registered task loads zero items and scores as if it passed | med |
| 2.24 | The judge-calibration loop is fully wired and never invoked | `Eval/Judge.swift:88`, `Eval/Agreement.swift:5`, `Commands/Eval.swift:141` | every model decision rests on an unvalidated judge | med |
| 2.25 | The cost axis counts output tokens only | `Eval/Runner.swift:47` + `Eval/CellScoring.swift:58` | `estInputTokens` is written as 0 and never read, so a long-prompt model looks free | med |
| 2.26 | `resolveEvents` swallows a read failure unlogged, and missing events get no "unavailable" entry | `Query/ProvenanceLoader.swift:96-100`, `:111` (vs the correct `:112-117`) | a citation silently disappears from the recall view instead of showing as unavailable | med |
| 2.27 | `prune()` evicts all crash diagnostics before any metrics file | `App/DiagnosticsCollector.swift:44-55` | the diagnostics you actually need are the first deleted | low-med |
| 2.28 | Extraction never checks cancellation; `CancellationError` is logged as a per-session failure | `Intelligence/ExtractionRunner.swift:33`, `:125` | app quit mid-pass shows as N extraction failures | low |
| 2.29 | Non-UTF-8 or transiently unreadable transcript dropped forever | `Transcript/TranscriptParser.swift:14-17`; `Ingester.swift:139-144` | a transient read error permanently retires a session | low |
| 2.30 | One unrecognized enum raw value throws the whole query, not one row | `Model/LooseEndStatus.swift:8-11` | a future status value makes every loose-end query fail | low |
| 2.31 | Cloud completions capped at 1024 tokens with truncation undetected | `LLM/CloudProvider.swift:104`, `:153` | a truncated narration is stored and cached as complete | low |
| 2.32 | No mutual exclusion between agent extraction and a manual `pensieve sync`/`ingest` | `Sync/SyncRunner.swift:47`, `Commands/Ingest.swift:14` | duplicated LLM work and lock contention (events themselves are safe — fingerprints are checked inside the write txn) | low |
| 2.33 | `checkFreeSpace` whitelists a genuinely full volume | `Store/StoreRelocator.swift:337-341` | `?? 0` then `available == 0` passes the check | low |
| 2.34 | Index delete-and-retry removes only the main file, not `-wal`/`-shm` | `Search/SearchIndexStore.swift:37` (cf. `StoreRelocator.swift:253`, which does it right) | a corrupt index is "recreated" on top of a stale WAL | low |
| 2.35 | `FSEventStreamCreate`/`Start` failure discarded silently | `Support/DirectoryWatcher.swift:27-34` | live updates stop; the UI looks merely quiet | low |
| 2.36 | `pending()` fabricates "now" for an unparseable timestamp | `Store/CaptureSpool.swift:48` | a bad row sorts as the newest capture forever | low |
| 2.37 | Widget cannot distinguish absent from undecodable digest, even in its log | `PensieveWidgetBundle.swift:44-62`; `Widget/WidgetDigest.swift:50-53` | both render "Open Pensieve to get started"; a torn write is impossible (`publish` is `.atomic`) | low |
| 2.38 | Small ones | `Query/SystemStatus.swift:71-72` (`?? nil` on an already-flattened `try?`) · `Query/MonitorSnapshot.swift:68-71`, `:87-88` (unreadable store reports "Not set up") · `AppModel+Translation.swift:120-133` (late progress callback writes onto a later run) · `RelocationLauncher.swift:41-47` (bundle path interpolated into `sh -c`) · `AppModel.swift:233-240` (two `DirectoryWatcher`s on one directory) · `Commands/Mcp.swift:113` (unbounded `listRoots()`) · `:125` (unvalidated `context` — a typo silently shrinks the queue) · `Eval/CellScoring.swift:89-91` (judge failure scored as bad output, unlike sample failure at `:42-46`) | — | low |

### Category 3 — Architecture boundary violations

**The `Ingester.drain()`-is-the-only-writer invariant holds.** Audited from three directions: the
`Query` write verbs touch only organizing/lifecycle columns; the app's four canonical write families
are all deliberate organizing writes; the one event-touching path (`NodeCommands.delete` via FK
cascade) is guarded and documented. No violation found. The findings below are the softer boundaries.

| # | Violation | Anchor | Why it matters | Sev |
|---|---|---|---|---|
| 3.1 | (see 2.7) Watch-driven refresh opens fresh connections in the watched directory | `AppModel.swift:309`, `AppModel+Search.swift:46` | re-arms a documented busy-loop | high |
| 3.2 | `nameStrand` is the one LLM pass with no per-pass cap, and it fires inside `drain()` | `Ingester.swift:110`, `:185` vs the capped siblings at `:269`, `:273` | both neighbouring passes carry a cap *and document why*; an unbounded LLM pass inside the drain is how 2.5 becomes reachable | med |
| 3.3 | `Git.defaultBranch` (4 subprocesses) runs inside the canonical write transaction | `Ingester.swift:171` vs `:94` | holds the write lock across process spawns on the session path | med |
| 3.4 | `PensieveMCP`'s derivation lives in the CLI target, untestable | `Commands/Mcp.swift:181-314`, esp. `:293` | scope construction, passage budget and payload assembly sit where `PensieveKitTests` cannot reach — `grep -rl PensieveMCP` matches only that file. 26 of 28 CLI files are properly thin | med |
| 3.5 | Review Suggestions is the only surface in the window not Focus-scoped | `AppModel.swift:386` vs `:387-388` | Focus filter applied per call site; this site was missed | med |
| 3.6 | Two canonical reads + a full share-text render inside a context-menu `body` | `NodeOrganizing.swift:171`, `:189` | database work per menu construction | med |
| 3.7 | Day bucketing and two sorts inside the timeline's `body` | `DetailView.swift:319-323` | belongs in PensieveKit; note it does *not* duplicate a Kit rule (`startOfDay` appears once in the repo), so this is "untestable", not "drift" | med |
| 3.8 | Briefing's moved/quiet partition derived in the view | `BriefingView.swift:11-12` | same shape as 3.7 | low |
| 3.9 | The app is a canonical writer that bypasses `CanonicalWriterGate` | `AppModel.swift:215` vs `Store/StoreOpen.swift:17-31`, `:56-59` | the gate exists to make writer identity explicit; the app opts out | low |
| 3.10 | `SmartLists.compute` — the only read in its directory — demands `any DatabaseWriter` | `Query/SmartLists.swift:16` | a read path that cannot be handed a read-only connection | low |
| 3.11 | The app applies Focus itself, contradicting `whatsNext`'s own doc claim | `NextQueries.swift:91-98` + `SmartLists.swift:22` vs `AppModel.swift:331-335`, `:371-373` | two layers each believe they own Focus scoping | low |

### Category 4 — Non-idiomatic or suboptimal Swift

**Thin, and that is a real result.** Three auditors reported this category empty for their areas; the
Swift here is idiomatic. What is left is vestigial naming from the removed vector engine and two raw
`String` columns.

| # | Finding | Anchor | Sev |
|---|---|---|---|
| 4.1 | `Event.kind` / `Source.kind` are the last raw-`String` kind columns | `Model/Event.swift:10`, `Model/Source.swift:8` | low, boundary-crossing fix |
| 4.2 | `EmbeddableItem` / `EmbeddableCorpus` are named for the removed engine; `contentHash` is vector-era indirection | `Search/EmbeddableItem.swift:30-39` | low — rename to `SearchDocument`/`SearchCorpus` has a *contained* blast radius (only `Translation/TranslatableCorpus.swift:42`, `:50` reference them outside `Search/`; no wire format, no `CodingKeys`) |
| 4.3 | `SearchHitResolver`'s doc comment asserts a live vector engine | `Query/SearchHitResolver.swift:26-27`, `:40-43` | low |
| 4.4 | `abs` shadows `Swift.abs` | `Commands/Track.swift:10` | low |
| 4.5 | Raw `Date` printing, non-atomic write, echoed API key, double provider build | `Commands/Status.swift:14`, `Eval.swift:109`, `Eval.swift:29`, `Ingest.swift:9` | low |

### Category 5 — Inefficiency with evidence

#### 5.1 `looseEnds` has no `nodeID` index, and three per-node loops scan it once per active node — **high / certain / measured**

- **Anchors:** `Query/NextQueries.swift:69`, `:70-72` (two scans per node);
  `Query/BriefingQueries.swift:55` (a third, via `LooseEndQueries.open`); the index is absent —
  `Store/CanonicalStore.swift:88`, `:210-211` create the only three indexes and none covers `looseEnds`
- **Why here (measured against the live store):**
  `EXPLAIN QUERY PLAN SELECT count(*) FROM looseEnds WHERE nodeID=? AND status='open' AND label<>'noise'`
  → `SCAN looseEnds`. The sibling query on events → `SEARCH events USING INDEX idx_events_project`.
  Per `refresh()`: `NextQueries.ranked` = 610 scans (open + closed per node), `BriefingQueries.cards`
  = 305 more, plus 2 = **~917 scans × 1,076 rows ≈ 987k row visits**, for numbers that two grouped
  aggregates already produce. `refresh()` runs on every debounced store-watch event and after every
  resolve; `refreshGlance()` re-runs `ranked` for the menu-bar popover.
- **Fix (one migration line):**
  `CREATE INDEX "idx_looseends_node" ON "looseEnds"("nodeID", "status")`, mirroring
  `idx_events_project`. That is the one-line half; **1.4 is the structural half** — do both.

#### 5.2 `refresh()` is two un-batched whole-store passes on the main actor — **medium-high / certain**

- **Anchor:** `AppModel.swift:359-390`
- **Why here:** ~1,000 statements synchronously on the main actor on every watch tick, every
  organizing write and every loose-end resolve — including `briefingCards` for a pane that is usually
  off screen, and sitting *beside* `rowFacts`, which was batched for exactly this reason and already
  computes two of the facts `ranked` recomputes per node.
- **Fix:** fold onto the batched aggregates (1.4) and compute briefing lazily when its pane is visible.

| # | Cost | Anchor | Why the path is hot | Sev |
|---|---|---|---|---|
| 5.3 | `model.displayed(...)` is a main-actor SQLite read + `StableHash`, 5N times per detail load | `DetailView.swift:71-72`, `:173`, `:187`, `:209`, `:232` → `TranslationStore.swift:56-63` | every detail-pane open; gated off when translation is off (the default) | med |
| 5.4 | `searchStore.state()` is a main-actor SQLite read (5 s busy timeout) per search | `AppModel+Search.swift:104` — contradicting the same file's policy at `:49-51` | every keystroke-debounced search | med |
| 5.5 | Bulk close = one main-actor write transaction per loose end | `AppModel+Recall.swift:96-99` | 288 transactions for "resolve all" on a busy node | med |
| 5.6 | `importLabels` opens one write transaction per entry | `Query/LooseEndCommands.swift:114` | bootstrap path over the whole backlog | med |
| 5.7 | `digest` narrates every active node including strands, sequentially | `Commands/Digest.swift:13` | one LLM call per node, no cap — a CLI command that grows unusable as the tree grows | med |
| 5.8 | `capture-session-start` makes two unbounded `git` calls in the foreground hook | `Commands/CaptureSessionStart.swift:25` → `Support/Git.swift:4` | on the capture path — the hook is foreground here, unlike the `&`-backgrounded commit hook | med |
| 5.9 | Every new transcript is read and JSON-parsed twice, once for a flag | `Discovery/TranscriptDiscovery.swift:38-45` | every drain, every new session file | low-med |
| 5.10 | `displayed(field:)` is unmemoized SQL per row per body evaluation | `AppModel+Translation.swift:56-61` | list scrolling | low-med |
| 5.11 | Off-`body` `.task` reads are still main-actor | `AppModel+Recall.swift:7-14`, `:28-31` | correct place, wrong actor | low-med |
| 5.12 | Both LLM naming passes fetch all ~190 project nodes + 1 query per node, every 300 s | `Ingester.swift:300-306`, `:341-345` | every agent pass, forever | low |
| 5.13 | Emoji search re-runs a Unicode-name transform over the whole catalog per keystroke | `IconPicker.swift:91-97`, `:34-37` | icon picker typing | low |
| 5.14 | `segments(for:)` linear-scans the message array on every access | `LooseEndRow.swift:358-363` | per row, per body evaluation | low |
| 5.15 | `AppModel.node(_:)` is an O(nodes) scan per feed/search row | `ContentListView.swift:116`, `:190`, `:239` | 306 nodes × every visible row | low |
| 5.16 | Passage rewrite is 1 INSERT per row (max 464) and reruns when nothing grew | `Ingest/Ingester+Passages.swift:45-46` | every drain | low |
| 5.17 | Every capture pays a DDL write transaction before its insert | `Store/CaptureSpool.swift:19-31` | **on the sacred path** — cheap today, but it is a write txn where the design says "append one row and exit" | low |
| 5.18 | `resolveEvents` issues per-id point queries; the measured sibling batches with `IN` | `ProvenanceLoader.swift:96-100` vs `LooseEndQueries.swift:166-170` | recall view load | low |
| 5.19 | One read transaction per node in the eval corpus builder, breaking snapshot consistency | `Eval/CorpusBuilder.swift:91-96` | corpus freeze | low |

### Category 6 — Type and file structure

You read `AppModel.swift` at exactly 400 lines as a signal. It is a signal about `refresh()` (1.4,
2.7, 5.2), not about the file. Per-file verdicts:

| File | Lines | Verdict | Seam |
|---|---|---|---|
| `PensieveApp/AppModel.swift` | 400 | **Long, not incoherent.** 45% is stored state Swift cannot move to an extension; six `AppModel+` extensions already exist | If you split: `:203-329` (`start()` + liveness wiring) → `AppModel+Lifecycle.swift` |
| `Ingest/Ingester.swift` | 395 | **Genuine cohesion problem** | The three LLM-assist passes `:267-388` → `Ingester+Naming.swift`. They are the only part that is not spool-draining, and they are what 3.2/3.3 are about |
| `Transcript/TranscriptMarkup.swift` | 392 | **Cohesive — merely long. Do not split.** | — (but see 7.1: its doc comments are corrupted) |
| `PensieveApp/LooseEndRow.swift` | 387 | **Genuine cohesion problem** | The provenance box, ~170 lines and 4 of 8 `@State` (`:224-247`, `:338-387`) → own view |
| `PensieveApp/DetailView.swift` | 385 | **Genuine, two seams** | `ActivityTimeline` (`:312-385`) → own file; the `.task` load orchestration (`:141-189`) → Kit |
| `pensieve/Commands/Mcp.swift` | 376 | **Genuine — but the seam is a layering fix, not a file split** | `PensieveMCP`'s derivation → PensieveKit (3.4) |
| `Search/SearchIndexStore.swift` | 373 | Merely long; not flagged | — |
| `PensieveApp/ContentListView.swift` | 366 | **Merely long**, one clean seam if wanted | The search surface (`:65-139`) |

Category 6 came up **empty** for `Query/` (30 files averaging 95 lines) and for `Search`/`Eval`.

### Category 7 — Naming debt

#### 7.1 A previous naming cleanup silently corrupted 24 doc-comment lines in 3 files — **medium / certain / verified by the orchestrator**

Read this before doing any of the renames below. Whole-word replacement rewrote English prose:

| File | Lines | Damage |
|---|---|---|
| `Transcript/TranscriptMarkup.swift` | 18 | every article "a" → `commandArgs`; `i.e.` → `scanIndex.e.`. Commit `321bad2` "refactor: rename identifiers in markup, next, verifier and commands" |
| `Eval/CorpusBuilder.swift` | 5 | "a" → `lhs` (`"Marker Claude Code stamps on lhs compaction-summary record"`) |
| `PensieveApp/IconPicker.swift` | 1 | `e.g.` → `emojiValue.g.` |

Samples, verbatim from the tree:

```
/// (harness first, then callouts) is self-contradictory: commandArgs callout containing commandArgs `<system-reminder>`
/// absent — scanIndex.e. it can actually *open* an indented code block, per CommonMark; commandArgs continuation
/// Reads the canonical store (+ transcripts/git) and produces lhs frozen, stratified corpus for
/// A lowercase Unicode name for search, emojiValue.g. "😀" → "grinning face". Uses the system transform.
```

**Why it matters here:** `TranscriptMarkup.swift`'s doc comments *are* the parser specification —
the precedence ladder and the CommonMark reasoning exist nowhere else. They are now unreliable, and
`--strict` lint is blind to comment prose, so the corruption survived review. **This is a live
argument against a bulk mechanical rename pass**: do the category-7 work with word-boundary *and*
identifier-context awareness, or file by file with the diff read.
**Fix (three files):** restore the prose. `git show 321bad2 -- Sources/PensieveKit/Transcript/TranscriptMarkup.swift`
gives the pre-rename text for the 18-line bulk.

#### 7.2 The genuine abbreviation inventory

Your probe of ~37 live hits is closer to **~28 genuine sites**. `info` is almost entirely noise:
`Log.*.info(` / `AppLog.*.info(` is the `os.Logger` level, `"info.circle"` is an SF Symbol, plus
`Bundle.infoDictionary` and Apple's own `FSEventStreamContext(info:)` callback label. One genuine
site survives. `res`, `val`, `num`, `src`, `dst`, `cnt` have **zero** hits.

| File | Tokens | Proposed |
|---|---|---|
| `pensieve/Commands/Eval.swift:11-149` | `cfg` ×25 | `config` — includes the **declared** label `RunSweepContext(cfg:)` at `:149` |
| `PensieveApp/LooseEndRow.swift:225-385` | `msg` ×22, `ctx`, `idx`, `pos`, `all` | `message`, `context`, `offset`, `messagePosition` — all fileprivate/private |
| `Ingest/ProjectContext.swift:71,116,126,140,157` | `obj`, `ctx` ×4 | `payload`, `context` |
| `Support/Git.swift:4,26,31,38` | `args`, `ref`, `cfg` | `arguments` (**declared external label**), `symbolicRef`, `configuredBranch` |
| `Eval/CorpusBuilder.swift:37,56` + `EvalPaths.swift` | `dir` ×13 | `directory` (**declared external labels** `to dir:` / `from dir:`) |
| `Eval/CorpusSampler.swift:44-53` | `arr`, `idx` | `stratum`, `cursor` |
| `Eval/Runner.swift:7-9,40-48` | `msg`, `err` | `message`, `caughtError` |
| `Ingest/Ingester.swift:277,283` | `obj` | `metadata` |
| `Transcript/TranscriptParser.swift:27` | `obj` | `line` / `record` |
| `Transcript/TranscriptMarkup.swift:283-304` | `args` | `arguments` — internal; the `"command-args"` **literal is a wire tag** and must stay |
| `Intelligence/SalienceClassifier.swift:30,54` | `idx`, `pos` | `nonSalientIndices`, `messagePosition` |
| `Support/DirectoryWatcher.swift:20` | `ctx` | `streamContext` — the `info:` label is Apple's, keep |
| `Discovery/SourceScanner.swift` | `dir` ×4 | `directory` |
| `PensieveApp/AppInfo.swift:17` | `info` | `bundleInfo` |
| `PensieveApp/IconPicker.swift` | `props`, `out` | `properties`, `names` |
| `LLM/FoundationModelsProvider.swift:43` | `idx` | `messageIndex` |
| `Query/NodeForest.swift:20-21,29,33` | `pid`, `kids` | `parentID`, `children` |
| `Query/{NodeContext,SessionContextQueries,MonitorSnapshot,Snippet}.swift` | `ctx`, `loose`, `lead`/`trail` | `context`, `openLooseEnds`, `leading`/`trailing` |
| `Commands/Track.swift:10` | `abs` | shadows `Swift.abs` — rename regardless |

**Boundary warnings.** `Git.run(_ args:)`, `CorpusBuilder.write(to dir:)` / `loadFrozen(from dir:)`
and `RunSweepContext(cfg:)` are **declared labels** — every call site must change in the same commit.
`identifier_name` has `min_length: 3`, so `ctx`/`cfg`/`obj`/`idx`/`arr`/`pos`/`msg`/`len`/`dir`/`ref`
all pass lint *at the declaration too*: **lint will not catch a half-done rename, only the compiler
will.** Keep behind `CodingKeys`/verbatim: `"command-args"`, `messageIndex`, `maxTokens`,
`CloudProvider`'s response DTO keys, all MCP `snake_case` keys, and `SearchHit.Kind.looseEnd`'s
`"loose_end"` (a stored index value). Greps for `fm`/`le` matched string *values*
(`"apple/fm"`, `providerKind: "fm"`), not identifiers.

### Category 8 — Test quality

**The suite is unusually good, and that is a measured claim.** Fixtures are deliberately built so
rank order cannot be confused with insertion order; absence-halves are paired with presence-halves;
doc comments record past mutation runs and name what a test does *not* cover. Seven mutations were
run against the weakest assertions found in 13.7k lines; **two came back "the test is real"**, and
those are reported as such. No order dependence, no wall-clock or future-date fragility, no
happy-path write to the live store. The UI suite (351 lines) needed nothing.

#### Mutation log (7 run, every one reverted; worktree verified clean afterwards)

| # | Mutation | Observed | Verdict |
|---|---|---|---|
| M3 | `LLM/DefaultProvider.swift:46` — factory always returns a **cloud** provider | **802/802 passed** | vacuous ✓ (strongest result) |
| M1 | `Eval/NarrationTask.swift:13` text → `"MUTANT"` | target test passed, a sibling failed | vacuous ✓ |
| M6 | `Eval/DescriptionTask.swift:13` sanitize removed | **802/802 passed** | vacuous ✓ |
| M7 | `Store/CaptureSpool.swift:105` dropped `WHERE ingested = 0` | **802/802 passed** | vacuous ✓ |
| M4 | `Query/SystemStatus.swift:69` → `false` | failed on this Mac (probe returns `true`) | real here, **vacuous in CI** |
| M2 | `Intelligence/NarrationCacheKey.swift:19` `"r2"` → `""` | failed (`contains("")` is `false` in Swift) | **suspicion disconfirmed** |
| M5 | `Intelligence/SummaryBuilder.swift:66` budget break deleted | failed (6259 vs 2000) | **test is real — not a finding** |

Baseline: `make test FILTER=FTSQueryTests` → 15/15. Post-revert full suite: 802 tests, 17 suites, pass.

#### 8.1 `makeDefaultLLMProvider`'s return value is asserted nowhere in 802 tests — **high / certain (mutation-proven)**

- **Anchors:** `Tests/PensieveKitTests/DefaultProviderTests.swift:19` (+ `:5`, `:29`, `:45`, `:58`);
  implementation `Sources/PensieveKit/LLM/DefaultProvider.swift:43`
- **Wrong:** every test named for the provider fallback asserts on `resolvedProviderKind` — the pure
  resolver *beside* the factory — not on what the factory returns. M3 replaced the factory body with
  "always return a remote cloud provider" and the entire suite passed.
- **Why here:** `CLAUDE.md` states "extraction stays on-device" and you have no API key. That is a
  privacy and correctness guarantee with **zero** test coverage: a refactor that routes on-device
  extraction to the cloud provider ships green. This is the single largest coverage hole found.
- **Fix (one test):** assert on the concrete type the factory returns for each preference —
  `#expect(provider is FoundationModelsProvider)` for `.auto` on a capable machine, and that no
  configuration reachable without an explicit cloud opt-in returns `CloudProvider`.

#### 8.2 Remaining test-quality findings

| # | Finding | Anchor | Sev |
|---|---|---|---|
| 8.3 | `narrationTaskReturnsProse` asserts a value the implementation hardcodes (M1) | `NarrationDescriptionTaskTests.swift:10-15`; `Eval/NarrationTask.swift:13` | med |
| 8.4 | `descriptionTaskSanitizesModelOutput` feeds input that needs no sanitizing — tests pass-through (M6) | `NarrationDescriptionTaskTests.swift:28-35`; `Eval/DescriptionTask.swift:13` | med |
| 8.5 | `readOnlyAccessorsMatchWritePathOnRealStores` compares two restatements of one SQL query only to each other, on a spool with **zero** ingested rows (M7) | `MonitorSnapshotTests.swift:81`; `Store/CaptureSpool.swift:85` + `:105` | med |
| 8.6 | Three tests `setenv` process-global `PENSIEVE_DB`/`PENSIEVE_CAPTURE_DB` with no `.serialized`; on a lost race one **appends a row to the live capture spool** | `StoreOpenTests.swift:9`, `:27`, `:64`, `:74` | med |
| 8.7 | Three tests silently pass without exercising anything when `git worktree add` fails | `GitSourceTests.swift:24`, `IngesterTests.swift:163`, `SourceScannerTests.swift:56` | low |
| 8.8 | `CatalogCoverageTests`' missing-key direction is vacuous if the source scan finds nothing | `CatalogCoverageTests.swift:231-239` (+ `:152-156`, `:178`) | low |
| 8.9 | `foundationModelsAvailable` asserts `f(x) == f(x)` against the same probe the impl calls — vacuous in CI (M4) | `SystemStatusTests.swift:27`; `Query/SystemStatus.swift:69` | low |
| 8.10 | Assertion subsumed by the line above it (`"/usr/bin".contains("/bin")`) | `SyncAgentEnvironmentTests.swift:9` | low |
| 8.11 | Cache-key test pins the rule token's presence; nothing pins it being *bumped* | `NarrationCacheKeyRuleTests.swift:15`; `NarrationCacheKey.swift:19` | low |

**Missing error-path coverage** for the category-2 findings above: 2.2 (watermark advance on an
unparseable reply), 2.3 (a punctuation token beside a real term — `FTSQueryTests` tests punctuation
only in isolation), 2.4 (negative `radius`), 2.1 (`worktreesOfOneRepoShareCommonDir:160` covers the
worktree *existing*; nothing covers it being gone), and 1.6 (`PensievePathsTests.swift:75` pins only
the `in: support` form for the narration cache).

---

## 3. Top 10 worth doing

Ordered by value-per-effort. Sequencing rationale follows the table.

| # | Do this | Fixes | Effort | Why now |
|---|---|---|---|---|
| 1 | Clamp `radius` in `TranscriptWindow.slice` | 2.4 | **one line** | A live crash that kills your MCP server mid-session. Two sibling call sites already do it and say why |
| 2 | `CREATE INDEX idx_looseends_node ON looseEnds(nodeID, status)` | 5.1 | **one migration line** | ~917 table scans → ~917 index seeks per refresh, for one line |
| 3 | `narrationCacheURL()` → `indexURL(named:)`, and pick one narratable window | 1.6 | **one line + one decision** | A fixture run can delete your live narration cache; and `pensieve prime` is permanently cold today |
| 4 | Add `isClosedAndReal` and use it at all three sites | 1.1 | **one file** | A 👎 currently drops a node from What's Next, the widget, MCP and the CLI *permanently*, with no closed feed showing it |
| 5 | Throw instead of returning `[]` on an unparseable extraction reply | 2.2 | **one file + one call site** | Silent permanent loss of loose ends — a direct north-star violation. The runner's `catch` already does the right thing |
| 6 | Resolve repo identity at capture time; extract `ProjectResolver.identityKey` | 2.1 + 1.2 + 1.9 + 1.29 | **one file + a payload field** (+ a one-off merge of the 9 phantoms) | The worst *data* defect found, already in your store. The precedent exists in the codebase |
| 7 | Assert what `makeDefaultLLMProvider` returns | 8.1 | **one test** | "Extraction stays on-device" is a stated guarantee with zero coverage; the mutation shipped green |
| 8 | Deadline + start-line in the sync agent | 2.5 | **one file** | A hang stops all background ingestion forever, and the log looks fine |
| 9 | Drop zero-token words in `FTSQuery.parse` | 2.3 | **one file** | Pasting a node title into search returns nothing. Add the paste case to `FTSQueryTests` |
| 10 | Reuse the model's open stores in `refreshFromWatch` | 2.7 | **one file** | Re-arms a documented busy-loop; also the cheapest large win on main-actor stalls |

**Sequencing.** Items 1–3 are one-liners with no design questions — land them first, in any order.
Item 4 then 5 are the two "wrong answer" bugs and are independent of each other. Item 6 is the only
one needing a payload-schema decision and a data migration, so give it its own branch; do it *after*
4 and 5 so the phantom-node merge runs against correct loose-end accounting. Item 7 is a test-only
change that should land *before* any provider refactor. Items 8–10 are independent single-file fixes.

**Deliberately not in the top 10, though tempting:** the 1.4 four-way consolidation (high value, but
it is a real refactor — schedule it right after item 2, since the index makes the N+1 survivable in
the meantime) and the category-7 rename pass (do 7.1's comment restoration first, and read 7.1's
warning before touching anything mechanically).

---

## 4. Considered and rejected

The union of ten auditors' lists, condensed. This is what was examined and deliberately *not* flagged.

**Invariants verified intact — these were the questions most worth answering, and the answers are good.**
- **`Ingester.drain()` is genuinely the only writer of canonical *event* data.** Checked from three
  directions. The `Query` write verbs touch only organizing/lifecycle columns; the app's four write
  families are all deliberate organizing writes; `NodeCommands.delete`'s FK cascade is guarded and
  documented. `BackfillPassages` writes through the Ingester.
- **Git hooks cannot block or fail `git commit`.** Traced end to end (`HookInstaller.swift:20-25`,
  `:33-38`): `&` plus `exit 0`.
- **Concurrent app + agent drains cannot double-write events.** All four capture kinds carry a
  fingerprint checked *inside* the write transaction (`Fingerprint` derives all three key kinds in
  one enum, with no second implementation).
- **The verbatim trust gate is a real chokepoint.** `LooseEnd.insert` appears in exactly the places
  it should; the normalization rule lives in one function that the display side calls. Its
  case-sensitivity and lack of Unicode normalization are deliberate and tested.
- **FTS5 escaping is single-sourced and safe.** `FTSQueryBuilder.quoted` is the only MATCH builder;
  `"`, `""`, `""*`, `*`, `^`, `NEAR`, `a:b`, `C++*`, an unbalanced quote and `don't` were all run
  against a real FTS5 table — none error. (The one real bug, 2.3, is a *producer*-side zero-token
  case, not an escaping hole.)
- **A torn widget digest is impossible** — `publish` writes with `options: .atomic`.
- **Migrations cannot half-apply** — GRDB wraps each registered migration in its own transaction.
- **A failed partial index rebuild cannot leave a silently wrong index** — `rebuild` is transactional.
- **No captured content flows through a localization or translation path.** Checked every site;
  `TranslationField` has no case for a quote or a transcript, and translated node names reach only
  the search index, never a rendered label.
- **Source-kind agnosticism is clean.** Grepped every kind literal; outside `CapturePayloads.swift`
  only doc comments and test fixtures.
- **`Model/` does not lie about the STRICT schema** — all ten types walked against every migration.
- **JSON-RPC framing is correct** — newline framing with partial-read accumulation, `parseError` on
  malformed input, handler throws mapped to `internalError`, no-op transport logger, and **nothing**
  in PensieveKit or the CLI writes to stdout.
- **`Package.swift` is tools-6.0 without `NonisolatedNonsendingByDefault`, so SE-0338 hops
  `drain()` off the main actor** — the `AppModel` main-actor call is not a bug. *Re-check if the
  package adopts Swift 6.2 defaults.*
- **`StoreRelocator` is the strongest code in the codebase** — lock-before-copy, copy-not-move,
  semantic verification, one commit point, post-commit recovery, and no recycle when recovery is
  unverifiable.

**Already-single-sourced rules — do not re-litigate these.** `LooseEnd.isOpen`/`openSQLPredicate`
(two spellings by necessity, pinned by `looseEndOpenPredicatesAgree`) · `NodeState.searchable` /
`LooseEndStatus.searchable` (one allow-list, two deliberate applications) ·
`EmbeddableCorpus.corpusNodes`/`corpusLooseEnds` shared with `TranslatableCorpus` ·
`NodeContextResolver.visibleNodeIDs` shared by app/Kit/Spotlight · `groundedScore` ·
`FindMatcher.options` read by `SnippetMaker` · `NextQueries.whatsNext` as the single "what to pick
up" answer · `IdleTranslationPolicy.shouldStart` expressed *through* `shouldContinue` ·
`SmartListKind` ↔ `DeepLink.SmartList` (a compile-checked exhaustive bridge, not a duplication) ·
`normalizeWhitespace`'s five call sites · `PensieveDefaults`/`AppDefaults` key *names* (only the
values drift — that is 1.23) · dormancy *thresholds* (14/3 days — grepped, genuinely not duplicated).

**Looked like duplication, is not.** `PassageChunker` as a third chunker (different rule: overlap) ·
`EventSourceStyle` vs `AppearanceStyle.sourceLabel` (different rules, one input) ·
`Mcp.swift:361`'s `"passage"` vs `Passage.searchKind` (independent contracts) · the three
`batchCharBudget: 2000` defaults · `15 * 60` in `MonitorSnapshot` vs the widget's reload cadence ·
the two `Debouncer(0.15)`s · `NodeContext.displayKey` returning a localization key so app and widget
each localize from their own bundle (inherent to an appex) · `PassageQueries`' unconditional
`minQueryLength` (a correct asymmetry — merely undocumented) · `BriefingView`'s partition
(a category-3 finding, not drift).

**Platform primitives — checked, and the custom path is justified.** The hand-built emoji/symbol
pickers (no public API gives an app an inline picker) · the recursive `NSStatusBarButton` hunt ·
`MenuBarView`'s `Menu` + `SettingsLink` footer (already the first-party route) ·
`.searchScopes` vs the hand-rolled segmented Picker · `AdvancedSettingsTab`'s 5 s poll (`.task`
cancels on disappear) · per-call `LanguageModelSession` and `GenerationSchema` construction ·
`ClaudeCLIProvider`'s three-thread pipe drain + `DispatchGroup` (correct — no deadlock).

**Traced expecting a bug; found none.** `LooseEndRow`'s cancelled load leaving `loading == true` ·
`refresh()` reentrancy and stale overwrite (fully synchronous on the main actor) · `NodeFindState`
not being `@MainActor` · `SyncLog` append/trim racing (single writer) · a capture landing in the old
spool during relocation recovery · `CorpusSampler.select`'s divide-by-zero · `ModelProviderFactory`'s
`apiKey!` (guarded) · `makeDefaultLLMProvider`'s `cloudConfig!` (safe) · `firstJSONArray`'s
escape/string state machine · malformed/partial `.jsonl` last lines · fenced-code and orphan-tag
handling in `TranscriptMarkup` · the widget reading `PensieveDefaults.shared()` from its sandbox ·
`nonisolated(unsafe) static let sharedDefaults` (immutable) · both `@unchecked Sendable` conformances
· 34 sites of `#expect(x != nil)` (every one is a real guard) · 11 files of hardcoded `2026-06-30`
transcript timestamps (no recency window keys off them).

**Cold paths, not micro-optimized:** `fetchOne` + `update` doubling in the write verbs (11 sites) ·
per-id update loops in `setSubtreeState`/`resurface`/`delete` · `ProvenanceLoader.store`'s O(n log n)
eviction (cacheLimit 200) · `NodeFindDocument.units` rebuilding per access ·
`ExtractionRunner.run()`'s full `cc.session` fetch per cycle · re-opening the canonical store per MCP
call (a short-lived request, correctly scoped) · `SourceScanner.walk`'s unbounded recursion
(user-invoked).

**Out of scope by rule, as instructed:** anything SwiftLint catches, `.swiftlint.yml`'s decisions,
file-length cap findings as such, comment density and formatting · re-adding vector/embedding
retrieval (4.2/4.3 concern *residue naming*, not the engine) · unit tests for the app target
(3.5–3.8 are phrased as "move it to PensieveKit") · Python or non-Swift tooling · speculative
flexibility or pluggability · deleting pre-existing dead code (listed below, not recommended).

**Documentation nit worth one line:** `CLAUDE.md`'s layout section says `Sources/PensieveCLI/`; the
directory is `Sources/pensieve/` (the *target* is `PensieveCLI`). Noted, not fixed.

### Dead code observed (a list, not a recommendation)

`Query/PassageProvenance.window(session:passage:event:radius:)` (`:42-50`) — **zero** callers,
including tests · `Query/NodeFindDocument.text(for:)` (`:145-147`) — tests only ·
`Query/MonitorSnapshot.gather(canonicalURL:spoolURL:now:activeWithin:)` (`:31-52`) — tests only ·
`Query/LooseEndCommands.corpus` (`:92-96`) — tests only · `SmartLists.compute`'s `dormantAfterDays` /
`activeWithinDays` parameters — never passed a non-default value · `Eval/Judge.labelGrounding`,
`Eval/Agreement.rate`, `CellSample.estInput/OutputTokens`, `JudgeVerdict.dimensionScores`, and the
unreachable `judgeAgreement` report branch (the whole calibration loop, 2.24) ·
`Intelligence/SalienceClassifier` and its provider method (deliberately unwired) ·
`LLM/FoundationModelsProbe.roundTrip` · `Intelligence/SummaryBuilder.assembleFacts` ·
`Translation/TranslationStore.pruneKeeping` (and note 1.38's field-agnostic trap if it is ever
wired) · `Log.semantic` · a `semantic-index.sqlite` expectation still in the tests · the legacy
`DaemonInstaller` path.

---

## 5. Coverage and confidence

Ten auditors; every finding above was reached by opening the file, not by grepping. Per-area
"category empty" results, which are load-bearing negatives: **category 4** empty for
Ingest/Capture/Transcript/Discovery/Model and thin everywhere; **category 6** empty for `Query/`
(30 files, 95-line average) and for Search/Eval; **category 3** empty for Search/Eval and for the
app views; **category 2** empty for the app views beyond one unstructured `Task`, and no Swift 6
strict-concurrency hole or actor-isolation mistake found anywhere in Ingest/Capture.

Two auditors independently reached 1.1, 1.3 and 1.6 (1.6 by four); those are the
highest-confidence findings in the document. Two claims are explicitly marked *likely* rather than
*certain* — 2.5 (the hang is reasoned from `FoundationModelsProvider` having no cap, not observed)
and 2.7 (the rule violation is certain; the loop firing today is inferred). Nothing in this document
is dressed up beyond its evidence.

Mutation testing ran in a disposable git worktree; `git status` there was verified clean after every
revert and after a final unmutated full-suite run. **No file under `Sources/` or `Tests/` in this
checkout was modified by this audit.**
