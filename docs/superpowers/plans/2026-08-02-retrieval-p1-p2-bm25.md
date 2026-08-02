# Retrieval P1 + P2 — corpus hygiene and BM25 "Related" Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stop shipping a broken retrieval ranker — clean the embeddable corpus of content-free junk (P1), then replace the vector engine behind ⌘F "Related" and the MCP `search` tool with an FTS5/BM25 keyword index (P2), leaving every grounding guard and public shape unchanged.

**Architecture:** A new disposable, device-local, never-synced `text-index.sqlite` holds an FTS5 table over the *same* `EmbeddableCorpus.gather` items the vector index used. `TextIndexStore` owns the index (fingerprint-gated full rebuild + a BM25 query); `RelatedQueries` is the query layer that mirrors `SemanticQueries`' over-fetch/filter/re-resolve pipeline, sharing one extracted `RelatedResolver` so the two paths can never drift on grounding. The vector stack (`SemanticIndexStore`, `SemanticIndexer`, `SemanticQueries`, `NLContextualEmbedder`) stays in the tree, tested, and wired to nothing — it exists for the P3 harness only.

**Tech Stack:** Swift 6 · SQLiteData 1.6.6 (re-exports GRDB) · SQLite FTS5 + `bm25()` from Apple's system libsqlite3 (verified available: `sqlite3 3.51.0`) · Swift Testing.

## Global Constraints

- **The trust gate is untouched.** This changes only *which real stored rows* are eligible to be returned. It touches neither extraction nor narration. No task may edit `LooseEndExtractor`, `TranscriptVocabulary.injectionMarkers`, or any verbatim-quote path.
- **Public shapes are unchanged:** `SemanticHit`, the MCP `SearchItem` JSON keys (`id, kind, node_id, node_name, title, snippet, similarity, archived`), `includeArchived`, Focus visibility (`visibleNodeIDs`), `excludingIDs`, and the canonical re-resolve all keep their current form and meaning.
- **The floor is removed, not retuned.** BM25 scores are unbounded and per-query-scaled; `floor: 0.25` is meaningless for them. Relevance is bounded by rank (`k`) plus the requirement that a document actually contain query terms. **A rank cap is not a relevance threshold** — this sentence must appear in a code comment at the query layer (spec §P2).
- **OR semantics between query terms**, k1/b left at SQLite's FTS5 defaults (1.2 / 0.75). This is the exact configuration the spec's measurements used (`measurements/2026-07-28-retrieval-recall/rprobe2.swift:80`); deviating invalidates the evidence.
- **Predicates use `.eq(x)`, never `== x`.** Reuse `CaptureKind` / `SourceKind` constants. No shared mutable `static ISO8601DateFormatter`. No Python.
- **Best-effort throughout:** an unavailable/corrupt index, an empty query, or a failed rebuild yields `[]` or a no-op — never a throw, never a block on capture/ingest/UI.
- **The app target has no unit tests.** All logic lands in PensieveKit with tests; `Sources/PensieveApp` stays thin. Verify the app with `xcodebuild` + a non-blocking smoke-launch of the inner binary using throwaway `PENSIEVE_DB`/`PENSIEVE_CAPTURE_DB`.
- **Run tests with `./scripts/test.sh`** (optionally `--filter <name>`). Current baseline: **524 tests**.
- **Commit messages:** backticks inside `git commit -m "..."` get shell-executed — use `git commit -F` with a quoted-`EOF` heredoc. Keep the `Co-Authored-By:` and `Claude-Session:` trailers.
- **German localization:** app UI chrome only. Node names, loose-end text/quotes, event summaries and transcript text are never localized. Keys are authored **by hand** in `Sources/PensieveApp/Localizable.xcstrings` — `xcodebuild` does not populate them.

## Settled design decisions (do not re-litigate mid-task)

1. **The "Semantic search" toggle becomes a master switch for "Related", and the engine is always BM25.** `PensieveDefaults.semanticSearchKey` (`"app.semanticSearch"`) keeps its string and its default of **ON** — only the user-facing copy and the doc comments change. The vector is not reachable from the app or MCP at all.
2. **The vector stack is retained but unwired.** Delete no files from `Sources/PensieveKit/Semantic/` other than what these changes orphan. `SemanticIndexer` loses both of its call sites (`SyncRunner`, `AppModel`) because nothing queries the vector index any more — leaving them would burn CPU and download the NL asset to maintain an index no reader consults.
3. **A separate `text-index.sqlite`,** not a table inside `semantic-index.sqlite`. `SemanticIndexStore`'s `prepareDatabase` hook *throws* when sqlite-vec fails to register, which would take the whole pool — and with it BM25 — down with it. The FTS index must not inherit that failure mode.
4. **Full rebuild, fingerprint-gated,** not incremental reconciliation. The corpus is ~2,300 short rows; a whole-table rewrite is milliseconds and cannot drift. A stored fingerprint over `(itemID, kind, nodeID, state, contentHash)` makes the steady-state no-op free.
5. **The stale `semantic-index.sqlite` is left on disk.** No task deletes user data. The docs task notes it is now inert and safe to remove by hand.

---

### Task 1: P1 — corpus hygiene in `EmbeddableCorpus.gather`

Drop the two classes of junk the spec measured: `git.checkout` events (261 of 1,686 on the real store; 84 literally `checkout HEAD`) and exact-duplicate texts (400 of 2,630 rows across 111 groups, one string occupying up to 84 top-k slots). Measured effect: 2,630 → 2,264 items, BM25 P@1 0.387 → 0.433.

This is a production change with no gate. It benefits the vector path too, and ships first so P2 is measured against the cleaned corpus.

**Explicitly NOT in this task** (spec §P1): the 155 loose ends whose `text == quote` (22% of 704, a bare prompt echo). They are *real* captured user prompts; suppressing them is a grounding/recall judgment owned by whoever owns loose-end quality, not hygiene. Do not add that filter here even though the measurement mentions it.

**Files:**
- Modify: `Sources/PensieveKit/Semantic/EmbeddableItem.swift:48-62` (the event loop) and add a private helper
- Test: `Tests/PensieveKitTests/SemanticIndexerTests.swift` (append to the existing `gather*` tests at the end of the file, after line 361)

**Interfaces:**
- Consumes: nothing new.
- Produces: `EmbeddableCorpus.gather(_:) -> [EmbeddableItem]` — same signature, fewer items. Adds internal `EmbeddableCorpus.dedupedByText(_ items: [EmbeddableItem]) -> [EmbeddableItem]` (used by Task 1's tests only; Tasks 2–6 call `gather` alone).

- [ ] **Step 1: Write the failing tests**

Append to `Tests/PensieveKitTests/SemanticIndexerTests.swift`. Note the local `makeSource` helper: `sources` has a `UNIQUE(key, kind)` index, so two events under one node must share a single Source row (the file's existing `makeEvent` mints a new Source per call and would violate it).

```swift
/// One Source per node, so several Events can hang off it without tripping
/// `idx_sources_key_kind` (UNIQUE(key, kind)). Events keep `fingerprint == nil`,
/// and SQLite treats NULLs as distinct in a UNIQUE index, so duplicates are insertable.
private func makeSharedSource(_ db: any DatabaseWriter, node: Node) throws -> Source {
  let s = Source(nodeID: node.id, kind: SourceKind.gitRepo, key: "/shared/\(node.id)")
  try db.write { try Source.insert { s }.execute($0) }
  return s
}

private func insertEvent(_ db: any DatabaseWriter, node: Node, source: Source,
                         kind: String, summary: String) throws -> Event {
  let e = Event(nodeID: node.id, sourceID: source.id, occurredAt: Date(),
                kind: kind, summary: summary, detailJSON: "{}")
  try db.write { try Event.insert { e }.execute($0) }
  return e
}

@Suite struct EmbeddableCorpusHygieneTests {
  /// `git.checkout` events carry no work content — on the real store 261 of 1,686 events were bare
  /// `checkout <branch>` strings, and they were the actual source of the "gibberish matches
  /// everything" symptom (its top hit was `checkout feat/pensieve-app-three-pane`).
  @Test func gatherDropsGitCheckoutEvents() async throws {
    let db = try openCanonicalDatabase(at: tempURL("corpus-checkout"))
    let n = Node(name: "Refunds work", kind: NodeKind.project)
    try await db.write { try Node.insert { n }.execute($0) }
    let src = try makeSharedSource(db, node: n)
    let checkout = try insertEvent(db, node: n, source: src,
                                   kind: CaptureKind.gitCheckout, summary: "checkout main")
    let commit = try insertEvent(db, node: n, source: src,
                                 kind: CaptureKind.gitCommit, summary: "fix the refund rounding")

    let ids = Set(try EmbeddableCorpus.gather(db).map { $0.itemID })
    #expect(!ids.contains(checkout.id.uuidString))
    #expect(ids.contains(commit.id.uuidString))
  }

  /// 400 of 2,630 rows on the real store were exact duplicate texts across 111 groups; one string
  /// could occupy up to 84 top-k slots. First occurrence wins.
  @Test func gatherDropsExactDuplicateTextsKeepingTheFirst() async throws {
    let db = try openCanonicalDatabase(at: tempURL("corpus-dupes"))
    let n = Node(name: "Billing", kind: NodeKind.project)
    try await db.write { try Node.insert { n }.execute($0) }
    let src = try makeSharedSource(db, node: n)
    let first = try insertEvent(db, node: n, source: src,
                                kind: CaptureKind.gitCommit, summary: "wip")
    let dupe = try insertEvent(db, node: n, source: src,
                               kind: CaptureKind.gitCommit, summary: "wip")
    let spaced = try insertEvent(db, node: n, source: src,
                                 kind: CaptureKind.gitCommit, summary: "  wip  ")

    let ids = Set(try EmbeddableCorpus.gather(db).map { $0.itemID })
    #expect(ids.contains(first.id.uuidString))
    #expect(!ids.contains(dupe.id.uuidString))
    #expect(!ids.contains(spaced.id.uuidString))   // compared after trimming
  }

  /// Dedup runs over the gather order (nodes → loose ends → events), so a node can never be
  /// dropped in favour of an event that happens to repeat its text — losing a node would make it
  /// permanently unfindable in "Related".
  @Test func gatherKeepsTheNodeWhenAnEventRepeatsItsText() async throws {
    let db = try openCanonicalDatabase(at: tempURL("corpus-node-wins"))
    let n = Node(name: "Pensieve", kind: NodeKind.project)
    try await db.write { try Node.insert { n }.execute($0) }
    let src = try makeSharedSource(db, node: n)
    let echo = try insertEvent(db, node: n, source: src,
                               kind: CaptureKind.gitCommit, summary: "Pensieve")

    let ids = Set(try EmbeddableCorpus.gather(db).map { $0.itemID })
    #expect(ids.contains(n.id.uuidString))
    #expect(!ids.contains(echo.id.uuidString))
  }

  /// The de-dup key is the item text, not the item id — identical text under DIFFERENT nodes is
  /// still one row. Pins that the filter is global (matching the measurement), not per-node.
  @Test func gatherDedupesAcrossNodes() async throws {
    let db = try openCanonicalDatabase(at: tempURL("corpus-cross-node"))
    let a = Node(name: "Alpha", kind: NodeKind.project)
    let b = Node(name: "Beta", kind: NodeKind.project)
    try await db.write { db in
      try Node.insert { a }.execute(db)
      try Node.insert { b }.execute(db)
    }
    let srcA = try makeSharedSource(db, node: a)
    let srcB = try makeSharedSource(db, node: b)
    let first = try insertEvent(db, node: a, source: srcA,
                                kind: CaptureKind.gitCommit, summary: "bump deps")
    let second = try insertEvent(db, node: b, source: srcB,
                                 kind: CaptureKind.gitCommit, summary: "bump deps")

    let ids = Set(try EmbeddableCorpus.gather(db).map { $0.itemID })
    #expect(ids.contains(first.id.uuidString))
    #expect(!ids.contains(second.id.uuidString))
  }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `./scripts/test.sh --filter EmbeddableCorpusHygieneTests`
Expected: FAIL — 4 failures. `gatherDropsGitCheckoutEvents` fails on the `!ids.contains(checkout…)` expectation (checkout events are currently indexed); the dedup tests fail because every duplicate is currently kept.

- [ ] **Step 3: Implement the hygiene filter**

In `Sources/PensieveKit/Semantic/EmbeddableItem.swift`, inside `gather`'s event loop, add the kind guard immediately after the `state` lookup, and return through the de-dup helper.

Replace lines 48-64 (the `let events = …` block through `return out`) with:

```swift
      let events = try Event.all.fetchAll(db)
      for e in events {
        guard let state = stateByNodeID[e.nodeID] else { continue }
        // `git.checkout` carries no work content: on the real store 261 of 1,686 events were bare
        // `checkout <branch>` strings (84 literally `checkout HEAD`, 72 `checkout main`). They
        // occupy top-k slots in every retrieval strategy and were the actual source of the
        // "gibberish matches everything" symptom the semantic defect report opened on.
        guard e.kind != CaptureKind.gitCheckout else { continue }
        let text: String?
        switch e.kind {
        // LLM-enriched prose — gate it: degenerate model output ("[]", a bare "/") is not content.
        case CaptureKind.ccSession: text = e.workSummary.flatMap { isSearchable($0) ? $0 : nil }
        // Human-authored (a git commit subject). NOT gated — "wip" and "fix ci" are real, short work.
        default: text = e.summary.isEmpty ? nil : e.summary
        }
        if let text {
          out.append(.init(itemID: e.id.uuidString, kind: "event", nodeID: e.nodeID.uuidString,
                           state: state, text: text))
        }
      }
      return dedupedByText(out)
    }
  }

  /// Drop any item whose text is identical (after trimming) to one already kept — 400 of 2,630 rows
  /// on the real store were exact duplicates across 111 groups, and a single string could occupy up
  /// to 84 top-k slots. First-wins over `gather`'s order (nodes → loose ends → events), so a node is
  /// never dropped in favour of an event repeating its text; losing a node would make that node
  /// permanently unfindable. Trimmed but NOT case-folded, matching the measurement
  /// (`measurements/2026-07-28-retrieval-recall/rprobe4.swift:104-111`).
  static func dedupedByText(_ items: [EmbeddableItem]) -> [EmbeddableItem] {
    var seen = Set<String>()
    return items.filter {
      seen.insert($0.text.trimmingCharacters(in: .whitespacesAndNewlines)).inserted
    }
  }
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `./scripts/test.sh --filter EmbeddableCorpusHygieneTests`
Expected: PASS — 4 tests.

Then the full suite, because `gather` feeds `SemanticIndexer` and `SyncRunner`:

Run: `./scripts/test.sh`
Expected: PASS — 528 tests (524 + 4).

- [ ] **Step 5: Commit**

```bash
git add Sources/PensieveKit/Semantic/EmbeddableItem.swift Tests/PensieveKitTests/SemanticIndexerTests.swift
git commit -F - <<'EOF'
feat(retrieval): P1 corpus hygiene — drop checkout events and duplicate texts

`git.checkout` events carry no work content (261 of 1,686 on the real store, 84
literally `checkout HEAD`) and 400 of 2,630 rows were exact duplicate texts across
111 groups. Both occupy top-k slots in every retrieval strategy; the gibberish top
hit in the original defect report was a checkout event. Measured: 2,630 -> 2,264
items, BM25 P@1 0.387 -> 0.433.

De-dup is first-wins over gather's order, so a node is never dropped in favour of
an event repeating its text.

Spec: docs/superpowers/specs/2026-07-28-retrieval-eval-harness-design.md (P1)

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_017jpKhJZCEtKSagji4yzECH
EOF
```

---

### Task 2: `TextIndexStore` — the FTS5/BM25 index

The storage layer: a disposable, device-local, never-synced `text-index.sqlite` holding one FTS5 table over the same `EmbeddableItem`s. Owns a fingerprint-gated full rebuild and a BM25 query. No sqlite-vec, no embedder, no NL asset.

**Files:**
- Create: `Sources/PensieveKit/Semantic/TextIndexStore.swift`
- Modify: `Sources/PensieveKit/Support/PensievePaths.swift` (add `textIndexURL()` after `semanticIndexURL()`, which ends at line 23)
- Test: `Tests/PensieveKitTests/TextIndexStoreTests.swift` (create)

**Interfaces:**
- Consumes: `EmbeddableItem` (`itemID, kind, nodeID, state, text`, plus `contentHash`) from Task 1's file; `PensievePaths.ensureParentDirectory(of:)`.
- Produces, for Tasks 3–6:
  - `public struct BM25Result: Sendable { public let itemID: String, kind: String, nodeID: String; public let score: Double }`
  - `public struct TextIndexStore: Sendable`
    - `public init(url: URL)`
    - `public var isAvailable: Bool`
    - `@discardableResult public func rebuild(items: [EmbeddableItem]) -> Bool` (true = the index was rewritten; false = fingerprint unchanged or unavailable)
    - `public func search(query: String, k: Int, includeArchived: Bool) -> [BM25Result]` (best first)
    - `static func matchExpression(for raw: String) -> String?` (internal, tested directly)
  - `public static func textIndexURL() -> URL` on `PensievePaths`

- [ ] **Step 1: Write the failing tests**

Create `Tests/PensieveKitTests/TextIndexStoreTests.swift`:

```swift
import Testing
import Foundation
@testable import PensieveKit

@Suite struct TextIndexStoreTests {
  private func store() -> TextIndexStore {
    TextIndexStore(url: URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("txtidx-\(UUID().uuidString).sqlite"))
  }

  private func item(_ id: String, _ text: String, state: String = "active",
                    kind: String = "event", node: String = "N1") -> EmbeddableItem {
    EmbeddableItem(itemID: id, kind: kind, nodeID: node, state: state, text: text)
  }

  // MARK: match expression

  /// Every term is quoted so a user typing an FTS5 keyword gets a literal match instead of a
  /// syntax error or a silent operator. Terms are OR-ed, matching the spec's measurement config.
  @Test func matchExpressionQuotesTermsAndOrsThem() {
    #expect(TextIndexStore.matchExpression(for: "background sync") == "\"background\" OR \"sync\"")
  }

  @Test func matchExpressionTreatsFTS5KeywordsAsLiterals() {
    #expect(TextIndexStore.matchExpression(for: "cats AND dogs") == "\"cats\" OR \"and\" OR \"dogs\"")
  }

  /// Punctuation is a separator (mirroring unicode61) and 1-character tokens are dropped.
  @Test func matchExpressionSplitsOnPunctuationAndDropsShortTokens() {
    #expect(TextIndexStore.matchExpression(for: "login-items: a v2!") == "\"login\" OR \"items\" OR \"v2\"")
  }

  @Test func matchExpressionDedupesRepeatedTermsPreservingOrder() {
    #expect(TextIndexStore.matchExpression(for: "sync sync agent") == "\"sync\" OR \"agent\"")
  }

  /// Nothing usable → nil, so the caller returns [] instead of handing FTS5 an empty MATCH
  /// (which is a syntax error).
  @Test func matchExpressionIsNilWhenNothingUsableSurvives() {
    #expect(TextIndexStore.matchExpression(for: "  ") == nil)
    #expect(TextIndexStore.matchExpression(for: "a ? !") == nil)
  }

  /// A pasted paragraph must not build an unbounded OR chain (SQLITE_MAX_EXPR_DEPTH).
  @Test func matchExpressionCapsTermCount() {
    let raw = (1...100).map { "term\($0)" }.joined(separator: " ")
    let expr = TextIndexStore.matchExpression(for: raw)
    #expect(expr?.components(separatedBy: " OR ").count == 32)
  }

  // MARK: search

  @Test func searchRanksTheDocumentContainingMoreQueryTermsFirst() {
    let s = store()
    s.rebuild(items: [
      item("A", "background sync agent registers with login items"),
      item("B", "the sync daemon interval"),
      item("C", "unrelated transcript rendering work"),
    ])
    let hits = s.search(query: "background sync login", k: 10, includeArchived: false)
    #expect(hits.first?.itemID == "A")
    #expect(!hits.contains { $0.itemID == "C" })   // shares no query term
  }

  /// Higher score = more relevant, so the caller can sort/compare without knowing bm25()'s sign.
  @Test func searchScoresDescend() {
    let s = store()
    s.rebuild(items: [
      item("A", "background sync agent login items"),
      item("B", "sync"),
    ])
    let hits = s.search(query: "background sync login", k: 10, includeArchived: false)
    #expect(hits.count == 2)
    #expect(hits[0].score > hits[1].score)
  }

  @Test func searchCarriesKindAndNodeIDThrough() {
    let s = store()
    s.rebuild(items: [item("A", "refund rounding", kind: "loose_end", node: "NODE-7")])
    let hit = s.search(query: "refund", k: 5, includeArchived: false).first
    #expect(hit?.kind == "loose_end")
    #expect(hit?.nodeID == "NODE-7")
  }

  @Test func searchRespectsK() {
    let s = store()
    s.rebuild(items: (1...10).map { item("I\($0)", "sync item \($0)") })
    #expect(s.search(query: "sync", k: 3, includeArchived: false).count == 3)
  }

  @Test func searchReturnsEmptyForAnUnusableQuery() {
    let s = store()
    s.rebuild(items: [item("A", "background sync")])
    #expect(s.search(query: "  ", k: 5, includeArchived: false).isEmpty)
    #expect(s.search(query: "sync", k: 0, includeArchived: false).isEmpty)
  }

  // MARK: state filtering (allow-list, mirroring SemanticIndexStore.knn)

  @Test func searchExcludesArchivedByDefaultAndIncludesItWhenAsked() {
    let s = store()
    s.rebuild(items: [
      item("ACT", "sync agent work", state: "active"),
      item("ARC", "sync agent work archived", state: "archived"),
    ])
    let strict = s.search(query: "sync", k: 10, includeArchived: false).map { $0.itemID }
    #expect(strict == ["ACT"])
    let wide = Set(s.search(query: "sync", k: 10, includeArchived: true).map { $0.itemID })
    #expect(wide == ["ACT", "ARC"])
  }

  /// The filter is an allow-list, never a deny-list — an unknown/future state can't leak in by
  /// omission. (`muted` is never gathered, but the store must not depend on that.)
  @Test func searchNeverReturnsUnknownStates() {
    let s = store()
    s.rebuild(items: [
      item("ACT", "sync agent work", state: "active"),
      item("MUT", "sync agent muted", state: "muted"),
      item("FUT", "sync agent future", state: "somethingNew"),
    ])
    #expect(s.search(query: "sync", k: 10, includeArchived: true).map { $0.itemID } == ["ACT"])
  }

  // MARK: rebuild

  @Test func rebuildReplacesTheWholeIndex() {
    let s = store()
    s.rebuild(items: [item("OLD", "legacy invoices")])
    s.rebuild(items: [item("NEW", "legacy invoices")])
    let hits = s.search(query: "invoices", k: 10, includeArchived: false)
    #expect(hits.map { $0.itemID } == ["NEW"])
  }

  /// The fingerprint short-circuit: an unchanged corpus must not rewrite the table (the app
  /// rebuilds on every refresh; the daemon every 300 s).
  @Test func rebuildIsANoOpWhenTheCorpusIsUnchanged() {
    let s = store()
    let corpus = [item("A", "background sync"), item("B", "login items")]
    #expect(s.rebuild(items: corpus) == true)
    #expect(s.rebuild(items: corpus) == false)
  }

  /// State and node id are part of the fingerprint, not just the text hash — an archive flip or a
  /// strand repoint changes filter/attribution columns and must re-index.
  @Test func rebuildDetectsStateAndNodeChangesWithUnchangedText() {
    let s = store()
    #expect(s.rebuild(items: [item("A", "background sync", state: "active")]) == true)
    #expect(s.rebuild(items: [item("A", "background sync", state: "archived")]) == true)
    #expect(s.rebuild(items: [item("A", "background sync", state: "archived", node: "N2")]) == true)
  }

  /// Order is not identity: the same set gathered in a different order is the same corpus.
  @Test func rebuildFingerprintIsOrderIndependent() {
    let s = store()
    let a = item("A", "background sync"), b = item("B", "login items")
    #expect(s.rebuild(items: [a, b]) == true)
    #expect(s.rebuild(items: [b, a]) == false)
  }

  @Test func rebuildWithAnEmptyCorpusClearsTheIndex() {
    let s = store()
    s.rebuild(items: [item("A", "background sync")])
    s.rebuild(items: [])
    #expect(s.search(query: "sync", k: 10, includeArchived: false).isEmpty)
  }

  /// Survives a reopen: the index is a file, and a second process (app vs. daemon vs. MCP) must
  /// see the same rows AND the same fingerprint (no spurious rebuild on every process start).
  @Test func indexAndFingerprintSurviveAReopen() {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("txtidx-reopen-\(UUID().uuidString).sqlite")
    let corpus = [item("A", "background sync agent")]
    #expect(TextIndexStore(url: url).rebuild(items: corpus) == true)

    let reopened = TextIndexStore(url: url)
    #expect(reopened.search(query: "sync", k: 5, includeArchived: false).map { $0.itemID } == ["A"])
    #expect(reopened.rebuild(items: corpus) == false)
  }

  /// Best-effort: a path that cannot be opened disables the store instead of throwing, and every
  /// op no-ops. The path must be unopenable even AFTER the delete-and-retry recovery — a directory
  /// sitting at the db path would simply be deleted and the retry would succeed. A path under
  /// `/dev/null` (a character device) can never hold a directory, so both attempts fail.
  @Test func anUnopenablePathDisablesTheStore() {
    let s = TextIndexStore(url: URL(fileURLWithPath: "/dev/null/nope/text-index.sqlite"))
    #expect(s.isAvailable == false)
    #expect(s.rebuild(items: [item("A", "x")]) == false)
    #expect(s.search(query: "sync", k: 5, includeArchived: false).isEmpty)
  }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `./scripts/test.sh --filter TextIndexStoreTests`
Expected: FAIL to **compile** — "cannot find 'TextIndexStore' in scope". That is the expected first failure.

- [ ] **Step 3: Add the path**

In `Sources/PensieveKit/Support/PensievePaths.swift`, immediately after `semanticIndexURL()` (which closes at line 23):

```swift
  /// The disposable, device-local, never-synced keyword (FTS5/BM25) index behind ⌘F "Related" and
  /// the MCP `search` tool, shared across app / CLI / daemon / MCP. Losing it costs only a rebuild
  /// on the next sync. Deliberately a separate file from `semanticIndexURL()`: that store fails to
  /// open at all when sqlite-vec can't register, and keyword search must not inherit that.
  public static func textIndexURL() -> URL {
    supportDirectory().appendingPathComponent("text-index.sqlite")
  }
```

- [ ] **Step 4: Implement the store**

Create `Sources/PensieveKit/Semantic/TextIndexStore.swift`:

```swift
import Foundation
import SQLiteData   // re-exports GRDB
import GRDB

public struct BM25Result: Sendable {
  public let itemID: String, kind: String, nodeID: String
  /// Relevance in BM25's own units, **negated so higher is better**. Unbounded and scaled per
  /// query (it moves with query length and idf mass) — comparable only *within* one result set,
  /// never across queries and never against a cosine similarity.
  public let score: Double
}

/// The keyword retrieval index: one FTS5 table over the same `EmbeddableCorpus` items the vector
/// index used, ranked by SQLite's `bm25()` at its default k1=1.2 / b=0.75 — the configuration the
/// spec's measurements used. Deliberately NOT the canonical store and not the vector store:
/// losing the file costs one rebuild, and it must stay open even when sqlite-vec can't register.
///
/// Rebuild is whole-table and fingerprint-gated rather than incrementally reconciled: the corpus is
/// a couple of thousand short rows, a full rewrite is milliseconds and cannot drift, and the stored
/// fingerprint makes the (overwhelmingly common) unchanged case free.
public struct TextIndexStore: Sendable {
  private let db: (any DatabaseWriter)?
  public var isAvailable: Bool { db != nil }

  /// Opens (creating if needed) the index at `url`. Best-effort, mirroring `SemanticIndexStore`:
  /// on a corrupt/unopenable file it deletes and retries once; if that also fails the store is
  /// disabled (every op no-ops, `isAvailable == false`) and callers degrade to exact search alone.
  public init(url: URL) {
    if let opened = Self.open(url) {
      self.db = opened
    } else {
      try? FileManager.default.removeItem(at: url)
      self.db = Self.open(url)
      if self.db == nil {
        Log.semantic.error("TextIndexStore: failed to open index after delete-and-retry at \(url.path, privacy: .public)")
      }
    }
  }

  private static func open(_ url: URL) -> (any DatabaseWriter)? {
    do {
      try PensievePaths.ensureParentDirectory(of: url)
      var config = Configuration()
      config.busyMode = .timeout(5)   // cross-process writer contention (app / daemon / MCP), matching CanonicalStore
      let pool = try DatabasePool(path: url.path, configuration: config)
      try pool.write { db in
        // Only `text` is indexed; the rest are UNINDEXED metadata carried for filtering and for
        // handing the query layer enough to re-resolve each hit against canonical.
        try db.execute(sql: """
          CREATE VIRTUAL TABLE IF NOT EXISTS docs USING fts5(
            item_id UNINDEXED, kind UNINDEXED, node_id UNINDEXED, state UNINDEXED, text,
            tokenize = 'unicode61 remove_diacritics 2')
          """)
        try db.execute(sql: "CREATE TABLE IF NOT EXISTS meta(fingerprint TEXT)")
      }
      return pool
    } catch { return nil }
  }

  /// Rewrite the index from `items` unless its fingerprint is unchanged. Returns true when the
  /// table was actually rewritten. One `write` (implicitly BEGIN IMMEDIATE in GRDB), so a
  /// concurrent app/daemon rebuild serialises instead of interleaving a half-empty index.
  @discardableResult
  public func rebuild(items: [EmbeddableItem]) -> Bool {
    guard let db else { return false }
    let fp = Self.fingerprint(items)
    return (try? db.write { db -> Bool in
      if try String.fetchOne(db, sql: "SELECT fingerprint FROM meta") == fp { return false }
      try db.execute(sql: "DELETE FROM docs")
      for i in items {
        try db.execute(sql: """
          INSERT INTO docs(item_id, kind, node_id, state, text) VALUES (?, ?, ?, ?, ?)
          """, arguments: [i.itemID, i.kind, i.nodeID, i.state, i.text])
      }
      try db.execute(sql: "DELETE FROM meta")
      try db.execute(sql: "INSERT INTO meta(fingerprint) VALUES (?)", arguments: [fp])
      return true
    }) ?? false
  }

  /// Top-`k` BM25 matches, best first. `includeArchived: false` returns active items only; `true`
  /// widens to active + archived. The state filter is an allow-list, never a deny-list, so a future
  /// state can never leak in by omission — same shape as `SemanticIndexStore.knn`. The SQL fragment
  /// is chosen from a Bool (no interpolated caller input), so there is no injection surface; the
  /// user's text reaches SQLite only as a bound parameter.
  public func search(query: String, k: Int, includeArchived: Bool) -> [BM25Result] {
    guard let db, k > 0, let match = Self.matchExpression(for: query) else { return [] }
    let filter = includeArchived
      ? "AND state IN ('active','archived')"
      : "AND state = 'active'"
    return (try? db.read { db in
      try Row.fetchAll(db, sql: """
        SELECT item_id, kind, node_id, bm25(docs) AS rank_score FROM docs
        WHERE docs MATCH ? \(filter) ORDER BY bm25(docs) LIMIT ?
        """, arguments: [match, k]).map { r in
        // bm25() is negative with more-negative = better; negate so callers can treat the score
        // like every other relevance number in the codebase (higher is better). Bound to an
        // explicitly typed local — GRDB's Row subscript is generic, and an inline `as Double`
        // leaves the overload ambiguous.
        let raw: Double = r["rank_score"]
        return BM25Result(itemID: r["item_id"], kind: r["kind"], nodeID: r["node_id"], score: -raw)
      }
    }) ?? []
  }

  /// Fingerprint of the whole corpus: every field that lands in a row, sorted so gather order can
  /// never look like a change. Includes `state`/`node_id`/`kind` as well as the text hash — an
  /// archive flip or a strand repoint changes filter and attribution columns with identical text.
  /// FNV-1a, not `hashValue` (which is per-process salted and would rebuild on every launch).
  static func fingerprint(_ items: [EmbeddableItem]) -> String {
    var h: UInt64 = 1469598103934665603
    for s in items.map({ "\($0.itemID)|\($0.kind)|\($0.nodeID)|\($0.state)|\($0.contentHash)" }).sorted() {
      for b in s.utf8 { h = (h ^ UInt64(b)) &* 1099511628211 }
      h = (h ^ 0x0a) &* 1099511628211        // record separator: "ab"+"c" must not hash as "a"+"bc"
    }
    return String(h, radix: 16)
  }

  /// Build an FTS5 MATCH expression from raw user text. Tokenises the way the index's `unicode61`
  /// tokenizer does (letters and digits are word characters, everything else separates), drops
  /// 1-character tokens, de-dupes, and **quotes every term** so a user typing an FTS5 keyword
  /// (`AND`, `OR`, `NOT`, `NEAR`) or a bare `*` gets a literal match instead of an operator or a
  /// syntax error. Terms are OR-ed — a document scores on ANY query term and `bm25()` then ranks by
  /// how many and how rare — which is the configuration the spec measured (`rprobe2.swift:80`);
  /// switching to AND would invalidate that evidence. Capped at 32 terms so a pasted paragraph
  /// can't build an expression deep enough to trip SQLITE_MAX_EXPR_DEPTH. Returns nil when nothing
  /// usable survives, which the caller turns into an empty result (an empty MATCH is a syntax error).
  static func matchExpression(for raw: String) -> String? {
    var seen = Set<String>()
    let terms = raw.lowercased()
      .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
      .map(String.init)
      .filter { $0.count >= 2 && seen.insert($0).inserted }
      .prefix(32)
    guard !terms.isEmpty else { return nil }
    return terms
      .map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
      .joined(separator: " OR ")
  }
}
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `./scripts/test.sh --filter TextIndexStoreTests`
Expected: PASS — 20 tests.

Run: `./scripts/test.sh`
Expected: PASS — 548 tests (528 + 20).

- [ ] **Step 6: Commit**

```bash
git add Sources/PensieveKit/Semantic/TextIndexStore.swift Sources/PensieveKit/Support/PensievePaths.swift Tests/PensieveKitTests/TextIndexStoreTests.swift
git commit -F - <<'EOF'
feat(retrieval): TextIndexStore — FTS5/BM25 index over the embeddable corpus

A disposable, device-local, never-synced text-index.sqlite holding one FTS5 table
over the same EmbeddableCorpus items the vector index used, ranked by SQLite's
bm25() at its default k1/b — the configuration the spec measured.

Separate file from semantic-index.sqlite on purpose: that store's prepareDatabase
hook throws when sqlite-vec can't register, and keyword search must not inherit
that failure mode.

Rebuild is whole-table and fingerprint-gated rather than incrementally reconciled:
~2,300 short rows rewrite in milliseconds and cannot drift, and the stored
fingerprint makes the unchanged case free. Query terms are quoted (an FTS5 keyword
typed by the user is a literal, not an operator) and OR-ed, capped at 32.

Spec: docs/superpowers/specs/2026-07-28-retrieval-eval-harness-design.md (P2)

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_017jpKhJZCEtKSagji4yzECH
EOF
```

---

### Task 3: `RelatedQueries` + one shared grounding resolver

The query layer. Extract the canonical re-resolve out of `SemanticQueries` into `RelatedResolver` so both engines share **one** implementation of every grounding guard — the spec's stated hazard is exactly that the two drift (`SemanticQueries.swift:81-83`: "if the index widens to archived but this does not, archived rows pass KNN and are then silently dropped here"). Then build `RelatedQueries.search` on top of it, mirroring the over-fetch/filter pipeline minus the floor.

**Files:**
- Create: `Sources/PensieveKit/Query/RelatedResolver.swift`
- Create: `Sources/PensieveKit/Query/RelatedQueries.swift`
- Modify: `Sources/PensieveKit/Query/SemanticQueries.swift` (delete `resolve`, call the shared one from `buildHits`; extend the `SemanticHit.similarity` doc)
- Test: `Tests/PensieveKitTests/RelatedQueriesTests.swift` (create)

**Interfaces:**
- Consumes: `TextIndexStore` / `BM25Result` (Task 2); `EmbeddableCorpus.gather` (Task 1); the existing `SemanticHit`, `SnippetMaker.make(from:matching:)`, `LooseEnd.isOpen`.
- Produces, for Tasks 5–6:
  - `public enum RelatedQueries` with
    `public static func search(query: String, visibleNodeIDs: Set<UUID>, excludingIDs: Set<UUID>, k: Int, includeArchived: Bool = false, store: TextIndexStore, _ db: any DatabaseReader) -> [SemanticHit]`
    — **synchronous** (it does no awaiting); a `@MainActor` caller must offload it.
  - `enum RelatedResolver` (internal) with
    `static func resolve(kind: String, itemID: UUID, score: Double, includeArchived: Bool, query: String, _ db: any DatabaseReader) throws -> SemanticHit?`

- [ ] **Step 1: Write the failing tests**

Create `Tests/PensieveKitTests/RelatedQueriesTests.swift`. The `makeEvent` helper and `openCanonicalDatabase`/`tempURL` come from the existing test support already used by `SemanticQueriesTests.swift`; redeclare the local helper here to keep the file self-contained (the codebase already does this — see the comment at `SemanticQueriesTests.swift:8`).

```swift
import Testing
import Foundation
import SQLiteData
@testable import PensieveKit

/// Inserts a Source + Event under `node` so a LooseEnd's sourceEventID FK is satisfiable.
/// Mirrors the helpers in SemanticQueriesTests.swift / SemanticIndexerTests.swift.
private func makeRelatedEvent(_ db: any DatabaseWriter, node: Node,
                              kind: String = CaptureKind.gitCommit,
                              summary: String = "did a thing",
                              workSummary: String? = nil) throws -> Event {
  let source = Source(nodeID: node.id, kind: SourceKind.gitRepo, key: "/rel/\(node.id)")
  let event = Event(nodeID: node.id, sourceID: source.id, occurredAt: Date(), kind: kind,
                    summary: summary, detailJSON: "{}", workSummary: workSummary)
  try db.write { db in
    try Source.insert { source }.execute(db)
    try Event.insert { event }.execute(db)
  }
  return event
}

@Suite struct RelatedQueriesTests {
  private func store() -> TextIndexStore {
    TextIndexStore(url: URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("relq-\(UUID().uuidString).sqlite"))
  }

  /// Index straight from the live corpus, so these tests exercise the same producer production uses.
  private func indexed(_ db: any DatabaseReader) throws -> TextIndexStore {
    let s = store()
    s.rebuild(items: try EmbeddableCorpus.gather(db))
    return s
  }

  @Test func findsANodeByAWordInItsName() async throws {
    let db = try openCanonicalDatabase(at: tempURL("relq-basic"))
    let n = Node(name: "Refunds pipeline overhaul", kind: NodeKind.project)
    try await db.write { try Node.insert { n }.execute($0) }
    let s = try indexed(db)

    let hits = RelatedQueries.search(query: "refunds", visibleNodeIDs: [n.id],
                                     excludingIDs: [], k: 5, store: s, db)
    #expect(hits.map { $0.id } == [n.id])
    #expect(hits.first?.kind == "node")
    #expect(hits.first?.nodeName == "Refunds pipeline overhaul")
  }

  /// Focus muting is applied AFTER retrieval, on the caller's visible set.
  @Test func focusMutedNodesNeverSurface() async throws {
    let db = try openCanonicalDatabase(at: tempURL("relq-mute"))
    let visible = Node(name: "Visible refunds work", kind: NodeKind.project)
    let muted = Node(name: "Muted refunds work", kind: NodeKind.project, context: "personal")
    try await db.write { db in
      try Node.insert { visible }.execute(db)
      try Node.insert { muted }.execute(db)
    }
    let s = try indexed(db)

    let hits = RelatedQueries.search(query: "refunds", visibleNodeIDs: [visible.id],
                                     excludingIDs: [], k: 5, store: s, db)
    #expect(hits.contains { $0.nodeID == visible.id })
    #expect(!hits.contains { $0.nodeID == muted.id })
  }

  /// Regression guard for the over-fetch itself. 60 muted-context nodes match BOTH query terms in
  /// a short name; the one visible node matches only "refunds" inside a deliberately long name, so
  /// BM25's length normalisation ranks it **61st** — below the initial `kFetch = max(k*8, 50)`
  /// window. Only the grow-and-retry loop reaches it. (Ranking verified against SQLite's bm25()
  /// before this fixture was written; the muted names differ per-index so Task 1's text de-dup
  /// keeps all 60.)
  @Test func overFetchReachesAVisibleHitBuriedUnderMutedMatches() async throws {
    let db = try openCanonicalDatabase(at: tempURL("relq-overfetch"))
    let filler = (0..<60).map { "filler\($0)" }.joined(separator: " ")
    let visible = Node(name: "refunds \(filler)", kind: NodeKind.project)
    let muted = (0..<60).map {
      Node(name: "refunds pipeline k\($0)", kind: NodeKind.project, context: "personal")
    }
    try await db.write { db in
      try Node.insert { visible }.execute(db)
      for m in muted { try Node.insert { m }.execute(db) }
    }
    let s = try indexed(db)

    let hits = RelatedQueries.search(query: "refunds pipeline", visibleNodeIDs: [visible.id],
                                     excludingIDs: [], k: 2, store: s, db)
    #expect(hits.contains { $0.nodeID == visible.id })
  }

  @Test func excludedIDsAreDropped() async throws {
    let db = try openCanonicalDatabase(at: tempURL("relq-exclude"))
    let a = Node(name: "Refunds alpha", kind: NodeKind.project)
    let b = Node(name: "Refunds beta", kind: NodeKind.project)
    try await db.write { db in
      try Node.insert { a }.execute(db)
      try Node.insert { b }.execute(db)
    }
    let s = try indexed(db)

    let hits = RelatedQueries.search(query: "refunds", visibleNodeIDs: [a.id, b.id],
                                     excludingIDs: [a.id], k: 5, store: s, db)
    #expect(hits.map { $0.id } == [b.id])
  }

  @Test func archivedNodesSurfaceOnlyWhenAskedAndAreBadged() async throws {
    let db = try openCanonicalDatabase(at: tempURL("relq-archived"))
    let active = Node(name: "Refunds active", kind: NodeKind.project)
    let archived = Node(name: "Refunds archived", state: .archived, kind: NodeKind.project)
    try await db.write { db in
      try Node.insert { active }.execute(db)
      try Node.insert { archived }.execute(db)
    }
    let s = try indexed(db)
    let visible: Set<UUID> = [active.id, archived.id]

    let strict = RelatedQueries.search(query: "refunds", visibleNodeIDs: visible,
                                       excludingIDs: [], k: 5, store: s, db)
    #expect(strict.map { $0.id } == [active.id])

    let wide = RelatedQueries.search(query: "refunds", visibleNodeIDs: visible, excludingIDs: [],
                                     k: 5, includeArchived: true, store: s, db)
    #expect(Set(wide.map { $0.id }) == visible)
    #expect(wide.first { $0.id == archived.id }?.isArchived == true)
    #expect(wide.first { $0.id == active.id }?.isArchived == false)
  }

  /// The last grounding defense: a row that is still in the index but no longer in the live corpus
  /// must not surface. Index first, then close the loose end WITHOUT rebuilding.
  @Test func aStaleIndexRowNeverSurfacesAsALiveHit() async throws {
    let db = try openCanonicalDatabase(at: tempURL("relq-stale"))
    let n = Node(name: "Billing", kind: NodeKind.project)
    try await db.write { try Node.insert { n }.execute($0) }
    let ev = try makeRelatedEvent(db, node: n, kind: CaptureKind.ccSession,
                                  summary: "session", workSummary: "worked on invoices")
    let le = LooseEnd(nodeID: n.id, sourceEventID: ev.id,
                      text: "drop the legacy refunds table", quote: "TODO drop refunds")
    try await db.write { try LooseEnd.insert { le }.execute($0) }
    let s = try indexed(db)
    #expect(RelatedQueries.search(query: "refunds", visibleNodeIDs: [n.id],
                                  excludingIDs: [], k: 5, store: s, db).contains { $0.id == le.id })

    try await db.write { db in
      try LooseEnd.where { $0.id.eq(le.id) }.update { $0.status = "closed" }.execute(db)
    }
    let after = RelatedQueries.search(query: "refunds", visibleNodeIDs: [n.id],
                                      excludingIDs: [], k: 5, store: s, db)
    #expect(!after.contains { $0.id == le.id })   // index still holds it; canonical re-check drops it
  }

  /// Loose ends and events resolve to their own titles/snippets, not their node's.
  @Test func resolvesLooseEndsAndEventsWithTheirOwnText() async throws {
    let db = try openCanonicalDatabase(at: tempURL("relq-kinds"))
    let n = Node(name: "Billing", kind: NodeKind.project)
    try await db.write { try Node.insert { n }.execute($0) }
    let ev = try makeRelatedEvent(db, node: n, kind: CaptureKind.ccSession,
                                  summary: "session", workSummary: "rewrote the dunning emails")
    let le = LooseEnd(nodeID: n.id, sourceEventID: ev.id,
                      text: "verify the dunning schedule", quote: "check dunning")
    try await db.write { try LooseEnd.insert { le }.execute($0) }
    let s = try indexed(db)

    let hits = RelatedQueries.search(query: "dunning", visibleNodeIDs: [n.id],
                                     excludingIDs: [], k: 5, store: s, db)
    #expect(hits.first { $0.kind == "loose_end" }?.title == "verify the dunning schedule")
    #expect(hits.first { $0.kind == "event" }?.title == "rewrote the dunning emails")
    #expect(hits.allSatisfy { $0.nodeName == "Billing" })
  }

  @Test func shortOrEmptyQueriesReturnNothing() async throws {
    let db = try openCanonicalDatabase(at: tempURL("relq-short"))
    let n = Node(name: "Refunds", kind: NodeKind.project)
    try await db.write { try Node.insert { n }.execute($0) }
    let s = try indexed(db)

    #expect(RelatedQueries.search(query: "r", visibleNodeIDs: [n.id],
                                  excludingIDs: [], k: 5, store: s, db).isEmpty)
    #expect(RelatedQueries.search(query: "   ", visibleNodeIDs: [n.id],
                                  excludingIDs: [], k: 5, store: s, db).isEmpty)
  }

  /// Best-effort: an unavailable index degrades to no related results, never a throw. (`/dev/null`
  /// is a character device, so no directory can be created under it and the store's
  /// delete-and-retry recovery cannot rescue the path — see TextIndexStoreTests.)
  @Test func anUnavailableStoreReturnsNothing() async throws {
    let db = try openCanonicalDatabase(at: tempURL("relq-unavailable"))
    let n = Node(name: "Refunds", kind: NodeKind.project)
    try await db.write { try Node.insert { n }.execute($0) }
    let dead = TextIndexStore(url: URL(fileURLWithPath: "/dev/null/nope/text-index.sqlite"))

    #expect(RelatedQueries.search(query: "refunds", visibleNodeIDs: [n.id], excludingIDs: [],
                                  k: 5, store: dead, db).isEmpty)
  }

  @Test func resultsAreOrderedBestFirstAndCappedAtK() async throws {
    let db = try openCanonicalDatabase(at: tempURL("relq-order"))
    let strong = Node(name: "background sync agent login items", kind: NodeKind.project)
    let weak = Node(name: "sync notes", kind: NodeKind.project)
    let other = Node(name: "sync inbox", kind: NodeKind.project)
    try await db.write { db in
      try Node.insert { strong }.execute(db)
      try Node.insert { weak }.execute(db)
      try Node.insert { other }.execute(db)
    }
    let s = try indexed(db)
    let visible: Set<UUID> = [strong.id, weak.id, other.id]

    let hits = RelatedQueries.search(query: "background sync login", visibleNodeIDs: visible,
                                     excludingIDs: [], k: 2, store: s, db)
    #expect(hits.count == 2)
    #expect(hits.first?.id == strong.id)
    #expect(hits[0].similarity >= hits[1].similarity)
  }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `./scripts/test.sh --filter RelatedQueriesTests`
Expected: FAIL to compile — "cannot find 'RelatedQueries' in scope".

- [ ] **Step 3: Extract the shared resolver**

Create `Sources/PensieveKit/Query/RelatedResolver.swift` — this is `SemanticQueries.resolve` moved verbatim, with `similarity:` renamed to `score:` (the two engines produce relevance in different units) and `SemanticHit` unchanged:

```swift
// Sources/PensieveKit/Query/RelatedResolver.swift
import Foundation
import SQLiteData

/// Re-resolve one retrieval-index row against canonical — the last grounding defense, so a
/// between-sync stale row never surfaces a dead hit. Shared by BOTH retrieval engines
/// (`RelatedQueries` over BM25 and `SemanticQueries` over the vector index) so the two can never
/// drift on what is eligible: if the index widens to archived but this predicate does not, archived
/// rows pass retrieval and are then silently dropped here. Same predicate shape as `SearchQueries`
/// uses for exact search.
enum RelatedResolver {
  static func resolve(kind: String, itemID: UUID, score: Double,
                      includeArchived: Bool, query: String,
                      _ db: any DatabaseReader) throws -> SemanticHit? {
    func eligible(_ n: Node) -> Bool {
      n.state == .active || (includeArchived && n.state == .archived)
    }
    return try db.read { db in
      switch kind {
      case "node":
        guard let n = try Node.where { $0.id.eq(itemID) }.fetchOne(db), eligible(n) else { return nil }
        return SemanticHit(id: n.id, kind: kind, nodeID: n.id, nodeName: n.name, title: n.name,
                           snippet: SnippetMaker.make(from: n.description.isEmpty ? n.name : n.description, matching: query),
                           similarity: score, isArchived: n.state == .archived)
      case "loose_end":
        guard let le = try LooseEnd.where { $0.id.eq(itemID) && LooseEnd.isOpen($0) }.fetchOne(db),
              let n = try Node.where { $0.id.eq(le.nodeID) }.fetchOne(db), eligible(n) else { return nil }
        return SemanticHit(id: le.id, kind: kind, nodeID: le.nodeID, nodeName: n.name, title: le.text,
                           snippet: SnippetMaker.make(from: le.text, matching: query),
                           similarity: score, isArchived: n.state == .archived)
      case "event":
        guard let e = try Event.where { $0.id.eq(itemID) }.fetchOne(db),
              let n = try Node.where { $0.id.eq(e.nodeID) }.fetchOne(db), eligible(n) else { return nil }
        let body = (e.workSummary?.isEmpty == false ? e.workSummary! : e.summary)
        return SemanticHit(id: e.id, kind: kind, nodeID: e.nodeID, nodeName: n.name, title: body,
                           snippet: SnippetMaker.make(from: body, matching: query),
                           similarity: score, isArchived: n.state == .archived)
      default: return nil
      }
    }
  }
}
```

- [ ] **Step 4: Point `SemanticQueries` at the shared resolver**

In `Sources/PensieveKit/Query/SemanticQueries.swift`:

1. Extend the `similarity` doc on `SemanticHit` (replace line 12, `public let similarity: Double`):

```swift
  /// Relevance in the producing engine's own units — a BM25 score (positive, unbounded, scaled per
  /// query) from `RelatedQueries`, or a cosine similarity (0…1) from `SemanticQueries`. Higher is
  /// better in both. Comparable only WITHIN one result set: never across queries, never across
  /// engines, and never as an absolute quality threshold.
  public let similarity: Double
```

2. In `buildHits`, replace the `resolve(...)` call (line 72-73) with the shared one:

```swift
      guard let hit = try? RelatedResolver.resolve(kind: r.kind, itemID: itemID, score: r.similarity,
                                                   includeArchived: includeArchived, query: query, db) else { continue }
```

3. Delete the whole private `resolve` function (lines 80-113, from the `/// Re-resolve one index row…` doc comment through its closing brace) — it now lives in `RelatedResolver`.

4. Add to the `SemanticQueries` type doc (after line 26, before `public enum SemanticQueries {`):

```swift
/// **Not wired to any surface.** ⌘F "Related" and the MCP `search` tool run on `RelatedQueries`
/// (BM25) since the 2026-08-02 retrieval remediation — mean-pooled contextual embeddings measured
/// as a ranking failure, not a threshold-calibration problem (P@1 0.250 vs BM25's 0.433). This
/// path is retained, tested, and reachable for the P3 eval harness that decides whether a real
/// sentence encoder is worth bundling. See `specs/2026-07-28-retrieval-eval-harness-design.md`.
```

- [ ] **Step 5: Implement `RelatedQueries`**

Create `Sources/PensieveKit/Query/RelatedQueries.swift`:

```swift
// Sources/PensieveKit/Query/RelatedQueries.swift
import Foundation
import SQLiteData

/// Keyword ("find related work") recall over the BM25 index, joined back to the live canonical
/// corpus. Retrieval is fixed-k and pre-filter, so a fixed fetch could return only Focus-muted rows:
/// this over-fetches from the store, applies `visibleNodeIDs`/`excludingIDs`, then re-resolves each
/// survivor against canonical through the shared `RelatedResolver` — the same "is this still part of
/// the live corpus" predicate the index itself uses — as the last line of grounding defense.
/// Best-effort: an unavailable index or an unusable query yields `[]`, never throws.
///
/// **There is no relevance floor, by design.** BM25 scores are unbounded and scaled per query, so a
/// fixed cutoff would be meaningless (the vector path's `floor: 0.25` was measured inert). Relevance
/// here is bounded by rank (`k`) plus the requirement that a document actually contain query terms —
/// which, unlike an anisotropic cosine, is a real signal. **A rank cap is not a relevance threshold:**
/// for a single common term this will still return `k` weak matches. Earning a real threshold is
/// exactly what the P3 harness exists to do.
///
/// Synchronous on purpose (no embedding step, so nothing to await) — a `@MainActor` caller must
/// offload it, e.g. `await Task.detached { RelatedQueries.search(…) }.value`.
public enum RelatedQueries {
  public static func search(query rawQuery: String,
                            visibleNodeIDs: Set<UUID>,
                            excludingIDs: Set<UUID>,
                            k: Int,
                            includeArchived: Bool = false,
                            store: TextIndexStore,
                            _ db: any DatabaseReader) -> [SemanticHit] {
    let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    guard query.count >= SearchQueries.minQueryLength, k > 0, store.isAvailable else { return [] }

    // Grow the fetch window when post-retrieval filtering (Focus-muting, exclusions, stale rows)
    // starves the result below k. BM25 ordering is deterministic and score-descending, so each
    // larger fetch is a superset prefix and rebuilding from the top is correct. Exits as soon as
    // the store is exhausted (`raw.count < kFetch`) so an ordinary sparse query costs one fetch.
    var kFetch = max(k * 8, 50)
    let maxFetch = 2000
    while true {
      let raw = store.search(query: query, k: kFetch, includeArchived: includeArchived)
      let hits = buildHits(raw, k: k, visibleNodeIDs: visibleNodeIDs, excludingIDs: excludingIDs,
                           includeArchived: includeArchived, query: query, db)
      if hits.count >= k || raw.count < kFetch || kFetch >= maxFetch { return hits }
      kFetch = min(kFetch * 4, maxFetch)
    }
  }

  /// Filter one BM25 page down to at most `k` grounded, visible, non-excluded hits.
  private static func buildHits(_ raw: [BM25Result], k: Int,
                                visibleNodeIDs: Set<UUID>, excludingIDs: Set<UUID>,
                                includeArchived: Bool,
                                query: String, _ db: any DatabaseReader) -> [SemanticHit] {
    var hits: [SemanticHit] = []
    for r in raw {
      guard let nodeID = UUID(uuidString: r.nodeID), visibleNodeIDs.contains(nodeID) else { continue }
      guard let itemID = UUID(uuidString: r.itemID), !excludingIDs.contains(itemID) else { continue }
      guard let hit = try? RelatedResolver.resolve(kind: r.kind, itemID: itemID, score: r.score,
                                                   includeArchived: includeArchived, query: query, db) else { continue }
      hits.append(hit)
      if hits.count == k { break }
    }
    return hits
  }
}
```

- [ ] **Step 6: Run the tests to verify they pass**

Run: `./scripts/test.sh --filter RelatedQueriesTests`
Expected: PASS — 10 tests.

Run: `./scripts/test.sh --filter SemanticQueriesTests`
Expected: PASS — the vector path's existing tests are unchanged and must stay green after the resolver extraction. **If any fail, the extraction was not verbatim** — diff `RelatedResolver.resolve` against the deleted `SemanticQueries.resolve` before touching anything else.

Run: `./scripts/test.sh`
Expected: PASS — 558 tests (548 + 10).

- [ ] **Step 7: Commit**

```bash
git add Sources/PensieveKit/Query/RelatedResolver.swift Sources/PensieveKit/Query/RelatedQueries.swift Sources/PensieveKit/Query/SemanticQueries.swift Tests/PensieveKitTests/RelatedQueriesTests.swift
git commit -F - <<'EOF'
feat(retrieval): RelatedQueries over BM25, sharing one grounding resolver

Extracts SemanticQueries' canonical re-resolve into RelatedResolver so both engines
share ONE implementation of every grounding guard — the drift the vector path's own
comment warned about (index widens to archived, re-check does not, hits vanish).

RelatedQueries mirrors the over-fetch/filter/re-resolve pipeline without a floor:
BM25 scores are unbounded and per-query-scaled, so a fixed cutoff is meaningless.
Relevance is bounded by rank plus the requirement that a document contain query
terms. A rank cap is not a relevance threshold — that is P3's job.

SemanticQueries is retained, tested, and now documented as wired to nothing.

Spec: docs/superpowers/specs/2026-07-28-retrieval-eval-harness-design.md (P2)

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_017jpKhJZCEtKSagji4yzECH
EOF
```

---

### Task 4: Maintain the index in `SyncRunner`

The daemon/CLI side of index maintenance. Replaces the vector-index block: the text index is what the surfaces read now, so it is what sync keeps fresh.

**Files:**
- Modify: `Sources/PensieveKit/Sync/SyncRunner.swift:9-22` (stored property + init) and `:50-60` (the maintenance block)
- Test: `Tests/PensieveKitTests/SyncRunnerTests.swift:104-125` (rewrite `syncPopulatesSemanticIndexWhenEnabled`)

**Interfaces:**
- Consumes: `TextIndexStore` (Task 2), `EmbeddableCorpus.gather` (Task 1), `PensievePaths.textIndexURL()`, `PensieveDefaults.semanticSearchEnabled()`.
- Produces: `SyncRunner.init(spool:db:provider:projectsDir:now:textIndexStore:)` — the trailing `semanticIndexer:` parameter is **replaced** by `textIndexStore: TextIndexStore? = nil`. Both production callers (`Sources/pensieve/Commands/Sync.swift:10`, `Sources/PensieveSyncAgent/PensieveSyncAgent.swift:17`) omit it and need no change.

- [ ] **Step 1: Rewrite the failing test**

In `Tests/PensieveKitTests/SyncRunnerTests.swift`, replace the whole `syncPopulatesSemanticIndexWhenEnabled` test (lines 104-125) with:

```swift
/// Proves the injected `textIndexStore` is rebuilt at the end of `run()` from the live corpus
/// (an active node is embeddable content per `EmbeddableCorpus.gather`).
@Test func syncPopulatesTextIndexWhenEnabled() async throws {
  let projects = tmp("projects", ext: "d")
  try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
  let spool = try CaptureSpool(at: tmp("sync-spool", ext: "sqlite"))
  let db = try openCanonicalDatabase(at: tmp("sync-canon", ext: "sqlite"))

  try await db.write { db in
    let n = Node(name: "Indexed refunds project", kind: NodeKind.project)
    try Node.insert { n }.execute(db)
  }

  let store = TextIndexStore(url: tmp("t", ext: "sqlite"))
  let runner = SyncRunner(spool: spool, db: db, provider: NoopProvider(), projectsDir: projects,
                          now: { Date() }, textIndexStore: store)
  _ = try await runner.run()

  #expect(!store.search(query: "refunds", k: 5, includeArchived: false).isEmpty)
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `./scripts/test.sh --filter syncPopulatesTextIndexWhenEnabled`
Expected: FAIL to compile — "incorrect argument label in call (have 'textIndexStore:', expected 'semanticIndexer:')".

- [ ] **Step 3: Swap the dependency and the maintenance block**

In `Sources/PensieveKit/Sync/SyncRunner.swift`:

1. Replace the stored property (line 16) `let semanticIndexer: SemanticIndexer?` with:

```swift
  let textIndexStore: TextIndexStore?
```

2. Replace the init (lines 18-22) with:

```swift
  public init(spool: CaptureSpool, db: any DatabaseWriter, provider: any LLMProvider,
              projectsDir: URL, now: @escaping @Sendable () -> Date = Date.init,
              textIndexStore: TextIndexStore? = nil) {
    self.spool = spool; self.db = db; self.provider = provider
    self.projectsDir = projectsDir; self.now = now; self.textIndexStore = textIndexStore
  }
```

3. Replace the maintenance block (lines 50-60) with:

```swift
    // Keyword index refresh (best-effort, toggle-gated). Never blocks the sync summary: a rebuild
    // is a whole-table rewrite of ~2k short rows and short-circuits on an unchanged fingerprint.
    if PensieveDefaults.semanticSearchEnabled() {
      let store = textIndexStore ?? TextIndexStore(url: PensievePaths.textIndexURL())
      if store.isAvailable, let corpus = try? EmbeddableCorpus.gather(db) {
        store.rebuild(items: corpus)
      }
    }
```

Note the deliberate difference from the old block: an injected store is honored, but the *gate* now applies to both the injected and the default path (the old code ran an injected indexer unconditionally). The test above sets no defaults, and `semanticSearchEnabled()` returns true when unset.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `./scripts/test.sh --filter SyncRunner`
Expected: PASS.

Run: `./scripts/test.sh`
Expected: PASS — 558 tests (unchanged count; one test was rewritten, not added).

- [ ] **Step 5: Verify the CLI and sync agent still build**

Run: `swift build`
Expected: builds clean — both `SyncRunner` callers use the defaulted parameter.

- [ ] **Step 6: Commit**

```bash
git add Sources/PensieveKit/Sync/SyncRunner.swift Tests/PensieveKitTests/SyncRunnerTests.swift
git commit -F - <<'EOF'
feat(retrieval): sync maintains the BM25 index instead of the vector index

The keyword index is what the surfaces read now, so it is what the daemon keeps
fresh. Vector maintenance is dropped rather than kept alongside: it would burn CPU
and download the NL asset to maintain an index no reader consults.

Rebuild short-circuits on an unchanged corpus fingerprint, so the steady-state
300 s cycle costs one hash.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_017jpKhJZCEtKSagji4yzECH
EOF
```

---

### Task 5: App — ⌘F "Related" on BM25, and honest Settings copy

Swap the app's query + index maintenance, and rewrite the Settings toggle's copy so it no longer promises "by meaning". The toggle keeps its key (`app.semanticSearch`) and its default (ON) — only its meaning and wording change.

**Files:**
- Modify: `Sources/PensieveApp/AppModel.swift` — lines 254-255 (stale scope comment), 267-270 (the embedder/vector store properties), 341-347 (index maintenance), 528-535 (the query)
- Modify: `Sources/PensieveApp/AppDefaults.swift:26-31` (doc comment only)
- Modify: `Sources/PensieveApp/Settings/IntelligenceSettingsTab.swift:66-68` (toggle copy)
- Modify: `Sources/PensieveApp/Localizable.xcstrings` (retire 2 keys, add 2)

**Interfaces:**
- Consumes: `RelatedQueries.search(query:visibleNodeIDs:excludingIDs:k:includeArchived:store:_:)` (Task 3, **synchronous**), `TextIndexStore` (Task 2), `EmbeddableCorpus.gather` (Task 1).
- Produces: no new API. `AppModel.semanticHits: [SemanticHit]` keeps its name and type, so `ContentListView`'s "Related" section (`ContentListView.swift:100-116`) needs **no change**.

- [ ] **Step 1: Replace the vector store with the text index**

In `Sources/PensieveApp/AppModel.swift`, replace lines 267-270:

```swift
  // Built once; NLContextualEmbedder resolves dimension from the loaded asset at init.
  @ObservationIgnored private lazy var embedder: NLContextualEmbedder = NLContextualEmbedder()
  @ObservationIgnored private lazy var semanticStore = SemanticIndexStore(
    url: PensievePaths.semanticIndexURL(), dimension: embedder.dimension, embedderVersion: embedder.version)
```

with:

```swift
  // The keyword ("Related") index. Opened lazily once; no embedder, no on-device model asset.
  @ObservationIgnored private lazy var textStore = TextIndexStore(url: PensievePaths.textIndexURL())
```

- [ ] **Step 2: Fix the now-stale search-scope comment**

Replace lines 254-255:

```swift
  /// ⌘F search scope. `.all` opts archived nodes into EXACT results (semantic "Related" stays
  /// active-only — the semantic index holds no archived content). Observable → drives the scope bar.
```

with:

```swift
  /// ⌘F search scope. `.all` opts archived nodes into BOTH halves — exact results and "Related".
  /// Observable → drives the scope bar.
```

- [ ] **Step 3: Rebuild the index on the launch/⌘R cadence**

Replace lines 341-347 (the `// Best-effort semantic index catch-up…` block through its closing brace):

```swift
    // Best-effort keyword index catch-up (launch + ⌘R cadence, mirroring SpotlightIndexer above).
    // The sync daemon also rebuilds periodically; this just keeps ⌘F "Related" fresh sooner after
    // in-app activity. Detached + toggle-gated so it never blocks the UI refresh, and a no-op when
    // the corpus fingerprint is unchanged.
    if AppDefaults.semanticSearchEnabled, let db {
      let store = textStore
      Task.detached {
        if let corpus = try? EmbeddableCorpus.gather(db) { store.rebuild(items: corpus) }
      }
    }
```

- [ ] **Step 4: Swap the query**

Replace lines 528-535 (from `guard AppDefaults.semanticSearchEnabled` through `self.semanticHits = sem`):

```swift
      guard AppDefaults.semanticSearchEnabled else { self.semanticHits = []; return }
      let exact = Set((results?.nodes.map { $0.id } ?? []) + (results?.looseEnds.map { $0.id } ?? []))
      let store = self.textStore
      // RelatedQueries is synchronous (no embedding step) — offload it exactly like the exact
      // search above, so a @MainActor keystroke never runs SQLite reads on the main thread.
      let sem = await Task.detached {
        RelatedQueries.search(query: query, visibleNodeIDs: visible, excludingIDs: exact, k: 8,
                              includeArchived: includeArchived, store: store, db)
      }.value
      guard self.searchToken == token, !Task.isCancelled else { return }
      self.semanticHits = sem
```

- [ ] **Step 5: Update the `AppDefaults` doc comment**

Replace lines 26-31 of `Sources/PensieveApp/AppDefaults.swift`:

```swift
  /// "Related" results are ON by default (matching the @AppStorage default and the Kit reader).
  /// The key name is historical — it gated the vector index before the 2026-08-02 retrieval
  /// remediation, and now gates the BM25 "Related" section and its index. Kept as-is so an
  /// existing user's explicit choice isn't reset by a rename.
  static var semanticSearchEnabled: Bool {
    UserDefaults.standard.object(forKey: PensieveDefaults.semanticSearchKey) == nil
      ? true : UserDefaults.standard.bool(forKey: PensieveDefaults.semanticSearchKey)
  }
```

- [ ] **Step 6: Rewrite the Settings copy**

In `Sources/PensieveApp/Settings/IntelligenceSettingsTab.swift`, replace lines 66-68:

```swift
        Toggle("Semantic search (find by meaning)", isOn: $semanticSearchEnabled)
        Text("Builds an on-device index so ⌘F and Claude Code can find work by meaning, not just exact words. First use downloads a small on-device model.")
          .font(.caption).foregroundStyle(.secondary)
```

with:

```swift
        Toggle("Find related work", isOn: $semanticSearchEnabled)
        Text("Builds an on-device index so ⌘F and Claude Code can surface related summaries, loose ends and commit messages under “Related”. Matches the words you type.")
          .font(.caption).foregroundStyle(.secondary)
```

- [ ] **Step 7: Reconcile the String Catalog by hand**

`xcodebuild` does **not** populate `.xcstrings` — author both keys manually, keeping the file's alphabetical-ish ordering and its exact 2-space-indent JSON shape.

Delete the entry `"Semantic search (find by meaning)"` (currently at line 2023) and the entry `"Builds an on-device index so ⌘F and Claude Code can find work by meaning, not just exact words. First use downloads a small on-device model."` (currently at line 15), and add:

```json
    "Builds an on-device index so ⌘F and Claude Code can surface related summaries, loose ends and commit messages under “Related”. Matches the words you type." : {
      "extractionState" : "manual",
      "localizations" : {
        "de" : {
          "stringUnit" : {
            "state" : "translated",
            "value" : "Erstellt einen geräteinternen Index, damit ⌘F und Claude Code verwandte Zusammenfassungen, offene Enden und Commit-Nachrichten unter „Verwandt“ anzeigen können. Findet die eingegebenen Wörter."
          }
        }
      }
    },
```

```json
    "Find related work" : {
      "extractionState" : "manual",
      "localizations" : {
        "de" : {
          "stringUnit" : {
            "state" : "translated",
            "value" : "Verwandte Arbeit finden"
          }
        }
      }
    },
```

(The existing `"Related"` → `"Verwandt"` key stays — the German copy above deliberately reuses that word so the Settings text and the ⌘F section header agree.)

Verify the file is still valid JSON:

Run: `plutil -lint Sources/PensieveApp/Localizable.xcstrings`
Expected: `OK`

- [ ] **Step 8: Build and smoke-launch the app**

```bash
xcodegen generate
xcodebuild -project Pensieve.xcodeproj -scheme Pensieve -configuration Debug \
  -derivedDataPath ./.build-xcode build
```
Expected: `BUILD SUCCEEDED`, with no reference left to `semanticStore` or `embedder` in `AppModel`.

Then a non-blocking smoke-launch of the **inner binary** against throwaway stores:

```bash
PENSIEVE_DB=/tmp/pensieve-smoke.sqlite PENSIEVE_CAPTURE_DB=/tmp/pensieve-smoke-capture.sqlite \
  ./.build-xcode/Build/Products/Debug/Pensieve.app/Contents/MacOS/Pensieve &
sleep 5; kill %1
```
Expected: launches and stays up for 5 s with no crash. Check for the German catalog:

```bash
ls ./.build-xcode/Build/Products/Debug/Pensieve.app/Contents/Resources/de.lproj/
```
Expected: contains `Localizable.strings`.

- [ ] **Step 9: Commit**

```bash
git add Sources/PensieveApp/AppModel.swift Sources/PensieveApp/AppDefaults.swift Sources/PensieveApp/Settings/IntelligenceSettingsTab.swift Sources/PensieveApp/Localizable.xcstrings
git commit -F - <<'EOF'
feat(app): ⌘F "Related" runs on BM25, with honest Settings copy

AppModel swaps the vector store + embedder for TextIndexStore, rebuilds the keyword
index on the launch/⌘R cadence, and offloads the (synchronous) RelatedQueries read
so a keystroke never runs SQLite on the main thread. ContentListView is untouched —
semanticHits keeps its name and type.

The Settings toggle keeps its key and its ON default; only the copy changes. It no
longer promises "find by meaning", because the shipped engine matches words. German
reuses "Verwandt" so Settings and the ⌘F section header agree.

Also fixes the now-stale search-scope comment: Include Archived drives both halves.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_017jpKhJZCEtKSagji4yzECH
EOF
```

---

### Task 6: MCP — `search` returns BM25-ranked related items

The surface every Claude Code session actually calls. Same JSON contract, better ranking, honest tool + field descriptions.

**Files:**
- Modify: `Sources/pensieve/Commands/Mcp.swift` — lines 39-46 (tool description), 127-134 (the cached statics), 196-224 (`searchJSON`), 240-242 (the payload doc)

**Interfaces:**
- Consumes: `RelatedQueries.search(...)` (Task 3), `TextIndexStore` (Task 2), `PensievePaths.textIndexURL()`.
- Produces: no API change. `SearchPayload`/`SearchItem` keep every key: `{ "exact": [...], "related": [...] }` with `id, kind, node_id, node_name, title, snippet, similarity, archived`.

- [ ] **Step 1: Replace the cached vector statics**

In `Sources/pensieve/Commands/Mcp.swift`, replace lines 127-134:

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

with:

```swift
  // Built once for the server's lifetime (the MCP process is long-lived): the index pool open is
  // otherwise repeated on every `search` call. Sendable. Caveat: the cached handle isn't reopened
  // mid-session — acceptable, the server is session-scoped and the app/daemon own rebuilds.
  private static let textStore = TextIndexStore(url: PensievePaths.textIndexURL())
```

- [ ] **Step 2: Swap the query in `searchJSON`**

Replace the doc comment and the `related` block (lines 196-200 and 217-224).

The doc comment (lines 196-200) becomes:

```swift
  /// Unified "find across my work" tool: exact substring match (`SearchQueries`) plus, when the
  /// related-results toggle is on, keyword-ranked related items (`RelatedQueries` over the BM25
  /// index) — excluding anything already surfaced as an exact hit. Scope is all active nodes (MCP
  /// has no Focus context), widened to archived by `include_archived`, which gates the exact and
  /// related halves alike. Everything is local: no model, no network, no cloud.
```

The `related` block (lines 217-224) becomes:

```swift
    let related: [SemanticHit]
    if PensieveDefaults.semanticSearchEnabled() {
      related = RelatedQueries.search(query: query, visibleNodeIDs: visible, excludingIDs: exactIDs,
                                      k: limit, includeArchived: includeArchived,
                                      store: textStore, db)
    } else {
      related = []
    }
```

- [ ] **Step 3: Correct the tool description and the `similarity` contract note**

Replace the `search` tool description (line 40):

```swift
             description: "Find across all your work by keyword — exact matches first, related items below, ranked by relevance; each result is a real, cited item.",
```

Replace the `SearchPayload` doc (lines 240-242):

```swift
/// The `search` tool's response shape: `{ "exact": [...], "related": [...] }`. `similarity` is
/// present only on related items — `encode(to:)` omits it (not `null`) for exact items, which have
/// no score. It is a BM25 relevance in unbounded, per-query units where higher is better: rank the
/// related list by it, but never read it as an absolute quality threshold or compare it across
/// queries.
```

- [ ] **Step 4: Build the CLI**

```bash
xcodebuild -project Pensieve.xcodeproj -scheme PensieveCLI -configuration Debug \
  -derivedDataPath ./.build-xcode build
```
Expected: `BUILD SUCCEEDED`.

- [ ] **Step 5: Exercise the tool end-to-end against a throwaway store**

`Sources/pensieve` has no unit-test target, so verify by hand. Use a throwaway canonical store — **do not point this at the live store.**

```bash
BIN=./.build-xcode/Build/Products/Debug/pensieve
export PENSIEVE_DB=/tmp/pensieve-mcp-smoke.sqlite
export PENSIEVE_CAPTURE_DB=/tmp/pensieve-mcp-smoke-capture.sqlite
rm -f "$PENSIEVE_DB" "$PENSIEVE_CAPTURE_DB"
$BIN add-node "Refunds pipeline overhaul" --kind project
$BIN sync
printf '%s\n' \
  '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"smoke","version":"1"}}}' \
  '{"jsonrpc":"2.0","method":"notifications/initialized"}' \
  '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"search","arguments":{"query":"refunds","limit":5}}}' \
  | $BIN mcp
```
Expected: the id-2 response contains a `related` (or `exact`) entry for the node, and every related item carries a positive `similarity`. Note `sync` is what builds the index — a `search` before any `sync` legitimately returns `{"exact":[],"related":[]}`.

Clean up: `rm -f /tmp/pensieve-mcp-smoke*.sqlite*` and, if `PensievePaths.textIndexURL()` was written under the real support dir during this smoke run, leave it — the next real sync rebuilds it correctly.

- [ ] **Step 6: Commit**

```bash
git add Sources/pensieve/Commands/Mcp.swift
git commit -F - <<'EOF'
feat(mcp): search returns BM25-ranked related items

Same JSON contract (exact/related, every key unchanged), better ranking, and no
embedder or model asset in the MCP process at all. The tool description no longer
claims "by meaning", and the similarity field is documented as an unbounded
per-query BM25 relevance — rank by it, never threshold on it.

This is the surface that was diluting every Claude Code session's context.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_017jpKhJZCEtKSagji4yzECH
EOF
```

---

### Task 7: Close the defect in the docs

The OPEN DEFECT entry, the Status changelog, and the handoff all still describe the inert floor as the problem. Correct them, and record precisely what P2 did and did not earn.

**Files:**
- Modify: `docs/superpowers/backlog.md:211` (the "Semantic relevance floor is inert — OPEN DEFECT" section)
- Modify: `CLAUDE.md` (Status list — add a bullet after the transcript-readability one; update the "Next" bullet's Track C line)
- Modify: `CONTINUE.md` (the ⚠️ defect warning, "Most recent ships", "THE NEXT ACTION")

**Interfaces:** none (documentation only).

- [ ] **Step 1: Rewrite the backlog defect entry**

Replace the heading at `backlog.md:211` —

```markdown
## Semantic relevance floor is inert — OPEN DEFECT (found 2026-07-19, needs its own spec)
```

— with:

```markdown
## Semantic recall was a ranking failure — P1+P2 DONE (2026-08-02), P3 open
```

and rewrite its body to keep the measurements (they are the evidence base for P3) while stating:

- The diagnosis changed: **ranking failure, not scale failure**. The inert floor was a symptom.
- **Shipped 2026-08-02:** P1 corpus hygiene (2,630 → 2,264 items; BM25 P@1 0.387 → 0.433) and P2 (BM25 behind ⌘F "Related" + MCP `search`; floor removed, not retuned; vector retained in-tree, wired to nothing).
- **Still open — P3:** the paraphrase harness. Both engines fail "find without remembering the words" (`vector` ≈ 0/8, `bm25` ≈ 2/8 on hand-written short queries). **Blocked on the user writing 30–50 paraphrase queries** as the gold set. Its decision rule and absolute floor are pre-registered in the spec.
- **A rank cap is not a relevance threshold** — P2 did not earn one, and P3 is what would.
- Cross-reference `specs/2026-07-28-retrieval-eval-harness-design.md` and `measurements/2026-07-28-retrieval-recall/`.

- [ ] **Step 2: Add the CLAUDE.md Status bullet**

Insert after the transcript-readability bullet, in the established house style (what shipped, Kit vs app split, what stayed sacred, test count, spec/plan paths):

- **Retrieval P1 + P2 — corpus hygiene and BM25 "Related" — DONE**. P1: `EmbeddableCorpus.gather` drops `git.checkout` events + exact-duplicate texts. P2: new `TextIndexStore` (FTS5 + `bm25()` in a separate, rebuildable, never-synced `text-index.sqlite` — separate from the vector store because that one's `prepareDatabase` throws when sqlite-vec can't register) + `RelatedQueries`, sharing **one** extracted `RelatedResolver` with `SemanticQueries` so the grounding guards can't drift. The `0.25` floor is **removed, not retuned**. The vector stack is retained, tested, and wired to nothing (P3 only). The Settings toggle keeps its key + ON default; only the copy changed ("Find related work"). **Trust gate untouched** — retrieval only chooses which real stored rows are eligible.
- Update the **Next** bullet: Track C's remaining items become **P3 (blocked on the user's gold set)** + transcript-passage chunking.

- [ ] **Step 3: Refresh CONTINUE.md**

- Delete the "**One OPEN DEFECT is live in production**" warning; replace with a line noting P1+P2 shipped and P3 is the open question, gated on the gold set.
- Add a "Most recent ships" entry (newest first) matching the CLAUDE.md bullet.
- Rewrite "THE NEXT ACTION" so the ⚠️ first item is **P3 — write 30–50 paraphrase queries**, with Track A slice 5 and transcript-passage chunking as the alternatives.
- Add to the post-merge carries: **rebuild + reinstall to `/Applications`** so the bundled `pensieve mcp` and the app pick up BM25 (the installed app is already several ships stale), then verify `ls -l ~/.local/bin/pensieve` is still a symlink.
- Note that `~/Library/Application Support/Pensieve/semantic-index.sqlite` is now inert and safe to delete by hand; nothing deletes it automatically.

- [ ] **Step 4: Verify**

Run: `./scripts/test.sh`
Expected: PASS — 558 tests.

Run: `git status --short`
Expected: only the three doc files modified (discard any transient `Package.resolved` churn from the xcodebuild runs: `git checkout Package.resolved`).

- [ ] **Step 5: Commit**

```bash
git add CLAUDE.md CONTINUE.md docs/superpowers/backlog.md
git commit -F - <<'EOF'
docs: close the semantic-recall defect — P1+P2 shipped, P3 is the open question

The diagnosis changed and the docs still carried the old one: it was a ranking
failure, not threshold calibration. The inert floor was a symptom of an encoder
that doesn't discriminate.

Records what P2 earned (BM25 ranking, measured 1.7x better P@5) and what it did
NOT (a real relevance threshold — a rank cap is not one), and leaves P3 blocked on
30-50 hand-written paraphrase queries.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_017jpKhJZCEtKSagji4yzECH
EOF
```

---

## Verification checklist (before finishing the branch)

- [ ] `./scripts/test.sh` — **558 tests**, all passing (524 baseline + 4 hygiene + 20 store + 10 related; one SyncRunner test rewritten in place).
- [ ] `swift build` clean (Kit + CLI + sync agent).
- [ ] `xcodebuild -scheme Pensieve` and `-scheme PensieveCLI` both `BUILD SUCCEEDED`.
- [ ] Smoke-launch of the inner app binary survives 5 s against throwaway stores.
- [ ] `plutil -lint Sources/PensieveApp/Localizable.xcstrings` → OK; `de.lproj/Localizable.strings` present in the built bundle.
- [ ] The MCP `search` smoke run returns a related item with a positive `similarity`.
- [ ] `git grep -n "SemanticQueries\|SemanticIndexer" Sources/PensieveApp Sources/pensieve` returns **nothing** — the vector path is reachable only from Kit + tests.
- [ ] `git checkout Package.resolved` if xcodebuild churned it.

## Human-verify carries (need the built app at `/Applications`, the real store, plain `open`)

These cannot be scripted — the accessibility sandbox blocks driving the UI.

- ⌘F on a real query: the "Related" section is populated, rows land on the cited item, and results are visibly *more* relevant than before.
- The Include Archived scope now widens **both** halves — archived rows appear in Related with the archived badge.
- Settings ▸ Intelligence: the toggle reads "Find related work" with the new caption; flipping it off empties Related; flipping it back on repopulates after a ⌘R.
- German in situ (launch with `-AppleLanguages '(de)'`): "Verwandte Arbeit finden" in Settings, "Verwandt" as the ⌘F section header.
- After reinstalling to `/Applications`: `ls -l ~/.local/bin/pensieve` is still a symlink into `Contents/Helpers/` (a stale real binary there would silently keep serving old MCP code — this has bitten before).
- In a fresh Claude Code session, `search` via MCP on a phrase you remember loosely — the point of the whole exercise.
