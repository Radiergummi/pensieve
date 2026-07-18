# Semantic / vector recall — design

**Date:** 2026-07-18
**Status:** approved (brainstorm complete); **revised after two independent adversarial Opus reviews**;
ready for plan
**Track:** C (deeper Spotlight / semantic search), sub-project **#2**
**Builds on:** in-app find 1a (`2026-07-10-in-app-find-design.md`), MCP recall tool
(`2026-07-11-mcp-recall-tool-design.md`)

## Context

Pensieve's find surfaces are **lexical only**: in-app ⌘F (`SearchQueries`) and the MCP
`recall`/`project_context` tools all match on exact substrings. The standing loose end —
*"get the remaining text in, and investigate a real vector search so recall doesn't need exact
words"* — was split during the 1a brainstorm into findability (1a/1b) and this: **semantic
recall**, sub-project #2. This spec delivers it.

The driving intent (confirmed at brainstorm): the index is meant to **scale well beyond today's
small grounded corpus** — raw session transcripts and future non-git source types are explicit
future targets. So this is a *proper vector store*, not a brute-force cosine over an in-memory
array. v1 ships a deliberately-bounded corpus but the pipeline is built so more corpora are
**additive**.

## Goal

Find any node, open loose end, or event by *meaning* — a phrase semantically close to captured
text, not necessarily present in it — across both the in-app ⌘F surface and the MCP server, over
one shared PensieveKit kernel, honoring the active Focus filter and the grounded-with-provenance
north star.

## The native landscape (why these choices)

Investigated at brainstorm (July 2026, macOS 26 / Xcode 26):

- **Embedding generation → native.** `NLContextualEmbedding` (NaturalLanguage) is a real on-device,
  BERT-class embedder: private, no external deps, Apple-Silicon. **It is a per-token contextual
  embedder**, not a sentence embedder: `embeddingResult(for:language:)` yields one vector *per
  token* (`enumerateTokenVectors`), each of length `.dimension`. The default `TextEmbedder` therefore
  **mean-pools** the per-token vectors into one sentence vector. Use the **by-script Latin** model so
  mixed EN+DE content (app localized, captured content bilingual) lands in **one** vector space.
  *(There is no single generic "multilingual" model — it's script-scoped; a future corpus in CJK/
  Cyrillic would need additional models and would break the single-space assumption. Flagged because
  transcripts/other sources are the stated future target.)* It loads a model asset on first use
  (async `load()`/`requestAssets`). This is the **first `NaturalLanguage` use** in the codebase;
  available macOS 14+ (within PensieveKit's `.macOS(.v14)` floor).
- **Vector store → there is no first-class native one.** Foundation Models (macOS 26) is
  generation/tool-calling only (no embedding API, no store). Core Spotlight gained semantic search
  but is OS-managed, Spotlight-coupled, not a general top-k index we control with our own filters
  (Focus, active-only, grounding) or reach cross-process from CLI/MCP — that is Track C **1b**'s
  territory, not this.
- **Therefore:** native `NLContextualEmbedding` for the embedder + **`sqlite-vec`** for the store —
  the actual right answer, not a fallback. It lives *inside SQLite*, which every Pensieve process
  already speaks, so the index is **cross-process by construction**, scales, and is controllable.

## Architecture

Five PensieveKit components (all real logic, tested); two thin surfaces.

### 1. `TextEmbedder` protocol + `NLContextualEmbedder`

```
protocol TextEmbedder: Sendable {
  var version: String { get }      // model id + dimension, derived from the loaded model at runtime
  var dimension: Int { get }       // read from NLContextualEmbedding.dimension, NOT hardcoded
  func embed(_ texts: [String]) async -> [[Float]]?   // batch; nil = asset unavailable (best-effort)
}
```

- Default `NLContextualEmbedder` wraps `NLContextualEmbedding` (by-script Latin), async asset load,
  **mean-pools** per-token vectors to one D-vector per string, best-effort (`nil` when the asset
  isn't ready — never throws, never blocks).
- `version` (model id + runtime dimension) drives index invalidation (a model/dimension change ⇒
  full rebuild). **No `EvalTask`** — this is a fixed native asset, not a `pensieve eval`-selectable
  generation model, so the registry↔config test rule doesn't apply.
- Swappable/testable, mirroring the `LLMProvider` pattern. Tests inject a deterministic stub.

### 2. `SemanticIndexStore` — a separate `semantic-index.sqlite` (+ `sqlite-vec`)

- **Its own db file** in the disposable support dir (`PensievePaths.semanticIndexURL()`), alongside
  `narration-cache.sqlite` — **NOT** the canonical `pensieve.sqlite`. Rationale: embeddings are
  device-local, embedder-version-specific, must **never** CloudKit-sync, and are fully derivable from
  canonical content. Drop-and-rebuild on version change; zero migration risk to the sacred canonical
  store. Best-effort open with delete-and-retry on corruption, exactly like `NarrationCache`.
- Schema (raw SQL, mirroring `NarrationCache`'s non-`@Table` approach):
  - a `sqlite-vec` `vec0` virtual table `embeddings` with the `vector float[D]` column **plus
    filterable metadata columns `node_id TEXT` and `state TEXT`** (so KNN can pre-filter by node
    scope + active-state — see §4), and `item_id TEXT` / `kind TEXT`;
  - a plain `items(item_id TEXT PRIMARY KEY, kind TEXT, node_id TEXT, state TEXT, content_hash TEXT)`
    metadata table for the reconciliation diff;
  - a one-row `meta(embedder_version TEXT, dimension INT)` for whole-index invalidation.
- **Holds ids + hashes + scope only — never a copy of the content.** Cited text is joined back from
  canonical at result time → single source of truth, nothing stale to leak.

### 3. `SemanticIndexer.sync(canonical:index:embedder:)`

Incremental **reconciliation** of the index to the canonical grounded corpus. Reconciliation is
**membership- and metadata-driven, not hash-driven** — `content_hash` gates *only re-embedding*.

- **v1 corpus (grounded records), text per kind:**
  - **node** → `name` + `description`;
  - **open loose end** (passes `LooseEnd.isOpen`, i.e. `status = "open"` AND `label ≠ "noise"`) →
    `text` (+ `quote`);
  - **event** → `git.commit`: `summary`; `cc.session`: `workSummary` **when non-nil**, else **skip**
    (do not embed the terse placeholder `summary` — it pollutes the space; same fallback
    `SummaryBuilder` already makes).
  - All already-modeled, real, individually-citable records with stable UUID `item_id`s.
- **Each sync, per live corpus item:** upsert its metadata (`node_id`, `state`) **unconditionally**,
  and **(re-)embed only when `content_hash` changed or the item is new**. This is what makes a
  strand-birth *repoint* correct: `Ingester.materializeStrand` repoints a loose end's `nodeID` with
  text unchanged, so the hash is unchanged — we update `node_id` in the index **without re-embedding**.
- **Prune (membership-driven):** delete index rows whose item is no longer in the live corpus
  predicate — a loose end that now fails `LooseEnd.isOpen` (closed **or** `label = "noise"` — note
  there is **no** `resolved` status in the model), a node/subtree flipped to `state = "archived"`, a
  deleted row. These transitions leave `content_hash` unchanged, so pruning **must** evaluate the live
  predicate, never the hash. *(Resurrection is free: `resurfaceIfArchived` re-activates on new
  activity; the pruned item re-enters the corpus and re-embeds as new — sound, minor churn.)*
- **Full rebuild** when `meta.embedder_version` ≠ the embedder's `version` (or the file is missing/
  corrupt): drop + re-embed. **Guard concurrent rebuilds** — the app and the daemon can both detect a
  version mismatch on the shared file; use single-writer coordination (or an idempotent rebuild) so
  two overlapping drop-and-rebuilds can't corrupt each other (WAL row-contention alone won't cover it).
- **Event/long text is truncated to the embedder's token window** in v1 (BERT ~512-token ceiling).
  Real chunking is deferred with transcripts (see Non-goals).
- **Triggers (corrected):** the indexer is a reconciliation, so it attaches wherever a process
  advances canonical:
  - **daemon** — in `SyncRunner.run()` **after `ExtractionRunner.run()`** (which is the *only* writer
    of loose ends + `workSummary`, so the daemon produces most embeddable content);
  - **app** — after `AppModel.drain()`/`refresh()` (the app runs **`Ingester.drain()` with no LLM** —
    it never runs extraction, so there is no "after extraction" hook there; it picks up node edits and
    the daemon's canonical writes surfaced via the canonical `ValueObservation`/FSEvents watch).
  On-device compute only; runs *after* the sacred capture path, never inside it.

### 4. `SemanticQueries.search(query:visibleNodeIDs:k:floor:…)`

- Embed the query (best-effort; `nil` ⇒ empty results).
- **KNN must not under-return under the Focus filter.** `visibleNodeIDs` mutes the opposite Focus
  context (`NodeContextResolver.visibleNodeIDs`); a fixed-`k` KNN could return `k` items all in the
  muted context and yield **zero** visible hits though relevant ones sit just past rank `k`. You
  cannot post-filter a `vec0` KNN the way `SearchQueries` post-filters a full table scan. So:
  **filter `state = "active"` inside the KNN** (metadata column), **over-fetch `k' ≫ k`**, then apply
  `visibleNodeIDs` + the cosine **floor** + the `k` cap in Swift, with an expand-and-retry if
  under-filled. *(Filtering `node_id` in-KNN against a large dynamic visible set is impractical, so
  node-scope stays a post-filter over the over-fetched set; `state` — small cardinality — is the
  in-KNN pre-filter.)*
- **The result join re-applies the live corpus predicate** — drop any hit whose canonical row is
  missing **or** now fails `LooseEnd.isOpen` / `state == "active"` (a between-syncs stale index row
  can still KNN-match). This is the last line of grounding defense.
- Return ranked `SemanticHit`s carrying the same provenance the lexical hits carry (node name,
  loose-end quote, event ref) **plus** a similarity score and the item kind.

### 5. Shared consumption — one kernel, two thin surfaces

- **In-app ⌘F.** `AppModel` runs `SemanticQueries` after `SearchQueries`. `ContentListView` keeps
  1a's exact groups (Projects / Loose ends) **unchanged** and adds a third **"Related"** group
  beneath them: semantic-only hits above the floor, **deduped against the exact hit ids**, rendered
  only when non-empty. Reuses `SnippetText`/`NodeBadge`/`LooseEndRow`. *(Note: `SnippetMaker.make`
  returns a no-match snippet — a plain head window, nothing bolded — when the query substring is
  absent, which is always true for a semantic hit. That's the intended affordance for "Related" rows,
  not a bug.)*
- **MCP.** A single unified **`search`** tool (see below) over the same kernel.

## The MCP `search` tool (unified, not semantic-only)

Rather than ship a semantic-only tool now and a keyword tool later, the MCP surface is **one**
`search(query, k?, context?)` tool returning the **same exact+semantic blend ⌘F shows** — exact
hits first, related (semantic) below, all **cited**. Claude Code gets one obvious "find across my
work" tool instead of three overlapping ones; this **subsumes the deferred keyword-search sibling**
from the recall-tool spec. Opens both dbs cross-process (the `MCP`/`swift-sdk` dep is already
`PensieveCLI`-only; a fourth tool alongside `project_context`/`whats_next`/`recall` in `Mcp.swift`
over a shared kernel is exactly how the current tools are built). Complements the existing `recall`
(loose-end → transcript window) and `project_context` tools.

## Grounding (north star intact)

Semantic is **retrieval-only**. Every surfaced hit is a real node / loose end / event with its
verbatim cited text — the vector merely ranks. **No opaque clusters, no synthesized "why it
matched," no fabrication.** The query join dropping stale/absent/now-excluded rows (§4) is the
enforcement point. On-device embeddings only, exactly like extraction; **cloud is never used here**
(the cloud provider serves narration only). The trust gate is untouched.

## Settings

A **"Semantic search" toggle** in Settings ▸ Intelligence, **default ON**. It gates the indexer
(background embedding compute + first-run model-asset download) and the query surfaces. Off ⇒ no
indexing, no "Related" section, MCP `search` returns exact-only. Stored in the shared
`PensieveDefaults` suite (`me.mazetti.pensieve`) and read cross-process by the daemon before it runs
the indexer — the established `llmProvider` pattern. *(Cross-process propagation is eventually
consistent — a brief cfprefsd-cache window after a change — inherited from the shipped
provider-selection read; not instantaneous.)*

## Degradation (best-effort throughout)

- Embedder asset unavailable → indexer no-ops; queries return no semantic hits; ⌘F still shows
  exact; MCP `search` returns exact-only. No crash, no block.
- `sqlite-vec` unavailable → semantic features disable gracefully; exact ⌘F and the rest of the
  app/CLI/daemon unaffected.
- Index corrupt / `embedder_version` mismatch → drop + rebuild (guarded, §3).
- Nothing here can block capture or ingest.

## Testing

- **Kit unit tests with a deterministic stub embedder** (no dependency on NL assets): cosine
  ordering, the floor, the **over-fetch/expand-retry** so a Focus-muted top-`k` still returns visible
  hits, `state`-in-KNN + `visibleNodeIDs`/active post-filter scoping, exact-vs-related dedup, the
  **join re-applying the corpus predicate** (a stale index row for a now-noise/archived item is
  dropped), and **incremental sync** — add / change-by-hash / repoint-updates-`node_id`-without-
  re-embed / noise-label-prunes / archive-prunes / resurface-re-embeds / delete /
  version-bump-full-rebuild.
- **One guarded `sqlite-vec` integration test in the SwiftPM test target** (register the C target's
  init + insert + `vec0` KNN) — proves the store where `swift test` runs.
- App target stays test-free (per convention): `xcodebuild` build + non-blocking smoke launch.

## Non-goals (v1)

- **Transcript-passage chunking** — the next increment. v1 defines a typed **`EmbeddableItem`
  producer** abstraction (source-kind + text + citation handle) so transcripts and future source
  types are additive, not a rearchitecture.
- CloudKit sync of the index (never — device-local by design).
- Cloud / API embeddings (on-device only; trust gate).
- LLM re-ranking, synthesized answers, or theme clustering.
- BM25 / hybrid lexical-fusion scoring (exact substring already owns lexical recall).
- Spotlight/OS-level semantic indexing (that is Track C 1b).

## De-risk order (the plan must front-load this)

1. **`sqlite-vec` as a vendored SwiftPM C target in `Package.swift`, registered via
   `sqlite3_auto_extension` (static; no runtime dylib load, no `enable_load_extension`, no dylib to
   sign).** PensieveKit + its **SwiftPM test target** are the primary and first-to-hit linkage site;
   the three product targets (app / `PensieveCLI` / `PensieveSyncAgent`) inherit it transitively
   through the `PensieveKit` product — one mechanism, not three. *(Explicitly rule out the prebuilt-
   dylib route: it would be three embedding+signing problems and would leave `swift test` unable to
   load the extension — unlike the xcodebuild-only MarkdownUI dep, sqlite-vec must be in
   `Package.swift`.)* **Spike (step 0):** prove the C target compiles and `vec0` KNN works under
   `swift test`. Lower-risk than the earlier "runtime-load in three targets" framing, but still first
   — if it fights us, fall back to an app-owned index (daemon writes canonical only, the app indexes).
2. **First-run `NLContextualEmbedding` asset download in the launchd background agent.** Embedding
   *inference* in the agent is already de-risked — the `PensieveSyncAgent` already runs FoundationModels
   on-device via `SyncRunner`. The open question is the async **asset download** (network) on first
   run in a headless context; on failure it's best-effort `nil` and degrades to the app-only indexer.
3. Multilingual/by-script embedder quality validated on real EN+DE captured content.

## Open items for the plan

- Exact cosine **floor** value (start conservative; tune in ⌘F).
- `k` caps and the **over-fetch factor `k'`** for ⌘F "Related" and MCP `search`.
- The `EmbeddableItem` producer protocol shape (kept minimal in v1, extensible for transcripts).
- Single-writer/idempotent-rebuild coordination mechanism for the concurrent-rebuild guard (§3).
