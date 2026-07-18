# Semantic / vector recall — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Find any node, open loose end, or event by *meaning* (not exact words) across the in-app ⌘F surface and the MCP server, over one shared PensieveKit kernel, staying grounded and Focus-scoped.

**Architecture:** Native `NLContextualEmbedding` (on-device, per-token → mean-pooled, unit-normalized) produces vectors; `sqlite-vec` (vendored as a SwiftPM C target, statically registered via `sqlite3_auto_extension`) stores them in a **separate, rebuildable, never-synced `semantic-index.sqlite`**. An incremental reconciler keeps the index in step with the canonical store after each sync/drain; a query kernel does KNN + grounded post-filtering. Two thin surfaces: a ⌘F "Related" section and a unified MCP `search` tool.

**Tech Stack:** Swift 6, SQLiteData (GRDB-backed) over system SQLite, `sqlite-vec` (vendored C amalgamation), NaturalLanguage (`NLContextualEmbedding`), SwiftUI (app target), MCP Swift SDK (`PensieveCLI` only).

**Spec:** `docs/superpowers/specs/2026-07-18-semantic-vector-recall-design.md` (revised after two adversarial reviews).

## Global Constraints

- **Swift only. No Python, ever.**
- **On-device embeddings only.** The cloud provider is never used here (it serves narration only). Extraction/embedding stay on-device — trust gate untouched.
- **Grounded-retrieval-only.** Every surfaced hit is a real, cited node/loose end/event; the vector only ranks. Never fabricate, never surface an uncited/stale/now-excluded item. The query join re-applies the live corpus predicate as the last defense.
- **The index db is separate, disposable, never-synced, rebuildable.** Not `pensieve.sqlite`, not `capture.sqlite`. Mirror the `NarrationCache` pattern (best-effort open, delete-and-retry on corruption).
- **No `EvalTask`** for the embedder — it is a fixed native asset, not a `pensieve eval`-selectable generation model.
- **SQLiteData predicates use `.eq(x)` / `.neq(x)`, NOT `== x`.** Reuse `LooseEnd.isOpen`, `NodeKind`, `CaptureKind` constants. Tables are STRICT; canonical PKs are UUID.
- **No shared mutable `static` `ISO8601DateFormatter`** (Swift 6). Not needed here anyway.
- **The app target (`Sources/PensieveApp/`) has no unit tests.** Put all logic in tested PensieveKit; keep views thin. Verify app tasks with an `xcodebuild` build + a non-blocking smoke-launch of the inner binary with throwaway `PENSIEVE_DB`/`PENSIEVE_CAPTURE_DB`.
- **Platform floor:** `Package.swift` stays `.macOS(.v14)`; the app is 15.0. `NLContextualEmbedding` is macOS 14+ (no `@available` fences needed).
- **Kit tests run with `./scripts/test.sh --filter <name>`** (thin `swift test` passthrough). App builds with `xcodegen generate && xcodebuild -project Pensieve.xcodeproj -scheme Pensieve -configuration Debug -derivedDataPath ./.build-xcode build`.
- **Commits:** backticks in `-m` get shell-executed — use `git commit -F` with a quoted heredoc. Keep the `Co-Authored-By:` + `Claude-Session:` trailers.

---

### Task 0: sqlite-vec de-risk spike (GO/NO-GO gate)

**This task is a hard gate.** If `vec0` KNN cannot be made to work under `swift test`, STOP and report — the store architecture falls back to an app-owned index (a separate spec). Do not start Task 1+ until this passes.

**Files:**
- Create: `Sources/CSQLiteVec/sqlite-vec.c` (vendored amalgamation)
- Create: `Sources/CSQLiteVec/include/sqlite-vec.h` (vendored)
- Create: `Sources/CSQLiteVec/include/sqlite3ext.h` (vendored, if system headers lack it)
- Create: `Sources/CSQLiteVec/shim.c`
- Create: `Sources/CSQLiteVec/include/CSQLiteVec.h`
- Create: `Sources/CSQLiteVec/include/module.modulemap`
- Modify: `Package.swift`
- Test: `Tests/PensieveKitTests/SQLiteVecSpikeTests.swift`

**Interfaces:**
- Produces: a C function `int pensieve_sqlite_vec_register(void)` (registers sqlite-vec as an auto-extension for all subsequent SQLite connections in the process; returns `SQLITE_OK` on success), importable in Swift via `import CSQLiteVec`.

- [ ] **Step 1: Vendor the sqlite-vec amalgamation.** Download the release amalgamation (`sqlite-vec.c`, `sqlite-vec.h`) from the sqlite-vec GitHub releases (v0.1.x) into `Sources/CSQLiteVec/` and `Sources/CSQLiteVec/include/`. If a build later reports a missing `sqlite3ext.h`, also vendor `sqlite3ext.h` (+ the matching `sqlite3.h`) from the SQLite amalgamation into `include/`. Record the exact sqlite-vec version in a comment at the top of `shim.c`.

- [ ] **Step 2: Write the C shim** that keeps all SQLite C-interop in C (so Swift needs no `sqlite3` symbols).

`Sources/CSQLiteVec/shim.c`:
```c
// sqlite-vec vendored version: v0.1.x  (record exact tag)
#include <sqlite3.h>
// sqlite-vec's init entry point (defined in sqlite-vec.c)
extern int sqlite3_vec_init(sqlite3 *db, char **pzErrMsg, const sqlite3_api_routines *pApi);

// Register sqlite-vec so every subsequent connection in this process loads vec0.
int pensieve_sqlite_vec_register(void) {
  return sqlite3_auto_extension((void (*)(void))sqlite3_vec_init);
}
```

`Sources/CSQLiteVec/include/CSQLiteVec.h`:
```c
#ifndef CSQLITEVEC_H
#define CSQLITEVEC_H
int pensieve_sqlite_vec_register(void);
#endif
```

`Sources/CSQLiteVec/include/module.modulemap`:
```
module CSQLiteVec {
  header "CSQLiteVec.h"
  export *
}
```

- [ ] **Step 3: Add the C target to `Package.swift`** and make PensieveKit depend on it (so all three product targets inherit it transitively through the `PensieveKit` product).

Modify `Package.swift`:
```swift
targets: [
  .target(
    name: "CSQLiteVec",
    // sqlite-vec.c uses SQLITE_CORE-off extension mode; link the system sqlite3.
    cSettings: [.define("SQLITE_CORE", to: "0")],
    linkerSettings: [.linkedLibrary("sqlite3")]
  ),
  .target(
    name: "PensieveKit",
    dependencies: [
      .product(name: "SQLiteData", package: "sqlite-data"),
      "CSQLiteVec",
    ]
  ),
  .testTarget(
    name: "PensieveKitTests",
    dependencies: ["PensieveKit"],
    resources: [.copy("Fixtures")]
  ),
]
```

- [ ] **Step 4: Write the spike test** — register the extension, open a GRDB `DatabaseQueue`, create a `vec0` table, insert vectors, run a KNN query.

`Tests/PensieveKitTests/SQLiteVecSpikeTests.swift`:
```swift
import Testing
import Foundation
import SQLiteData   // re-exports GRDB
import CSQLiteVec
@testable import PensieveKit

@Suite struct SQLiteVecSpikeTests {
  @Test func vec0KNNReturnsNearestFirst() throws {
    #expect(pensieve_sqlite_vec_register() == 0)   // SQLITE_OK; auto-extension registered process-wide
    let queue = try DatabaseQueue()                // in-memory; new connection picks up the auto-extension
    try queue.write { db in
      try db.execute(sql: "CREATE VIRTUAL TABLE vt USING vec0(item_id TEXT PRIMARY KEY, embedding float[3])")
      try db.execute(sql: "INSERT INTO vt(item_id, embedding) VALUES (?, ?)",
                     arguments: ["a", "[1.0, 0.0, 0.0]"])
      try db.execute(sql: "INSERT INTO vt(item_id, embedding) VALUES (?, ?)",
                     arguments: ["b", "[0.0, 1.0, 0.0]"])
    }
    let ids = try queue.read { db in
      try String.fetchAll(db, sql: """
        SELECT item_id FROM vt WHERE embedding MATCH ? AND k = 2 ORDER BY distance
        """, arguments: ["[0.9, 0.1, 0.0]"])
    }
    #expect(ids.first == "a")   // nearest to the query vector
    #expect(ids.count == 2)
  }
}
```

- [ ] **Step 5: Run the spike test.**

Run: `./scripts/test.sh --filter SQLiteVecSpikeTests`
Expected: PASS. If it fails to compile on a missing `sqlite3ext.h`/`sqlite3.h`, vendor those headers (Step 1) and retry. If `vec0` is unknown at runtime, the auto-extension didn't register — verify `pensieve_sqlite_vec_register()` returns 0 and is called **before** the connection opens.

- [ ] **Step 6: GO/NO-GO checkpoint.** If PASS, commit and proceed. If it cannot be made to pass after resolving headers + registration, STOP and report — the store architecture needs the app-owned-index fallback.

- [ ] **Step 7: Commit**
```bash
git add Package.swift Sources/CSQLiteVec Tests/PensieveKitTests/SQLiteVecSpikeTests.swift
git commit -F - <<'EOF'
feat(kit): vendor sqlite-vec as a C target; prove vec0 KNN under swift test

De-risk gate for semantic recall: static sqlite3_auto_extension registration,
reachable by all targets through the PensieveKit product.
EOF
```

---

### Task 1: `TextEmbedder` protocol + stub + `NLContextualEmbedder`

**Files:**
- Create: `Sources/PensieveKit/Semantic/TextEmbedder.swift`
- Create: `Sources/PensieveKit/Semantic/NLContextualEmbedder.swift`
- Test: `Tests/PensieveKitTests/TextEmbedderTests.swift`

**Interfaces:**
- Produces:
  - `protocol TextEmbedder: Sendable { var version: String { get }; var dimension: Int { get }; func embed(_ texts: [String]) async -> [[Float]]? }`
  - `struct StubEmbedder: TextEmbedder` (deterministic; test-only helper, but lives in the main target so multiple test files use it) — configurable `dimension`/`version`, maps each string to a deterministic unit vector.
  - `struct NLContextualEmbedder: TextEmbedder` — the on-device default.
  - `enum EmbeddingMath { static func meanPool(_ tokenVectors: [[Float]]) -> [Float]; static func normalize(_ v: [Float]) -> [Float] }`

- [ ] **Step 1: Write the failing test** for the math helpers + stub determinism.

`Tests/PensieveKitTests/TextEmbedderTests.swift`:
```swift
import Testing
import Foundation
@testable import PensieveKit

@Suite struct TextEmbedderTests {
  @Test func meanPoolAveragesTokenVectors() {
    let pooled = EmbeddingMath.meanPool([[1, 0, 0], [0, 1, 0]])
    #expect(pooled == [0.5, 0.5, 0.0])
  }

  @Test func normalizeProducesUnitLength() {
    let n = EmbeddingMath.normalize([3, 4])   // |v| = 5
    #expect(abs((n[0] * n[0] + n[1] * n[1]) - 1.0) < 1e-6)
  }

  @Test func stubIsDeterministicAndUnit() async {
    let e = StubEmbedder(dimension: 8)
    let a = await e.embed(["hello"])
    let b = await e.embed(["hello"])
    #expect(a == b)
    let v = a![0]
    #expect(abs(v.reduce(0) { $0 + $1 * $1 } - 1.0) < 1e-6)   // unit length
  }
}
```

- [ ] **Step 2: Run to verify it fails.**
Run: `./scripts/test.sh --filter TextEmbedderTests`
Expected: FAIL (no `EmbeddingMath`/`StubEmbedder`).

- [ ] **Step 3: Write `TextEmbedder.swift`** (protocol + math + stub).
```swift
import Foundation

public protocol TextEmbedder: Sendable {
  var version: String { get }     // e.g. "nl-latin:512" — derived from the loaded model at runtime
  var dimension: Int { get }
  /// One unit-normalized vector per input string, or nil if the model asset is unavailable.
  func embed(_ texts: [String]) async -> [[Float]]?
}

public enum EmbeddingMath {
  public static func meanPool(_ tokenVectors: [[Float]]) -> [Float] {
    guard let first = tokenVectors.first else { return [] }
    var acc = [Float](repeating: 0, count: first.count)
    for v in tokenVectors { for i in v.indices { acc[i] += v[i] } }
    let n = Float(tokenVectors.count)
    return acc.map { $0 / n }
  }
  public static func normalize(_ v: [Float]) -> [Float] {
    let mag = v.reduce(Float(0)) { $0 + $1 * $1 }.squareRoot()
    guard mag > 0 else { return v }
    return v.map { $0 / mag }
  }
  /// Cosine similarity of two unit vectors from a sqlite-vec L2 `distance`: for unit vectors,
  /// L2² = 2 - 2·cos, so cos = 1 - distance²/2.
  public static func cosine(fromL2 distance: Double) -> Double { 1.0 - (distance * distance) / 2.0 }
}

/// Deterministic embedder for tests: a stable per-string unit vector (hash-seeded), no assets.
public struct StubEmbedder: TextEmbedder {
  public let dimension: Int
  public let version: String
  public init(dimension: Int = 16, version: String = "stub:16") {
    self.dimension = dimension; self.version = version
  }
  public func embed(_ texts: [String]) async -> [[Float]]? {
    texts.map { text in
      var seed = UInt64(bitPattern: Int64(text.hashValue))
      var v = [Float](repeating: 0, count: dimension)
      for i in 0..<dimension {                      // xorshift → deterministic pseudo-random
        seed ^= seed << 13; seed ^= seed >> 7; seed ^= seed << 17
        v[i] = Float(seed % 1000) / 1000.0 - 0.5
      }
      return EmbeddingMath.normalize(v)
    }
  }
}
```

- [ ] **Step 4: Run to verify PASS.**
Run: `./scripts/test.sh --filter TextEmbedderTests`
Expected: PASS.

- [ ] **Step 5: Write `NLContextualEmbedder.swift`** (the on-device default; mean-pool per-token vectors, unit-normalize, runtime dimension, best-effort nil).
```swift
import Foundation
import NaturalLanguage

/// On-device sentence embeddings via NLContextualEmbedding (by-script Latin, covers EN+DE).
/// Per-token model → mean-pooled + unit-normalized to one vector per string. Best-effort:
/// returns nil until the model asset is loaded (never throws, never blocks capture/ingest).
public final class NLContextualEmbedder: TextEmbedder, @unchecked Sendable {
  private let model: NLContextualEmbedding?
  public let dimension: Int
  public let version: String

  public init() {
    let m = NLContextualEmbedding(script: .latin)
    if let m, !m.hasAvailableAssets {
      // Kick off the async asset request; until it lands, embed() returns nil (best-effort).
      m.requestAssets { _, _ in }
    }
    self.model = m
    self.dimension = m?.dimension ?? 0
    self.version = "nl-latin:\(m?.dimension ?? 0)"
  }

  public func embed(_ texts: [String]) async -> [[Float]]? {
    guard let model, model.hasAvailableAssets else { return nil }
    do { try model.load() } catch { return nil }
    var out: [[Float]] = []
    for text in texts {
      guard let result = try? model.embeddingResult(for: text, language: nil) else { return nil }
      var tokens: [[Float]] = []
      result.enumerateTokenVectors(in: text.startIndex..<text.endIndex) { vec, _ in
        tokens.append(vec.map { Float($0) }); return true
      }
      guard !tokens.isEmpty else { return nil }
      out.append(EmbeddingMath.normalize(EmbeddingMath.meanPool(tokens)))
    }
    return out
  }
}
```
> Note: the exact NLContextualEmbedding call names (`hasAvailableAssets`, `requestAssets`, `load`, `embeddingResult(for:language:)`, `enumerateTokenVectors`) are from the NaturalLanguage API; if a signature differs on the toolchain, adapt minimally and keep the mean-pool + normalize + best-effort-nil contract. This type has no unit test (it needs the OS asset); it is exercised only through the real app/daemon.

- [ ] **Step 6: Build to confirm it compiles.**
Run: `swift build`
Expected: builds clean.

- [ ] **Step 7: Commit**
```bash
git add Sources/PensieveKit/Semantic Tests/PensieveKitTests/TextEmbedderTests.swift
git commit -F - <<'EOF'
feat(kit): TextEmbedder protocol + deterministic stub + NLContextualEmbedder

Per-token model mean-pooled + unit-normalized to one vector per string;
runtime dimension/version; best-effort nil when the asset is unavailable.
EOF
```

---

### Task 2: `SemanticIndexStore` (schema, upsert, prune, KNN, rebuild)

**Files:**
- Create: `Sources/PensieveKit/Semantic/SemanticIndexStore.swift`
- Modify: `Sources/PensieveKit/Support/PensievePaths.swift`
- Test: `Tests/PensieveKitTests/SemanticIndexStoreTests.swift`

**Interfaces:**
- Consumes: `pensieve_sqlite_vec_register()` (Task 0), `EmbeddingMath.cosine(fromL2:)` (Task 1).
- Produces:
  - `PensievePaths.semanticIndexURL() -> URL`
  - `struct IndexRow: Sendable { let itemID: String; let kind: String; let nodeID: String; let state: String; let contentHash: String }`
  - `struct KNNResult: Sendable { let itemID: String; let kind: String; let nodeID: String; let similarity: Double }`
  - `struct SemanticIndexStore: Sendable`:
    - `init(url: URL, dimension: Int, embedderVersion: String)` — opens/creates; best-effort; **drops + recreates when stored `meta.embedder_version` ≠ `embedderVersion`** (or dimension differs, or file corrupt).
    - `var isAvailable: Bool` (false when the db couldn't open / sqlite-vec missing → callers degrade).
    - `func existingItems() -> [String: String]` — map `item_id → content_hash` for the reconciliation diff.
    - `func upsert(row: IndexRow, embedding: [Float]?)` — insert/replace metadata; when `embedding` is non-nil, (re)write the vector; when nil, update metadata only (repoint/state change).
    - `func delete(itemIDs: [String])`
    - `func knn(query: [Float], k: Int, activeOnly: Bool) -> [KNNResult]` — vec0 KNN with an in-query `state='active'` filter when `activeOnly`; similarity via `EmbeddingMath.cosine(fromL2:)`.

- [ ] **Step 1: Add the path.** In `PensievePaths.swift`, after `narrationCacheURL()`:
```swift
  /// The disposable, device-local, never-synced semantic index (shared across app / CLI / daemon /
  /// MCP). Losing it costs only a re-index. Drop-and-rebuilt on embedder-version change.
  public static func semanticIndexURL() -> URL {
    supportDirectory().appendingPathComponent("semantic-index.sqlite")
  }
```

- [ ] **Step 2: Write the failing test.**

`Tests/PensieveKitTests/SemanticIndexStoreTests.swift`:
```swift
import Testing
import Foundation
@testable import PensieveKit

@Suite struct SemanticIndexStoreTests {
  private func tempURL() -> URL {
    URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("sem-\(UUID().uuidString).sqlite")
  }

  @Test func upsertThenKNNReturnsNearestWithMetadata() async {
    let store = SemanticIndexStore(url: tempURL(), dimension: 8, embedderVersion: "stub:8")
    #expect(store.isAvailable)
    let e = StubEmbedder(dimension: 8)
    let va = await e.embed(["alpha"])![0]
    let vb = await e.embed(["beta"])![0]
    store.upsert(row: .init(itemID: "a", kind: "loose_end", nodeID: "n1", state: "active",
                            contentHash: "h1"), embedding: va)
    store.upsert(row: .init(itemID: "b", kind: "loose_end", nodeID: "n2", state: "active",
                            contentHash: "h2"), embedding: vb)
    let hits = store.knn(query: va, k: 2, activeOnly: true)
    #expect(hits.first?.itemID == "a")
    #expect(hits.first?.nodeID == "n1")
    #expect(hits.first!.similarity > hits.last!.similarity)
  }

  @Test func activeOnlyFilterExcludesArchivedInKNN() async {
    let store = SemanticIndexStore(url: tempURL(), dimension: 8, embedderVersion: "stub:8")
    let e = StubEmbedder(dimension: 8)
    let v = await e.embed(["x"])![0]
    store.upsert(row: .init(itemID: "keep", kind: "node", nodeID: "n1", state: "active",
                            contentHash: "h"), embedding: v)
    store.upsert(row: .init(itemID: "gone", kind: "node", nodeID: "n2", state: "archived",
                            contentHash: "h"), embedding: v)
    let hits = store.knn(query: v, k: 5, activeOnly: true)
    #expect(hits.map(\.itemID) == ["keep"])
  }

  @Test func metadataOnlyUpsertUpdatesNodeWithoutEmbedding() async {
    let store = SemanticIndexStore(url: tempURL(), dimension: 8, embedderVersion: "stub:8")
    let e = StubEmbedder(dimension: 8)
    let v = await e.embed(["x"])![0]
    store.upsert(row: .init(itemID: "a", kind: "loose_end", nodeID: "old", state: "active",
                            contentHash: "h"), embedding: v)
    store.upsert(row: .init(itemID: "a", kind: "loose_end", nodeID: "new", state: "active",
                            contentHash: "h"), embedding: nil)   // repoint: node changes, no re-embed
    #expect(store.knn(query: v, k: 1, activeOnly: true).first?.nodeID == "new")
  }

  @Test func versionMismatchRebuildsEmpty() async {
    let url = tempURL()
    let e = StubEmbedder(dimension: 8)
    let v = await e.embed(["x"])![0]
    do {
      let s = SemanticIndexStore(url: url, dimension: 8, embedderVersion: "stub:8")
      s.upsert(row: .init(itemID: "a", kind: "node", nodeID: "n", state: "active",
                          contentHash: "h"), embedding: v)
    }
    let reopened = SemanticIndexStore(url: url, dimension: 8, embedderVersion: "stub:9")  // new version
    #expect(reopened.existingItems().isEmpty)   // dropped + rebuilt
  }

  @Test func existingItemsReturnsHashMap() async {
    let store = SemanticIndexStore(url: tempURL(), dimension: 8, embedderVersion: "stub:8")
    let e = StubEmbedder(dimension: 8)
    let v = await e.embed(["x"])![0]
    store.upsert(row: .init(itemID: "a", kind: "node", nodeID: "n", state: "active",
                            contentHash: "h1"), embedding: v)
    #expect(store.existingItems() == ["a": "h1"])
  }
}
```

- [ ] **Step 3: Run to verify it fails.**
Run: `./scripts/test.sh --filter SemanticIndexStoreTests`
Expected: FAIL (no `SemanticIndexStore`).

- [ ] **Step 4: Implement `SemanticIndexStore.swift`.** Mirror `NarrationCache`'s best-effort open; register sqlite-vec once; create the `vec0` table with `node_id`/`state` metadata columns + an `items` metadata table + a `meta` row; drop+recreate on version/dimension mismatch.
```swift
import Foundation
import SQLiteData   // re-exports GRDB
import CSQLiteVec

public struct IndexRow: Sendable {
  public let itemID: String, kind: String, nodeID: String, state: String, contentHash: String
  public init(itemID: String, kind: String, nodeID: String, state: String, contentHash: String) {
    self.itemID = itemID; self.kind = kind; self.nodeID = nodeID
    self.state = state; self.contentHash = contentHash
  }
}
public struct KNNResult: Sendable {
  public let itemID: String, kind: String, nodeID: String, similarity: Double
}

public struct SemanticIndexStore: Sendable {
  private let db: (any DatabaseWriter)?
  public var isAvailable: Bool { db != nil }

  // Register sqlite-vec exactly once for the whole process (auto-extension applies to all connections).
  private static let registered: Bool = { pensieve_sqlite_vec_register() == 0 }()

  public init(url: URL, dimension: Int, embedderVersion: String) {
    _ = Self.registered
    if let opened = Self.open(url, dimension: dimension, version: embedderVersion) {
      self.db = opened
    } else {
      try? FileManager.default.removeItem(at: url)
      self.db = Self.open(url, dimension: dimension, version: embedderVersion)
    }
  }

  private static func open(_ url: URL, dimension: Int, version: String) -> (any DatabaseWriter)? {
    guard registered, dimension > 0 else { return nil }
    do {
      try PensievePaths.ensureParentDirectory(of: url)
      let pool = try DatabasePool(path: url.path)
      try pool.write { db in
        // Whole-index invalidation: drop everything if the embedder version/dimension changed.
        let stored = try? Row.fetchOne(db, sql: "SELECT embedder_version, dimension FROM meta")
        let mismatch = stored == nil
          || (stored!["embedder_version"] as String?) != version
          || (stored!["dimension"] as Int?) != dimension
        if mismatch {
          try db.execute(sql: "DROP TABLE IF EXISTS embeddings")
          try db.execute(sql: "DROP TABLE IF EXISTS items")
          try db.execute(sql: "DROP TABLE IF EXISTS meta")
        }
        try db.execute(sql: """
          CREATE VIRTUAL TABLE IF NOT EXISTS embeddings USING vec0(
            item_id TEXT PRIMARY KEY, node_id TEXT, state TEXT, kind TEXT,
            embedding float[\(dimension)])
          """)
        try db.execute(sql: """
          CREATE TABLE IF NOT EXISTS items(
            item_id TEXT PRIMARY KEY, kind TEXT, node_id TEXT, state TEXT, content_hash TEXT)
          """)
        try db.execute(sql: "CREATE TABLE IF NOT EXISTS meta(embedder_version TEXT, dimension INT)")
        if mismatch {
          try db.execute(sql: "INSERT INTO meta(embedder_version, dimension) VALUES (?, ?)",
                         arguments: [version, dimension])
        }
      }
      return pool
    } catch { return nil }
  }

  public func existingItems() -> [String: String] {
    guard let db else { return [:] }
    return (try? db.read { db in
      try Row.fetchAll(db, sql: "SELECT item_id, content_hash FROM items")
        .reduce(into: [String: String]()) { $0[$1["item_id"]] = $1["content_hash"] }
    }) ?? [:]
  }

  public func upsert(row: IndexRow, embedding: [Float]?) {
    guard let db else { return }
    try? db.write { db in
      try db.execute(sql: """
        INSERT INTO items(item_id, kind, node_id, state, content_hash) VALUES (?, ?, ?, ?, ?)
        ON CONFLICT(item_id) DO UPDATE SET kind=excluded.kind, node_id=excluded.node_id,
          state=excluded.state, content_hash=excluded.content_hash
        """, arguments: [row.itemID, row.kind, row.nodeID, row.state, row.contentHash])
      if let embedding {
        let json = "[" + embedding.map { String($0) }.joined(separator: ",") + "]"
        try db.execute(sql: "DELETE FROM embeddings WHERE item_id = ?", arguments: [row.itemID])
        try db.execute(sql: """
          INSERT INTO embeddings(item_id, node_id, state, kind, embedding) VALUES (?, ?, ?, ?, ?)
          """, arguments: [row.itemID, row.nodeID, row.state, row.kind, json])
      } else {
        // Metadata-only change (repoint / state flip): keep the vector, update the vec0 metadata cols.
        try db.execute(sql: "UPDATE embeddings SET node_id = ?, state = ? WHERE item_id = ?",
                       arguments: [row.nodeID, row.state, row.itemID])
      }
    }
  }

  public func delete(itemIDs: [String]) {
    guard let db, !itemIDs.isEmpty else { return }
    let marks = Array(repeating: "?", count: itemIDs.count).joined(separator: ",")
    let args = StatementArguments(itemIDs)
    try? db.write { db in
      try db.execute(sql: "DELETE FROM embeddings WHERE item_id IN (\(marks))", arguments: args)
      try db.execute(sql: "DELETE FROM items WHERE item_id IN (\(marks))", arguments: args)
    }
  }

  public func knn(query: [Float], k: Int, activeOnly: Bool) -> [KNNResult] {
    guard let db else { return [] }
    let json = "[" + query.map { String($0) }.joined(separator: ",") + "]"
    let filter = activeOnly ? "AND state = 'active'" : ""
    return (try? db.read { db in
      try Row.fetchAll(db, sql: """
        SELECT item_id, kind, node_id, distance FROM embeddings
        WHERE embedding MATCH ? AND k = ? \(filter) ORDER BY distance
        """, arguments: [json, k]).map { r in
        KNNResult(itemID: r["item_id"], kind: r["kind"], nodeID: r["node_id"],
                  similarity: EmbeddingMath.cosine(fromL2: r["distance"]))
      }
    }) ?? []
  }
}
```
> If `UPDATE embeddings SET node_id ...` on a `vec0` metadata column isn't supported by the sqlite-vec version, fall back to delete+reinsert with the same (already-stored) vector; the Task-0 spike is the place to confirm metadata-column update support and adjust this method.

- [ ] **Step 5: Run to verify PASS.**
Run: `./scripts/test.sh --filter SemanticIndexStoreTests`
Expected: PASS (all five).

- [ ] **Step 6: Commit**
```bash
git add Sources/PensieveKit/Semantic/SemanticIndexStore.swift Sources/PensieveKit/Support/PensievePaths.swift Tests/PensieveKitTests/SemanticIndexStoreTests.swift
git commit -F - <<'EOF'
feat(kit): SemanticIndexStore over sqlite-vec (separate rebuildable index db)

vec0 with node_id/state metadata columns + items/meta tables; best-effort
open with delete-and-retry; drop+rebuild on embedder-version/dimension change;
upsert (embedding or metadata-only), delete, and state-filtered KNN.
EOF
```

---

### Task 3: `EmbeddableItem` + `SemanticIndexer` (incremental reconciliation)

**Files:**
- Create: `Sources/PensieveKit/Semantic/EmbeddableItem.swift`
- Create: `Sources/PensieveKit/Semantic/SemanticIndexer.swift`
- Test: `Tests/PensieveKitTests/SemanticIndexerTests.swift`

**Interfaces:**
- Consumes: `SemanticIndexStore`, `TextEmbedder`, `StubEmbedder`, `Node`/`LooseEnd`/`Event` models, `LooseEnd.isOpen`, `CaptureKind`.
- Produces:
  - `struct EmbeddableItem: Sendable { let itemID: String; let kind: String; let nodeID: String; let state: String; let text: String; var contentHash: String { ... } }`
  - `enum EmbeddableCorpus { static func gather(_ db: any DatabaseReader) throws -> [EmbeddableItem] }` — the v1 producer (nodes + open loose ends + events; the seam future producers extend).
  - `struct SemanticIndexer: Sendable { init(store:embedder:); func sync(_ db: any DatabaseReader) async }`

- [ ] **Step 1: Write the failing test.** Covers add / change-by-hash / repoint-metadata-only / noise-prune / archive-prune / delete.

`Tests/PensieveKitTests/SemanticIndexerTests.swift`:
```swift
import Testing
import Foundation
import SQLiteData
@testable import PensieveKit

@Suite struct SemanticIndexerTests {
  private func store() -> SemanticIndexStore {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("semidx-\(UUID().uuidString).sqlite")
    return SemanticIndexStore(url: url, dimension: 16, embedderVersion: "stub:16")
  }

  @Test func indexesActiveNodesOpenLooseEndsAndEvents() async throws {
    let db = try makeInMemoryCanonical()          // existing test helper (see makeTestDB usage in repo)
    let n = Node(name: "Payments", kind: NodeKind.project)
    try await db.write { try n.insert($0) }
    let le = LooseEnd(nodeID: n.id, sourceEventID: UUID(), text: "wire up refunds", quote: "TODO refunds")
    try await db.write { try le.insert($0) }
    let s = store()
    let idx = SemanticIndexer(store: s, embedder: StubEmbedder(dimension: 16))
    await idx.sync(db)
    #expect(s.existingItems().keys.contains(n.id.uuidString))
    #expect(s.existingItems().keys.contains(le.id.uuidString))
  }

  @Test func noiseLabelPrunesLooseEnd() async throws {
    let db = try makeInMemoryCanonical()
    let n = Node(name: "N", kind: NodeKind.project)
    let le = LooseEnd(nodeID: n.id, sourceEventID: UUID(), text: "t", quote: "q")
    try await db.write { try n.insert($0); try le.insert($0) }
    let s = store()
    let idx = SemanticIndexer(store: s, embedder: StubEmbedder(dimension: 16))
    await idx.sync(db)
    #expect(s.existingItems().keys.contains(le.id.uuidString))
    try await db.write { db in
      try LooseEnd.where { $0.id.eq(le.id) }.update { $0.label = "noise" }.execute(db)
    }
    await idx.sync(db)                              // membership-driven prune (hash unchanged)
    #expect(!s.existingItems().keys.contains(le.id.uuidString))
  }

  @Test func repointUpdatesNodeWithoutChangingHash() async throws {
    let db = try makeInMemoryCanonical()
    let a = Node(name: "A", kind: NodeKind.project)
    let b = Node(name: "B", kind: NodeKind.strand)
    let le = LooseEnd(nodeID: a.id, sourceEventID: UUID(), text: "t", quote: "q")
    try await db.write { try a.insert($0); try b.insert($0); try le.insert($0) }
    let s = store()
    let idx = SemanticIndexer(store: s, embedder: StubEmbedder(dimension: 16))
    await idx.sync(db)
    try await db.write { db in
      try LooseEnd.where { $0.id.eq(le.id) }.update { $0.nodeID = b.id }.execute(db)
    }
    await idx.sync(db)
    let hits = s.knn(query: await StubEmbedder(dimension: 16).embed(["t q"])![0], k: 5, activeOnly: true)
    #expect(hits.first(where: { $0.itemID == le.id.uuidString })?.nodeID == b.id.uuidString)
  }
}
```
> The plan assumes a test helper that builds an in-memory canonical DB with the schema/migrations. If the repo's helper has a different name (grep `makeTestDB`/`openInMemory` in `Tests/`), use that; the assertions are the contract.

- [ ] **Step 2: Run to verify it fails.**
Run: `./scripts/test.sh --filter SemanticIndexerTests`
Expected: FAIL.

- [ ] **Step 3: Implement `EmbeddableItem.swift`.**
```swift
import Foundation
import Crypto   // if unavailable, use a simple stable hash (see note)

public struct EmbeddableItem: Sendable {
  public let itemID: String, kind: String, nodeID: String, state: String, text: String
  public init(itemID: String, kind: String, nodeID: String, state: String, text: String) {
    self.itemID = itemID; self.kind = kind; self.nodeID = nodeID; self.state = state; self.text = text
  }
  /// Stable across processes/runs (String.hashValue is per-process salted — do NOT use it here).
  public var contentHash: String {
    var h: UInt64 = 1469598103934665603            // FNV-1a
    for b in text.utf8 { h = (h ^ UInt64(b)) &* 1099511628211 }
    return String(h, radix: 16)
  }
}

public enum EmbeddableCorpus {
  public static func gather(_ db: any DatabaseReader) throws -> [EmbeddableItem] {
    try db.read { db in
      var out: [EmbeddableItem] = []
      let nodes = try Node.where { $0.state.eq("active") }.fetchAll(db)
      let activeIDs = Set(nodes.map { $0.id })
      for n in nodes {
        out.append(.init(itemID: n.id.uuidString, kind: "node", nodeID: n.id.uuidString,
                         state: n.state, text: [n.name, n.description].filter { !$0.isEmpty }.joined(separator: " — ")))
      }
      let ends = try LooseEnd.where { LooseEnd.isOpen($0) }.fetchAll(db)
      for le in ends where activeIDs.contains(le.nodeID) {
        out.append(.init(itemID: le.id.uuidString, kind: "loose_end", nodeID: le.nodeID.uuidString,
                         state: "active", text: [le.text, le.quote].filter { !$0.isEmpty }.joined(separator: " — ")))
      }
      let events = try Event.all.fetchAll(db)
      for e in events where activeIDs.contains(e.nodeID) {
        let text: String?
        switch e.kind {
        case CaptureKind.ccSession: text = e.workSummary   // nil = skip terse placeholder
        default: text = e.summary.isEmpty ? nil : e.summary
        }
        if let text {
          out.append(.init(itemID: e.id.uuidString, kind: "event", nodeID: e.nodeID.uuidString,
                           state: "active", text: text))
        }
      }
      return out
    }
  }
}
```
> Do not add a `Crypto` dependency just for a hash — use the inline FNV-1a shown (per-process `String.hashValue` is salted and would break cross-run stability). Remove the `import Crypto` line.

- [ ] **Step 4: Implement `SemanticIndexer.swift`** (membership + metadata-driven reconciliation; embed only new/changed).
```swift
import Foundation
import SQLiteData

public struct SemanticIndexer: Sendable {
  let store: SemanticIndexStore
  let embedder: any TextEmbedder
  public init(store: SemanticIndexStore, embedder: any TextEmbedder) {
    self.store = store; self.embedder = embedder
  }

  public func sync(_ db: any DatabaseReader) async {
    guard store.isAvailable else { return }
    guard let corpus = try? EmbeddableCorpus.gather(db) else { return }
    let existing = store.existingItems()                 // item_id -> content_hash
    let liveIDs = Set(corpus.map { $0.itemID })

    // Prune anything no longer in the live corpus (closed/noise loose ends, archived, deleted).
    let stale = existing.keys.filter { !liveIDs.contains($0) }
    store.delete(itemIDs: Array(stale))

    // Which items need (re-)embedding: new, or content_hash changed.
    let needEmbed = corpus.filter { existing[$0.itemID] != $0.contentHash }
    var vectors: [String: [Float]] = [:]
    if !needEmbed.isEmpty, let embedded = await embedder.embed(needEmbed.map { truncate($0.text) }) {
      for (item, vec) in zip(needEmbed, embedded) { vectors[item.itemID] = vec }
    }
    // Upsert every live item: metadata always; vector only when (re-)embedded this run.
    for item in corpus {
      store.upsert(row: .init(itemID: item.itemID, kind: item.kind, nodeID: item.nodeID,
                              state: item.state, contentHash: item.contentHash),
                   embedding: vectors[item.itemID])
    }
  }

  // v1: truncate to a safe character budget for the BERT-class token window. Real chunking rides
  // in with transcripts (a future EmbeddableItem producer).
  private func truncate(_ s: String) -> String { String(s.prefix(2000)) }
}
```

- [ ] **Step 5: Run to verify PASS.**
Run: `./scripts/test.sh --filter SemanticIndexerTests`
Expected: PASS.

- [ ] **Step 6: Commit**
```bash
git add Sources/PensieveKit/Semantic/EmbeddableItem.swift Sources/PensieveKit/Semantic/SemanticIndexer.swift Tests/PensieveKitTests/SemanticIndexerTests.swift
git commit -F - <<'EOF'
feat(kit): EmbeddableItem corpus + SemanticIndexer incremental reconciliation

Membership/metadata-driven: prune by live corpus predicate (not hash), embed
only new/changed, upsert metadata unconditionally (repoint-safe). v1 corpus =
active nodes + open loose ends + enriched events. FNV-1a content hash.
EOF
```

---

### Task 4: `SemanticQueries` (KNN over-fetch + grounded post-filter/join)

**Files:**
- Create: `Sources/PensieveKit/Query/SemanticQueries.swift`
- Test: `Tests/PensieveKitTests/SemanticQueriesTests.swift`

**Interfaces:**
- Consumes: `SemanticIndexStore`, `TextEmbedder`, `SearchQueries.NodeHit`/`LooseEndHit` shapes, `SnippetMaker`, `LooseEnd.isOpen`, `Node`.
- Produces:
  - `struct SemanticHit: Identifiable, Sendable { let id: UUID; let kind: String; let nodeID: UUID; let nodeName: String; let title: String; let snippet: Snippet; let similarity: Double }`
  - `enum SemanticQueries { static func search(query:visibleNodeIDs:excludingIDs:k:floor:store:embedder:_ db:) async -> [SemanticHit] }`
    - `excludingIDs: Set<UUID>` = the exact-hit ids to dedupe against (⌘F passes these; MCP passes empty).
    - Over-fetches `k' = max(k*8, 50)` from the store, applies floor + `visibleNodeIDs` + exclude + the join-time live-predicate drop, returns up to `k`.

- [ ] **Step 1: Write the failing test.** Focus-muting must not zero-out; floor drops weak; stale row dropped by the join.

`Tests/PensieveKitTests/SemanticQueriesTests.swift`:
```swift
import Testing
import Foundation
import SQLiteData
@testable import PensieveKit

@Suite struct SemanticQueriesTests {
  @Test func focusMutingDoesNotZeroOutVisibleHits() async throws {
    let db = try makeInMemoryCanonical()
    let visible = Node(name: "Visible refunds work", kind: NodeKind.project)
    let muted = Node(name: "Muted refunds work", kind: NodeKind.project, context: "personal")
    try await db.write { try visible.insert($0); try muted.insert($0) }
    let embedder = StubEmbedder(dimension: 16)
    let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("q-\(UUID()).sqlite")
    let store = SemanticIndexStore(url: url, dimension: 16, embedderVersion: "stub:16")
    await SemanticIndexer(store: store, embedder: embedder).sync(db)

    let hits = await SemanticQueries.search(
      query: "refunds", visibleNodeIDs: [visible.id], excludingIDs: [], k: 5, floor: -1.0,
      store: store, embedder: embedder, db)
    #expect(hits.contains { $0.nodeID == visible.id })
    #expect(!hits.contains { $0.nodeID == muted.id })    // muted node filtered out post-KNN
  }

  @Test func staleIndexRowDroppedByJoin() async throws {
    let db = try makeInMemoryCanonical()
    let n = Node(name: "N", kind: NodeKind.project)
    let le = LooseEnd(nodeID: n.id, sourceEventID: UUID(), text: "refund flow", quote: "q")
    try await db.write { try n.insert($0); try le.insert($0) }
    let embedder = StubEmbedder(dimension: 16)
    let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("q-\(UUID()).sqlite")
    let store = SemanticIndexStore(url: url, dimension: 16, embedderVersion: "stub:16")
    await SemanticIndexer(store: store, embedder: embedder).sync(db)
    // Simulate between-sync drift: noise-label the loose end in canonical WITHOUT re-syncing the index.
    try await db.write { db in
      try LooseEnd.where { $0.id.eq(le.id) }.update { $0.label = "noise" }.execute(db)
    }
    let hits = await SemanticQueries.search(
      query: "refund flow", visibleNodeIDs: [n.id], excludingIDs: [], k: 5, floor: -1.0,
      store: store, embedder: embedder, db)
    #expect(!hits.contains { $0.id == le.id })           // join re-applies isOpen → dropped
  }
}
```

- [ ] **Step 2: Run to verify it fails.**
Run: `./scripts/test.sh --filter SemanticQueriesTests`
Expected: FAIL.

- [ ] **Step 3: Implement `SemanticQueries.swift`.**
```swift
import Foundation
import SQLiteData

public struct SemanticHit: Identifiable, Sendable, Equatable {
  public let id: UUID           // node id / loose-end id / event id
  public let kind: String       // "node" | "loose_end" | "event"
  public let nodeID: UUID
  public let nodeName: String
  public let title: String      // node name / loose-end text / event summary
  public let snippet: Snippet
  public let similarity: Double
}

public enum SemanticQueries {
  public static func search(query rawQuery: String,
                            visibleNodeIDs: Set<UUID>,
                            excludingIDs: Set<UUID>,
                            k: Int,
                            floor: Double,
                            store: SemanticIndexStore,
                            embedder: any TextEmbedder,
                            _ db: any DatabaseReader) async -> [SemanticHit] {
    let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    guard query.count >= 2, store.isAvailable,
          let qvec = await embedder.embed([query])?.first else { return [] }

    // Over-fetch so post-KNN filtering (Focus/exclude/floor/join) can't starve results.
    let kPrime = max(k * 8, 50)
    let raw = store.knn(query: qvec, k: kPrime, activeOnly: true)

    var hits: [SemanticHit] = []
    for r in raw {
      guard r.similarity >= floor,
            let nodeID = UUID(uuidString: r.nodeID), visibleNodeIDs.contains(nodeID) else { continue }
      guard let itemID = UUID(uuidString: r.itemID), !excludingIDs.contains(itemID) else { continue }
      // Join canonical + re-apply the live corpus predicate (last grounding defense).
      guard let hit = try? resolve(kind: r.kind, itemID: itemID, similarity: r.similarity,
                                   query: query, db) else { continue }
      hits.append(hit)
      if hits.count == k { break }
    }
    return hits
  }

  private static func resolve(kind: String, itemID: UUID, similarity: Double,
                              query: String, _ db: any DatabaseReader) throws -> SemanticHit? {
    try db.read { db in
      switch kind {
      case "node":
        guard let n = try Node.where { $0.id.eq(itemID) }.fetchOne(db), n.state == "active" else { return nil }
        return SemanticHit(id: n.id, kind: kind, nodeID: n.id, nodeName: n.name, title: n.name,
                           snippet: SnippetMaker.make(from: n.description.isEmpty ? n.name : n.description, matching: query),
                           similarity: similarity)
      case "loose_end":
        guard let le = try LooseEnd.where { $0.id.eq(itemID) && LooseEnd.isOpen($0) }.fetchOne(db),
              let n = try Node.where { $0.id.eq(le.nodeID) }.fetchOne(db), n.state == "active" else { return nil }
        return SemanticHit(id: le.id, kind: kind, nodeID: le.nodeID, nodeName: n.name, title: le.text,
                           snippet: SnippetMaker.make(from: le.text, matching: query), similarity: similarity)
      case "event":
        guard let e = try Event.where { $0.id.eq(itemID) }.fetchOne(db),
              let n = try Node.where { $0.id.eq(e.nodeID) }.fetchOne(db), n.state == "active" else { return nil }
        let body = (e.workSummary?.isEmpty == false ? e.workSummary! : e.summary)
        return SemanticHit(id: e.id, kind: kind, nodeID: e.nodeID, nodeName: n.name, title: body,
                           snippet: SnippetMaker.make(from: body, matching: query), similarity: similarity)
      default: return nil
      }
    }
  }
}
```

- [ ] **Step 4: Run to verify PASS.**
Run: `./scripts/test.sh --filter SemanticQueriesTests`
Expected: PASS.

- [ ] **Step 5: Full suite green.**
Run: `./scripts/test.sh`
Expected: PASS (all).

- [ ] **Step 6: Commit**
```bash
git add Sources/PensieveKit/Query/SemanticQueries.swift Tests/PensieveKitTests/SemanticQueriesTests.swift
git commit -F - <<'EOF'
feat(kit): SemanticQueries — KNN over-fetch + grounded post-filter/join

Over-fetch k' before applying floor + visibleNodeIDs + exclude; the canonical
join re-applies isOpen/active so a between-sync stale row is dropped. Returns
cited SemanticHits (node/loose_end/event).
EOF
```

---

### Task 5: Wire the indexer into the daemon sync path (toggle-gated)

**Files:**
- Modify: `Sources/PensieveKit/Sync/SyncRunner.swift`
- Modify: `Sources/PensieveKit/Support/PensieveDefaults.swift`
- Test: `Tests/PensieveKitTests/SyncRunnerTests.swift` (add a case)

**Interfaces:**
- Consumes: `SemanticIndexer`, `SemanticIndexStore`, `NLContextualEmbedder`, `PensieveDefaults`.
- Produces: `PensieveDefaults.semanticSearchKey` + a `semanticSearchEnabled(_:)` reader; `SyncRunner` runs the indexer after extraction when enabled.

- [ ] **Step 1: Add the shared default key + reader.** In `PensieveDefaults.swift`:
```swift
  public static let semanticSearchKey = "app.semanticSearch"

  /// Semantic search is ON by default (matching the app's @AppStorage default). Cross-process
  /// readers (the daemon) must honor the same default — `bool` alone reads false when unset.
  public static func semanticSearchEnabled(_ defaults: UserDefaults = shared()) -> Bool {
    defaults.object(forKey: semanticSearchKey) == nil ? true : defaults.bool(forKey: semanticSearchKey)
  }
```

- [ ] **Step 2: Add a `SyncRunner` test** proving the indexer runs when enabled and populates the index. Add to `SyncRunnerTests.swift`:
```swift
  @Test func syncPopulatesSemanticIndexWhenEnabled() async throws {
    let env = try makeSyncEnv()                 // existing helper building spool+db+provider+projectsDir
    // seed one active node + open loose end via env.db (reuse the file's existing seeding helper)
    try await env.db.write { db in
      let n = Node(name: "Indexed project", kind: NodeKind.project); try n.insert(db)
    }
    let idxURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("s-\(UUID()).sqlite")
    let store = SemanticIndexStore(url: idxURL, dimension: 16, embedderVersion: "stub:16")
    let runner = SyncRunner(spool: env.spool, db: env.db, provider: env.provider,
                            projectsDir: env.projectsDir,
                            semanticIndexer: SemanticIndexer(store: store, embedder: StubEmbedder(dimension: 16)))
    _ = try await runner.run()
    #expect(!store.existingItems().isEmpty)
  }
```
> If the file's env helper differs, adapt names; the contract is "after `run()`, the index has rows." If adding an injected indexer to `SyncRunner.init` is undesirable, gate on `PensieveDefaults.semanticSearchEnabled()` and build the real indexer inside `run()` — then the test seeds the default and asserts via a store at the real path; prefer injection for testability.

- [ ] **Step 3: Run to verify it fails.**
Run: `./scripts/test.sh --filter SyncRunnerTests`
Expected: FAIL (no `semanticIndexer` param).

- [ ] **Step 4: Wire `SyncRunner`.** Add an optional injected indexer; when nil, build the default (toggle-gated) inside `run()`.
```swift
  let semanticIndexer: SemanticIndexer?

  public init(spool: CaptureSpool, db: any DatabaseWriter, provider: any LLMProvider,
              projectsDir: URL, now: @escaping @Sendable () -> Date = Date.init,
              semanticIndexer: SemanticIndexer? = nil) {
    self.spool = spool; self.db = db; self.provider = provider
    self.projectsDir = projectsDir; self.now = now; self.semanticIndexer = semanticIndexer
  }
```
At the end of `run()`, after the `ExtractionRunner` block and before `return`:
```swift
    // Semantic index refresh (best-effort, on-device, toggle-gated). Never blocks the sync summary.
    if let indexer = semanticIndexer {
      await indexer.sync(db)
    } else if PensieveDefaults.semanticSearchEnabled() {
      let embedder = NLContextualEmbedder()
      let store = SemanticIndexStore(url: PensievePaths.semanticIndexURL(),
                                     dimension: embedder.dimension, embedderVersion: embedder.version)
      if store.isAvailable, embedder.dimension > 0 { await SemanticIndexer(store: store, embedder: embedder).sync(db) }
    }
```

- [ ] **Step 5: Run to verify PASS.**
Run: `./scripts/test.sh --filter SyncRunnerTests`
Expected: PASS.

- [ ] **Step 6: Commit**
```bash
git add Sources/PensieveKit/Sync/SyncRunner.swift Sources/PensieveKit/Support/PensieveDefaults.swift Tests/PensieveKitTests/SyncRunnerTests.swift
git commit -F - <<'EOF'
feat(kit): run the semantic indexer after extraction in SyncRunner (toggle-gated)

Injected indexer for tests; otherwise builds the on-device embedder + index
store gated on PensieveDefaults.semanticSearchEnabled (default on). Best-effort,
never blocks the sync summary.
EOF
```

---

### Task 6: Settings "Semantic search" toggle (app)

**Files:**
- Modify: `Sources/PensieveApp/AppDefaults.swift`
- Modify: `Sources/PensieveApp/Settings/IntelligenceSettingsTab.swift`
- Modify: `Sources/PensieveApp/Localizable.xcstrings`

**Interfaces:**
- Consumes: `PensieveDefaults.semanticSearchKey` (Task 5).
- Produces: a `@AppStorage(PensieveDefaults.semanticSearchKey)`-backed toggle; `AppDefaults.semanticSearchEnabled` for non-View readers.

- [ ] **Step 1: Add the non-View reader.** In `AppDefaults.swift`, after `backgroundSyncEnabled`:
```swift
  /// Semantic search is ON by default (matching the @AppStorage default and the Kit reader).
  static var semanticSearchEnabled: Bool {
    UserDefaults.standard.object(forKey: PensieveDefaults.semanticSearchKey) == nil
      ? true : UserDefaults.standard.bool(forKey: PensieveDefaults.semanticSearchKey)
  }
```
> Import note: `AppDefaults` already references `PensieveDefaults` keys elsewhere? It currently uses bare string keys. Use `PensieveDefaults.semanticSearchKey` here (the app imports PensieveKit).

- [ ] **Step 2: Add the toggle to the Intelligence tab.** In `IntelligenceSettingsTab.swift`, add the storage near the other `@AppStorage`:
```swift
  @AppStorage(PensieveDefaults.semanticSearchKey) private var semanticSearchEnabled = true
```
And in `body`, add a `Toggle` in the appropriate `Section` (next to the narration toggle):
```swift
      Toggle("Semantic search (find by meaning)", isOn: $semanticSearchEnabled)
      Text("Builds an on-device index so ⌘F and Claude Code can find work by meaning, not just exact words. First use downloads a small on-device model.")
        .font(.caption).foregroundStyle(.secondary)
```

- [ ] **Step 3: Add the two String Catalog keys** (`"Semantic search (find by meaning)"` and the caption) to `Localizable.xcstrings` with English base + a German `de` translation. Per the localization gotcha, author the keys by hand (xcodebuild doesn't auto-populate). German:
  - `"Semantic search (find by meaning)"` → `"Semantische Suche (nach Bedeutung finden)"`
  - caption → `"Erstellt einen geräteinternen Index, damit ⌘F und Claude Code Arbeit nach Bedeutung finden, nicht nur nach exakten Wörtern. Bei der ersten Nutzung wird ein kleines geräteinternes Modell geladen."`

- [ ] **Step 4: Build the app.**
Run: `xcodegen generate && xcodebuild -project Pensieve.xcodeproj -scheme Pensieve -configuration Debug -derivedDataPath ./.build-xcode build`
Expected: BUILD SUCCEEDED.

- [ ] **Step 5: Smoke-launch (non-blocking, throwaway stores).**
```bash
PENSIEVE_DB=/tmp/p-$$.sqlite PENSIEVE_CAPTURE_DB=/tmp/c-$$.sqlite \
  ./.build-xcode/Build/Products/Debug/Pensieve.app/Contents/MacOS/Pensieve &
sleep 4 && kill %1
```
Expected: launches without crashing.

- [ ] **Step 6: Commit**
```bash
git add Sources/PensieveApp/AppDefaults.swift Sources/PensieveApp/Settings/IntelligenceSettingsTab.swift Sources/PensieveApp/Localizable.xcstrings
git commit -F - <<'EOF'
feat(app): Settings ▸ Intelligence "Semantic search" toggle (default on) + German
EOF
```

---

### Task 7: In-app ⌘F "Related" section + app-side indexer hook

**Files:**
- Modify: `Sources/PensieveApp/AppModel.swift`
- Modify: `Sources/PensieveApp/ContentListView.swift`
- Modify: `Sources/PensieveApp/Localizable.xcstrings`

**Interfaces:**
- Consumes: `SemanticQueries`, `SemanticHit`, `SemanticIndexStore`, `NLContextualEmbedder`, `AppDefaults.semanticSearchEnabled`.
- Produces: `AppModel.semanticHits: [SemanticHit]` (published), populated in `runSearch` after the exact search; the app runs the indexer after `refresh()`.

- [ ] **Step 1: Add state + a lazily-built store/embedder to `AppModel`.** Near the search state (line ~241):
```swift
  @Published private(set) var semanticHits: [SemanticHit] = []
  // Built once; NLContextualEmbedder resolves dimension from the loaded asset at init.
  private lazy var embedder: NLContextualEmbedder = NLContextualEmbedder()
  private lazy var semanticStore = SemanticIndexStore(
    url: PensievePaths.semanticIndexURL(), dimension: embedder.dimension, embedderVersion: embedder.version)
```

- [ ] **Step 2: Extend `runSearch()`** to also run semantic (dedup against exact ids; gated on the toggle). Replace the `searchTask` closure body:
```swift
    searchTask = Task { [weak self] in
      guard let self else { return }
      let results = try? await Task.detached {
        try SearchQueries.search(query: query, visibleNodeIDs: visible, db)
      }.value
      guard self.searchToken == token, !Task.isCancelled else { return }
      self.searchResults = results ?? SearchResults()

      guard AppDefaults.semanticSearchEnabled else { self.semanticHits = []; return }
      let exact = Set((results?.nodes.map { $0.id } ?? []) + (results?.looseEnds.map { $0.id } ?? []))
      let sem = await SemanticQueries.search(
        query: query, visibleNodeIDs: visible, excludingIDs: exact, k: 8, floor: 0.25,
        store: self.semanticStore, embedder: self.embedder, db)
      guard self.searchToken == token, !Task.isCancelled else { return }
      self.semanticHits = sem
    }
```
Also clear `semanticHits` in the early-return guard and in `clearSearch()`.

- [ ] **Step 3: Run the indexer after refresh.** In `refresh()` (or `drainThenRefresh`), after the canonical read completes, fire a detached best-effort index sync (gated):
```swift
    if AppDefaults.semanticSearchEnabled, let db {
      let store = semanticStore, embedder = self.embedder
      Task.detached { await SemanticIndexer(store: store, embedder: embedder).sync(db) }
    }
```
> Place this where `db` is non-nil and `allNodes` is loaded. It's best-effort; it must not block the UI refresh.

- [ ] **Step 4: Render the "Related" section** in `ContentListView.searchResultsList()`. After the Loose Ends section and before the `ContentUnavailableView.search`:
```swift
      if !model.semanticHits.isEmpty {
        Section(header: Text("Related")) {
          ForEach(model.semanticHits) { hit in
            Button {
              if hit.kind == "loose_end" {
                model.selectSearchLooseEnd(LooseEndHit(id: hit.id, nodeID: hit.nodeID,
                                                       nodeName: hit.nodeName, snippet: hit.snippet))
              } else {
                model.selectSearchNode(hit.nodeID)
              }
            } label: {
              VStack(alignment: .leading, spacing: 2) {
                Text(hit.title).lineLimit(1)
                SnippetText(snippet: hit.snippet).font(.caption).foregroundStyle(.secondary)
              }
            }.buttonStyle(.plain)
          }
        }
      }
```
And change the empty-state guard so it accounts for semantic hits:
```swift
      if r.isEmpty && model.semanticHits.isEmpty { ContentUnavailableView.search(text: model.searchText) }
```
> Reuse existing row idioms from the file's node/loose-end sections; match their exact `Button`/label styling rather than the sketch above if it diverges. `LooseEndHit`'s initializer must match its 1a definition (`id`, `nodeID`, `nodeName`, `snippet`) — verify in `SearchQueries.swift`.

- [ ] **Step 5: Add the `"Related"` String Catalog key** (English + German `"Verwandt"`).

- [ ] **Step 6: Build + smoke-launch.**
Run: `xcodegen generate && xcodebuild -project Pensieve.xcodeproj -scheme Pensieve -configuration Debug -derivedDataPath ./.build-xcode build`
Expected: BUILD SUCCEEDED. Then the smoke-launch from Task 6 Step 5.

- [ ] **Step 7: Commit**
```bash
git add Sources/PensieveApp/AppModel.swift Sources/PensieveApp/ContentListView.swift Sources/PensieveApp/Localizable.xcstrings
git commit -F - <<'EOF'
feat(app): ⌘F "Related" semantic section + app-side index sync after refresh

Runs SemanticQueries after the exact search (deduped, toggle-gated, floor 0.25)
and syncs the on-device index on refresh. Views stay thin over the Kit kernel.
EOF
```

---

### Task 8: Unified MCP `search` tool

**Files:**
- Modify: `Sources/pensieve/Commands/Mcp.swift`
- Create: `Sources/pensieve/MCP/SearchTool.swift` (or extend the existing `PensieveMCP` helper file — match where `projectContextJSON`/`whatsNextJSON` live)
- Test: `Tests/PensieveKitTests/` — add a Kit-level test only if a new Kit helper is introduced; the MCP glue itself is CLI-target and untested (like the other tools).

**Interfaces:**
- Consumes: `SearchQueries`, `SemanticQueries`, `SemanticIndexStore`, `NLContextualEmbedder`, the existing `PensieveMCP.result(_:)` helper + the canonical read handle the other tools use.
- Produces: an MCP `search` tool returning JSON: `{ "exact": [...], "related": [...] }`, each item `{ id, kind, node_id, node_name, title, snippet }` (+ `similarity` for related). All items are cited (real rows).

- [ ] **Step 1: Register the tool** in the `ListTools` handler (after `recall`):
```swift
        Tool(name: "search",
             description: "Find across all your work by keyword AND meaning — exact matches first, semantically related items below. Each result is a real, cited node/loose end/event.",
             inputSchema: .object(["type": .string("object"), "properties": .object([
               "query": .object(["type": .string("string"), "description": .string("what to find")]),
               "limit": .object(["type": .string("number"), "description": .string("max results per group (default 8)")]),
             ]), "required": .array([.string("query")])]),
             annotations: .init(readOnlyHint: true, openWorldHint: false)),
```

- [ ] **Step 2: Handle the call** in the `CallTool` switch (after the `recall` case):
```swift
      case "search":
        guard let query = params.arguments?["query"]?.stringValue else {
          return PensieveMCP.result("{\"error\":\"query required\"}")
        }
        let limit = params.arguments?["limit"]?.intValue ?? 8
        let json = try await PensieveMCP.searchJSON(query: query, limit: limit)
        return PensieveMCP.result(json)
```

- [ ] **Step 3: Implement `PensieveMCP.searchJSON`** alongside the other `*JSON` helpers. It opens the canonical store read-only (as the other tools do), runs `SearchQueries` for exact + `SemanticQueries` for related over the semantic store, and encodes both groups. Semantic scope = **all nodes** (no Focus in MCP): pass `visibleNodeIDs` = the set of active node ids.
```swift
  static func searchJSON(query: String, limit: Int) async throws -> String {
    let db = try openCanonicalReadOnly()                    // match the other tools' open helper
    let allActive = try db.read { db in
      Set(try Node.where { $0.state.eq("active") }.fetchAll(db).map { $0.id })
    }
    let exact = try SearchQueries.search(query: query, visibleNodeIDs: allActive, db)
    let embedder = NLContextualEmbedder()
    let store = SemanticIndexStore(url: PensievePaths.semanticIndexURL(),
                                   dimension: embedder.dimension, embedderVersion: embedder.version)
    let exactIDs = Set(exact.nodes.map { $0.id } + exact.looseEnds.map { $0.id })
    let related = PensieveDefaults.semanticSearchEnabled()
      ? await SemanticQueries.search(query: query, visibleNodeIDs: allActive, excludingIDs: exactIDs,
                                     k: limit, floor: 0.25, store: store, embedder: embedder, db)
      : []
    // Encode { exact: [...], related: [...] } — reuse the codable DTOs the other tools use, or
    // build a small Encodable payload here. Keep item shape { id, kind, node_id, node_name, title, snippet }.
    return try encodeSearchPayload(exact: exact, related: related, limit: limit)
  }
```
> Match the exact canonical-open + JSON-encoding idioms already in the MCP helper file (grep `projectContextJSON`, `openCanonical`, `result(`). Do not invent a new open path. If `SearchQueries.search` returns more than `limit`, truncate to `limit` per group in the encoder.

- [ ] **Step 4: Build the CLI.**
Run: `xcodebuild -scheme PensieveCLI build`
Expected: BUILD SUCCEEDED.

- [ ] **Step 5: Manual smoke** (optional, needs the real store + a built CLI): `echo '{"jsonrpc":"2.0",...}' ` handshake is heavy — instead confirm the tool lists via `swift build && .build/debug/... ` is not available (CLI is Xcode-built). Rely on the build + the fact that the tool mirrors the tested kernels. Note in the commit that live MCP verification is a human carry.

- [ ] **Step 6: Commit**
```bash
git add Sources/pensieve/Commands/Mcp.swift Sources/pensieve/MCP
git commit -F - <<'EOF'
feat(mcp): unified `search` tool — exact + semantic blend over the shared kernel

One "find across my work" tool: SearchQueries (exact) + SemanticQueries
(related, toggle-gated), all cited. Subsumes the deferred keyword-search sibling.
EOF
```

---

## Self-Review

**Spec coverage:**
- Native embedder (`NLContextualEmbedding`, per-token→mean-pool, runtime dim) → Task 1. ✓
- `sqlite-vec` static C target, all targets via PensieveKit → Task 0. ✓
- Separate rebuildable `semantic-index.sqlite`, vec0 + metadata cols, drop-on-version → Task 2. ✓
- v1 corpus (nodes + open loose ends + events; per-kind text; truncate) + `EmbeddableItem` seam → Task 3. ✓
- Membership/metadata-driven incremental sync (repoint no-re-embed, noise/archive prune) → Task 3. ✓
- KNN over-fetch + Focus/floor/exclude post-filter + grounded join re-applying predicate → Task 4. ✓
- Indexer in the daemon sync path, toggle-gated → Task 5; app-side sync after refresh → Task 7. ✓
- Settings toggle (default on), cross-process reader → Tasks 5 (Kit) + 6 (app). ✓
- ⌘F "Related" section → Task 7. ✓
- Unified MCP `search` tool → Task 8. ✓
- Grounding/degradation (best-effort nil, stale-row drop, on-device only) → Tasks 1/2/4. ✓
- No `EvalTask`; German l10n; app has no unit tests → constraints + Tasks 6/7. ✓

**Placeholder scan:** No TBD/TODO. Notes that say "match the existing idiom / verify the helper name" point at concrete real symbols to confirm during implementation, not missing content.

**Type consistency:** `TextEmbedder.embed -> [[Float]]?`, `SemanticIndexStore.knn -> [KNNResult]`, `SemanticIndexer.sync(_:)`, `SemanticQueries.search(...) -> [SemanticHit]`, `IndexRow`/`EmbeddableItem` fields, and `PensieveDefaults.semanticSearchKey`/`semanticSearchEnabled` are used consistently across Tasks 1–8.

**Open items deferred to implementation (from the spec, intentionally):** the exact cosine `floor` (plan starts at 0.25 — tune in ⌘F), `k'` over-fetch factor (plan uses `max(k*8, 50)`), the concurrent-rebuild guard (Task 2 relies on best-effort open + WAL; if the app+daemon race a rebuild in practice, add a file lock — flagged, not built), and the `EmbeddableItem` producer extension for transcripts (next increment).
