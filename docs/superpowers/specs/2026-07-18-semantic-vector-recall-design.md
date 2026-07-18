# Semantic / vector recall — design

**Date:** 2026-07-18
**Status:** approved (brainstorm complete), ready for plan
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

Find any node, open loose end, or event by *meaning* — a phrase that is semantically close to
captured text, not necessarily present in it — across both the in-app ⌘F surface and the MCP
server, over one shared PensieveKit kernel, honoring the active Focus filter and the
grounded-with-provenance north star.

## The native landscape (why these choices)

Investigated at brainstorm (July 2026, macOS 26 / Xcode 26):

- **Embedding generation → native.** `NLContextualEmbedding` (NaturalLanguage) is a real
  on-device, BERT-class **sentence** embedder: private, no external deps, Apple-Silicon. It loads
  a model asset on first use (async request) and emits a fixed-dimension vector per string. Use
  the **multilingual / by-script** model so mixed EN+DE content (the app is localized; captured
  content is bilingual) lands in **one** vector space.
- **Vector store → there is no first-class native one.** Foundation Models (macOS 26) is
  generation/tool-calling only (no embedding API, no store). Core Spotlight gained semantic search
  but is OS-managed, Spotlight-coupled, not a general top-k index we control with our own filters
  (Focus, active-only, grounding) or reach cross-process from CLI/MCP — that is Track C **1b**'s
  territory, not this. The ecosystem builds the store itself.
- **Therefore:** native `NLContextualEmbedding` for the embedder + **`sqlite-vec`** for the store.
  Not a fallback — the actual right answer. It lives *inside SQLite*, which every Pensieve process
  already speaks, so the index is **cross-process by construction** (app + CLI + daemon + MCP),
  scales, and is fully controllable.

## Architecture

Five PensieveKit components (all real logic, tested); two thin surfaces.

### 1. `TextEmbedder` protocol + `NLContextualEmbedder`

```
protocol TextEmbedder: Sendable {
  var version: String { get }                 // model id + dimension, e.g. "nl-multilingual-v1:512"
  var dimension: Int { get }
  func embed(_ texts: [String]) async -> [[Float]]?   // batch; nil = asset unavailable (best-effort)
}
```

- Default `NLContextualEmbedder` wraps `NLContextualEmbedding` (multilingual by script), async
  asset load, best-effort (`nil` when the asset isn't ready — never throws, never blocks).
- `version` drives index invalidation (a model/dimension change ⇒ full rebuild).
- Swappable/testable, mirroring the `LLMProvider` pattern. Tests inject a deterministic stub.

### 2. `SemanticIndexStore` — a separate `semantic-index.sqlite` (+ `sqlite-vec`)

- **Its own db file** in the disposable support dir, alongside `narration-cache.sqlite` — **NOT**
  the canonical `pensieve.sqlite`. Rationale: embeddings are device-local, embedder-version-
  specific, must **never** CloudKit-sync, and are fully derivable from canonical content.
  Drop-and-rebuild on version change; zero migration risk to the sacred canonical store.
- Schema:
  - a `sqlite-vec` `vec0` virtual table `embeddings(item_id TEXT, kind TEXT, vector float[D])`;
  - a plain `items(item_id TEXT PRIMARY KEY, kind TEXT, node_id TEXT, content_hash TEXT,
    embedder_version TEXT)` metadata table;
  - a `meta(embedder_version TEXT, dimension INT)` one-row table for whole-index invalidation.
- **Holds ids + hashes only — never a copy of the content.** The cited text is joined back from
  canonical at result time → single source of truth, and no stale/duplicated content to leak.

### 3. `SemanticIndexer.sync(canonical:index:embedder:)`

Incremental reconciliation of the index to the canonical grounded corpus.

- **v1 corpus (grounded records):** nodes (name + description), **open** loose ends (text +
  quote), and event summaries (git-commit summary + session `workSummary`). All already-modeled,
  real, individually-citable records already in canonical.
- Diff by `(item_id, content_hash)`: embed new/changed items, upsert their vectors + metadata;
  prune items no longer in the corpus (closed loose ends, deleted nodes, archived subtrees).
- **`content_hash` keys the embedding; `node_id` is separate metadata.** A strand-birth *repoint*
  of a loose end to a new node (text unchanged) updates `node_id` **without re-embedding**.
- **Full rebuild** when `meta.embedder_version` ≠ the embedder's `version` (or the file is
  missing/corrupt): drop + re-embed the whole corpus.
- **Event text is truncated to the embedder's token window** in v1 (BERT ~512-token ceiling).
  Real chunking is deferred with transcripts (see Non-goals).
- **Runs right after extraction in BOTH** the app's background refresh **and** the daemon's
  `SyncRunner` → the index stays fresh whether the app or the headless daemon did the ingest.
  On-device compute only; runs *after* the sacred capture path, never inside it.

### 4. `SemanticQueries.search(query:visibleNodeIDs:k:floor:…)`

- Embed the query (best-effort; `nil` ⇒ empty results).
- `sqlite-vec` KNN over `embeddings`; filter by `visibleNodeIDs` (Focus, by construction) +
  **active-state only** + a **cosine floor** (semantic KNN always returns *something*; the floor
  discards weak matches — start conservative, tune by eyeballing ⌘F).
- Join canonical for the cited content; return ranked `SemanticHit`s carrying the same provenance
  the lexical hits carry (node name, loose-end quote, event ref) **plus** a similarity score and
  the item kind.

### 5. Shared consumption — one kernel, two thin surfaces

- **In-app ⌘F.** `AppModel` runs `SemanticQueries` after the existing `SearchQueries`.
  `ContentListView` keeps 1a's exact groups (Projects / Loose ends) **unchanged** and adds a third
  **"Related"** group beneath them: semantic-only hits above the floor, **deduped against the exact
  hit ids**. Rendered only when non-empty. Reuses `SnippetText`/`NodeBadge`/`LooseEndRow`.
- **MCP.** A single unified **`search`** tool (see below) over the same kernel.

## The MCP `search` tool (unified, not semantic-only)

Rather than ship a semantic-only tool now and a keyword tool later, the MCP surface is **one**
`search(query, k?, context?)` tool that returns the **same exact+semantic blend ⌘F shows** —
exact hits first, related (semantic) below, all **cited**. Claude Code gets one obvious
"find across my work" tool instead of three overlapping ones; this **subsumes the deferred
keyword-search sibling** from the recall-tool spec. Opens both dbs cross-process. Complements the
existing `recall` (loose-end → transcript window) and `project_context` tools.

## Grounding (north star intact)

Semantic is **retrieval-only**. Every surfaced hit is a real node / loose end / event with its
verbatim cited text — the vector merely ranks. **No opaque clusters, no synthesized "why it
matched," no fabrication.** On-device embeddings only, exactly like extraction; **cloud is never
used here** (the cloud provider serves narration only). The trust gate is untouched.

## Settings

A **"Semantic search" toggle** in Settings ▸ Intelligence, **default ON**. It gates the indexer
(background embedding compute + first-run model-asset download) and the query surfaces. Off ⇒ no
indexing, no "Related" section, MCP `search` returns exact-only. Honors the whole-system pattern
(shared UserDefaults, read cross-process by the daemon) so the daemon's indexer respects it too.

## Degradation (best-effort throughout)

- Embedder asset unavailable → indexer no-ops; queries return no semantic hits; ⌘F still shows
  exact; MCP `search` returns exact-only. No crash, no block.
- `sqlite-vec` fails to load → semantic features disable gracefully; exact ⌘F and the rest of the
  app/CLI/daemon are unaffected.
- Index corrupt / `embedder_version` mismatch → drop + rebuild.
- Nothing here can block capture or ingest.

## Testing

- **Kit unit tests with a deterministic stub embedder** (no dependency on NL assets): cosine
  ordering, the floor, `visibleNodeIDs`/active-only scoping, exact-vs-related dedup, and
  **incremental sync** — add / change-by-hash / repoint-updates-node_id-without-re-embed / delete /
  version-bump-triggers-full-rebuild.
- **One guarded `sqlite-vec` integration test** (load extension + insert + KNN) — proves the store
  in the SwiftPM test target.
- App target stays test-free (per convention): `xcodebuild` build + non-blocking smoke launch.
- **New LLM-adjacent task:** if the embedder needs a default-model choice, register an `EvalTask`
  per the repo rule; otherwise the model id is a fixed native constant (documented) — decide at
  plan time.

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

1. **`sqlite-vec` load + static-link/bundle across all three targets** — the app (Xcode), the
   `PensieveCLI` tool target, and the `PensieveSyncAgent` helper — proving *load + insert + KNN* in
   each. **A time-boxed spike is step 0 of the plan.** This is the one risk that can invalidate the
   store choice; if it fights us, fall back to an app-owned index (daemon writes canonical only,
   the app indexes) — but decide on day one. Everything below is contingent on this passing.
2. `NLContextualEmbedding` availability + asset-loading in the **launchd background** context (the
   daemon must be able to embed, or indexing degrades to app-only).
3. Multilingual embedder choice validated on real EN+DE captured content.

## Open items for the plan

- Exact cosine **floor** value (start conservative; tune in ⌘F).
- `k` caps for ⌘F "Related" and for MCP `search`.
- Whether the embedder registers an `EvalTask` (see Testing).
- The `EmbeddableItem` producer protocol shape (kept minimal in v1, extensible for transcripts).
