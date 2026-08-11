# Remove the Vector Search Path — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Delete the vector/semantic search engine — Swift code, vendored `sqlite-vec` C target, user-facing toggle, and all wiring — leaving FTS5/BM25 as the only retrieval path.

**Architecture:** A pure deletion, ordered so the test suite is green after every task and the riskiest removal (the C target, which is the only step that can break the build in an unfamiliar way) is last. The one shared file living inside the doomed directory — `EmbeddableItem.swift`, which holds the corpus BM25 depends on — is moved out **first**, as its own commit, so its safety is proven before anything is deleted.

**Tech Stack:** Swift 6, SwiftPM (PensieveKit + tests), XcodeGen/xcodebuild (app + CLI targets), GRDB/SQLiteData, FTS5.

## Global Constraints

- **Spec:** `docs/superpowers/specs/2026-08-11-remove-vector-search-design.md`. Read it before Task 1.
- **The trust gate is untouched.** Extraction never used embeddings. No task may edit any file under `Sources/PensieveKit/Intelligence/` or `Sources/PensieveKit/Transcript/`.
- **BM25 behaviour must not change.** `SearchQueriesTests`, `SearchIndexStoreTests`, `FTSQueryTests`, `SearchIndexerTests` and `EmbeddableCorpusHygieneTests` pass **untouched**. Editing any of those files is a red flag to justify to the reviewer, never a way to make a task pass.
- **A removal can pass the suite by deleting the tests that would have failed.** Every task states its expected test count. Check it. If a count is off by even one, stop and find out why before committing.
- **Test count arithmetic:** measure the baseline in Task 0. **39 tests are deleted** (Task 4: 1, Task 5: 38) and **1 is added** (Task 4). Task 3 adds no `@Test` — `Sources/pensieve/` has no test target, so its verification is a runtime assertion against the real store. **Final count = `BASELINE − 38`.** Per-task expectations: Tasks 1–4 leave the count at `BASELINE`; Tasks 5 and 6 leave it at `BASELINE − 38`.
- **`swift test` is Kit-only.** `Sources/PensieveApp/` and `Sources/pensieve/` are Xcode-only targets, so Tasks 2 and 3 cannot be verified by the suite — they need `xcodebuild`. Build command:
  `xcodegen generate && xcodebuild -project Pensieve.xcodeproj -scheme Pensieve -configuration Debug -derivedDataPath ./.build-xcode build`
- **SwiftLint is enforced `--strict`.** Run `swiftlint lint --strict --quiet` before every commit; it must print nothing.
- **Commit messages:** never backticks inside `git commit -m` (the shell executes them) — use `git commit -F -` with a quoted heredoc. Keep the `Co-Authored-By:` and `Claude-Session:` trailers.
- **Do NOT set `PENSIEVE_DB` / `PENSIEVE_CAPTURE_DB` to any real path.** Tests use temp files.
- **Discard `Package.resolved` churn** after any `xcodebuild` (`git checkout -- Package.resolved`) — MarkdownUI is an xcodebuild-only dependency and rewrites it.
- The working tree may contain **the user's own uncommitted edits** (`TranscriptMessageView.swift`, `IngesterDropTests.swift` at time of writing). **Never `git add -A` or `git add .`** — stage only the exact paths each task names.

---

## File Structure

**Deleted outright:**

| Path | Why it exists today |
|---|---|
| `Sources/PensieveKit/Semantic/NLContextualEmbedder.swift` | the encoder that lost on measurement |
| `Sources/PensieveKit/Semantic/TextEmbedder.swift` | protocol seam for swapping encoders |
| `Sources/PensieveKit/Semantic/SemanticIndexer.swift` | membership-driven vector index reconciliation |
| `Sources/PensieveKit/Semantic/SemanticIndexStore.swift` | `vec0` store + the sqlite-vec registration hook |
| `Sources/PensieveKit/Query/SemanticQueries.swift` | KNN + `SemanticSearchScope` + the inert `floor` |
| `Sources/CSQLiteVec/` (dir) | vendored `sqlite-vec.c`, shim, modulemap |
| `Tests/PensieveKitTests/SemanticIndexerTests.swift` | 15 tests |
| `Tests/PensieveKitTests/SemanticIndexStoreTests.swift` | 8 tests |
| `Tests/PensieveKitTests/SemanticQueriesTests.swift` | 10 tests |
| `Tests/PensieveKitTests/TextEmbedderTests.swift` | 4 tests |
| `Tests/PensieveKitTests/SQLiteVecSpikeTests.swift` | 1 test (the GO/NO-GO spike) |
| `Tests/PensieveKitTests/Support/{NilEmbedder,PoisonEmbedder,StubEmbedder}.swift` | test doubles used only by the above |

**Moved:** `Sources/PensieveKit/Semantic/EmbeddableItem.swift` → `Sources/PensieveKit/Search/EmbeddableItem.swift`. Holds `EmbeddableItem` + `EmbeddableCorpus.gather` — **the corpus BM25 reads**, including P1 hygiene. After the move, `Semantic/` is empty and is deleted.

**Modified:** `SyncRunner.swift`, `PensieveDefaults.swift`, `PensievePaths.swift`, `SearchHit.swift`, `Package.swift`, `Mcp.swift`, `AppModel.swift`, `AppModel+Search.swift`, `ContentListView.swift`, `AppDefaults.swift`, `Settings/IntelligenceSettingsTab.swift`, `Localizable.xcstrings`, `SyncRunnerTests.swift`, plus docs.

---

## Task 0: Baseline

**Files:** none.

- [ ] **Step 1: Record the starting state**

```bash
git rev-parse --short HEAD
./scripts/test.sh 2>&1 | grep 'Test run with'
swiftlint lint --strict --quiet && echo "LINT CLEAN"
```

Write the test number down as `BASELINE`. At time of writing it was **577** (which included one uncommitted local test); at commit `92d76c6` with a clean tree it is **576**. Use what *you* measure — every later count is `BASELINE`-relative.

- [ ] **Step 2: Confirm the vector path is genuinely unreferenced by the retained corpus**

```bash
grep -rn 'contentHash' Sources/PensieveKit/ | grep -v 'Semantic/EmbeddableItem.swift'
```

Expected: exactly one hit, in `Search/SearchIndexer.swift` (`corpusHash` folds `item.contentHash`). This is why `contentHash` survives the removal.

---

## Task 1: Move `EmbeddableItem.swift` out of `Semantic/`

The file BM25 depends on currently lives in the directory being deleted. Move it first and prove the suite stays green, so no later deletion can take it by accident.

**Files:**
- Move: `Sources/PensieveKit/Semantic/EmbeddableItem.swift` → `Sources/PensieveKit/Search/EmbeddableItem.swift`
- Modify: the moved file's doc comments only (three of them cite embeddings)

**Interfaces:**
- Consumes: nothing.
- Produces: `EmbeddableItem` (`itemID`/`kind`/`nodeID`/`state`/`text`/`files`/`contentHash`) and `EmbeddableCorpus.gather(_:) throws -> [EmbeddableItem]`, at their new path. Public API is **unchanged** — same module, so no import changes anywhere.

- [ ] **Step 1: Move the file with git, so history follows it**

```bash
git mv Sources/PensieveKit/Semantic/EmbeddableItem.swift Sources/PensieveKit/Search/EmbeddableItem.swift
```

- [ ] **Step 2: Run the suite — a pure move must change nothing**

Run: `./scripts/test.sh 2>&1 | grep 'Test run with'`
Expected: PASS, exactly `BASELINE` tests. Same module means no `import` edits; if anything fails, the move was not a move.

- [ ] **Step 3: Fix the three doc comments that explain themselves in terms of embeddings**

In the moved file, replace the `files` property comment:

```swift
  /// Newline-joined changed-file paths. Events only; "" everywhere else. Indexed into the FTS5
  /// search index's SEPARATE `document_files` table, never beside the text: FTS5 normalises `bm25()`
  /// by the row's TOTAL token count across all columns, so paths sharing a row with text would
  /// discount every commit's text matches. Measured — see the spec's verification gate.
  public let files: String
```

Replace the `contentHash` comment:

```swift
  /// Stable across processes/runs (String.hashValue is per-process salted — do NOT use it here).
  /// Hashes `text` ONLY. `files` is excluded so that a change to path indexing does not invalidate
  /// every item's content hash; `SearchIndexer.corpusHash` folds `files` in separately, so a
  /// paths-only change is still noticed. (Historically this split existed to avoid re-embedding on
  /// the retired vector path; the reason is now purely about what the FTS5 rebuild guard tracks.)
  public var contentHash: String {
```

Replace the `EmbeddableCorpus` type comment's first line:

```swift
/// v1 producer of the search corpus: active AND archived nodes + their open loose ends +
```

- [ ] **Step 4: Check the retired vocabulary is gone from this file**

```bash
grep -in 'embed\|semantic\|vector' Sources/PensieveKit/Search/EmbeddableItem.swift
```

Expected: only the one deliberate parenthetical in the `contentHash` comment, and the word "Embeddable" in the type names themselves (the names stay — renaming the type is out of scope and would churn every call site).

- [ ] **Step 5: Run the suite and lint**

Run: `./scripts/test.sh 2>&1 | grep 'Test run with'` → PASS, `BASELINE` tests.
Run: `swiftlint lint --strict --quiet` → no output.

- [ ] **Step 6: Commit**

```bash
git add Sources/PensieveKit/Search/EmbeddableItem.swift Sources/PensieveKit/Semantic/EmbeddableItem.swift
git commit -F - <<'EOF'
refactor(search): move EmbeddableItem beside the index that reads it

EmbeddableCorpus produces the corpus BM25 searches, but it lived in Semantic/ —
the directory the vector removal deletes. Moving it first, on its own, so the
suite proves it is safe before anything is deleted.

Its three doc comments explained the type in terms of embeddings. The files/text
split is now justified the way it actually earns its keep: FTS5 normalises bm25()
by the row's total token count, so paths cannot share a row with text.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01J7duqNmYpADJ6axVaL3y6G
EOF
```

---

## Task 2: Remove the app surface

**Files:**
- Modify: `Sources/PensieveApp/AppModel.swift` (lines ~113–131)
- Modify: `Sources/PensieveApp/AppModel+Search.swift` (`syncSearchIndexes`, `runSearch`, `clearSearch`)
- Modify: `Sources/PensieveApp/ContentListView.swift` (lines ~55–68)
- Modify: `Sources/PensieveApp/AppDefaults.swift` (lines 27–33)
- Modify: `Sources/PensieveApp/Settings/IntelligenceSettingsTab.swift` (lines 11, 66–73)
- Modify: `Sources/PensieveApp/Localizable.xcstrings` (3 keys)

**Interfaces:**
- Consumes: `EmbeddableItem`/`EmbeddableCorpus` at their Task 1 path (indirectly, via `SearchIndexer`).
- Produces: an `AppModel` with **no** `embedder`, `semanticStore`, or `semanticHits`; `syncSearchIndexes()` unchanged in signature (`func syncSearchIndexes()`), still calling `searchIndexesDidSync(state:)`.

- [ ] **Step 1: Delete the two lazy vars and the hits array in `AppModel.swift`**

Delete `var semanticHits: [SearchHit] = []` (~line 114). Delete these three lines (~128–130):

```swift
  // Built once; NLContextualEmbedder resolves dimension from the loaded asset at init.
  @ObservationIgnored lazy var embedder: NLContextualEmbedder = NLContextualEmbedder()
  @ObservationIgnored lazy var semanticStore = SemanticIndexStore(
    url: PensievePaths.semanticIndexURL(), dimension: embedder.dimension, embedderVersion: embedder.version)
```

Keep `@ObservationIgnored lazy var searchStore = SearchIndexStore(url: PensievePaths.searchIndexURL())`.

- [ ] **Step 2: Simplify `syncSearchIndexes` in `AppModel+Search.swift`**

The whole semantic tuple goes. Replace the body from `let searchStore = self.searchStore` through the closing of the detached task with:

```swift
    let searchStore = self.searchStore
    Task.detached { [weak self] in
      SearchIndexer(store: searchStore).sync(database)
      // Read the state HERE, off the main actor: it is a SQL read against the pool whose 5 s busy
      // timeout is the whole reason this work is detached.
      let state = searchStore.state()
      await MainActor.run { self?.searchIndexesDidSync(state: state) }
    }
```

Also delete the now-stale sentence "Both indexes are hash-guarded" from the method's doc comment, replacing it with "The index is hash-guarded, so an unchanged corpus costs one gather and one hash." The paragraph explaining *why* the work is detached stays — it is about corpus size and the busy timeout, not about the vector path.

- [ ] **Step 3: Delete the semantic half of `runSearch`**

Delete these lines (~104–111):

```swift
      guard AppDefaults.semanticSearchEnabled else { self.semanticHits = []; return }
      let related = await SemanticQueries.search(
        query: query,
        scope: SemanticSearchScope(visibleNodeIDs: visible, excludingIDs: Set(hits.map { $0.id }),
                                   limit: 8, floor: 0.25, includeArchived: includeArchived),
        store: self.semanticStore, embedder: self.embedder, database)
      guard self.searchToken == token, !Task.isCancelled else { return }
      self.semanticHits = related
```

`self.searchHits = hits` becomes the last statement of the task. Then delete the two remaining `semanticHits = []` assignments (~line 73 and ~line 156).

- [ ] **Step 4: Delete the "Related" section and fix the empty-state condition in `ContentListView.swift`**

Delete:

```swift
      if !model.semanticHits.isEmpty {
        Section(header: Text("Related (experimental)")) {
          ForEach(model.semanticHits) { hit in searchRow(hit) }
        }
      }
```

And in `searchEmptyState()`, change the condition:

```swift
    if model.searchHits.isEmpty && model.pinnedTopHit == nil {
```

- [ ] **Step 5: Delete `AppDefaults.semanticSearchEnabled`**

Remove lines 27–33 of `AppDefaults.swift` (the doc comment and the computed property). Leave the rest of the enum alone.

- [ ] **Step 6: Delete the Settings toggle**

In `IntelligenceSettingsTab.swift`, delete line 11:

```swift
  @AppStorage(PensieveDefaults.semanticSearchKey) private var semanticSearchEnabled = false
```

and the toggle plus its caption (~66–73):

```swift
        Toggle("Semantic search (experimental)", isOn: $semanticSearchEnabled)
        Text("""
          Adds a second, separately ranked list of related work below the search results, found by \
          meaning rather than by words. Off by default: it currently finds the right project less \
          often than the ordinary search does. Builds an on-device index; first use downloads a \
          small on-device model.
          """)
          .font(.caption).foregroundStyle(.secondary)
```

The narration toggle above it and the LLM Provider picker below it stay.

- [ ] **Step 7: Remove the three String Catalog keys**

`Localizable.xcstrings` is JSON. Remove exactly these three top-level keys from `"strings"`, each with its whole object (en base + `de` localization):

1. `"Semantic search (experimental)"`
2. `"Adds a second, separately ranked list of related work below the search results, found by meaning rather than by words. Off by default: it currently finds the right project less often than the ordinary search does. Builds an on-device index; first use downloads a small on-device model."`
3. `"Related (experimental)"`

Verify the file is still valid JSON and the count dropped by exactly 3 (215 → 212 at time of writing):

```bash
python3 -c "import json; d=json.load(open('Sources/PensieveApp/Localizable.xcstrings')); print('keys:', len(d['strings'])); print('leftovers:', [k for k in d['strings'] if 'semantic' in k.lower() or 'Related (experimental)' in k])"
```

Expected: the leftovers list is empty. (Editing the catalog by hand is required — `xcodebuild` does not populate or prune it; that is IDE-only.)

- [ ] **Step 8: Verify nothing app-side still references the vector path**

```bash
grep -rn 'semanticHits\|semanticStore\|semanticSearchEnabled\|SemanticQueries\|NLContextualEmbedder\|SemanticIndexer' Sources/PensieveApp/
```

Expected: **no output**.

- [ ] **Step 9: Build the app and CLI**

Run: `xcodegen generate && xcodebuild -project Pensieve.xcodeproj -scheme Pensieve -configuration Debug -derivedDataPath ./.build-xcode build 2>&1 | tail -3`
Expected: `** BUILD SUCCEEDED **`. Then `git checkout -- Package.resolved`.

- [ ] **Step 10: Run the Kit suite and lint**

Run: `./scripts/test.sh 2>&1 | grep 'Test run with'` → PASS, `BASELINE` tests (the app has no unit tests, so the count is unchanged).
Run: `swiftlint lint --strict --quiet` → no output.

- [ ] **Step 11: Commit**

```bash
git add Sources/PensieveApp/AppModel.swift Sources/PensieveApp/AppModel+Search.swift \
        Sources/PensieveApp/ContentListView.swift Sources/PensieveApp/AppDefaults.swift \
        Sources/PensieveApp/Settings/IntelligenceSettingsTab.swift Sources/PensieveApp/Localizable.xcstrings
git commit -F - <<'EOF'
feat(app)!: remove the semantic search surface

Deletes the Settings toggle, the "Related (experimental)" results section, the
semanticHits state, and the AppModel embedder/store lazy vars. With the toggle
off there is no visible change; the section rendered empty.

The lazy vars are the reason this is a real removal rather than a hide: touching
them created an index file and loaded a NaturalLanguage model asset, which is
how a disabled feature still had a launch-time cost (b36f745).

Three String Catalog keys removed by hand, en + de — xcodebuild neither adds nor
prunes them.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01J7duqNmYpADJ6axVaL3y6G
EOF
```

---

## Task 3: Remove the MCP surface and drop the `engine` field

**Files:**
- Modify: `Sources/pensieve/Commands/Mcp.swift` (statics ~175–182; `handleSearch`/`searchJSON` ~255–278; `SearchItem` ~302–338)
- Test: `Tests/PensieveKitTests/` — none possible (`Sources/pensieve/` is Xcode-only). Verification is a real stdio round-trip, specified below.

**Interfaces:**
- Consumes: `SearchQueries.search(query:file:scope:store:_:)` (unchanged).
- Produces: the `search` tool's JSON payload **without** an `engine` key: `{"items":[{"id","kind","node_id","node_name","title","snippet","score","archived"}],"index_state":"…"}`. This is a deliberate breaking change to the documented tool contract.

- [ ] **Step 1: Delete the cached vector statics**

Remove these lines and their comment block from `enum PensieveMCP`:

```swift
  // Built once for the server's lifetime (the MCP process is long-lived): the NL asset load + the
  // index pool open are otherwise repeated on every `search` call. Both are Sendable. Caveat: a
  // version bump WHILE the server runs won't reopen the cached store — acceptable, the server is
  // session-scoped and the app/daemon own rebuilds.
  private static let semanticEmbedder = NLContextualEmbedder()
  private static let semanticStore = SemanticIndexStore(
    url: PensievePaths.semanticIndexURL(),
    dimension: semanticEmbedder.dimension, embedderVersion: semanticEmbedder.version)
```

Keep the `searchStore` static beside them.

- [ ] **Step 2: Delete the semantic branch in the search handler**

Replace:

```swift
    var items = ranked.map { SearchItem(hit: $0, engine: "bm25") }
    if PensieveDefaults.semanticSearchEnabled() {
      let related = await SemanticQueries.search(
        query: query,
        scope: SemanticSearchScope(visibleNodeIDs: visible, excludingIDs: Set(ranked.map { $0.id }),
                                   limit: limit, floor: 0.25, includeArchived: includeArchived),
        store: semanticStore, embedder: semanticEmbedder, database)
      items += related.map { SearchItem(hit: $0, engine: "vector") }
    }
    return try makeEncoder().encode(
      SearchPayload(items: Array(items.prefix(limit * 2)), indexState: searchStore.state()))
```

with:

```swift
    // `limit` is honoured by SearchQueries itself; there is no second engine to make room for, so
    // the payload no longer over-allocates and then truncates.
    let items = ranked.map { SearchItem(hit: $0) }
    return try makeEncoder().encode(
      SearchPayload(items: items, indexState: searchStore.state()))
```

Note the deliberate behaviour change: `prefix(limit * 2)` existed only to fit two engines' results. `limit` now means `limit`.

- [ ] **Step 3: Drop `engine` from `SearchItem`**

Delete the `var engine: String` property, its `init` parameter and assignment (`self.engine = engine`), and `engine` from `CodingKeys`. Rewrite the `score` doc comment, since half of it was about comparing engines:

```swift
  /// BM25 relevance. NOT reliably comparable between items: hits found by file path come from a
  /// different FTS5 table with a different average document length than text hits, and can score
  /// higher while being less relevant. Array order is the contract — re-sorting by `score` would
  /// reconstruct exactly the ranking the verification gate rejected on measured evidence.
  var score: Double?
```

The resulting init signature is `init(hit: SearchHit)`.

- [ ] **Step 4: Update the tool description, which promises the caller two engines**

In the `search` tool's `description`, the sentence about `score` not being comparable "between items" stays (still true). Remove any wording implying multiple engines, and keep the ranked-order instruction. Verify by reading the emitted schema in Step 6.

- [ ] **Step 5: Verify nothing CLI-side still references the vector path**

```bash
grep -rn 'Semantic\|semantic\|NLContextual\|engine' Sources/pensieve/
```

Expected: no `Semantic*`/`NLContextual*`/`semantic*` hits. The word "engine" may legitimately survive in prose; read each hit.

- [ ] **Step 6: Build, then verify the wire shape against the real store (read-only)**

Run: `xcodebuild -project Pensieve.xcodeproj -scheme PensieveCLI -configuration Debug -derivedDataPath ./.build-xcode build 2>&1 | tail -3` → `** BUILD SUCCEEDED **`, then `git checkout -- Package.resolved`.

The MCP server exits on stdin EOF before replying, so a redirect prints nothing — you must hold stdin open:

```bash
CLI=./.build-xcode/Build/Products/Debug/pensieve
perl -e '$|=1;
print qq({"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"v","version":"1"}}}\n); sleep 2;
print qq({"jsonrpc":"2.0","method":"notifications/initialized"}\n); sleep 1;
print qq({"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"search","arguments":{"query":"sync","limit":3}}}\n); sleep 6;' \
| "$CLI" mcp 2>/dev/null > /tmp/mcp-verify.txt
python3 - <<'PY'
import json
for line in open('/tmp/mcp-verify.txt'):
    line = line.strip()
    if not line.startswith('{'): continue
    try: msg = json.loads(line)
    except ValueError: continue
    if msg.get('id') != 2: continue
    payload = json.loads(msg['result']['content'][0]['text'])
    keys = sorted({k for item in payload['items'] for k in item})
    print('index_state:', payload.get('index_state'))
    print('item keys  :', keys)
    assert 'engine' not in keys, 'engine key still present'
    assert payload['items'], 'no results — check the index is built'
    assert len(payload['items']) <= 3, 'limit not honoured'
    print('OK: no engine key, limit honoured')
PY
```

Expected: `OK: no engine key, limit honoured`.

- [ ] **Step 7: Run the Kit suite and lint**

Run: `./scripts/test.sh 2>&1 | grep 'Test run with'` → PASS, `BASELINE` tests.
Run: `swiftlint lint --strict --quiet` → no output.

- [ ] **Step 8: Commit**

```bash
git add Sources/pensieve/Commands/Mcp.swift
git commit -F - <<'EOF'
feat(mcp)!: search returns one engine's results, without an engine tag

Removes the semantic branch and the cached embedder/store statics, and drops the
`engine` field from every SearchItem — a breaking change to the documented tool
contract, accepted because with one engine the field carries no information.

`prefix(limit * 2)` went with it: that existed only to leave room for a second
engine's results, so `limit` now means what it says.

Verified over stdio against the real store: no engine key, limit honoured.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01J7duqNmYpADJ6axVaL3y6G
EOF
```

---

## Task 4: Remove `SyncRunner.semanticIndexer` and its self-constructing fallback

`SyncRunner` builds a semantic indexer *itself* when none is injected and the toggle is on — pointing at the shared `PensievePaths.semanticIndexURL()`. That is the hazard the search indexer deliberately avoids, and it goes with the rest.

**Files:**
- Modify: `Sources/PensieveKit/Sync/SyncRunner.swift` (property 15, init 20 + 24, block ~56–66)
- Test: `Tests/PensieveKitTests/SyncRunnerTests.swift` (delete 1 test, add 1)

**Interfaces:**
- Consumes: nothing new.
- Produces: `SyncRunner.init(spool:database:provider:projectsDir:now:searchIndexer:)` — the `semanticIndexer:` parameter no longer exists. `searchIndexer` keeps its `nil` default and its no-fallback contract.

- [ ] **Step 1: Write the failing test that pins the parameter's absence**

Add to `Tests/PensieveKitTests/SyncRunnerTests.swift`:

```swift
/// The retired vector path must leave no way back in. `SyncRunner` used to construct a
/// SemanticIndexer itself when none was injected and the toggle was on — pointing at the SHARED
/// index path, so any caller could rebuild a real index it never asked for. This pins the surviving
/// shape: one optional indexer, no self-construction, and a run that indexes only what it was given.
@Test func syncTakesOnlyASearchIndexer() async throws {
  let projects = tmp("projects", ext: "d")
  try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
  let spool = try CaptureSpool(at: tmp("sync-onlysearch-spool", ext: "sqlite"))
  let database = try openCanonicalDatabase(at: tmp("sync-onlysearch-canon", ext: "sqlite"))
  let node = Node(name: "Background sync agent", kind: NodeKind.project)
  try await database.write { database in try Node.insert { node }.execute(database) }

  let store = SearchIndexStore(url: tmp("sync-onlysearch-index", ext: "sqlite"))
  // Compiles ONLY while `semanticIndexer:` does not exist: adding it back with a default would keep
  // this green, but re-adding a self-constructing fallback is what the deleted `else if` did, and
  // Step 4's grep is what guards that.
  let runner = SyncRunner(spool: spool, database: database, provider: NoopProvider(),
                          projectsDir: projects, searchIndexer: SearchIndexer(store: store))
  _ = try await runner.run()

  #expect(store.state() == .ready)
  #expect(store.search(FTSQueryBuilder.build("background ")!, limit: 5,
                       includeArchived: false).map(\.itemID) == [node.id.uuidString])
}
```

- [ ] **Step 2: Delete the old semantic test from the same file**

Delete `syncPopulatesSemanticIndexWhenEnabled()` in full, including its `///` doc comment (~lines 106–128). It constructs `SemanticIndexStore` and `StubEmbedder`, both of which cease to exist in Task 5.

- [ ] **Step 3: Run the suite**

Run: `./scripts/test.sh 2>&1 | grep -E 'Test run with|error:'`
Expected: PASS at `BASELINE` tests (one deleted, one added).

Note this is a **pin, not a red-then-green cycle**: the new test exercises only the API that survives, so it passes before the deletion as well as after. That is the honest shape for a removal — what it guards is the *future* re-addition of a `semanticIndexer:` parameter, which would make it stop compiling. If instead you get a compile error here, the likely cause is a stray `StubEmbedder` or `SemanticIndexStore` reference left behind in the file by Step 2.

- [ ] **Step 4: Delete the semantic wiring from `SyncRunner.swift`**

Remove `let semanticIndexer: SemanticIndexer?` (line 15), the `semanticIndexer: SemanticIndexer? = nil,` init parameter (line 20), and `self.semanticIndexer = semanticIndexer;` from line 24 (keep `self.searchIndexer = searchIndexer`). Then delete the whole block:

```swift
    // Semantic index refresh (best-effort, on-device, toggle-gated). Never blocks the sync summary.
    if let semanticIndexer {
      await semanticIndexer.sync(database)
    } else if PensieveDefaults.semanticSearchEnabled() {
      let embedder = NLContextualEmbedder()
      let store = SemanticIndexStore(url: PensievePaths.semanticIndexURL(),
                                     dimension: embedder.dimension, embedderVersion: embedder.version)
      if store.isAvailable, embedder.dimension > 0 {
        await SemanticIndexer(store: store, embedder: embedder).sync(database)
      }
    }
```

The search-index block that follows it stays, comment and all.

- [ ] **Step 5: Verify no self-construction remains**

```bash
grep -n 'IndexStore(url:\|Indexer(' Sources/PensieveKit/Sync/SyncRunner.swift
```

Expected: **no output** — `SyncRunner` constructs neither store nor indexer; both are injected.

- [ ] **Step 6: Run the suite and lint**

Run: `./scripts/test.sh 2>&1 | grep 'Test run with'` → PASS, `BASELINE` tests (−1 +1).
Run: `swiftlint lint --strict --quiet` → no output.

- [ ] **Step 7: Commit**

```bash
git add Sources/PensieveKit/Sync/SyncRunner.swift Tests/PensieveKitTests/SyncRunnerTests.swift
git commit -F - <<'EOF'
refactor(sync)!: SyncRunner takes only a search indexer

Drops the semanticIndexer parameter and, with it, the fallback that constructed a
SemanticIndexer against the SHARED index path when none was injected and the
toggle was on — precisely the hazard the search indexer has no fallback in order
to avoid. Any caller could have rebuilt an index it never asked for.

The replacement test pins the surviving shape rather than the deleted one.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01J7duqNmYpADJ6axVaL3y6G
EOF
```

---

## Task 5: Delete the Kit vector code and its tests

**Files:**
- Delete: `Sources/PensieveKit/Semantic/{NLContextualEmbedder,TextEmbedder,SemanticIndexer,SemanticIndexStore}.swift` (then the empty `Semantic/` directory)
- Delete: `Sources/PensieveKit/Query/SemanticQueries.swift`
- Delete: `Tests/PensieveKitTests/{SemanticIndexerTests,SemanticIndexStoreTests,SemanticQueriesTests,TextEmbedderTests,SQLiteVecSpikeTests}.swift`
- Delete: `Tests/PensieveKitTests/Support/{NilEmbedder,PoisonEmbedder,StubEmbedder}.swift`
- Modify: `Sources/PensieveKit/Support/PensieveDefaults.swift` (remove `semanticSearchKey` + `semanticSearchEnabled`)
- Modify: `Sources/PensieveKit/Support/PensievePaths.swift` (remove `semanticIndexURL`)
- Modify: `Sources/PensieveKit/Query/SearchHit.swift` (doc comment, lines 12–14)

**Interfaces:**
- Consumes: nothing.
- Produces: a Kit with no vector types. `PensievePaths.indexURL(named:storeOverride:)` and `searchIndexURL()` survive unchanged — the env-scoping rule is shared, not vector-specific.

- [ ] **Step 1: Delete the files**

```bash
git rm Sources/PensieveKit/Semantic/NLContextualEmbedder.swift \
       Sources/PensieveKit/Semantic/TextEmbedder.swift \
       Sources/PensieveKit/Semantic/SemanticIndexer.swift \
       Sources/PensieveKit/Semantic/SemanticIndexStore.swift \
       Sources/PensieveKit/Query/SemanticQueries.swift \
       Tests/PensieveKitTests/SemanticIndexerTests.swift \
       Tests/PensieveKitTests/SemanticIndexStoreTests.swift \
       Tests/PensieveKitTests/SemanticQueriesTests.swift \
       Tests/PensieveKitTests/TextEmbedderTests.swift \
       Tests/PensieveKitTests/SQLiteVecSpikeTests.swift \
       Tests/PensieveKitTests/Support/NilEmbedder.swift \
       Tests/PensieveKitTests/Support/PoisonEmbedder.swift \
       Tests/PensieveKitTests/Support/StubEmbedder.swift
```

Confirm `Semantic/` is empty and gone: `ls Sources/PensieveKit/Semantic/ 2>&1` → "No such file or directory". (Task 1 moved its only survivor.)

- [ ] **Step 2: Remove the two `PensieveDefaults` members**

Delete `public static let semanticSearchKey = "app.semanticSearch"` and the whole `semanticSearchEnabled(_:)` function with its doc comment. The other keys (`llmProviderKey`, `cloudFlavorKey`, `cloudBaseURLKey`, `cloudModelKey`), `appDomain` and `shared()` all stay — `shared()` is still used for provider selection.

- [ ] **Step 3: Remove `PensievePaths.semanticIndexURL`**

Delete the function and its doc comment. **Keep** `searchIndexURL()`, `indexURL(named:)` and `indexURL(named:storeOverride:)`. Update the shared helper's doc comment where it says "the indexes" (plural) to name the search index specifically, but leave the `PENSIEVE_DB` rationale intact — it is the reason the helper exists.

- [ ] **Step 4: Fix the `SearchHit` doc comment, which describes two engines**

```swift
/// One search result, from the FTS5/BM25 index — the only retrieval path. The name deliberately does
/// not claim an engine: `score` is whatever the producing engine ranks by, which keeps the type
/// reusable if a measured-better engine ever replaces BM25.
```

- [ ] **Step 5: Verify the vector path is gone from the Kit**

```bash
grep -rn 'SemanticQueries\|SemanticIndex\|NLContextualEmbedder\|TextEmbedder\|semanticSearch\|SemanticSearchScope\|import CSQLiteVec' Sources/PensieveKit/
```

Expected: **no output**.

```bash
grep -rn 'prepareDatabase' Sources/PensieveKit/
```

Expected: exactly one hit, `Store/CaptureSpool.swift` (the WAL pragma). The sqlite-vec registration hook left with `SemanticIndexStore`.

- [ ] **Step 6: Run the suite — this is where the count must drop by exactly 38**

Run: `./scripts/test.sh 2>&1 | grep 'Test run with'`
Expected: PASS with `BASELINE - 38` tests (15 + 8 + 10 + 4 + 1). If the number is lower, a BM25 or corpus test was deleted with them — find it before committing.

Run: `swiftlint lint --strict --quiet` → no output.

- [ ] **Step 7: Confirm BM25's own tests were untouched**

```bash
git diff --stat HEAD -- Tests/PensieveKitTests/SearchQueriesTests.swift \
  Tests/PensieveKitTests/SearchIndexStoreTests.swift Tests/PensieveKitTests/FTSQueryTests.swift \
  Tests/PensieveKitTests/SearchIndexerTests.swift Tests/PensieveKitTests/EmbeddableCorpusHygieneTests.swift
```

Expected: **no output** — not one line changed in any of them.

- [ ] **Step 8: Commit**

```bash
git add -u Sources/PensieveKit Tests/PensieveKitTests
git commit -F - <<'EOF'
feat(kit)!: delete the vector search engine

Removes the embedder, its protocol seam, the vec0 index store, the incremental
indexer, and SemanticQueries — including SemanticSearchScope and the `floor` that
was the original defect: measured on the real corpus, gibberish scored 0.880
cosine against a perfect match's 0.936, so no threshold could separate them.

38 tests go with it. BM25's tests are untouched, which is the point: the corpus,
the hygiene rules and every grounding guard are unchanged.

PensievePaths keeps its PENSIEVE_DB-scoped indexURL helper — that rule is about
any derived store, not about vectors.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01J7duqNmYpADJ6axVaL3y6G
EOF
```

---

## Task 6: Delete the vendored `sqlite-vec` C target

Last, because it is the only step that can break the build in an unfamiliar way.

**Files:**
- Delete: `Sources/CSQLiteVec/` (`sqlite-vec.c`, `shim.c`, `include/CSQLiteVec.h`, `include/module.modulemap`)
- Modify: `Package.swift` (remove the target and PensieveKit's dependency on it)

**Interfaces:**
- Consumes: nothing. Nothing imports `CSQLiteVec` after Task 5.
- Produces: a `Package.swift` with two targets (`PensieveKit`, `PensieveKitTests`) and one product.

- [ ] **Step 1: Confirm nothing imports it**

```bash
grep -rn 'CSQLiteVec\|sqlite_vec\|sqlite-vec' Sources/PensieveKit Sources/PensieveApp Sources/pensieve Tests/
```

Expected: **no output**. Do not proceed otherwise.

- [ ] **Step 2: Delete the directory**

```bash
git rm -r Sources/CSQLiteVec
```

- [ ] **Step 3: Remove the target and the dependency from `Package.swift`**

Delete this target entirely:

```swift
    .target(
      name: "CSQLiteVec",
      // sqlite-vec.c uses SQLITE_CORE-off extension mode; link the system sqlite3.
      cSettings: [.define("SQLITE_CORE", to: "0")],
      linkerSettings: [.linkedLibrary("sqlite3")]
    ),
```

and remove `"CSQLiteVec",` from `PensieveKit`'s `dependencies`, leaving:

```swift
    .target(
      name: "PensieveKit",
      dependencies: [
        .product(name: "SQLiteData", package: "sqlite-data"),
      ],
      // Documentation that lives next to the code it describes; not a build input.
      exclude: ["Eval/README.md"]
    ),
```

- [ ] **Step 4: Build from clean, so a stale artifact cannot mask a broken manifest**

```bash
rm -rf .build
swift build 2>&1 | tail -5
```

Expected: build succeeds with no C compilation. (A `rm -rf .build` is also the documented remedy for the intermittent SwiftSyntax/macro linker error, so this step doubles as insurance.)

- [ ] **Step 5: Run the suite and lint**

Run: `./scripts/test.sh 2>&1 | grep 'Test run with'` → PASS, `BASELINE - 38` tests (unchanged from Task 5 — deleting the spike test happened there).
Run: `swiftlint lint --strict --quiet` → no output.

- [ ] **Step 6: Build the app + CLI, which link PensieveKit as a local SwiftPM package**

Run: `xcodegen generate && xcodebuild -project Pensieve.xcodeproj -scheme Pensieve -configuration Debug -derivedDataPath ./.build-xcode build 2>&1 | tail -3`
Expected: `** BUILD SUCCEEDED **`. Then `git checkout -- Package.resolved`.

- [ ] **Step 7: Commit**

```bash
git add Package.swift Sources/CSQLiteVec
git commit -F - <<'EOF'
build!: drop the vendored sqlite-vec C target

320 KB of vendored C, a hand-written module map, and a per-connection extension
registration all leave with the engine that needed them. `swift test` no longer
compiles a C target.

The integration was hard-won — Apple disables sqlite3_auto_extension, so
registration had to happen per-connection via GRDB's prepareDatabase. That
finding is recorded in the semantic-vector-recall spec and in git, which is what
makes it recoverable. Shipped code is not documentation.

Verified from a clean .build so no stale artifact could mask a broken manifest.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01J7duqNmYpADJ6axVaL3y6G
EOF
```

---

## Task 7: Documentation

**Files:**
- Modify: `CLAUDE.md` (Status list), `CONTINUE.md`, `docs/superpowers/backlog.md`

**Interfaces:** none.

- [ ] **Step 1: Add the ship entry to `CLAUDE.md`**

Insert immediately before the `- **Next: two open tracks…**` bullet, matching the density of its neighbours:

```markdown
- **Vector search removed — DONE** (2026-08-11): deleted the engine that lost on measurement. The embedder, its protocol seam, the `vec0` store, the incremental indexer, `SemanticQueries` (incl. `SemanticSearchScope` and the inert `floor`), the vendored `sqlite-vec` C target, the Settings toggle, the ⌘F "Related (experimental)" section, and the MCP `engine` field are all gone; **BM25 is the only retrieval path**. Three findings forced it: default-off **did not mean off** (a `true` persisted from July's default-on kept the vector engine live and measurably diluting MCP results — `search "focus filter spotlight"` returned the correct BM25 hit plus **three** vector rows, two of them unrelated projects at 0.886/0.878); a **disabled** feature still created its index and loaded a model asset on every launch (`b36f745`); and two engines was a standing tax on grounding — the retrieval branch had to extract a shared `SearchHitResolver` *because* the two had drifted. `EmbeddableItem`/`EmbeddableCorpus` **survive and moved** to `Search/` — that is the corpus BM25 reads, hygiene rules included. **Breaking:** MCP `search` items no longer carry `engine`, and `limit` now means `limit` (the `prefix(limit * 2)` over-allocation existed only to fit two engines). **P3 unaffected** — all four committed probes carry their own ~25-line embedder and import no PensieveKit vector type, so the eval owns its research dependency, which is the right home for it. Trust gate untouched (extraction never embedded). Spec/plan: `docs/superpowers/{specs,plans}/2026-08-11-remove-vector-search*`. **Post-merge carry:** rebuild + reinstall to `/Applications` so the bundled `pensieve mcp` stops advertising the old wire shape.
```

- [ ] **Step 2: Update the "Next" bullet in `CLAUDE.md`**

In the same bullet, replace the Track C sentence so semantic recall is described as removed rather than shipped, and P3 remains the open item:

> **(C) findability / OS-integration:** in-app find, menu bar, `pensieve://`, App Intents + Spotlight, Focus filters, Spotlight loose-end indexing and **retrieval P1+P2′ (BM25)** shipped; **semantic/vector recall was built, measured worse, and removed (2026-08-11)**. Remaining — **P3 the paraphrase eval harness** (blocked on the user's gold set) and **transcript-passage chunking** (own spec).

- [ ] **Step 3: Rewrite the backlog's quarantine entry**

Retitle `## Semantic relevance floor is inert — CLOSED 2026-08-11 as QUARANTINED, not deleted` to `## Semantic relevance floor — CLOSED by removing the engine (2026-08-11)`. Replace the "⚠️ THE DEFAULT FLIP DOES NOT MIGRATE" clause's *forward-looking* wording (the toggle no longer exists) but **keep**: the measurements table, the general lesson (*flipping a default is not a migration — a shipped default-on toggle leaves persisted `true`s on every machine that ever ran it, and no code review can see that*), and the pointer to the probes. Add one line: the persisted `app.semanticSearch` key is now inert and can be deleted with `defaults delete me.mazetti.pensieve app.semanticSearch`.

- [ ] **Step 4: Update `CONTINUE.md`**

Replace the "No open defects on the DEFAULT path" paragraph — the migration caveat it describes is moot once the toggle is gone — with a short statement that BM25 is the only retrieval path and the vector stack is deleted. Move P3 to the front of THE NEXT ACTION, still marked blocked on the user's 30–50 paraphrase queries. Add to the post-merge carries: rebuild + reinstall for the MCP wire change, and `defaults delete me.mazetti.pensieve app.semanticSearch`.

- [ ] **Step 5: Check the docs make no claim the code contradicts**

```bash
grep -rn -i 'semantic search\|vector recall\|Related (experimental)' CLAUDE.md CONTINUE.md | grep -vi 'removed\|retired\|deleted\|was built\|no longer\|inert'
```

Expected: no output, or only lines that are explicitly historical (the July ship entries, which stay — they are a record of what happened).

- [ ] **Step 6: Commit**

```bash
git add CLAUDE.md CONTINUE.md docs/superpowers/backlog.md
git commit -F - <<'EOF'
docs: vector search removed — BM25 is the only retrieval path

Records what was deleted and the three findings that forced it, keeping the
measurements and the general lesson: flipping a default is not a migration.

The July ship entries stay. They are a record of what happened, not a claim
about what ships.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01J7duqNmYpADJ6axVaL3y6G
EOF
```

---

## Post-merge carries

Not tasks — they need the installed app, the real store, and a human.

- **Rebuild + reinstall to `/Applications`.** The bundled `pensieve mcp` is what every Claude Code session calls, so until this happens sessions still see the `engine` field. Then confirm `ls -l ~/.local/bin/pensieve` is still a symlink into `Contents/Helpers/`.
- **Expect the background agent to need healing.** Replacing the bundle mints a new helper cdhash, and `SMAppService.register()` silently no-ops a stale registration (`EX_CONFIG` / "Launch Constraint Violation"). Observed 2026-08-11: the app's own unregister+register did **not** heal it. The fix that worked was: quit the app → `launchctl bootout gui/$(id -u)/me.mazetti.pensieve.sync` → relaunch → verify `last exit code = 0` and a fresh line in `~/Library/Logs/Pensieve/sync.log`.
- **`defaults delete me.mazetti.pensieve app.semanticSearch`** — inert once the toggle is gone, but leaving it invites a future reader to wonder what reads it.
- **Human-verify ⌘F:** a multi-word query with no verbatim occurrence still returns work; a bare filename still finds its commits; each row still shows *why* it matched; no "Related" section appears; German in-situ for the Intelligence tab now that a toggle was removed from it.
- **Already done, do not repeat:** `semantic-index.sqlite` and the orphaned `text-index.sqlite` were deleted by hand on 2026-08-11 (~11 MB). Nothing recreates them.

---

## Self-Review

**Spec coverage.** Every "Delete" bullet maps to a task: Kit vector files + `PensieveDefaults`/`PensievePaths` members → Task 5; vendored dependency → Task 6; app surface incl. the corrected `ContentListView` section and `semanticHits` → Task 2; MCP surface + `engine` → Task 3; `SyncRunner` → Task 4; tests → Tasks 4 and 5. "Keep, and move" (`EmbeddableItem` + its two comment rationales) → Task 1. Docs → Task 7. Out-of-scope items (P3, BM25, the trust gate) are named in Global Constraints and touched by no step.

**Placeholder scan.** No TBDs. Every code step shows the actual code; every verification step shows the command and its expected output. The one prose-only step is Task 7 Step 4 (rewriting a handoff document), where dictating exact wording would be worse than stating the required content.

**Type consistency.** `SearchItem.init(hit:)` (Task 3) matches its only call site in the same task. `SyncRunner.init(spool:database:provider:projectsDir:now:searchIndexer:)` (Task 4) matches the test written in Step 1 of that task and the production call sites, which already pass `searchIndexer:` by label and never passed `semanticIndexer:`. `SearchIndexer.production()`, `SearchIndexStore.state()`, `FTSQueryBuilder.build(_:)` are used with their existing signatures.

**Counts.** 38 deleted in Task 5 (15 + 8 + 10 + 4 + 1) and 1 in Task 4, against 1 added in Task 4 and 0 elsewhere — Task 3's verification is a runtime assertion, not a `@Test`, because `Sources/pensieve/` has no test target. `BASELINE − 39 + 1 = BASELINE − 38`, which is what Global Constraints and every per-task expectation now state.

**Known limitation, stated rather than hidden.** Two tasks are verified by a build plus a runtime check rather than by the suite: Task 2 (the app target has no unit tests, by design in this project) and Task 3 (no test target for the CLI). For Task 3 that gap is partly closed by the stdio round-trip in Step 6, which asserts the wire shape against the real store. For Task 2 it is not closed at all — the ⌘F behaviour changes are in the human-verify carries. A reviewer should weigh Task 2's diff more carefully for that reason.

**Ordering.** Tasks 2–4 remove all consumers before Task 5 removes the types, so the suite and both Xcode targets stay green throughout. Task 6 is last because a manifest change is the only step that can fail in an unfamiliar way. Task 1 is first because it de-risks the one shared file.
