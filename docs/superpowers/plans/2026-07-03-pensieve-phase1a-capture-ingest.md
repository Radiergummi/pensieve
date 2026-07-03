# Pensieve Phase 1A — Capture & Ingest Pipeline — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the headless data pipeline that turns git commits and Claude Code sessions into project-attributed events in a local SQLite store, driven by a `pensieve` CLI and git hooks.

**Architecture:** One SwiftPM package. A `PensieveKit` library holds the model, the two SQLite stores (a dumb append-only **capture spool** and the rich **canonical store**), the transcript parser, and the ingester that drains the spool into the canonical store. A thin `pensieve` executable exposes CLI subcommands; git hooks call the capture subcommands fire-and-forget. No AI in this plan — the `looseEnds` table is created but populated in Plan 1B.

**Tech Stack:** Swift 6, SQLiteData (GRDB-backed), swift-argument-parser, Swift Testing (`import Testing`).

## Global Constraints

- **Toolchain:** `swift-tools-version: 6.0`; platform floor `.macOS(.v14)`. This machine is **Command Line Tools only (no Xcode.app)**, so run the test suite with **`./scripts/test.sh`** (a committed wrapper that puts the Swift Testing framework on the search path/rpath) — plain `swift test` fails to load `Testing.framework` here. `swift build` and `swift run` work normally.
- **Persistence:** SQLiteData `from: "1.6.0"` (built on GRDB). Canonical store uses a GRDB `DatabasePool` (WAL, multi-process). **UUID primary keys** on every canonical table (keeps CloudKit sync reachable later). Tables are `STRICT`. **CREATE TABLE column names must exactly match the Swift `@Table` property names** (no snake_casing).
- **Two databases:** `capture.sqlite` — dumb, append-only, local, **never synced**; `pensieve.sqlite` — canonical, rich, the only store that will ever sync.
- **Capture path is sacred:** must be fast and independent of any running process. Git hooks use **only `post-commit` / `post-checkout`** (which run after the ref moves, off the commit critical path), run the CLI backgrounded (`&`) with errors swallowed, so a missing/failing `pensieve` can never break a commit. The capture subcommands do the minimum: append one row to the spool and exit. All git enrichment happens later, in the ingester.
- **Language:** Swift only. No Python, ever.
- **Model principle:** a Project is an area of work, **not** a directory. Attribution is by filesystem path → source → project. Many sources may bind to one project; `group` merges projects.
- **DB locations:** `~/Library/Application Support/Pensieve/pensieve.sqlite` and `.../capture.sqlite`.

---

### Task 1: Package scaffold + canonical-store foundation

Pins the exact SQLiteData API end-to-end with a real round-tripping test before anything is built on it.

**Files:**
- Create: `Package.swift`
- Create: `Sources/PensieveKit/Support/PensievePaths.swift`
- Create: `Sources/PensieveKit/Model/Project.swift`
- Create: `Sources/PensieveKit/Store/CanonicalStore.swift`
- Test: `Tests/PensieveKitTests/CanonicalStoreTests.swift`

**Interfaces:**
- Produces: `enum PensievePaths { static func canonicalURL() -> URL; static func captureURL() -> URL; static func supportDirectory() -> URL }`
- Produces: `@Table struct Project { let id: UUID; var name: String; var state: String; var createdAt: Date }`
- Produces: `func openCanonicalDatabase(at url: URL) throws -> any DatabaseWriter`

- [ ] **Step 1: Write `Package.swift`**

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "Pensieve",
  platforms: [.macOS(.v14)],
  products: [
    .library(name: "PensieveKit", targets: ["PensieveKit"]),
    .executable(name: "pensieve", targets: ["pensieve"]),
  ],
  dependencies: [
    .package(url: "https://github.com/pointfreeco/sqlite-data", from: "1.6.0"),
    .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"),
  ],
  targets: [
    .target(
      name: "PensieveKit",
      dependencies: [.product(name: "SQLiteData", package: "sqlite-data")]
    ),
    .executableTarget(
      name: "pensieve",
      dependencies: [
        "PensieveKit",
        .product(name: "ArgumentParser", package: "swift-argument-parser"),
      ]
    ),
    .testTarget(name: "PensieveKitTests", dependencies: ["PensieveKit"]),
  ]
)
```

- [ ] **Step 2: Write `PensievePaths.swift`**

```swift
import Foundation

public enum PensievePaths {
  public static func supportDirectory() -> URL {
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    return base.appendingPathComponent("Pensieve", isDirectory: true)
  }
  public static func canonicalURL() -> URL {
    supportDirectory().appendingPathComponent("pensieve.sqlite")
  }
  public static func captureURL() -> URL {
    supportDirectory().appendingPathComponent("capture.sqlite")
  }
}
```

- [ ] **Step 3: Write `Project.swift`**

```swift
import Foundation
import SQLiteData

@Table
public struct Project: Identifiable, Equatable, Sendable {
  public let id: UUID
  public var name: String
  public var state: String        // "active" | "archived" | "muted"
  public var createdAt: Date

  public init(id: UUID = UUID(), name: String, state: String = "active", createdAt: Date = Date()) {
    self.id = id; self.name = name; self.state = state; self.createdAt = createdAt
  }
}
```

- [ ] **Step 4: Write `CanonicalStore.swift`** (only the Project table for now)

```swift
import Foundation
import SQLiteData   // re-exports GRDB symbols (DatabasePool, Configuration, DatabaseMigrator, #sql).
                    // If a symbol is missing at compile time, add `import GRDB`.

public func openCanonicalDatabase(at url: URL) throws -> any DatabaseWriter {
  try FileManager.default.createDirectory(
    at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
  let configuration = Configuration()
  let db = try DatabasePool(path: url.path, configuration: configuration)  // WAL, multi-process
  try migrateCanonical(db)
  return db
}

func migrateCanonical(_ db: any DatabaseWriter) throws {
  var migrator = DatabaseMigrator()
  migrator.registerMigration("v1-projects") { db in
    try #sql("""
      CREATE TABLE "projects"(
        "id" TEXT NOT NULL PRIMARY KEY,
        "name" TEXT NOT NULL,
        "state" TEXT NOT NULL DEFAULT 'active',
        "createdAt" TEXT NOT NULL
      ) STRICT
      """).execute(db)
  }
  try migrator.migrate(db)
}
```

- [ ] **Step 5: Write the failing test**

```swift
import Foundation
import Testing
import SQLiteData
@testable import PensieveKit

@Test func projectRoundTrips() throws {
  let url = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("pensieve-test-\(UUID().uuidString).sqlite")
  let db = try openCanonicalDatabase(at: url)

  let p = Project(name: "Cetacean")
  try db.write { db in try Project.insert { p }.execute(db) }

  let fetched = try db.read { db in try Project.all.fetchAll(db) }
  #expect(fetched.count == 1)
  #expect(fetched.first?.name == "Cetacean")
}
```

- [ ] **Step 6: Run test to verify it fails**

Run: `./scripts/test.sh --filter projectRoundTrips`
Expected: FAIL (package doesn't build yet / no such symbol) on first run before code is complete.

- [ ] **Step 7: Make it pass**

Resolve dependencies and build: `swift build`. If the `Date` column errors at the macro layer, annotate the property with `@Column(as: Date.ISO8601Representation.self)` and keep the column `TEXT` — the round-trip test is the arbiter. If a GRDB symbol is unresolved, add `import GRDB` to `CanonicalStore.swift`.

Run: `./scripts/test.sh --filter projectRoundTrips`
Expected: PASS

- [ ] **Step 8: Commit**

```bash
git add Package.swift Sources/PensieveKit/Support/PensievePaths.swift \
  Sources/PensieveKit/Model/Project.swift Sources/PensieveKit/Store/CanonicalStore.swift \
  Tests/PensieveKitTests/CanonicalStoreTests.swift
git commit -m "feat: package scaffold + canonical store with Project table"
```

---

### Task 2: Remaining canonical tables

**Files:**
- Create: `Sources/PensieveKit/Model/Source.swift`
- Create: `Sources/PensieveKit/Model/Event.swift`
- Create: `Sources/PensieveKit/Model/LooseEnd.swift`
- Create: `Sources/PensieveKit/Model/Checkpoint.swift`
- Modify: `Sources/PensieveKit/Store/CanonicalStore.swift` (add tables to migration)
- Test: `Tests/PensieveKitTests/SchemaTests.swift`

**Interfaces:**
- Produces: `@Table struct Source { let id: UUID; var projectID: UUID; var kind: String; var key: String; var createdAt: Date }` — `kind` is `"gitRepo" | "claudeCode"`, `key` is the absolute directory/repo path.
- Produces: `@Table struct Event { let id: UUID; var projectID: UUID; var sourceID: UUID; var occurredAt: Date; var kind: String; var summary: String; var detailJSON: String; var createdAt: Date }`
- Produces: `@Table struct LooseEnd { let id: UUID; var projectID: UUID; var sourceEventID: UUID; var text: String; var quote: String; var status: String; var createdAt: Date }` — populated in Plan 1B.
- Produces: `@Table struct Checkpoint { let id: UUID; var projectID: UUID; var note: String; var createdAt: Date }`

- [ ] **Step 1: Write the failing test**

```swift
import Foundation
import Testing
import SQLiteData
@testable import PensieveKit

@Test func allTablesRoundTrip() throws {
  let url = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("pensieve-schema-\(UUID().uuidString).sqlite")
  let db = try openCanonicalDatabase(at: url)

  let project = Project(name: "Colibri")
  let source = Source(projectID: project.id, kind: "gitRepo", key: "/Users/moritz/Projects/colibri")
  let event = Event(projectID: project.id, sourceID: source.id, occurredAt: Date(),
                    kind: "git.commit", summary: "init", detailJSON: "{}")
  try db.write { db in
    try Project.insert { project }.execute(db)
    try Source.insert { source }.execute(db)
    try Event.insert { event }.execute(db)
  }
  let events = try db.read { db in try Event.all.fetchAll(db) }
  #expect(events.first?.summary == "init")
  #expect(events.first?.projectID == project.id)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `./scripts/test.sh --filter allTablesRoundTrip`
Expected: FAIL — `Source`/`Event` types not defined.

- [ ] **Step 3: Write the four model files**

```swift
// Source.swift
import Foundation
import SQLiteData

@Table
public struct Source: Identifiable, Equatable, Sendable {
  public let id: UUID
  public var projectID: UUID
  public var kind: String        // "gitRepo" | "claudeCode"
  public var key: String         // absolute directory/repo path
  public var createdAt: Date
  public init(id: UUID = UUID(), projectID: UUID, kind: String, key: String, createdAt: Date = Date()) {
    self.id = id; self.projectID = projectID; self.kind = kind; self.key = key; self.createdAt = createdAt
  }
}
```

```swift
// Event.swift
import Foundation
import SQLiteData

@Table
public struct Event: Identifiable, Equatable, Sendable {
  public let id: UUID
  public var projectID: UUID
  public var sourceID: UUID
  public var occurredAt: Date
  public var kind: String        // "git.commit" | "git.checkout" | "cc.session"
  public var summary: String     // short human-readable line
  public var detailJSON: String  // enriched payload as JSON
  public var createdAt: Date
  public init(id: UUID = UUID(), projectID: UUID, sourceID: UUID, occurredAt: Date,
              kind: String, summary: String, detailJSON: String, createdAt: Date = Date()) {
    self.id = id; self.projectID = projectID; self.sourceID = sourceID; self.occurredAt = occurredAt
    self.kind = kind; self.summary = summary; self.detailJSON = detailJSON; self.createdAt = createdAt
  }
}
```

```swift
// LooseEnd.swift  (created now; populated in Plan 1B)
import Foundation
import SQLiteData

@Table
public struct LooseEnd: Identifiable, Equatable, Sendable {
  public let id: UUID
  public var projectID: UUID
  public var sourceEventID: UUID
  public var text: String        // the open item
  public var quote: String       // verbatim provenance from captured text
  public var status: String      // "open" | "resolved"
  public var createdAt: Date
  public init(id: UUID = UUID(), projectID: UUID, sourceEventID: UUID, text: String,
              quote: String, status: String = "open", createdAt: Date = Date()) {
    self.id = id; self.projectID = projectID; self.sourceEventID = sourceEventID
    self.text = text; self.quote = quote; self.status = status; self.createdAt = createdAt
  }
}
```

```swift
// Checkpoint.swift
import Foundation
import SQLiteData

@Table
public struct Checkpoint: Identifiable, Equatable, Sendable {
  public let id: UUID
  public var projectID: UUID
  public var note: String
  public var createdAt: Date
  public init(id: UUID = UUID(), projectID: UUID, note: String, createdAt: Date = Date()) {
    self.id = id; self.projectID = projectID; self.note = note; self.createdAt = createdAt
  }
}
```

- [ ] **Step 4: Extend the migration in `CanonicalStore.swift`**

Add inside `migrateCanonical`, after the `v1-projects` migration:

```swift
  migrator.registerMigration("v2-sources-events-looseends-checkpoints") { db in
    try #sql("""
      CREATE TABLE "sources"(
        "id" TEXT NOT NULL PRIMARY KEY,
        "projectID" TEXT NOT NULL REFERENCES "projects"("id") ON DELETE CASCADE,
        "kind" TEXT NOT NULL,
        "key" TEXT NOT NULL,
        "createdAt" TEXT NOT NULL
      ) STRICT
      """).execute(db)
    try #sql("""
      CREATE TABLE "events"(
        "id" TEXT NOT NULL PRIMARY KEY,
        "projectID" TEXT NOT NULL REFERENCES "projects"("id") ON DELETE CASCADE,
        "sourceID" TEXT NOT NULL REFERENCES "sources"("id") ON DELETE CASCADE,
        "occurredAt" TEXT NOT NULL,
        "kind" TEXT NOT NULL,
        "summary" TEXT NOT NULL,
        "detailJSON" TEXT NOT NULL,
        "createdAt" TEXT NOT NULL
      ) STRICT
      """).execute(db)
    try #sql("""
      CREATE TABLE "looseEnds"(
        "id" TEXT NOT NULL PRIMARY KEY,
        "projectID" TEXT NOT NULL REFERENCES "projects"("id") ON DELETE CASCADE,
        "sourceEventID" TEXT NOT NULL REFERENCES "events"("id") ON DELETE CASCADE,
        "text" TEXT NOT NULL,
        "quote" TEXT NOT NULL,
        "status" TEXT NOT NULL DEFAULT 'open',
        "createdAt" TEXT NOT NULL
      ) STRICT
      """).execute(db)
    try #sql("""
      CREATE TABLE "checkpoints"(
        "id" TEXT NOT NULL PRIMARY KEY,
        "projectID" TEXT NOT NULL REFERENCES "projects"("id") ON DELETE CASCADE,
        "note" TEXT NOT NULL,
        "createdAt" TEXT NOT NULL
      ) STRICT
      """).execute(db)
    try #sql(#"CREATE INDEX "idx_events_project" ON "events"("projectID", "occurredAt")"#).execute(db)
    try #sql(#"CREATE UNIQUE INDEX "idx_sources_key_kind" ON "sources"("key", "kind")"#).execute(db)
  }
```

- [ ] **Step 5: Run test to verify it passes**

Run: `./scripts/test.sh --filter allTablesRoundTrip`
Expected: PASS

- [ ] **Step 6: Commit**

```bash
git add Sources/PensieveKit/Model Sources/PensieveKit/Store/CanonicalStore.swift \
  Tests/PensieveKitTests/SchemaTests.swift
git commit -m "feat: add sources, events, looseEnds, checkpoints tables"
```

---

### Task 3: Capture spool

A separate, dumb, append-only SQLite database — deliberately not a `@Table`/canonical concern.

**Files:**
- Create: `Sources/PensieveKit/Store/CaptureSpool.swift`
- Test: `Tests/PensieveKitTests/CaptureSpoolTests.swift`

**Interfaces:**
- Produces: `struct SpoolRow { let id: Int64; let ts: Date; let kind: String; let payload: String }`
- Produces: `final class CaptureSpool { init(at url: URL) throws; func append(kind: String, payload: String, at: Date = Date()) throws; func pending() throws -> [SpoolRow]; func markIngested(_ ids: [Int64]) throws }`

- [ ] **Step 1: Write the failing test**

```swift
import Foundation
import Testing
@testable import PensieveKit

@Test func spoolAppendsAndDrains() throws {
  let url = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("capture-\(UUID().uuidString).sqlite")
  let spool = try CaptureSpool(at: url)

  try spool.append(kind: "git.commit", payload: #"{"hash":"abc"}"#)
  try spool.append(kind: "cc.session", payload: #"{"path":"/x.jsonl"}"#)

  var pending = try spool.pending()
  #expect(pending.count == 2)

  try spool.markIngested([pending[0].id])
  pending = try spool.pending()
  #expect(pending.count == 1)
  #expect(pending.first?.kind == "cc.session")
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `./scripts/test.sh --filter spoolAppendsAndDrains`
Expected: FAIL — `CaptureSpool` not defined.

- [ ] **Step 3: Implement `CaptureSpool.swift`**

```swift
import Foundation
import SQLiteData   // for GRDB's DatabaseQueue / Row APIs

public struct SpoolRow: Sendable {
  public let id: Int64
  public let ts: Date
  public let kind: String
  public let payload: String
}

public final class CaptureSpool {
  private let dbQueue: DatabaseQueue
  private static let iso = ISO8601DateFormatter()

  public init(at url: URL) throws {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    self.dbQueue = try DatabaseQueue(path: url.path)
    try dbQueue.write { db in
      try db.execute(sql: """
        CREATE TABLE IF NOT EXISTS captures(
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          ts TEXT NOT NULL,
          kind TEXT NOT NULL,
          payload TEXT NOT NULL,
          ingested INTEGER NOT NULL DEFAULT 0
        )
        """)
    }
  }

  public func append(kind: String, payload: String, at: Date = Date()) throws {
    try dbQueue.write { db in
      try db.execute(
        sql: "INSERT INTO captures(ts, kind, payload) VALUES(?, ?, ?)",
        arguments: [Self.iso.string(from: at), kind, payload])
    }
  }

  public func pending() throws -> [SpoolRow] {
    try dbQueue.read { db in
      try Row.fetchAll(db, sql: "SELECT id, ts, kind, payload FROM captures WHERE ingested = 0 ORDER BY id")
        .map { row in
          SpoolRow(
            id: row["id"],
            ts: Self.iso.date(from: row["ts"]) ?? Date(),
            kind: row["kind"],
            payload: row["payload"])
        }
    }
  }

  public func markIngested(_ ids: [Int64]) throws {
    guard !ids.isEmpty else { return }
    try dbQueue.write { db in
      let placeholders = ids.map { _ in "?" }.joined(separator: ",")
      try db.execute(
        sql: "UPDATE captures SET ingested = 1 WHERE id IN (\(placeholders))",
        arguments: StatementArguments(ids))
    }
  }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `./scripts/test.sh --filter spoolAppendsAndDrains`
Expected: PASS. If `Row`/`DatabaseQueue`/`StatementArguments` are unresolved, add `import GRDB`.

- [ ] **Step 5: Commit**

```bash
git add Sources/PensieveKit/Store/CaptureSpool.swift Tests/PensieveKitTests/CaptureSpoolTests.swift
git commit -m "feat: append-only capture spool"
```

---

### Task 4: Capture payloads + capture CLI subcommands

**Files:**
- Create: `Sources/PensieveKit/Capture/CapturePayloads.swift`
- Create: `Sources/pensieve/Pensieve.swift` (ArgumentParser root)
- Create: `Sources/pensieve/Commands/CaptureCommit.swift`
- Create: `Sources/pensieve/Commands/CaptureCheckout.swift`
- **Delete: `Sources/pensieve/main.swift`** (a placeholder stub added in Task 1 so the empty executable target would build). The `@main struct Pensieve` introduced in this task **cannot coexist with a top-level `main.swift`** — Swift errors with "'main' attribute cannot be used in a module that contains top-level code". Delete the stub as part of this task.
- Test: `Tests/PensieveKitTests/CapturePayloadTests.swift`

**Interfaces:**
- Consumes: `CaptureSpool` (Task 3).
- Produces: `struct GitCommitPayload: Codable { var repoPath: String; var hash: String; var branch: String }`
- Produces: `struct GitCheckoutPayload: Codable { var repoPath: String; var from: String; var to: String; var branch: String }`
- Produces: `struct SessionRefPayload: Codable { var transcriptPath: String }`
- Produces: `enum CaptureKind { static let gitCommit = "git.commit"; static let gitCheckout = "git.checkout"; static let ccSession = "cc.session" }`
- Produces: `func encodeJSON<T: Encodable>(_ v: T) throws -> String`

- [ ] **Step 1: Write the failing test**

```swift
import Foundation
import Testing
@testable import PensieveKit

@Test func gitCommitPayloadEncodesToSpool() throws {
  let url = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("capture-\(UUID().uuidString).sqlite")
  let spool = try CaptureSpool(at: url)

  let payload = GitCommitPayload(repoPath: "/Users/moritz/Projects/colibri", hash: "abc123", branch: "main")
  try spool.append(kind: CaptureKind.gitCommit, payload: try encodeJSON(payload))

  let rows = try spool.pending()
  #expect(rows.first?.kind == CaptureKind.gitCommit)
  let decoded = try JSONDecoder().decode(GitCommitPayload.self, from: Data(rows[0].payload.utf8))
  #expect(decoded.hash == "abc123")
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `./scripts/test.sh --filter gitCommitPayloadEncodesToSpool`
Expected: FAIL — payload types not defined.

- [ ] **Step 3: Implement `CapturePayloads.swift`**

```swift
import Foundation

public enum CaptureKind {
  public static let gitCommit = "git.commit"
  public static let gitCheckout = "git.checkout"
  public static let ccSession = "cc.session"
}

public struct GitCommitPayload: Codable, Sendable {
  public var repoPath: String; public var hash: String; public var branch: String
  public init(repoPath: String, hash: String, branch: String) {
    self.repoPath = repoPath; self.hash = hash; self.branch = branch
  }
}

public struct GitCheckoutPayload: Codable, Sendable {
  public var repoPath: String; public var from: String; public var to: String; public var branch: String
  public init(repoPath: String, from: String, to: String, branch: String) {
    self.repoPath = repoPath; self.from = from; self.to = to; self.branch = branch
  }
}

public struct SessionRefPayload: Codable, Sendable {
  public var transcriptPath: String
  public init(transcriptPath: String) { self.transcriptPath = transcriptPath }
}

public func encodeJSON<T: Encodable>(_ v: T) throws -> String {
  let data = try JSONEncoder().encode(v)
  return String(decoding: data, as: UTF8.self)
}
```

- [ ] **Step 4: Implement the CLI root and two capture commands**

```swift
// Sources/pensieve/Pensieve.swift
import ArgumentParser
import Foundation
import PensieveKit

@main
struct Pensieve: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "pensieve",
    abstract: "Track work across parallel projects.",
    subcommands: [CaptureCommit.self, CaptureCheckout.self]
  )
}

/// Opens the spool at the standard location (override for tests via PENSIEVE_CAPTURE_DB).
func openSpool() throws -> CaptureSpool {
  if let override = ProcessInfo.processInfo.environment["PENSIEVE_CAPTURE_DB"] {
    return try CaptureSpool(at: URL(fileURLWithPath: override))
  }
  return try CaptureSpool(at: PensievePaths.captureURL())
}
```

```swift
// Sources/pensieve/Commands/CaptureCommit.swift
import ArgumentParser
import PensieveKit

struct CaptureCommit: ParsableCommand {
  static let configuration = CommandConfiguration(commandName: "capture-commit")
  @Option var repo: String
  @Option var hash: String
  @Option var branch: String

  func run() throws {
    let payload = GitCommitPayload(repoPath: repo, hash: hash, branch: branch)
    try openSpool().append(kind: CaptureKind.gitCommit, payload: try encodeJSON(payload))
  }
}
```

```swift
// Sources/pensieve/Commands/CaptureCheckout.swift
import ArgumentParser
import PensieveKit

struct CaptureCheckout: ParsableCommand {
  static let configuration = CommandConfiguration(commandName: "capture-checkout")
  @Option var repo: String
  @Option var from: String
  @Option var to: String
  @Option var branch: String

  func run() throws {
    let payload = GitCheckoutPayload(repoPath: repo, from: from, to: to, branch: branch)
    try openSpool().append(kind: CaptureKind.gitCheckout, payload: try encodeJSON(payload))
  }
}
```

- [ ] **Step 5: Run test + smoke-test the CLI**

Run: `./scripts/test.sh --filter gitCommitPayloadEncodesToSpool`
Expected: PASS

Run: `PENSIEVE_CAPTURE_DB=/tmp/smoke.sqlite swift run pensieve capture-commit --repo /tmp/r --hash abc --branch main`
Expected: exits 0, no output.

- [ ] **Step 6: Commit**

```bash
git add Sources/PensieveKit/Capture Sources/pensieve Tests/PensieveKitTests/CapturePayloadTests.swift
git commit -m "feat: capture payloads and capture-commit/checkout CLI"
```

---

### Task 5: Claude Code transcript parser

Extracts the facts Plan 1B needs from a session `.jsonl`, defensively (skip unparseable lines, never throw on a bad record).

**Files:**
- Create: `Sources/PensieveKit/Transcript/ParsedSession.swift`
- Create: `Sources/PensieveKit/Transcript/TranscriptParser.swift`
- Test: `Tests/PensieveKitTests/TranscriptParserTests.swift`
- Test fixture: `Tests/PensieveKitTests/Fixtures/session.jsonl`

**Interfaces:**
- Produces: `struct ParsedSession { let sessionID: String; let cwd: String?; let startedAt: Date?; let endedAt: Date?; let userPromptCount: Int; let messages: [TranscriptMessage] }`
- Produces: `struct TranscriptMessage { let role: String; let text: String; let timestamp: Date? }`
- Produces: `enum TranscriptParser { static func parse(fileURL: URL) -> ParsedSession }`

- [ ] **Step 1: Create the fixture** `Tests/PensieveKitTests/Fixtures/session.jsonl`

```
{"type":"user","cwd":"/Users/moritz/Projects/colibri","timestamp":"2026-06-30T10:00:00Z","message":{"role":"user","content":"Add rate limiting and also set the CI deploy vars"}}
{"type":"assistant","timestamp":"2026-06-30T10:01:00Z","message":{"role":"assistant","content":[{"type":"text","text":"I'll add the limiter now."}]}}
{"garbage that is not json}
{"type":"user","cwd":"/Users/moritz/Projects/colibri","timestamp":"2026-06-30T10:05:00Z","message":{"role":"user","content":"looks good"}}
```

- [ ] **Step 2: Write the failing test**

```swift
import Foundation
import Testing
@testable import PensieveKit

@Test func parsesSessionDefensively() throws {
  let url = Bundle.module.url(forResource: "session", withExtension: "jsonl", subdirectory: "Fixtures")!
  let s = TranscriptParser.parse(fileURL: url)

  #expect(s.cwd == "/Users/moritz/Projects/colibri")
  #expect(s.userPromptCount == 2)                       // bad line skipped, not counted
  #expect(s.messages.contains { $0.text.contains("rate limiting") })
  #expect(s.startedAt != nil && s.endedAt != nil)
}
```

Add resource handling to the test target in `Package.swift`:

```swift
    .testTarget(
      name: "PensieveKitTests",
      dependencies: ["PensieveKit"],
      resources: [.copy("Fixtures")]
    ),
```

- [ ] **Step 3: Run test to verify it fails**

Run: `./scripts/test.sh --filter parsesSessionDefensively`
Expected: FAIL — `TranscriptParser` not defined.

- [ ] **Step 4: Implement `ParsedSession.swift` and `TranscriptParser.swift`**

```swift
// ParsedSession.swift
import Foundation

public struct TranscriptMessage: Sendable {
  public let role: String
  public let text: String
  public let timestamp: Date?
}

public struct ParsedSession: Sendable {
  public let sessionID: String
  public let cwd: String?
  public let startedAt: Date?
  public let endedAt: Date?
  public let userPromptCount: Int
  public let messages: [TranscriptMessage]
}
```

```swift
// TranscriptParser.swift
import Foundation

public enum TranscriptParser {
  private static let iso = ISO8601DateFormatter()

  public static func parse(fileURL: URL) -> ParsedSession {
    let sessionID = fileURL.deletingPathExtension().lastPathComponent
    guard let content = try? String(contentsOf: fileURL, encoding: .utf8) else {
      return ParsedSession(sessionID: sessionID, cwd: nil, startedAt: nil, endedAt: nil,
                           userPromptCount: 0, messages: [])
    }

    var cwd: String?
    var messages: [TranscriptMessage] = []
    var timestamps: [Date] = []
    var userPrompts = 0

    for line in content.split(separator: "\n", omittingEmptySubsequences: true) {
      guard let data = line.data(using: .utf8),
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
      else { continue }   // defensive: skip garbage lines

      if cwd == nil, let c = obj["cwd"] as? String { cwd = c }
      if let ts = obj["timestamp"] as? String, let d = iso.date(from: ts) { timestamps.append(d) }

      let type = obj["type"] as? String
      let message = obj["message"] as? [String: Any]
      let role = (message?["role"] as? String) ?? (type ?? "unknown")
      let text = extractText(message?["content"])
      if type == "user" { userPrompts += 1 }
      if !text.isEmpty {
        messages.append(TranscriptMessage(role: role, text: text,
                                          timestamp: (obj["timestamp"] as? String).flatMap(iso.date(from:))))
      }
    }

    return ParsedSession(
      sessionID: sessionID, cwd: cwd,
      startedAt: timestamps.min(), endedAt: timestamps.max(),
      userPromptCount: userPrompts, messages: messages)
  }

  /// `content` is either a String or an array of content blocks (`{type:text,text:...}`).
  private static func extractText(_ content: Any?) -> String {
    if let s = content as? String { return s }
    if let blocks = content as? [[String: Any]] {
      return blocks.compactMap { $0["text"] as? String }.joined(separator: "\n")
    }
    return ""
  }
}
```

- [ ] **Step 5: Run test to verify it passes**

Run: `./scripts/test.sh --filter parsesSessionDefensively`
Expected: PASS

- [ ] **Step 6: Commit**

```bash
git add Sources/PensieveKit/Transcript Tests/PensieveKitTests/TranscriptParserTests.swift \
  Tests/PensieveKitTests/Fixtures Package.swift
git commit -m "feat: defensive Claude Code transcript parser"
```

---

### Task 6: Project resolver (path → project/source, auto-create, group)

**Files:**
- Create: `Sources/PensieveKit/Ingest/ProjectResolver.swift`
- Test: `Tests/PensieveKitTests/ProjectResolverTests.swift`

**Interfaces:**
- Consumes: `Project`, `Source`, `Event` tables; `any DatabaseWriter`.
- Produces: `struct ProjectResolver { init(db: any DatabaseWriter); func resolve(path: String, kind: String) throws -> (project: Project, source: Source); func group(_ primaryID: UUID, into merged: [UUID]) throws }`
  - `resolve`: finds the `Source` with matching `(key: path, kind)`; if none, finds any project already bound to that path (any kind) and adds a source of `kind`; else creates a new project (name = last path component) plus the source. Returns the project and the source of the requested kind.
  - `group`: repoints all sources and events of `merged` projects to `primaryID`, then deletes the merged projects.

- [ ] **Step 1: Write the failing test**

```swift
import Foundation
import Testing
import SQLiteData
@testable import PensieveKit

@Test func resolverAutoCreatesAndReuses() throws {
  let url = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("resolver-\(UUID().uuidString).sqlite")
  let db = try openCanonicalDatabase(at: url)
  let resolver = ProjectResolver(db: db)

  let a = try resolver.resolve(path: "/Users/moritz/Projects/colibri", kind: "gitRepo")
  #expect(a.project.name == "colibri")

  // Same path, different source kind → same project, new source.
  let b = try resolver.resolve(path: "/Users/moritz/Projects/colibri", kind: "claudeCode")
  #expect(b.project.id == a.project.id)
  #expect(b.source.id != a.source.id)

  let projects = try db.read { db in try Project.all.fetchAll(db) }
  #expect(projects.count == 1)
}

@Test func groupMergesProjects() throws {
  let url = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("group-\(UUID().uuidString).sqlite")
  let db = try openCanonicalDatabase(at: url)
  let resolver = ProjectResolver(db: db)

  let front = try resolver.resolve(path: "/p/app-frontend", kind: "gitRepo")
  let back = try resolver.resolve(path: "/p/app-backend", kind: "gitRepo")
  try resolver.group(front.project.id, into: [back.project.id])

  let projects = try db.read { db in try Project.all.fetchAll(db) }
  #expect(projects.count == 1)
  let sources = try db.read { db in try Source.all.fetchAll(db) }
  #expect(sources.allSatisfy { $0.projectID == front.project.id })
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `./scripts/test.sh --filter resolver`
Expected: FAIL — `ProjectResolver` not defined.

- [ ] **Step 3: Implement `ProjectResolver.swift`**

```swift
import Foundation
import SQLiteData

public struct ProjectResolver {
  let db: any DatabaseWriter
  public init(db: any DatabaseWriter) { self.db = db }

  public func resolve(path: String, kind: String) throws -> (project: Project, source: Source) {
    try db.write { db in
      // 1. Exact source (path, kind) already exists?
      if let source = try Source.where({ $0.key == path && $0.kind == kind }).fetchOne(db),
         let project = try Project.where({ $0.id == source.projectID }).fetchOne(db) {
        return (project, source)
      }
      // 2. A project already bound to this path via another source kind?
      if let sibling = try Source.where({ $0.key == path }).fetchOne(db),
         let project = try Project.where({ $0.id == sibling.projectID }).fetchOne(db) {
        let source = Source(projectID: project.id, kind: kind, key: path)
        try Source.insert { source }.execute(db)
        return (project, source)
      }
      // 3. Brand-new project + source.
      let project = Project(name: (path as NSString).lastPathComponent)
      let source = Source(projectID: project.id, kind: kind, key: path)
      try Project.insert { project }.execute(db)
      try Source.insert { source }.execute(db)
      return (project, source)
    }
  }

  public func group(_ primaryID: UUID, into merged: [UUID]) throws {
    try db.write { db in
      for other in merged where other != primaryID {
        try Source.where { $0.projectID == other }
          .update { $0.projectID = primaryID }.execute(db)
        try Event.where { $0.projectID == other }
          .update { $0.projectID = primaryID }.execute(db)
        try Project.where { $0.id == other }.delete().execute(db)
      }
    }
  }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `./scripts/test.sh --filter resolver`
Expected: PASS. If StructuredQueries' `where`/`update`/`delete` builder names differ at compile time, consult the generated `Source`/`Project` query API (the macro exposes `.where`, `.update`, `.delete`, `.fetchOne`, `.fetchAll`); adjust closure syntax to match, keeping behavior identical.

- [ ] **Step 5: Commit**

```bash
git add Sources/PensieveKit/Ingest/ProjectResolver.swift Tests/PensieveKitTests/ProjectResolverTests.swift
git commit -m "feat: project resolver with auto-create and grouping"
```

---

### Task 7: Ingester (drain spool → enriched events)

**Files:**
- Create: `Sources/PensieveKit/Support/Git.swift`
- Create: `Sources/PensieveKit/Ingest/Ingester.swift`
- Test: `Tests/PensieveKitTests/IngesterTests.swift`

**Interfaces:**
- Consumes: `CaptureSpool`, `ProjectResolver`, `TranscriptParser`, `Git`.
- Produces: `enum Git { static func run(_ args: [String], in repo: String) -> String? }` — runs `git` via `Process`, returns trimmed stdout or nil on failure.
- Produces: `struct Ingester { init(spool: CaptureSpool, db: any DatabaseWriter); @discardableResult func drain() throws -> Int }` — processes all pending spool rows into events, returns the count ingested.

- [ ] **Step 1: Write the failing test** (creates a real temp git repo so enrichment is exercised)

```swift
import Foundation
import Testing
import SQLiteData
@testable import PensieveKit

@Test func ingestsGitCommitIntoEvent() throws {
  // Arrange: a real temp git repo with one commit.
  let repo = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("repo-\(UUID().uuidString)")
  try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
  _ = Git.run(["init"], in: repo.path)
  _ = Git.run(["config", "user.email", "t@t.co"], in: repo.path)
  _ = Git.run(["config", "user.name", "T"], in: repo.path)
  try "hello".write(to: repo.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
  _ = Git.run(["add", "-A"], in: repo.path)
  _ = Git.run(["commit", "-m", "first commit"], in: repo.path)
  let hash = Git.run(["rev-parse", "HEAD"], in: repo.path)!

  let spoolURL = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("spool-\(UUID().uuidString).sqlite")
  let spool = try CaptureSpool(at: spoolURL)
  let dbURL = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("canon-\(UUID().uuidString).sqlite")
  let db = try openCanonicalDatabase(at: dbURL)

  let payload = GitCommitPayload(repoPath: repo.path, hash: hash, branch: "main")
  try spool.append(kind: CaptureKind.gitCommit, payload: try encodeJSON(payload))

  // Act
  let n = try Ingester(spool: spool, db: db).drain()

  // Assert
  #expect(n == 1)
  let events = try db.read { db in try Event.all.fetchAll(db) }
  #expect(events.count == 1)
  #expect(events.first?.summary == "first commit")
  #expect(events.first?.kind == CaptureKind.gitCommit)
  #expect(try spool.pending().isEmpty)   // marked ingested
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `./scripts/test.sh --filter ingestsGitCommitIntoEvent`
Expected: FAIL — `Git` / `Ingester` not defined.

- [ ] **Step 3: Implement `Git.swift`**

```swift
import Foundation

public enum Git {
  public static func run(_ args: [String], in repo: String) -> String? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["git", "-C", repo] + args
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = Pipe()
    do { try process.run() } catch { return nil }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { return nil }
    return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
  }
}
```

- [ ] **Step 4: Implement `Ingester.swift`**

```swift
import Foundation
import SQLiteData

public struct Ingester {
  let spool: CaptureSpool
  let db: any DatabaseWriter
  let resolver: ProjectResolver

  public init(spool: CaptureSpool, db: any DatabaseWriter) {
    self.spool = spool; self.db = db; self.resolver = ProjectResolver(db: db)
  }

  @discardableResult
  public func drain() throws -> Int {
    let rows = try spool.pending()
    var done: [Int64] = []
    for row in rows {
      do {
        try ingest(row)
        done.append(row.id)
      } catch {
        // Leave the row unmarked so it retries next drain; don't abort the batch.
        continue
      }
    }
    try spool.markIngested(done)
    return done.count
  }

  private func ingest(_ row: SpoolRow) throws {
    let data = Data(row.payload.utf8)
    switch row.kind {
    case CaptureKind.gitCommit:
      let p = try JSONDecoder().decode(GitCommitPayload.self, from: data)
      let (project, source) = try resolver.resolve(path: p.repoPath, kind: "gitRepo")
      let subject = Git.run(["show", "-s", "--format=%s", p.hash], in: p.repoPath) ?? p.hash
      let when = Git.run(["show", "-s", "--format=%cI", p.hash], in: p.repoPath)
        .flatMap { ISO8601DateFormatter().date(from: $0) } ?? row.ts
      let files = Git.run(["show", "--name-only", "--format=", p.hash], in: p.repoPath) ?? ""
      let detail = try encodeJSON(["hash": p.hash, "branch": p.branch, "files": files])
      let event = Event(projectID: project.id, sourceID: source.id, occurredAt: when,
                        kind: CaptureKind.gitCommit, summary: subject, detailJSON: detail)
      try db.write { db in try Event.insert { event }.execute(db) }

    case CaptureKind.gitCheckout:
      let p = try JSONDecoder().decode(GitCheckoutPayload.self, from: data)
      let (project, source) = try resolver.resolve(path: p.repoPath, kind: "gitRepo")
      let detail = try encodeJSON(["from": p.from, "to": p.to, "branch": p.branch])
      let event = Event(projectID: project.id, sourceID: source.id, occurredAt: row.ts,
                        kind: CaptureKind.gitCheckout, summary: "checkout \(p.branch)", detailJSON: detail)
      try db.write { db in try Event.insert { event }.execute(db) }

    case CaptureKind.ccSession:
      let p = try JSONDecoder().decode(SessionRefPayload.self, from: data)
      let session = TranscriptParser.parse(fileURL: URL(fileURLWithPath: p.transcriptPath))
      guard let cwd = session.cwd else { return }   // can't attribute without a path
      let (project, source) = try resolver.resolve(path: cwd, kind: "claudeCode")
      let detail = try encodeJSON(["sessionID": session.sessionID,
                                   "prompts": String(session.userPromptCount),
                                   "transcriptPath": p.transcriptPath])
      let event = Event(projectID: project.id, sourceID: source.id,
                        occurredAt: session.endedAt ?? row.ts,
                        kind: CaptureKind.ccSession,
                        summary: "session (\(session.userPromptCount) prompts)", detailJSON: detail)
      try db.write { db in try Event.insert { event }.execute(db) }

    default:
      return   // unknown kind: mark done (drop) — forward-compat, don't wedge the spool
    }
  }
}
```

- [ ] **Step 5: Run test to verify it passes**

Run: `./scripts/test.sh --filter ingestsGitCommitIntoEvent`
Expected: PASS

- [ ] **Step 6: Commit**

```bash
git add Sources/PensieveKit/Support/Git.swift Sources/PensieveKit/Ingest/Ingester.swift \
  Tests/PensieveKitTests/IngesterTests.swift
git commit -m "feat: ingester drains spool into enriched events"
```

---

### Task 8: CLI — ingest / ingest-session / list / status / track / group

**Files:**
- Create: `Sources/PensieveKit/Query/ProjectQueries.swift`
- Create: `Sources/pensieve/Commands/{Ingest,IngestSession,ListProjects,Status,Track,Group}.swift`
- Modify: `Sources/pensieve/Pensieve.swift` (register subcommands; add `openCanonical()`)
- Test: `Tests/PensieveKitTests/ProjectQueriesTests.swift`

**Interfaces:**
- Consumes: `Ingester`, `ProjectResolver`, `CaptureSpool`, canonical tables.
- Produces: `struct ProjectStatus { let project: Project; let recentEvents: [Event] }`
- Produces: `enum ProjectQueries { static func all(_ db: any DatabaseWriter) throws -> [Project]; static func status(_ db: any DatabaseWriter, name: String, limit: Int) throws -> ProjectStatus? }`
- Produces (CLI): `func openCanonical() throws -> any DatabaseWriter` (honours `PENSIEVE_DB` override for tests).

- [ ] **Step 1: Write the failing test**

```swift
import Foundation
import Testing
import SQLiteData
@testable import PensieveKit

@Test func statusReturnsRecentEvents() throws {
  let url = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("q-\(UUID().uuidString).sqlite")
  let db = try openCanonicalDatabase(at: url)
  let (project, source) = try ProjectResolver(db: db).resolve(path: "/p/colibri", kind: "gitRepo")
  try db.write { db in
    try Event.insert {
      Event(projectID: project.id, sourceID: source.id, occurredAt: Date(),
            kind: "git.commit", summary: "did a thing", detailJSON: "{}")
    }.execute(db)
  }

  let status = try ProjectQueries.status(db, name: "colibri", limit: 10)
  #expect(status?.recentEvents.first?.summary == "did a thing")
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `./scripts/test.sh --filter statusReturnsRecentEvents`
Expected: FAIL — `ProjectQueries` not defined.

- [ ] **Step 3: Implement `ProjectQueries.swift`**

```swift
import Foundation
import SQLiteData

public struct ProjectStatus: Sendable {
  public let project: Project
  public let recentEvents: [Event]
}

public enum ProjectQueries {
  public static func all(_ db: any DatabaseWriter) throws -> [Project] {
    try db.read { db in try Project.order { $0.name }.fetchAll(db) }
  }

  public static func status(_ db: any DatabaseWriter, name: String, limit: Int) throws -> ProjectStatus? {
    try db.read { db in
      guard let project = try Project.where({ $0.name == name }).fetchOne(db) else { return nil }
      let events = try Event.where { $0.projectID == project.id }
        .order { $0.occurredAt.descending() }
        .limit(limit)
        .fetchAll(db)
      return ProjectStatus(project: project, recentEvents: events)
    }
  }
}
```

- [ ] **Step 4: Implement the CLI commands and register them**

Add to `Pensieve.swift`:

```swift
func openCanonical() throws -> any DatabaseWriter {
  if let override = ProcessInfo.processInfo.environment["PENSIEVE_DB"] {
    return try openCanonicalDatabase(at: URL(fileURLWithPath: override))
  }
  return try openCanonicalDatabase(at: PensievePaths.canonicalURL())
}
```

Update the root `subcommands:` array to:

```swift
    subcommands: [
      CaptureCommit.self, CaptureCheckout.self, IngestSession.self,
      Ingest.self, ListProjects.self, Status.self, Track.self, Group.self,
    ]
```

```swift
// Ingest.swift
import ArgumentParser
import PensieveKit

struct Ingest: ParsableCommand {
  static let configuration = CommandConfiguration(commandName: "ingest",
    abstract: "Drain the capture spool into the canonical store.")
  func run() throws {
    let n = try Ingester(spool: try openSpool(), db: try openCanonical()).drain()
    print("ingested \(n) event(s)")
  }
}
```

```swift
// IngestSession.swift
import ArgumentParser
import PensieveKit

struct IngestSession: ParsableCommand {
  static let configuration = CommandConfiguration(commandName: "ingest-session",
    abstract: "Record a Claude Code transcript for ingestion.")
  @Option var path: String
  func run() throws {
    let payload = SessionRefPayload(transcriptPath: path)
    try openSpool().append(kind: CaptureKind.ccSession, payload: try encodeJSON(payload))
  }
}
```

```swift
// ListProjects.swift
import ArgumentParser
import PensieveKit

struct ListProjects: ParsableCommand {
  static let configuration = CommandConfiguration(commandName: "list")
  func run() throws {
    for p in try ProjectQueries.all(try openCanonical()) { print("\(p.name)  [\(p.state)]") }
  }
}
```

```swift
// Status.swift
import ArgumentParser
import PensieveKit

struct Status: ParsableCommand {
  static let configuration = CommandConfiguration(commandName: "status")
  @Argument var project: String
  func run() throws {
    guard let s = try ProjectQueries.status(try openCanonical(), name: project, limit: 20) else {
      print("no project named '\(project)'"); return
    }
    print("# \(s.project.name)")
    for e in s.recentEvents { print("  \(e.occurredAt) \(e.kind)  \(e.summary)") }
  }
}
```

```swift
// Track.swift
import ArgumentParser
import Foundation
import PensieveKit

struct Track: ParsableCommand {
  static let configuration = CommandConfiguration(commandName: "track",
    abstract: "Explicitly register a repo as a project.")
  @Argument var path: String
  func run() throws {
    let abs = URL(fileURLWithPath: path).standardizedFileURL.path
    let r = try ProjectResolver(db: try openCanonical()).resolve(path: abs, kind: "gitRepo")
    print("tracking \(r.project.name)")
  }
}
```

```swift
// Group.swift
import ArgumentParser
import PensieveKit
import SQLiteData

struct Group: ParsableCommand {
  static let configuration = CommandConfiguration(commandName: "group",
    abstract: "Merge one or more projects into the first.")
  @Argument var names: [String]
  func run() throws {
    let db = try openCanonical()
    let projects = try ProjectQueries.all(db)
    let ids = names.compactMap { name in projects.first { $0.name == name }?.id }
    guard let primary = ids.first, ids.count == names.count else {
      print("unknown project name(s)"); return
    }
    try ProjectResolver(db: db).group(primary, into: Array(ids.dropFirst()))
    print("grouped \(names.dropFirst().joined(separator: ", ")) into \(names[0])")
  }
}
```

- [ ] **Step 5: Run test + smoke-test end-to-end**

Run: `./scripts/test.sh --filter statusReturnsRecentEvents`
Expected: PASS

```bash
export PENSIEVE_DB=/tmp/e2e.sqlite PENSIEVE_CAPTURE_DB=/tmp/e2e-cap.sqlite
swift run pensieve track /tmp   # creates a project
swift run pensieve list         # shows it
```
Expected: `list` prints `tmp  [active]`.

- [ ] **Step 6: Commit**

```bash
git add Sources/PensieveKit/Query Sources/pensieve/Commands Sources/pensieve/Pensieve.swift \
  Tests/PensieveKitTests/ProjectQueriesTests.swift
git commit -m "feat: ingest/list/status/track/group CLI commands"
```

---

### Task 9: Git hook templates + installer

**Files:**
- Create: `Sources/PensieveKit/Capture/HookInstaller.swift`
- Create: `Sources/pensieve/Commands/InstallHooks.swift`
- Modify: `Sources/pensieve/Pensieve.swift` (register `InstallHooks`)
- Test: `Tests/PensieveKitTests/HookInstallerTests.swift`

**Interfaces:**
- Produces: `enum HookInstaller { static func install(inRepo repo: URL) throws -> [URL]; static let postCommitScript: String; static let postCheckoutScript: String }`

- [ ] **Step 1: Write the failing test**

```swift
import Foundation
import Testing
@testable import PensieveKit

@Test func installsExecutableHooks() throws {
  let repo = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("hookrepo-\(UUID().uuidString)")
  try FileManager.default.createDirectory(
    at: repo.appendingPathComponent(".git/hooks"), withIntermediateDirectories: true)

  let written = try HookInstaller.install(inRepo: repo)
  #expect(written.count == 2)

  let postCommit = repo.appendingPathComponent(".git/hooks/post-commit")
  let body = try String(contentsOf: postCommit, encoding: .utf8)
  #expect(body.contains("pensieve capture-commit"))
  let perms = try FileManager.default.attributesOfItem(atPath: postCommit.path)[.posixPermissions] as! NSNumber
  #expect(perms.intValue & 0o111 != 0)   // executable bit set
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `./scripts/test.sh --filter installsExecutableHooks`
Expected: FAIL — `HookInstaller` not defined.

- [ ] **Step 3: Implement `HookInstaller.swift`**

```swift
import Foundation

public enum HookInstaller {
  // Backgrounded (&) and error-swallowed so a missing/slow `pensieve` never affects git.
  public static let postCommitScript = """
    #!/bin/sh
    pensieve capture-commit \
      --repo "$(git rev-parse --show-toplevel)" \
      --hash "$(git rev-parse HEAD)" \
      --branch "$(git rev-parse --abbrev-ref HEAD)" >/dev/null 2>&1 &
    exit 0
    """

  public static let postCheckoutScript = """
    #!/bin/sh
    # Only branch checkouts ($3 == 1), not file checkouts.
    [ "$3" = "1" ] || exit 0
    pensieve capture-checkout \
      --repo "$(git rev-parse --show-toplevel)" \
      --from "$1" --to "$2" \
      --branch "$(git rev-parse --abbrev-ref HEAD)" >/dev/null 2>&1 &
    exit 0
    """

  public static func install(inRepo repo: URL) throws -> [URL] {
    let hooksDir = repo.appendingPathComponent(".git/hooks", isDirectory: true)
    try FileManager.default.createDirectory(at: hooksDir, withIntermediateDirectories: true)
    var written: [URL] = []
    for (name, script) in [("post-commit", postCommitScript), ("post-checkout", postCheckoutScript)] {
      let url = hooksDir.appendingPathComponent(name)
      try script.write(to: url, atomically: true, encoding: .utf8)
      try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
      written.append(url)
    }
    return written
  }
}
```

- [ ] **Step 4: Implement `InstallHooks.swift` and register it**

```swift
// InstallHooks.swift
import ArgumentParser
import Foundation
import PensieveKit

struct InstallHooks: ParsableCommand {
  static let configuration = CommandConfiguration(commandName: "install-hooks",
    abstract: "Install Pensieve git hooks into a repository.")
  @Argument var repo: String
  func run() throws {
    let url = URL(fileURLWithPath: repo).standardizedFileURL
    let written = try HookInstaller.install(inRepo: url)
    for w in written { print("installed \(w.path)") }
  }
}
```

Add `InstallHooks.self` to the root `subcommands:` array in `Pensieve.swift`.

- [ ] **Step 5: Run test to verify it passes**

Run: `./scripts/test.sh --filter installsExecutableHooks`
Expected: PASS

- [ ] **Step 6: Full suite + commit**

Run: `./scripts/test.sh`
Expected: all tests PASS.

```bash
git add Sources/PensieveKit/Capture/HookInstaller.swift Sources/pensieve/Commands/InstallHooks.swift \
  Sources/pensieve/Pensieve.swift Tests/PensieveKitTests/HookInstallerTests.swift
git commit -m "feat: git hook templates and install-hooks command"
```

---

## Manual end-to-end acceptance (run once after Task 9)

Proves the whole pipeline on a real repo:

```bash
swift build -c release
BIN="$(swift build -c release --show-bin-path)/pensieve"
export PATH="$(dirname "$BIN"):$PATH"     # so hooks find `pensieve`

cd /tmp && rm -rf pensieve-accept && mkdir pensieve-accept && cd pensieve-accept
git init -q
pensieve install-hooks .
echo hi > f.txt && git add -A && git commit -qm "acceptance commit"
sleep 1                                    # let the backgrounded hook write
pensieve ingest
pensieve status pensieve-accept            # should list the acceptance commit
```

Expected: `status` shows one `git.commit  acceptance commit` line under project `pensieve-accept`.

---

## Self-Review (completed against the spec)

- **Spec coverage (Phase 1A scope):** capture spool ✓ (Task 3); canonical store, `project ≠ directory`, many-sources→one-project, `group` ✓ (Tasks 1–2, 6); git `post-commit`/`post-checkout` fire-and-forget capture ✓ (Tasks 4, 9); direct-write-to-spool, no daemon dependency ✓ (Tasks 3–4); read CC transcripts directly ✓ (Task 5); ingester single-writer into canonical store ✓ (Task 7); UUID PKs / STRICT / column-name-match constraint ✓ (Tasks 1–2). LLM/loose-ends intelligence is intentionally **out of scope** (Plan 1B) — `looseEnds` table exists but is unpopulated. Always-on `pensieved` service is **out of scope** (Plan for Phase 2); ingestion is CLI-triggered here, exactly as the spec's Phase 1 says.
- **Placeholder scan:** none. Every code step contains complete code; the two "if the macro API differs, adjust" notes (Tasks 1, 6) are test-backed verification checkpoints, not deferred work.
- **Type consistency:** `Event(projectID:sourceID:occurredAt:kind:summary:detailJSON:)`, `Source(projectID:kind:key:)`, `ProjectResolver.resolve(path:kind:) -> (project:source:)`, `CaptureSpool.append/pending/markIngested`, `CaptureKind.*`, `openCanonicalDatabase(at:)` are used identically across every task that references them.
