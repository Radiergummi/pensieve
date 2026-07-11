# MCP `recall` tool Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Expose a loose end's surrounding transcript window over MCP so `recall` no longer requires shelling out to grep `.jsonl` transcripts.

**Architecture:** A read-only MCP tool `recall(loose_end_id, radius?)` wraps the existing, tested `ProvenanceQueries.context(radius:)` kernel via a new thin `SessionContextQueries.recall(...)` that shapes a Codable `RecallBundle`. `project_context` loose ends gain an additive `id` handle. No LLM, verbatim only — inside the trust gate. All logic lives in tested PensieveKit; the `pensieve mcp` command layer stays thin.

**Tech Stack:** Swift 6, SwiftPM package (`PensieveKit` + `pensieve` CLI), SQLiteData (GRDB), the MCP Swift SDK (`MCP`), Swift Testing.

## Global Constraints

- **Test runner:** `./scripts/test.sh --filter <name>` (thin `swift test` passthrough). Plain `swift test` also works.
- **SQLiteData predicates use `.eq(x)`, NOT `== x`** (e.g. `.where { $0.id.eq(id) }`). `==` is `unavailable`.
- **No Python, ever. Swift only.**
- **Trust gate is sacred:** recall returns only verbatim captured transcript text or an honest `transcriptAvailable: false` + the stored quote. No model in the loop, no fabrication.
- **`ProvenanceQueries` is NOT to be modified** — it already takes a `radius` and already handles missing/stale/gone transcripts.
- **Kind strings live in `CaptureKind`/`SourceKind`** (`CapturePayloads.swift`) — reuse constants.
- **Do not use a shared mutable `static ISO8601DateFormatter`** — the existing `makeEncoder()` sets `.iso8601` per-call; reuse it.
- **The `pensieve` CLI / MCP layer has no unit tests** — verify Task 3 with `swift build`. Kernel tests (Tasks 1–2) carry the coverage.

---

### Task 1: Expose loose-end `id` on `project_context` output

Additive handle so the model can pass a specific loose end to `recall`.

**Files:**
- Modify: `Sources/PensieveKit/Query/SessionContextQueries.swift` (the `BundleLooseEnd` struct ~lines 6–11, and the `looseEnds.map` in `bundle(...)` ~line 101)
- Test: `Tests/PensieveKitTests/SessionContextQueriesTests.swift`

**Interfaces:**
- Consumes: existing `LooseEnd` model (has `public let id: UUID`), existing `LooseEndQueries.open(...) -> [(looseEnd: LooseEnd, ageDays: Int)]`.
- Produces: `BundleLooseEnd` gains `public let id: UUID` as its first field.

- [ ] **Step 1: Write the failing test**

Add to `Tests/PensieveKitTests/SessionContextQueriesTests.swift`:

```swift
@Test func bundleLooseEndCarriesItsID() async throws {
  let db = try openCanonicalDatabase(at: tempURL("sc"))
  let (node, event) = try seedOneNode(db)
  // The one loose end seeded by seedOneNode — read its id back for the assertion.
  let seededID = try #require(try db.read { db in
    try LooseEnd.where { $0.nodeID.eq(node.id) }.fetchOne(db)?.id
  })
  _ = event
  let bundle = try #require(try await SessionContextQueries.bundle(
    forPath: "/p/one", nodeID: nil, db, now: Date(),
    summaryBuilder: nil, providerKind: "fm", cache: nil))
  #expect(bundle.looseEnds.first?.id == seededID)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `./scripts/test.sh --filter bundleLooseEndCarriesItsID`
Expected: FAIL — compile error, `BundleLooseEnd` has no member `id`.

- [ ] **Step 3: Add the field and populate it**

In `Sources/PensieveKit/Query/SessionContextQueries.swift`, change `BundleLooseEnd`:

```swift
public struct BundleLooseEnd: Codable, Sendable {
  public let id: UUID
  public let text: String
  public let quote: String
  public let role: String
  public let ageDays: Int
}
```

In `bundle(...)`, update the `looseEnds` mapping (currently starting `looseEnds: ends.map { BundleLooseEnd(text: ...`):

```swift
      looseEnds: ends.map { BundleLooseEnd(id: $0.looseEnd.id, text: $0.looseEnd.text,
                                           quote: $0.looseEnd.quote, role: $0.looseEnd.role,
                                           ageDays: $0.ageDays) },
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `./scripts/test.sh --filter bundleLooseEndCarriesItsID`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/PensieveKit/Query/SessionContextQueries.swift Tests/PensieveKitTests/SessionContextQueriesTests.swift
git commit -F - <<'EOF'
feat(kit): expose loose-end id on project_context bundle

Additive handle so an MCP client can point recall at a specific loose end.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01NrPyxAP3kiCe2NqkqeaMDW
EOF
```

---

### Task 2: `RecallBundle` payloads + `SessionContextQueries.recall(...)` kernel

The core: resolve a loose end by id → surrounding transcript window via `ProvenanceQueries`.

**Files:**
- Modify: `Sources/PensieveKit/Query/SessionContextQueries.swift` (add two payload structs near the other `Bundle*` types; add the `recall` static method to the `SessionContextQueries` enum)
- Test: `Tests/PensieveKitTests/SessionContextQueriesTests.swift`

**Interfaces:**
- Consumes: `ProvenanceQueries.context(_ db:, looseEnd:, radius:) throws -> ProvenanceContext` (unchanged); `LooseEnd` model; `ProvenanceContext` has `.sourceEvent: Event`, `.messages: [ProvenanceMessage]`, `.transcriptAvailable: Bool`; `ProvenanceMessage` has `index/role/text/isCited/isUserPrompt`; `Event` has `.occurredAt: Date`.
- Produces:
  - `public struct RecallMessage: Codable, Sendable { index: Int; role: String; text: String; isCited: Bool; isUserPrompt: Bool }`
  - `public struct RecallBundle: Codable, Sendable { looseEndText: String; quote: String; transcriptAvailable: Bool; sessionOccurredAt: Date; messages: [RecallMessage] }`
  - `SessionContextQueries.recall(looseEndID: UUID, radius: Int, _ db: any DatabaseReader) throws -> RecallBundle?` — `nil` when the id resolves to no loose end.

- [ ] **Step 1: Write the failing tests**

Add to `Tests/PensieveKitTests/SessionContextQueriesTests.swift`. These reuse the transcript/loose-end seeding pattern from `ProvenanceQueriesTests.swift` — inlined here so the file is self-contained:

```swift
/// Local copy of the transcript writer (mirrors ProvenanceQueriesTests): one JSONL line per
/// (type, text); "user" prose → isUserPrompt true.
private func writeRecallTranscript(_ prefix: String, _ lines: [(type: String, text: String)]) throws -> URL {
  let url = tempURL(prefix, ext: "jsonl")
  let jsonl = lines.map { line in
    #"{"type":"\#(line.type)","cwd":"/p/app","timestamp":"2026-06-29T13:03:43.382Z","message":{"role":"\#(line.type)","content":"\#(line.text)"}}"#
  }.joined(separator: "\n")
  try jsonl.write(to: url, atomically: true, encoding: .utf8)
  return url
}

/// Inserts an event pointing at `transcriptURL` + a loose end citing `citedIndex` with `quote`.
private func seedRecallLooseEnd(_ db: any DatabaseWriter, transcriptURL: URL,
                                citedIndex: Int, quote: String) throws -> LooseEnd {
  let (node, source) = try ProjectResolver(db: db).resolve(path: "/p/recall", kind: SourceKind.claudeCode)
  let detail = try encodeJSON(["transcriptPath": transcriptURL.path, "sessionID": "s", "prompts": "2"])
  let event = Event(nodeID: node.id, sourceID: source.id, occurredAt: Date(),
                    kind: CaptureKind.ccSession, summary: "session", detailJSON: detail, fingerprint: "fpr")
  let le = LooseEnd(nodeID: node.id, sourceEventID: event.id, text: "finish the migration",
                    quote: quote, role: "user", sourceMessageIndex: citedIndex)
  try db.write { db in
    try Event.insert { event }.execute(db)
    try LooseEnd.insert { le }.execute(db)
  }
  return le
}

@Test func recallReturnsWindowAroundCitedUserPrompt() throws {
  let db = try openCanonicalDatabase(at: tempURL("recall-happy"))
  let url = try writeRecallTranscript("recall-happy", [
    (type: "user", text: "hello there"),                            // index 0
    (type: "assistant", text: "sure working on it"),                // index 1
    (type: "user", text: "we still need to finish the migration"),  // index 2 (cited)
    (type: "assistant", text: "got it"),                            // index 3
    (type: "user", text: "thanks"),                                 // index 4
  ])
  let le = try seedRecallLooseEnd(db, transcriptURL: url, citedIndex: 2, quote: "finish the migration")
  let bundle = try #require(try SessionContextQueries.recall(looseEndID: le.id, radius: 1, db))
  #expect(bundle.transcriptAvailable)
  #expect(bundle.quote == "finish the migration")
  #expect(bundle.looseEndText == "finish the migration")
  #expect(bundle.messages.map(\.index) == [1, 2, 3])   // radius 1 around index 2
  let cited = bundle.messages.first { $0.isCited }
  #expect(cited?.index == 2)
  #expect(cited?.isUserPrompt == true)
}

@Test func recallRespectsRadius() throws {
  let db = try openCanonicalDatabase(at: tempURL("recall-radius"))
  let url = try writeRecallTranscript("recall-radius", [
    (type: "user", text: "aaa"), (type: "assistant", text: "bbb"),
    (type: "user", text: "we still need to finish the migration"),  // index 2 (cited)
    (type: "assistant", text: "ccc"), (type: "user", text: "ddd"),
  ])
  let le = try seedRecallLooseEnd(db, transcriptURL: url, citedIndex: 2, quote: "finish the migration")
  let bundle = try #require(try SessionContextQueries.recall(looseEndID: le.id, radius: 4, db))
  #expect(bundle.messages.map(\.index) == [0, 1, 2, 3, 4])   // wider radius → whole clamped window
}

@Test func recallReturnsNilForUnknownID() throws {
  let db = try openCanonicalDatabase(at: tempURL("recall-unknown"))
  #expect(try SessionContextQueries.recall(looseEndID: UUID(), radius: 8, db) == nil)
}

@Test func recallDegradesHonestlyWhenTranscriptGone() throws {
  let db = try openCanonicalDatabase(at: tempURL("recall-gone"))
  let gone = tempURL("recall-gone-file", ext: "jsonl")   // never written to disk
  let le = try seedRecallLooseEnd(db, transcriptURL: gone, citedIndex: 0, quote: "anything")
  let bundle = try #require(try SessionContextQueries.recall(looseEndID: le.id, radius: 8, db))
  #expect(bundle.transcriptAvailable == false)
  #expect(bundle.messages.isEmpty)
  #expect(bundle.quote == "anything")   // stored quote preserved for honest fallback
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `./scripts/test.sh --filter recall`
Expected: FAIL — `SessionContextQueries` has no member `recall` (and `RecallBundle` undefined).

- [ ] **Step 3: Add the payloads and the kernel method**

In `Sources/PensieveKit/Query/SessionContextQueries.swift`, add near the other JSON payloads (after `BundleEvent`):

```swift
public struct RecallMessage: Codable, Sendable {
  public let index: Int
  public let role: String
  public let text: String
  public let isCited: Bool
  public let isUserPrompt: Bool
}

/// A loose end's surrounding transcript window — the MCP `recall` contract. Verbatim only.
public struct RecallBundle: Codable, Sendable {
  public let looseEndText: String
  public let quote: String
  public let transcriptAvailable: Bool
  public let sessionOccurredAt: Date
  public let messages: [RecallMessage]   // empty when transcriptAvailable == false
}
```

Add this method inside the `SessionContextQueries` enum (e.g. after `rankedContext`):

```swift
  /// Recall the transcript conversation around a loose end. Fetches the LooseEnd by UUID and
  /// delegates to the tested `ProvenanceQueries.context(radius:)` — no LLM, verbatim only, inside
  /// the trust gate. Returns nil if the id resolves to no loose end; a bundle with
  /// `transcriptAvailable == false` (+ the stored quote) if the transcript is gone.
  public static func recall(looseEndID: UUID, radius: Int,
                            _ db: any DatabaseReader) throws -> RecallBundle? {
    guard let le = try db.read({ db in
      try LooseEnd.where { $0.id.eq(looseEndID) }.fetchOne(db)
    }) else { return nil }
    let ctx = try ProvenanceQueries.context(db, looseEnd: le, radius: radius)
    return RecallBundle(
      looseEndText: le.text, quote: le.quote,
      transcriptAvailable: ctx.transcriptAvailable,
      sessionOccurredAt: ctx.sourceEvent.occurredAt,
      messages: ctx.messages.map { RecallMessage(index: $0.index, role: $0.role, text: $0.text,
                                                 isCited: $0.isCited, isUserPrompt: $0.isUserPrompt) })
  }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `./scripts/test.sh --filter recall`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/PensieveKit/Query/SessionContextQueries.swift Tests/PensieveKitTests/SessionContextQueriesTests.swift
git commit -F - <<'EOF'
feat(kit): SessionContextQueries.recall — loose end → transcript window

Wraps the tested ProvenanceQueries kernel behind a Codable RecallBundle;
nil on unknown id, honest transcriptAvailable:false when the transcript is
gone. Verbatim only, inside the trust gate.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01NrPyxAP3kiCe2NqkqeaMDW
EOF
```

---

### Task 3: Wire the `recall` MCP tool

Expose the kernel over the `pensieve mcp` stdio server. Thin layer; no unit tests (project convention) — gate on `swift build`.

**Files:**
- Modify: `Sources/pensieve/Commands/Mcp.swift` (add the tool to `ListTools`; add a `case "recall"` to the `CallTool` dispatch; add `PensieveMCP.recallJSON(...)`)

**Interfaces:**
- Consumes: `SessionContextQueries.recall(looseEndID:radius:_:) throws -> RecallBundle?` (Task 2); existing `PensieveMCP.openCanonicalReadOnly()`, `PensieveMCP.makeEncoder()`, `PensieveMCP.result(_:)`.
- Produces: a third MCP tool named `recall`.

- [ ] **Step 1: Add the tool declaration to `ListTools`**

In `Sources/pensieve/Commands/Mcp.swift`, inside `server.withMethodHandler(ListTools.self)`, add a third `Tool(...)` after `whats_next`:

```swift
        Tool(name: "recall",
             description: "Recall the surrounding transcript conversation around a loose end — reconstruct how a discussion went and how it resolved. Pass a loose_end_id from project_context.",
             inputSchema: .object(["type": .string("object"), "properties": .object([
               "loose_end_id": .object(["type": .string("string"), "description": .string("UUID of a loose end from project_context")]),
               "radius": .object(["type": .string("number"), "description": .string("messages of context each side (default 8)")]),
             ]), "required": .array([.string("loose_end_id")])]),
             annotations: .init(readOnlyHint: true, openWorldHint: false)),
```

- [ ] **Step 2: Add the `CallTool` dispatch case**

In the `server.withMethodHandler(CallTool.self)` switch, add before `default:`:

```swift
      case "recall":
        guard let idStr = params.arguments?["loose_end_id"]?.stringValue,
              let id = UUID(uuidString: idStr) else {
          return .init(content: [.text(text: "recall requires a valid loose_end_id (UUID)", annotations: nil, _meta: nil)], isError: true)
        }
        let radius = params.arguments?["radius"]?.intValue ?? 8
        let json = try PensieveMCP.recallJSON(looseEndID: id, radius: radius)
        return PensieveMCP.result(json)
```

- [ ] **Step 3: Add `recallJSON` to `PensieveMCP`**

In the `enum PensieveMCP`, add alongside `whatsNextJSON`:

```swift
  static func recallJSON(looseEndID: UUID, radius: Int) throws -> Data {
    guard let db = try? openCanonicalReadOnly() else {
      return try makeEncoder().encode(Optional<RecallBundle>.none)   // "null"
    }
    let bundle = try SessionContextQueries.recall(looseEndID: looseEndID, radius: radius, db)
    return try makeEncoder().encode(bundle)   // encodes `null` for an unknown id
  }
```

- [ ] **Step 4: Build to verify it compiles**

Run: `swift build`
Expected: `Build complete!` with no errors.

- [ ] **Step 5: Run the full kernel test suite (no regressions)**

Run: `./scripts/test.sh`
Expected: all tests pass (the prior 260+ plus the 5 added in Tasks 1–2).

- [ ] **Step 6: Commit**

```bash
git add Sources/pensieve/Commands/Mcp.swift
git commit -F - <<'EOF'
feat(mcp): recall tool — loose end id -> transcript window

Third read-only MCP tool over SessionContextQueries.recall; validates the
UUID, default radius 8. Replaces the shell round-trip that grepped .jsonl
transcripts to reconstruct a past conversation.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01NrPyxAP3kiCe2NqkqeaMDW
EOF
```

---

## Manual verification (optional, after Task 3)

Rebuild + reinstall the release CLI so the live MCP server carries the new tool, then in a fresh Claude Code session confirm `recall` appears and returns a transcript window for a `loose_end_id` taken from `project_context` — the flow that previously needed ~5 shell calls should now be `project_context` → `recall`. (Human-verify carry; not gating.)

## Self-Review

- **Spec coverage:** Kit payloads + `recall` kernel (Task 2 ✓), additive `BundleLooseEnd.id` (Task 1 ✓), MCP tool with `loose_end_id`+`radius` default 8 (Task 3 ✓), trust gate / no `ProvenanceQueries` change (Global Constraints ✓), deferred items are backlog-only (no tasks — correct). Testing section maps to Task 2's four tests + Task 1's id test.
- **Placeholder scan:** none — every step has concrete code/commands.
- **Type consistency:** `RecallBundle`/`RecallMessage` field names and `recall(looseEndID:radius:_:)` signature match across Tasks 2 and 3; `BundleLooseEnd(id:text:quote:role:ageDays:)` order matches the struct.
