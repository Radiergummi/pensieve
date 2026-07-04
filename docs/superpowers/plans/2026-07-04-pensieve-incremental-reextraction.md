# Incremental Re-Extraction Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Change loose-end extraction from extract-once to incremental, so a paused/resumed Claude session has its later messages extracted on transcript growth — without duplicating what was already surfaced.

**Architecture:** Add two watermark columns to `Event` (additive migration v7). `ExtractionRunner.run()` stops filtering to `extractedAt == nil`; instead it processes every `cc.session` event, skips transcripts whose byte size is unchanged, and extracts only the new message slice `messages[start...]` with a clamp that recovers safely from shrink/rewrite. Legacy rows (extracted before this feature, size 0) initialize the watermark without extracting. The trust gate (`LooseEndVerifier`) and the normalized-quote dedup are untouched.

**Tech Stack:** Swift 6, SQLiteData (GRDB-backed), STRICT SQLite tables, Swift Testing.

## Global Constraints

- Build with `swift build`; run tests with `./scripts/test.sh` (optionally `--filter <name>`). **NEVER `swift test`** — Command Line Tools only. On a SwiftSyntax/macro linker error, `rm -rf .build` and retry.
- SQLiteData predicates use `.eq(x)`, **NOT** `== x`. Tables are `STRICT`. PKs are `UUID`.
- Migration must be **additive** — v7 follows v6; both new columns are `INTEGER NOT NULL DEFAULT 0`.
- **The trust gate is untouched.** Do not modify `LooseEndVerifier`, `LooseEndExtractor`, `IntentClassifier`, `TranscriptParser`, or the normalized-quote dedup. Reuse them.
- No shared mutable `static ISO8601DateFormatter` (Swift 6 concurrency).
- Never set `PENSIEVE_DB` / `PENSIEVE_CAPTURE_DB` — tests use `tempURL(...)` stores.

---

### Task 1: Event watermark fields + migration v7

**Files:**
- Modify: `Sources/PensieveKit/Model/Event.swift`
- Modify: `Sources/PensieveKit/Store/CanonicalStore.swift` (append migration after `v6-session-branches`, before `try migrator.migrate(db)`)
- Test: `Tests/PensieveKitTests/SchemaV7Tests.swift` (create)

**Interfaces:**
- Produces: `Event.extractedMessageCount: Int` and `Event.extractedTranscriptSize: Int`, both defaulting to `0` in `Event.init` (added as the last two parameters before `createdAt`). Task 2 reads and writes both. Existing `Event(...)` call sites (the ingester, other tests) are unchanged because both new params are defaulted.

- [ ] **Step 1: Write the failing schema test**

Create `Tests/PensieveKitTests/SchemaV7Tests.swift`:

```swift
import Foundation
import Testing
import SQLiteData
@testable import PensieveKit

@Test func v7AddsWatermarkColumnsWithDefaults() throws {
  let db = try openCanonicalDatabase(at: tempURL("v7"))
  let node = Node(name: "Colibri")
  let source = Source(nodeID: node.id, kind: SourceKind.claudeCode, key: "/p/colibri")
  let event = Event(nodeID: node.id, sourceID: source.id, occurredAt: Date(),
                    kind: CaptureKind.ccSession, summary: "s", detailJSON: "{}",
                    fingerprint: "fp-v7")
  try db.write { db in
    try Node.insert { node }.execute(db)
    try Source.insert { source }.execute(db)
    try Event.insert { event }.execute(db)
  }
  // New rows default to 0 for both watermark columns.
  let ev = try db.read { db in try Event.all.fetchAll(db) }.first
  #expect(ev?.extractedMessageCount == 0)
  #expect(ev?.extractedTranscriptSize == 0)

  // Non-zero values round-trip through the STRICT columns.
  try db.write { db in
    try Event.where { $0.id.eq(event.id) }.update {
      $0.extractedMessageCount = 5
      $0.extractedTranscriptSize = 1234
    }.execute(db)
  }
  let updated = try db.read { db in try Event.all.fetchAll(db) }.first
  #expect(updated?.extractedMessageCount == 5)
  #expect(updated?.extractedTranscriptSize == 1234)
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `./scripts/test.sh --filter v7AddsWatermarkColumnsWithDefaults`
Expected: FAIL — compile error (`Event` has no member `extractedMessageCount`).

- [ ] **Step 3: Add the two fields to `Event`**

In `Sources/PensieveKit/Model/Event.swift`, add the two `var`s after `extractedAt` and before `createdAt`, and add the two defaulted params to `init` (after `extractedAt:`, before `createdAt:`). The struct becomes:

```swift
import Foundation
import SQLiteData

@Table
public struct Event: Identifiable, Equatable, Sendable {
  public let id: UUID
  public var nodeID: UUID
  public var sourceID: UUID
  public var occurredAt: Date
  public var kind: String        // "git.commit" | "git.checkout" | "cc.session"
  public var summary: String     // short human-readable line
  public var detailJSON: String  // enriched payload as JSON
  public var fingerprint: String?   // source-agnostic idempotency key (unique per sourceID)
  public var branchKey: String?     // non-default git branch this event belongs to, if any
  public var extractedAt: Date?     // when loose-end extraction last processed this event
  public var extractedMessageCount: Int   // watermark: parsed messages already extracted
  public var extractedTranscriptSize: Int // transcript byte size at last extraction (change detector)
  public var createdAt: Date
  public init(id: UUID = UUID(), nodeID: UUID, sourceID: UUID, occurredAt: Date,
              kind: String, summary: String, detailJSON: String,
              fingerprint: String? = nil, branchKey: String? = nil, extractedAt: Date? = nil,
              extractedMessageCount: Int = 0, extractedTranscriptSize: Int = 0,
              createdAt: Date = Date()) {
    self.id = id; self.nodeID = nodeID; self.sourceID = sourceID; self.occurredAt = occurredAt
    self.kind = kind; self.summary = summary; self.detailJSON = detailJSON
    self.fingerprint = fingerprint; self.branchKey = branchKey; self.extractedAt = extractedAt
    self.extractedMessageCount = extractedMessageCount; self.extractedTranscriptSize = extractedTranscriptSize
    self.createdAt = createdAt
  }
}
```

- [ ] **Step 4: Add migration v7**

In `Sources/PensieveKit/Store/CanonicalStore.swift`, add this migration immediately after the `v6-session-branches` block and before `try migrator.migrate(db)`:

```swift
  migrator.registerMigration("v7-incremental-extraction") { db in
    try #sql(#"ALTER TABLE "events" ADD COLUMN "extractedMessageCount" INTEGER NOT NULL DEFAULT 0"#).execute(db)
    try #sql(#"ALTER TABLE "events" ADD COLUMN "extractedTranscriptSize" INTEGER NOT NULL DEFAULT 0"#).execute(db)
  }
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `./scripts/test.sh --filter v7AddsWatermarkColumnsWithDefaults`
Expected: PASS.

- [ ] **Step 6: Run the full suite to confirm no regression**

Run: `./scripts/test.sh`
Expected: PASS (all existing tests still green — the new params are defaulted so no call site changes).

- [ ] **Step 7: Commit**

```bash
git add Sources/PensieveKit/Model/Event.swift Sources/PensieveKit/Store/CanonicalStore.swift Tests/PensieveKitTests/SchemaV7Tests.swift
git commit -F - <<'EOF'
feat: add Event watermark fields + migration v7

Two INTEGER NOT NULL DEFAULT 0 columns (extractedMessageCount,
extractedTranscriptSize) for incremental re-extraction. Additive v7.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_019yV6ctNrVASgwYM9ivghMc
EOF
```

---

### Task 2: Incremental `ExtractionRunner.run()`

**Files:**
- Modify: `Sources/PensieveKit/Intelligence/ExtractionRunner.swift` (rewrite the body of `run()`)
- Test: `Tests/PensieveKitTests/ExtractionRunnerTests.swift` (add a shared provider + helpers + the new tests; keep the existing test)

**Interfaces:**
- Consumes: `Event.extractedMessageCount` / `Event.extractedTranscriptSize` (Task 1); `TranscriptParser.parse(fileURL:) -> ParsedSession`; `ParsedSession.messages: [TranscriptMessage]` (each with a dense, line-ordered, append-stable `.index`); `LooseEndExtractor(provider:).extract(from:)`; `LooseEndVerifier.verify(_:messages:)`; `normalizeWhitespace(_:)`.
- Produces: same `[ExtractionResult]` return shape (unchanged). A skipped/unchanged/legacy-init event contributes **no** element to the result array.

- [ ] **Step 1: Add the shared test provider + transcript helpers**

At the top of `Tests/PensieveKitTests/ExtractionRunnerTests.swift`, below the existing `CannedProvider`, add:

```swift
/// Models slice-scoped extraction: proposes a `genuine` candidate only when its `quote`
/// literally appears in the extraction prompt (i.e. its message is in the sliced input),
/// so it faithfully mirrors "extract only the new slice". `fabricated` candidates are
/// always proposed but never appear in any message, so the verifier must drop them
/// (exercising the trust gate). The intent classifier is forced to fail open (keep every
/// user prompt) by throwing — matching the protocol default's non-array behavior.
private struct SliceAwareProvider: LLMProvider {
  var genuine: [(quote: String, index: Int)] = []
  var fabricated: [(quote: String, index: Int)] = []
  func complete(prompt: String) async throws -> String { "[]" }
  func extractCandidates(prompt: String) async throws -> [LooseEndCandidate] {
    var out = genuine.filter { prompt.contains($0.quote) }
      .map { LooseEndCandidate(text: "todo: \($0.quote)", quote: $0.quote, messageIndex: $0.index) }
    out += fabricated.map { LooseEndCandidate(text: "fab", quote: $0.quote, messageIndex: $0.index) }
    return out
  }
  func classifyGenuineIndices(prompt: String) async throws -> [Int] {
    throw LLMError.providerFailed("force fail-open: keep all user prompts")
  }
}

/// One JSONL user-message line as Claude Code records it.
private func userLine(_ text: String, ts: String) -> String {
  let obj: [String: Any] = ["type": "user", "cwd": "/p/x", "timestamp": ts,
                            "message": ["role": "user", "content": text]]
  let data = try! JSONSerialization.data(withJSONObject: obj)
  return String(data: data, encoding: .utf8)!
}

/// Writes a fresh temp transcript of user-message lines; returns its URL. Each text becomes
/// a genuine user prompt at dense index 0,1,2,… in order.
private func writeTranscript(_ texts: [String]) throws -> URL {
  let url = tempURL("transcript", ext: "jsonl")
  let lines = texts.enumerated().map { i, t in userLine(t, ts: "2026-06-30T10:0\(i):00Z") }
  try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
  return url
}

/// Appends one raw line (already JSON, no trailing newline) to an existing transcript.
private func appendRawLine(_ url: URL, _ line: String) throws {
  let handle = try FileHandle(forWritingTo: url)
  defer { try? handle.close() }
  try handle.seekToEnd()
  try handle.write(contentsOf: Data((line + "\n").utf8))
}

/// Inserts a cc.session Event pointing at `transcript` and returns it (already persisted).
private func makeSessionEvent(db: any DatabaseWriter, transcript: URL) throws -> Event {
  let (node, source) = try ProjectResolver(db: db).resolve(path: "/p/x", kind: SourceKind.claudeCode)
  let detail = try encodeJSON(["sessionID": transcript.deletingPathExtension().lastPathComponent,
                               "transcriptPath": transcript.path])
  let event = Event(nodeID: node.id, sourceID: source.id, occurredAt: Date(),
                    kind: CaptureKind.ccSession, summary: "s", detailJSON: detail,
                    fingerprint: "fp-\(UUID().uuidString)")
  try db.write { db in try Event.insert { event }.execute(db) }
  return event
}
```

- [ ] **Step 2: Write the growth + trust-gate test (failing)**

Add to `ExtractionRunnerTests.swift`:

```swift
@Test func reextractsOnlyNewMessagesOnGrowth() async throws {
  let db = try openCanonicalDatabase(at: tempURL("run-growth"))
  let rate = "We still need to add rate limiting before launch"
  let migration = "Also remember to write the migration test before merging"
  let transcript = try writeTranscript([rate])
  let event = try makeSessionEvent(db: db, transcript: transcript)

  // Run 1: only msg 0 exists → the rate-limiting loose end is inserted.
  let run1 = try await ExtractionRunner(db: db, provider:
    SliceAwareProvider(genuine: [(rate, 0)])).run()
  #expect(run1.first?.inserted == 1)
  let after1 = try await db.read { db in try LooseEnd.all.fetchAll(db) }
  #expect(after1.count == 1)
  #expect(after1.first?.quote == rate)

  // Watermark advanced to the current message count and byte size.
  let ev1 = try await db.read { db in try Event.all.fetchAll(db) }.first!
  #expect(ev1.extractedMessageCount == 1)
  #expect(ev1.extractedTranscriptSize > 0)

  // Append a second genuine user message (index 1) and re-run.
  try appendRawLine(transcript, userLine(migration, ts: "2026-06-30T10:05:00Z"))
  // Provider proposes the NEW loose end (index 1) plus one fabricated candidate that must
  // be dropped by the verifier; it does NOT re-propose the rate-limiting quote.
  let run2 = try await ExtractionRunner(db: db, provider:
    SliceAwareProvider(genuine: [(migration, 1)],
                       fabricated: [(quote: "never said this at all", index: 1)])).run()

  #expect(run2.first?.proposed == 2)   // genuine (in slice) + fabricated
  #expect(run2.first?.verified == 1)   // trust gate drops the fabricated one on re-extraction
  #expect(run2.first?.inserted == 1)   // only the new loose end, no duplicate of the old
  let after2 = try await db.read { db in try LooseEnd.all.fetchAll(db) }
  #expect(after2.count == 2)
  #expect(Set(after2.map { $0.quote }) == Set([rate, migration]))
  let ev2 = try await db.read { db in try Event.all.fetchAll(db) }.first!
  #expect(ev2.extractedMessageCount == 2)
}
```

- [ ] **Step 3: Run it to verify it fails**

Run: `./scripts/test.sh --filter reextractsOnlyNewMessagesOnGrowth`
Expected: FAIL — the current runner filters to `extractedAt == nil`, so run 2 returns nothing and `run2.first` is nil.

- [ ] **Step 4: Rewrite `ExtractionRunner.run()`**

Replace the body of `run()` in `Sources/PensieveKit/Intelligence/ExtractionRunner.swift` with:

```swift
  public func run() async throws -> [ExtractionResult] {
    // Every cc.session event is a candidate now — the extract-once filter is gone; a
    // byte-size gate and a message-count watermark decide what (if anything) to re-extract.
    let events = try await db.read { db in
      try Event.where { $0.kind.eq(CaptureKind.ccSession) }.fetchAll(db)
    }

    var results: [ExtractionResult] = []
    for event in events {
      do {
        let detail = (try? JSONDecoder().decode([String: String].self,
                                                from: Data(event.detailJSON.utf8))) ?? [:]
        let fileURL = URL(fileURLWithPath: detail["transcriptPath"] ?? "")

        // Cheap change detector: stat the byte size, no parse. Unreadable/missing → skip
        // (leave the watermark unadvanced so it retries next run; never crash the batch).
        guard let size = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize else {
          continue
        }
        // Unchanged since last extraction → skip (avoids re-parsing multi-MB transcripts).
        if size == event.extractedTranscriptSize { continue }

        let session = TranscriptParser.parse(fileURL: fileURL)

        // Legacy init (one-time, no extraction): a row extracted before this feature existed
        // has extractedAt set but size still 0. Its prior extraction already covered the
        // transcript as it then stood, so initialize the watermark/size WITHOUT extracting —
        // otherwise migration would resurface every previously-resolved loose end.
        if event.extractedAt != nil && event.extractedTranscriptSize == 0 {
          let count = session.messages.count
          try await db.write { db in
            try Event.where { $0.id.eq(event.id) }.update {
              $0.extractedMessageCount = count
              $0.extractedTranscriptSize = size
            }.execute(db)
          }
          continue
        }

        // Choose the slice start with a clamp/guard (crash- and misalignment-proof).
        let start: Int
        if session.messages.count >= event.extractedMessageCount {
          start = event.extractedMessageCount        // normal incremental slice
        } else {
          // Fewer messages than the watermark: the transcript shrank/was rewritten, or the
          // parser now filters more. Re-extract from 0 — the quote-dedup makes this safe.
          start = 0
          FileHandle.standardError.write(Data(
            "pensieve: re-extracting \(session.sessionID) from 0: transcript boundary changed\n".utf8))
        }

        // Extract only the new slice (start <= messages.count always → subscript is valid;
        // an empty slice means nothing new). Verify against the FULL message list: the
        // verifier resolves candidates by absolute messageIndex, so slicing the extractor's
        // INPUT never breaks index resolution or sourceMessageIndex.
        let slice = Array(session.messages[start...])
        let candidates = try await LooseEndExtractor(provider: provider).extract(from: slice)
        let verified = candidates.compactMap { LooseEndVerifier.verify($0, messages: session.messages) }

        let stamp = now()
        let newCount = session.messages.count
        let inserted = try await db.write { db -> Int in
          // Collapse against existing OPEN loose ends in this node (verbatim, normalized).
          let existing = try LooseEnd.where { $0.nodeID.eq(event.nodeID) }.fetchAll(db)
          var seen = Set(existing.filter { $0.status == "open" }.map { normalizeWhitespace($0.quote) })
          var insertedCount = 0
          for v in verified {
            let key = normalizeWhitespace(v.quote)
            if seen.contains(key) { continue }   // within- and cross-session dedup
            seen.insert(key)
            try LooseEnd.insert {
              LooseEnd(nodeID: event.nodeID, sourceEventID: event.id, text: v.text,
                       quote: v.quote, role: v.role, sourceMessageIndex: v.sourceMessageIndex)
            }.execute(db)
            insertedCount += 1
          }
          // Advance the watermark, size, and last-extracted stamp in the same write.
          try Event.where { $0.id.eq(event.id) }.update {
            $0.extractedAt = #bind(stamp)
            $0.extractedMessageCount = newCount
            $0.extractedTranscriptSize = size
          }.execute(db)
          return insertedCount
        }

        results.append(ExtractionResult(sessionID: session.sessionID,
          proposed: candidates.count, verified: verified.count, inserted: inserted))
      } catch {
        // A single bad session (provider error, etc.) must never abort the batch or
        // silently advance the watermark — leave it unset so it retries next run.
        FileHandle.standardError.write(Data("pensieve: extraction failed for session \(event.id): \(error)\n".utf8))
        continue
      }
    }
    return results
  }
```

- [ ] **Step 5: Run the growth test to verify it passes**

Run: `./scripts/test.sh --filter reextractsOnlyNewMessagesOnGrowth`
Expected: PASS.

- [ ] **Step 6: Verify the existing test (fresh-session + no-op regression) still passes**

The existing `runnerStoresOnlyVerifiedLooseEnds` covers the fresh-session-extracts-fully path and the unchanged-transcript no-op (its second run now skips via the size gate rather than the `extractedAt` filter).

Run: `./scripts/test.sh --filter runnerStoresOnlyVerifiedLooseEnds`
Expected: PASS.

- [ ] **Step 7: Write the unchanged-no-op test (failing → passing)**

Add:

```swift
@Test func unchangedTranscriptIsNoOp() async throws {
  let db = try openCanonicalDatabase(at: tempURL("run-noop"))
  let quote = "We still need to add rate limiting before launch"
  let transcript = try writeTranscript([quote])
  _ = try makeSessionEvent(db: db, transcript: transcript)

  _ = try await ExtractionRunner(db: db, provider: SliceAwareProvider(genuine: [(quote, 0)])).run()
  #expect(try await db.read { db in try LooseEnd.all.fetchAll(db) }.count == 1)

  // Re-run with NO change to the transcript → the size gate skips it: no result element,
  // nothing inserted.
  let second = try await ExtractionRunner(db: db, provider: SliceAwareProvider(genuine: [(quote, 0)])).run()
  #expect(second.isEmpty)
  #expect(try await db.read { db in try LooseEnd.all.fetchAll(db) }.count == 1)
}
```

Run: `./scripts/test.sh --filter unchangedTranscriptIsNoOp`
Expected: PASS (the runner change from Step 4 already implements the size gate).

- [ ] **Step 8: Write the shrink/count-drop guard test**

Add:

```swift
@Test func countDropReextractsFromZeroWithoutCrashOrDuplicate() async throws {
  let db = try openCanonicalDatabase(at: tempURL("run-shrink"))
  let quote = "We still need to add rate limiting before launch"
  let transcript = try writeTranscript([quote])
  let event = try makeSessionEvent(db: db, transcript: transcript)

  _ = try await ExtractionRunner(db: db, provider: SliceAwareProvider(genuine: [(quote, 0)])).run()
  #expect(try await db.read { db in try LooseEnd.all.fetchAll(db) }.count == 1)

  // Simulate a rewrite/filter change: watermark far above the current message count, and a
  // size different from the real file (non-zero, so it is NOT mistaken for a legacy row).
  try await db.write { db in
    try Event.where { $0.id.eq(event.id) }.update {
      $0.extractedMessageCount = 99
      $0.extractedTranscriptSize = 1   // != real size and != 0
    }.execute(db)
  }

  // Must NOT trap on messages[99...]; re-extracts from 0, and the dedup prevents a duplicate.
  let rerun = try await ExtractionRunner(db: db, provider: SliceAwareProvider(genuine: [(quote, 0)])).run()
  #expect(rerun.first?.inserted == 0)   // already-open loose end deduped
  let ends = try await db.read { db in try LooseEnd.all.fetchAll(db) }
  #expect(ends.count == 1)
  // Watermark repaired to the real count.
  let ev = try await db.read { db in try Event.all.fetchAll(db) }.first!
  #expect(ev.extractedMessageCount == 1)
}
```

Run: `./scripts/test.sh --filter countDropReextractsFromZeroWithoutCrashOrDuplicate`
Expected: PASS.

- [ ] **Step 9: Write the legacy-init test (does not resurrect resolved items)**

Add:

```swift
@Test func legacyRowInitializesWithoutResurrectingResolved() async throws {
  let db = try openCanonicalDatabase(at: tempURL("run-legacy"))
  let resolvedQuote = "We still need to add rate limiting before launch"
  let transcript = try writeTranscript([resolvedQuote])
  let event = try makeSessionEvent(db: db, transcript: transcript)

  // Simulate a pre-feature row: extractedAt set, size still 0, count 0; and a RESOLVED loose
  // end whose quote is still in the transcript.
  try await db.write { db in
    try Event.where { $0.id.eq(event.id) }.update { $0.extractedAt = #bind(Date(timeIntervalSince1970: 1)) }.execute(db)
    try LooseEnd.insert {
      LooseEnd(nodeID: event.nodeID, sourceEventID: event.id, text: "rate limiting",
               quote: resolvedQuote, status: "resolved", role: "user", sourceMessageIndex: 0)
    }.execute(db)
  }

  // Legacy init: initializes the watermark/size, extracts NOTHING → the resolved item is not
  // resurfaced.
  let init1 = try await ExtractionRunner(db: db, provider: SliceAwareProvider(genuine: [(resolvedQuote, 0)])).run()
  #expect(init1.isEmpty)
  let after1 = try await db.read { db in try LooseEnd.all.fetchAll(db) }
  #expect(after1.count == 1)
  #expect(after1.first?.status == "resolved")
  let ev1 = try await db.read { db in try Event.all.fetchAll(db) }.first!
  #expect(ev1.extractedMessageCount == 1)
  #expect(ev1.extractedTranscriptSize > 0)

  // A later append then extracts only the genuinely new content.
  let newQuote = "Also remember to write the migration test before merging"
  try appendRawLine(transcript, userLine(newQuote, ts: "2026-06-30T10:05:00Z"))
  let run2 = try await ExtractionRunner(db: db, provider: SliceAwareProvider(genuine: [(newQuote, 1)])).run()
  #expect(run2.first?.inserted == 1)
  let after2 = try await db.read { db in try LooseEnd.all.fetchAll(db) }
  #expect(after2.count == 2)
  #expect(after2.filter { $0.status == "open" }.map { $0.quote } == [newQuote])
}
```

Run: `./scripts/test.sh --filter legacyRowInitializesWithoutResurrectingResolved`
Expected: PASS.

- [ ] **Step 10: Write the unreadable-transcript skip test**

Add:

```swift
@Test func unreadableTranscriptSkipsAndLeavesWatermarkUnadvanced() async throws {
  let db = try openCanonicalDatabase(at: tempURL("run-missing"))
  // Point the event at a path that does not exist.
  let missing = tempURL("no-such-transcript", ext: "jsonl")
  let event = try makeSessionEvent(db: db, transcript: missing)

  let results = try await ExtractionRunner(db: db, provider: SliceAwareProvider()).run()
  #expect(results.isEmpty)
  let ev = try await db.read { db in try Event.all.fetchAll(db) }.first!
  #expect(ev.extractedAt == nil)              // not marked; will retry
  #expect(ev.extractedMessageCount == 0)
  #expect(ev.extractedTranscriptSize == 0)
}
```

Run: `./scripts/test.sh --filter unreadableTranscriptSkipsAndLeavesWatermarkUnadvanced`
Expected: PASS.

- [ ] **Step 11: Write the partial-trailing-line regression test**

Add:

```swift
@Test func partialTrailingLinePicksUpAtCorrectIndexAfterCompletion() async throws {
  let db = try openCanonicalDatabase(at: tempURL("run-partial"))
  let q0 = "We still need to add rate limiting before launch"
  let q1 = "Also remember to write the migration test before merging"
  let transcript = try writeTranscript([q0])
  // Append a half-written (invalid-JSON) trailing line: the parser skips it (1 message).
  try appendRawLine(transcript, "{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":\"Als")
  let event = try makeSessionEvent(db: db, transcript: transcript)

  let run1 = try await ExtractionRunner(db: db, provider: SliceAwareProvider(genuine: [(q0, 0)])).run()
  #expect(run1.first?.inserted == 1)
  let ev1 = try await db.read { db in try Event.all.fetchAll(db) }.first!
  #expect(ev1.extractedMessageCount == 1)   // partial line did not create a phantom message

  // "Complete" the record by rewriting the file with both full messages present.
  try (userLine(q0, ts: "2026-06-30T10:00:00Z") + "\n" + userLine(q1, ts: "2026-06-30T10:05:00Z") + "\n")
    .write(to: transcript, atomically: true, encoding: .utf8)

  // The now-complete message is picked up at index 1 with no offset drift.
  let run2 = try await ExtractionRunner(db: db, provider: SliceAwareProvider(genuine: [(q1, 1)])).run()
  #expect(run2.first?.inserted == 1)
  let ends = try await db.read { db in try LooseEnd.all.fetchAll(db) }
  #expect(ends.count == 2)
  #expect(ends.first(where: { $0.quote == q1 })?.sourceMessageIndex == 1)
}
```

Run: `./scripts/test.sh --filter partialTrailingLinePicksUpAtCorrectIndexAfterCompletion`
Expected: PASS.

- [ ] **Step 12: Run the full suite**

Run: `./scripts/test.sh`
Expected: PASS — all prior tests plus the new ones (target: 96 + 1 (Task 1) + 6 (Task 2) = 103).

- [ ] **Step 13: Commit**

```bash
git add Sources/PensieveKit/Intelligence/ExtractionRunner.swift Tests/PensieveKitTests/ExtractionRunnerTests.swift
git commit -F - <<'EOF'
feat: incremental re-extraction in ExtractionRunner

Drop the extract-once (extractedAt == nil) gate. Process every cc.session
event; skip transcripts unchanged by byte size; extract only the new message
slice with a clamp that recovers from shrink/rewrite; legacy rows (size 0)
initialize the watermark without extracting. Trust gate untouched.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_019yV6ctNrVASgwYM9ivghMc
EOF
```

---

## Self-Review

**1. Spec coverage** — every spec section maps to a task:
- Event model, two new fields, `Event.init` defaulted → Task 1 Step 3. ✓
- Additive migration v7, both `INTEGER NOT NULL DEFAULT 0` → Task 1 Step 4; schema round-trip test → Task 1 Step 1. ✓
- Select all `cc.session` (remove filter) → Task 2 Step 4 (`events` fetch, no `.filter`). ✓
- `stat` size; unreadable → skip; `size == stored` → skip → Task 2 Step 4; tested Steps 7, 10. ✓
- Legacy init (`extractedAt != nil && size == 0`) without extracting → Task 2 Step 4; tested Step 9. ✓
- Clamp `start = messages.count >= watermark ? watermark : 0`, log on reset → Task 2 Step 4; tested Step 8. ✓
- Extract `messages[start...]`, verify against full messages, dedup-insert → Task 2 Step 4; tested Steps 2, 9. ✓
- Update `extractedMessageCount`/`extractedTranscriptSize`/`extractedAt` in same write → Task 2 Step 4. ✓
- Per-session error isolation unchanged → Task 2 Step 4 (`catch { … continue }`). ✓
- Trust gate intact on re-extraction → Task 2 Step 2 (fabricated candidate dropped). ✓
- Fresh-session-extracts-fully + partial-trailing-line → existing test (Step 6) + Step 11. ✓
- Migration test → Task 1. ✓

**2. Placeholder scan** — no TBD/TODO/"handle edge cases"; all steps carry real code and exact commands. One deliberate dead line in Step 11 is flagged for deletion with an explicit note.

**3. Type consistency** — `LooseEndCandidate(text:quote:messageIndex:)`, `LooseEnd(nodeID:sourceEventID:text:quote:status:role:sourceMessageIndex:)`, `Event(...)` with the two new defaulted params, `.update { … }` multi-assignment (matches `Ingester.swift:206`), `.eq(x)` predicates, `fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize` (`Int?`) — all match the real signatures verified against source. `ProjectResolver(db:).resolve(path:kind:)` returns `(node, source)` as used in the existing test.
