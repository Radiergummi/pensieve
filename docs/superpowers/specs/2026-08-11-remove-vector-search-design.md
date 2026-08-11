# Remove the vector search path — design

**Status:** approved in conversation 2026-08-11, plan not yet written.
**Predecessors:** `2026-07-18-semantic-vector-recall-design.md` (built it),
`2026-07-28-retrieval-eval-harness-design.md` (measured it, replaced it).

## Why

The vector engine lost on measurement and now costs more than it returns.

The retrieval branch (merged 2026-08-11) established that mean-pooled `NLContextualEmbedding` **is not a
sentence-similarity encoder for this corpus**: gibberish scored 0.880 cosine against a perfect match's
0.936, so the `0.25` floor never rejected anything. FTS5/BM25 replaced it (P@1 **0.395** vs **0.255**,
n=1500), and `hybridRRF` measured worse than BM25 alone. The vector path was kept as a default-off
"experimental second engine" — transitional scaffolding from a time when it was the incumbent and BM25 the
challenger. That framing expired when the gate concluded; nobody re-asked whether the scaffolding should
come down.

Three things force the question now:

1. **Default-off did not mean off.** Semantic search shipped default-**ON** in July, so this machine had
   `app.semanticSearch = 1` persisted, and the flip only changed the *unset* default. Live on 2026-08-11,
   `pensieve mcp search "focus filter spotlight"` returned 4 items: the correct BM25 hit, then **three
   vector rows** including two unrelated projects at 0.886 / 0.878. The noise the branch existed to stop
   feeding Claude was still being fed. Turning the key off dropped 4 items to 1.
2. **A disabled feature still had side effects.** Even off, materializing the lazy `semanticStore` created
   its SQLite file and loaded the NaturalLanguage model asset on every launch (fixed in `b36f745`). Dead
   code is not inert when it is still wired into a launch path.
3. **Two engines is a standing tax on grounding.** The retrieval branch had to extract a shared
   `SearchHitResolver` *because* the two engines' canonical re-check had drifted. Every future corpus or
   grounding change pays that cost twice.

A user-facing toggle whose ON state is a known, measured defect is not a choice offered to the user; it is
a trap. It also violates this project's own rule — *no "flexibility" or "configurability" that wasn't
requested*. A search-engine switch was never requested.

## What this is not

Not a reversal of the sqlite-vec integration's *findings*, and not a claim that vectors are wrong for
Pensieve forever. The finding was specifically that **this encoder** cannot discriminate on **this corpus**.
The record of how to do it lives in the predecessor spec, the measurements directory, and git history —
which is what makes this recoverable. Keeping compiled, shipped, user-reachable code is not a form of
documentation.

## Decisions

Settled in conversation before this spec was written:

| Decision | Choice | Consequence |
|---|---|---|
| How far | **Full removal**, including the vendored `sqlite-vec` C target | No dead dependency compiled into every build; a future encoder redoes the (documented) integration |
| Retired on-disk files | **Delete by hand, no cleanup code** | Done 2026-08-11: `semantic-index.sqlite` + the orphaned `text-index.sqlite`, ~11 MB. No file-deletion code in the launch path for a one-time problem |
| MCP `engine` field | **Drop it** | Breaking change to the documented tool contract, accepted: with one engine the field carries no information |

## Scope

### Delete

**Kit:**
- `Sources/PensieveKit/Semantic/NLContextualEmbedder.swift`
- `Sources/PensieveKit/Semantic/TextEmbedder.swift` (the protocol seam)
- `Sources/PensieveKit/Semantic/SemanticIndexer.swift`
- `Sources/PensieveKit/Semantic/SemanticIndexStore.swift`
- `Sources/PensieveKit/Query/SemanticQueries.swift` (incl. `SemanticSearchScope` and the `floor` concept)
- `PensieveDefaults.semanticSearchKey` + `semanticSearchEnabled`
- `PensievePaths.semanticIndexURL`
- `SyncRunner.semanticIndexer` (parameter, property, call)

**Vendored dependency:**
- `Sources/CSQLiteVec/` (`sqlite-vec.c`, `shim.c`, `include/`)
- its `Package.swift` target + every `dependencies:` reference
- the GRDB `prepareDatabase` registration hook, which existed only for `vec0`

**App:**
- `AppModel.embedder`, `AppModel.semanticStore`, `AppModel.semanticHits`
- the semantic branch of `AppModel+Search.syncSearchIndexes`, and the semantic half of `runSearch`
- the `ContentListView` "Related (experimental)" section + `semanticHits` in the empty-state condition
- `AppDefaults.semanticSearchEnabled`
- the Settings ▸ Intelligence toggle + its explanatory copy
- three String Catalog entries (en + de): `Semantic search (experimental)`, its long description, and
  `Related (experimental)`

**MCP:**
- the `PensieveDefaults.semanticSearchEnabled()` branch in `handleSearch`
- the cached `static let semanticStore` / `semanticEmbedder`
- `SearchItem.engine` and every write of it

**Tests:** `SemanticIndexerTests`, `SemanticIndexStoreTests`, `SemanticQueriesTests`, `TextEmbedderTests`,
`SQLiteVecSpikeTests`, and `Support/{NilEmbedder,PoisonEmbedder,StubEmbedder}.swift`.

### Keep, and move

`Sources/PensieveKit/Semantic/EmbeddableItem.swift` **must survive** — it holds `EmbeddableItem` and
`EmbeddableCorpus.gather`, which is the corpus **BM25 depends on**, including the P1 hygiene rules. With the
last vector file gone, `Semantic/` is the wrong home: move it to `Sources/PensieveKit/Search/` and delete
the directory.

Two members need a fresh justification once nothing embeds:

- `EmbeddableItem.contentHash` — documented as "hashes `text` ONLY so adding path indexing does not
  invalidate every embedding". No embeddings remain, but `SearchIndexer.corpusHash` still folds it in, so it
  stays with an updated comment.
- The `files`-excluded-from-`contentHash` rule loses its stated reason for the same reason. Behaviour is
  unchanged — `corpusHash` covers `files` separately — but the comment must stop citing re-embedding.

### Explicitly out of scope

- **P3, the paraphrase harness.** Unaffected. Verified during design: all four probes in
  `docs/superpowers/measurements/2026-07-28-retrieval-recall/` carry their **own** ~25-line embedder
  (`import NaturalLanguage` → `NLContextualEmbedding(script: .latin)` → mean-pool → cosine) and import no
  PensieveKit vector type. P3 keeps `vector` and `hybridRRF` as measurable strategies with its harness
  owning the embedder — which is the correct home for a research dependency.
- BM25, the corpus, hygiene, grounding, Focus scoping, archived handling, `index_state`.
- The trust gate. Extraction never used embeddings.

## Consequences worth stating plainly

- **⌘F loses its "Related (experimental)" section.** Corrected during planning: an earlier draft of this
  spec claimed the section was already gone, replaced by the single ranked list. It is not —
  `ContentListView.swift:56` still renders it, gated on the toggle, fed by `AppModel.semanticHits`. So the
  removal must also delete that section, `semanticHits`, and its two references in the empty-state
  condition. With the toggle off there is still no *visible* change, because the section is empty.
- **MCP `search` changes shape**: no `engine` key. `score` remains, documented in the tool description as
  BM25's and not comparable between items.
- **`semantic-index.sqlite` stops existing.** Already deleted by hand; after this, nothing recreates it.
- **The build gets smaller and simpler**: 320 KB of vendored C, a custom module map, and a
  per-connection extension registration all leave. `swift test` no longer compiles a C target.
- **Reversibility**: `git revert` of one branch, or the predecessor spec as a build recipe. A better
  encoder would need re-measurement against P3 anyway, so it would not want this code as-is.

## Testing

Removal is verified mostly by *absence*, which needs care — a deletion can pass a suite by deleting the
tests that would have failed.

- **Test count must drop by exactly the deleted files' tests, and nothing else.** State the expected count
  in the plan and check it, so an accidentally-deleted BM25 test is visible.
- **BM25 behaviour is unchanged**: every `SearchQueriesTests` / `SearchIndexStoreTests` / `FTSQueryTests` /
  `SearchIndexerTests` case passes untouched. Any edit to those files is a red flag to justify, not a fix.
- **`EmbeddableCorpus` hygiene tests pass untouched** after the file moves — the move must be a move, not a
  rewrite.
- **New**: `SyncRunner` still builds the search index with no semantic parameter in existence.
- **New**: the MCP payload has no `engine` key (pin the wire shape, since dropping a field is the breaking
  part of this change).
- **Empirical, on the real store** (the class of bug this session actually produced): launch the app, and
  confirm no `semantic-index.sqlite` appears and no NaturalLanguage asset loads. `b36f745` was caught only
  by deleting the file and relaunching; a reviewer reading the diff would not have seen it.

## Risks

- **Deleting a shared thing by accident.** `EmbeddableItem.swift` sits in the directory being removed and is
  load-bearing for BM25. Mitigation: move it *first*, as its own commit, and see the suite stay green before
  deleting anything.
- **The C target's removal touching the build in non-obvious ways.** `Package.swift`, the modulemap, and the
  GRDB `prepareDatabase` hook are coupled; the canonical pool's *other* configuration (busy timeout) must
  survive. Mitigation: its own commit; `swift build`, `swift test`, and `xcodebuild` all checked.
- **Wire break landing before the app is reinstalled.** The bundled `pensieve mcp` is what Claude Code
  calls, so between merge and reinstall a session could see the old shape. Mitigation: the post-merge
  reinstall step, which is already routine.
- **Losing the reason a surviving comment exists.** `contentHash`'s rationale is written in terms of
  embeddings. Mitigation: it is called out above as a required edit, not left to be noticed.

## Sequencing (for the plan)

Ordered so the suite is green after every step and the riskiest deletion is last:

1. Move `EmbeddableItem.swift` out of `Semantic/`; fix its embedding-era comments. No behaviour change.
2. Remove the app surface: toggle, Settings copy, l10n, `AppModel` members, the sync branch.
3. Remove the MCP surface: the semantic branch, cached statics, and the `engine` field.
4. Remove `SyncRunner.semanticIndexer`.
5. Delete the Kit vector files + `PensieveDefaults`/`PensievePaths` members, and their tests.
6. Delete the `CSQLiteVec` target and its `Package.swift` wiring last, since it is the only step that can
   break the build in an unfamiliar way.
7. Docs: `CLAUDE.md` status entry, `CONTINUE.md`, and the backlog's quarantine entry — which becomes
   "removed", with its measurements and the general lesson (*flipping a default is not a migration*) kept.
