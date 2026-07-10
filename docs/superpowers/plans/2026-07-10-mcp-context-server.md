# MCP Context Server Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Feed Pensieve's grounded, cwd-weighted project context back into Claude Code through three surfaces — an ambient `pensieve prime` SessionStart hook, model-invoked MCP tools, and user-attachable MCP resources — all thin over one new tested PensieveKit kernel.

**Architecture:** A single read-only Kit kernel (`SessionContextQueries`) composes the existing tested queries (`NextQueries`, `LooseEndQueries`, `NodeFactsQueries`, `ProjectQueries.status`, `ProvenanceQueries`, `SummaryBuilder`) into a `ProjectContextBundle` and a ranked `WhatsNextItem` list, plus markdown/compact renderers. A new disposable `NarrationCache` (standalone SQLite) shares prose across processes. Two new thin `pensieve` subcommands wrap the kernel: `prime` (prints `additionalContext`) and `mcp` (an official-MCP-Swift-SDK stdio server exposing tools + resources + roots). No new canonical schema; the only canonical writer stays `Ingester.drain()`.

**Tech Stack:** Swift 6, SwiftPM, SQLiteData (GRDB-backed), swift-argument-parser, the official MCP Swift SDK (`modelcontextprotocol/swift-sdk`, pin `0.12.1`), swift-testing.

## Global Constraints

- **Swift tools 6.0 manifest; macOS 14 platform floor** (`Package.swift` unchanged on these). The MCP SDK requires a **Swift 6.1+ toolchain** (satisfied by the active Xcode 26.6) and supports macOS 13+ — compatible.
- **The MCP SDK dependency is added to the `pensieve` executable target ONLY — never `PensieveKit`.** The app links PensieveKit and must not inherit the JSON-RPC stack.
- **All derivation logic lives in tested `PensieveKit`.** The `prime` and `mcp` commands stay thin: they call the kernel and map its output to stdout / SDK types. The kernel's `Codable` payload structs are the stable contract; SDK glue is verified by build + manual JSON-RPC smoke, mirroring how the app target is verified.
- **Read-only.** Both commands open the canonical store via `openCanonicalDatabaseReadOnly(at:)` (no migrator, cannot create the file, never contends with the writer). No write tools.
- **Trust gate unchanged.** Loose ends carry real `quote` + provenance (inside the gate). Prose is best-effort: `nil` on no-events/provider-failure/timeout — never a facts-dump substitute.
- **Narration cache key is `NarrationCacheKey.make(events:provider:)`** — event-set + `extractedAt` + provider. Never `nodeID + latestEventID`.
- **SQLiteData predicate syntax is `.eq(x)`, not `== x`.** Column names must match `@Table` property names exactly.
- **Tests use swift-testing** (`import Testing`, `@Test`, `#expect`, `#require`) and seed a throwaway temp store via `openCanonicalDatabase(at: tempURL("prefix"))` + `ProjectResolver(db:).resolve(path:kind:)`. Run the suite with `./scripts/test.sh` (or `swift test`).
- **Commit after every task.** End commit messages with the `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>` trailer. If backticks appear in a commit message, use `-F`/single quotes (backticks in `-m "..."` get shell-executed).
- Spec: `docs/superpowers/specs/2026-07-08-mcp-context-server-design.md`.

---

## File Structure

**New PensieveKit files:**
- `Sources/PensieveKit/Intelligence/NarrationCache.swift` — the standalone disposable SQLite prose cache.
- `Sources/PensieveKit/Query/SessionContextQueries.swift` — the kernel: `ProjectContextBundle`, `WhatsNextItem`, sub-structs, `nodeID(forPath:)`, `bundle(...)`, `rankedContext(...)`.
- `Sources/PensieveKit/Query/ProjectContextRender.swift` — `renderMarkdown(_:)` (resources) + `renderCompact(_:)` (prime).

**Modified PensieveKit files:**
- `Sources/PensieveKit/Query/NextQueries.swift` — widen `ranked` param `any DatabaseWriter` → `any DatabaseReader`.
- `Sources/PensieveKit/Support/PensievePaths.swift` — add `narrationCacheURL()`.

**New CLI files (`Sources/pensieve/`):**
- `Commands/Prime.swift` — the `prime` SessionStart hook.
- `Commands/Mcp.swift` — the stdio MCP server.

**Modified CLI files:**
- `Sources/pensieve/Pensieve.swift` — add `openCanonicalReadOnly()` helper; register `Prime` + `Mcp` subcommands.

**Modified build:**
- `Package.swift` — add the MCP SDK package + wire it into the `pensieve` target only.

**New tests:**
- `Tests/PensieveKitTests/NarrationCacheTests.swift`
- `Tests/PensieveKitTests/SessionContextQueriesTests.swift`
- `Tests/PensieveKitTests/ProjectContextRenderTests.swift`

---

## Task 1: Widen `NextQueries.ranked` to accept a read-only handle

The kernel and MCP server open the store read-only (`any DatabaseReader`), but `ranked` today takes `any DatabaseWriter`. `ranked` only reads, and `DatabaseWriter` refines `DatabaseReader`, so widening the parameter is strictly more permissive and source-compatible with the existing writer-passing callers.

**Files:**
- Modify: `Sources/PensieveKit/Query/NextQueries.swift:14`
- Test: `Tests/PensieveKitTests/NextQueriesTests.swift` (existing — must still pass)

**Interfaces:**
- Produces: `NextQueries.ranked(_ db: any DatabaseReader, now: Date) throws -> [NextItem]`

- [ ] **Step 1: Change the parameter type**

In `Sources/PensieveKit/Query/NextQueries.swift`, change the signature line:

```swift
  public static func ranked(_ db: any DatabaseReader, now: Date) throws -> [NextItem] {
```

(Only `DatabaseWriter` → `DatabaseReader` changes; the body is untouched — it already only calls `db.read`.)

- [ ] **Step 2: Run the existing NextQueries test to verify it still passes**

Run: `./scripts/test.sh --filter NextQueriesTests`
Expected: PASS. The existing test passes a `DatabasePool` (an `any DatabaseWriter` from `openCanonicalDatabase`), which upcasts to `any DatabaseReader`. The `Next.swift` CLI caller (`NextQueries.ranked(try openCanonical(), now:)`) likewise upcasts.

- [ ] **Step 3: Build the whole package to confirm no caller broke**

Run: `swift build`
Expected: builds clean.

- [ ] **Step 4: Commit**

```bash
git add Sources/PensieveKit/Query/NextQueries.swift
git commit -m "refactor(kit): NextQueries.ranked accepts a read-only handle

Widen the param from DatabaseWriter to DatabaseReader so read-only
observers (the MCP server, prime hook) can rank without a writer. ranked
only reads; existing writer-passing callers upcast unchanged.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 2: `PensievePaths.narrationCacheURL()`

**Files:**
- Modify: `Sources/PensieveKit/Support/PensievePaths.swift`

**Interfaces:**
- Produces: `PensievePaths.narrationCacheURL() -> URL` → `~/Library/Application Support/Pensieve/narration-cache.sqlite`

- [ ] **Step 1: Add the path helper**

In `Sources/PensieveKit/Support/PensievePaths.swift`, add after `captureURL()`:

```swift
  /// The disposable narration cache (shared across app / CLI / MCP). Not the canonical store,
  /// not the spool — losing it costs only a re-narrate.
  public static func narrationCacheURL() -> URL {
    supportDirectory().appendingPathComponent("narration-cache.sqlite")
  }
```

- [ ] **Step 2: Build to confirm it compiles**

Run: `swift build`
Expected: builds clean.

- [ ] **Step 3: Commit**

```bash
git add Sources/PensieveKit/Support/PensievePaths.swift
git commit -m "feat(kit): PensievePaths.narrationCacheURL()

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 3: `NarrationCache` — disposable cross-process prose store

A small standalone SQLite store keyed by `NarrationCacheKey.make(events:provider:)`. Best-effort: a corrupt/unopenable file is deleted and retried once; a still-failing open disables the cache (all ops no-op). GRDB's `DatabasePool` gives WAL + cross-process safety.

**Files:**
- Create: `Sources/PensieveKit/Intelligence/NarrationCache.swift`
- Test: `Tests/PensieveKitTests/NarrationCacheTests.swift`

**Interfaces:**
- Consumes: `PensievePaths.ensureParentDirectory(of:)`; `NarrationCacheKey.make(events:provider:)` (existing).
- Produces:
  - `struct NarrationCache: Sendable`
  - `init(url: URL)`
  - `func get(_ key: String) -> String?`
  - `func put(_ key: String, prose: String)`

- [ ] **Step 1: Write the failing tests**

Create `Tests/PensieveKitTests/NarrationCacheTests.swift`:

```swift
import Foundation
import Testing
import SQLiteData
@testable import PensieveKit

@Test func narrationCacheRoundTrips() {
  let cache = NarrationCache(url: tempURL("narr"))
  cache.put("k1", prose: "the recap")
  #expect(cache.get("k1") == "the recap")
  #expect(cache.get("missing") == nil)
}

@Test func narrationCacheMissesOnChangedKey() {
  // Two different event sets / providers → different keys → the old prose does not leak.
  let e1 = Event(nodeID: UUID(), sourceID: UUID(), occurredAt: Date(), kind: CaptureKind.ccSession,
                 summary: "s", detailJSON: "{}")
  let e2 = Event(nodeID: UUID(), sourceID: UUID(), occurredAt: Date(), kind: CaptureKind.ccSession,
                 summary: "s", detailJSON: "{}")
  let kOne = NarrationCacheKey.make(events: [e1], provider: "fm")
  let kTwo = NarrationCacheKey.make(events: [e1, e2], provider: "fm")
  let kProv = NarrationCacheKey.make(events: [e1], provider: "cloud")
  let cache = NarrationCache(url: tempURL("narr"))
  cache.put(kOne, prose: "one")
  #expect(cache.get(kOne) == "one")
  #expect(cache.get(kTwo) == nil)   // event set changed → auto-invalidated
  #expect(cache.get(kProv) == nil)  // provider changed → auto-invalidated
}

@Test func narrationCacheToleratesCorruptFile() throws {
  let url = tempURL("narr")
  try "not a database".write(to: url, atomically: true, encoding: .utf8)
  let cache = NarrationCache(url: url)   // must delete + recreate, not crash
  cache.put("k", prose: "v")
  #expect(cache.get("k") == "v")
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `./scripts/test.sh --filter NarrationCacheTests`
Expected: FAIL — `cannot find 'NarrationCache' in scope`.

- [ ] **Step 3: Implement `NarrationCache`**

Create `Sources/PensieveKit/Intelligence/NarrationCache.swift`:

```swift
import Foundation
import SQLiteData   // re-exports GRDB (DatabasePool, etc.)

/// A small, disposable, cross-process cache of node narration prose, keyed by
/// `NarrationCacheKey.make(events:provider:)`. Deliberately NOT the canonical store (whose
/// only writer stays `Ingester.drain()`) and NOT the capture spool — losing the file costs
/// only a re-narrate. Read by `pensieve prime` (cache-only) and written through by `pensieve mcp`.
public struct NarrationCache: Sendable {
  private let db: (any DatabaseWriter)?

  /// Opens (creating if needed) the cache at `url`. Best-effort: on a corrupt/unopenable file
  /// it deletes and retries once; if that still fails, the cache is disabled (all ops no-op).
  public init(url: URL) {
    if let opened = Self.open(url) {
      self.db = opened
    } else {
      try? FileManager.default.removeItem(at: url)
      self.db = Self.open(url)
    }
  }

  private static func open(_ url: URL) -> (any DatabaseWriter)? {
    do {
      try PensievePaths.ensureParentDirectory(of: url)
      let pool = try DatabasePool(path: url.path)
      try pool.write { db in
        try db.execute(sql: "CREATE TABLE IF NOT EXISTS narration (key TEXT PRIMARY KEY, prose TEXT NOT NULL)")
      }
      return pool
    } catch {
      return nil
    }
  }

  public func get(_ key: String) -> String? {
    guard let db else { return nil }
    let result = try? db.read { db -> String? in
      try String.fetchOne(db, sql: "SELECT prose FROM narration WHERE key = ?", arguments: [key])
    }
    return result ?? nil
  }

  public func put(_ key: String, prose: String) {
    guard let db else { return }
    try? db.write { db in
      try db.execute(sql: "INSERT OR REPLACE INTO narration (key, prose) VALUES (?, ?)", arguments: [key, prose])
    }
  }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `./scripts/test.sh --filter NarrationCacheTests`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/PensieveKit/Intelligence/NarrationCache.swift Tests/PensieveKitTests/NarrationCacheTests.swift
git commit -m "feat(kit): NarrationCache — disposable cross-process prose store

Keyed by NarrationCacheKey.make(events:provider:); best-effort (deletes +
recreates a corrupt file, disables on hard failure). WAL via DatabasePool.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 4: `SessionContextQueries` payload types + `nodeID(forPath:)` resolver

The read-only path→node resolver and the JSON-shaped payload structs. **The critical correctness point:** git sources are keyed on the canonicalized git **common-dir** (ends `.git`), not the working directory, so the resolver must compute the common-dir first (as capture does) and also try the plain canonical path (for non-git / claudeCode sources).

**Files:**
- Create: `Sources/PensieveKit/Query/SessionContextQueries.swift` (payload types + resolver in this task; `bundle`/`rankedContext` added in Tasks 5–6)
- Test: `Tests/PensieveKitTests/SessionContextQueriesTests.swift`

**Interfaces:**
- Consumes: `Git.commonDir(in:)`, `ProjectResolver.canonical(_:)` (internal, same module), `Source` (`.key`, `.nodeID`).
- Produces:
  - `struct BundleLooseEnd: Codable, Sendable { let text, quote, role: String; let ageDays: Int }`
  - `struct BundleEvent: Codable, Sendable { let summary, kind: String; let occurredAt: Date }`
  - `struct ProjectContextBundle: Codable, Sendable` with: `nodeID: UUID`, `name: String`, `kind: String`, `description: String`, `context: String`, `daysDormant: Int`, `openLooseEndCount: Int`, `score: Double`, `looseEnds: [BundleLooseEnd]`, `recentEvents: [BundleEvent]`, `prose: String?`
  - `struct WhatsNextItem: Codable, Sendable` with: `nodeID: UUID`, `name: String`, `kind: String`, `openLooseEnds: Int`, `daysDormant: Int`, `score: Double`, `topLooseEnd: String?`
  - `enum SessionContextQueries` with `static func nodeID(forPath path: String, _ db: any DatabaseReader) throws -> UUID?`

- [ ] **Step 1: Write the failing tests**

Create `Tests/PensieveKitTests/SessionContextQueriesTests.swift`:

```swift
import Foundation
import Testing
import SQLiteData
@testable import PensieveKit

@Test func nodeIDResolvesABoundNonGitPath() throws {
  let db = try openCanonicalDatabase(at: tempURL("sc"))
  let dir = try makePlainDir()   // not a git repo
  let (node, _) = try ProjectResolver(db: db).resolve(path: dir.path, kind: SourceKind.claudeCode)
  let resolved = try SessionContextQueries.nodeID(forPath: dir.path, db)
  #expect(resolved == node.id)
}

@Test func nodeIDResolvesAGitCwdViaCommonDir() throws {
  let db = try openCanonicalDatabase(at: tempURL("sc"))
  let (repo, _) = try makeCommittedRepo()
  // Seed the source the way capture does: keyed on the git common-dir, not the working dir.
  let common = Git.commonDir(in: repo.path)!
  let (node, _) = try ProjectResolver(db: db).resolve(path: common, kind: SourceKind.gitRepo)
  // Resolve from the WORKING directory — must map through the common-dir to the same node.
  let resolved = try SessionContextQueries.nodeID(forPath: repo.path, db)
  #expect(resolved == node.id)
}

@Test func nodeIDReturnsNilForUnboundPath() throws {
  let db = try openCanonicalDatabase(at: tempURL("sc"))
  let dir = try makePlainDir()
  #expect(try SessionContextQueries.nodeID(forPath: dir.path, db) == nil)
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `./scripts/test.sh --filter SessionContextQueriesTests`
Expected: FAIL — `cannot find 'SessionContextQueries' in scope`.

- [ ] **Step 3: Implement the payload types + resolver**

Create `Sources/PensieveKit/Query/SessionContextQueries.swift`:

```swift
import Foundation
import SQLiteData

// MARK: - JSON-shaped payloads (the stable MCP / prime contract)

public struct BundleLooseEnd: Codable, Sendable {
  public let text: String
  public let quote: String
  public let role: String
  public let ageDays: Int
}

public struct BundleEvent: Codable, Sendable {
  public let summary: String
  public let kind: String
  public let occurredAt: Date
}

/// One node's grounded state — "reload where this project stands." Loose ends carry verbatim
/// quotes (inside the trust gate); `prose` is best-effort (`nil` on no-events/failure/timeout).
public struct ProjectContextBundle: Codable, Sendable {
  public let nodeID: UUID
  public let name: String
  public let kind: String
  public let description: String
  public let context: String
  public let daysDormant: Int
  public let openLooseEndCount: Int
  public let score: Double
  public let looseEnds: [BundleLooseEnd]
  public let recentEvents: [BundleEvent]
  public let prose: String?
}

/// One ranked "what's next" row: score signals + the top cited loose end (verbatim quote).
public struct WhatsNextItem: Codable, Sendable {
  public let nodeID: UUID
  public let name: String
  public let kind: String
  public let openLooseEnds: Int
  public let daysDormant: Int
  public let score: Double
  public let topLooseEnd: String?
}

public enum SessionContextQueries {
  /// Canonical path → source → node, read-only. Tries the git common-dir first (sources are keyed
  /// on `…/.git`, not the working dir), then the plain canonical path (non-git / claudeCode sources).
  /// Returns nil if the path binds to no node.
  public static func nodeID(forPath path: String, _ db: any DatabaseReader) throws -> UUID? {
    var candidates: [String] = []
    if let common = Git.commonDir(in: path) { candidates.append(common) }  // already symlink-resolved
    candidates.append(ProjectResolver.canonical(path))
    return try db.read { db in
      for key in candidates {
        if let source = try Source.where({ $0.key.eq(key) }).fetchOne(db) {
          return source.nodeID
        }
      }
      return nil
    }
  }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `./scripts/test.sh --filter SessionContextQueriesTests`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/PensieveKit/Query/SessionContextQueries.swift Tests/PensieveKitTests/SessionContextQueriesTests.swift
git commit -m "feat(kit): SessionContextQueries payloads + read-only path->node resolver

Codable ProjectContextBundle / WhatsNextItem + nodeID(forPath:) that maps a
git working dir through its common-dir to the bound node (falls back to the
canonical path for non-git sources).

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 5: `SessionContextQueries.bundle(...)` — the grounded bundle + prose state machine

Composes facts + loose ends + recent events into a `ProjectContextBundle`, and runs the **cache-first → bounded-narrate → nil** prose logic. Prose generation is injected (a `SummaryBuilder?` + `providerKind` + `NarrationCache?`) so it's fully testable with a stub provider and no real model. A `nil` builder means cache-read-only (what `prime` passes); a real builder means narrate-under-timeout-and-write-through on a cache miss (what `mcp` passes).

**Files:**
- Modify: `Sources/PensieveKit/Query/SessionContextQueries.swift`
- Test: `Tests/PensieveKitTests/SessionContextQueriesTests.swift`

**Interfaces:**
- Consumes: `NodeFactsQueries.facts(for:_:now:)`, `LooseEndQueries.open(_:nodeID:now:)`, `ProjectQueries.status(_:node:limit:)`, `SummaryBuilder.narrate(project:events:)`, `NarrationCacheKey.make(events:provider:)`, `NarrationCache.get/put`.
- Produces: `SessionContextQueries.bundle(forPath:nodeID:_:now:recentLimit:summaryBuilder:providerKind:cache:narrateTimeout:) async throws -> ProjectContextBundle?`

- [ ] **Step 1: Write the failing tests**

Add to `Tests/PensieveKitTests/SessionContextQueriesTests.swift`:

```swift
/// A canned provider: `complete` returns a fixed string so narration is deterministic and offline.
private struct StubProvider: LLMProvider {
  let reply: String
  func complete(prompt: String) async throws -> String { reply }
}

/// Seeds one node with one event + one loose end; returns the node and the event.
private func seedOneNode(_ db: any DatabaseWriter) throws -> (node: Node, event: Event) {
  let (node, source) = try ProjectResolver(db: db).resolve(path: "/p/one", kind: SourceKind.claudeCode)
  let event = Event(nodeID: node.id, sourceID: source.id, occurredAt: Date(),
                    kind: CaptureKind.ccSession, summary: "did the thing", detailJSON: "{}", fingerprint: "f1")
  try db.write { db in
    try Event.insert { event }.execute(db)
    try LooseEnd.insert {
      LooseEnd(nodeID: node.id, sourceEventID: event.id, text: "finish auth",
               quote: "we must finish the auth flow", role: "user", sourceMessageIndex: 0)
    }.execute(db)
  }
  return (node, event)
}

@Test func bundleComposesGroundedState() async throws {
  let db = try openCanonicalDatabase(at: tempURL("sc"))
  let (node, _) = try seedOneNode(db)
  let bundle = try #require(try await SessionContextQueries.bundle(
    forPath: "/p/one", nodeID: nil, db, now: Date(),
    summaryBuilder: nil, providerKind: "fm", cache: nil))
  #expect(bundle.nodeID == node.id)
  #expect(bundle.openLooseEndCount == 1)
  #expect(bundle.looseEnds.first?.quote == "we must finish the auth flow")
  #expect(bundle.recentEvents.first?.summary == "did the thing")
  #expect(bundle.prose == nil)   // no builder, empty cache → no prose (never a facts-dump)
}

@Test func bundleReturnsNilForUnboundPath() async throws {
  let db = try openCanonicalDatabase(at: tempURL("sc"))
  let bundle = try await SessionContextQueries.bundle(
    forPath: "/nope", nodeID: nil, db, now: Date(),
    summaryBuilder: nil, providerKind: "fm", cache: nil)
  #expect(bundle == nil)
}

@Test func bundleServesCachedProseWithoutABuilder() async throws {
  let db = try openCanonicalDatabase(at: tempURL("sc"))
  let (node, _) = try seedOneNode(db)
  let cache = NarrationCache(url: tempURL("narr"))
  // Pre-warm the cache with the exact key bundle() will compute (top recentLimit events, same provider).
  let events = try ProjectQueries.status(db, node: node, limit: 8).recentEvents
  cache.put(NarrationCacheKey.make(events: events, provider: "fm"), prose: "cached recap")
  let bundle = try #require(try await SessionContextQueries.bundle(
    forPath: "/p/one", nodeID: nil, db, now: Date(),
    summaryBuilder: nil, providerKind: "fm", cache: cache))
  #expect(bundle.prose == "cached recap")
}

@Test func bundleNarratesOnMissAndWritesThrough() async throws {
  let db = try openCanonicalDatabase(at: tempURL("sc"))
  let (node, _) = try seedOneNode(db)
  let cache = NarrationCache(url: tempURL("narr"))
  let builder = SummaryBuilder(provider: StubProvider(reply: "fresh recap"))
  let bundle = try #require(try await SessionContextQueries.bundle(
    forPath: "/p/one", nodeID: nil, db, now: Date(),
    summaryBuilder: builder, providerKind: "fm", cache: cache))
  #expect(bundle.prose == "fresh recap")
  // Write-through: the key is now populated.
  let events = try ProjectQueries.status(db, node: node, limit: 8).recentEvents
  #expect(cache.get(NarrationCacheKey.make(events: events, provider: "fm")) == "fresh recap")
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `./scripts/test.sh --filter SessionContextQueriesTests`
Expected: FAIL — `bundle(forPath:...)` not found.

- [ ] **Step 3: Implement `bundle(...)` and the timeout helper**

Add to `enum SessionContextQueries` in `Sources/PensieveKit/Query/SessionContextQueries.swift`:

```swift
  /// The grounded bundle for a node identified by `nodeID` (preferred) or `path`. Read-only.
  /// Prose is cache-first → bounded narrate → nil:
  ///   • `summaryBuilder == nil`  → cache-read-only (the `prime` hook: never narrates).
  ///   • `summaryBuilder != nil`  → on a cache miss, narrate under `narrateTimeout`s and write
  ///     through on success; `nil` on no-events/failure/timeout (never a facts-dump).
  public static func bundle(
    forPath path: String?, nodeID explicitID: UUID?,
    _ db: any DatabaseReader, now: Date,
    recentLimit: Int = 8,
    summaryBuilder: SummaryBuilder?, providerKind: String,
    cache: NarrationCache?, narrateTimeout: Double = 3.0
  ) async throws -> ProjectContextBundle? {
    // 1. Resolve the node.
    let resolvedID: UUID?
    if let explicitID { resolvedID = explicitID }
    else if let path { resolvedID = try nodeID(forPath: path, db) }
    else { resolvedID = nil }
    guard let id = resolvedID else { return nil }
    guard let facts = try NodeFactsQueries.facts(for: [id], db, now: now).first else { return nil }
    let node = facts.node

    // 2. Grounded pieces (pure queries).
    let ends = try LooseEndQueries.open(db, nodeID: id, now: now)
    let status = try ProjectQueries.status(db, node: node, limit: recentLimit)
    let score = Double(facts.openLooseEnds) * 2 + Double(facts.daysDormant)   // matches NextQueries

    // 3. Prose: cache-first → bounded narrate → nil.
    let key = NarrationCacheKey.make(events: status.recentEvents, provider: providerKind)
    var prose = cache?.get(key)
    if prose == nil, let builder = summaryBuilder {
      prose = await narrateWithin(narrateTimeout, builder: builder, project: node, events: status.recentEvents)
      if let prose { cache?.put(key, prose: prose) }
    }

    return ProjectContextBundle(
      nodeID: id, name: node.name, kind: node.kind, description: node.description, context: node.context,
      daysDormant: facts.daysDormant, openLooseEndCount: facts.openLooseEnds, score: score,
      looseEnds: ends.map { BundleLooseEnd(text: $0.looseEnd.text, quote: $0.looseEnd.quote,
                                           role: $0.looseEnd.role, ageDays: $0.ageDays) },
      recentEvents: status.recentEvents.map { BundleEvent(summary: $0.summary, kind: $0.kind,
                                                          occurredAt: $0.occurredAt) },
      prose: prose)
  }

  /// Races `narrate` against a timeout; returns nil if the model doesn't answer in time (FM
  /// cold-start can be ≫ a couple seconds and the caller is blocking on the result).
  private static func narrateWithin(_ seconds: Double, builder: SummaryBuilder,
                                    project: Node, events: [Event]) async -> String? {
    await withTaskGroup(of: String?.self) { group in
      group.addTask { await builder.narrate(project: project, events: events) }
      group.addTask {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        return nil
      }
      let first = await group.next() ?? nil
      group.cancelAll()
      return first
    }
  }
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `./scripts/test.sh --filter SessionContextQueriesTests`
Expected: PASS (all SessionContextQueries tests, incl. the 4 new bundle tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/PensieveKit/Query/SessionContextQueries.swift Tests/PensieveKitTests/SessionContextQueriesTests.swift
git commit -m "feat(kit): SessionContextQueries.bundle — grounded bundle + prose state machine

Composes facts/loose-ends/recent-events; prose is cache-first then a bounded
narrate (3s) with write-through, nil on miss when no builder is injected.
Trust gate intact: quotes cited, prose best-effort.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 6: `SessionContextQueries.rankedContext(...)` — filtered, sliced, cited

Wraps `NextQueries.ranked` with the work/personal context filter (via `NodeContextResolver.visibleNodeIDs`), a `limit` slice, and each node's top cited loose end.

**Files:**
- Modify: `Sources/PensieveKit/Query/SessionContextQueries.swift`
- Test: `Tests/PensieveKitTests/SessionContextQueriesTests.swift`

**Interfaces:**
- Consumes: `NextQueries.ranked(_:now:)` (reader — Task 1), `ProjectQueries.all(_:)`, `NodeContextResolver.visibleNodeIDs(for:in:)`, `LooseEndQueries.open(_:nodeID:now:)`.
- Produces: `SessionContextQueries.rankedContext(limit:context:_:now:) throws -> [WhatsNextItem]`

- [ ] **Step 1: Write the failing test**

Add to `Tests/PensieveKitTests/SessionContextQueriesTests.swift`:

```swift
@Test func rankedContextFiltersSlicesAndCites() throws {
  let db = try openCanonicalDatabase(at: tempURL("sc"))
  let resolver = ProjectResolver(db: db)
  let (work, ws) = try resolver.resolve(path: "/p/work", kind: SourceKind.claudeCode)
  let (personal, ps) = try resolver.resolve(path: "/p/personal", kind: SourceKind.claudeCode)
  let old = Calendar.current.date(byAdding: .day, value: -10, to: Date())!
  try db.write { db in
    try Node.where { $0.id.eq(work.id) }.update { $0.context = #bind(NodeContext.work) }.execute(db)
    try Node.where { $0.id.eq(personal.id) }.update { $0.context = #bind(NodeContext.personal) }.execute(db)
    let ew = Event(nodeID: work.id, sourceID: ws.id, occurredAt: old, kind: CaptureKind.ccSession,
                   summary: "s", detailJSON: "{}", fingerprint: "w1")
    let ep = Event(nodeID: personal.id, sourceID: ps.id, occurredAt: old, kind: CaptureKind.ccSession,
                   summary: "s", detailJSON: "{}", fingerprint: "p1")
    try Event.insert { ew }.execute(db); try Event.insert { ep }.execute(db)
    try LooseEnd.insert {
      LooseEnd(nodeID: work.id, sourceEventID: ew.id, text: "t",
               quote: "ship the work thing", role: "user", sourceMessageIndex: 0)
    }.execute(db)
  }
  // Unfiltered: both nodes present.
  #expect(try SessionContextQueries.rankedContext(limit: 5, context: nil, db, now: Date()).count == 2)
  // Work focus: personal is muted; the work node's top loose end is cited.
  let work_only = try SessionContextQueries.rankedContext(limit: 5, context: NodeContext.work, db, now: Date())
  #expect(work_only.count == 1)
  #expect(work_only.first?.nodeID == work.id)
  #expect(work_only.first?.topLooseEnd == "ship the work thing")
  // Limit is honored.
  #expect(try SessionContextQueries.rankedContext(limit: 1, context: nil, db, now: Date()).count == 1)
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `./scripts/test.sh --filter SessionContextQueriesTests`
Expected: FAIL — `rankedContext` not found.

- [ ] **Step 3: Implement `rankedContext(...)`**

Add to `enum SessionContextQueries`:

```swift
  /// Ranked "what's next" across all active nodes, optionally restricted to a work/personal
  /// context (unset nodes always show; the opposite explicit context is muted), sliced to
  /// `limit`, each carrying its oldest open loose end's verbatim quote.
  public static func rankedContext(limit: Int, context: String?,
                                   _ db: any DatabaseReader, now: Date) throws -> [WhatsNextItem] {
    let items = try NextQueries.ranked(db, now: now)
    var filtered = items
    if let context, !context.isEmpty {
      let all = try ProjectQueries.all(db)
      let visible = NodeContextResolver.visibleNodeIDs(for: context, in: all)
      filtered = items.filter { visible.contains($0.project.id) }
    }
    return try db.read { db in
      try filtered.prefix(limit).map { item in
        let ends = try LooseEnd.where { $0.nodeID.eq(item.project.id) && LooseEnd.isOpen($0) }
          .order { $0.createdAt }.fetchAll(db)
        return WhatsNextItem(
          nodeID: item.project.id, name: item.project.name, kind: item.project.kind,
          openLooseEnds: item.openLooseEnds, daysDormant: item.daysDormant, score: item.score,
          topLooseEnd: ends.first?.quote)
      }
    }
  }
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `./scripts/test.sh --filter SessionContextQueriesTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/PensieveKit/Query/SessionContextQueries.swift Tests/PensieveKitTests/SessionContextQueriesTests.swift
git commit -m "feat(kit): SessionContextQueries.rankedContext — filtered, sliced, cited

Wraps NextQueries.ranked with work/personal visibility (NodeContextResolver),
a limit slice, and each node's oldest open loose-end quote.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 7: Bundle renderers — `renderMarkdown` + `renderCompact`

Pure string renderers over `ProjectContextBundle`: markdown for MCP resources, compact plain text for the `prime` hook's `additionalContext`. Both omit the prose section when `prose == nil`.

**Files:**
- Create: `Sources/PensieveKit/Query/ProjectContextRender.swift`
- Test: `Tests/PensieveKitTests/ProjectContextRenderTests.swift`

**Interfaces:**
- Consumes: `ProjectContextBundle`, `BundleLooseEnd`, `BundleEvent`.
- Produces:
  - `SessionContextRender.markdown(_ bundle: ProjectContextBundle) -> String`
  - `SessionContextRender.compact(_ bundle: ProjectContextBundle) -> String`

- [ ] **Step 1: Write the failing tests**

Create `Tests/PensieveKitTests/ProjectContextRenderTests.swift`:

```swift
import Foundation
import Testing
@testable import PensieveKit

private func sampleBundle(prose: String?) -> ProjectContextBundle {
  ProjectContextBundle(
    nodeID: UUID(), name: "Pensieve", kind: NodeKind.project,
    description: "context reconstruction tool", context: NodeContext.work,
    daysDormant: 3, openLooseEndCount: 1, score: 5,
    looseEnds: [BundleLooseEnd(text: "finish auth", quote: "we must finish the auth flow",
                               role: "user", ageDays: 3)],
    recentEvents: [BundleEvent(summary: "did the thing", kind: "cc.session", occurredAt: Date())],
    prose: prose)
}

@Test func markdownIncludesNameLooseEndAndProse() {
  let md = SessionContextRender.markdown(sampleBundle(prose: "A short recap."))
  #expect(md.contains("Pensieve"))
  #expect(md.contains("we must finish the auth flow"))
  #expect(md.contains("A short recap."))
}

@Test func markdownOmitsProseSectionWhenNil() {
  let md = SessionContextRender.markdown(sampleBundle(prose: nil))
  #expect(md.contains("we must finish the auth flow"))
  #expect(!md.lowercased().contains("last work done"))   // the prose heading is absent
}

@Test func compactIsPlainAndCitesLooseEnds() {
  let text = SessionContextRender.compact(sampleBundle(prose: nil))
  #expect(text.contains("Pensieve"))
  #expect(text.contains("we must finish the auth flow"))
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `./scripts/test.sh --filter ProjectContextRenderTests`
Expected: FAIL — `cannot find 'SessionContextRender' in scope`.

- [ ] **Step 3: Implement the renderers**

Create `Sources/PensieveKit/Query/ProjectContextRender.swift`:

```swift
import Foundation

/// Pure renderers for a ProjectContextBundle. Markdown feeds MCP resources (Claude Code renders
/// it); compact plain text feeds the `prime` hook's additionalContext. Both omit prose when nil.
public enum SessionContextRender {
  public static func markdown(_ b: ProjectContextBundle) -> String {
    var out = "# \(b.name)\n"
    if !b.description.isEmpty { out += "\n\(b.description)\n" }
    out += "\n*\(b.kind) · \(b.daysDormant)d dormant · \(b.openLooseEndCount) open loose end(s)*\n"
    if let prose = b.prose {
      out += "\n## Last Work Done\n\n\(prose)\n"
    }
    if !b.looseEnds.isEmpty {
      out += "\n## Open Loose Ends\n\n"
      for le in b.looseEnds {
        out += "- \(le.text)\n  > \(le.quote)\n"
      }
    }
    if !b.recentEvents.isEmpty {
      out += "\n## Recent Activity\n\n"
      for e in b.recentEvents { out += "- \(e.summary)\n" }
    }
    return out
  }

  public static func compact(_ b: ProjectContextBundle) -> String {
    var lines: [String] = []
    lines.append("Pensieve — \(b.name) (\(b.daysDormant)d dormant, \(b.openLooseEndCount) open loose end(s))")
    if let prose = b.prose { lines.append(prose) }
    if !b.looseEnds.isEmpty {
      lines.append("Open loose ends:")
      for le in b.looseEnds { lines.append("• \(le.text) — \"\(le.quote)\"") }
    }
    return lines.joined(separator: "\n")
  }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `./scripts/test.sh --filter ProjectContextRenderTests`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/PensieveKit/Query/ProjectContextRender.swift Tests/PensieveKitTests/ProjectContextRenderTests.swift
git commit -m "feat(kit): SessionContextRender — markdown (resources) + compact (prime)

Pure renderers over ProjectContextBundle; both omit the prose section when nil.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 8: `openCanonicalReadOnly()` helper + `pensieve prime` hook

The read-only CLI opener (the existing `openCanonical()` returns a writer + migrates) and the ambient `prime` SessionStart hook. `prime` reads the hook JSON's `cwd` from stdin (mirroring `capture-session-start`), builds the bundle **cache-read-only** (no builder → never narrates → never blocks), and prints the compact render — or nothing for an unbound cwd.

**Files:**
- Modify: `Sources/pensieve/Pensieve.swift` (add `openCanonicalReadOnly()`; register `Prime`)
- Create: `Sources/pensieve/Commands/Prime.swift`

**Interfaces:**
- Consumes: `openCanonicalDatabaseReadOnly(at:)`, `PensievePaths.canonicalURL()`, `PensieveDefaults.shared()`, `resolvedProviderKind(defaults:cloudConfig:apiKey:)`, `NarrationCache(url:)`, `PensievePaths.narrationCacheURL()`, `SessionContextQueries.bundle(...)`, `SessionContextRender.compact(_:)`.
- Produces: `openCanonicalReadOnly() throws -> any DatabaseReader`; the `prime` subcommand.

- [ ] **Step 1: Add the read-only opener**

In `Sources/pensieve/Pensieve.swift`, add after `openCanonical()`:

```swift
/// Opens the canonical store strictly read-only (no migrator, cannot create the file).
/// Override for tests via PENSIEVE_DB. For read-only surfaces: `prime`, `mcp`.
func openCanonicalReadOnly() throws -> any DatabaseReader {
  if let override = ProcessInfo.processInfo.environment["PENSIEVE_DB"] {
    return try openCanonicalDatabaseReadOnly(at: URL(fileURLWithPath: override))
  }
  return try openCanonicalDatabaseReadOnly(at: PensievePaths.canonicalURL())
}
```

- [ ] **Step 2: Create the `prime` command**

Create `Sources/pensieve/Commands/Prime.swift`:

```swift
import ArgumentParser
import Foundation
import PensieveKit
import SQLiteData

struct Prime: AsyncParsableCommand {
  static let configuration = CommandConfiguration(commandName: "prime",
    abstract: "SessionStart hook: emit the cwd's grounded Pensieve context (reads hook JSON from stdin).")

  private struct HookInput: Decodable { let cwd: String? }

  func run() async throws {
    // Read the hook's cwd from stdin; fall back to the process cwd. Never fail a session.
    let data = FileHandle.standardInput.readDataToEndOfFile()
    let cwd = (try? JSONDecoder().decode(HookInput.self, from: data))?.cwd
      ?? FileManager.default.currentDirectoryPath
    guard let db = try? openCanonicalReadOnly() else { return }
    let providerKind = resolvedProviderKind(defaults: PensieveDefaults.shared(), cloudConfig: nil, apiKey: nil)
    let cache = NarrationCache(url: PensievePaths.narrationCacheURL())
    // Cache-READ-ONLY: summaryBuilder nil → never narrates, never spawns, never blocks.
    // `try?` on a `-> ProjectContextBundle?` yields a double optional; `?? nil` flattens it so
    // both a thrown error and an unbound cwd (nil bundle) emit nothing.
    let result = try? await SessionContextQueries.bundle(
      forPath: cwd, nodeID: nil, db, now: Date(),
      summaryBuilder: nil, providerKind: providerKind, cache: cache)
    guard let bundle = result ?? nil else { return }
    print(SessionContextRender.compact(bundle))
  }
}
```

- [ ] **Step 3: Register the subcommand**

In `Sources/pensieve/Pensieve.swift`, add `Prime.self` to the `subcommands:` array (e.g. after `Sync.self`).

- [ ] **Step 4: Build**

Run: `swift build`
Expected: builds clean.

- [ ] **Step 5: Smoke-test `prime` against a seeded temp store**

Run (unbound cwd → emits nothing):

```bash
PENSIEVE_DB=$(mktemp -u).sqlite bash -c 'echo "{\"cwd\":\"/definitely/not/bound\"}" | swift run pensieve prime'
```

Expected: **no output** (unbound cwd is silent). This exercises the read-only open + resolver on an empty store without needing a bound node.

- [ ] **Step 6: Commit**

```bash
git add Sources/pensieve/Pensieve.swift Sources/pensieve/Commands/Prime.swift
git commit -m "feat(cli): pensieve prime — ambient SessionStart context hook

Read-only, cache-only prose (never narrates/spawns/blocks); prints the compact
bundle for the hook cwd, nothing for an unbound cwd. Adds openCanonicalReadOnly().

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 9: MCP SDK dependency + `pensieve mcp` with the two tools

Add the official MCP Swift SDK to the `pensieve` target only, and stand up the stdio server with `project_context` + `whats_next`. The Kit payloads are the fixed contract; the handlers JSON-encode them into MCP tool results.

> **SDK API note:** The handler-registration names below (`Server`, `withMethodHandler(ListTools.self)`, `CallTool`, `Tool`, `Tool.Content`, `StdioTransport`) are from the SDK's `main` source, pinned here to `0.12.1`. If the resolved `0.12.1` tag's result initializers use slightly different labels, **match them — the Kit payload contract does not change.** Verify names with a build after Step 2.

**Files:**
- Modify: `Package.swift`
- Create: `Sources/pensieve/Commands/Mcp.swift`
- Modify: `Sources/pensieve/Pensieve.swift` (register `Mcp`)

**Interfaces:**
- Consumes: `SessionContextQueries.bundle(...)`, `SessionContextQueries.rankedContext(...)`, `makeDefaultLLMProvider(defaults:)`, `SummaryBuilder(provider:)`, `resolvedProviderKind(...)`, `NarrationCache`.
- Produces: the `mcp` subcommand; a private `PensieveMCP` helper that builds tool-result JSON from the kernel.

- [ ] **Step 1: Add the dependency (pensieve target only)**

In `Package.swift`, add to `dependencies`:

```swift
    .package(url: "https://github.com/modelcontextprotocol/swift-sdk", exact: "0.12.1"),
```

And add to the **`pensieve` executable target's** `dependencies` (NOT PensieveKit):

```swift
        .product(name: "MCP", package: "swift-sdk"),
```

- [ ] **Step 2: Resolve + confirm the product/package names**

Run: `swift package resolve`
Expected: resolves `swift-sdk` at `0.12.1`. Then `swift build`. If the compiler reports the package name differs from `swift-sdk`, run `swift package describe --type json | grep -i mcp` to find the exact package identity and fix the `.product(package:)` label.

- [ ] **Step 3: Create the `mcp` command with the two tools**

Create `Sources/pensieve/Commands/Mcp.swift`:

```swift
import ArgumentParser
import Foundation
import MCP
import PensieveKit
import SQLiteData

struct Mcp: AsyncParsableCommand {
  static let configuration = CommandConfiguration(commandName: "mcp",
    abstract: "Long-lived stdio MCP server exposing grounded Pensieve context (read-only).")

  func run() async throws {
    let server = Server(
      name: "pensieve", version: "0.1.0",
      capabilities: .init(resources: .init(), tools: .init(listChanged: false)))

    // project_context
    await server.withMethodHandler(ListTools.self) { _ in
      .init(tools: [
        Tool(name: "project_context",
             description: "Reload where a project stands: facts, cited open loose ends, recent activity, prose recap. Defaults to the current workspace.",
             inputSchema: .object(["type": .string("object"), "properties": .object([
               "path": .object(["type": .string("string"), "description": .string("directory to resolve; defaults to the workspace")]),
               "node_id": .object(["type": .string("string"), "description": .string("resolve a specific node by UUID")]),
             ])]),
             annotations: .init(readOnlyHint: true, openWorldHint: false)),
        Tool(name: "whats_next",
             description: "Ranked queue of what to pick up across all projects, on grounded signals (open loose ends, dormancy).",
             inputSchema: .object(["type": .string("object"), "properties": .object([
               "limit": .object(["type": .string("number"), "description": .string("max rows (default 5)")]),
               "context": .object(["type": .string("string"), "description": .string("filter: work | personal")]),
             ])]),
             annotations: .init(readOnlyHint: true, openWorldHint: false)),
      ])
    }

    await server.withMethodHandler(CallTool.self) { params in
      switch params.name {
      case "project_context":
        let path = params.arguments?["path"]?.stringValue
        let nodeID = (params.arguments?["node_id"]?.stringValue).flatMap { UUID(uuidString: $0) }
        let json = try await PensieveMCP.projectContextJSON(path: path, nodeID: nodeID)
        return PensieveMCP.result(json)
      case "whats_next":
        let limit = params.arguments?["limit"]?.intValue ?? 5
        let context = params.arguments?["context"]?.stringValue
        let json = try PensieveMCP.whatsNextJSON(limit: limit, context: context)
        return PensieveMCP.result(json)
      default:
        return .init(content: [.text("unknown tool")], isError: true)
      }
    }

    try await server.start(transport: StdioTransport())
    await server.waitUntilCompleted()
  }
}

/// Bridges the tested Kit kernel to MCP results. Opens the store read-only per call (fresh read
/// transaction sees the latest committed drain). The prose builder is on-device by default.
enum PensieveMCP {
  static let maxResultSizeMeta = "anthropic/maxResultSizeChars"

  private static func makeBuilderAndKind() -> (SummaryBuilder, String) {
    let defaults = PensieveDefaults.shared()
    let provider = makeDefaultLLMProvider(defaults: defaults)
    let kind = resolvedProviderKind(defaults: defaults, cloudConfig: nil, apiKey: nil)
    return (SummaryBuilder(provider: provider), kind)
  }

  static func projectContextJSON(path: String?, nodeID: UUID?) async throws -> Data {
    let db = try openCanonicalReadOnly()
    let (builder, kind) = makeBuilderAndKind()
    let cache = NarrationCache(url: PensievePaths.narrationCacheURL())
    let effectivePath = path ?? FileManager.default.currentDirectoryPath
    let bundle = try await SessionContextQueries.bundle(
      forPath: effectivePath, nodeID: nodeID, db, now: Date(),
      summaryBuilder: builder, providerKind: kind, cache: cache)
    let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
    return try encoder.encode(bundle)   // encodes `null` for an unbound path
  }

  static func whatsNextJSON(limit: Int, context: String?) throws -> Data {
    let db = try openCanonicalReadOnly()
    let items = try SessionContextQueries.rankedContext(limit: limit, context: context, db, now: Date())
    let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
    return try encoder.encode(items)
  }

  /// A text tool result carrying the JSON payload + the result-size hint Claude Code honors.
  static func result(_ json: Data) -> CallTool.Result {
    let text = String(decoding: json, as: UTF8.self)
    return .init(content: [.text(text)],
                 _meta: .object([maxResultSizeMeta: .int(500_000)]))
  }
}
```

- [ ] **Step 4: Register the subcommand**

In `Sources/pensieve/Pensieve.swift`, add `Mcp.self` to the `subcommands:` array.

- [ ] **Step 5: Build and reconcile SDK types**

Run: `swift build`
Expected: builds clean. If a `CallTool.Result` / `Tool.Content` / `Tool.Annotations` / `Value` initializer label differs in `0.12.1`, adjust the call to match (the research was taken from `main`; `0.12.1` is close but verify). Common adjustments: `.text(...)` may require `.text(text:)`; `_meta` may be a named type. Keep the Kit-encoded `json` payload exactly as-is.

- [ ] **Step 6: Smoke-test the stdio JSON-RPC handshake**

Create `/private/tmp/claude-501/-Users-moritz-Projects-pensieve/4f2deae3-c43f-49d0-bd2e-ad64547c640a/scratchpad/mcp-smoke.jsonl` with three framed requests:

```
{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"smoke","version":"1"}}}
{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}
{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"whats_next","arguments":{"limit":3}}}
```

Run against an empty temp store:

```bash
PENSIEVE_DB=$(mktemp -u).sqlite bash -c 'cat /private/tmp/claude-501/-Users-moritz-Projects-pensieve/4f2deae3-c43f-49d0-bd2e-ad64547c640a/scratchpad/mcp-smoke.jsonl | swift run pensieve mcp'
```

Expected: three JSON-RPC responses on stdout — an `initialize` result, a `tools/list` listing `project_context` + `whats_next`, and a `tools/call` result whose content text is `[]` (empty ranked list on an empty store). If the server blocks waiting for more input after the third response, that's fine — Ctrl-C it; the three responses appearing is the pass condition.

- [ ] **Step 7: Commit**

```bash
git add Package.swift Package.resolved Sources/pensieve/Commands/Mcp.swift Sources/pensieve/Pensieve.swift
git commit -m "feat(cli): pensieve mcp — stdio MCP server with project_context + whats_next

Official MCP Swift SDK (0.12.1, pensieve target only). Thin over
SessionContextQueries; read-only per call; maxResultSizeChars hint set.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 10: MCP resources over `pensieve://` (user-attach surface)

Expose the same bundle as user-attachable resources: a `pensieve://node/{id}` template + a static `pensieve://smartlist/whats-next`, served as `text/markdown` via `SessionContextRender.markdown`.

> **SDK API note:** Same caveat as Task 9 — `ListResources`, `ListResourceTemplates`, `ReadResource`, and their `Result`/`Resource.Content` initializers are pinned to `0.12.1`; match the resolved labels, keep the Kit rendering fixed.

**Files:**
- Modify: `Sources/pensieve/Commands/Mcp.swift`

**Interfaces:**
- Consumes: `SessionContextQueries.bundle(...)`, `SessionContextQueries.rankedContext(...)`, `SessionContextRender.markdown(_:)`.
- Produces: resource handlers on the same `server`; `PensieveMCP.nodeMarkdown(id:)` and `PensieveMCP.whatsNextMarkdown()`.

- [ ] **Step 1: Add render helpers to `PensieveMCP`**

In `Sources/pensieve/Commands/Mcp.swift`, add to `enum PensieveMCP`:

```swift
  static func nodeMarkdown(id: UUID) async throws -> String? {
    let db = try openCanonicalReadOnly()
    let (builder, kind) = makeBuilderAndKind()
    let cache = NarrationCache(url: PensievePaths.narrationCacheURL())
    guard let bundle = try await SessionContextQueries.bundle(
      forPath: nil, nodeID: id, db, now: Date(),
      summaryBuilder: builder, providerKind: kind, cache: cache) else { return nil }
    return SessionContextRender.markdown(bundle)
  }

  static func whatsNextMarkdown() throws -> String {
    let db = try openCanonicalReadOnly()
    let items = try SessionContextQueries.rankedContext(limit: 10, context: nil, db, now: Date())
    var out = "# What's Next\n\n"
    for i in items { out += "- **\(i.name)** — \(i.openLooseEnds) open, \(i.daysDormant)d dormant"
      if let q = i.topLooseEnd { out += "\n  > \(q)" }; out += "\n" }
    return out
  }
```

- [ ] **Step 2: Register the resource handlers**

In `Mcp.run()`, after the `CallTool` handler and before `server.start(...)`, add:

```swift
    await server.withMethodHandler(ListResources.self) { _ in
      .init(resources: [
        Resource(name: "What's Next", uri: "pensieve://smartlist/whats-next",
                 description: "Ranked queue across all projects", mimeType: "text/markdown"),
      ])
    }
    await server.withMethodHandler(ListResourceTemplates.self) { _ in
      .init(templates: [
        Resource.Template(uriTemplate: "pensieve://node/{id}", name: "Project context",
                          description: "One project's grounded context", mimeType: "text/markdown"),
      ])
    }
    await server.withMethodHandler(ReadResource.self) { params in
      let uri = params.uri
      if uri == "pensieve://smartlist/whats-next" {
        let md = try PensieveMCP.whatsNextMarkdown()
        return .init(contents: [.text(md, uri: uri, mimeType: "text/markdown")])
      }
      if uri.hasPrefix("pensieve://node/"),
         let id = UUID(uuidString: String(uri.dropFirst("pensieve://node/".count))),
         let md = try await PensieveMCP.nodeMarkdown(id: id) {
        return .init(contents: [.text(md, uri: uri, mimeType: "text/markdown")])
      }
      return .init(contents: [.text("not found", uri: uri, mimeType: "text/plain")])
    }
```

- [ ] **Step 3: Build and reconcile SDK types**

Run: `swift build`
Expected: builds clean; adjust `Resource` / `Resource.Template` / `ReadResource.Result` / `.text(_:uri:mimeType:)` initializer labels to the resolved `0.12.1` names if the compiler disagrees.

- [ ] **Step 4: Smoke-test resources**

Append to the smoke file two more requests and re-run:

```
{"jsonrpc":"2.0","id":4,"method":"resources/templates/list","params":{}}
{"jsonrpc":"2.0","id":5,"method":"resources/list","params":{}}
```

```bash
PENSIEVE_DB=$(mktemp -u).sqlite bash -c 'cat /private/tmp/claude-501/-Users-moritz-Projects-pensieve/4f2deae3-c43f-49d0-bd2e-ad64547c640a/scratchpad/mcp-smoke.jsonl | swift run pensieve mcp'
```

Expected: response `id:4` lists the `pensieve://node/{id}` template; `id:5` lists the `whats-next` resource.

- [ ] **Step 5: Commit**

```bash
git add Sources/pensieve/Commands/Mcp.swift
git commit -m "feat(cli): pensieve mcp resources — pensieve://node/{id} + whats-next

User-attachable markdown resources over the existing scheme, same kernel.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 11: Roots auto-scoping + docs/wiring

Make `project_context` resolve the workspace via the client's `roots` capability when no `path`/`node_id` is given (Claude Code v2.1.203+), falling back to the process cwd. Then document the hook wiring (incl. the `compact` matcher) and update CLAUDE.md.

> **SDK API note:** `server.listRoots()` returns the client's roots (`file://` URIs). Pinned to `0.12.1`; match the resolved return-type shape.

**Files:**
- Modify: `Sources/pensieve/Commands/Mcp.swift`
- Modify: `CLAUDE.md`
- Modify: `docs/observability.md` (add a one-line pointer if a category is emitted; else skip)

**Interfaces:**
- Consumes: `Server.listRoots()`.
- Produces: roots-aware default path in the `project_context` handler.

- [ ] **Step 1: Resolve roots in the `project_context` handler**

In `Mcp.run()`, replace the `project_context` case body's path resolution so that when both `path` and `node_id` are absent, it queries roots. Change the `CallTool` `project_context` branch to:

```swift
      case "project_context":
        var path = params.arguments?["path"]?.stringValue
        let nodeID = (params.arguments?["node_id"]?.stringValue).flatMap { UUID(uuidString: $0) }
        if path == nil, nodeID == nil {
          // Zero-arg "reload wherever I am": ask the client for its workspace roots.
          if let roots = try? await server.listRoots(), let first = roots.first {
            path = URL(string: first.uri)?.path   // file:// → filesystem path
          }
        }
        let json = try await PensieveMCP.projectContextJSON(path: path, nodeID: nodeID)
        return PensieveMCP.result(json)
```

(`PensieveMCP.projectContextJSON` already falls back to the process cwd when `path` is nil, covering clients that advertise no roots.)

- [ ] **Step 2: Build**

Run: `swift build`
Expected: builds clean; adjust `listRoots()` / `Root.uri` names to the resolved SDK if needed.

- [ ] **Step 3: Re-run the full smoke to confirm no regression**

```bash
PENSIEVE_DB=$(mktemp -u).sqlite bash -c 'cat /private/tmp/claude-501/-Users-moritz-Projects-pensieve/4f2deae3-c43f-49d0-bd2e-ad64547c640a/scratchpad/mcp-smoke.jsonl | swift run pensieve mcp'
```

Expected: all five responses as before (the client sends no roots in the smoke, so `project_context` falls back to cwd — unchanged behavior here since we call `whats_next` in the smoke).

- [ ] **Step 4: Document the wiring in CLAUDE.md**

In `CLAUDE.md`, add a Status bullet after the cloud-provider bullet:

```markdown
- **MCP context server (`pensieve mcp` + `pensieve prime`) — DONE** (merged): Pensieve feeds its grounded context back into Claude Code across three surfaces over one tested Kit kernel (`SessionContextQueries`). **`pensieve mcp`** — official MCP Swift SDK (`0.12.1`, pensieve target only) stdio server: tools `project_context` (roots/cwd-scoped, `node_id` override) + `whats_next` (ranked, `context?` filter), and user-attachable resources `pensieve://node/{id}` + `pensieve://smartlist/whats-next` (`text/markdown`). **`pensieve prime`** — a SessionStart hook printing the cwd's compact bundle (cache-read-only prose: never narrates/spawns/blocks; nothing on an unbound cwd). New disposable `NarrationCache` (`narration-cache.sqlite`, keyed `NarrationCacheKey.make(events:provider:)`) shares prose across app/CLI/MCP; `mcp` write-through warms it, `prime` reads it. Trust gate intact (quotes cited, prose best-effort `nil`). Register: `claude mcp add pensieve -- pensieve mcp`; and a SessionStart hook running `pensieve prime` matched on `startup`/`resume`/`clear`/`compact`. Deferred: MCP prompts (fast-follow), sync-daemon ambient-prose warming. Spec/plan: `docs/superpowers/{specs,plans}/2026-07-0{8,-mcp}...`.
```

- [ ] **Step 5: Run the full test suite**

Run: `./scripts/test.sh`
Expected: PASS. All prior tests plus the new `NarrationCacheTests`, `SessionContextQueriesTests`, `ProjectContextRenderTests`.

- [ ] **Step 6: Commit**

```bash
git add Sources/pensieve/Commands/Mcp.swift CLAUDE.md
git commit -m "feat(cli): roots-based auto-scoping for project_context + docs

Zero-arg project_context resolves the client's workspace via roots/list
(cwd fallback). Documents the MCP + prime wiring in CLAUDE.md.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Human-verify carries (need the built CLI + a real store + Claude Code)

These require the release CLI and a live Claude Code session; run them after merge:

- **Rebuild + reinstall the release CLI** (`~/.local/bin/pensieve`) — the binary gains `prime` + `mcp`.
- **MCP tools:** `claude mcp add pensieve -- pensieve mcp`, then in a session confirm `project_context` and `whats_next` are callable and return grounded bundles; confirm zero-arg `project_context` scopes to the current repo via roots (Claude Code v2.1.203+), and cwd fallback on older clients.
- **MCP resources:** confirm `@pensieve:pensieve://node/<id>` autocompletes + attaches a node's markdown context, and the static `whats-next` resource attaches and renders.
- **`prime` hook:** register a SessionStart hook running `pensieve prime` (matchers `startup`, `resume`, `clear`, `compact`); confirm ambient context appears at session start and after a compaction, and that session start is not visibly slowed (facts + cited loose ends immediate; prose appears only once the node was pulled via `project_context` or opened in the app).
- **On-device FM path** is taken (not `claude -p`) on this machine; the narration cache invalidates after a new commit/session (new event set → new key → re-narrate).
- **Bundled-dep sanity:** confirm the MCP SDK did not leak into the app build — `xcodebuild ... build` still succeeds and PensieveKit gained no new dependency.

---

## Self-Review

**Spec coverage:**
- Component 1 `SessionContextQueries` (bundle + ranked + path→node) → Tasks 4, 5, 6. ✓
- Component 2a tools (`project_context`, `whats_next`, roots, maxResultSizeChars, cache-first→bounded→nil prose) → Tasks 5, 9, 11. ✓
- Component 2b resources (`pensieve://node/{id}` template + static) → Task 10. ✓
- Component 3 `prime` (read-only, never spawns, compact render, compact-matcher) → Tasks 7, 8, 11. ✓
- Component 4 `NarrationCache` (standalone, `NarrationCacheKey`, corrupt-tolerant) → Tasks 2, 3. ✓
- Read-only opener; SDK scoped to executable target; git-common-dir resolution → Tasks 8, 9, 4. ✓
- Testing (kernel, cache, render, mcp/prime smoke) → per-task tests + smoke steps. ✓
- Non-goals (no sampling/elicitation/subscriptions/prompts-v1) → honored (prompts noted as fast-follow, nothing implements them). ✓

**Deferred, correctly not in this plan:** sync-daemon ambient-prose warming; MCP prompts + completion; blended weighting.

**Placeholder scan:** no TBD/TODO; every code step shows full code; the only "adjust to compiler" instructions are third-party MCP-SDK initializer-label reconciliation (Tasks 9–11), explicitly bounded and with the Kit contract fixed.

**Type consistency:** `ProjectContextBundle`/`WhatsNextItem`/`BundleLooseEnd`/`BundleEvent` fields defined in Task 4 are used unchanged in Tasks 5, 7, 9, 10; `SessionContextQueries.nodeID/bundle/rankedContext` and `SessionContextRender.markdown/compact` signatures match across producer and consumer tasks; `NarrationCache.get/put` and `narrationCacheURL()` consistent across Tasks 2, 3, 5, 8, 9, 10.
