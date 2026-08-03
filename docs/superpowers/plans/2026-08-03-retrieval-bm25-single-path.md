# Retrieval: corpus hygiene + BM25 as the single search path — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Retire the substring matcher and the inert cosine floor, and make one BM25/FTS5 index — built from the hygiene-cleaned `EmbeddableCorpus`, including changed-file paths — the single retrieval path behind ⌘F and MCP `search`.

**Architecture:** A new derived, never-synced `search-index.sqlite` holds one FTS5 row per `EmbeddableItem` (`text` weight 1.0, `files` weight 0.1), rebuilt whole and hash-guarded from the same `EmbeddableCorpus.gather` the semantic index uses. A pure `FTSQueryBuilder` turns raw user input into a safe `MATCH` expression; `SearchQueries` runs it, over-fetches, applies Focus/state/exclusion guards, and re-resolves every survivor against the canonical store before it can become a result. Node navigation is guaranteed by a pure `topHit` scan over the visible node set, not by the capped result list. The vector path stays in the tree, returns the same `SearchHit` type, and goes default-off.

**Tech Stack:** Swift 6 / Swift Testing, SQLiteData 1.6.6 (GRDB-backed), SQLite FTS5 via **raw SQL** (system libsqlite3), SwiftUI (app target), XcodeGen + Xcode 26.6 for the app/CLI bundle.

**Scope:** Spec parts **P1** and **P2′** only. **P3** (the paraphrase eval harness) is a separate plan, written after this ships and after the 30–50 hand-written gold queries exist.

**Spec:** `docs/superpowers/specs/2026-07-28-retrieval-eval-harness-design.md`

## Global Constraints

- **Swift only. No Python, ever.** Measurement probes are single-file `swift <file>.swift` scripts.
- **SQLiteData predicates use `.eq(x)`, never `== x`** — `==` is `unavailable` and will not compile.
- **Name things explicitly — no abbreviations, no single letters.** `database`, `looseEnd`, `event`, `node`, `store`. Genuine wire-format keys (`node_id`, `item_id`, `include_archived`) stay `snake_case` behind explicit `CodingKeys`.
- **SwiftLint is enforced (`swiftlint lint --strict`)** with the repo-root `.swiftlint.yml`. Never relax a rule to accommodate a finding.
- **FTS5 is reached through raw SQL only** (`database.execute(sql:)` / `Row.fetchAll(database, sql:)`). GRDB's Swift-level FTS5 API (`FTS5TokenizerDescriptor`, `virtualTable(.fts5)`) is conditionally compiled and is **not** used. No vendoring, no C target, no `prepareDatabase` hook — those are sqlite-vec requirements, not ours. Verified available on system SQLite 3.51.0.
- **Tokenizer is exactly `unicode61 remove_diacritics 2`, unstemmed.** Stemming is out of scope (P3 measures `bm25Porter`).
- **bm25 column weights: `text` 1.0, `files` 0.1**, pinned by test.
- **bm25() returns a negative score, best-first ascending.** Store and return `-bm25(...)` so `SearchHit.score` is positive and higher-is-better, matching the direction `similarity` had.
- **The trust gate is untouched.** This work changes which rows are *eligible* to be returned, never what may be *said* about them. Extraction, narration and `injectionMarkers` are not modified.
- **Tests run with `./scripts/test.sh`** (optionally `--filter <name>`). The whole suite must pass at the end of every task.
- **The app target (`Sources/PensieveApp/`) has no unit tests.** Verify with `xcodegen generate` + `xcodebuild` + a non-blocking smoke-launch of the **inner binary** with throwaway `PENSIEVE_DB`/`PENSIEVE_CAPTURE_DB`, then `kill`.
- **Localize app chrome only, en + de.** Node names, loose-end text/quotes, event summaries, file paths and query text are content and stay verbatim. App-Intents/Siri strings stay English literals.
- **Commit after every task.** Never use backticks inside `git commit -m "..."` (they get shell-executed) — use `-F` or single quotes.

---

## File Structure

**Created**

| File | Responsibility |
|---|---|
| `Sources/PensieveKit/Search/FTSQuery.swift` | Pure: raw user input → a safe FTS5 `MATCH` expression + the term list for snippets. No I/O. |
| `Sources/PensieveKit/Search/SearchIndexStore.swift` | The `search-index.sqlite` FTS5 store: open/migrate, whole rebuild, corpus-hash read/write, index state, the ranked `MATCH` query. |
| `Sources/PensieveKit/Search/SearchIndexer.swift` | `EmbeddableCorpus.gather` → corpus hash → guarded whole rebuild. Best-effort. |
| `Sources/PensieveKit/Query/SearchHit.swift` | The one hit type both engines return, plus `SearchIndexState`. |
| `Tests/PensieveKitTests/FTSQueryTests.swift` | Hostile-input coverage for the builder. |
| `Tests/PensieveKitTests/SearchIndexStoreTests.swift` | DDL, rebuild idempotence, weight pinning, state filtering. |
| `Tests/PensieveKitTests/SearchIndexerTests.swift` | Hash guard, hygiene interaction. |
| `Tests/PensieveKitTests/CorpusDumpGenerator.swift` | Env-guarded, test-only `corpus.jsonl` generator for the measurement probes (uses `gather` verbatim). |

**Rewritten**

| File | Change |
|---|---|
| `Sources/PensieveKit/Query/SearchQueries.swift` | Substring matcher deleted. Becomes the BM25 query layer: `search`, `topHit`. `SearchResults`/`NodeHit`/`LooseEndHit` retire with it. Signature changes, so every call site fails to compile until updated — that is the intent. |
| `Tests/PensieveKitTests/SearchQueriesTests.swift` | Rewritten against the new engine; guard parity tests ported from `SemanticQueriesTests`. |

**Modified**

`EmbeddableItem.swift` (P1 hygiene + `files`), `SemanticQueries.swift` (returns `SearchHit`), `Snippet.swift` (`matchingAny:`), `PensievePaths.swift` (`searchIndexURL`), `SyncRunner.swift` + `Sources/pensieve/Commands/Mcp.swift` (wiring, tool contract), `AppModel.swift` / `AppModel+Search.swift` / `ContentListView.swift` / `AppDefaults.swift` / `PensieveDefaults.swift` / `IntelligenceSettingsTab.swift` / `Localizable.xcstrings` (app), `docs/superpowers/measurements/2026-07-28-retrieval-recall/*` (probes + README).

---

## Task 1: P1 corpus hygiene — drop `git.checkout`, per-node de-dup

**Files:**
- Modify: `Sources/PensieveKit/Semantic/EmbeddableItem.swift:48-62` (the event loop in `gather`)
- Test: `Tests/PensieveKitTests/SemanticIndexerTests.swift` (add cases; `gather` is covered here today)

**Interfaces:**
- Consumes: nothing (first task).
- Produces: `EmbeddableCorpus.gather(_:)` keeps its signature `(any DatabaseReader) throws -> [EmbeddableItem]`; its *output* now excludes `git.checkout` events and within-node duplicate texts.

**Context an implementer needs.** `gather` is the single producer of the semantic corpus and, after Task 5, of the search corpus too — so a hygiene fix here lands in both indexes. `CaptureKind.gitCheckout` is the constant for checkout events (never hardcode `"git.checkout"`). De-dup is **per node**, not global: collapsing an identical commit subject across projects would silently decide which project owns a shared phrase, which is a grounding call P1 explicitly declines to make (see spec §P1). The survivor must be deterministic — `Event.all` has no `ORDER BY`, so the current row order is whatever SQLite returns.

- [ ] **Step 1: Write the failing tests**

Add to `Tests/PensieveKitTests/SemanticIndexerTests.swift`:

```swift
@Test func gatherSkipsCheckoutEvents() async throws {
  let database = try openCanonicalDatabase(at: tempURL("gather-checkout"))
  let node = Node(name: "Pensieve", kind: NodeKind.project)
  let source = Source(nodeID: node.id, kind: SourceKind.gitRepo, key: "/p/\(node.id)")
  try await database.write { database in
    try Node.insert { node }.execute(database)
    try Source.insert { source }.execute(database)
    try Event.insert {
      Event(nodeID: node.id, sourceID: source.id, occurredAt: Date(),
            kind: CaptureKind.gitCheckout, summary: "checkout main",
            detailJSON: "{}", fingerprint: "checkout-1")
    }.execute(database)
    try Event.insert {
      Event(nodeID: node.id, sourceID: source.id, occurredAt: Date(),
            kind: CaptureKind.gitCommit, summary: "add the parser",
            detailJSON: "{}", fingerprint: "commit-1")
    }.execute(database)
  }
  let corpus = try EmbeddableCorpus.gather(database)
  let eventTexts = corpus.filter { $0.kind == "event" }.map(\.text)
  #expect(eventTexts == ["add the parser"])
}

@Test func gatherDeDupesWithinANodeKeepingTheEarliest() async throws {
  let database = try openCanonicalDatabase(at: tempURL("gather-dedup"))
  let node = Node(name: "Pensieve", kind: NodeKind.project)
  let source = Source(nodeID: node.id, kind: SourceKind.gitRepo, key: "/p/\(node.id)")
  let earliest = Date(timeIntervalSince1970: 1_000)
  let latest = Date(timeIntervalSince1970: 2_000)
  let keptID = UUID()
  try await database.write { database in
    try Node.insert { node }.execute(database)
    try Source.insert { source }.execute(database)
    // Insert the LATER one first, so passing requires real ordering, not insertion luck.
    try Event.insert {
      Event(nodeID: node.id, sourceID: source.id, occurredAt: latest,
            kind: CaptureKind.gitCommit, summary: "fix ci", detailJSON: "{}", fingerprint: "b")
    }.execute(database)
    try Event.insert {
      Event(id: keptID, nodeID: node.id, sourceID: source.id, occurredAt: earliest,
            kind: CaptureKind.gitCommit, summary: "fix ci", detailJSON: "{}", fingerprint: "a")
    }.execute(database)
  }
  let events = try EmbeddableCorpus.gather(database).filter { $0.kind == "event" }
  #expect(events.count == 1)
  #expect(events[0].itemID == keptID.uuidString)
}

@Test func gatherKeepsIdenticalTextsInDifferentNodes() async throws {
  let database = try openCanonicalDatabase(at: tempURL("gather-dedup-cross"))
  let first = Node(name: "Alpha", kind: NodeKind.project)
  let second = Node(name: "Beta", kind: NodeKind.project)
  try await database.write { database in
    try Node.insert { first }.execute(database)
    try Node.insert { second }.execute(database)
    for node in [first, second] {
      let source = Source(nodeID: node.id, kind: SourceKind.gitRepo, key: "/p/\(node.id)")
      try Source.insert { source }.execute(database)
      try Event.insert {
        Event(nodeID: node.id, sourceID: source.id, occurredAt: Date(),
              kind: CaptureKind.gitCommit, summary: "fix ci",
              detailJSON: "{}", fingerprint: "fix-\(node.id)")
      }.execute(database)
    }
  }
  let events = try EmbeddableCorpus.gather(database).filter { $0.kind == "event" }
  #expect(events.count == 2)   // cross-node duplicates are NOT collapsed
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `./scripts/test.sh --filter gather`
Expected: FAIL — `gatherSkipsCheckoutEvents` sees 2 event texts, `gatherDeDupesWithinANodeKeepingTheEarliest` sees 2 events.

- [ ] **Step 3: Implement the hygiene rules**

In `Sources/PensieveKit/Semantic/EmbeddableItem.swift`, replace the event loop in `gather` (currently `let events = try Event.all.fetchAll(database)` through the end of that `for` loop) with:

```swift
      // Hygiene (spec P1). Two rules, both bounded to events:
      //  1. `git.checkout` carries no work content — 261 of 1,686 rows were bare "checkout <branch>",
      //     84 of them literally "checkout HEAD". They only ever occupied top-k slots.
      //  2. De-duplicate identical texts WITHIN a node, keeping the earliest by (occurredAt, id).
      //     Deliberately not global: collapsing "fix ci" across three projects would silently pick
      //     which project owns the only findable copy — a grounding call, not hygiene. Ordering is
      //     explicit because `Event.all` has none, so "the first occurrence" would otherwise be
      //     whatever SQLite happened to return, and could differ between rebuilds.
      let events = try Event.order { ($0.occurredAt, $0.id) }.fetchAll(database)
      var seenTextsByNode: [UUID: Set<String>] = [:]
      for event in events where event.kind != CaptureKind.gitCheckout {
        guard let state = stateByNodeID[event.nodeID] else { continue }
        let text: String?
        switch event.kind {
        // LLM-enriched prose — gate it: degenerate model output ("[]", a bare "/") is not content.
        case CaptureKind.ccSession: text = event.workSummary.flatMap { isSearchable($0) ? $0 : nil }
        // Human-authored (a git commit subject). NOT gated — "wip" and "fix ci" are real, short work.
        default: text = event.summary.isEmpty ? nil : event.summary
        }
        guard let text else { continue }
        guard seenTextsByNode[event.nodeID, default: []].insert(text).inserted else { continue }
        out.append(.init(itemID: event.id.uuidString, kind: "event", nodeID: event.nodeID.uuidString,
                         state: state, text: text))
      }
```

Also update the doc comment on `EmbeddableCorpus` (above `isSearchable`) to state the two hygiene rules.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `./scripts/test.sh --filter gather` → PASS
Run: `./scripts/test.sh` → the whole suite passes (the semantic indexer/query tests use `gather`; if one now sees fewer events, fix the *test fixture*, not the rule).

- [ ] **Step 5: Commit**

```bash
git add Sources/PensieveKit/Semantic/EmbeddableItem.swift Tests/PensieveKitTests/SemanticIndexerTests.swift
git commit -F - <<'EOF'
feat: P1 corpus hygiene — drop git.checkout events, per-node de-dup

Skips git.checkout events (no work content) and de-duplicates identical
event texts within a node, keeping the earliest by (occurredAt, id).

De-dup is per-node rather than global on purpose: collapsing a shared
commit subject across projects would silently decide which project owns
the only findable copy. Ordering is explicit because Event.all has none.
EOF
```

---

## Task 2: Re-baseline the P1 measurement (and make the corpus extract reproducible)

**Files:**
- Create: `Tests/PensieveKitTests/CorpusDumpGenerator.swift`
- Modify: `docs/superpowers/measurements/2026-07-28-retrieval-recall/rprobe.swift:98` (the `tok` function)
- Modify: `docs/superpowers/measurements/2026-07-28-retrieval-recall/rprobe4.swift` (its hygiene rule → per-node)
- Modify: `docs/superpowers/measurements/2026-07-28-retrieval-recall/README.md`
- Modify: `docs/superpowers/specs/2026-07-28-retrieval-eval-harness-design.md` (§Verification gate step 1)

**Interfaces:**
- Consumes: `EmbeddableCorpus.gather` from Task 1.
- Produces: a recorded **post-P1 P@1 baseline number** that Task 13 holds P2′ to. No production API.

**Context an implementer needs.** The spec's §Verification gate is a two-step gate and this is step 1. `0.433` was measured under *global* de-dup and is no longer the shipped rule, so it is a historical figure, not a target. Two prerequisites have to be fixed before the number means anything:

1. **`corpus.jsonl` has no generator.** The README says to regenerate it through `EmbeddableCorpus.gather`, but nothing does — the original extract was produced ad hoc and the method is lost. That is precisely the failure mode §Evidence exists to prevent, so this task adds a real generator. It must go through `gather` (not a hand-rolled SQL mirror) or eval and production diverge.
2. **The probes' tokenizer doesn't match the shipped one.** They `lowercased()` and keep `ä`; FTS5's `remove_diacritics 2` folds it to `a`. Fold in the probe.

**Privacy:** `corpus.jsonl` is real work text. Write it under `$PENSIEVE_MEASURE_DIR` (a scratch dir), never into the repo, and delete it after the run. `.eval/` is gitignored; the measurements directory is not.

- [ ] **Step 1: Write the env-guarded corpus generator**

Create `Tests/PensieveKitTests/CorpusDumpGenerator.swift`:

```swift
import Foundation
import Testing
import SQLiteData
@testable import PensieveKit

/// NOT a test — a guarded generator for the retrieval measurement probes, which need the real
/// corpus as JSONL and must get it from `EmbeddableCorpus.gather` verbatim (a hand-rolled SQL
/// mirror would reintroduce exactly the eval/production divergence reusing `gather` prevents).
///
/// No-ops unless BOTH env vars are set, so it never runs in CI or an ordinary suite run:
///   PENSIEVE_MEASURE_DIR   destination directory for corpus.jsonl
///   PENSIEVE_MEASURE_DB    a VACUUM INTO snapshot of the canonical store (NOT the live file:
///                          it is WAL-mode, and a plain copy silently drops uncheckpointed rows)
///
/// Usage:
///   sqlite3 ~/Library/Application\ Support/Pensieve/pensieve.sqlite \
///     "VACUUM INTO '/tmp/measure/snapshot.sqlite'"
///   PENSIEVE_MEASURE_DIR=/tmp/measure PENSIEVE_MEASURE_DB=/tmp/measure/snapshot.sqlite \
///     ./scripts/test.sh --filter dumpCorpusForMeasurement
///
/// The output is real work text. Delete it when the measurement run is done.
@Test func dumpCorpusForMeasurement() throws {
  let environment = ProcessInfo.processInfo.environment
  guard let directory = environment["PENSIEVE_MEASURE_DIR"],
        let snapshotPath = environment["PENSIEVE_MEASURE_DB"] else { return }

  let database = try openCanonicalDatabase(at: URL(fileURLWithPath: snapshotPath))
  let corpus = try EmbeddableCorpus.gather(database)

  var lines: [String] = []
  let encoder = JSONEncoder()
  encoder.outputFormatting = .sortedKeys
  for item in corpus {
    let record = ["kind": item.kind, "itemID": item.itemID, "nodeID": item.nodeID,
                  "state": item.state, "text": item.text, "files": item.files]
    lines.append(String(data: try encoder.encode(record), encoding: .utf8) ?? "")
  }
  let destination = URL(fileURLWithPath: directory).appendingPathComponent("corpus.jsonl")
  try lines.joined(separator: "\n").write(to: destination, atomically: true, encoding: .utf8)

  var counts: [String: Int] = [:]
  for item in corpus { counts[item.kind, default: 0] += 1 }
  print("corpus.jsonl written: \(corpus.count) items \(counts.sorted { $0.key < $1.key })")
}
```

> **Ordering note:** `item.files` does not exist until Task 3. Run this task's *measurement* now with the `files` key omitted, or run Task 3 first and keep the line as written. If you run Task 2 before Task 3, drop `"files": item.files` from the record and add it back in Task 3.

- [ ] **Step 2: Fold diacritics in the probe tokenizer**

In `docs/superpowers/measurements/2026-07-28-retrieval-recall/rprobe.swift`, replace `tok`:

```swift
// Matches the shipped FTS5 tokenizer: `unicode61 remove_diacritics 2`, unstemmed.
// The ≥2-char filter is a probe-only divergence (FTS5 indexes 1-char tokens); immaterial to ranking.
func tok(_ s: String) -> [String] {
  s.folding(options: [.diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    .lowercased()
    .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
    .map(String.init)
    .filter { $0.count >= 2 }
}
```

Apply the identical change to the `tok` in `rprobe2.swift`, `rprobe3.swift` and `rprobe4.swift` if they define their own (grep: `func tok(`).

- [ ] **Step 3: Make rprobe4's hygiene rule match the shipped one**

`rprobe4.swift` currently models global de-dup. Change its de-dup to key on `(nodeID, text)` instead of `text` alone, keeping the first occurrence in file order (the generator writes `gather` order, which is now deterministic). Leave the `git.checkout` rule as-is.

- [ ] **Step 4: Generate the snapshot and run the probes**

```bash
mkdir -p /tmp/measure
sqlite3 ~/Library/Application\ Support/Pensieve/pensieve.sqlite "VACUUM INTO '/tmp/measure/snapshot.sqlite'"
PENSIEVE_MEASURE_DIR=/tmp/measure PENSIEVE_MEASURE_DB=/tmp/measure/snapshot.sqlite \
  ./scripts/test.sh --filter dumpCorpusForMeasurement
cd docs/superpowers/measurements/2026-07-28-retrieval-recall
PENSIEVE_MEASURE_DIR=/tmp/measure swift rprobe4.swift
```

Expected: a P@1 figure for `bm25` on the cleaned corpus, somewhat **below** the historical 0.433 (per-node de-dup keeps distractors global de-dup removed). A figure far above it means the de-dup rule didn't change — re-check Step 3.

- [ ] **Step 5: Record the baseline in both documents**

In the measurements README, add a row under the composition table: the new item counts and the measured post-P1 P@1, labelled "post-P1, per-node de-dup (shipped rule)".

In the spec's §Verification gate, replace the step-1 placeholder with the actual number, and update §P1's "Measured effect" line to cite both figures (historical global, shipped per-node).

- [ ] **Step 6: Clean up the private extract**

```bash
rm -rf /tmp/measure
```

- [ ] **Step 7: Commit**

```bash
git add Tests/PensieveKitTests/CorpusDumpGenerator.swift \
        docs/superpowers/measurements/2026-07-28-retrieval-recall/ \
        docs/superpowers/specs/2026-07-28-retrieval-eval-harness-design.md
git commit -F - <<'EOF'
test: reproducible corpus extract + re-baselined P1 measurement

Adds an env-guarded generator that produces corpus.jsonl through
EmbeddableCorpus.gather (the extract previously had no generator at all).
Folds diacritics in the probe tokenizer to match the shipped FTS5
unicode61 remove_diacritics 2, and switches rprobe4 to per-node de-dup.

Records the post-P1 baseline that the P2 verification gate holds to.
EOF
```

---

## Task 3: `EmbeddableItem.files` — changed-file paths join the corpus

**Files:**
- Modify: `Sources/PensieveKit/Semantic/EmbeddableItem.swift` (struct + `gather`)
- Test: `Tests/PensieveKitTests/SemanticIndexerTests.swift`

**Interfaces:**
- Consumes: Task 1's `gather`.
- Produces: `EmbeddableItem.files: String` (newline-joined paths, `""` for non-events and for commits with none). `EmbeddableItem.init(itemID:kind:nodeID:state:text:files:)` with `files` defaulted to `""` so existing call sites keep compiling.

**Context an implementer needs.** `Ingester.swift:93` already writes `{"hash":…,"branch":…,"files":…}` into `Event.detailJSON`, where `files` is a newline-joined string (`Ingester.swift:392`). Nothing reads it. **The semantic path must ignore `files`** — file paths must never enter embedded text, and `contentHash` must keep hashing `text` alone so adding paths does not force a full re-embed of the corpus.

- [ ] **Step 1: Write the failing test**

```swift
@Test func gatherCarriesChangedFilePathsOnCommitEvents() async throws {
  let database = try openCanonicalDatabase(at: tempURL("gather-files"))
  let node = Node(name: "Pensieve", kind: NodeKind.project)
  let source = Source(nodeID: node.id, kind: SourceKind.gitRepo, key: "/p/\(node.id)")
  let detail = #"{"hash":"abc","branch":"main","files":"Sources/A.swift\nSources/B.swift"}"#
  try await database.write { database in
    try Node.insert { node }.execute(database)
    try Source.insert { source }.execute(database)
    try Event.insert {
      Event(nodeID: node.id, sourceID: source.id, occurredAt: Date(),
            kind: CaptureKind.gitCommit, summary: "add the parser",
            detailJSON: detail, fingerprint: "c1")
    }.execute(database)
    try Event.insert {
      Event(nodeID: node.id, sourceID: source.id, occurredAt: Date(),
            kind: CaptureKind.ccSession, summary: "session",
            detailJSON: "{}", workSummary: "worked on the parser for a while", fingerprint: "s1")
    }.execute(database)
  }
  let corpus = try EmbeddableCorpus.gather(database)
  let commit = corpus.first { $0.text == "add the parser" }
  #expect(commit?.files == "Sources/A.swift\nSources/B.swift")
  #expect(corpus.first { $0.kind == "node" }?.files == "")
  #expect(corpus.first { $0.text.contains("worked on the parser") }?.files == "")
}

@Test func contentHashIgnoresFilesSoPathsNeverForceAReEmbed() {
  let withoutFiles = EmbeddableItem(itemID: "i", kind: "event", nodeID: "n", state: "active",
                                    text: "same text")
  let withFiles = EmbeddableItem(itemID: "i", kind: "event", nodeID: "n", state: "active",
                                 text: "same text", files: "Sources/A.swift")
  #expect(withoutFiles.contentHash == withFiles.contentHash)
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `./scripts/test.sh --filter Files`
Expected: FAIL to compile — `EmbeddableItem` has no `files` parameter.

- [ ] **Step 3: Implement**

In `EmbeddableItem`:

```swift
public struct EmbeddableItem: Sendable {
  public let itemID: String, kind: String, nodeID: String, state: String, text: String
  /// Newline-joined changed-file paths. Events only; "" everywhere else. Indexed by the FTS5
  /// search index at weight 0.1 — the SEMANTIC path ignores this field entirely, because file
  /// paths must not enter embedded text.
  public let files: String
  public init(itemID: String, kind: String, nodeID: String, state: String, text: String,
              files: String = "") {
    self.itemID = itemID; self.kind = kind; self.nodeID = nodeID
    self.state = state; self.text = text; self.files = files
  }
  /// Stable across processes/runs (String.hashValue is per-process salted — do NOT use it here).
  /// Hashes `text` ONLY: `files` is deliberately excluded so adding path indexing does not
  /// invalidate every embedding. The search index tracks paths through its own corpus hash.
  public var contentHash: String {
    var hashAccumulator: UInt64 = 1469598103934665603            // FNV-1a
    for byte in text.utf8 { hashAccumulator = (hashAccumulator ^ UInt64(byte)) &* 1099511628211 }
    return String(hashAccumulator, radix: 16)
  }
}
```

In `gather`'s event loop, decode the paths and pass them through:

```swift
        guard let text else { continue }
        guard seenTextsByNode[event.nodeID, default: []].insert(text).inserted else { continue }
        out.append(.init(itemID: event.id.uuidString, kind: "event", nodeID: event.nodeID.uuidString,
                         state: state, text: text, files: Self.changedFiles(in: event.detailJSON)))
```

And add the decoder to `EmbeddableCorpus`:

```swift
  /// The ingester writes {"hash","branch","files"} for a commit, with `files` newline-joined.
  /// Anything else (a session's detail, malformed JSON, an absent key) yields "".
  static func changedFiles(in detailJSON: String) -> String {
    guard let data = detailJSON.data(using: .utf8),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let files = object["files"] as? String else { return "" }
    return files
  }
```

- [ ] **Step 4: Run to verify it passes**

Run: `./scripts/test.sh --filter Files` → PASS
Run: `./scripts/test.sh` → whole suite passes.

- [ ] **Step 5: Commit**

```bash
git add Sources/PensieveKit/Semantic/EmbeddableItem.swift Tests/PensieveKitTests/SemanticIndexerTests.swift
git commit -F - <<'EOF'
feat: carry changed-file paths on corpus events

EmbeddableItem gains a defaulted `files` field, decoded from the
detailJSON the ingester already writes. The semantic path ignores it and
contentHash still hashes text alone, so paths never force a re-embed.
EOF
```

---

## Task 4: `FTSQueryBuilder` — user input never reaches `MATCH` raw

**Files:**
- Create: `Sources/PensieveKit/Search/FTSQuery.swift`
- Test: `Tests/PensieveKitTests/FTSQueryTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces:
  ```swift
  public struct FTSQuery: Equatable, Sendable {
    public let match: String     // the MATCH expression, every term a quoted string literal
    public let terms: [String]   // bare terms, for snippet highlighting
  }
  public enum FTSQueryBuilder {
    public static func build(_ raw: String, file: String? = nil) -> FTSQuery?
  }
  ```

**Context an implementer needs.** FTS5 `MATCH` is a query language, and every one of these ordinary inputs is a **verified** hard error when passed raw (measured against SQLite 3.51.0):

| raw input | error |
|---|---|
| `don't` | `fts5: syntax error near "'"` |
| `C++` | `fts5: syntax error near "+"` |
| `a:b` | `no such column: a` |
| `"unbalanced` | `unterminated string` |
| `*` | `unknown special query:` |

Also verified: a quoted literal of pure punctuation (`"+++"`) matches nothing but does **not** error; `""` likewise; `"backg"*` is a valid prefix query; `files : "syncrunner"` is FTS5's own column-filter syntax and matches path segments.

Rules:
- Split into balanced quoted phrases and whitespace-separated bare terms. An unterminated `"` takes the rest of the input as one phrase (rather than erroring).
- A bare term with a leading `files:` (case-insensitive) is routed to the `files` column.
- Every term is emitted as `"…"` with internal `"` doubled — that disables all operator interpretation.
- Terms are ANDed explicitly.
- Append `*` to the **last** term only, and only when the raw input did not end in whitespace (the as-you-type prefix idiom).
- Return `nil` when nothing survives, so a pointless or malformed `MATCH` is never executed.
- The `file:` parameter (structured, from MCP) is added as an additional ANDed `files`-column term, so the caller never constructs syntax.

- [ ] **Step 1: Write the failing tests**

Create `Tests/PensieveKitTests/FTSQueryTests.swift`:

```swift
import Testing
@testable import PensieveKit

@Suite struct FTSQueryTests {
  @Test func singleTermGetsQuotedAndPrefixed() {
    #expect(FTSQueryBuilder.build("pens")?.match == "\"pens\"*")
  }

  @Test func trailingSpaceMeansTheWordIsFinishedSoNoPrefix() {
    #expect(FTSQueryBuilder.build("pensieve ")?.match == "\"pensieve\"")
  }

  @Test func multipleTermsAreAndedAndOnlyTheLastIsAPrefix() {
    #expect(FTSQueryBuilder.build("focus filter spot")?.match
            == "\"focus\" AND \"filter\" AND \"spot\"*")
  }

  @Test func apostropheIsNeutralised() {
    let built = FTSQueryBuilder.build("don't ")
    #expect(built?.match == "\"don't\"")
    #expect(built?.terms == ["don't"])
  }

  @Test func embeddedDoubleQuoteIsDoubled() {
    #expect(FTSQueryBuilder.build("say \"hi ")?.match == "\"say\" AND \"hi\"")
  }

  @Test func operatorCharactersAreLiteral() {
    #expect(FTSQueryBuilder.build("C++ ")?.match == "\"C++\"")
    #expect(FTSQueryBuilder.build("a:b ")?.match == "\"a:b\"")
    #expect(FTSQueryBuilder.build("* ")?.match == "\"*\"")
  }

  @Test func balancedPhraseStaysOnePhrase() {
    #expect(FTSQueryBuilder.build("\"background sync\" ")?.match == "\"background sync\"")
  }

  @Test func unbalancedQuoteTakesTheRestAsOnePhrase() {
    #expect(FTSQueryBuilder.build("\"background sync")?.match == "\"background sync\"*")
  }

  @Test func filesPrefixRoutesToTheFilesColumn() {
    #expect(FTSQueryBuilder.build("files:SemanticQueries.swift ")?.match
            == "files : \"SemanticQueries.swift\"")
  }

  @Test func structuredFileParameterIsAndedIn() {
    let built = FTSQueryBuilder.build("refactor ", file: "Sources/A.swift")
    #expect(built?.match == "\"refactor\" AND files : \"Sources/A.swift\"")
  }

  @Test func structuredFileParameterAloneIsAValidQuery() {
    #expect(FTSQueryBuilder.build("", file: "Sources/A.swift")?.match == "files : \"Sources/A.swift\"")
  }

  @Test func emptyAndWhitespaceOnlyYieldNil() {
    #expect(FTSQueryBuilder.build("") == nil)
    #expect(FTSQueryBuilder.build("   ") == nil)
    #expect(FTSQueryBuilder.build("\"\"") == nil)
  }

  @Test func termsAreExposedForSnippetHighlighting() {
    #expect(FTSQueryBuilder.build("focus filter")?.terms == ["focus", "filter"])
  }

  @Test func unicodeInputSurvives() {
    #expect(FTSQueryBuilder.build("Lösung ")?.match == "\"Lösung\"")
    #expect(FTSQueryBuilder.build("設計 ")?.match == "\"設計\"")
    #expect(FTSQueryBuilder.build("🐛 ")?.match == "\"🐛\"")
  }
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `./scripts/test.sh --filter FTSQuery`
Expected: FAIL to compile — no such type `FTSQueryBuilder`.

- [ ] **Step 3: Implement**

Create `Sources/PensieveKit/Search/FTSQuery.swift`:

```swift
import Foundation

/// A safe FTS5 `MATCH` expression plus the bare terms behind it (for snippet highlighting).
public struct FTSQuery: Equatable, Sendable {
  public let match: String
  public let terms: [String]
  public init(match: String, terms: [String]) { self.match = match; self.terms = terms }
}

/// Turns raw user input into an FTS5 `MATCH` expression. Pure — no I/O, no database.
///
/// FTS5 `MATCH` is a query language, so ordinary typing is hostile input: `don't`, `C++`, `a:b`,
/// an unbalanced `"`, and a lone `*` each throw a hard SQLite error when passed raw. Every term
/// therefore leaves here as a double-quoted FTS5 string literal (internal quotes doubled), which
/// disables all operator interpretation. Nothing else may build a MATCH expression.
public enum FTSQueryBuilder {
  private static let filesColumn = "files"
  private static let filesPrefix = "files:"

  public static func build(_ raw: String, file: String? = nil) -> FTSQuery? {
    var clauses: [String] = []
    var terms: [String] = []
    let parsed = parse(raw)

    for (index, token) in parsed.tokens.enumerated() {
      let isLast = index == parsed.tokens.count - 1
      // Prefix-match the final term as the user types, unless they finished the word with a space
      // or closed a quoted phrase, and never when a structured `file:` clause follows it.
      let prefixed = isLast && parsed.allowsTrailingPrefix && file == nil
      let literal = quoted(token.text) + (prefixed ? "*" : "")
      clauses.append(token.column == nil ? literal : "\(token.column!) : \(literal)")
      terms.append(token.text)
    }
    if let file, !file.trimmingCharacters(in: .whitespaces).isEmpty {
      clauses.append("\(filesColumn) : \(quoted(file))")
      terms.append(file)
    }
    guard !clauses.isEmpty else { return nil }
    return FTSQuery(match: clauses.joined(separator: " AND "), terms: terms)
  }

  private struct Token { let text: String; let column: String? }
  private struct Parsed { let tokens: [Token]; let allowsTrailingPrefix: Bool }

  private static func parse(_ raw: String) -> Parsed {
    var tokens: [Token] = []
    var index = raw.startIndex
    var endedOnClosedPhraseOrSpace = raw.isEmpty || raw.last == " "

    while index < raw.endIndex {
      let character = raw[index]
      if character == " " || character == "\t" || character == "\n" {
        index = raw.index(after: index)
        continue
      }
      if character == "\"" {
        // A balanced phrase ends at the next quote; an unbalanced one takes the rest of the input,
        // so a half-typed quote degrades into a phrase search instead of a SQLite error.
        let afterOpen = raw.index(after: index)
        if let close = raw[afterOpen...].firstIndex(of: "\"") {
          let phrase = String(raw[afterOpen..<close])
          if !phrase.isEmpty { tokens.append(Token(text: phrase, column: nil)) }
          index = raw.index(after: close)
          endedOnClosedPhraseOrSpace = true
        } else {
          let phrase = String(raw[afterOpen...])
          if !phrase.isEmpty { tokens.append(Token(text: phrase, column: nil)) }
          index = raw.endIndex
          endedOnClosedPhraseOrSpace = false
        }
        continue
      }
      let wordEnd = raw[index...].firstIndex(where: { $0 == " " || $0 == "\t" || $0 == "\n" })
        ?? raw.endIndex
      let word = String(raw[index..<wordEnd])
      if word.lowercased().hasPrefix(filesPrefix) {
        let value = String(word.dropFirst(filesPrefix.count))
        if !value.isEmpty { tokens.append(Token(text: value, column: filesColumn)) }
      } else if !word.isEmpty {
        tokens.append(Token(text: word, column: nil))
      }
      index = wordEnd
    }
    // A `files:` token is a column filter, not a word being typed — never prefix it.
    let lastIsColumnFiltered = tokens.last?.column != nil
    return Parsed(tokens: tokens,
                  allowsTrailingPrefix: !endedOnClosedPhraseOrSpace && !lastIsColumnFiltered)
  }

  /// An FTS5 string literal: wrap in double quotes, doubling any internal double quote.
  private static func quoted(_ text: String) -> String {
    "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\""
  }
}
```

- [ ] **Step 4: Run to verify they pass**

Run: `./scripts/test.sh --filter FTSQuery` → PASS

If `unbalancedQuoteTakesTheRestAsOnePhrase` disagrees on the trailing `*`, note the intent: an unterminated phrase is still being typed, so it *is* prefixed; a closed phrase is not.

- [ ] **Step 5: Commit**

```bash
git add Sources/PensieveKit/Search/FTSQuery.swift Tests/PensieveKitTests/FTSQueryTests.swift
git commit -F - <<'EOF'
feat: pure FTS5 query builder — raw input never reaches MATCH

Every term leaves as a quoted FTS5 string literal, so apostrophes, C++,
colons, unbalanced quotes and a lone asterisk stop being hard SQLite
errors. Supports FTS5's own files: column filter and a structured file
parameter, plus as-you-type prefixing of the final term.
EOF
```

---

## Task 5: `SearchIndexStore` — the FTS5 index

**Files:**
- Create: `Sources/PensieveKit/Search/SearchIndexStore.swift`
- Create: `Sources/PensieveKit/Query/SearchHit.swift`
- Modify: `Sources/PensieveKit/Support/PensievePaths.swift`
- Test: `Tests/PensieveKitTests/SearchIndexStoreTests.swift`

**Interfaces:**
- Consumes: `FTSQuery` (Task 4), `EmbeddableItem` (Task 3).
- Produces:
  ```swift
  public enum SearchIndexState: String, Sendable { case absent, building, ready }

  public struct SearchIndexHit: Sendable {
    public let itemID: String, kind: String, nodeID: String, state: String, score: Double
  }

  public struct SearchIndexStore: Sendable {
    public init(url: URL)
    public var isAvailable: Bool { get }
    public func state() -> SearchIndexState
    public func storedCorpusHash() -> String?
    public func rebuild(items: [EmbeddableItem], corpusHash: String)
    public func search(_ query: FTSQuery, limit: Int, includeArchived: Bool) -> [SearchIndexHit]
  }

  // PensievePaths
  public static func searchIndexURL() -> URL
  ```

**Context an implementer needs.** Model this on `SemanticIndexStore` — same best-effort shape (a corrupt file is deleted and retried once, then the store disables itself and every operation no-ops), same `busyMode = .timeout(5)` for cross-process contention (app / daemon / CLI / MCP all open it). **Differences:** no sqlite-vec, so no `prepareDatabase` hook and no C import; no incremental reconciliation, so no `items`/`existingItems` bookkeeping — `rebuild` drops and reinserts everything in one transaction.

Verified FTS5 facts to rely on: `bm25()` returns negative, best-first ascending, so return `-bm25(...)`; `UNINDEXED` columns are still stored and filterable in `WHERE`; weights are positional over *all* columns and default to 1.0, so `bm25(documents, 1.0, 0.1)` correctly weights `text` and `files` and leaves the UNINDEXED ones inert.

`state()` semantics: `.absent` when the store failed to open or `meta` holds no corpus hash (never built); `.building` when a rebuild is in flight (a `building` flag row); `.ready` otherwise.

- [ ] **Step 1: Write the failing tests**

Create `Tests/PensieveKitTests/SearchIndexStoreTests.swift`:

```swift
import Testing
import Foundation
@testable import PensieveKit

@Suite struct SearchIndexStoreTests {
  private func tempStore() -> SearchIndexStore {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("search-\(UUID().uuidString).sqlite")
    return SearchIndexStore(url: url)
  }

  private func item(_ itemID: String, _ text: String, files: String = "",
                    kind: String = "event", nodeID: String = "n1",
                    state: String = "active") -> EmbeddableItem {
    EmbeddableItem(itemID: itemID, kind: kind, nodeID: nodeID, state: state,
                   text: text, files: files)
  }

  @Test func freshStoreIsAvailableAndAbsent() {
    let store = tempStore()
    #expect(store.isAvailable)
    #expect(store.state() == .absent)
    #expect(store.storedCorpusHash() == nil)
  }

  @Test func rebuildMakesItReadyAndSearchable() {
    let store = tempStore()
    store.rebuild(items: [item("a", "background sync agent login items")], corpusHash: "h1")
    #expect(store.state() == .ready)
    #expect(store.storedCorpusHash() == "h1")
    let query = FTSQueryBuilder.build("background sync ")!
    #expect(store.search(query, limit: 10, includeArchived: false).map(\.itemID) == ["a"])
  }

  @Test func rebuildIsIdempotentAndReplacesRatherThanAppends() {
    let store = tempStore()
    store.rebuild(items: [item("a", "alpha")], corpusHash: "h1")
    store.rebuild(items: [item("a", "alpha")], corpusHash: "h1")
    let query = FTSQueryBuilder.build("alpha ")!
    #expect(store.search(query, limit: 10, includeArchived: false).count == 1)

    store.rebuild(items: [item("b", "beta")], corpusHash: "h2")
    #expect(store.search(query, limit: 10, includeArchived: false).isEmpty)
    #expect(store.storedCorpusHash() == "h2")
  }

  /// Pins the 0.1 `files` weight: a term matching in `text` must outrank the same term matching
  /// only in `files`. Measured on SQLite 3.51.0: 1.13e-06 vs 1.42e-07.
  @Test func textMatchOutranksFilesOnlyMatch() {
    let store = tempStore()
    store.rebuild(items: [item("text-match", "refactor the parser today"),
                          item("files-match", "unrelated commit subject",
                               files: "Sources/parser/Lexer.swift")],
                  corpusHash: "h")
    let hits = store.search(FTSQueryBuilder.build("parser ")!, limit: 10, includeArchived: false)
    #expect(hits.map(\.itemID) == ["text-match", "files-match"])
    #expect(hits[0].score > hits[1].score)
  }

  @Test func archivedIsExcludedByDefaultAndIncludedOnRequest() {
    let store = tempStore()
    store.rebuild(items: [item("live", "shared phrase", nodeID: "n1", state: "active"),
                          item("old", "shared phrase", nodeID: "n2", state: "archived"),
                          item("hidden", "shared phrase", nodeID: "n3", state: "muted")],
                  corpusHash: "h")
    let query = FTSQueryBuilder.build("shared ")!
    #expect(store.search(query, limit: 10, includeArchived: false).map(\.itemID) == ["live"])
    let widened = Set(store.search(query, limit: 10, includeArchived: true).map(\.itemID))
    #expect(widened == ["live", "old"])   // muted is excluded in BOTH modes — allow-list, never deny-list
  }

  @Test func filesColumnIsSearchableByPathSegment() {
    let store = tempStore()
    store.rebuild(items: [item("a", "unrelated subject", files: "Sources/PensieveKit/Sync/SyncRunner.swift")],
                  corpusHash: "h")
    #expect(store.search(FTSQueryBuilder.build("syncrunner ")!, limit: 10,
                         includeArchived: false).map(\.itemID) == ["a"])
    #expect(store.search(FTSQueryBuilder.build("files:syncrunner ")!, limit: 10,
                         includeArchived: false).map(\.itemID) == ["a"])
  }

  @Test func diacriticsAreFoldedBothWays() {
    let store = tempStore()
    store.rebuild(items: [item("a", "Lösung für Umlaute")], corpusHash: "h")
    #expect(store.search(FTSQueryBuilder.build("losung ")!, limit: 10,
                         includeArchived: false).map(\.itemID) == ["a"])
    #expect(store.search(FTSQueryBuilder.build("Lösung ")!, limit: 10,
                         includeArchived: false).map(\.itemID) == ["a"])
  }

  @Test func hostileInputReturnsEmptyRatherThanThrowing() {
    let store = tempStore()
    store.rebuild(items: [item("a", "ordinary text")], corpusHash: "h")
    for raw in ["don't ", "C++ ", "a:b ", "\"unbalanced", "* ", "+++ "] {
      guard let query = FTSQueryBuilder.build(raw) else { continue }
      #expect(store.search(query, limit: 10, includeArchived: false).isEmpty)
    }
  }

  @Test func limitCapsResults() {
    let store = tempStore()
    let items = (0..<20).map { item("i\($0)", "common word \($0)") }
    store.rebuild(items: items, corpusHash: "h")
    #expect(store.search(FTSQueryBuilder.build("common ")!, limit: 5,
                         includeArchived: false).count == 5)
  }
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `./scripts/test.sh --filter SearchIndexStore`
Expected: FAIL to compile — no such type `SearchIndexStore`.

- [ ] **Step 3: Add the path and the hit/state types**

In `Sources/PensieveKit/Support/PensievePaths.swift`, after `semanticIndexURL()`:

```swift
  /// The disposable, device-local, never-synced FTS5 search index (shared across app / CLI /
  /// daemon / MCP). Separate from the semantic index on purpose: that one drops and rebuilds its
  /// whole database on an embedder-version change, which has nothing to do with search.
  public static func searchIndexURL() -> URL {
    supportDirectory().appendingPathComponent("search-index.sqlite")
  }
```

Create `Sources/PensieveKit/Query/SearchHit.swift`:

```swift
import Foundation

/// Whether the search index can answer at all. Distinct from "no matches" — after BM25 became the
/// single retrieval path, an unbuilt index and a genuinely empty result set would otherwise render
/// identically, and the user would read a broken index as "you never worked on that".
public enum SearchIndexState: String, Sendable, Equatable {
  case absent     // never built, or the store could not be opened
  case building   // a rebuild is in flight
  case ready
}

/// One search result. Both engines return this: BM25 (the shipped path) and the vector index
/// (default-off, experimental). The name deliberately does not claim an engine — `score` is
/// whatever the producing engine ranks by, and is NEVER comparable across engines.
public struct SearchHit: Identifiable, Sendable, Equatable {
  public let id: UUID           // node id / loose-end id / event id
  public let kind: String       // "node" | "loose_end" | "event"
  public let nodeID: UUID
  public let nodeName: String
  public let title: String      // node name / loose-end text / event summary
  public let snippet: Snippet
  /// Higher is better. BM25 hits carry `-bm25(...)`; a pinned Top Hit carries nil (it did not come
  /// from the ranking, and a comparable-looking number would invite exactly the cross-scale
  /// confusion the spec removes).
  public let score: Double?
  /// The owning node is archived — the view badges the row. Always false unless the caller opted in.
  public let isArchived: Bool

  public init(id: UUID, kind: String, nodeID: UUID, nodeName: String, title: String,
              snippet: Snippet, score: Double?, isArchived: Bool) {
    self.id = id; self.kind = kind; self.nodeID = nodeID; self.nodeName = nodeName
    self.title = title; self.snippet = snippet; self.score = score; self.isArchived = isArchived
  }
}
```

- [ ] **Step 4: Implement the store**

Create `Sources/PensieveKit/Search/SearchIndexStore.swift`:

```swift
import Foundation
import SQLiteData   // re-exports GRDB
import GRDB

public struct SearchIndexHit: Sendable {
  public let itemID: String, kind: String, nodeID: String, state: String, score: Double
}

/// A small, disposable, device-local FTS5 index over the same corpus the semantic index uses
/// (shared across app / CLI / daemon / MCP). Deliberately NOT the canonical store — losing the
/// file costs only a rebuild, which is milliseconds for the whole corpus.
///
/// FTS5 is reached through raw SQL: it ships in the system SQLite (verified on 3.51.0), so unlike
/// sqlite-vec it needs no vendored C target and no per-connection registration. GRDB's Swift-level
/// FTS5 API is conditionally compiled and deliberately unused.
public struct SearchIndexStore: Sendable {
  private static let schemaVersion = 1
  /// Column order fixes the bm25 weights: text 1.0, files 0.1. UNINDEXED columns are still stored
  /// and filterable; their positional weights default to 1.0 and are inert (they never match).
  private static let ranking = "bm25(documents, 1.0, 0.1)"

  private let database: (any DatabaseWriter)?
  public var isAvailable: Bool { database != nil }

  /// Best-effort: on a corrupt/unopenable file, or one from an older schema, it drops and retries
  /// once; if that still fails the index disables itself (all operations no-op) and callers
  /// degrade to `state() == .absent` rather than to a silent empty result.
  public init(url: URL) {
    if let opened = Self.open(url) {
      self.database = opened
    } else {
      try? FileManager.default.removeItem(at: url)
      self.database = Self.open(url)
      if self.database == nil {
        Log.semantic.error("SearchIndexStore: failed to open index after delete-and-retry at \(url.path, privacy: .public)")
      }
    }
  }

  private static func open(_ url: URL) -> (any DatabaseWriter)? {
    do {
      try PensievePaths.ensureParentDirectory(of: url)
      var configuration = Configuration()
      configuration.busyMode = .timeout(5)   // app / daemon / CLI / MCP all open this file
      let pool = try DatabasePool(path: url.path, configuration: configuration)
      try pool.write { database in
        let storedVersion = try? Int.fetchOne(database, sql: "SELECT schema_version FROM meta")
        if storedVersion != schemaVersion {
          try database.execute(sql: "DROP TABLE IF EXISTS documents")
          try database.execute(sql: "DROP TABLE IF EXISTS meta")
        }
        try database.execute(sql: """
          CREATE VIRTUAL TABLE IF NOT EXISTS documents USING fts5(
            text, files,
            item_id UNINDEXED, kind UNINDEXED, node_id UNINDEXED, state UNINDEXED,
            tokenize = 'unicode61 remove_diacritics 2')
          """)
        try database.execute(sql: """
          CREATE TABLE IF NOT EXISTS meta(
            schema_version INT, corpus_hash TEXT, building INT NOT NULL DEFAULT 0)
          """)
        if storedVersion != schemaVersion {
          try database.execute(sql: "INSERT INTO meta(schema_version, corpus_hash, building) VALUES (?, NULL, 0)",
                               arguments: [schemaVersion])
        }
      }
      return pool
    } catch { return nil }
  }

  public func state() -> SearchIndexState {
    guard let database else { return .absent }
    // `try?` over a fetchOne makes this doubly optional (read failed vs no row) — both mean
    // "cannot answer", so flatten and treat either as absent.
    let fetched = try? database.read { database in
      try Row.fetchOne(database, sql: "SELECT corpus_hash, building FROM meta")
    }
    guard let row = fetched ?? nil else { return .absent }
    if (row["building"] as Int?) == 1 { return .building }
    return (row["corpus_hash"] as String?) == nil ? .absent : .ready
  }

  public func storedCorpusHash() -> String? {
    guard let database else { return nil }
    let fetched = try? database.read { database in
      try String.fetchOne(database, sql: "SELECT corpus_hash FROM meta")
    }
    return fetched ?? nil
  }

  /// Drop and reinsert everything in one transaction. Whole-rebuild rather than reconciliation:
  /// FTS5 insertion is cheap (the whole corpus is milliseconds), and a rebuild has no staleness
  /// bugs to reimplement. The `building` flag makes an interrupted rebuild observable instead of
  /// leaving a half-filled index that reads as `ready`.
  public func rebuild(items: [EmbeddableItem], corpusHash: String) {
    guard let database else { return }
    try? database.write { database in
      try database.execute(sql: "UPDATE meta SET building = 1")
    }
    do {
      try database.write { database in
        try database.execute(sql: "DELETE FROM documents")
        for item in items {
          try database.execute(sql: """
            INSERT INTO documents(text, files, item_id, kind, node_id, state)
            VALUES (?, ?, ?, ?, ?, ?)
            """, arguments: [item.text, item.files, item.itemID, item.kind, item.nodeID, item.state])
        }
        try database.execute(sql: "UPDATE meta SET corpus_hash = ?, building = 0",
                             arguments: [corpusHash])
      }
    } catch {
      Log.semantic.error("SearchIndexStore: rebuild failed: \(error, privacy: .public)")
      try? database.write { database in try database.execute(sql: "UPDATE meta SET building = 0") }
    }
  }

  /// `includeArchived: false` returns active items only; `true` widens to active + archived.
  /// `muted` is excluded in BOTH modes — an allow-list, never a deny-list, so a future state can
  /// never leak in by omission. The SQL fragment is chosen from a Bool (no interpolated caller
  /// input) and the MATCH expression comes from `FTSQueryBuilder`, so there is no injection surface.
  public func search(_ query: FTSQuery, limit: Int, includeArchived: Bool) -> [SearchIndexHit] {
    guard let database else { return [] }
    let stateFilter = includeArchived
      ? "AND state IN ('active','archived')"
      : "AND state = 'active'"
    return (try? database.read { database in
      try Row.fetchAll(database, sql: """
        SELECT item_id, kind, node_id, state, -\(Self.ranking) AS score
        FROM documents
        WHERE documents MATCH ? \(stateFilter)
        ORDER BY \(Self.ranking)
        LIMIT ?
        """, arguments: [query.match, limit]).map { row in
        SearchIndexHit(itemID: row["item_id"], kind: row["kind"], nodeID: row["node_id"],
                       state: row["state"], score: row["score"])
      }
    }) ?? []
  }
}
```

- [ ] **Step 5: Run to verify they pass**

Run: `./scripts/test.sh --filter SearchIndexStore` → PASS
Run: `swiftlint lint --strict` → clean.

- [ ] **Step 6: Commit**

```bash
git add Sources/PensieveKit/Search/SearchIndexStore.swift Sources/PensieveKit/Query/SearchHit.swift \
        Sources/PensieveKit/Support/PensievePaths.swift Tests/PensieveKitTests/SearchIndexStoreTests.swift
git commit -F - <<'EOF'
feat: FTS5 search index store

A derived, never-synced search-index.sqlite holding one FTS5 row per
corpus item, with text weighted 1.0 and changed-file paths 0.1. Whole
rebuild in one transaction rather than reconciliation. Reached through
raw SQL — FTS5 ships in the system SQLite, so no vendoring is needed.
EOF
```

---

## Task 6: `SearchIndexer` — hash-guarded rebuild

**Files:**
- Create: `Sources/PensieveKit/Search/SearchIndexer.swift`
- Test: `Tests/PensieveKitTests/SearchIndexerTests.swift`

**Interfaces:**
- Consumes: `EmbeddableCorpus.gather` (Tasks 1, 3), `SearchIndexStore` (Task 5).
- Produces:
  ```swift
  public struct SearchIndexer: Sendable {
    public init(store: SearchIndexStore)
    public func sync(_ database: any DatabaseReader)
    public static func corpusHash(_ items: [EmbeddableItem]) -> String
  }
  ```

**Context an implementer needs.** This runs at the seams `SemanticIndexer` already uses — after extraction in `SyncRunner`, and on app refresh. App refresh fires off the debounced `ValueObservation` + FSEvents path, so it runs on **every WAL change**, including the sync daemon's. A rebuild is milliseconds but it is still a *write*, so the hash guard is what keeps an unchanged corpus from churning the file. `sync` is **not** `async` — there is no embedder, so there is nothing to await.

The corpus hash must cover everything the index stores: `itemID`, `contentHash` (which covers `text`), `files`, `kind`, `nodeID`, `state`. Note `EmbeddableItem.contentHash` deliberately excludes `files`, so the corpus hash has to add it explicitly or a path-only change would go unnoticed.

- [ ] **Step 1: Write the failing tests**

Create `Tests/PensieveKitTests/SearchIndexerTests.swift`:

```swift
import Testing
import Foundation
import SQLiteData
@testable import PensieveKit

@Suite struct SearchIndexerTests {
  private func tempStore() -> SearchIndexStore {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("searchidx-\(UUID().uuidString).sqlite")
    return SearchIndexStore(url: url)
  }

  private func item(_ itemID: String, text: String, files: String = "",
                    state: String = "active") -> EmbeddableItem {
    EmbeddableItem(itemID: itemID, kind: "event", nodeID: "n1", state: state,
                   text: text, files: files)
  }

  @Test func corpusHashIsStableAndOrderIndependent() {
    let first = item("a", text: "alpha")
    let second = item("b", text: "beta")
    #expect(SearchIndexer.corpusHash([first, second]) == SearchIndexer.corpusHash([second, first]))
    #expect(SearchIndexer.corpusHash([first]) != SearchIndexer.corpusHash([second]))
  }

  @Test func corpusHashNoticesAFilesOnlyChange() {
    let without = item("a", text: "alpha")
    let with = item("a", text: "alpha", files: "Sources/A.swift")
    #expect(SearchIndexer.corpusHash([without]) != SearchIndexer.corpusHash([with]))
  }

  @Test func corpusHashNoticesAStateChange() {
    #expect(SearchIndexer.corpusHash([item("a", text: "alpha")])
            != SearchIndexer.corpusHash([item("a", text: "alpha", state: "archived")]))
  }

  @Test func syncBuildsTheIndexFromTheLiveCorpus() async throws {
    let database = try openCanonicalDatabase(at: tempURL("searchidx-build"))
    let node = Node(name: "Background sync agent", kind: NodeKind.project)
    try await database.write { database in try Node.insert { node }.execute(database) }
    let store = tempStore()
    SearchIndexer(store: store).sync(database)
    #expect(store.state() == .ready)
    let hits = store.search(FTSQueryBuilder.build("background ")!, limit: 10, includeArchived: false)
    #expect(hits.map(\.itemID) == [node.id.uuidString])
  }

  @Test func unchangedCorpusSkipsTheRebuild() async throws {
    let database = try openCanonicalDatabase(at: tempURL("searchidx-guard"))
    let node = Node(name: "Alpha", kind: NodeKind.project)
    try await database.write { database in try Node.insert { node }.execute(database) }
    let store = tempStore()
    let indexer = SearchIndexer(store: store)
    indexer.sync(database)
    let firstHash = store.storedCorpusHash()

    indexer.sync(database)   // nothing changed
    #expect(store.storedCorpusHash() == firstHash)

    try await database.write { database in
      try Node.insert { Node(name: "Beta", kind: NodeKind.project) }.execute(database)
    }
    indexer.sync(database)
    #expect(store.storedCorpusHash() != firstHash)
    #expect(store.search(FTSQueryBuilder.build("beta ")!, limit: 10, includeArchived: false).count == 1)
  }

  @Test func hygieneAppliesToTheSearchIndexToo() async throws {
    let database = try openCanonicalDatabase(at: tempURL("searchidx-hygiene"))
    let node = Node(name: "Pensieve", kind: NodeKind.project)
    let source = Source(nodeID: node.id, kind: SourceKind.gitRepo, key: "/p/\(node.id)")
    try await database.write { database in
      try Node.insert { node }.execute(database)
      try Source.insert { source }.execute(database)
      try Event.insert {
        Event(nodeID: node.id, sourceID: source.id, occurredAt: Date(),
              kind: CaptureKind.gitCheckout, summary: "checkout main",
              detailJSON: "{}", fingerprint: "co")
      }.execute(database)
    }
    let store = tempStore()
    SearchIndexer(store: store).sync(database)
    #expect(store.search(FTSQueryBuilder.build("checkout ")!, limit: 10,
                         includeArchived: false).isEmpty)
  }
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `./scripts/test.sh --filter SearchIndexer`
Expected: FAIL to compile — no such type `SearchIndexer`.

- [ ] **Step 3: Implement**

Create `Sources/PensieveKit/Search/SearchIndexer.swift`:

```swift
import Foundation
import SQLiteData

/// Rebuilds the FTS5 search index from the live canonical corpus. Whole-rebuild, hash-guarded.
///
/// Unlike `SemanticIndexer` there is no reconciliation: embedding is expensive, FTS5 insertion is
/// not, so a full drop-and-reinsert is both simpler and free of staleness bugs. The guard exists
/// because the app calls this on every debounced refresh — that is every WAL change, including the
/// daemon's — and an unchanged corpus should not churn the file.
///
/// Best-effort throughout: an unavailable store no-ops, a gather failure no-ops, and neither ever
/// blocks capture or ingest.
public struct SearchIndexer: Sendable {
  let store: SearchIndexStore
  public init(store: SearchIndexStore) { self.store = store }

  public func sync(_ database: any DatabaseReader) {
    guard store.isAvailable else { return }
    guard let corpus = try? EmbeddableCorpus.gather(database) else { return }
    let hash = Self.corpusHash(corpus)
    guard hash != store.storedCorpusHash() else { return }
    store.rebuild(items: corpus, corpusHash: hash)
  }

  /// FNV-1a over every field the index stores, sorted by item id so gather order cannot change the
  /// hash. `contentHash` covers `text`; `files` is folded in separately because `contentHash`
  /// deliberately excludes it (paths must never force a re-embed on the semantic side).
  public static func corpusHash(_ items: [EmbeddableItem]) -> String {
    var accumulator: UInt64 = 1469598103934665603
    func absorb(_ text: String) {
      for byte in text.utf8 { accumulator = (accumulator ^ UInt64(byte)) &* 1099511628211 }
      accumulator = (accumulator ^ 0x1F) &* 1099511628211      // field separator
    }
    for item in items.sorted(by: { $0.itemID < $1.itemID }) {
      absorb(item.itemID); absorb(item.contentHash); absorb(item.files)
      absorb(item.kind); absorb(item.nodeID); absorb(item.state)
    }
    return String(accumulator, radix: 16)
  }
}
```

- [ ] **Step 4: Run to verify they pass**

Run: `./scripts/test.sh --filter SearchIndexer` → PASS

- [ ] **Step 5: Commit**

```bash
git add Sources/PensieveKit/Search/SearchIndexer.swift Tests/PensieveKitTests/SearchIndexerTests.swift
git commit -F - <<'EOF'
feat: hash-guarded search index rebuild

Whole rebuild from EmbeddableCorpus.gather, skipped when the corpus hash
is unchanged — the app calls this on every debounced refresh, which is
every WAL change including the daemon's.
EOF
```

---

## Task 7: `SearchQueries` — the BM25 query layer, guards, and the Top Hit

**Files:**
- Rewrite: `Sources/PensieveKit/Query/SearchQueries.swift`
- Modify: `Sources/PensieveKit/Query/Snippet.swift`
- Rewrite: `Tests/PensieveKitTests/SearchQueriesTests.swift`

**Interfaces:**
- Consumes: `FTSQueryBuilder`, `SearchIndexStore`, `SearchHit`, `SearchIndexState`.
- Produces:
  ```swift
  public struct SearchScope: Sendable {
    public var visibleNodeIDs: Set<UUID>
    public var excludingIDs: Set<UUID>
    public var limit: Int
    public var includeArchived: Bool
    public init(visibleNodeIDs: Set<UUID>, excludingIDs: Set<UUID> = [],
                limit: Int = SearchQueries.resultCap, includeArchived: Bool = false)
  }

  public enum SearchQueries {
    public static let minQueryLength = 2
    public static let resultCap = 50
    public static func search(query: String, file: String? = nil, scope: SearchScope,
                              store: SearchIndexStore,
                              _ database: any DatabaseReader) -> [SearchHit]
    public static func topHit(query: String, in nodes: [Node]) -> SearchHit?
  }

  // SnippetMaker
  public static func make(from source: String, matchingAny terms: [String], window: Int = 80) -> Snippet
  ```
  `SearchResults`, `NodeHit`, `LooseEndHit` and the old `search(query:visibleNodeIDs:includeArchived:_:)` are **deleted**. Every call site breaks until Tasks 9–12 update it — that is intentional.

**Context an implementer needs.** Three things are load-bearing and must not be softened:

1. **The canonical re-resolve.** Every index hit is re-fetched from the canonical store and re-checked against the live corpus predicate (`LooseEnd.isOpen`, node `.active` or — when `includeArchived` — `.archived`). Anything failing is dropped silently as a stale index row, never returned. Copy the shape from `SemanticQueries.resolve`.
2. **The over-fetch loop has no floor exit.** `SemanticQueries` exits early when the farthest neighbour is below the floor; BM25 has no floor, so the honest termination is: stop when the index returned fewer rows than requested (exhausted), when enough hits survive, or at the 2000 cap.
3. **`topHit` scans nodes, not hits.** A node crowded out of the 50 by events is equally absent from any function of those 50. It takes the caller's already-visible, already-scoped node list, so a Focus-muted node can never be pinned above a list that excludes it.

"Word prefix" for `topHit` means the query matches at the start of the name **or** at the start of any word inside it, case- and diacritic-insensitively.

- [ ] **Step 1: Extend `SnippetMaker`**

In `Sources/PensieveKit/Query/Snippet.swift`, add below the existing `make(from:matching:)` (leave that one — the inspector and other callers use it):

```swift
  /// Highlights the first of `terms` that occurs in `source`, scanning terms in order. BM25 is
  /// unstemmed, so a matched region is always a query term or a word it prefixes — substring
  /// highlighting stays correct without parsing FTS5's own `snippet()` marker string, and the
  /// displayed text keeps coming from the canonical store rather than the index.
  public static func make(from source: String, matchingAny terms: [String],
                          window: Int = 80) -> Snippet {
    for term in terms where !term.isEmpty {
      if source.range(of: term, options: [.caseInsensitive, .diacriticInsensitive]) != nil {
        return make(from: source, matching: term, window: window)
      }
    }
    return make(from: source, matching: "", window: window)
  }
```

Note `make(from:matching:)` with an empty query returns a head window, which is the right no-match behaviour (a `files`-only hit has no term in the displayed text).

- [ ] **Step 2: Write the failing tests**

Replace the contents of `Tests/PensieveKitTests/SearchQueriesTests.swift` with:

```swift
import Foundation
import Testing
import SQLiteData
@testable import PensieveKit

@Suite struct SearchQueriesTests {
  private func tempStore() -> SearchIndexStore {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("searchq-\(UUID().uuidString).sqlite")
    return SearchIndexStore(url: url)
  }

  private func indexed(_ database: any DatabaseWriter) -> SearchIndexStore {
    let store = tempStore()
    SearchIndexer(store: store).sync(database)
    return store
  }

  private func makeEvent(_ database: any DatabaseWriter, node: Node, summary: String,
                         files: String = "") throws -> Event {
    let source = Source(nodeID: node.id, kind: SourceKind.gitRepo, key: "/p/\(node.id)-\(UUID())")
    let detail = files.isEmpty ? "{}"
      : String(data: try JSONSerialization.data(withJSONObject: ["files": files]), encoding: .utf8)!
    let event = Event(nodeID: node.id, sourceID: source.id, occurredAt: Date(),
                      kind: CaptureKind.gitCommit, summary: summary, detailJSON: detail,
                      fingerprint: UUID().uuidString)
    try database.write { database in
      try Source.insert { source }.execute(database)
      try Event.insert { event }.execute(database)
    }
    return event
  }

  @Test func shortCircuitsBelowMinLength() throws {
    let database = try openCanonicalDatabase(at: tempURL("searchq-short"))
    let store = indexed(database)
    #expect(SearchQueries.search(query: "a", scope: SearchScope(visibleNodeIDs: []),
                                 store: store, database).isEmpty)
  }

  @Test func findsANodeByName() async throws {
    let database = try openCanonicalDatabase(at: tempURL("searchq-node"))
    let node = Node(name: "Background sync agent", kind: NodeKind.project)
    try await database.write { database in try Node.insert { node }.execute(database) }
    let store = indexed(database)
    let hits = SearchQueries.search(query: "background sync ",
                                    scope: SearchScope(visibleNodeIDs: [node.id]),
                                    store: store, database)
    #expect(hits.map(\.id) == [node.id])
    #expect(hits[0].kind == "node")
    #expect((hits[0].score ?? 0) > 0)
  }

  @Test func findsAnEventTheOldSubstringMatcherCouldNotSee() async throws {
    let database = try openCanonicalDatabase(at: tempURL("searchq-event"))
    let node = Node(name: "Pensieve", kind: NodeKind.project)
    try await database.write { database in try Node.insert { node }.execute(database) }
    let event = try makeEvent(database, node: node, summary: "wire the focus filter intent")
    let store = indexed(database)
    // Multi-word, non-contiguous: the substring matcher returned nothing for this.
    let hits = SearchQueries.search(query: "focus intent ",
                                    scope: SearchScope(visibleNodeIDs: [node.id]),
                                    store: store, database)
    #expect(hits.contains { $0.id == event.id })
  }

  @Test func findsWorkByTheFilesItTouched() async throws {
    let database = try openCanonicalDatabase(at: tempURL("searchq-files"))
    let node = Node(name: "Pensieve", kind: NodeKind.project)
    try await database.write { database in try Node.insert { node }.execute(database) }
    let event = try makeEvent(database, node: node, summary: "unrelated subject",
                              files: "Sources/PensieveKit/Query/SemanticQueries.swift")
    let store = indexed(database)
    let bare = SearchQueries.search(query: "semanticqueries ",
                                    scope: SearchScope(visibleNodeIDs: [node.id]),
                                    store: store, database)
    #expect(bare.contains { $0.id == event.id })
    let structured = SearchQueries.search(query: "", file: "SemanticQueries.swift",
                                          scope: SearchScope(visibleNodeIDs: [node.id]),
                                          store: store, database)
    #expect(structured.contains { $0.id == event.id })
  }

  @Test func focusMutedNodesAreNeverReturned() async throws {
    let database = try openCanonicalDatabase(at: tempURL("searchq-mute"))
    let visible = Node(name: "Visible refunds work", kind: NodeKind.project)
    let muted = Node(name: "Muted refunds work", kind: NodeKind.project, context: "personal")
    try await database.write { database in
      try Node.insert { visible }.execute(database)
      try Node.insert { muted }.execute(database)
    }
    let store = indexed(database)
    let hits = SearchQueries.search(query: "refunds ",
                                    scope: SearchScope(visibleNodeIDs: [visible.id]),
                                    store: store, database)
    #expect(hits.map(\.nodeID) == [visible.id])
  }

  @Test func archivedIsExcludedByDefaultAndIncludedOnRequest() async throws {
    let database = try openCanonicalDatabase(at: tempURL("searchq-arch"))
    let live = Node(name: "Alpha refunds", kind: NodeKind.project)
    let old = Node(name: "Beta refunds", kind: NodeKind.project, state: .archived)
    try await database.write { database in
      try Node.insert { live }.execute(database)
      try Node.insert { old }.execute(database)
    }
    let store = indexed(database)
    let visible: Set<UUID> = [live.id, old.id]
    #expect(SearchQueries.search(query: "refunds ", scope: SearchScope(visibleNodeIDs: visible),
                                 store: store, database).map(\.nodeID) == [live.id])
    let widened = SearchQueries.search(
      query: "refunds ", scope: SearchScope(visibleNodeIDs: visible, includeArchived: true),
      store: store, database)
    #expect(Set(widened.map(\.nodeID)) == visible)
    #expect(widened.first { $0.nodeID == old.id }?.isArchived == true)
  }

  @Test func excludingIDsAreDropped() async throws {
    let database = try openCanonicalDatabase(at: tempURL("searchq-exclude"))
    let node = Node(name: "Refunds work", kind: NodeKind.project)
    try await database.write { database in try Node.insert { node }.execute(database) }
    let store = indexed(database)
    let hits = SearchQueries.search(
      query: "refunds ", scope: SearchScope(visibleNodeIDs: [node.id], excludingIDs: [node.id]),
      store: store, database)
    #expect(hits.isEmpty)
  }

  /// The last grounding defense: an index row whose canonical row is gone must never surface.
  @Test func staleIndexRowsAreDroppedByTheCanonicalReResolve() async throws {
    let database = try openCanonicalDatabase(at: tempURL("searchq-stale"))
    let node = Node(name: "Doomed refunds project", kind: NodeKind.project)
    try await database.write { database in try Node.insert { node }.execute(database) }
    let store = indexed(database)                       // index knows about it…
    try await database.write { database in              // …canonical no longer does
      try Node.delete().where { $0.id.eq(node.id) }.execute(database)
    }
    let hits = SearchQueries.search(query: "refunds ",
                                    scope: SearchScope(visibleNodeIDs: [node.id]),
                                    store: store, database)
    #expect(hits.isEmpty)
  }

  @Test func closedLooseEndsAreDroppedByTheCanonicalReResolve() async throws {
    let database = try openCanonicalDatabase(at: tempURL("searchq-closed"))
    let node = Node(name: "Pensieve", kind: NodeKind.project)
    try await database.write { database in try Node.insert { node }.execute(database) }
    let event = try makeEvent(database, node: node, summary: "session")
    let looseEnd = LooseEnd(nodeID: node.id, sourceEventID: event.id,
                            text: "revisit the refunds flow", quote: "revisit the refunds flow",
                            role: "user", label: "todo")
    try await database.write { database in try LooseEnd.insert { looseEnd }.execute(database) }
    let store = indexed(database)
    #expect(SearchQueries.search(query: "refunds ", scope: SearchScope(visibleNodeIDs: [node.id]),
                                 store: store, database).contains { $0.id == looseEnd.id })
    try await database.write { database in
      try LooseEnd.update { $0.closedAt = Date() }.where { $0.id.eq(looseEnd.id) }.execute(database)
    }
    #expect(!SearchQueries.search(query: "refunds ", scope: SearchScope(visibleNodeIDs: [node.id]),
                                  store: store, database).contains { $0.id == looseEnd.id })
  }

  @Test func resultsAreCappedAtFifty() async throws {
    let database = try openCanonicalDatabase(at: tempURL("searchq-cap"))
    let node = Node(name: "Pensieve", kind: NodeKind.project)
    try await database.write { database in try Node.insert { node }.execute(database) }
    for index in 0..<60 { _ = try makeEvent(database, node: node, summary: "refunds change \(index)") }
    let store = indexed(database)
    #expect(SearchQueries.search(query: "refunds ", scope: SearchScope(visibleNodeIDs: [node.id]),
                                 store: store, database).count == SearchQueries.resultCap)
  }

  // MARK: - Top Hit

  @Test func topHitMatchesAWordPrefixCaseAndDiacriticInsensitively() {
    let nodes = [Node(name: "Pensieve", kind: NodeKind.project),
                 Node(name: "Lösung Tracker", kind: NodeKind.project)]
    #expect(SearchQueries.topHit(query: "pens", in: nodes)?.nodeID == nodes[0].id)
    #expect(SearchQueries.topHit(query: "losung", in: nodes)?.nodeID == nodes[1].id)
    #expect(SearchQueries.topHit(query: "Tracker", in: nodes)?.nodeID == nodes[1].id)  // inner word
    #expect(SearchQueries.topHit(query: "racker", in: nodes) == nil)                   // mid-word: no
  }

  @Test func topHitCarriesNoScoreBecauseItDidNotComeFromTheRanking() {
    let nodes = [Node(name: "Pensieve", kind: NodeKind.project)]
    #expect(SearchQueries.topHit(query: "pens", in: nodes)?.score == nil)
  }

  @Test func topHitIsDeterministicAcrossEquallyGoodCandidates() {
    let nodes = [Node(name: "Refunds beta", kind: NodeKind.project),
                 Node(name: "Refunds alpha", kind: NodeKind.project)]
    #expect(SearchQueries.topHit(query: "refunds", in: nodes)?.title == "Refunds alpha")
  }

  /// The guarantee the pin exists for: a node ranked out of the capped result list is STILL
  /// offered for navigation, because topHit scans the node set rather than the returned hits.
  @Test func topHitSurvivesANodeRankedOutOfTheResultCap() async throws {
    let database = try openCanonicalDatabase(at: tempURL("searchq-tophit"))
    let target = Node(name: "Refunds", kind: NodeKind.project)
    let noisy = Node(name: "Noise", kind: NodeKind.project)
    try await database.write { database in
      try Node.insert { target }.execute(database)
      try Node.insert { noisy }.execute(database)
    }
    // 60 short event texts all containing "refunds" outrank a bare node name on BM25 length norm.
    for index in 0..<60 { _ = try makeEvent(database, node: noisy, summary: "refunds \(index)") }
    let store = indexed(database)
    let visible: Set<UUID> = [target.id, noisy.id]
    let hits = SearchQueries.search(query: "refunds ", scope: SearchScope(visibleNodeIDs: visible),
                                    store: store, database)
    let pinned = SearchQueries.topHit(query: "refunds", in: [target, noisy])
    #expect(pinned?.nodeID == target.id)
    // Whether or not `target` made the cap, the pin offers it — that IS the guarantee.
    _ = hits
  }
}
```

- [ ] **Step 3: Run to verify they fail**

Run: `./scripts/test.sh --filter SearchQueries`
Expected: FAIL to compile — the old `SearchQueries.search` signature is gone from the tests but not yet from the source.

- [ ] **Step 4: Rewrite `SearchQueries`**

Replace `Sources/PensieveKit/Query/SearchQueries.swift` entirely:

```swift
// Sources/PensieveKit/Query/SearchQueries.swift
import Foundation
import SQLiteData

/// The filters a search applies AFTER the index returns candidates: which nodes are visible under
/// the active Focus, which item ids the caller already surfaced, how many hits to keep, and whether
/// archived content is eligible.
public struct SearchScope: Sendable {
  public var visibleNodeIDs: Set<UUID>
  public var excludingIDs: Set<UUID>
  public var limit: Int
  public var includeArchived: Bool
  public init(visibleNodeIDs: Set<UUID>, excludingIDs: Set<UUID> = [],
              limit: Int = SearchQueries.resultCap, includeArchived: Bool = false) {
    self.visibleNodeIDs = visibleNodeIDs
    self.excludingIDs = excludingIDs
    self.limit = limit
    self.includeArchived = includeArchived
  }
}

/// Find across the grounded corpus: BM25 over the FTS5 index, joined back to the live canonical
/// store. This is the single retrieval path — the substring matcher it replaced could not see
/// events at all (64% of the corpus) and could not answer a multi-word query.
///
/// The index only decides which rows are ELIGIBLE. Every candidate is re-resolved against
/// canonical and re-checked against the same "is this still part of the live corpus" predicate the
/// index itself uses, so a between-sync stale row can never surface a dead hit. Best-effort: an
/// unavailable index or an untypeable query yields `[]`, never a throw.
///
/// There is no relevance floor. BM25 scores are unbounded and per-query-scaled, so a fixed cutoff
/// would be meaningless — relevance is bounded by rank plus the requirement that a document
/// actually contain the query's terms. **A rank cap is not a relevance threshold**; earning one is
/// what the paraphrase eval harness (spec P3) exists to decide.
public enum SearchQueries {
  public static let minQueryLength = 2
  public static let resultCap = 50
  private static let maxFetch = 2000

  public static func search(query rawQuery: String,
                            file: String? = nil,
                            scope: SearchScope,
                            store: SearchIndexStore,
                            _ database: any DatabaseReader) -> [SearchHit] {
    let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    let hasFile = !(file ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    guard query.count >= minQueryLength || hasFile, store.isAvailable,
          let ftsQuery = FTSQueryBuilder.build(rawQuery, file: file) else { return [] }

    // Over-fetch, and grow the window if post-index filtering (Focus-muting, exclusions, a stale
    // row) starved the result below `limit`. With no floor there is no early exit to be had: the
    // honest termination is "the index has no more rows" or the hard cap.
    var fetchCount = max(scope.limit * 8, 50)
    while true {
      let candidates = store.search(ftsQuery, limit: fetchCount, includeArchived: scope.includeArchived)
      let hits = buildHits(candidates, terms: ftsQuery.terms, scope: scope, database)
      if hits.count >= scope.limit || candidates.count < fetchCount || fetchCount >= maxFetch {
        return hits
      }
      fetchCount = min(fetchCount * 4, maxFetch)
    }
  }

  /// The node the user is most likely navigating to, selected by scanning the VISIBLE node set —
  /// never the returned hits. A node crowded out of the result cap by events is equally absent
  /// from any function of those hits, and that happens exactly on the common-term queries where
  /// navigation matters most. Callers pass their already-Focus-filtered, already-scoped nodes, so
  /// a muted node can never be pinned above a list that excludes it.
  public static func topHit(query rawQuery: String, in nodes: [Node]) -> SearchHit? {
    let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    guard query.count >= minQueryLength else { return nil }
    let match = nodes
      .filter { hasWordPrefix($0.name, prefix: query) }
      .sorted { ($0.name, $0.id.uuidString) < ($1.name, $1.id.uuidString) }
      .first
    guard let match else { return nil }
    return SearchHit(id: match.id, kind: "node", nodeID: match.id, nodeName: match.name,
                     title: match.name,
                     snippet: SnippetMaker.make(from: match.name, matching: query),
                     score: nil, isArchived: match.state == .archived)
  }

  /// True when `prefix` starts the name or starts any word inside it, case- and
  /// diacritic-insensitively. Mid-word matches do not count — "racker" is not navigation intent.
  private static func hasWordPrefix(_ name: String, prefix: String) -> Bool {
    let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive, .anchored]
    if name.range(of: prefix, options: options) != nil { return true }
    return name.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
      .contains { $0.range(of: prefix, options: options) != nil }
  }

  private static func buildHits(_ candidates: [SearchIndexHit], terms: [String],
                                scope: SearchScope, _ database: any DatabaseReader) -> [SearchHit] {
    var hits: [SearchHit] = []
    for candidate in candidates {
      guard let nodeID = UUID(uuidString: candidate.nodeID),
            scope.visibleNodeIDs.contains(nodeID) else { continue }
      guard let itemID = UUID(uuidString: candidate.itemID),
            !scope.excludingIDs.contains(itemID) else { continue }
      guard let hit = try? resolve(candidate, itemID: itemID, terms: terms,
                                   includeArchived: scope.includeArchived, database) else { continue }
      hits.append(hit)
      if hits.count == scope.limit { break }
    }
    return hits
  }

  /// Re-resolve one index row against canonical — the last grounding defense. The state predicate
  /// MUST mirror the index filter: if the index widens to archived but this does not, archived
  /// rows pass the query and are then silently dropped here.
  private static func resolve(_ candidate: SearchIndexHit, itemID: UUID, terms: [String],
                              includeArchived: Bool,
                              _ database: any DatabaseReader) throws -> SearchHit? {
    let score = candidate.score
    func eligible(_ node: Node) -> Bool {
      node.state == .active || (includeArchived && node.state == .archived)
    }
    return try database.read { database in
      switch candidate.kind {
      case "node":
        guard let node = try Node.where({ $0.id.eq(itemID) }).fetchOne(database),
              eligible(node) else { return nil }
        let body = node.description.isEmpty ? node.name : node.description
        return SearchHit(id: node.id, kind: "node", nodeID: node.id, nodeName: node.name,
                         title: node.name,
                         snippet: SnippetMaker.make(from: body, matchingAny: terms),
                         score: score, isArchived: node.state == .archived)
      case "loose_end":
        guard let looseEnd = try LooseEnd.where({ $0.id.eq(itemID) && LooseEnd.isOpen($0) })
                .fetchOne(database),
              let node = try Node.where({ $0.id.eq(looseEnd.nodeID) }).fetchOne(database),
              eligible(node) else { return nil }
        return SearchHit(id: looseEnd.id, kind: "loose_end", nodeID: looseEnd.nodeID,
                         nodeName: node.name, title: looseEnd.text,
                         snippet: SnippetMaker.make(from: looseEnd.text, matchingAny: terms),
                         score: score, isArchived: node.state == .archived)
      case "event":
        guard let event = try Event.where({ $0.id.eq(itemID) }).fetchOne(database),
              let node = try Node.where({ $0.id.eq(event.nodeID) }).fetchOne(database),
              eligible(node) else { return nil }
        let body = (event.workSummary?.isEmpty == false ? event.workSummary! : event.summary)
        return SearchHit(id: event.id, kind: "event", nodeID: event.nodeID, nodeName: node.name,
                         title: body,
                         snippet: SnippetMaker.make(from: body, matchingAny: terms),
                         score: score, isArchived: node.state == .archived)
      default: return nil
      }
    }
  }
}
```

- [ ] **Step 5: Run the new tests**

Run: `./scripts/test.sh --filter SearchQueries` → PASS

The rest of the suite will **not** build yet (`Mcp.swift`, `AppModel+Search.swift` still reference the deleted types). That is expected and is fixed in Tasks 9–12. If `./scripts/test.sh` cannot even compile the *Kit* target, that is a real failure — the app and CLI live in other targets.

- [ ] **Step 6: Commit**

```bash
git add Sources/PensieveKit/Query/SearchQueries.swift Sources/PensieveKit/Query/Snippet.swift \
        Tests/PensieveKitTests/SearchQueriesTests.swift
git commit -F - <<'EOF'
feat!: BM25 replaces the substring matcher as the search engine

SearchQueries now runs FTS5/BM25 over the search index, keeping every
grounding guard: Focus visibility, state/archived scoping, exclusions,
and the canonical re-resolve that drops stale index rows.

Top Hit scans the visible node set rather than the capped result list,
so a node crowded out by events is still offered for navigation.

SearchResults/NodeHit/LooseEndHit are deleted; call sites follow.
EOF
```

---

## Task 8: `SemanticQueries` returns `SearchHit`

**Files:**
- Modify: `Sources/PensieveKit/Query/SemanticQueries.swift`
- Modify: `Tests/PensieveKitTests/SemanticQueriesTests.swift`

**Interfaces:**
- Consumes: `SearchHit` (Task 5).
- Produces: `SemanticQueries.search(...) async -> [SearchHit]`. `SemanticHit` is deleted; `SemanticSearchScope` keeps its `floor` (the vector still has one — it is the BM25 path that has no meaningful floor).

**Context an implementer needs.** This is a mechanical type substitution, kept in its own task so a reviewer can see it is *only* that. `SemanticHit.similarity: Double` becomes `SearchHit.score: Double?` — always non-nil here. Do **not** remove the floor from the semantic path, and do not touch the over-fetch loop's floor-aware early exit: both are correct for a bounded-score engine.

- [ ] **Step 1: Update the tests first**

In `Tests/PensieveKitTests/SemanticQueriesTests.swift`, replace every `SemanticHit` with `SearchHit` and every `.similarity` read with `.score`. Where a test asserts on a similarity value, unwrap: `#expect((hits[0].score ?? 0) > 0.5)`.

- [ ] **Step 2: Run to verify they fail**

Run: `./scripts/test.sh --filter SemanticQueries`
Expected: FAIL to compile — `SemanticQueries.search` still returns `[SemanticHit]`.

- [ ] **Step 3: Implement**

In `Sources/PensieveKit/Query/SemanticQueries.swift`:
- Delete the `SemanticHit` struct entirely (it lived at the top of the file).
- Change `search`'s return type to `[SearchHit]` and `buildHits`/`resolve` likewise.
- In `resolve`, construct `SearchHit(...)` with `score: similarity` and keep every other field the same.
- Update the type's doc comment to say it returns the shared `SearchHit`, and that its `score` is a cosine similarity that is **never** comparable with a BM25 score.

- [ ] **Step 4: Run to verify they pass**

Run: `./scripts/test.sh --filter Semantic` → PASS

- [ ] **Step 5: Commit**

```bash
git add Sources/PensieveKit/Query/SemanticQueries.swift Tests/PensieveKitTests/SemanticQueriesTests.swift
git commit -F - <<'EOF'
refactor: semantic search returns the shared SearchHit type

SemanticHit is deleted; both engines now return SearchHit. The vector
keeps its similarity floor — it is BM25 that has no meaningful one.
EOF
```

---

## Task 9: Wire the indexer into `SyncRunner`

**Files:**
- Modify: `Sources/PensieveKit/Sync/SyncRunner.swift:15-22,53-63`
- Test: `Tests/PensieveKitTests/SyncRunnerTests.swift`

**Interfaces:**
- Consumes: `SearchIndexer` (Task 6).
- Produces: `SyncRunner.init(..., semanticIndexer:searchIndexer:)` — `searchIndexer` defaulted to `nil`, in which case the runner builds one over `PensievePaths.searchIndexURL()`.

**Context an implementer needs.** The search index is **not** toggle-gated — BM25 is no longer optional. Only the *semantic* refresh stays behind `PensieveDefaults.semanticSearchEnabled()`. Keep both best-effort and after the sync summary is logged, so an index failure never changes the sync result.

- [ ] **Step 1: Write the failing test**

Add to `Tests/PensieveKitTests/SyncRunnerTests.swift`:

```swift
@Test func runBuildsTheSearchIndex() async throws {
  let database = try openCanonicalDatabase(at: tempURL("sync-search-index"))
  let node = Node(name: "Background sync agent", kind: NodeKind.project)
  try await database.write { database in try Node.insert { node }.execute(database) }
  let indexURL = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("sync-search-\(UUID().uuidString).sqlite")
  let store = SearchIndexStore(url: indexURL)

  let runner = SyncRunner(spool: try makeSpool(), database: database,
                          provider: StubProvider(), projectsDir: tempDirectory(),
                          searchIndexer: SearchIndexer(store: store))
  _ = try await runner.run()

  #expect(store.state() == .ready)
  #expect(store.search(FTSQueryBuilder.build("background ")!, limit: 5,
                       includeArchived: false).map(\.itemID) == [node.id.uuidString])
}
```

Match `makeSpool()` / `StubProvider()` / `tempDirectory()` to whatever the existing `SyncRunnerTests` helpers are actually called — read the top of that file and reuse them verbatim rather than inventing new ones.

- [ ] **Step 2: Run to verify it fails**

Run: `./scripts/test.sh --filter SyncRunner`
Expected: FAIL to compile — no `searchIndexer:` parameter.

- [ ] **Step 3: Implement**

In `SyncRunner`, add the stored property and init parameter beside `semanticIndexer`:

```swift
  let semanticIndexer: SemanticIndexer?
  let searchIndexer: SearchIndexer?

  public init(spool: CaptureSpool, database: any DatabaseWriter, provider: any LLMProvider,
              projectsDir: URL, now: @escaping @Sendable () -> Date = Date.init,
              semanticIndexer: SemanticIndexer? = nil,
              searchIndexer: SearchIndexer? = nil) {
    self.spool = spool; self.database = database; self.provider = provider
    self.projectsDir = projectsDir; self.now = now
    self.semanticIndexer = semanticIndexer; self.searchIndexer = searchIndexer
  }
```

And after the existing semantic block in `run()`:

```swift
    // Search index refresh (best-effort, NOT toggle-gated — BM25 is the only retrieval path, so it
    // is never optional). Hash-guarded, so an unchanged corpus costs one read.
    if let searchIndexer {
      searchIndexer.sync(database)
    } else {
      SearchIndexer(store: SearchIndexStore(url: PensievePaths.searchIndexURL())).sync(database)
    }
```

- [ ] **Step 4: Run to verify it passes**

Run: `./scripts/test.sh --filter SyncRunner` → PASS

- [ ] **Step 5: Commit**

```bash
git add Sources/PensieveKit/Sync/SyncRunner.swift Tests/PensieveKitTests/SyncRunnerTests.swift
git commit -F - <<'EOF'
feat: build the search index during sync

Runs after extraction alongside the semantic refresh, but ungated — BM25
is the only retrieval path, so it is never optional.
EOF
```

---

## Task 10: MCP `search` — one `items` array, a structured `file` parameter, an honest index state

**Files:**
- Modify: `Sources/pensieve/Commands/Mcp.swift` (tool schema ~line 65, `searchJSON` ~line 228, `SearchPayload`/`SearchItem` ~line 274)
- Test: manual, plus the Kit tests already covering the query layer

**Interfaces:**
- Consumes: `SearchQueries.search`, `SemanticQueries.search`, `SearchIndexStore`, `SearchIndexState`.
- Produces: the `search` tool JSON contract:
  ```json
  { "items": [ { "id","kind","node_id","node_name","title","snippet","score","archived","engine" } ],
    "index_state": "ready" | "building" | "absent" }
  ```

**Context an implementer needs.** The old shape was `{"exact":[…],"related":[…]}`; it becomes one `items` array. `engine` distinguishes `"bm25"` from `"vector"` for the (default-off) experimental half, so a consumer never mistakes one score scale for the other. `index_state` is why this task matters: with the substring matcher gone, an unbuilt index and a genuine miss would otherwise be indistinguishable.

MCP has no Focus context, so the visible set is all active nodes (widened by `include_archived`) — that logic already exists in `searchJSON` and is reused unchanged. MCP ignores the Top Hit (it is a UI affordance).

Follow the existing static-caching pattern: `semanticEmbedder`/`semanticStore` are `private static let` because the MCP process is long-lived. Add `searchStore` the same way.

- [ ] **Step 1: Add the cached store and rewrite `searchJSON`**

Beside the existing statics:

```swift
  private static let searchStore = SearchIndexStore(url: PensievePaths.searchIndexURL())
```

Replace `searchJSON` with:

```swift
  /// Unified "find across my work": BM25 over the on-device FTS5 index, plus — only when the
  /// experimental vector toggle is on — semantically related items below it, excluding anything
  /// BM25 already returned. Scope is all active nodes (MCP has no Focus context), widened by
  /// `include_archived`. `index_state` distinguishes "nothing matched" from "the index isn't built",
  /// which since BM25 became the only retrieval path would otherwise read identically.
  static func searchJSON(query: String, file: String?, limit: Int,
                         includeArchived: Bool = false) async throws -> Data {
    guard let database = try? openCanonicalReadOnly() else {
      return try makeEncoder().encode(SearchPayload(items: [], indexState: .absent))
    }
    let visible = try await database.read { database -> Set<UUID> in
      let nodes = try Node.all.fetchAll(database)
      return Set(nodes.filter {
        $0.state == .active || (includeArchived && $0.state == .archived)
      }.map { $0.id })
    }
    let scope = SearchScope(visibleNodeIDs: visible, limit: limit, includeArchived: includeArchived)
    let ranked = SearchQueries.search(query: query, file: file, scope: scope,
                                      store: searchStore, database)

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
  }
```

- [ ] **Step 2: Rewrite the payload types**

```swift
/// The `search` tool's response shape. One ranked `items` array (the two-array exact/related shape
/// retired with the substring matcher), plus the index state so an unbuilt index is distinguishable
/// from a genuine miss.
private struct SearchPayload: Encodable {
  var items: [SearchItem]
  var indexState: SearchIndexState
  private enum CodingKeys: String, CodingKey {
    case items
    case indexState = "index_state"
  }
}

private struct SearchItem: Encodable {
  var id: String
  var kind: String
  var nodeID: String
  var nodeName: String
  var title: String
  var snippet: String
  /// Ranking score in the PRODUCING engine's units — a BM25 score and a cosine similarity are
  /// never comparable, which is what `engine` is here to make explicit.
  var score: Double?
  var engine: String
  var archived: Bool

  init(hit: SearchHit, engine: String) {
    id = hit.id.uuidString
    kind = hit.kind
    nodeID = hit.nodeID.uuidString
    nodeName = hit.nodeName
    title = hit.title
    snippet = hit.snippet.leading + hit.snippet.match + hit.snippet.trailing
    score = hit.score
    self.engine = engine
    archived = hit.isArchived
  }

  private enum CodingKeys: String, CodingKey {
    case id, kind, title, snippet, score, engine, archived
    case nodeID = "node_id"
    case nodeName = "node_name"
  }
}
```

`SearchIndexState` must encode as its raw string — it is already `String`-raw-representable, so add `: Codable` to its declaration in `SearchHit.swift` if the compiler asks.

- [ ] **Step 3: Update the tool schema and handler**

```swift
      Tool(name: "search",
           description: "Find across all your work — by keyword, by phrase, or by the files a commit touched. Every result is a real, cited item.",
           inputSchema: .object(["type": .string("object"), "properties": .object([
             "query": .object(["type": .string("string"), "description": .string("what to find")]),
             "file": .object(["type": .string("string"),
                              "description": .string("restrict to work that touched this file path (or any part of one)")]),
             "limit": .object(["type": .string("number"), "description": .string("max results (default 8)")]),
             "include_archived": .object(["type": .string("boolean"),
                                          "description": .string("also search archived projects (default false)")]),
           ]), "required": .array([.string("query")])]),
           annotations: .init(readOnlyHint: true, openWorldHint: false)),
```

In `handleSearch`, read `file` from `params.arguments?["file"]?.stringValue` and pass it through. Keep `query` required so the tool contract does not change shape; a caller wanting a pure file lookup passes the path as `file` and a term as `query`.

- [ ] **Step 4: Build and smoke-test the CLI**

```bash
xcodegen generate
xcodebuild -project Pensieve.xcodeproj -scheme PensieveCLI -configuration Debug \
  -derivedDataPath ./.build-xcode build 2>&1 | tail -5
```

Then exercise the tool over stdio against the real store:

```bash
printf '%s\n' \
  '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"t","version":"1"}}}' \
  '{"jsonrpc":"2.0","method":"notifications/initialized"}' \
  '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"search","arguments":{"query":"focus filter","limit":3}}}' \
  | ./.build-xcode/Build/Products/Debug/pensieve mcp 2>/dev/null | tail -1
```

Expected: one JSON result containing `"items"` and `"index_state"`. Repeat with `{"query":"sync","file":"SyncRunner.swift"}` and confirm the hits are commits that touched that file.

- [ ] **Step 5: Commit**

```bash
git add Sources/pensieve/Commands/Mcp.swift
git commit -F - <<'EOF'
feat!: MCP search returns one ranked list plus an index state

Replaces the exact/related two-array shape with a single items array,
each item tagged with the engine that produced its score. Adds a
structured file parameter so Claude never constructs query syntax, and
an index_state so an unbuilt index is distinguishable from a real miss.
EOF
```

---

## Task 11: App model — search state, index seam, default-off vector

**Files:**
- Modify: `Sources/PensieveApp/AppModel.swift:108-125` (state), `:193-200` (index seam)
- Rewrite: `Sources/PensieveApp/AppModel+Search.swift`
- Modify: `Sources/PensieveApp/AppDefaults.swift`
- Modify: `Sources/PensieveKit/Support/PensieveDefaults.swift`
- Modify: `Sources/PensieveApp/Settings/IntelligenceSettingsTab.swift`

**Interfaces:**
- Consumes: `SearchQueries.search`, `SearchQueries.topHit`, `SearchIndexStore`, `SearchIndexer`, `SearchHit`, `SearchIndexState`.
- Produces, on `AppModel`: `searchHits: [SearchHit]`, `pinnedTopHit: SearchHit?`, `semanticHits: [SearchHit]`, `searchIndexState: SearchIndexState`, `selectSearchHit(_ hit: SearchHit)`.

**Context an implementer needs.** Three homes carry the vector's default and all three must flip to **off**: `PensieveDefaults.semanticSearchEnabled()` (the cross-process reader), `AppDefaults.semanticSearchEnabled` (the non-View reader), and `IntelligenceSettingsTab`'s `@AppStorage(…) = true` (the toggle). The `@AppStorage` literal is the one that will silently disagree. An explicitly-stored `true` must keep working — only the *unset* default changes.

The search index build is **awaited**, not `Task.detached` like the semantic one: it is a millisecond-scale pure-SQL rebuild with no model to load, and awaiting it is what makes "the field is usable when it accepts input" true on first launch.

`AppModel` is `@Observable`; view-read properties must **not** be `@ObservationIgnored`. `searchStore` is infrastructure (never read by a view body) so it is ignored; `searchHits`/`pinnedTopHit`/`searchIndexState` are read by views and must be tracked.

- [ ] **Step 1: Flip the three defaults**

`PensieveDefaults.swift`:

```swift
  /// Semantic (vector) search is OFF by default. It is the experimental second engine now — BM25
  /// is the shipped retrieval path — and on this corpus the vector measured materially worse
  /// (P@1 0.250 vs 0.387). An explicitly stored `true` is still honored; only the unset default
  /// changed. Cross-process readers (the daemon, MCP) must agree with the app's @AppStorage default.
  public static func semanticSearchEnabled(_ defaults: UserDefaults = shared()) -> Bool {
    defaults.bool(forKey: semanticSearchKey)
  }
```

`AppDefaults.swift`:

```swift
  /// Semantic (vector) search is OFF by default — see PensieveDefaults.semanticSearchEnabled.
  static var semanticSearchEnabled: Bool {
    UserDefaults.standard.bool(forKey: PensieveDefaults.semanticSearchKey)
  }
```

`IntelligenceSettingsTab.swift`:

```swift
  @AppStorage(PensieveDefaults.semanticSearchKey) private var semanticSearchEnabled = false
```

Also update that toggle's label/footer copy to say it is experimental and adds a second, separately-ranked list (String Catalog keys land in Task 12).

- [ ] **Step 2: Add the store and state to `AppModel`**

Replace the `searchResults`/`semanticHits` declarations:

```swift
  /// The single ranked result list. NOT private(set): AppModel+Search.swift writes it.
  var searchHits: [SearchHit] = []
  /// The node pinned above the list for guaranteed navigation. Selected by scanning the visible
  /// node set, NOT the capped list — see SearchQueries.topHit.
  var pinnedTopHit: SearchHit?
  /// Experimental vector hits, populated below the ranked list only when the toggle is on.
  var semanticHits: [SearchHit] = []
  /// Whether the index can answer at all — distinct from "no matches", so an unbuilt index does
  /// not read as "you never worked on that".
  var searchIndexState: SearchIndexState = .absent
```

And beside `semanticStore`:

```swift
  @ObservationIgnored lazy var searchStore = SearchIndexStore(url: PensievePaths.searchIndexURL())
```

- [ ] **Step 3: Build the index on refresh**

In `drainThenRefresh()`, replace the semantic catch-up block with:

```swift
    // The search index backs the ONLY retrieval path, so it is ungated and awaited rather than
    // detached: a whole rebuild is milliseconds of pure SQL (no model to load), and awaiting it is
    // what makes the search field usable the moment it accepts input on a first launch.
    if let database {
      SearchIndexer(store: searchStore).sync(database)
      searchIndexState = searchStore.state()
    }
    // The vector index stays best-effort, detached and toggle-gated — it loads an NL asset and
    // embeds, which is far too slow to await on the UI path.
    if AppDefaults.semanticSearchEnabled, let database {
      let store = semanticStore, embedder = self.embedder
      Task.detached { await SemanticIndexer(store: store, embedder: embedder).sync(database) }
    }
```

- [ ] **Step 4: Rewrite `AppModel+Search.swift`**

```swift
// Sources/PensieveApp/AppModel+Search.swift
import Foundation
import PensieveKit

extension AppModel {
  /// The keystroke entry point (from the .searchable field). Coalesces rapid typing into one
  /// debounced DB read; an empty/whitespace field clears immediately so exiting search stays crisp.
  func searchTextChanged() {
    guard isSearching else { runSearch(); return }
    Task { await searchDebouncer.schedule() }
  }

  /// The one entry point for the actual search read (the debounced keystroke path AND the liveness
  /// refresh). Cancels the prior task; runs the read off-main; assigns results under a monotonic
  /// token so a stale keystroke can't overwrite a newer result.
  func runSearch() {
    searchTask?.cancel()
    let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard query.count >= SearchQueries.minQueryLength, let database else {
      searchHits = []
      pinnedTopHit = nil
      semanticHits = []
      expandedLooseEndID = nil   // emptying the field (any way) exits search coherently
      return
    }
    let visible = NodeContextResolver.visibleNodeIDs(for: activeFocusContext, in: allNodes)
    // Pre-Task locals: reading self off-main is an isolation violation.
    let includeArchived = (searchScope == .all)
    let rawQuery = searchText
    let scopedNodes = allNodes.filter {
      visible.contains($0.id) && ($0.state == .active || (includeArchived && $0.state == .archived))
    }
    // The pin is pure and instant — no DB, no index. Assign it before the async read so navigation
    // never waits on ranking.
    pinnedTopHit = SearchQueries.topHit(query: query, in: scopedNodes)
    searchIndexState = searchStore.state()

    searchToken += 1
    let token = searchToken
    let store = searchStore
    searchTask = Task { [weak self] in
      let hits = await Task.detached {
        SearchQueries.search(query: rawQuery,
                             scope: SearchScope(visibleNodeIDs: visible,
                                                includeArchived: includeArchived),
                             store: store, database)
      }.value
      guard let self, self.searchToken == token, !Task.isCancelled else { return }
      self.searchHits = hits

      guard AppDefaults.semanticSearchEnabled else { self.semanticHits = []; return }
      let related = await SemanticQueries.search(
        query: query,
        scope: SemanticSearchScope(visibleNodeIDs: visible, excludingIDs: Set(hits.map { $0.id }),
                                   limit: 8, floor: 0.25, includeArchived: includeArchived),
        store: self.semanticStore, embedder: self.embedder, database)
      guard self.searchToken == token, !Task.isCancelled else { return }
      self.semanticHits = related
    }
  }

  /// A node search hit: drive the detail only (the briefing-card pattern), leaving sidebarSelection
  /// so clearing the field restores a coherent middle list. Clears any pending loose-end expand.
  func selectSearchNode(_ id: UUID) {
    expandedLooseEndID = nil
    selectedNodeID = id
  }

  /// Any ranked hit. A loose end auto-expands its cited row; a node or an event drives the detail
  /// (an event's home is its node).
  func selectSearchHit(_ hit: SearchHit) {
    if hit.kind == "loose_end" {
      selectedNodeID = hit.nodeID
      expandedLooseEndID = hit.id
    } else {
      selectSearchNode(hit.nodeID)
    }
  }

  /// A Spotlight/App-Intent loose-end open: resolve the loose end → its node (read-only lookup),
  /// select the node, and mark the row to auto-expand. Degrades honestly: a deleted loose end falls
  /// back to the briefing. Window fronting is done by `applyDeepLink`.
  func openLooseEnd(_ id: UUID) {
    guard let database,
          let facts = try? LooseEndFactsQueries.facts(for: [id], database),
          let firstFact = facts.first else {
      sidebarSelection = .briefing
      selectedNodeID = nil
      expandedLooseEndID = nil
      return
    }
    sidebarSelection = .node(firstFact.nodeID)
    selectedNodeID = firstFact.nodeID
    expandedLooseEndID = firstFact.looseEndID
  }

  /// Exit search mode (e.g. on sidebar navigation): clear the field, results, and pending expand.
  func clearSearch() {
    searchText = ""
    searchHits = []
    pinnedTopHit = nil
    semanticHits = []
    expandedLooseEndID = nil
    searchTask?.cancel()
  }
}
```

Delete `selectSearchLooseEnd(_:)` and `selectSemanticHit(_:)` — `selectSearchHit` replaces both.

- [ ] **Step 5: Build**

```bash
xcodegen generate
xcodebuild -project Pensieve.xcodeproj -scheme Pensieve -configuration Debug \
  -derivedDataPath ./.build-xcode build 2>&1 | tail -20
```

Expected: errors **only** in `ContentListView.swift` (still referencing `searchResults`, `NodeHit`, `LooseEndHit`) — that is Task 12. Everything else must compile.

- [ ] **Step 6: Commit**

```bash
git add Sources/PensieveApp/AppModel.swift Sources/PensieveApp/AppModel+Search.swift \
        Sources/PensieveApp/AppDefaults.swift Sources/PensieveApp/Settings/IntelligenceSettingsTab.swift \
        Sources/PensieveKit/Support/PensieveDefaults.swift
git commit -F - <<'EOF'
feat: app search over BM25, vector default-off

One ranked list plus a pinned Top Hit computed synchronously from the
visible node set, so navigation never waits on ranking. The search index
build is awaited on refresh (milliseconds of pure SQL); the vector index
stays detached and gated.

Flips the vector default to off in all three homes it lives in.
EOF
```

---

## Task 12: `ContentListView` — one list, pinned Top Hit, honest empty state, German

**Files:**
- Modify: `Sources/PensieveApp/ContentListView.swift:44-130`
- Modify: `Sources/PensieveApp/Localizable.xcstrings`

**Interfaces:**
- Consumes: `AppModel.searchHits`, `.pinnedTopHit`, `.semanticHits`, `.searchIndexState`, `.selectSearchHit`.
- Produces: no API.

**Context an implementer needs.** `searchNodesSection`, `searchLooseEndsSection` and `searchRelatedSection` collapse into: a Top Hit section, one Results section, and (only when the vector toggle is on) a clearly-labelled experimental section below. Row layout branches on `hit.kind` rather than on hit *type*, since there is one type now.

**The empty state is the point of the task, not a detail.** `ContentUnavailableView.search` says "no results", which after this change would also be what a never-built index looks like. Branch on `searchIndexState`.

**Localization:** app chrome only. New keys go in `Localizable.xcstrings` by hand — `xcodebuild` does **not** auto-populate the source catalog (IDE-only), and a mis-keyed `de` value silently falls back to English.

| Key (en) | de |
|---|---|
| `Top Hit` | `Bester Treffer` |
| `Results` | `Ergebnisse` |
| `Related (experimental)` | `Ähnlich (experimentell)` |
| `Building the search index…` | `Suchindex wird erstellt…` |
| `The search index has not been built yet.` | `Der Suchindex wurde noch nicht erstellt.` |

`Active` and `Include Archived` already exist — do not duplicate them. Node names, snippets and file paths are content and stay verbatim.

- [ ] **Step 1: Replace the search sections**

```swift
  @ViewBuilder private func searchResultsList() -> some View {
    List {
      searchScopePicker()
      if let pinned = model.pinnedTopHit {
        Section(header: Text("Top Hit")) { searchRow(pinned) }
      }
      if !model.searchHits.isEmpty {
        Section(header: Text("Results")) {
          ForEach(model.searchHits) { hit in searchRow(hit) }
        }
      }
      if !model.semanticHits.isEmpty {
        Section(header: Text("Related (experimental)")) {
          ForEach(model.semanticHits) { hit in searchRow(hit) }
        }
      }
    }
    .overlay { searchEmptyState() }
  }

  /// "Nothing matched" and "the index isn't built" must not look the same — since BM25 became the
  /// only retrieval path, an unbuilt index would otherwise read as "you never worked on that".
  @ViewBuilder private func searchEmptyState() -> some View {
    if model.searchHits.isEmpty && model.semanticHits.isEmpty && model.pinnedTopHit == nil {
      switch model.searchIndexState {
      case .building:
        ContentUnavailableView("Building the search index…", systemImage: "clock.arrow.circlepath")
      case .absent:
        ContentUnavailableView("The search index has not been built yet.",
                               systemImage: "exclamationmark.magnifyingglass")
      case .ready:
        ContentUnavailableView.search(text: model.searchText)
      }
    }
  }

  /// One row for every hit, branching on `kind` — there is one hit type now, so the old
  /// per-section row builders collapse into this.
  @ViewBuilder private func searchRow(_ hit: SearchHit) -> some View {
    Button { model.selectSearchHit(hit) } label: {
      HStack(spacing: 10) {
        if hit.kind == "node", let resultNode = model.node(hit.nodeID) {
          NodeBadge(node: resultNode, size: 22)
        }
        VStack(alignment: .leading, spacing: 2) {
          if hit.kind == "node" {
            Text(hit.nodeName)
            SnippetText(snippet: hit.snippet).font(.caption).foregroundStyle(.secondary)
          } else {
            Text(hit.nodeName).font(.caption).foregroundStyle(.secondary)
            SnippetText(snippet: hit.snippet)
          }
        }
        if hit.isArchived { Spacer(); ArchivedBadge() }
      }
      .rowHitArea()
    }
    .buttonStyle(.plain)
  }
```

Delete `searchNodesSection`, `searchLooseEndsSection` and `searchRelatedSection`.

- [ ] **Step 2: Add the String Catalog keys**

For each key in the table above, add an entry to `Sources/PensieveApp/Localizable.xcstrings` matching the existing entry shape exactly (`extractionState`, `localizations.en.stringUnit` and `localizations.de.stringUnit`, both `state: "translated"`). Copy the JSON shape from an existing simple key such as `"Related"` rather than hand-writing it.

- [ ] **Step 3: Build**

```bash
xcodegen generate
xcodebuild -project Pensieve.xcodeproj -scheme Pensieve -configuration Debug \
  -derivedDataPath ./.build-xcode build 2>&1 | tail -20
```
Expected: BUILD SUCCEEDED, no warnings about the catalog.

- [ ] **Step 4: Verify the German entries actually shipped**

```bash
plutil -p ./.build-xcode/Build/Products/Debug/Pensieve.app/Contents/Resources/de.lproj/Localizable.strings \
  | grep -i -E "Treffer|Ergebnisse|Suchindex|experimentell"
```
Expected: all five German values present. An English value here means a mis-keyed entry that would silently fall back.

- [ ] **Step 5: Smoke-launch**

```bash
DB=$(mktemp -d)
PENSIEVE_DB=$DB/p.sqlite PENSIEVE_CAPTURE_DB=$DB/c.sqlite \
  ./.build-xcode/Build/Products/Debug/Pensieve.app/Contents/MacOS/Pensieve &
PID=$!; sleep 6; kill $PID; rm -rf $DB
```
Expected: launches and stays up for 6 s without crashing.

- [ ] **Step 6: Commit**

```bash
git add Sources/PensieveApp/ContentListView.swift Sources/PensieveApp/Localizable.xcstrings
git commit -F - <<'EOF'
feat: one ranked search list with a pinned Top Hit

Collapses the Projects/Loose Ends/Related sections into a single ranked
list, with the Top Hit pinned above it and the vector's hits, when
enabled, in a separately labelled experimental section below.

The empty state now distinguishes "nothing matched" from "the index has
not been built" — with BM25 as the only retrieval path those two would
otherwise be indistinguishable. German added for the five new keys.
EOF
```

---

## Task 13: Verification gate — re-measure with the `files` column

**Files:**
- Modify: `docs/superpowers/measurements/2026-07-28-retrieval-recall/README.md`
- Modify: `docs/superpowers/specs/2026-07-28-retrieval-eval-harness-design.md` (§Verification gate step 2)
- Possibly modify: `Sources/PensieveKit/Search/SearchIndexStore.swift` (only if the fallback fires)

**Interfaces:**
- Consumes: everything above.
- Produces: a recorded post-P2′ P@1, and a go/no-go on the pre-specified fallback.

**Context an implementer needs.** This is step 2 of the spec's two-step gate. The `files` column is unmeasured, and it changes BM25's document-length normalisation — FTS5 normalises by the row's **total** token count across all columns, so every event row got longer and its `text` matches are discounted relative to nodes and loose ends. The 0.1 weight bounds how much a path *match* contributes; it does nothing about how much a path *presence* costs. Only this re-measurement catches the second effect.

**The fallback is already decided** (spec §Verification gate): if P@1 regresses below the Task 2 baseline, move `files` into its own FTS5 table joined on `item_id`, queried separately and merged by rank. Do not improvise a different fix.

- [ ] **Step 1: Regenerate the snapshot and corpus extract**

```bash
mkdir -p /tmp/measure
sqlite3 ~/Library/Application\ Support/Pensieve/pensieve.sqlite "VACUUM INTO '/tmp/measure/snapshot.sqlite'"
PENSIEVE_MEASURE_DIR=/tmp/measure PENSIEVE_MEASURE_DB=/tmp/measure/snapshot.sqlite \
  ./scripts/test.sh --filter dumpCorpusForMeasurement
```

The extract now carries `files`. Record the item counts printed by the generator.

- [ ] **Step 2: Teach `rprobe` to index the files column**

In `rprobe.swift`, extend the BM25 scoring to two fields with weights 1.0 / 0.1, mirroring FTS5:
score each document as `bm25(text tokens) + 0.1 * bm25(files tokens)`, with the document length used
for normalisation being **the sum of both fields' token counts** — that is the effect being measured,
and modelling only the weight would measure nothing.

- [ ] **Step 3: Run and compare**

```bash
cd docs/superpowers/measurements/2026-07-28-retrieval-recall
PENSIEVE_MEASURE_DIR=/tmp/measure swift rprobe.swift
```

Compare P@1 against the Task 2 baseline.

- [ ] **Step 4a: If P@1 ≥ baseline — record and finish**

Add the figure to the README table and to the spec's §Verification gate step 2, then clean up:

```bash
rm -rf /tmp/measure
```

- [ ] **Step 4b: If P@1 < baseline — apply the pre-specified fallback**

Move `files` out of the `documents` table into its own FTS5 table:

```sql
CREATE VIRTUAL TABLE IF NOT EXISTS document_files USING fts5(
  files, item_id UNINDEXED, tokenize = 'unicode61 remove_diacritics 2');
```

`SearchIndexStore.rebuild` writes both; `search` runs the text query and, when the query has a
`files`-column term, a second query against `document_files`, merging by rank (interleave, text
first). Update `SearchIndexStoreTests.textMatchOutranksFilesOnlyMatch` to assert the merged order
instead of a single-table bm25 comparison. Then re-run Step 3 and confirm P@1 has returned to the
baseline, and record both numbers with a note on which configuration shipped.

- [ ] **Step 5: Run the full suite and lint**

```bash
./scripts/test.sh
swiftlint lint --strict
```
Expected: all tests pass, lint clean.

- [ ] **Step 6: Commit**

```bash
git add docs/superpowers/measurements/2026-07-28-retrieval-recall/ \
        docs/superpowers/specs/2026-07-28-retrieval-eval-harness-design.md \
        Sources/PensieveKit/Search/SearchIndexStore.swift
git commit -F - <<'EOF'
docs: record the post-P2 retrieval baseline

Re-runs the committed probe with the files column present, closing the
two-step verification gate the spec pre-registered.
EOF
```

---

## Post-merge carries

Not tasks — they need the built app at `/Applications`, the real store, and a human.

- **Rebuild and reinstall to `/Applications`** so the bundled `pensieve mcp` exposes the new `search` contract and the app picks up the single list. The `~/.local/bin/pensieve` symlink follows automatically.
- **Re-register nothing** — the MCP server registration and the SMAppService agent are unchanged.
- **Human-verify:**
  - ⌘F with a common term (`sync`, `app`) — does the Top Hit pin the node you meant, even when events fill the list?
  - ⌘F with a multi-word query that has no verbatim occurrence (`focus filter spotlight`) — the old matcher returned nothing here; it should now return work.
  - ⌘F with a file path (`SemanticQueries.swift`) — do commits that touched it come back?
  - Type an apostrophe, a colon, `C++`, an unbalanced quote — no crash, no error, no empty-because-broken.
  - Delete `~/Library/Application Support/Pensieve/search-index.sqlite` while the app is closed, relaunch, and search immediately — do you get "building"/"not built" rather than a bare "no results"?
  - Settings ▸ Intelligence — the vector toggle reads **off** on a machine that never set it, and turning it on adds a labelled experimental section below the results.
  - German in-situ (`-AppleLanguages '(de)'`) for the five new keys.
  - `pensieve mcp` from a Claude Code session: `search` returns `items` + `index_state`, and the `file` parameter works.

---

## Self-Review

**Spec coverage.** P1 hygiene → Task 1; per-node de-dup + re-baseline → Tasks 1–2; `files` in the corpus → Task 3; `FTSQuery` builder → Task 4; index location/DDL/tokenizer/weights/raw-SQL → Task 5; hash-guarded whole rebuild → Task 6; one hit type, guards, canonical re-resolve, no floor, over-fetch simplification, result cap, Top Hit, snippets → Task 7; vector returns `SearchHit` → Task 8; maintenance seams → Tasks 9, 11; MCP surface → Task 10; ⌘F surface, first-run/staleness sentinel, three-home default flip → Tasks 11–12; verification gate + pre-specified fallback → Task 13. **Not covered, by design:** P3 (own plan), and the deferred `doctor` diagnostic surface.

**Known ordering hazard.** Task 2's generator references `item.files`, which Task 3 adds. Either run Task 3 before Task 2's measurement, or drop that one key and restore it — flagged inline in Task 2.

**Known breakage window.** Task 7 deletes `SearchResults`/`NodeHit`/`LooseEndHit`, so the app and CLI targets do not build until Tasks 10–12 land. That is deliberate — the compiler is what guarantees no call site keeps the old semantics — but it means Tasks 7–12 should land as one branch, not be merged individually.

**Type consistency.** `SearchHit.score` is `Double?` everywhere (nil only for a pinned Top Hit); `SearchIndexState` is the single state enum used by the store, the app and MCP; `SearchScope` (BM25) and `SemanticSearchScope` (vector, keeps `floor`) stay distinct on purpose; `SearchIndexer.sync` is synchronous, `SemanticIndexer.sync` is `async`.
