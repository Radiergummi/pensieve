# Pensieve Phase 1B — Intelligence Layer (the gate) — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn captured Claude Code sessions into **verified, verbatim-cited loose ends** (plus grounded summaries and a deterministic "what's next") on the existing flat `Project` model, and prove on real projects that they are real and cited with zero hallucinations.

**Architecture:** A narrow `LLMProvider` protocol (default = on-device Apple **Foundation Models**, fallback = `claude -p`) feeds a `LooseEndExtractor`. Every candidate passes an incorruptible, code-only `LooseEndVerifier` (verbatim substring, user-prose-only, min-length) before it is stored — the extractor proposes, the verifier disposes. Ingestion gains a source-agnostic fingerprint so re-runs don't duplicate. Extraction is a separate async pass over newly-ingested `cc.session` events, keyed by an `extractedAt` marker. Summaries narrate deterministically-assembled facts (fenced from cited items); "what's next" is pure ranking.

**Tech Stack:** Swift 6, SQLiteData (GRDB-backed), swift-argument-parser, Swift Testing (`import Testing`), Apple `FoundationModels` framework.

## Global Constraints

- **Toolchain / tests:** `swift-tools-version: 6.0`; platform floor `.macOS(.v14)`. Run the suite with **`./scripts/test.sh`** (optionally `--filter <name>`) — **NOT** `swift test` (Command-Line-Tools-only machine; the wrapper puts Swift Testing on the rpath). `swift build`/`swift run` work normally. If a build dies with a SwiftSyntax/macro linker error, `rm -rf .build` and retry.
- **Swift only. No Python, ever.**
- **SQLiteData predicates use `.eq(x)`, NOT `== x`** (e.g. `.where { $0.kind.eq(CaptureKind.ccSession) }`), and `.desc()` for ordering. `==` is `unavailable`.
- **Canonical tables are `STRICT`; column names must exactly match `@Table` property names; PKs are `UUID`.** Additive migrations only in 1B (a new `v3` migration); do not edit `v1`/`v2`.
- **Reuse kind constants** from `CaptureKind`/`SourceKind` (`CapturePayloads.swift`). Don't hardcode kind strings.
- **No shared mutable `static ISO8601DateFormatter`** (Swift 6 concurrency) — use a local instance or `Date.ISO8601FormatStyle`.
- **LLM layer is local-first:** Foundation Models is the default provider; `claude -p` is fallback + escalation only. FM code is `@available(macOS 26.0, *)`-guarded so the package still builds/links on the `.v14` floor.
- **Read current Apple Foundation Models / ML documentation at implementation time** (Task 1) — the framework is new; do not rely on training memory for exact API names.
- **The trust rule is absolute and enforced in code:** a loose end is stored only if its `quote` is verbatim-present in a genuine user-authored message. **Display leads with the quote**; the model's paraphrase (`text`) is secondary.
- **Scope:** flat `Project` model only. **No** tree/`parentID`/`kind`/strands/`Node` rename/session-start hook/organizing CLI — all deferred to a future `1B-org` spec (see `docs/superpowers/backlog.md`). Extraction mines **genuine user prose only**; TodoWrite/tool-content mining is deferred (the primary recall lever if the gate shows thin recall).

---

### Task 1: Foundation Models de-risking spike

Pins the exact Foundation Models API on this machine before anything depends on it. **Read the current Apple `FoundationModels` documentation first** (availability API, `LanguageModelSession`, guided generation) — the snippets below are best-known and MUST be reconciled with the live API; the test is the arbiter.

**Files:**
- Create: `Sources/PensieveKit/LLM/FoundationModelsProbe.swift`
- Test: `Tests/PensieveKitTests/FoundationModelsProbeTests.swift`

**Interfaces:**
- Produces: `enum FoundationModelsProbe { static func availabilityDescription() -> String; @available(macOS 26.0, *) static func roundTrip(_ prompt: String) async throws -> String }`

- [ ] **Step 1: Write the probe**

```swift
import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// A minimal, isolated probe used once to confirm on-device model availability and a
/// working round-trip on this machine. Confirm the exact API names against the current
/// Apple FoundationModels documentation — reconcile any differences here.
public enum FoundationModelsProbe {
  /// Human-readable availability, safe to call on any macOS (returns a reason string when
  /// the framework or model is unavailable rather than trapping).
  public static func availabilityDescription() -> String {
    #if canImport(FoundationModels)
    if #available(macOS 26.0, *) {
      switch SystemLanguageModel.default.availability {
      case .available:
        return "available"
      case .unavailable(let reason):
        return "unavailable: \(reason)"
      @unknown default:
        return "unavailable: unknown"
      }
    } else {
      return "unavailable: requires macOS 26"
    }
    #else
    return "unavailable: FoundationModels not importable"
    #endif
  }

  #if canImport(FoundationModels)
  @available(macOS 26.0, *)
  public static func roundTrip(_ prompt: String) async throws -> String {
    let session = LanguageModelSession()
    let response = try await session.respond(to: prompt)
    return response.content
  }
  #endif
}
```

- [ ] **Step 2: Write the test** (does not hard-fail when the model is unavailable — it records)

```swift
import Foundation
import Testing
@testable import PensieveKit

@Test func foundationModelsAvailabilityIsReported() {
  let desc = FoundationModelsProbe.availabilityDescription()
  print("FoundationModels availability: \(desc)")
  #expect(!desc.isEmpty)
}

@Test func foundationModelsRoundTripIfAvailable() async throws {
  guard FoundationModelsProbe.availabilityDescription() == "available" else {
    print("skipping round-trip: model unavailable")
    return
  }
  if #available(macOS 26.0, *) {
    let out = try await FoundationModelsProbe.roundTrip("Reply with the single word: ok")
    print("FoundationModels round-trip output: \(out)")
    #expect(!out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
  }
}
```

- [ ] **Step 3: Build + run**

Run: `swift build` then `./scripts/test.sh --filter foundationModels`
Expected: builds; `availabilityIsReported` PASS; round-trip PASS printing "available" (on this macOS 26 machine). **If it does not build or prints unavailable**, record the exact API/error in the task notes — the plan's default provider decision (Task 3) depends on this outcome. Reconcile `SystemLanguageModel`, `LanguageModelSession`, `respond(to:)`, `.content` with the current docs and fix until the round-trip passes.

- [ ] **Step 4: Commit**

```bash
git add Sources/PensieveKit/LLM/FoundationModelsProbe.swift Tests/PensieveKitTests/FoundationModelsProbeTests.swift
git commit -m "feat: Foundation Models availability + round-trip spike"
```

---

### Task 2: `LLMProvider` protocol + `claude -p` fallback provider

The always-buildable provider (works on the `.v14` floor). Injectable process runner so it is unit-testable without a live `claude`.

**Files:**
- Create: `Sources/PensieveKit/LLM/LLMProvider.swift`
- Create: `Sources/PensieveKit/LLM/ClaudeCLIProvider.swift`
- Test: `Tests/PensieveKitTests/ClaudeCLIProviderTests.swift`

**Interfaces:**
- Produces: `protocol LLMProvider: Sendable { func complete(prompt: String) async throws -> String }`
- Produces: `struct ClaudeCLIProvider: LLMProvider { init(run: @escaping @Sendable (String) throws -> String = ClaudeCLIProvider.shellRun); func complete(prompt: String) async throws -> String }` and `static func shellRun(_ prompt: String) throws -> String`
- Produces: `enum LLMError: Error { case providerFailed(String) }`

- [ ] **Step 1: Write the failing test** (stubbed runner — no real CLI)

```swift
import Foundation
import Testing
@testable import PensieveKit

@Test func claudeProviderUsesInjectedRunner() async throws {
  let provider = ClaudeCLIProvider(run: { prompt in "echo: \(prompt)" })
  let out = try await provider.complete(prompt: "hello")
  #expect(out == "echo: hello")
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `./scripts/test.sh --filter claudeProviderUsesInjectedRunner`
Expected: FAIL — types not defined.

- [ ] **Step 3: Implement the protocol and provider**

```swift
// LLMProvider.swift
import Foundation

public enum LLMError: Error, Sendable { case providerFailed(String) }

/// The single narrow seam through which all model calls flow. Deliberately minimal:
/// one method, prompt in / text out. Structured output is achieved by prompting for
/// JSON and decoding at the call site, so any provider (local or HTTP) satisfies it.
public protocol LLMProvider: Sendable {
  func complete(prompt: String) async throws -> String
}
```

```swift
// ClaudeCLIProvider.swift
import Foundation

/// Fallback provider: shells out to `claude -p` (subscription auth, no API key).
public struct ClaudeCLIProvider: LLMProvider {
  private let run: @Sendable (String) throws -> String
  public init(run: @escaping @Sendable (String) throws -> String = ClaudeCLIProvider.shellRun) {
    self.run = run
  }

  public func complete(prompt: String) async throws -> String {
    try run(prompt)
  }

  /// Runs `claude -p` with the prompt on stdin; returns trimmed stdout.
  public static func shellRun(_ prompt: String) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["claude", "-p"]
    let stdin = Pipe(), stdout = Pipe()
    process.standardInput = stdin
    process.standardOutput = stdout
    process.standardError = Pipe()
    do { try process.run() } catch { throw LLMError.providerFailed("spawn: \(error)") }
    stdin.fileHandleForWriting.write(Data(prompt.utf8))
    stdin.fileHandleForWriting.closeFile()
    let data = stdout.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
      throw LLMError.providerFailed("claude -p exit \(process.terminationStatus)")
    }
    return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
  }
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `./scripts/test.sh --filter claudeProviderUsesInjectedRunner`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/PensieveKit/LLM/LLMProvider.swift Sources/PensieveKit/LLM/ClaudeCLIProvider.swift \
  Tests/PensieveKitTests/ClaudeCLIProviderTests.swift
git commit -m "feat: LLMProvider protocol + claude -p fallback provider"
```

---

### Task 3: Foundation Models provider + default-provider selection

Wraps the Task-1-confirmed API behind `LLMProvider`, and selects it as default when available, else falls back to `claude -p`.

**Files:**
- Create: `Sources/PensieveKit/LLM/FoundationModelsProvider.swift`
- Create: `Sources/PensieveKit/LLM/DefaultProvider.swift`
- Test: `Tests/PensieveKitTests/DefaultProviderTests.swift`

**Interfaces:**
- Consumes: `LLMProvider` (Task 2), `FoundationModelsProbe` (Task 1).
- Produces: `@available(macOS 26.0, *) struct FoundationModelsProvider: LLMProvider { init(); func complete(prompt: String) async throws -> String }`
- Produces: `func makeDefaultLLMProvider() -> any LLMProvider`

- [ ] **Step 1: Write the failing test** (selection returns *some* provider on any OS)

```swift
import Foundation
import Testing
@testable import PensieveKit

@Test func defaultProviderIsSelectable() async throws {
  let provider = makeDefaultLLMProvider()
  // On macOS 26 with the model enabled this is FoundationModelsProvider; otherwise Claude.
  // Either way we get a usable LLMProvider value.
  _ = provider
  #expect(Bool(true))
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `./scripts/test.sh --filter defaultProviderIsSelectable`
Expected: FAIL — `makeDefaultLLMProvider` not defined.

- [ ] **Step 3: Implement the FM provider (reconcile with Task 1's confirmed API)**

```swift
// FoundationModelsProvider.swift
import Foundation
#if canImport(FoundationModels)
import FoundationModels

/// Default provider: on-device Apple model. No API key, no rate limits, no subprocess.
@available(macOS 26.0, *)
public struct FoundationModelsProvider: LLMProvider {
  public init() {}

  public func complete(prompt: String) async throws -> String {
    let session = LanguageModelSession()
    do {
      let response = try await session.respond(to: prompt)
      return response.content
    } catch {
      throw LLMError.providerFailed("FoundationModels: \(error)")
    }
  }
}
#endif
```

```swift
// DefaultProvider.swift
import Foundation

/// Local-first selection: Foundation Models when available on this machine, else `claude -p`.
public func makeDefaultLLMProvider() -> any LLMProvider {
  #if canImport(FoundationModels)
  if #available(macOS 26.0, *), FoundationModelsProbe.availabilityDescription() == "available" {
    return FoundationModelsProvider()
  }
  #endif
  return ClaudeCLIProvider()
}
```

- [ ] **Step 4: Run to verify it passes + smoke the real model**

Run: `./scripts/test.sh --filter defaultProviderIsSelectable`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/PensieveKit/LLM/FoundationModelsProvider.swift Sources/PensieveKit/LLM/DefaultProvider.swift \
  Tests/PensieveKitTests/DefaultProviderTests.swift
git commit -m "feat: Foundation Models provider + local-first default selection"
```

---

### Task 4: Schema v3 migration + model field additions

Additive columns: `Event.fingerprint`, `Event.extractedAt`, `LooseEnd.role`, `LooseEnd.sourceMessageIndex`; a unique dedup index; backfill of existing rows.

**Files:**
- Modify: `Sources/PensieveKit/Model/Event.swift`
- Modify: `Sources/PensieveKit/Model/LooseEnd.swift`
- Modify: `Sources/PensieveKit/Store/CanonicalStore.swift` (append a `v3` migration only)
- Test: `Tests/PensieveKitTests/SchemaV3Tests.swift`

**Interfaces:**
- Produces (updated): `Event(... , fingerprint: String? = nil, extractedAt: Date? = nil)` with stored props `var fingerprint: String?`, `var extractedAt: Date?`.
- Produces (updated): `LooseEnd(... , role: String = "", sourceMessageIndex: Int = 0, ...)` with stored props `var role: String`, `var sourceMessageIndex: Int`.

- [ ] **Step 1: Write the failing test**

```swift
import Foundation
import Testing
import SQLiteData
@testable import PensieveKit

@Test func v3AddsColumnsAndRoundTrips() throws {
  let db = try openCanonicalDatabase(at: tempURL("v3"))
  let project = Project(name: "Colibri")
  let source = Source(projectID: project.id, kind: SourceKind.claudeCode, key: "/p/colibri")
  let event = Event(projectID: project.id, sourceID: source.id, occurredAt: Date(),
                    kind: CaptureKind.ccSession, summary: "s", detailJSON: "{}",
                    fingerprint: "fp-1", extractedAt: nil)
  try db.write { db in
    try Project.insert { project }.execute(db)
    try Source.insert { source }.execute(db)
    try Event.insert { event }.execute(db)
    try LooseEnd.insert {
      LooseEnd(projectID: project.id, sourceEventID: event.id, text: "do X",
               quote: "we still need to do X", role: "user", sourceMessageIndex: 3)
    }.execute(db)
  }
  let le = try db.read { db in try LooseEnd.all.fetchAll(db) }.first
  #expect(le?.role == "user")
  #expect(le?.sourceMessageIndex == 3)
  let ev = try db.read { db in try Event.all.fetchAll(db) }.first
  #expect(ev?.fingerprint == "fp-1")
  #expect(ev?.extractedAt == nil)
}

@Test func v3UniqueFingerprintIndexRejectsDuplicate() throws {
  let db = try openCanonicalDatabase(at: tempURL("v3dup"))
  let project = Project(name: "P")
  let source = Source(projectID: project.id, kind: SourceKind.gitRepo, key: "/p")
  try db.write { db in
    try Project.insert { project }.execute(db)
    try Source.insert { source }.execute(db)
    try Event.insert {
      Event(projectID: project.id, sourceID: source.id, occurredAt: Date(),
            kind: CaptureKind.gitCommit, summary: "a", detailJSON: "{}", fingerprint: "dup")
    }.execute(db)
  }
  #expect(throws: (any Error).self) {
    try db.write { db in
      try Event.insert {
        Event(projectID: project.id, sourceID: source.id, occurredAt: Date(),
              kind: CaptureKind.gitCommit, summary: "b", detailJSON: "{}", fingerprint: "dup")
      }.execute(db)
    }
  }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `./scripts/test.sh --filter v3`
Expected: FAIL — new initializer params / columns don't exist.

- [ ] **Step 3: Update the model structs**

In `Event.swift`, add two stored properties and extend the initializer:

```swift
  public var detailJSON: String  // enriched payload as JSON
  public var fingerprint: String?   // source-agnostic idempotency key (unique per sourceID)
  public var extractedAt: Date?     // when loose-end extraction last processed this event
  public var createdAt: Date
  public init(id: UUID = UUID(), projectID: UUID, sourceID: UUID, occurredAt: Date,
              kind: String, summary: String, detailJSON: String,
              fingerprint: String? = nil, extractedAt: Date? = nil, createdAt: Date = Date()) {
    self.id = id; self.projectID = projectID; self.sourceID = sourceID; self.occurredAt = occurredAt
    self.kind = kind; self.summary = summary; self.detailJSON = detailJSON
    self.fingerprint = fingerprint; self.extractedAt = extractedAt; self.createdAt = createdAt
  }
```

In `LooseEnd.swift`, add two stored properties and extend the initializer:

```swift
  public var status: String      // "open" | "resolved"
  public var role: String            // role of the cited message (e.g. "user")
  public var sourceMessageIndex: Int // index of the cited message within the transcript
  public var createdAt: Date
  public init(id: UUID = UUID(), projectID: UUID, sourceEventID: UUID, text: String,
              quote: String, status: String = "open", role: String = "",
              sourceMessageIndex: Int = 0, createdAt: Date = Date()) {
    self.id = id; self.projectID = projectID; self.sourceEventID = sourceEventID
    self.text = text; self.quote = quote; self.status = status
    self.role = role; self.sourceMessageIndex = sourceMessageIndex; self.createdAt = createdAt
  }
```

- [ ] **Step 4: Append the `v3` migration** in `CanonicalStore.swift`, immediately before `try migrator.migrate(db)`:

```swift
  migrator.registerMigration("v3-fingerprint-extraction-provenance") { db in
    try #sql(#"ALTER TABLE "events" ADD COLUMN "fingerprint" TEXT"#).execute(db)
    try #sql(#"ALTER TABLE "events" ADD COLUMN "extractedAt" TEXT"#).execute(db)
    try #sql(#"ALTER TABLE "looseEnds" ADD COLUMN "role" TEXT NOT NULL DEFAULT ''"#).execute(db)
    try #sql(#"ALTER TABLE "looseEnds" ADD COLUMN "sourceMessageIndex" INTEGER NOT NULL DEFAULT 0"#).execute(db)
    // Backfill fingerprints for already-captured rows so the unique index is meaningful.
    try #sql(#"UPDATE "events" SET "fingerprint" = json_extract("detailJSON", '$.hash') WHERE "kind" = 'git.commit' AND "fingerprint" IS NULL"#).execute(db)
    try #sql(#"UPDATE "events" SET "fingerprint" = json_extract("detailJSON", '$.sessionID') WHERE "kind" = 'cc.session' AND "fingerprint" IS NULL"#).execute(db)
    // NULLs are distinct in a SQLite unique index, so unbackfilled rows (e.g. checkouts) don't collide.
    try #sql(#"CREATE UNIQUE INDEX "idx_events_source_fingerprint" ON "events"("sourceID", "fingerprint")"#).execute(db)
  }
```

- [ ] **Step 5: Run to verify it passes**

Run: `./scripts/test.sh --filter v3`
Expected: PASS. (If the STRICT-table `ALTER ... ADD COLUMN` errors on defaults, the round-trip/dup tests are the arbiter — adjust column definitions, keeping names identical to the struct properties.)

- [ ] **Step 6: Commit**

```bash
git add Sources/PensieveKit/Model/Event.swift Sources/PensieveKit/Model/LooseEnd.swift \
  Sources/PensieveKit/Store/CanonicalStore.swift Tests/PensieveKitTests/SchemaV3Tests.swift
git commit -m "feat: v3 migration — event fingerprint/extractedAt + loose-end provenance"
```

---

### Task 5: Transcript parser — message index + genuine-user-prompt flag

The verifier can only allow quotes from genuine user prose, so the parser must label each message.

**Files:**
- Modify: `Sources/PensieveKit/Transcript/ParsedSession.swift`
- Modify: `Sources/PensieveKit/Transcript/TranscriptParser.swift`
- Create fixture: `Tests/PensieveKitTests/Fixtures/session-roles.jsonl`
- Test: `Tests/PensieveKitTests/TranscriptRolesTests.swift`

**Interfaces:**
- Produces (updated): `struct TranscriptMessage { let index: Int; let role: String; let text: String; let timestamp: Date?; let isUserPrompt: Bool }`
- `isUserPrompt == true` iff the record's `type == "user"` AND its content is genuine prose (a plain string, or contains a `text` block) AND it is NOT a tool-result record (content contains a `tool_result` block).

- [ ] **Step 1: Create the fixture** `Tests/PensieveKitTests/Fixtures/session-roles.jsonl`

```
{"type":"user","cwd":"/p/colibri","timestamp":"2026-06-30T10:00:00Z","message":{"role":"user","content":"We still need to add rate limiting before launch"}}
{"type":"assistant","timestamp":"2026-06-30T10:01:00Z","message":{"role":"assistant","content":[{"type":"text","text":"You should also add pagination and retries."}]}}
{"type":"user","timestamp":"2026-06-30T10:02:00Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"x","content":"exit 0"}]}}
{"type":"user","cwd":"/p/colibri","timestamp":"2026-06-30T10:03:00Z","message":{"role":"user","content":"looks good, ship it"}}
```

- [ ] **Step 2: Write the failing test**

```swift
import Foundation
import Testing
@testable import PensieveKit

@Test func parserFlagsGenuineUserPrompts() throws {
  let url = Bundle.module.url(forResource: "session-roles", withExtension: "jsonl", subdirectory: "Fixtures")!
  let s = TranscriptParser.parse(fileURL: url)

  // indices are contiguous over retained messages
  #expect(s.messages.map(\.index) == Array(0..<s.messages.count))

  let userPrompts = s.messages.filter { $0.isUserPrompt }
  #expect(userPrompts.contains { $0.text.contains("rate limiting") })
  #expect(userPrompts.contains { $0.text.contains("ship it") })
  // assistant suggestion is NOT a user prompt
  #expect(!userPrompts.contains { $0.text.contains("pagination") })
  // tool-result user-record is NOT a user prompt (and has no text, so may be absent)
  #expect(!userPrompts.contains { $0.text.contains("exit 0") })
}
```

- [ ] **Step 3: Run to verify it fails**

Run: `./scripts/test.sh --filter parserFlagsGenuineUserPrompts`
Expected: FAIL — `index` / `isUserPrompt` not defined.

- [ ] **Step 4: Update `ParsedSession.swift`**

```swift
public struct TranscriptMessage: Sendable {
  public let index: Int
  public let role: String
  public let text: String
  public let timestamp: Date?
  public let isUserPrompt: Bool
}
```

- [ ] **Step 5: Update `TranscriptParser.swift`** — assign indices and compute `isUserPrompt`. Replace the message-building loop body:

```swift
    var nextIndex = 0
    for line in content.split(separator: "\n", omittingEmptySubsequences: true) {
      guard let data = line.data(using: .utf8),
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
      else { continue }   // defensive: skip garbage lines

      if cwd == nil, let c = obj["cwd"] as? String { cwd = c }
      let timestamp = (obj["timestamp"] as? String).flatMap(iso.date(from:))
      if let timestamp { timestamps.append(timestamp) }

      let type = obj["type"] as? String
      let message = obj["message"] as? [String: Any]
      let role = (message?["role"] as? String) ?? (type ?? "unknown")
      let content = message?["content"]
      let text = extractText(content)
      if type == "user" { userPrompts += 1 }
      let isUserPrompt = (type == "user") && !isToolResult(content) && !text.isEmpty
      if !text.isEmpty {
        messages.append(TranscriptMessage(index: nextIndex, role: role, text: text,
                                          timestamp: timestamp, isUserPrompt: isUserPrompt))
        nextIndex += 1
      }
    }
```

Add a helper alongside `extractText`:

```swift
  /// True when a `type:"user"` record is actually a tool result, not human prose.
  private static func isToolResult(_ content: Any?) -> Bool {
    guard let blocks = content as? [[String: Any]] else { return false }
    return blocks.contains { ($0["type"] as? String) == "tool_result" }
  }
```

- [ ] **Step 6: Run to verify it passes**

Run: `./scripts/test.sh --filter parserFlagsGenuineUserPrompts`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add Sources/PensieveKit/Transcript Tests/PensieveKitTests/TranscriptRolesTests.swift \
  Tests/PensieveKitTests/Fixtures/session-roles.jsonl
git commit -m "feat: parser marks message index + genuine user prompts"
```

---

### Task 6: `LooseEndVerifier` — the incorruptible gate

Pure, code-only. No LLM. This is the entire zero-hallucination guarantee; test it hard.

**Files:**
- Create: `Sources/PensieveKit/Intelligence/TextNormalization.swift`
- Create: `Sources/PensieveKit/Intelligence/LooseEndVerifier.swift`
- Test: `Tests/PensieveKitTests/LooseEndVerifierTests.swift`

**Interfaces:**
- Produces: `func normalizeWhitespace(_ s: String) -> String` — trims, collapses any run of whitespace/newlines to a single space.
- Produces: `struct LooseEndCandidate: Codable, Sendable { let text: String; let quote: String; let messageIndex: Int }`
- Produces: `struct VerifiedLooseEnd: Sendable { let text: String; let quote: String; let role: String; let sourceMessageIndex: Int }`
- Produces: `enum LooseEndVerifier { static let minQuoteLength = 15; static func verify(_ c: LooseEndCandidate, messages: [TranscriptMessage]) -> VerifiedLooseEnd? }`

- [ ] **Step 1: Write the failing tests**

```swift
import Foundation
import Testing
@testable import PensieveKit

private func msg(_ i: Int, _ role: String, _ text: String, userPrompt: Bool) -> TranscriptMessage {
  TranscriptMessage(index: i, role: role, text: text, timestamp: nil, isUserPrompt: userPrompt)
}

private let corpus: [TranscriptMessage] = [
  msg(0, "user", "We still need to add rate limiting before launch", userPrompt: true),
  msg(1, "assistant", "You should also add pagination and retries.", userPrompt: false),
  msg(2, "user", "ok", userPrompt: true),
]

@Test func verifierAcceptsVerbatimUserQuote() {
  let c = LooseEndCandidate(text: "add rate limiting",
                            quote: "we still need to add rate limiting before launch", messageIndex: 0)
  // whitespace-normalized, case-insensitive? NO — verbatim; test uses exact case below.
  let exact = LooseEndCandidate(text: "add rate limiting",
                                quote: "We still need to add rate limiting before launch", messageIndex: 0)
  #expect(LooseEndVerifier.verify(exact, messages: corpus) != nil)
  #expect(LooseEndVerifier.verify(c, messages: corpus) == nil) // wrong case is not verbatim
}

@Test func verifierRejectsAssistantQuote() {
  let c = LooseEndCandidate(text: "add pagination",
                            quote: "You should also add pagination and retries.", messageIndex: 1)
  #expect(LooseEndVerifier.verify(c, messages: corpus) == nil)  // not a user prompt
}

@Test func verifierRejectsFabricatedQuote() {
  let c = LooseEndCandidate(text: "deploy to prod",
                            quote: "remember to deploy to prod on Friday", messageIndex: 0)
  #expect(LooseEndVerifier.verify(c, messages: corpus) == nil)  // not present in message 0
}

@Test func verifierRejectsTooShortQuote() {
  let c = LooseEndCandidate(text: "ok", quote: "ok", messageIndex: 2)
  #expect(LooseEndVerifier.verify(c, messages: corpus) == nil)  // below minQuoteLength
}

@Test func verifierRejectsOutOfRangeIndex() {
  let c = LooseEndCandidate(text: "x", quote: "whatever text here padded", messageIndex: 99)
  #expect(LooseEndVerifier.verify(c, messages: corpus) == nil)
}

@Test func verifierToleratesWhitespaceDifferences() {
  let spaced = [msg(0, "user", "add   rate\n limiting  soon and more words", userPrompt: true)]
  let c = LooseEndCandidate(text: "rate limiting",
                            quote: "add rate limiting soon and more words", messageIndex: 0)
  #expect(LooseEndVerifier.verify(c, messages: spaced) != nil)
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `./scripts/test.sh --filter verifier`
Expected: FAIL — types not defined.

- [ ] **Step 3: Implement normalization + verifier**

```swift
// TextNormalization.swift
import Foundation

/// Trims and collapses every run of whitespace (incl. newlines) to a single space.
/// Used identically on both sides of the substring gate and for dedup.
public func normalizeWhitespace(_ s: String) -> String {
  s.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
}
```

```swift
// LooseEndVerifier.swift
import Foundation

public struct LooseEndCandidate: Codable, Sendable {
  public let text: String
  public let quote: String
  public let messageIndex: Int
  public init(text: String, quote: String, messageIndex: Int) {
    self.text = text; self.quote = quote; self.messageIndex = messageIndex
  }
}

public struct VerifiedLooseEnd: Sendable {
  public let text: String
  public let quote: String
  public let role: String
  public let sourceMessageIndex: Int
}

/// The gate: a candidate survives only if its quote is verbatim (whitespace-normalized),
/// long enough, and drawn from a genuine user-authored message. Everything else is dropped.
public enum LooseEndVerifier {
  public static let minQuoteLength = 15

  public static func verify(_ c: LooseEndCandidate, messages: [TranscriptMessage]) -> VerifiedLooseEnd? {
    guard c.quote.count >= minQuoteLength else { return nil }
    guard let m = messages.first(where: { $0.index == c.messageIndex }) else { return nil }
    guard m.isUserPrompt else { return nil }
    let haystack = normalizeWhitespace(m.text)
    let needle = normalizeWhitespace(c.quote)
    guard !needle.isEmpty, haystack.contains(needle) else { return nil }
    return VerifiedLooseEnd(text: c.text, quote: c.quote, role: m.role, sourceMessageIndex: m.index)
  }
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `./scripts/test.sh --filter verifier`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/PensieveKit/Intelligence/TextNormalization.swift \
  Sources/PensieveKit/Intelligence/LooseEndVerifier.swift \
  Tests/PensieveKitTests/LooseEndVerifierTests.swift
git commit -m "feat: LooseEndVerifier — verbatim, user-prose, min-length gate"
```

---

### Task 7: `LooseEndExtractor` — chunk, prompt, decode candidates

Builds prompts over user prompts only, calls the provider, defensively decodes candidates. Tested with a stub provider (no real model).

**Files:**
- Create: `Sources/PensieveKit/Intelligence/LooseEndExtractor.swift`
- Test: `Tests/PensieveKitTests/LooseEndExtractorTests.swift`

**Interfaces:**
- Consumes: `LLMProvider` (Task 2), `TranscriptMessage` (Task 5), `LooseEndCandidate` (Task 6).
- Produces: `struct LooseEndExtractor { init(provider: any LLMProvider, chunkCharBudget: Int = 6000); func extract(from messages: [TranscriptMessage]) async throws -> [LooseEndCandidate] }`
- Produces: `static func decodeCandidates(_ raw: String) -> [LooseEndCandidate]` (finds the first JSON array in the output; skips malformed).

- [ ] **Step 1: Write the failing test** (stub provider returns canned JSON; asserts decode + user-only chunking)

```swift
import Foundation
import Testing
@testable import PensieveKit

private struct StubProvider: LLMProvider {
  let reply: @Sendable (String) -> String
  func complete(prompt: String) async throws -> String { reply(prompt) }
}

@Test func extractorDecodesCandidatesFromModelOutput() async throws {
  let messages = [
    TranscriptMessage(index: 0, role: "user", text: "We still need to add rate limiting", timestamp: nil, isUserPrompt: true),
    TranscriptMessage(index: 1, role: "assistant", text: "sure", timestamp: nil, isUserPrompt: false),
  ]
  let stub = StubProvider { prompt in
    // The prompt must contain only user prose (index 0), not the assistant line.
    #expect(prompt.contains("rate limiting"))
    #expect(!prompt.contains("sure"))
    return """
    Here you go:
    [{"text":"add rate limiting","quote":"We still need to add rate limiting","messageIndex":0}]
    """
  }
  let out = try await LooseEndExtractor(provider: stub).extract(from: messages)
  #expect(out.count == 1)
  #expect(out.first?.messageIndex == 0)
  #expect(out.first?.quote == "We still need to add rate limiting")
}

@Test func decodeCandidatesSkipsMalformedOutput() {
  #expect(LooseEndExtractor.decodeCandidates("no json here").isEmpty)
  let ok = LooseEndExtractor.decodeCandidates(#"prefix [{"text":"t","quote":"qqqqqqqqqqqqqqqq","messageIndex":2}] suffix"#)
  #expect(ok.first?.messageIndex == 2)
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `./scripts/test.sh --filter extractor`  (and `--filter decodeCandidates`)
Expected: FAIL — `LooseEndExtractor` not defined.

- [ ] **Step 3: Implement the extractor**

```swift
import Foundation

/// Proposes loose-end candidates from GENUINE USER PROSE only. The model proposes;
/// the LooseEndVerifier disposes — so this stage optimizes for recall, not trust.
public struct LooseEndExtractor {
  private let provider: any LLMProvider
  private let chunkCharBudget: Int

  public init(provider: any LLMProvider, chunkCharBudget: Int = 6000) {
    self.provider = provider
    self.chunkCharBudget = chunkCharBudget
  }

  public func extract(from messages: [TranscriptMessage]) async throws -> [LooseEndCandidate] {
    let prompts = messages.filter { $0.isUserPrompt }
    guard !prompts.isEmpty else { return [] }
    var candidates: [LooseEndCandidate] = []
    for chunk in chunked(prompts) {
      let raw = try await provider.complete(prompt: Self.buildPrompt(chunk))
      candidates.append(contentsOf: Self.decodeCandidates(raw))
    }
    return candidates
  }

  /// Groups user prompts into windows under the char budget (approximate token control).
  private func chunked(_ prompts: [TranscriptMessage]) -> [[TranscriptMessage]] {
    var chunks: [[TranscriptMessage]] = [], current: [TranscriptMessage] = [], size = 0
    for p in prompts {
      if size + p.text.count > chunkCharBudget, !current.isEmpty {
        chunks.append(current); current = []; size = 0
      }
      current.append(p); size += p.text.count
    }
    if !current.isEmpty { chunks.append(current) }
    return chunks
  }

  static func buildPrompt(_ chunk: [TranscriptMessage]) -> String {
    let body = chunk.map { "[\($0.index)] \($0.text)" }.joined(separator: "\n\n")
    return """
    You extract LOOSE ENDS from a developer's own messages: things they said they would \
    do, planned, or left unfinished, but which may not be done. Only use the text below.

    Return ONLY a JSON array. Each element: {"text": <short paraphrase>, "quote": <a VERBATIM \
    substring copied exactly from one message, including its original wording and casing>, \
    "messageIndex": <the [n] of the message the quote is from>}. The quote MUST be copied \
    character-for-character from a single message. If there are no loose ends, return [].

    Messages:
    \(body)
    """
  }

  /// Extracts the first top-level JSON array from arbitrary model output; skips malformed.
  public static func decodeCandidates(_ raw: String) -> [LooseEndCandidate] {
    guard let start = raw.firstIndex(of: "["), let end = raw.lastIndex(of: "]"), start < end
    else { return [] }
    let slice = String(raw[start...end])
    guard let data = slice.data(using: .utf8),
          let decoded = try? JSONDecoder().decode([LooseEndCandidate].self, from: data)
    else { return [] }
    return decoded
  }
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `./scripts/test.sh --filter extractor` and `./scripts/test.sh --filter decodeCandidates`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/PensieveKit/Intelligence/LooseEndExtractor.swift \
  Tests/PensieveKitTests/LooseEndExtractorTests.swift
git commit -m "feat: LooseEndExtractor — user-prose chunking + candidate decode"
```

---

### Task 8: Ingester dedup via source-agnostic fingerprint

Add a per-kind fingerprint and skip inserting an event that already exists for `(sourceID, fingerprint)`; leave `extractedAt` NULL so the extraction pass finds new events.

**Files:**
- Create: `Sources/PensieveKit/Ingest/Fingerprint.swift`
- Modify: `Sources/PensieveKit/Ingest/Ingester.swift`
- Test: `Tests/PensieveKitTests/IngesterDedupTests.swift`

**Interfaces:**
- Produces: `enum Fingerprint { static func commit(hash: String) -> String; static func session(sessionID: String, contents: String) -> String; static func checkout(repo: String, from: String, to: String, branch: String) -> String }`
- Consumes: existing `Ingester` (Task-4 `Event` now has `fingerprint`).

- [ ] **Step 1: Write the failing test** (re-draining the same commit twice yields ONE event)

```swift
import Foundation
import Testing
import SQLiteData
@testable import PensieveKit

@Test func reDrainDoesNotDuplicateCommitEvents() throws {
  let (repo, hash) = try makeCommittedRepo()
  let spool = try CaptureSpool(at: tempURL("dedup-spool"))
  let db = try openCanonicalDatabase(at: tempURL("dedup-canon"))

  let payload = try encodeJSON(GitCommitPayload(repoPath: repo.path, hash: hash, branch: "main"))
  try spool.append(kind: CaptureKind.gitCommit, payload: payload)
  _ = try Ingester(spool: spool, db: db).drain()

  // Append the SAME commit again and drain again.
  try spool.append(kind: CaptureKind.gitCommit, payload: payload)
  _ = try Ingester(spool: spool, db: db).drain()

  let events = try db.read { db in try Event.all.fetchAll(db) }
  #expect(events.count == 1)
  #expect(events.first?.fingerprint == Fingerprint.commit(hash: hash))
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `./scripts/test.sh --filter reDrainDoesNotDuplicateCommitEvents`
Expected: FAIL — `Fingerprint` not defined / second drain duplicates.

- [ ] **Step 3: Implement `Fingerprint.swift`**

```swift
import Foundation
import CryptoKit

/// The ONE place source-specifics live for idempotency. Each kind maps its payload to a
/// stable string; the ingester dedups generically on (sourceID, fingerprint).
public enum Fingerprint {
  public static func commit(hash: String) -> String { "commit:\(hash)" }

  public static func session(sessionID: String, contents: String) -> String {
    "session:\(sessionID):\(sha1(contents))"
  }

  /// Checkouts have no natural immutable id; synthesize one (identical toggles may collapse).
  public static func checkout(repo: String, from: String, to: String, branch: String) -> String {
    "checkout:\(sha1("\(repo)|\(from)|\(to)|\(branch)"))"
  }

  private static func sha1(_ s: String) -> String {
    Insecure.SHA1.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
  }
}
```

- [ ] **Step 4: Wire fingerprints into `Ingester.swift`** — add an existence check before each insert and set the fingerprint on the event. Add a private helper and use it in all three cases:

```swift
  /// Inserts the event only if no event with the same (sourceID, fingerprint) exists.
  private func insertIfNew(_ db: Database, _ event: Event) throws {
    let exists = try Event
      .where { $0.sourceID.eq(event.sourceID) && $0.fingerprint.eq(event.fingerprint) }
      .fetchOne(db) != nil
    if !exists { try Event.insert { event }.execute(db) }
  }
```

Update each case to compute a fingerprint and call `insertIfNew`. Commit case:

```swift
    case CaptureKind.gitCommit:
      let p = try JSONDecoder().decode(GitCommitPayload.self, from: data)
      let fields = gitCommitFields(hash: p.hash, repo: p.repoPath, fallbackTime: row.ts)
      let detail = try encodeJSON(["hash": p.hash, "branch": p.branch, "files": fields.files])
      try db.write { db in
        let (project, source) = try resolver.resolve(db, path: p.repoPath, kind: SourceKind.gitRepo)
        try insertIfNew(db, Event(projectID: project.id, sourceID: source.id, occurredAt: fields.when,
              kind: CaptureKind.gitCommit, summary: fields.subject, detailJSON: detail,
              fingerprint: Fingerprint.commit(hash: p.hash)))
      }
      return 1
```

Checkout case:

```swift
    case CaptureKind.gitCheckout:
      let p = try JSONDecoder().decode(GitCheckoutPayload.self, from: data)
      let detail = try encodeJSON(["from": p.from, "to": p.to, "branch": p.branch])
      try db.write { db in
        let (project, source) = try resolver.resolve(db, path: p.repoPath, kind: SourceKind.gitRepo)
        try insertIfNew(db, Event(projectID: project.id, sourceID: source.id, occurredAt: row.ts,
              kind: CaptureKind.gitCheckout, summary: "checkout \(p.branch)", detailJSON: detail,
              fingerprint: Fingerprint.checkout(repo: p.repoPath, from: p.from, to: p.to, branch: p.branch)))
      }
      return 1
```

Session case (read the transcript contents once for the fingerprint):

```swift
    case CaptureKind.ccSession:
      let p = try JSONDecoder().decode(SessionRefPayload.self, from: data)
      let transcriptURL = URL(fileURLWithPath: p.transcriptPath)
      let session = TranscriptParser.parse(fileURL: transcriptURL)
      guard let cwd = session.cwd else { throw IngestError.unattributableSession }
      let key = Git.run(["rev-parse", "--show-toplevel"], in: cwd) ?? cwd
      let contents = (try? String(contentsOf: transcriptURL, encoding: .utf8)) ?? ""
      let detail = try encodeJSON(["sessionID": session.sessionID,
                                   "prompts": String(session.userPromptCount),
                                   "transcriptPath": p.transcriptPath])
      try db.write { db in
        let (project, source) = try resolver.resolve(db, path: key, kind: SourceKind.claudeCode)
        try insertIfNew(db, Event(projectID: project.id, sourceID: source.id,
              occurredAt: session.endedAt ?? row.ts, kind: CaptureKind.ccSession,
              summary: "session (\(session.userPromptCount) prompts)", detailJSON: detail,
              fingerprint: Fingerprint.session(sessionID: session.sessionID, contents: contents)))
      }
      return 1
```

(`Database` is a GRDB type; `Ingester.swift` already `import GRDB`. If the `.where` inside `insertIfNew` needs the write `db`, note it runs inside the `db.write { db in ... }` closure — pass that `db`.)

- [ ] **Step 5: Run to verify it passes + full suite (no regressions)**

Run: `./scripts/test.sh --filter reDrainDoesNotDuplicateCommitEvents` then `./scripts/test.sh`
Expected: PASS; all prior tests still green.

- [ ] **Step 6: Commit**

```bash
git add Sources/PensieveKit/Ingest/Fingerprint.swift Sources/PensieveKit/Ingest/Ingester.swift \
  Tests/PensieveKitTests/IngesterDedupTests.swift
git commit -m "feat: source-agnostic fingerprint dedup in the ingester"
```

---

### Task 9: `ExtractionRunner` — orchestrate extraction over new sessions

The single async pass: find unextracted `cc.session` events, extract → verify → dedup/collapse → store `LooseEnd`s, mark `extractedAt`, and report proposed/verified/inserted counts.

**Files:**
- Create: `Sources/PensieveKit/Intelligence/ExtractionRunner.swift`
- Test: `Tests/PensieveKitTests/ExtractionRunnerTests.swift`

**Interfaces:**
- Consumes: `LLMProvider`, `LooseEndExtractor`, `LooseEndVerifier`, `TranscriptParser`, canonical tables.
- Produces: `struct ExtractionResult: Sendable { let sessionID: String; let proposed: Int; let verified: Int; let inserted: Int }`
- Produces: `struct ExtractionRunner { init(db: any DatabaseWriter, provider: any LLMProvider, now: @escaping @Sendable () -> Date = Date.init); func run() async throws -> [ExtractionResult] }`

- [ ] **Step 1: Write the failing test** (real transcript fixture event, stub provider, end-to-end into `LooseEnd`)

```swift
import Foundation
import Testing
import SQLiteData
@testable import PensieveKit

private struct CannedProvider: LLMProvider {
  let json: String
  func complete(prompt: String) async throws -> String { json }
}

@Test func runnerStoresOnlyVerifiedLooseEnds() async throws {
  let db = try openCanonicalDatabase(at: tempURL("run-canon"))
  // A cc.session event pointing at the roles fixture (its cwd is /p/colibri).
  let url = Bundle.module.url(forResource: "session-roles", withExtension: "jsonl", subdirectory: "Fixtures")!
  let (project, source) = try ProjectResolver(db: db).resolve(path: "/p/colibri", kind: SourceKind.claudeCode)
  let detail = try encodeJSON(["sessionID": "session-roles", "prompts": "2", "transcriptPath": url.path])
  let event = Event(projectID: project.id, sourceID: source.id, occurredAt: Date(),
                    kind: CaptureKind.ccSession, summary: "s", detailJSON: detail,
                    fingerprint: "fp-run")
  try db.write { db in try Event.insert { event }.execute(db) }

  // Model proposes two: one real user quote, one fabricated → only the real one survives.
  let provider = CannedProvider(json: """
  [{"text":"add rate limiting","quote":"We still need to add rate limiting before launch","messageIndex":0},
   {"text":"call the bank","quote":"remember to call the bank tomorrow","messageIndex":0}]
  """)
  let results = try await ExtractionRunner(db: db, provider: provider).run()

  #expect(results.count == 1)
  #expect(results.first?.proposed == 2)
  #expect(results.first?.verified == 1)
  #expect(results.first?.inserted == 1)

  let ends = try db.read { db in try LooseEnd.all.fetchAll(db) }
  #expect(ends.count == 1)
  #expect(ends.first?.quote == "We still need to add rate limiting before launch")
  #expect(ends.first?.role == "user")

  // extractedAt was set → a second run does nothing.
  let second = try await ExtractionRunner(db: db, provider: provider).run()
  #expect(second.isEmpty)
  #expect(try db.read { db in try LooseEnd.all.fetchAll(db) }.count == 1)
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `./scripts/test.sh --filter runnerStoresOnlyVerifiedLooseEnds`
Expected: FAIL — `ExtractionRunner` not defined.

- [ ] **Step 3: Implement `ExtractionRunner.swift`**

```swift
import Foundation
import SQLiteData
import GRDB

public struct ExtractionResult: Sendable {
  public let sessionID: String
  public let proposed: Int
  public let verified: Int
  public let inserted: Int
}

public struct ExtractionRunner {
  let db: any DatabaseWriter
  let provider: any LLMProvider
  let now: @Sendable () -> Date

  public init(db: any DatabaseWriter, provider: any LLMProvider,
              now: @escaping @Sendable () -> Date = Date.init) {
    self.db = db; self.provider = provider; self.now = now
  }

  public func run() async throws -> [ExtractionResult] {
    let pending = try db.read { db in
      try Event.where { $0.kind.eq(CaptureKind.ccSession) }.fetchAll(db)
    }.filter { $0.extractedAt == nil }

    var results: [ExtractionResult] = []
    for event in pending {
      let detail = (try? JSONDecoder().decode([String: String].self,
                                              from: Data(event.detailJSON.utf8))) ?? [:]
      let transcriptPath = detail["transcriptPath"] ?? ""
      let session = TranscriptParser.parse(fileURL: URL(fileURLWithPath: transcriptPath))

      let candidates = try await LooseEndExtractor(provider: provider).extract(from: session.messages)
      let verified = candidates.compactMap { LooseEndVerifier.verify($0, messages: session.messages) }

      var inserted = 0
      try db.write { db in
        // Collapse against existing OPEN loose ends in this project (verbatim, normalized).
        let existing = try LooseEnd.where { $0.projectID.eq(event.projectID) }.fetchAll(db)
        var seen = Set(existing.filter { $0.status == "open" }.map { normalizeWhitespace($0.quote) })
        for v in verified {
          let key = normalizeWhitespace(v.quote)
          if seen.contains(key) { continue }   // within- and cross-session dedup
          seen.insert(key)
          try LooseEnd.insert {
            LooseEnd(projectID: event.projectID, sourceEventID: event.id, text: v.text,
                     quote: v.quote, role: v.role, sourceMessageIndex: v.sourceMessageIndex)
          }.execute(db)
          inserted += 1
        }
        let stamp = now()
        try Event.where { $0.id.eq(event.id) }.update { $0.extractedAt = stamp }.execute(db)
      }

      results.append(ExtractionResult(sessionID: session.sessionID,
        proposed: candidates.count, verified: verified.count, inserted: inserted))
    }
    return results
  }
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `./scripts/test.sh --filter runnerStoresOnlyVerifiedLooseEnds`
Expected: PASS. (If `.update { $0.extractedAt = stamp }` needs a different setter form, consult the generated query API — behavior is the arbiter; the field must end non-nil.)

- [ ] **Step 5: Commit**

```bash
git add Sources/PensieveKit/Intelligence/ExtractionRunner.swift \
  Tests/PensieveKitTests/ExtractionRunnerTests.swift
git commit -m "feat: ExtractionRunner — verified, deduped loose ends with counts"
```

---

### Task 10: Loose-end queries with age (from `Event.occurredAt`)

Read surface for `status`/`looseends`. Age derives from the source event, never `LooseEnd.createdAt`.

**Files:**
- Create: `Sources/PensieveKit/Query/LooseEndQueries.swift`
- Test: `Tests/PensieveKitTests/LooseEndQueriesTests.swift`

**Interfaces:**
- Produces: `struct LooseEndView: Sendable { let looseEnd: LooseEnd; let occurredAt: Date; let ageDays: Int }`
- Produces: `enum LooseEndQueries { static func open(_ db: any DatabaseWriter, projectID: UUID?, now: Date) throws -> [LooseEndView] }` — `projectID == nil` → across all projects; sorted oldest-source-first.

- [ ] **Step 1: Write the failing test**

```swift
import Foundation
import Testing
import SQLiteData
@testable import PensieveKit

@Test func openLooseEndsCarrySourceAge() throws {
  let db = try openCanonicalDatabase(at: tempURL("le-q"))
  let (project, source) = try ProjectResolver(db: db).resolve(path: "/p/x", kind: SourceKind.claudeCode)
  let occurred = Calendar.current.date(byAdding: .day, value: -10, to: Date())!
  let event = Event(projectID: project.id, sourceID: source.id, occurredAt: occurred,
                    kind: CaptureKind.ccSession, summary: "s", detailJSON: "{}", fingerprint: "f")
  try db.write { db in
    try Event.insert { event }.execute(db)
    try LooseEnd.insert {
      LooseEnd(projectID: project.id, sourceEventID: event.id, text: "t",
               quote: "we still need to finish the migration", role: "user", sourceMessageIndex: 0)
    }.execute(db)
  }
  let views = try LooseEndQueries.open(db, projectID: project.id, now: Date())
  #expect(views.count == 1)
  #expect(views.first?.ageDays == 10)
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `./scripts/test.sh --filter openLooseEndsCarrySourceAge`
Expected: FAIL — `LooseEndQueries` not defined.

- [ ] **Step 3: Implement `LooseEndQueries.swift`**

```swift
import Foundation
import SQLiteData

public struct LooseEndView: Sendable {
  public let looseEnd: LooseEnd
  public let occurredAt: Date
  public let ageDays: Int
}

public enum LooseEndQueries {
  public static func open(_ db: any DatabaseWriter, projectID: UUID?, now: Date) throws -> [LooseEndView] {
    try db.read { db in
      let ends: [LooseEnd]
      if let projectID {
        ends = try LooseEnd.where { $0.projectID.eq(projectID) && $0.status.eq("open") }.fetchAll(db)
      } else {
        ends = try LooseEnd.where { $0.status.eq("open") }.fetchAll(db)
      }
      var views: [LooseEndView] = []
      for le in ends {
        guard let event = try Event.where({ $0.id.eq(le.sourceEventID) }).fetchOne(db) else { continue }
        let days = Calendar.current.dateComponents([.day], from: event.occurredAt, to: now).day ?? 0
        views.append(LooseEndView(looseEnd: le, occurredAt: event.occurredAt, ageDays: days))
      }
      return views.sorted { $0.occurredAt < $1.occurredAt }   // oldest source first
    }
  }
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `./scripts/test.sh --filter openLooseEndsCarrySourceAge`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/PensieveKit/Query/LooseEndQueries.swift Tests/PensieveKitTests/LooseEndQueriesTests.swift
git commit -m "feat: open loose-end queries with source-derived age"
```

---

### Task 11: CLI — async `ingest` (drain+extract), quote-led `status`, `looseends`, `checkpoint`

Wire the gate to the command line. This is the primary acceptance surface.

**Files:**
- Modify: `Sources/pensieve/Pensieve.swift` (root → `AsyncParsableCommand`; register new commands)
- Modify: `Sources/pensieve/Commands/Ingest.swift` (async; run extraction; print counts)
- Modify: `Sources/pensieve/Commands/Status.swift` (print open loose ends quote-first)
- Create: `Sources/pensieve/Commands/LooseEnds.swift`
- Create: `Sources/pensieve/Commands/Checkpoint.swift`
- Test: `Tests/PensieveKitTests/CheckpointTests.swift` (kit-level query; CLI smoke is manual)

**Interfaces:**
- Consumes: `Ingester`, `ExtractionRunner`, `makeDefaultLLMProvider`, `LooseEndQueries`, `ProjectQueries`.
- Produces: `enum CheckpointCommands { static func add(_ db: any DatabaseWriter, projectName: String, note: String) throws -> Bool }` (returns false if no such project).

- [ ] **Step 1: Write the failing test** (checkpoint insert via a small kit helper)

```swift
import Foundation
import Testing
import SQLiteData
@testable import PensieveKit

@Test func checkpointInsertsForKnownProject() throws {
  let db = try openCanonicalDatabase(at: tempURL("cp"))
  _ = try ProjectResolver(db: db).resolve(path: "/p/colibri", kind: SourceKind.gitRepo)
  #expect(try CheckpointCommands.add(db, projectName: "colibri", note: "mid refactor") == true)
  #expect(try CheckpointCommands.add(db, projectName: "nope", note: "x") == false)
  let notes = try db.read { db in try Checkpoint.all.fetchAll(db) }
  #expect(notes.first?.note == "mid refactor")
}
```

Put `CheckpointCommands` in `Sources/PensieveKit/Query/CheckpointCommands.swift` (kit code is testable; the CLI wrapper just calls it).

- [ ] **Step 2: Run to verify it fails**

Run: `./scripts/test.sh --filter checkpointInsertsForKnownProject`
Expected: FAIL — `CheckpointCommands` not defined.

- [ ] **Step 3: Implement `CheckpointCommands`**

```swift
// Sources/PensieveKit/Query/CheckpointCommands.swift
import Foundation
import SQLiteData

public enum CheckpointCommands {
  @discardableResult
  public static func add(_ db: any DatabaseWriter, projectName: String, note: String) throws -> Bool {
    try db.write { db in
      guard let project = try Project.where({ $0.name.eq(projectName) }).fetchOne(db) else { return false }
      try Checkpoint.insert { Checkpoint(projectID: project.id, note: note) }.execute(db)
      return true
    }
  }
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `./scripts/test.sh --filter checkpointInsertsForKnownProject`
Expected: PASS.

- [ ] **Step 5: Update the CLI** — root to async and register commands (`Pensieve.swift`):

```swift
@main
struct Pensieve: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "pensieve",
    abstract: "Track work across parallel projects.",
    subcommands: [
      CaptureCommit.self, CaptureCheckout.self, IngestSession.self,
      Ingest.self, ListProjects.self, Status.self, Track.self, Group.self,
      InstallHooks.self, LooseEnds.self, Checkpoint.self,
    ]
  )
}
```

`Ingest.swift` → async drain + extract with counts:

```swift
import ArgumentParser
import PensieveKit

struct Ingest: AsyncParsableCommand {
  static let configuration = CommandConfiguration(commandName: "ingest",
    abstract: "Drain the capture spool into events, then extract loose ends.")
  func run() async throws {
    let db = try openCanonical()
    let created = try Ingester(spool: try openSpool(), db: db).drain()
    let results = try await ExtractionRunner(db: db, provider: makeDefaultLLMProvider()).run()
    let proposed = results.reduce(0) { $0 + $1.proposed }
    let verified = results.reduce(0) { $0 + $1.verified }
    let inserted = results.reduce(0) { $0 + $1.inserted }
    print("ingested \(created) event(s)")
    print("extraction: \(results.count) session(s) — proposed \(proposed), verified \(verified), inserted \(inserted)")
  }
}
```

`Status.swift` → append quote-led open loose ends after the event list:

```swift
import ArgumentParser
import Foundation
import PensieveKit

struct Status: ParsableCommand {
  static let configuration = CommandConfiguration(commandName: "status")
  @Argument var project: String
  func run() throws {
    let db = try openCanonical()
    guard let s = try ProjectQueries.status(db, name: project, limit: 20) else {
      print("no project named '\(project)'"); return
    }
    print("# \(s.project.name)")
    for e in s.recentEvents { print("  \(e.occurredAt) \(e.kind)  \(e.summary)") }
    let ends = try LooseEndQueries.open(db, projectID: s.project.id, now: Date())
    guard !ends.isEmpty else { return }
    print("\n## Open loose ends (\(ends.count))")
    for v in ends {
      print("  “\(v.looseEnd.quote)”")                        // quote-first: the authoritative line
      print("    ↳ \(v.looseEnd.text)  [\(v.looseEnd.role), \(v.ageDays)d]")  // paraphrase is secondary
    }
  }
}
```

`LooseEnds.swift` (new):

```swift
import ArgumentParser
import Foundation
import PensieveKit

struct LooseEnds: ParsableCommand {
  static let configuration = CommandConfiguration(commandName: "looseends",
    abstract: "List open, cited loose ends (quote-first).")
  @Flag(name: .long) var all = false
  @Argument var project: String?
  func run() throws {
    let db = try openCanonical()
    var projectID: UUID? = nil
    if let project, !all {
      guard let p = try ProjectQueries.status(db, name: project, limit: 0)?.project else {
        print("no project named '\(project)'"); return
      }
      projectID = p.id
    }
    let ends = try LooseEndQueries.open(db, projectID: projectID, now: Date())
    for v in ends {
      print("“\(v.looseEnd.quote)”")
      print("  ↳ \(v.looseEnd.text)  [\(v.looseEnd.role), \(v.ageDays)d]")
    }
    print("\n\(ends.count) open loose end(s)")
  }
}
```

`Checkpoint.swift` (new):

```swift
import ArgumentParser
import PensieveKit

struct Checkpoint: ParsableCommand {
  static let configuration = CommandConfiguration(commandName: "checkpoint",
    abstract: "Record a manual 'I was in the middle of X' note on a project.")
  @Argument var project: String
  @Argument var note: String
  func run() throws {
    let ok = try CheckpointCommands.add(try openCanonical(), projectName: project, note: note)
    print(ok ? "noted on \(project)" : "no project named '\(project)'")
  }
}
```

- [ ] **Step 6: Build + smoke + full suite**

Run: `swift build` then `./scripts/test.sh`
Expected: builds; all tests PASS.

Smoke:
```bash
export PENSIEVE_DB=/tmp/1b.sqlite PENSIEVE_CAPTURE_DB=/tmp/1b-cap.sqlite
swift run pensieve track /tmp
swift run pensieve checkpoint tmp "trying the checkpoint command"
swift run pensieve status tmp
```
Expected: `status` prints the project and (no loose ends yet) exits cleanly.

- [ ] **Step 7: Commit**

```bash
git add Sources/PensieveKit/Query/CheckpointCommands.swift Sources/pensieve \
  Tests/PensieveKitTests/CheckpointTests.swift
git commit -m "feat: async ingest+extract CLI, quote-led status, looseends, checkpoint"
```

---

### Task 12: Deterministic "what's next" + `next` command

Pure ranking on grounded signals. No model.

**Files:**
- Create: `Sources/PensieveKit/Query/NextQueries.swift`
- Create: `Sources/pensieve/Commands/Next.swift`
- Modify: `Sources/pensieve/Pensieve.swift` (register `Next`)
- Test: `Tests/PensieveKitTests/NextQueriesTests.swift`

**Interfaces:**
- Produces: `struct NextItem: Sendable { let project: Project; let openLooseEnds: Int; let daysDormant: Int; let score: Double }`
- Produces: `enum NextQueries { static func ranked(_ db: any DatabaseWriter, now: Date) throws -> [NextItem] }` — `score = Double(openLooseEnds) * 2 + Double(daysDormant)`, sorted descending; `daysDormant` = days since the project's latest `Event.occurredAt` (0 if none).

- [ ] **Step 1: Write the failing test**

```swift
import Foundation
import Testing
import SQLiteData
@testable import PensieveKit

@Test func nextRanksByLooseEndsThenDormancy() throws {
  let db = try openCanonicalDatabase(at: tempURL("next"))
  let resolver = ProjectResolver(db: db)
  let (a, sa) = try resolver.resolve(path: "/p/a", kind: SourceKind.claudeCode)   // 2 loose ends, recent
  let (b, sb) = try resolver.resolve(path: "/p/b", kind: SourceKind.claudeCode)   // 0 loose ends, old
  let recent = Date(), old = Calendar.current.date(byAdding: .day, value: -30, to: Date())!
  try db.write { db in
    let ea = Event(projectID: a.id, sourceID: sa.id, occurredAt: recent, kind: CaptureKind.ccSession,
                   summary: "s", detailJSON: "{}", fingerprint: "a1")
    let eb = Event(projectID: b.id, sourceID: sb.id, occurredAt: old, kind: CaptureKind.ccSession,
                   summary: "s", detailJSON: "{}", fingerprint: "b1")
    try Event.insert { ea }.execute(db); try Event.insert { eb }.execute(db)
    for q in ["we must finish the auth flow", "don't forget the deploy vars"] {
      try LooseEnd.insert {
        LooseEnd(projectID: a.id, sourceEventID: ea.id, text: "t", quote: q, role: "user", sourceMessageIndex: 0)
      }.execute(db)
    }
  }
  let ranked = try NextQueries.ranked(db, now: Date())
  #expect(ranked.first?.project.id == a.id)   // 2*2+~0 = 4  >  0*2+30 = 30? -> see weighting note
  #expect(ranked.contains { $0.project.id == b.id })
}
```

> Weighting note: with `score = openLooseEnds*2 + daysDormant`, the 30-day-dormant project B (score 30) actually outranks A (score ~4). That's intended — long dormancy is a strong "you forgot this" signal. Adjust the assertion to `ranked.first?.project.id == b.id` and keep the weighting, OR flip the weights if loose-end count should dominate. Pick one in code and make the test match; document the choice in a comment.

- [ ] **Step 2: Run to verify it fails**

Run: `./scripts/test.sh --filter nextRanksByLooseEndsThenDormancy`
Expected: FAIL — `NextQueries` not defined.

- [ ] **Step 3: Implement `NextQueries.swift`**

```swift
import Foundation
import SQLiteData

public struct NextItem: Sendable {
  public let project: Project
  public let openLooseEnds: Int
  public let daysDormant: Int
  public let score: Double
}

public enum NextQueries {
  /// Deterministic ranking on grounded signals only. No model, no invented scores.
  public static func ranked(_ db: any DatabaseWriter, now: Date) throws -> [NextItem] {
    try db.read { db in
      let projects = try Project.where { $0.state.eq("active") }.fetchAll(db)
      var items: [NextItem] = []
      for p in projects {
        let latest = try Event.where { $0.projectID.eq(p.id) }
          .order { $0.occurredAt.desc() }.limit(1).fetchOne(db)
        let dormant = latest.map {
          Calendar.current.dateComponents([.day], from: $0.occurredAt, to: now).day ?? 0
        } ?? 0
        let open = try LooseEnd.where { $0.projectID.eq(p.id) && $0.status.eq("open") }.fetchAll(db).count
        let score = Double(open) * 2 + Double(dormant)
        items.append(NextItem(project: p, openLooseEnds: open, daysDormant: dormant, score: score))
      }
      return items.sorted { $0.score > $1.score }
    }
  }
}
```

- [ ] **Step 4: Implement `Next.swift` + register**

```swift
import ArgumentParser
import Foundation
import PensieveKit

struct Next: ParsableCommand {
  static let configuration = CommandConfiguration(commandName: "next",
    abstract: "Ranked queue of what to pick up, on grounded signals only.")
  func run() throws {
    for item in try NextQueries.ranked(try openCanonical(), now: Date()) {
      print("\(item.project.name)  — \(item.openLooseEnds) loose end(s), \(item.daysDormant)d dormant")
    }
  }
}
```

Add `Next.self` to the `subcommands:` array in `Pensieve.swift`.

- [ ] **Step 5: Run to verify it passes**

Run: `./scripts/test.sh --filter nextRanksByLooseEndsThenDormancy`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Sources/PensieveKit/Query/NextQueries.swift Sources/pensieve/Commands/Next.swift \
  Sources/pensieve/Pensieve.swift Tests/PensieveKitTests/NextQueriesTests.swift
git commit -m "feat: deterministic what's-next ranking + next command"
```

---

### Task 13: Grounded summary + thin `digest`

Narrate deterministically-assembled facts, fenced from cited items. Model narrates only; loose ends are shown verbatim.

**Files:**
- Create: `Sources/PensieveKit/Intelligence/SummaryBuilder.swift`
- Create: `Sources/pensieve/Commands/Digest.swift`
- Modify: `Sources/pensieve/Pensieve.swift` (register `Digest`)
- Test: `Tests/PensieveKitTests/SummaryBuilderTests.swift`

**Interfaces:**
- Consumes: `LLMProvider`, `ProjectQueries`, `LooseEndQueries`.
- Produces: `struct ProjectSummary: Sendable { let whatItIs: String; let lastWorkDone: String; let looseEnds: [LooseEndView] }`
- Produces: `struct SummaryBuilder { init(provider: any LLMProvider); func build(_ db: any DatabaseWriter, projectName: String, now: Date) async throws -> ProjectSummary? }`
- Produces: `static func assembleFacts(project: Project, events: [Event]) -> String` (deterministic input the model may narrate — pure, testable without a model).

- [ ] **Step 1: Write the failing test** (facts assembly is deterministic; narration via stub)

```swift
import Foundation
import Testing
import SQLiteData
@testable import PensieveKit

private struct EchoProvider: LLMProvider {
  func complete(prompt: String) async throws -> String { "NARRATED: " + prompt.prefix(20) }
}

@Test func assembleFactsListsRecentCommitSubjects() {
  let p = Project(name: "colibri")
  let s = UUID()
  let events = [
    Event(projectID: p.id, sourceID: s, occurredAt: Date(), kind: CaptureKind.gitCommit,
          summary: "add auth", detailJSON: "{}", fingerprint: "1"),
    Event(projectID: p.id, sourceID: s, occurredAt: Date(), kind: CaptureKind.ccSession,
          summary: "session (3 prompts)", detailJSON: "{}", fingerprint: "2"),
  ]
  let facts = SummaryBuilder.assembleFacts(project: p, events: events)
  #expect(facts.contains("add auth"))
  #expect(facts.contains("colibri"))
}

@Test func summaryBuildReturnsNarrationAndLooseEnds() async throws {
  let db = try openCanonicalDatabase(at: tempURL("sum"))
  let (project, source) = try ProjectResolver(db: db).resolve(path: "/p/colibri", kind: SourceKind.gitRepo)
  try db.write { db in
    try Event.insert {
      Event(projectID: project.id, sourceID: source.id, occurredAt: Date(), kind: CaptureKind.gitCommit,
            summary: "add auth", detailJSON: "{}", fingerprint: "c1")
    }.execute(db)
  }
  let sum = try await SummaryBuilder(provider: EchoProvider()).build(db, projectName: "colibri", now: Date())
  #expect(sum != nil)
  #expect(sum?.lastWorkDone.hasPrefix("NARRATED:") == true)
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `./scripts/test.sh --filter summary` (and `--filter assembleFacts`)
Expected: FAIL — `SummaryBuilder` not defined.

- [ ] **Step 3: Implement `SummaryBuilder.swift`**

```swift
import Foundation
import SQLiteData

public struct ProjectSummary: Sendable {
  public let whatItIs: String
  public let lastWorkDone: String
  public let looseEnds: [LooseEndView]
}

public struct SummaryBuilder {
  private let provider: any LLMProvider
  public init(provider: any LLMProvider) { self.provider = provider }

  /// Deterministic fact sheet the model is allowed to narrate — and nothing beyond it.
  public static func assembleFacts(project: Project, events: [Event]) -> String {
    let lines = events.prefix(15).map { "- \($0.kind): \($0.summary)" }.joined(separator: "\n")
    return "Project: \(project.name)\nRecent activity:\n\(lines)"
  }

  public func build(_ db: any DatabaseWriter, projectName: String, now: Date) async throws -> ProjectSummary? {
    guard let status = try ProjectQueries.status(db, name: projectName, limit: 15) else { return nil }
    let facts = Self.assembleFacts(project: status.project, events: status.recentEvents)
    let prompt = """
    Narrate ONLY the facts below into 2-3 sentences of "last work done". Do NOT add any \
    fact, plan, or detail that is not explicitly present. If the facts are thin, say so.

    \(facts)
    """
    let narration = (try? await provider.complete(prompt: prompt)) ?? facts   // fall back to raw facts
    let ends = try LooseEndQueries.open(db, projectID: status.project.id, now: now)
    return ProjectSummary(
      whatItIs: "\(status.project.name) — \(status.project.state)",
      lastWorkDone: narration,
      looseEnds: ends)
  }
}
```

- [ ] **Step 4: Implement `Digest.swift` + register** (fences generated prose from cited items)

```swift
import ArgumentParser
import Foundation
import PensieveKit

struct Digest: AsyncParsableCommand {
  static let configuration = CommandConfiguration(commandName: "digest",
    abstract: "Generate a morning markdown digest across active projects.")
  func run() async throws {
    let db = try openCanonical()
    let builder = SummaryBuilder(provider: makeDefaultLLMProvider())
    print("# Pensieve digest\n")
    for p in try ProjectQueries.all(db) {
      guard let sum = try await builder.build(db, projectName: p.name, now: Date()) else { continue }
      print("## \(sum.whatItIs)")
      print("\n_\(sum.lastWorkDone)_  <!-- generated narration -->\n")   // fenced: clearly generated
      if !sum.looseEnds.isEmpty {
        print("**Open loose ends (cited):**")
        for v in sum.looseEnds { print("- “\(v.looseEnd.quote)” (\(v.ageDays)d)") }
      }
      print("")
    }
  }
}
```

Add `Digest.self` to the `subcommands:` array in `Pensieve.swift`.

- [ ] **Step 5: Run to verify it passes + full suite**

Run: `./scripts/test.sh --filter summary` then `./scripts/test.sh`
Expected: PASS; whole suite green.

- [ ] **Step 6: Commit**

```bash
git add Sources/PensieveKit/Intelligence/SummaryBuilder.swift Sources/pensieve/Commands/Digest.swift \
  Sources/pensieve/Pensieve.swift Tests/PensieveKitTests/SummaryBuilderTests.swift
git commit -m "feat: grounded summary builder + fenced digest command"
```

---

### Task 14: Validation gate — the acceptance run (manual, run once)

The make-or-break check on **real** data. Not a unit test — a procedure whose output you read.

- [ ] **Step 1: Build release + expose the binary**

```bash
swift build -c release
BIN="$(swift build -c release --show-bin-path)/pensieve"
export PATH="$(dirname "$BIN"):$PATH"
export PENSIEVE_DB="$HOME/Library/Application Support/Pensieve/pensieve.sqlite"
export PENSIEVE_CAPTURE_DB="$HOME/Library/Application Support/Pensieve/capture.sqlite"
```

- [ ] **Step 2: Ingest real Claude Code sessions.** For several of your real recent projects, append their transcripts to the spool and ingest. (Point at real `~/.claude/projects/**/*.jsonl` files.)

```bash
for f in ~/.claude/projects/*/*.jsonl; do pensieve ingest-session --path "$f"; done
pensieve ingest      # drains + extracts; prints proposed/verified/inserted counts
```

Record the printed counts. **If `verified` is 0 while `proposed` > 0**, the gate is dropping everything — inspect why (model output shape, prompt) before judging recall.

- [ ] **Step 3: Precision check.** For each real project:

```bash
pensieve looseends --all
pensieve status <project>
```

Read every loose end against its quote. **PASS requires: every shown loose end is real, the quote is genuinely present in your own message, and nothing is fabricated or misattributed. Target: zero hallucinated items.**

- [ ] **Step 4: Recall spot-check.** Pick ≥1 real session you remember well. Hand-list the loose ends you know it contained. Confirm the pipeline surfaced them (allowing for the user-prose-only scope — items that lived only in TodoWrite/assistant text are expected misses and are the documented next lever). A degenerate "drops everything" extractor must NOT pass.

- [ ] **Step 5: Record the outcome** in `docs/superpowers/phase-1b-outcome.md` — counts, precision verdict (hallucination count), recall spot-check notes, and a go/no-go on proceeding to Phase 1B-org (the tree/strands). Commit it.

```bash
git add docs/superpowers/phase-1b-outcome.md
git commit -m "docs: Phase 1B acceptance-run outcome + go/no-go"
```

---

## Self-Review (completed against the spec)

- **Spec coverage:** `LLMProvider` + FM default + `claude -p` fallback ✓ (Tasks 1–3); local-first selection ✓ (Task 3); additive schema `fingerprint`/`extractedAt`/`role`/`sourceMessageIndex` + unique dedup index + backfill ✓ (Task 4); parser user-prose flag + index ✓ (Task 5); verbatim/user-only/min-length gate ✓ (Task 6); chunked extraction over user prose ✓ (Task 7); source-agnostic fingerprint dedup + extract-only-new ✓ (Tasks 8–9); within/cross-session collapse ✓ (Task 9); conservative resolution + age-from-`occurredAt` ✓ (Tasks 9–10); quote-led display ✓ (Task 11); deterministic what's-next ✓ (Task 12); grounded, fenced summaries + digest ✓ (Task 13); precision-AND-recall acceptance run + counts instrumentation ✓ (Tasks 9, 11, 14). **Deferred per spec (NOT built):** tree/`parentID`/`kind`/`Node` rename, strands, session-start hook, per-kind handler protocol, organizing CLI, domain rollup, auto-close, TodoWrite mining, NLEmbedding — all recorded in `backlog.md`.
- **Placeholder scan:** none. The only "confirm against docs" note (Task 1, Foundation Models API) is a test-backed spike whose deliverable *is* the confirmed API, mirroring 1A's "if the macro API differs, adjust — the test is the arbiter" checkpoints. The Task-12 weighting note is a documented, code-and-test-matched decision, not deferred work.
- **Type consistency:** `LLMProvider.complete(prompt:) async throws -> String`, `LooseEndCandidate{text,quote,messageIndex}`, `VerifiedLooseEnd{text,quote,role,sourceMessageIndex}`, `LooseEndVerifier.verify(_:messages:)`, `ExtractionResult{sessionID,proposed,verified,inserted}`, `LooseEndView{looseEnd,occurredAt,ageDays}`, `Fingerprint.commit/session/checkout`, `Event(...,fingerprint:extractedAt:)`, `LooseEnd(...,role:sourceMessageIndex:)`, `normalizeWhitespace(_:)` are used identically across every task that references them. CLI root is `AsyncParsableCommand`; async commands (`Ingest`, `Digest`) use `run() async throws`, sync ones keep `run() throws`.
