# Transcript-Passage Chunking Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the raw conversation recallable — index user prompts and the assistant prose that answered them as durable, grounded passages searchable from ⌥⌘F and MCP.

**Architecture:** Passages become canonical rows (migration **v13**) written by `Ingester` as it already parses each session transcript, so they survive the retention window that deletes 64% of transcripts. The FTS5 index gains a **second virtual table** with its **own corpus hash**, so a git commit never rebuilds 50k passage documents. Retrieval is a separate ranked list (`PassageQueries`) appended below the existing one, because BM25 scores from two tables are not comparable.

**Tech Stack:** Swift 6, SQLiteData 1.6.6 (GRDB), FTS5 via raw SQL, Swift Testing, SwiftUI (app slice).

**Spec:** `docs/superpowers/specs/2026-08-14-transcript-passage-chunking-bm25-design.md`

## Global Constraints

- **Swift only. No Python, ever.**
- **Predicates use `.eq(x)`, NOT `== x`** (`==` is `unavailable` and will not compile).
- **Explicit names, no abbreviations** — `database`, `passage`, `looseEnd`, `event`. Not `db`, `p`, `le`. Wire-format `snake_case` keys (`node_id`, `passage_id`) go behind explicit `CodingKeys` so the Swift property stays camelCase.
- **SwiftLint `--strict` runs in CI.** Files cap at **400 lines**; `function_parameter_count` and `cyclomatic_complexity` are enforced. Do not relax `.swiftlint.yml`.
- Tables are **STRICT**, primary keys are **UUID**, table/column names match `@Table` property names exactly.
- **String-typed domain values get a `RawRepresentable` enum**, never bare literals — mirror `LooseEndStatus`.
- No shared mutable `static ISO8601DateFormatter` (Swift 6 concurrency).
- **The trust gate is untouched.** `TranscriptVocabulary.injectionMarkers` and `TranscriptParser.isInjectedOrCommand` are **read, never modified or extended**. No task adds a marker or a tag.
- Run tests with **`make test [FILTER=<name>]`**. Build the app with **`make build`** (which runs `xcodegen generate` first — a bare `xcodebuild` does not, and Task 9 adds an app file).
- **Do NOT set `PENSIEVE_DB` / `PENSIEVE_CAPTURE_DB` when touching the live store.** Tests and smoke runs MUST set them to a temp path.
- **`xcodebuild … | tail` reports `tail`'s exit code.** Redirect to a log and grep for `** BUILD SUCCEEDED **`.
- Commit messages: use `git commit -F -` with a quoted heredoc (backticks in `-m "…"` get shell-executed). Keep the `Co-Authored-By:` and `Claude-Session:` trailers.

## Deviation from the spec, decided at plan time

The spec says *"`SearchHit.Kind` gains `.passage`, which the resolver's exhaustive `switch` forces the implementer to handle."* **Do not do this.** Checking it against the code shows it makes things worse in two ways:

1. `SearchQueries.buildHits` does `SearchHit.Kind(rawValue: candidate.kind)` over rows from the **`documents`** table. Adding a `.passage` case makes that constructor *accept* a passage row if a producer bug ever wrote one into `documents` — it would then be resolved and surfaced through the wrong ranked list. Keeping the enums disjoint makes that unrepresentable.
2. Passages need `role` (who spoke) and a turn identity for dedupe. Putting those on `SearchHit` gives every node, loose-end and event hit two fields that are structurally always-default — the same stale-duplicate-field smell `SearchIndexHit` explicitly avoids ("deliberately carries no `state`").

So passages get their own `PassageHit` type and their own `PassageQueries.search`. `SearchHit` and `SearchQueries` are **not modified at all**. MCP maps `PassageHit` into its existing flat `SearchItem` shape with `kind: "passage"`, so the wire format still has one items array.

## File Structure

**Create:**
- `Sources/PensieveKit/Model/PassageRole.swift` — the `prompt`/`reply` enum.
- `Sources/PensieveKit/Model/Passage.swift` — the `@Table` model.
- `Sources/PensieveKit/Transcript/PassageChunker.swift` — pure text → chunk windows.
- `Sources/PensieveKit/Transcript/PassageExtractor.swift` — `ParsedSession` → `[Passage]`.
- `Sources/PensieveKit/Query/PassageQueries.swift` — retrieval + turn dedupe + `PassageHit`.
- `Sources/PensieveKit/Query/PassageProvenance.swift` — the surrounding-window resolution.
- `Sources/pensieve/Commands/BackfillPassages.swift` — the one-time backfill.
- `Sources/PensieveApp/PassageResultsSection.swift` — the ⌥⌘F section.
- `Tests/PensieveKitTests/PassageChunkerTests.swift`
- `Tests/PensieveKitTests/PassageExtractorTests.swift`
- `Tests/PensieveKitTests/PassageStoreTests.swift`
- `Tests/PensieveKitTests/PassageQueriesTests.swift`
- `docs/superpowers/measurements/2026-08-14-passage-corpus/README.md` + probe.

**Modify:**
- `Sources/PensieveKit/Store/CanonicalStore.swift` — migration v13.
- `Sources/PensieveKit/Ingest/Ingester.swift` — write passages in the session transaction.
- `Sources/PensieveKit/Search/EmbeddableItem.swift` — `gatherPassages`.
- `Sources/PensieveKit/Search/SearchIndexStore.swift` — passage table, `rebuildPassages`, `searchPassages`, `passages_hash`.
- `Sources/PensieveKit/Search/SearchIndexer.swift` — `syncPassages`.
- `Sources/PensieveKit/Query/SessionContextQueries.swift` — `recall(passageID:)`.
- `Sources/pensieve/Commands/Mcp.swift` — passage items + `passage_id` on `recall`.
- `Sources/pensieve/Pensieve.swift` — register the backfill command.
- `Sources/PensieveApp/ContentListView.swift`, `AppModel.swift`, `Localizable.xcstrings` — the app slice.
- `project.yml` is **not** modified; XcodeGen globs `Sources/PensieveApp`, so `make build` picks the new file up.

---

### Task 1: The pre-registered corpus measurement

The spec makes this a gate: every size figure in it is a jq approximation, and this repo has a scar where raw-JSONL measurement invalidated a spec's evidence base. This task produces the parser-faithful numbers **before** any code depends on them.

**Files:**
- Create: `docs/superpowers/measurements/2026-08-14-passage-corpus/probe.swift`
- Create: `docs/superpowers/measurements/2026-08-14-passage-corpus/README.md`

**Interfaces:**
- Consumes: nothing.
- Produces: recorded counts that Task 6 checks its rebuild timing against. No Swift API.

- [ ] **Step 1: Write the probe**

It must reproduce `TranscriptParser`, not grep. Run it with `swift Sources/.../probe.swift`-style compilation against the package so `import PensieveKit` resolves; simplest is a temporary executable target-free `swift run`-less invocation via `swiftc` with the built module. The pragmatic form that works here: put the probe in the measurements dir and compile it against the built `.build/debug` module.

```swift
// probe.swift — throwaway measurement, committed as evidence. Not a product target.
import Foundation
import PensieveKit

// Read-only. Never sets PENSIEVE_DB; reads the live store through the read-only opener.
let storeURL = PensievePaths.canonicalURL()
let database = try openCanonicalDatabaseReadOnly(at: storeURL)

var liveTranscripts = 0, missingTranscripts = 0
var promptCount = 0, replyCount = 0
var promptBytes = 0, replyBytes = 0
var promptsOverChunkLimit = 0, repliesOverChunkLimit = 0

let events = try database.read { database in
  try Event.where { $0.kind.eq(CaptureKind.ccSession) }.fetchAll(database)
}
for event in events {
  guard let path = ProvenanceQueries.transcriptPath(in: event) else { continue }
  guard FileManager.default.fileExists(atPath: path) else { missingTranscripts += 1; continue }
  liveTranscripts += 1
  let session = TranscriptParser.parse(fileURL: URL(fileURLWithPath: path))
  for message in session.messages {
    if message.isUserPrompt {
      promptCount += 1; promptBytes += message.text.utf8.count
      if message.text.count > 2000 { promptsOverChunkLimit += 1 }
    } else if message.role == "assistant" {
      replyCount += 1; replyBytes += message.text.utf8.count
      if message.text.count > 2000 { repliesOverChunkLimit += 1 }
    }
  }
}
print("live=\(liveTranscripts) missing=\(missingTranscripts)")
print("prompts=\(promptCount) bytes=\(promptBytes) over2000=\(promptsOverChunkLimit)")
print("replies=\(replyCount) bytes=\(replyBytes) over2000=\(repliesOverChunkLimit)")
print("estimatedDocuments=\(promptCount + replyCount + promptsOverChunkLimit * 2 + repliesOverChunkLimit * 2)")
```

- [ ] **Step 2: Run it and record the output verbatim**

```bash
swift build 2>&1 | tail -3
swiftc -I .build/debug -L .build/debug -lPensieveKit \
  docs/superpowers/measurements/2026-08-14-passage-corpus/probe.swift \
  -o /tmp/passage-probe && /tmp/passage-probe
```

If linking fights you, the acceptable fallback is a temporary `@Test` in `PensieveKitTests` that prints the same figures against the live store path, run via `make test FILTER=passageCorpusProbe`, then deleted — but **the numbers must come from `TranscriptParser`**, not from grep or jq.

- [ ] **Step 3: Write the README with the numbers and the verdict**

Record: the command, the raw output, the date, and an explicit comparison against the spec's approximations (~7.4k prompts / ~33k replies / ~31 MB). State whether the spec's estimate held. **If total estimated documents exceed 150k or total bytes exceed 100 MB, STOP and report** — the spec's per-table-hash mitigation was sized for ~50k and needs revisiting before Task 6.

- [ ] **Step 4: Commit**

```bash
git add docs/superpowers/measurements/2026-08-14-passage-corpus/
git commit -F - <<'EOF'
docs: measure the passage corpus with the parser, not with grep

The spec's sizing was a jq approximation over raw JSONL and said so. These
are the numbers TranscriptParser actually produces.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_018KLCqkLxxL2THZNPFJpRkw
EOF
```

---

### Task 2: `Passage` model and migration v13

**Files:**
- Create: `Sources/PensieveKit/Model/PassageRole.swift`
- Create: `Sources/PensieveKit/Model/Passage.swift`
- Modify: `Sources/PensieveKit/Store/CanonicalStore.swift:189` (append inside `registerRecentMigrations`)
- Test: `Tests/PensieveKitTests/PassageStoreTests.swift`

**Interfaces:**
- Consumes: `openCanonicalDatabase(at:)`.
- Produces: `PassageRole` (`.prompt` / `.reply`, `QueryBindable`); `Passage(id:nodeID:eventID:turnIndex:messageIndex:role:text:occurredAt:createdAt:)` with all properties `public`.

- [ ] **Step 1: Write the failing test**

```swift
import Foundation
import Testing
import SQLiteData
@testable import PensieveKit

@Suite struct PassageStoreTests {
  /// v13 is additive: a store migrated from scratch has the table, and every earlier-schema test
  /// in this suite still opens. Mirrors the v4–v12 migration tests.
  @Test func migrationV13CreatesPassages() throws {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("passages-\(UUID().uuidString).sqlite")
    defer { try? FileManager.default.removeItem(at: url) }
    let database = try openCanonicalDatabase(at: url)

    let node = Node(name: "Pensieve")
    let source = Source(nodeID: node.id, kind: SourceKind.claudeCode, key: "/tmp/x")
    let event = Event(nodeID: node.id, sourceID: source.id, occurredAt: Date(),
                      kind: CaptureKind.ccSession, summary: "session", detailJSON: "{}")
    let passage = Passage(nodeID: node.id, eventID: event.id, turnIndex: 0, messageIndex: 3,
                          role: .prompt, text: "why does background sync die",
                          occurredAt: Date(timeIntervalSince1970: 1_000_000))
    try database.write { database in
      try Node.insert { node }.execute(database)
      try Source.insert { source }.execute(database)
      try Event.insert { event }.execute(database)
      try Passage.insert { passage }.execute(database)
    }

    let stored = try database.read { database in
      try Passage.where { $0.id.eq(passage.id) }.fetchOne(database)
    }
    #expect(stored?.text == "why does background sync die")
    #expect(stored?.role == .prompt)
    #expect(stored?.messageIndex == 3)
  }

  /// Deleting the anchor event takes its passages with it, so a re-ingest cannot orphan rows and
  /// the corpus cannot serve a passage whose session no longer exists.
  @Test func deletingAnEventCascadesToItsPassages() throws {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("passages-\(UUID().uuidString).sqlite")
    defer { try? FileManager.default.removeItem(at: url) }
    let database = try openCanonicalDatabase(at: url)
    let node = Node(name: "Pensieve")
    let source = Source(nodeID: node.id, kind: SourceKind.claudeCode, key: "/tmp/x")
    let event = Event(nodeID: node.id, sourceID: source.id, occurredAt: Date(),
                      kind: CaptureKind.ccSession, summary: "session", detailJSON: "{}")
    try database.write { database in
      try Node.insert { node }.execute(database)
      try Source.insert { source }.execute(database)
      try Event.insert { event }.execute(database)
      try Passage.insert {
        Passage(nodeID: node.id, eventID: event.id, turnIndex: 0, messageIndex: 0,
                role: .prompt, text: "hello", occurredAt: Date())
      }.execute(database)
      try Event.where { $0.id.eq(event.id) }.delete().execute(database)
    }
    let remaining = try database.read { database in try Passage.all.fetchCount(database) }
    #expect(remaining == 0)
  }
}
```

- [ ] **Step 2: Run it and confirm it fails**

Run: `make test FILTER=PassageStoreTests`
Expected: FAIL — `cannot find 'Passage' in scope`.

- [ ] **Step 3: Write `PassageRole`**

```swift
import Foundation
import SQLiteData

/// Who produced a passage. A real enum rather than raw strings, like `LooseEndStatus` /
/// `NodeKind` / `NodeState` — this codebase converted those precisely to kill the
/// mistyped-literal hazard, and `role` is compared wherever a passage renders.
///
/// Deliberately NOT reusing `LooseEnd.role`, which is a bare `String` holding the transcript's own
/// role value ("user"). That field records what the transcript said; this one records which side of
/// a turn Pensieve stored, and the two must be free to diverge — a transcript role is not a closed
/// set, and `SpeakerClass.of` already falls back to `.system` for unknown ones.
public enum PassageRole: String, QueryBindable, Sendable {
  /// A human turn — a message `TranscriptParser` flagged `isUserPrompt`.
  case prompt
  /// Assistant prose. Tool calls never reach this: `extractText` reads only `text` blocks, so a
  /// tool-use-only message has empty text and never enters `ParsedSession.messages` at all.
  case reply
}
```

- [ ] **Step 4: Write `Passage`**

```swift
import Foundation
import SQLiteData

/// One durable, verbatim slice of a captured conversation.
///
/// **Why this lives in the canonical store and not in the search index.** Claude Code deletes
/// transcripts on a retention window: measured 2026-08-14, only 393 of 1,096 captured session
/// transcripts still existed. The FTS5 index is disposable and whole-rebuilds from the corpus
/// whenever its hash moves, so text living only there would be deleted permanently by the first
/// rebuild after its transcript aged out — a cache acting as the system of record. Storing it here
/// is the same choice `LooseEnd.quote` already makes: a stored verbatim copy that can be cited
/// after the source file is gone.
///
/// Written ONLY by `Ingester`, like every other canonical row.
@Table
public struct Passage: Identifiable, Equatable, Sendable {
  public let id: UUID
  public var nodeID: UUID
  /// The `cc.session` event whose `detailJSON` carries `transcriptPath`. `ON DELETE CASCADE`, so
  /// re-ingesting a session cannot orphan passages.
  public var eventID: UUID
  /// Groups a prompt with the replies that answered it. Assigned by `PassageExtractor` in
  /// transcript order, starting at 0.
  public var turnIndex: Int
  /// `TranscriptMessage.index` of the message this came from — the key the surrounding-window
  /// lookup uses. Several chunks of one long message share it.
  public var messageIndex: Int
  public var role: PassageRole
  /// Verbatim. Never generated, never translated: translation deliberately excludes captured
  /// content, and a translated provenance quote is a broken citation.
  public var text: String
  /// The message's own timestamp, so a passage dates without joining its event.
  public var occurredAt: Date
  public var createdAt: Date
  public init(id: UUID = UUID(), nodeID: UUID, eventID: UUID, turnIndex: Int, messageIndex: Int,
              role: PassageRole, text: String, occurredAt: Date, createdAt: Date = Date()) {
    self.id = id; self.nodeID = nodeID; self.eventID = eventID
    self.turnIndex = turnIndex; self.messageIndex = messageIndex
    self.role = role; self.text = text
    self.occurredAt = occurredAt; self.createdAt = createdAt
  }
}
```

- [ ] **Step 5: Add migration v13**

Append inside `registerRecentMigrations`, after the `v12-looseend-resolvedat` block:

```swift
  migrator.registerMigration("v13-passages") { database in
    // Additive: a new table only, no ALTER on an existing one, so every v4–v12 store opens
    // unchanged. Both foreign keys CASCADE — a deleted node or a re-ingested event must not
    // leave passages behind, because a passage whose anchor is gone can never be cited.
    try #sql("""
      CREATE TABLE "passages"(
        "id" TEXT NOT NULL PRIMARY KEY,
        "nodeID" TEXT NOT NULL REFERENCES "nodes"("id") ON DELETE CASCADE,
        "eventID" TEXT NOT NULL REFERENCES "events"("id") ON DELETE CASCADE,
        "turnIndex" INTEGER NOT NULL,
        "messageIndex" INTEGER NOT NULL,
        "role" TEXT NOT NULL,
        "text" TEXT NOT NULL,
        "occurredAt" TEXT NOT NULL,
        "createdAt" TEXT NOT NULL
      ) STRICT
      """).execute(database)
    // The write path deletes by event before rewriting (idempotent re-ingest), and the corpus
    // producer reads by node. Without these, both are full scans over the largest table in the
    // store — and `looseEnds` already demonstrates the cost of a missing nodeID index.
    try #sql(#"CREATE INDEX "idx_passages_event" ON "passages"("eventID")"#).execute(database)
    try #sql(#"CREATE INDEX "idx_passages_node" ON "passages"("nodeID", "occurredAt")"#).execute(database)
  }
```

- [ ] **Step 6: Run the tests**

Run: `make test FILTER=PassageStoreTests`
Expected: PASS, both tests.

- [ ] **Step 7: Run the whole suite to prove v13 is additive**

Run: `make test`
Expected: PASS — every existing SchemaV4–V12 test still opens its store.

- [ ] **Step 8: Commit**

```bash
git add Sources/PensieveKit/Model/PassageRole.swift Sources/PensieveKit/Model/Passage.swift \
        Sources/PensieveKit/Store/CanonicalStore.swift Tests/PensieveKitTests/PassageStoreTests.swift
git commit -F - <<'EOF'
feat(kit): passages get a canonical home (migration v13)

Transcripts age out — 393 of 1,096 survive — so a passage's text cannot live
only in the disposable search index, which whole-rebuilds from the corpus and
would delete it. Same choice LooseEnd.quote already makes.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_018KLCqkLxxL2THZNPFJpRkw
EOF
```

---

### Task 3: `PassageChunker` — pure text splitting

**Files:**
- Create: `Sources/PensieveKit/Transcript/PassageChunker.swift`
- Test: `Tests/PensieveKitTests/PassageChunkerTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `PassageChunker.chunk(_ text: String) -> [String]`, and the constants `PassageChunker.singleChunkLimit = 2000`, `windowLength = 1500`, `overlapLength = 200`.

- [ ] **Step 1: Write the failing test**

```swift
import Foundation
import Testing
@testable import PensieveKit

@Suite struct PassageChunkerTests {
  @Test func shortTextIsOneChunk() {
    let text = "why does the background sync agent refuse to spawn"
    #expect(PassageChunker.chunk(text) == [text])
  }

  /// The boundary itself, both sides. A 2,000-character text is ONE chunk; 2,001 splits.
  @Test func theSingleChunkLimitIsInclusive() {
    let atLimit = String(repeating: "a", count: 2000)
    #expect(PassageChunker.chunk(atLimit).count == 1)
    let overLimit = String(repeating: "a", count: 2001)
    #expect(PassageChunker.chunk(overLimit).count > 1)
  }

  /// Overlap is the whole point: a phrase straddling a boundary must be findable from one side.
  /// Asserted by CONTENT, not by counting — an off-by-one in the stride would still produce
  /// plausible-looking chunk counts.
  @Test func windowsOverlapSoAStraddlingPhraseSurvives() {
    // A distinctive phrase placed to straddle the first window's end.
    let filler = String(repeating: "x ", count: 740)          // ~1480 chars
    let text = filler + "GHOST PHRASE HERE" + String(repeating: " y", count: 400)
    let chunks = PassageChunker.chunk(text)
    #expect(chunks.count > 1)
    #expect(chunks.contains { $0.contains("GHOST PHRASE HERE") },
            "the straddling phrase must appear intact in at least one chunk")
  }

  @Test func chunksSplitOnWhitespaceNotMidWord() {
    let word = "incomprehensibilities"
    let text = Array(repeating: word, count: 200).joined(separator: " ")
    let chunks = PassageChunker.chunk(text)
    #expect(chunks.count > 1)
    for chunk in chunks {
      let trimmed = chunk.trimmingCharacters(in: .whitespacesAndNewlines)
      #expect(!trimmed.isEmpty)
      // Every token in every chunk is the whole word — nothing was cut through.
      for token in trimmed.split(separator: " ") { #expect(token == word) }
    }
  }

  /// A pathological input with no whitespace at all must still terminate and still cover the text.
  @Test func textWithNoWhitespaceStillSplitsAndLosesNothing() {
    let text = String(repeating: "z", count: 5000)
    let chunks = PassageChunker.chunk(text)
    #expect(chunks.count > 1)
    #expect(chunks.allSatisfy { $0.count <= PassageChunker.windowLength })
    // No-loss: every character position is covered by some chunk.
    #expect(chunks.joined().count >= text.count)
  }

  @Test func emptyAndWhitespaceOnlyTextYieldNoChunks() {
    #expect(PassageChunker.chunk("").isEmpty)
    #expect(PassageChunker.chunk("   \n  ").isEmpty)
  }
}
```

- [ ] **Step 2: Run it and confirm it fails**

Run: `make test FILTER=PassageChunkerTests`
Expected: FAIL — `cannot find 'PassageChunker' in scope`.

- [ ] **Step 3: Implement**

```swift
import Foundation

/// Splits one message's text into the units BM25 scores.
///
/// Chunking exists because FTS5 normalises `bm25()` by a document's total token count: a 6,000-word
/// reply matching one term would be ranked far below a short commit subject matching the same term,
/// so a whole long message is the wrong document. Sizes carry over from the 2026-07-19 design
/// unchanged — the reason for overlap survives the switch from embeddings to BM25, because a phrase
/// straddling a boundary matches neither side otherwise.
public enum PassageChunker {
  /// At or under this, the text is one passage. Matches the extractor's `truncate` budget.
  public static let singleChunkLimit = 2000
  public static let windowLength = 1500
  public static let overlapLength = 200

  /// Ordered chunks covering `text`. Empty for empty or whitespace-only input.
  ///
  /// Advances by `windowLength - overlapLength`, so consecutive chunks share `overlapLength`
  /// characters of context. Each window prefers to end at the last whitespace inside it; a window
  /// with no whitespace at all is cut at its hard length rather than grown, so a pathological
  /// no-whitespace input still terminates.
  public static func chunk(_ text: String) -> [String] {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return [] }
    guard trimmed.count > singleChunkLimit else { return [trimmed] }

    var chunks: [String] = []
    var windowStart = trimmed.startIndex
    let stride = windowLength - overlapLength   // 1300; > 0, so progress is guaranteed

    while windowStart < trimmed.endIndex {
      let hardEnd = trimmed.index(windowStart, offsetBy: windowLength,
                                  limitedBy: trimmed.endIndex) ?? trimmed.endIndex
      // Prefer a whitespace boundary inside the window. Only when one exists AND leaves a
      // non-trivial chunk — a window whose only space sits at position 3 should not produce a
      // 3-character chunk and then re-scan almost the same text.
      var windowEnd = hardEnd
      if hardEnd < trimmed.endIndex,
         let lastSpace = trimmed[windowStart..<hardEnd]
           .lastIndex(where: { $0.isWhitespace }),
         trimmed.distance(from: windowStart, to: lastSpace) > overlapLength {
        windowEnd = lastSpace
      }
      let chunk = trimmed[windowStart..<windowEnd].trimmingCharacters(in: .whitespacesAndNewlines)
      if !chunk.isEmpty { chunks.append(chunk) }
      if windowEnd >= trimmed.endIndex { break }
      windowStart = trimmed.index(windowStart, offsetBy: stride,
                                  limitedBy: trimmed.endIndex) ?? trimmed.endIndex
    }
    return chunks
  }
}
```

- [ ] **Step 4: Run the tests**

Run: `make test FILTER=PassageChunkerTests`
Expected: PASS, all six.

- [ ] **Step 5: Mutation-check the overlap test**

This repo has shipped vacuous tests twice and caught them only by mutation. Temporarily set `overlapLength = 0` and re-run: `windowsOverlapSoAStraddlingPhraseSurvives` **must fail**. Restore it. If it passes with zero overlap, the test is not testing overlap — fix the test before continuing.

- [ ] **Step 6: Commit**

```bash
git add Sources/PensieveKit/Transcript/PassageChunker.swift Tests/PensieveKitTests/PassageChunkerTests.swift
git commit -F - <<'EOF'
feat(kit): chunk long messages into what BM25 should score

bm25() normalises by a document's total token count, so a whole long reply is
the wrong document. Overlap is mutation-verified, not assumed.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_018KLCqkLxxL2THZNPFJpRkw
EOF
```

---

### Task 4: `PassageExtractor` — `ParsedSession` → `[Passage]`

**Files:**
- Create: `Sources/PensieveKit/Transcript/PassageExtractor.swift`
- Test: `Tests/PensieveKitTests/PassageExtractorTests.swift`

**Interfaces:**
- Consumes: `PassageChunker.chunk`, `TranscriptParser.parse`, `ParsedSession`, `TranscriptMessage`, `TextQuality.isProse`, `Passage`, `PassageRole`.
- Produces: `PassageExtractor.passages(from session: ParsedSession, nodeID: UUID, eventID: UUID, fallbackDate: Date) -> [Passage]`.

- [ ] **Step 1: Write the failing test**

Tests build `ParsedSession` values directly — no transcript files needed, since `TranscriptParser` is already tested separately.

```swift
import Foundation
import Testing
@testable import PensieveKit

@Suite struct PassageExtractorTests {
  private let nodeID = UUID()
  private let eventID = UUID()
  private let anchorDate = Date(timeIntervalSince1970: 1_700_000_000)

  private func message(_ index: Int, _ role: String, _ text: String,
                       isUserPrompt: Bool) -> TranscriptMessage {
    TranscriptMessage(index: index, role: role, text: text,
                      timestamp: Date(timeIntervalSince1970: 1_700_000_000 + Double(index)),
                      isUserPrompt: isUserPrompt)
  }

  private func extract(_ messages: [TranscriptMessage]) -> [Passage] {
    let session = ParsedSession(sessionID: "s", cwd: "/tmp", startedAt: nil, endedAt: nil,
                               userPromptCount: 0, messages: messages)
    return PassageExtractor.passages(from: session, nodeID: nodeID, eventID: eventID,
                                     fallbackDate: anchorDate)
  }

  @Test func aPromptAndItsReplyShareATurn() {
    let passages = extract([
      message(0, "user", "why does background sync refuse to spawn", isUserPrompt: true),
      message(1, "assistant", "The agent's LWCR is stale, so launchd rejects the spawn.",
              isUserPrompt: false),
    ])
    #expect(passages.count == 2)
    #expect(passages[0].role == .prompt)
    #expect(passages[1].role == .reply)
    #expect(passages[0].turnIndex == 0)
    #expect(passages[1].turnIndex == 0)
  }

  @Test func aSecondPromptStartsANewTurn() {
    let passages = extract([
      message(0, "user", "first real question about the sync agent", isUserPrompt: true),
      message(1, "assistant", "First substantive answer about launchd.", isUserPrompt: false),
      message(2, "user", "second real question about the search index", isUserPrompt: true),
      message(3, "assistant", "Second substantive answer about FTS5.", isUserPrompt: false),
    ])
    #expect(passages.map(\.turnIndex) == [0, 0, 1, 1])
  }

  /// The gate that keeps the corpus clean. A `type:"user"` record that is a tool result or an
  /// injected envelope arrives with `isUserPrompt == false` and is NOT assistant prose, so it must
  /// produce nothing at all.
  @Test func nonPromptUserRecordsAreExcluded() {
    let passages = extract([
      message(0, "user", "<system-reminder>injected body</system-reminder>", isUserPrompt: false),
      message(1, "user", "tool result payload with lots of text", isUserPrompt: false),
    ])
    #expect(passages.isEmpty)
  }

  /// An unknown role is neither a prompt nor assistant prose. `role` is not a closed set, so this
  /// must fall through rather than be stored as one or the other.
  @Test func unknownRolesAreExcluded() {
    let passages = extract([message(0, "system", "some machine envelope text", isUserPrompt: false)])
    #expect(passages.isEmpty)
  }

  @Test func degeneratePromptsAreDropped() {
    let passages = extract([
      message(0, "user", "ok", isUserPrompt: true),
      message(1, "user", "go ahead", isUserPrompt: true),
    ])
    #expect(passages.isEmpty)
  }

  /// A reply longer than the single-chunk limit becomes several passages that share their message
  /// index and their turn — that shared identity is what the retrieval layer dedupes on.
  @Test func aLongReplyBecomesSeveralPassagesSharingItsTurnAndMessageIndex() {
    let long = Array(repeating: "sentence about the retrieval index", count: 200)
      .joined(separator: " ")
    let passages = extract([
      message(0, "user", "explain the retrieval index in detail please", isUserPrompt: true),
      message(1, "assistant", long, isUserPrompt: false),
    ])
    let replies = passages.filter { $0.role == .reply }
    #expect(replies.count > 1)
    #expect(Set(replies.map(\.messageIndex)) == [1])
    #expect(Set(replies.map(\.turnIndex)) == [0])
    #expect(Set(replies.map(\.id)).count == replies.count, "each chunk is its own row")
  }

  /// A reply with no preceding prompt (a transcript that starts mid-stream, or one whose opening
  /// prompt was an injected envelope) still gets a turn rather than being dropped or crashing.
  @Test func aReplyWithNoPrecedingPromptStillGetsATurn() {
    let passages = extract([
      message(0, "assistant", "Continuing from the previous session's work.", isUserPrompt: false),
    ])
    #expect(passages.count == 1)
    #expect(passages[0].role == .reply)
    #expect(passages[0].turnIndex == 0)
  }

  @Test func aMessageWithoutATimestampFallsBackToTheAnchorDate() {
    let session = ParsedSession(sessionID: "s", cwd: "/tmp", startedAt: nil, endedAt: nil,
                               userPromptCount: 0,
                               messages: [TranscriptMessage(index: 0, role: "user",
                                                            text: "a real question about sync",
                                                            timestamp: nil, isUserPrompt: true)])
    let passages = PassageExtractor.passages(from: session, nodeID: nodeID, eventID: eventID,
                                            fallbackDate: anchorDate)
    #expect(passages.first?.occurredAt == anchorDate)
  }
}
```

- [ ] **Step 2: Run it and confirm it fails**

Run: `make test FILTER=PassageExtractorTests`
Expected: FAIL — `cannot find 'PassageExtractor' in scope`.

- [ ] **Step 3: Implement**

```swift
import Foundation

/// Turns a parsed transcript into the passages Pensieve stores.
///
/// **The corpus rule, and why it needs no new vocabulary.** Prompts are exactly the messages
/// `TranscriptParser` flags `isUserPrompt` — a conjunctive gate that already excludes tool results,
/// `isMeta` records, slash-command envelopes and injected skill bodies. Replies are exactly
/// `role == "assistant"`, which already excludes tool calls for free: `extractText` reads only
/// `text` blocks, so a tool-use-only message has empty text and never enters
/// `ParsedSession.messages`. Everything else is skipped.
///
/// `TranscriptVocabulary.injectionMarkers` is therefore READ (transitively, through
/// `isUserPrompt`) and never written, extended, or referenced here. The trust gate is untouched.
public enum PassageExtractor {
  /// Assistant prose is not put through `TextQuality.isProse`. That gate exists to drop degenerate
  /// *model output* stored as a summary ("[]", a bare "/"), and a short real answer ("Yes — the
  /// LWCR is stale.") is legitimate content whose brevity is meaningful. Prompts ARE gated, because
  /// "ok" / "go ahead" carry no recallable intent.
  public static func passages(from session: ParsedSession, nodeID: UUID, eventID: UUID,
                              fallbackDate: Date) -> [Passage] {
    var passages: [Passage] = []
    var turnIndex = 0
    var sawAnyMessageInTurn = false

    for message in session.messages {
      let role: PassageRole
      if message.isUserPrompt {
        // A new human turn. Only advance PAST the first one, so the first prompt is turn 0.
        if sawAnyMessageInTurn { turnIndex += 1 }
        sawAnyMessageInTurn = true
        guard TextQuality.isProse(message.text) else { continue }
        role = .prompt
      } else if message.role == "assistant" {
        sawAnyMessageInTurn = true
        role = .reply
      } else {
        continue   // tool result, injected envelope, unknown role — not conversation
      }
      for chunk in PassageChunker.chunk(message.text) {
        passages.append(Passage(nodeID: nodeID, eventID: eventID, turnIndex: turnIndex,
                                messageIndex: message.index, role: role, text: chunk,
                                occurredAt: message.timestamp ?? fallbackDate))
      }
    }
    return passages
  }
}
```

Note on `degeneratePromptsAreDropped`: a dropped prompt still consumes its turn (the `guard` runs after the turn bookkeeping), so a reply following "ok" is attributed to that turn rather than folded into the previous one. That is the honest reading — the turn happened, its prompt just was not worth storing.

- [ ] **Step 4: Run the tests**

Run: `make test FILTER=PassageExtractorTests`
Expected: PASS, all nine.

- [ ] **Step 5: Commit**

```bash
git add Sources/PensieveKit/Transcript/PassageExtractor.swift \
        Tests/PensieveKitTests/PassageExtractorTests.swift
git commit -F - <<'EOF'
feat(kit): extract prompts and the prose that answered them

isUserPrompt already excludes tool results and injected bodies; assistant
prose already excludes tool calls, because extractText reads only text
blocks. So this needs no new filtering vocabulary and does not touch the
trust gate.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_018KLCqkLxxL2THZNPFJpRkw
EOF
```

---

### Task 5: Write passages during ingest, idempotently

**Files:**
- Modify: `Sources/PensieveKit/Ingest/Ingester.swift:156-174` (inside `ingestSession`'s `writeSync`)
- Test: `Tests/PensieveKitTests/PassageStoreTests.swift` (extend)

**Interfaces:**
- Consumes: `PassageExtractor.passages(from:nodeID:eventID:fallbackDate:)`.
- Produces: nothing new; `ingestSession` gains a passage write.

**Context the implementer needs:** `ingestSession` already parses the transcript at line 130 (`TranscriptParser.parse`), so the `ParsedSession` is in hand — do **not** parse it a second time. It early-returns when the event is a duplicate (`dup`), and that path must **still rewrite passages**, because `TranscriptDiscovery` re-spools in-progress sessions as they grow: the event is a duplicate but the transcript has new messages. This is the whole reason the write is delete-then-insert rather than insert-only.

- [ ] **Step 1: Write the failing test**

```swift
/// The load-bearing case. An in-progress session is re-ingested as it grows: the EVENT is a
/// duplicate, but the transcript has new messages, so passages must be rewritten rather than skipped
/// or duplicated. A test that ingested only once would pass with the delete removed.
///
/// Written in the idiom `IngesterTests` / `IngesterDropTests` / `StrandBirthTests` already use —
/// `tempURL`, a real `CaptureSpool`, a real committed repo for attribution, and a transcript named
/// `<sessionID>.jsonl` (the parser derives the id from the FILENAME, not the content). There are no
/// harness structs in this suite; do not add the first one.
@Test func reIngestingAGrownSessionReplacesItsPassagesRatherThanDuplicating() async throws {
  let (repo, _) = try makeCommittedRepo()
  let spool = try CaptureSpool(at: tempURL("passage-spool"))
  let database = try openCanonicalDatabase(at: tempURL("passage-canon"))

  let sessionID = UUID().uuidString
  let transcript = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("\(sessionID).jsonl")
  func userLine(_ text: String) -> String {
    """
    {"type":"user","cwd":"\(repo.path)","sessionId":"\(sessionID)",\
    "timestamp":"2026-06-30T10:00:00Z","message":{"role":"user","content":"\(text)"}}
    """
  }
  func assistantLine(_ text: String) -> String {
    """
    {"type":"assistant","sessionId":"\(sessionID)","timestamp":"2026-06-30T10:00:01Z",\
    "message":{"role":"assistant","content":[{"type":"text","text":"\(text)"}]}}
    """
  }
  func ingest() async throws {
    try spool.append(kind: CaptureKind.ccSession,
                     payload: try encodeJSON(SessionRefPayload(transcriptPath: transcript.path)))
    _ = try await Ingester(spool: spool, database: database).drain()
  }
  func passageTexts() async throws -> [String] {
    try await database.read { database in try Passage.all.fetchAll(database) }.map(\.text)
  }

  var lines = [userLine("first real question about the sync agent"),
               assistantLine("First substantive answer about launchd.")]
  try lines.joined(separator: "\n").write(to: transcript, atomically: true, encoding: .utf8)
  try await ingest()
  #expect(try await passageTexts().count == 2)

  // The session grows and is re-spooled. Same sessionID, so the EVENT dedupes — but the transcript
  // now has two more turns, and those must appear.
  lines += [userLine("second real question about the search index"),
            assistantLine("Second substantive answer about FTS5.")]
  try lines.joined(separator: "\n").write(to: transcript, atomically: true, encoding: .utf8)
  try await ingest()

  let afterSecond = try await passageTexts()
  #expect(afterSecond.count == 4, "the grown session contributes its new turns")
  #expect(Set(afterSecond).count == 4, "and does not duplicate the turns it already had")
  let events = try await database.read { database in
    try Event.where { $0.kind.eq(CaptureKind.ccSession) }.fetchAll(database)
  }
  #expect(events.count == 1, "still one event")
}
```

Put this in `Tests/PensieveKitTests/PassageStoreTests.swift` at file scope (outside the `@Suite`), matching how `IngesterTests` writes top-level `@Test func`s.

- [ ] **Step 2: Run it and confirm it fails**

Run: `make test FILTER=reIngestingAGrownSession`
Expected: FAIL — passages are never written, so `afterFirst.count` is 0.

- [ ] **Step 3: Implement**

Inside `ingestSession`'s `writeSync` closure, the `dup` early return currently returns before any passage work. Restructure so passages are written on **both** paths. Replace:

```swift
      let dup = try eventExists(database, sourceID: source.id, fingerprint: Fingerprint.session(sessionID: session.sessionID))
      if dup { return SessionIngestOutcome(inserted: false, born: nil, branch: nil) }
```

with:

```swift
      let fingerprint = Fingerprint.session(sessionID: session.sessionID)
      // A duplicate event is NOT a no-op: `TranscriptDiscovery` re-spools in-progress sessions as
      // they grow, so the same sessionID arrives repeatedly with more messages each time. The event
      // dedupes; the passages must be rewritten from the now-longer transcript.
      if let existing = try existingEvent(database, sourceID: source.id, fingerprint: fingerprint) {
        try writePassages(database, session: session, nodeID: existing.nodeID,
                          eventID: existing.id, fallbackDate: row.timestamp)
        return SessionIngestOutcome(inserted: false, born: nil, branch: nil)
      }
```

Add the two helpers to `Ingester` (private):

```swift
  /// The existing event for this fingerprint, or nil. A sibling of `eventExists` that returns the
  /// row rather than a Bool, because the re-ingest path needs its id and node to rewrite passages.
  private func existingEvent(_ database: Database, sourceID: UUID,
                             fingerprint: String) throws -> Event? {
    try Event.where { $0.sourceID.eq(sourceID) && $0.fingerprint.eq(fingerprint) }
      .fetchOne(database)
  }

  /// Delete-then-insert, never append. Idempotent by construction: re-ingesting a grown transcript
  /// replaces this event's passages with the full current set, so the same turn can never be stored
  /// twice and a turn edited by compaction cannot leave a stale copy behind.
  ///
  /// Best-effort in spirit but NOT swallowed: this runs inside the session's own write transaction,
  /// so a throw rolls the event back too. That is deliberate — an event whose passages failed to
  /// write would look ingested and be silently unrecallable.
  private func writePassages(_ database: Database, session: ParsedSession, nodeID: UUID,
                             eventID: UUID, fallbackDate: Date) throws {
    try Passage.where { $0.eventID.eq(eventID) }.delete().execute(database)
    let passages = PassageExtractor.passages(from: session, nodeID: nodeID, eventID: eventID,
                                             fallbackDate: fallbackDate)
    guard !passages.isEmpty else { return }
    for passage in passages { try Passage.insert { passage }.execute(database) }
  }
```

And on the insert path, after `try Event.insert { … }.execute(database)` and before `resurfaceIfArchived`, capture the event so its id is available:

```swift
      let event = Event(nodeID: attr.nodeID, sourceID: source.id,
                        occurredAt: session.endedAt ?? row.timestamp,
                        kind: CaptureKind.ccSession,
                        summary: "session (\(session.userPromptCount) prompts)",
                        detailJSON: detail, fingerprint: fingerprint, branchKey: branchKey)
      try Event.insert { event }.execute(database)
      try writePassages(database, session: session, nodeID: attr.nodeID, eventID: event.id,
                        fallbackDate: row.timestamp)
```

- [ ] **Step 4: Run the test**

Run: `make test FILTER=reIngestingAGrownSession`
Expected: PASS.

- [ ] **Step 5: Mutation-check it**

Delete the `Passage.where { … }.delete()` line and re-run. The test **must fail** on the `Set(afterSecond).count == 4` assertion. Restore it. This repo's index-freshness test and its first replacement both passed with the method they tested gutted; do not skip this.

- [ ] **Step 6: Run the full suite**

Run: `make test`
Expected: PASS. Watch specifically for existing `Ingester` tests — the `dup` path changed shape.

- [ ] **Step 7: Commit**

```bash
git add Sources/PensieveKit/Ingest/Ingester.swift Tests/PensieveKitTests/PassageStoreTests.swift
git commit -F - <<'EOF'
feat(kit): write passages as sessions are ingested

Delete-then-insert per event, because a duplicate event is not a no-op:
discovery re-spools in-progress sessions as they grow, so the same session
arrives repeatedly with more messages. Mutation-verified.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_018KLCqkLxxL2THZNPFJpRkw
EOF
```

---

### Task 6: The passage FTS5 table, its own hash, and the corpus producer

**Files:**
- Modify: `Sources/PensieveKit/Search/SearchIndexStore.swift`
- Modify: `Sources/PensieveKit/Search/EmbeddableItem.swift`
- Modify: `Sources/PensieveKit/Search/SearchIndexer.swift`
- Test: `Tests/PensieveKitTests/PassageQueriesTests.swift` (create; index-level tests here)

**Interfaces:**
- Consumes: `Passage`, `EmbeddableItem`, `NodeState.searchable(includeArchived:)`.
- Produces: `EmbeddableCorpus.gatherPassages(_:) throws -> [EmbeddableItem]` (items carry `kind: "passage"`); `SearchIndexStore.rebuildPassages(items:passagesHash:)`; `SearchIndexStore.storedPassagesHash() -> String?`; `SearchIndexStore.searchPassages(_ query: FTSQuery, limit: Int, includeArchived: Bool) -> [SearchIndexHit]`; `SearchIndexer.syncPassages(_:)`.

**Critical context:** `SearchIndexStore.schemaVersion` must go **4 → 5**. The store drops and recreates on mismatch, so the new table appears for free on next open. Do not add the table without bumping, or an existing index file will never gain it.

- [ ] **Step 1: Write the failing tests**

```swift
import Foundation
import Testing
import SQLiteData
@testable import PensieveKit

// MARK: - fixtures
//
// Free functions in the style `Tests/PensieveKitTests/TestSupport.swift` already establishes
// (`tempURL`, `tempSearchStore`, `makeCommittedRepo`). There are NO harness structs in this suite —
// do not introduce the first one. These stay `private` to this file because only it uses them;
// promote to `TestSupport.swift` only if a second file needs them.
//
// `tempSearchStore()` ALREADY EXISTS in TestSupport.swift — use it rather than constructing a
// `SearchIndexStore` by hand.

private func makePassageStore() throws -> any DatabaseWriter {
  try openCanonicalDatabase(at: tempURL("passage-canon"))
}

private func insertNode(_ database: any DatabaseWriter, name: String,
                        state: NodeState = .active) throws -> Node {
  let node = Node(name: name, state: state)
  try database.write { database in try Node.insert { node }.execute(database) }
  return node
}

/// A `cc.session` event with its `Source`. `transcriptPath` is written into `detailJSON` under the
/// same key `Ingester` uses, because that is where `ProvenanceQueries.transcriptPath(in:)` reads it.
private func insertSessionEvent(_ database: any DatabaseWriter, nodeID: UUID,
                                transcriptPath: String = "") throws -> Event {
  let source = Source(nodeID: nodeID, kind: SourceKind.claudeCode,
                      key: tempURL("repo", ext: nil).path)
  let detail = try encodeJSON(["sessionID": UUID().uuidString, "prompts": "1",
                               "transcriptPath": transcriptPath])
  let event = Event(nodeID: nodeID, sourceID: source.id, occurredAt: Date(),
                    kind: CaptureKind.ccSession, summary: "session", detailJSON: detail)
  try database.write { database in
    try Source.insert { source }.execute(database)
    try Event.insert { event }.execute(database)
  }
  return event
}

@discardableResult
private func insertPassage(_ database: any DatabaseWriter, nodeID: UUID, eventID: UUID,
                           turnIndex: Int, messageIndex: Int, role: PassageRole,
                           text: String) throws -> Passage {
  let passage = Passage(nodeID: nodeID, eventID: eventID, turnIndex: turnIndex,
                        messageIndex: messageIndex, role: role, text: text,
                        occurredAt: Date(timeIntervalSince1970: 1_700_000_000))
  try database.write { database in try Passage.insert { passage }.execute(database) }
  return passage
}

private func passageItem(_ text: String, nodeID: UUID, state: NodeState = .active,
                         itemID: UUID = UUID()) -> EmbeddableItem {
  EmbeddableItem(itemID: itemID.uuidString, kind: "passage", nodeID: nodeID.uuidString,
                 state: state.rawValue, text: text)
}

/// A transcript file of alternating prompt/reply pairs, named `<sessionID>.jsonl` — load-bearing,
/// because `TranscriptParser` derives the session id from the FILENAME, not from the JSON. The
/// assistant content is an ARRAY of `text` blocks, matching the real format `extractText` reads.
private func writeTranscript(_ pairs: [(prompt: String, reply: String)]) throws -> URL {
  let id = UUID().uuidString
  let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("\(id).jsonl")
  var lines: [String] = []
  for pair in pairs {
    lines.append("""
      {"type":"user","cwd":"/tmp","sessionId":"\(id)","timestamp":"2026-06-30T10:00:00Z",\
      "message":{"role":"user","content":"\(pair.prompt)"}}
      """)
    lines.append("""
      {"type":"assistant","sessionId":"\(id)","timestamp":"2026-06-30T10:00:01Z",\
      "message":{"role":"assistant","content":[{"type":"text","text":"\(pair.reply)"}]}}
      """)
  }
  try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
  return url
}

@Suite struct PassageQueriesTests {
  @Test func passagesAreSearchableInTheirOwnTable() throws {
    let store = tempSearchStore()
    let nodeID = UUID()
    store.rebuildPassages(items: [passageItem("the LWCR is stale so launchd rejects the spawn",
                                              nodeID: nodeID)],
                          passagesHash: "h1")
    let query = try #require(FTSQueryBuilder.build("launchd spawn", file: nil))
    let hits = store.searchPassages(query, limit: 10, includeArchived: false)
    #expect(hits.count == 1)
    #expect(hits.first?.kind == "passage")
  }

  /// The whole reason passages get their own table: writing them must not touch `documents`,
  /// so the existing text ranking is byte-identical by construction.
  @Test func rebuildingPassagesLeavesTheTextIndexAlone() throws {
    let store = tempSearchStore()
    let nodeID = UUID()
    store.rebuild(items: [EmbeddableItem(itemID: UUID().uuidString, kind: "node",
                                         nodeID: nodeID.uuidString, state: NodeState.active.rawValue,
                                         text: "launchd sync agent")],
                  corpusHash: "text-1")
    store.rebuildPassages(items: [passageItem("something about launchd entirely", nodeID: nodeID)],
                          passagesHash: "pass-1")
    let query = try #require(FTSQueryBuilder.build("launchd", file: nil))
    #expect(store.search(query, limit: 10, includeArchived: false).count == 1,
            "the node document survives a passage rebuild")
    #expect(store.storedCorpusHash() == "text-1", "and its hash is untouched")
  }

  /// Symmetry: a text rebuild must not wipe passages. Without a separate hash and a separate
  /// DELETE, every new commit would silently clear the passage index.
  @Test func rebuildingTheTextIndexLeavesPassagesAlone() throws {
    let store = tempSearchStore()
    let nodeID = UUID()
    store.rebuildPassages(items: [passageItem("passage about the retrieval index", nodeID: nodeID)],
                          passagesHash: "pass-1")
    store.rebuild(items: [], corpusHash: "text-2")
    let query = try #require(FTSQueryBuilder.build("retrieval", file: nil))
    #expect(store.searchPassages(query, limit: 10, includeArchived: false).count == 1)
    #expect(store.storedPassagesHash() == "pass-1")
  }

  @Test func archivedPassagesRequireOptIn() throws {
    let store = tempSearchStore()
    let nodeID = UUID()
    store.rebuildPassages(items: [passageItem("archived talk about launchd", nodeID: nodeID,
                                              state: .archived)],
                          passagesHash: "h1")
    let query = try #require(FTSQueryBuilder.build("launchd", file: nil))
    #expect(store.searchPassages(query, limit: 10, includeArchived: false).isEmpty)
    #expect(store.searchPassages(query, limit: 10, includeArchived: true).count == 1)
  }
}
```

- [ ] **Step 2: Run and confirm failure**

Run: `make test FILTER=PassageQueriesTests`
Expected: FAIL — `value of type 'SearchIndexStore' has no member 'rebuildPassages'`.

- [ ] **Step 3: Add the table and bump the schema version**

In `SearchIndexStore`: change `schemaVersion = 4` to `5`, add the ranking constant, add the table to `open`, and add the drop.

```swift
  private static let schemaVersion = 5
  private static let passagesRanking = "bm25(document_passages)"
```

In `open`, alongside the existing drops:

```swift
          try database.execute(sql: "DROP TABLE IF EXISTS document_passages")
```

and after the `document_files` table:

```swift
        // A THIRD table, for the same measured reason `document_files` is separate: FTS5 normalises
        // bm25() by a row's TOTAL token count, so putting 1,500-character passages beside 40-character
        // node names would discount every existing hit. Sharing one table regressed P@1 0.395 → 0.378
        // (McNemar p = 0.017, n = 1500) when this was tried with file paths. Passage scores are
        // therefore NOT comparable to text scores, which is why passage results are a separate,
        // appended list rather than merged into the ranked one.
        //
        // No `item_status`: a passage has no lifecycle of its own. If a future producer gives one to
        // a passage, add the filter here AND in the canonical re-check, in the same commit.
        try database.execute(sql: """
          CREATE VIRTUAL TABLE IF NOT EXISTS document_passages USING fts5(
            text,
            item_id UNINDEXED, kind UNINDEXED, node_id UNINDEXED, state UNINDEXED,
            tokenize = 'unicode61 remove_diacritics 2')
          """)
```

Extend the `meta` table creation to carry the second hash:

```swift
        try database.execute(sql: """
          CREATE TABLE IF NOT EXISTS meta(
            schema_version INT, corpus_hash TEXT, building INT NOT NULL DEFAULT 0,
            passages_hash TEXT)
          """)
```

and the seed insert:

```swift
          try database.execute(sql: """
            INSERT INTO meta(schema_version, corpus_hash, building, passages_hash)
            VALUES (?, NULL, 0, NULL)
            """, arguments: [schemaVersion])
```

- [ ] **Step 4: Add the store methods**

```swift
  public func storedPassagesHash() -> String? {
    guard let database else { return nil }
    return try? database.read { database in
      try String.fetchOne(database, sql: "SELECT passages_hash FROM meta")
    }
  }

  /// Whole-rebuild of the passage table ONLY. Deliberately does not touch `documents`,
  /// `document_files`, `corpus_hash`, or the `building` flag: the two indexes rebuild on their own
  /// hashes, so a new commit does not rewrite tens of thousands of unchanged passage rows.
  ///
  /// `building` is not reused here because it describes the text index's state, which `state()`
  /// reports to the UI. A passage rebuild in flight must not make ⌥⌘F claim the whole index is
  /// building.
  public func rebuildPassages(items: [EmbeddableItem], passagesHash: String) {
    guard let database else { return }
    do {
      try database.write { database in
        try database.execute(sql: "DELETE FROM document_passages")
        let insert = try database.cachedStatement(sql: """
          INSERT INTO document_passages(text, item_id, kind, node_id, state)
          VALUES (?, ?, ?, ?, ?)
          """)
        for item in items {
          try insert.execute(arguments: [item.text, item.itemID, item.kind, item.nodeID, item.state])
        }
        try database.execute(sql: "UPDATE meta SET passages_hash = ?", arguments: [passagesHash])
      }
    } catch {
      Log.search.error("SearchIndexStore: passage rebuild failed: \(error, privacy: .public)")
    }
  }

  /// Passage candidates for a text query. Only `FTSQuery.terms` matter here — a passage has no file
  /// paths, so the path shapes are irrelevant and a `pathOnly` query must return nothing rather than
  /// matching passage prose against a path expression.
  public func searchPassages(_ query: FTSQuery, limit: Int,
                             includeArchived: Bool) -> [SearchIndexHit] {
    guard database != nil else { return [] }
    let match: String
    switch query.shape {
    case .pathOnly: return []
    case .textRestrictedByPath(let text, _): match = text
    case .textWithPathProbe(let text): match = text
    }
    return fetch(sql: """
      SELECT item_id, kind, node_id, -\(Self.passagesRanking) AS score
      FROM document_passages
      WHERE document_passages MATCH ?
            AND \(Self.stateFilter(includeArchived: includeArchived))
      ORDER BY \(Self.passagesRanking) LIMIT ?
      """, arguments: [match, limit])
  }
```

- [ ] **Step 5: Add the corpus producer**

In `EmbeddableItem.swift`, extend `EmbeddableCorpus`:

```swift
  /// The passage corpus, gathered from the CANONICAL `passages` table — not from transcripts. That
  /// is the simplification storing text in canonical buys: the 2026-07-19 design needed a producer
  /// with its own reconciliation path precisely because passages came from a different source than
  /// everything else. They no longer do, so pruning is membership-driven for free.
  ///
  /// Separate from `gather` rather than a `kind == "passage"` branch inside it, because the passage
  /// table rebuilds on its own hash: one mixed array would have to be partitioned and two hashes
  /// reconciled inside `rebuild`, which is the kind-conditional shape `statusFilter`'s own comment
  /// warns about.
  public static func gatherPassages(_ database: any DatabaseReader) throws -> [EmbeddableItem] {
    try database.read { database in
      let nodes = try Node.all.fetchAll(database)
        .filter { $0.state == .active || $0.state == .archived }
      let stateByNodeID = Dictionary(nodes.map { ($0.id, $0.state.rawValue) },
                                     uniquingKeysWith: { firstState, _ in firstState })
      // Ordered so the corpus hash cannot depend on SQLite's arbitrary return order — the same
      // reason `gather` orders events explicitly.
      let passages = try Passage.order { ($0.occurredAt, $0.id) }.fetchAll(database)
      return passages.compactMap { passage in
        guard let state = stateByNodeID[passage.nodeID] else { return nil }
        return EmbeddableItem(itemID: passage.id.uuidString, kind: "passage",
                              nodeID: passage.nodeID.uuidString, state: state,
                              text: passage.text)
      }
    }
  }
```

- [ ] **Step 6: Add the indexer entry point**

In `SearchIndexer`:

```swift
  /// Rebuilds the passage index when its own corpus moved. Separate from `sync` and guarded on its
  /// own hash: passages change only when a session is ingested, while nodes/loose ends/events change
  /// on every commit, so sharing one hash would rebuild ~50k passage documents for a one-line commit.
  ///
  /// Reuses `corpusHash` — the passage items carry the same fields, and `files`/`language`/`status`
  /// are constant across them, so the hash is still a faithful digest of what the table holds.
  public func syncPassages(_ database: any DatabaseReader) {
    guard store.isAvailable else { return }
    guard let corpus = try? EmbeddableCorpus.gatherPassages(database) else { return }
    let hash = Self.corpusHash(corpus)
    guard hash != store.storedPassagesHash() else { return }
    store.rebuildPassages(items: corpus, passagesHash: hash)
  }
```

Then call it from every place that already calls `sync`: `SyncRunner` (after extraction) and the app's refresh path. Find them with `grep -rn "\.sync(" Sources/ | grep -i index`.

- [ ] **Step 7: Run the tests**

Run: `make test FILTER=PassageQueriesTests`
Expected: PASS, all four.

- [ ] **Step 8: Measure the rebuild, per the spec's gate**

Write a temporary test (or a throwaway probe) that builds ~50k synthetic passage items of ~1,200 characters and times `rebuildPassages`. Record the wall-clock in the Task 1 measurements README.
**If it exceeds ~2 s, STOP and report** — the spec pre-registered that threshold as the point where the per-table hash is insufficient and incremental indexing must be specified.

- [ ] **Step 9: Run the full suite and commit**

Run: `make test`

```bash
git add Sources/PensieveKit/Search/ Tests/PensieveKitTests/PassageQueriesTests.swift \
        docs/superpowers/measurements/2026-08-14-passage-corpus/
git commit -F - <<'EOF'
feat(kit): passages get their own FTS5 table and their own hash

Own table for the reason document_files has one: bm25() normalises by a row's
total token count, so 1,500-character passages beside node names would
discount every existing hit. Own hash so a one-line commit does not rebuild
50k unchanged passage documents.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_018KLCqkLxxL2THZNPFJpRkw
EOF
```

---

### Task 7: `PassageQueries` — grounded retrieval with turn dedupe

**Files:**
- Create: `Sources/PensieveKit/Query/PassageQueries.swift`
- Test: `Tests/PensieveKitTests/PassageQueriesTests.swift` (extend)

**Interfaces:**
- Consumes: `SearchIndexStore.searchPassages`, `Passage`, `Node`, `NodeState.searchable`, `SnippetMaker.make(from:matchingAny:)`, `FTSQueryBuilder.build`.
- Produces:
  ```swift
  public struct PassageHit: Identifiable, Sendable, Equatable {
    public let id: UUID          // the passage row
    public let nodeID: UUID
    public let nodeName: String
    public let role: PassageRole
    public let occurredAt: Date
    public let snippet: Snippet
    public let score: Double
    public let isArchived: Bool
  }
  public enum PassageQueries {
    public static func search(query: String, scope: SearchScope, store: SearchIndexStore,
                              _ database: any DatabaseReader) -> [PassageHit]
  }
  ```

- [ ] **Step 1: Write the failing tests**

```swift
  /// Turn dedupe: overlap and long replies both put several chunks of ONE conversation in the
  /// candidate list, and the user must see one row, ranked by its best chunk.
  @Test func chunksOfOneTurnCollapseToASingleHit() throws {
    let database = try makePassageStore()
    let store = tempSearchStore()
    let node = try insertNode(database, name: "Pensieve")
    let event = try insertSessionEvent(database, nodeID: node.id)
    let first = try insertPassage(database, nodeID: node.id, eventID: event.id, turnIndex: 0,
                                 messageIndex: 1, role: .reply,
                                 text: "launchd refuses the spawn because the LWCR is stale")
    let second = try insertPassage(database, nodeID: node.id, eventID: event.id, turnIndex: 0,
                                  messageIndex: 1, role: .reply,
                                  text: "the LWCR is stale, so launchd refuses it again")
    store.rebuildPassages(items: try EmbeddableCorpus.gatherPassages(database),
                          passagesHash: "h1")

    let hits = PassageQueries.search(query: "launchd",
                                     scope: SearchScope(visibleNodeIDs: [node.id]),
                                     store: store, database)
    #expect(hits.count == 1, "two chunks of one turn are one conversation")
    #expect([first.id, second.id].contains(hits[0].id))
  }

  @Test func twoDifferentTurnsStayTwoHits() throws {
    let database = try makePassageStore()
    let store = tempSearchStore()
    let node = try insertNode(database, name: "Pensieve")
    let event = try insertSessionEvent(database, nodeID: node.id)
    try insertPassage(database, nodeID: node.id, eventID: event.id, turnIndex: 0,
                      messageIndex: 0, role: .prompt, text: "why does launchd refuse")
    try insertPassage(database, nodeID: node.id, eventID: event.id, turnIndex: 1,
                      messageIndex: 2, role: .prompt, text: "does launchd log the reason")
    store.rebuildPassages(items: try EmbeddableCorpus.gatherPassages(database),
                          passagesHash: "h1")
    let hits = PassageQueries.search(query: "launchd",
                                     scope: SearchScope(visibleNodeIDs: [node.id]),
                                     store: store, database)
    #expect(hits.count == 2)
  }

  /// Turn 0 exists in EVERY session, so a dedupe key of `turnIndex` alone would collapse two
  /// unrelated conversations into one row. This pins that the key includes the event.
  @Test func turnZeroOfTwoDifferentSessionsStaysTwoHits() throws {
    let database = try makePassageStore()
    let store = tempSearchStore()
    let node = try insertNode(database, name: "Pensieve")
    let firstEvent = try insertSessionEvent(database, nodeID: node.id)
    let secondEvent = try insertSessionEvent(database, nodeID: node.id)
    try insertPassage(database, nodeID: node.id, eventID: firstEvent.id, turnIndex: 0,
                      messageIndex: 0, role: .prompt, text: "why does launchd refuse the spawn")
    try insertPassage(database, nodeID: node.id, eventID: secondEvent.id, turnIndex: 0,
                      messageIndex: 0, role: .prompt, text: "launchd again, a different session")
    store.rebuildPassages(items: try EmbeddableCorpus.gatherPassages(database),
                          passagesHash: "h1")
    let hits = PassageQueries.search(query: "launchd",
                                     scope: SearchScope(visibleNodeIDs: [node.id]),
                                     store: store, database)
    #expect(hits.count == 2)
  }

  /// The last line of grounding defense. A passage deleted from canonical after the index was built
  /// must not surface, even though its index row still matches.
  @Test func aPassageDeletedFromCanonicalDoesNotSurface() throws {
    let database = try makePassageStore()
    let store = tempSearchStore()
    let node = try insertNode(database, name: "Pensieve")
    let event = try insertSessionEvent(database, nodeID: node.id)
    let passage = try insertPassage(database, nodeID: node.id, eventID: event.id, turnIndex: 0,
                                   messageIndex: 0, role: .prompt,
                                   text: "why does launchd refuse the spawn")
    store.rebuildPassages(items: try EmbeddableCorpus.gatherPassages(database),
                          passagesHash: "h1")
    try database.write { database in
      try Passage.where { $0.id.eq(passage.id) }.delete().execute(database)
    }

    let hits = PassageQueries.search(query: "launchd",
                                     scope: SearchScope(visibleNodeIDs: [node.id]),
                                     store: store, database)
    #expect(hits.isEmpty)
  }

  /// Focus muting is applied after the index, like every other search path.
  @Test func aMutedNodesPassagesAreFilteredOut() throws {
    let database = try makePassageStore()
    let store = tempSearchStore()
    let node = try insertNode(database, name: "Pensieve")
    let event = try insertSessionEvent(database, nodeID: node.id)
    try insertPassage(database, nodeID: node.id, eventID: event.id, turnIndex: 0,
                      messageIndex: 0, role: .prompt, text: "why does launchd refuse")
    store.rebuildPassages(items: try EmbeddableCorpus.gatherPassages(database),
                          passagesHash: "h1")
    #expect(PassageQueries.search(query: "launchd", scope: SearchScope(visibleNodeIDs: []),
                                  store: store, database).isEmpty)
  }

  @Test func theSnippetHighlightsWhyTheRowMatched() throws {
    let database = try makePassageStore()
    let store = tempSearchStore()
    let node = try insertNode(database, name: "Pensieve")
    let event = try insertSessionEvent(database, nodeID: node.id)
    try insertPassage(database, nodeID: node.id, eventID: event.id, turnIndex: 0,
                      messageIndex: 0, role: .prompt,
                      text: "why does launchd refuse the spawn")
    store.rebuildPassages(items: try EmbeddableCorpus.gatherPassages(database),
                          passagesHash: "h1")
    let hits = PassageQueries.search(query: "launchd",
                                     scope: SearchScope(visibleNodeIDs: [node.id]),
                                     store: store, database)
    #expect(hits.first?.snippet.match.isEmpty == false)
  }
```

These use the file-scope fixtures defined in Task 6's test file. **Note the added sixth test** (`turnZeroOfTwoDifferentSessionsStaysTwoHits`) — it exists because `turnIndex` restarts at 0 per session, so a dedupe key missing the event id would silently merge unrelated conversations. Mutation-check it too: drop `eventID` from `TurnKey` and it must fail.

- [ ] **Step 2: Run and confirm failure**

Run: `make test FILTER=PassageQueriesTests`
Expected: FAIL — `cannot find 'PassageQueries' in scope`.

- [ ] **Step 3: Implement**

```swift
import Foundation
import SQLiteData

/// One conversation that matched — a whole turn, not a chunk.
///
/// A dedicated type rather than a `SearchHit.Kind.passage` case, decided at plan time against the
/// code. `SearchQueries.buildHits` constructs `SearchHit.Kind(rawValue:)` from rows in the
/// `documents` table; a `.passage` case there would make it ACCEPT a passage row that a producer bug
/// wrote into the wrong table, resolve it, and surface it in the wrong ranked list. Disjoint enums
/// make that unrepresentable. It also keeps `role` off `SearchHit`, where it would be structurally
/// always-default for the other three kinds.
public struct PassageHit: Identifiable, Sendable, Equatable {
  public let id: UUID
  public let nodeID: UUID
  public let nodeName: String
  public let role: PassageRole
  public let occurredAt: Date
  public let snippet: Snippet
  /// Higher is better (`-bm25(document_passages)`). **Not comparable to `SearchHit.score`** — a
  /// different table with a different average document length. This is why passage results are a
  /// separate appended list and never merged into the ranked one.
  public let score: Double
  public let isArchived: Bool
}

/// Find across stored conversation passages. BM25 over `document_passages`, re-resolved against the
/// canonical `passages` table so a stale index row can never surface a dead hit — the same
/// index-decides-eligibility / canonical-decides-truth split every other retrieval path uses.
///
/// Best-effort: an unavailable index or an untypeable query yields `[]`, never a throw.
public enum PassageQueries {
  public static func search(query rawQuery: String, scope: SearchScope, store: SearchIndexStore,
                            _ database: any DatabaseReader) -> [PassageHit] {
    let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    guard store.isAvailable, query.count >= SearchQueries.minQueryLength,
          let ftsQuery = FTSQueryBuilder.build(rawQuery, file: nil) else { return [] }

    // Over-fetch for the same reasons the text path does — Focus-muting, exclusions and stale rows
    // all drop candidates after the index — plus one specific to passages: several chunks of one
    // turn collapse into a single hit, so the candidate:hit ratio is structurally worse than 1:1.
    let candidates = store.searchPassages(ftsQuery, limit: max(scope.limit * 8, 50),
                                          includeArchived: scope.includeArchived)
    guard !candidates.isEmpty else { return [] }

    do {
      return try database.read { database in
        try resolve(candidates, terms: ftsQuery.terms, scope: scope, database)
      }
    } catch {
      Log.search.error("PassageQueries: canonical read failed: \(error, privacy: .public)")
      return []
    }
  }

  /// Re-resolve candidates against canonical, collapse chunks of one turn, and keep at most
  /// `scope.limit`. Ordering is the index's — candidates arrive BM25-descending, so the first
  /// surviving chunk of a turn is also its best-scoring one, and dedupe keeps that one.
  private static func resolve(_ candidates: [SearchIndexHit], terms: [String], scope: SearchScope,
                              _ database: Database) throws -> [PassageHit] {
    var hits: [PassageHit] = []
    var seenTurns = Set<TurnKey>()
    var nodeCache: [UUID: Node] = [:]

    for candidate in candidates {
      guard candidate.kind == "passage",
            let passageID = UUID(uuidString: candidate.itemID),
            let nodeID = UUID(uuidString: candidate.nodeID),
            scope.visibleNodeIDs.contains(nodeID),
            !scope.excludingIDs.contains(passageID) else { continue }
      // Re-read from canonical: the index only decided eligibility.
      guard let passage = try Passage.where({ $0.id.eq(passageID) }).fetchOne(database)
      else { continue }
      let node: Node
      if let cached = nodeCache[passage.nodeID] {
        node = cached
      } else {
        guard let fetched = try Node.where({ $0.id.eq(passage.nodeID) }).fetchOne(database)
        else { continue }
        nodeCache[passage.nodeID] = fetched
        node = fetched
      }
      // The same allow-list the SQL filter renders, applied again here so the two cannot disagree.
      guard node.state.isSearchable(includeArchived: scope.includeArchived) else { continue }
      guard seenTurns.insert(TurnKey(eventID: passage.eventID,
                                     turnIndex: passage.turnIndex)).inserted else { continue }

      hits.append(PassageHit(id: passage.id, nodeID: passage.nodeID, nodeName: node.name,
                             role: passage.role, occurredAt: passage.occurredAt,
                             snippet: SnippetMaker.make(from: passage.text, matchingAny: terms),
                             score: candidate.score, isArchived: node.state == .archived))
      if hits.count == scope.limit { break }
    }
    return hits
  }

  /// One conversation turn. `eventID` is part of the key because `turnIndex` restarts at 0 in every
  /// session — keying on the index alone would collapse turn 0 of every session into one row.
  private struct TurnKey: Hashable {
    let eventID: UUID
    let turnIndex: Int
  }
}
```

- [ ] **Step 4: Run the tests**

Run: `make test FILTER=PassageQueriesTests`
Expected: PASS, all nine (four from Task 6, five here).

- [ ] **Step 5: Mutation-check the dedupe test**

Remove the `seenTurns.insert(...).inserted` guard and re-run: `chunksOfOneTurnCollapseToASingleHit` **must fail**. Restore it.

- [ ] **Step 6: Commit**

```bash
git add Sources/PensieveKit/Query/PassageQueries.swift Tests/PensieveKitTests/PassageQueriesTests.swift
git commit -F - <<'EOF'
feat(kit): retrieve passages as turns, not as chunks

Overlap and long replies put several chunks of one conversation in the
candidate list; the user should see one row, ranked by its best chunk. The
turn key includes the event id because turnIndex restarts per session.

PassageHit is its own type rather than a SearchHit.Kind case: adding one
would make buildHits accept a passage row that leaked into the documents
table, and would put an always-default role on every other hit.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_018KLCqkLxxL2THZNPFJpRkw
EOF
```

---

### Task 8: The surrounding window, and MCP

**Files:**
- Create: `Sources/PensieveKit/Query/PassageProvenance.swift`
- Modify: `Sources/PensieveKit/Query/SessionContextQueries.swift`
- Modify: `Sources/pensieve/Commands/Mcp.swift`
- Test: `Tests/PensieveKitTests/PassageQueriesTests.swift` (extend)

**Interfaces:**
- Consumes: `Passage`, `Event`, `ProvenanceQueries.transcriptPath(in:)`, `TranscriptParser.parse`, `ProvenanceMessage`.
- Produces: `PassageProvenance.window(_ database:, passage: Passage, radius: Int) throws -> PassageWindow` where
  ```swift
  public struct PassageWindow: Sendable {
    public let passage: Passage
    public let sourceEvent: Event
    public let messages: [ProvenanceMessage]   // empty when transcriptAvailable == false
    public let transcriptAvailable: Bool
  }
  ```
  plus `SessionContextQueries.recall(passageID: UUID, radius: Int, _ database:) throws -> RecallBundle?`.

**The critical detail.** The loose-end guard in `ProvenanceQueries` is **two-part**: the cited message must be `isUserPrompt` **AND** still contain the stored quote. **Do not reuse it for passages.** A `.reply` passage cites assistant prose, which is never `isUserPrompt`, so the two-part guard would fail for *every reply passage* and silently withhold the window from half the corpus. The passage guard is **containment only** — the message at `messageIndex` must still contain the stored text.

- [ ] **Step 1: Write the failing tests**

```swift
  /// A reply passage must get its window. The loose-end guard is two-part (isUserPrompt AND
  /// contains-quote); reusing it here would fail for every assistant passage, which is half the
  /// corpus. This test exists to pin that the guard is containment-only.
  @Test func aReplyPassageResolvesItsWindow() throws {
    let database = try makePassageStore()
    let transcript = try writeTranscript([(prompt: "why does launchd refuse the spawn",
                                           reply: "Because the LWCR is stale.")])
    let node = try insertNode(database, name: "Pensieve")
    let event = try insertSessionEvent(database, nodeID: node.id,
                                       transcriptPath: transcript.path)
    // messageIndex 1 is the ASSISTANT message: writeTranscript emits user at 0, assistant at 1.
    let passage = try insertPassage(database, nodeID: node.id, eventID: event.id, turnIndex: 0,
                                   messageIndex: 1, role: .reply,
                                   text: "Because the LWCR is stale.")
    let window = try PassageProvenance.window(database, passage: passage, radius: 4)
    #expect(window.transcriptAvailable)
    #expect(window.messages.contains { $0.isCited })
    #expect(window.messages.first { $0.isCited }?.text.contains("LWCR is stale") == true)
  }

  /// Degrade, never drop — the inversion of the 2026-07-19 design, which had no stored text to fall
  /// back on. The stored passage IS the citation once the transcript is gone.
  @Test func aMissingTranscriptDegradesHonestly() throws {
    let database = try makePassageStore()
    let node = try insertNode(database, name: "Pensieve")
    let event = try insertSessionEvent(database, nodeID: node.id,
                                       transcriptPath: "/nonexistent/gone.jsonl")
    let passage = try insertPassage(database, nodeID: node.id, eventID: event.id, turnIndex: 0,
                                   messageIndex: 1, role: .reply,
                                   text: "Because the LWCR is stale.")
    let window = try PassageProvenance.window(database, passage: passage, radius: 4)
    #expect(!window.transcriptAvailable)
    #expect(window.messages.isEmpty)
    #expect(window.passage.text == "Because the LWCR is stale.")
  }

  /// Compaction rewrites transcripts. If the message at the stored index no longer contains the
  /// stored text, the window is withheld rather than highlighting the wrong message.
  @Test func compactionThatMovedTheTextWithholdsTheWindow() throws {
    let database = try makePassageStore()
    let transcript = try writeTranscript([(prompt: "a completely different question now",
                                           reply: "A completely different answer now.")])
    let node = try insertNode(database, name: "Pensieve")
    let event = try insertSessionEvent(database, nodeID: node.id,
                                       transcriptPath: transcript.path)
    let passage = try insertPassage(database, nodeID: node.id, eventID: event.id, turnIndex: 0,
                                   messageIndex: 1, role: .reply,
                                   text: "Because the LWCR is stale.")
    let window = try PassageProvenance.window(database, passage: passage, radius: 4)
    #expect(!window.transcriptAvailable)
  }

  @Test func recallByPassageIDReturnsABundle() throws {
    let database = try makePassageStore()
    let transcript = try writeTranscript([(prompt: "why does launchd refuse the spawn",
                                           reply: "Because the LWCR is stale.")])
    let node = try insertNode(database, name: "Pensieve")
    let event = try insertSessionEvent(database, nodeID: node.id,
                                       transcriptPath: transcript.path)
    let passage = try insertPassage(database, nodeID: node.id, eventID: event.id, turnIndex: 0,
                                   messageIndex: 0, role: .prompt,
                                   text: "why does launchd refuse the spawn")
    let bundle = try SessionContextQueries.recall(passageID: passage.id, radius: 4, database)
    #expect(bundle?.transcriptAvailable == true)
    #expect(bundle?.quote == "why does launchd refuse the spawn")
  }

  @Test func recallByUnknownPassageIDReturnsNil() throws {
    let database = try makePassageStore()
    #expect(try SessionContextQueries.recall(passageID: UUID(), radius: 4, database) == nil)
  }
```

- [ ] **Step 2: Run and confirm failure**

Run: `make test FILTER=PassageQueriesTests`
Expected: FAIL — `cannot find 'PassageProvenance' in scope`.

- [ ] **Step 3: Implement `PassageProvenance`**

```swift
import Foundation
import SQLiteData

/// A passage plus the conversation around it.
public struct PassageWindow: Sendable {
  public let passage: Passage
  public let sourceEvent: Event
  /// Empty when `transcriptAvailable == false`. The passage's own `text` is then the whole citation.
  public let messages: [ProvenanceMessage]
  public let transcriptAvailable: Bool
}

/// Resolves a passage to the surrounding transcript conversation, degrading honestly.
///
/// **The guard here is deliberately ONE part, not the two `ProvenanceQueries` uses for loose ends.**
/// That guard requires the cited message to be `isUserPrompt` AND to still contain the quote, which
/// is right for a loose end — every one cites a human turn, so a non-prompt at the stored index
/// proves the index is stale. A passage legitimately cites assistant prose, so requiring
/// `isUserPrompt` would withhold the window from every `.reply` passage: half the corpus, silently.
/// Containment alone is the check that means the same thing here — the stored text must still be at
/// the stored index.
public enum PassageProvenance {
  public static func window(_ database: any DatabaseReader, passage: Passage,
                            radius: Int = 8) throws -> PassageWindow {
    guard let event = try database.read({ database in
      try Event.where { $0.id.eq(passage.eventID) }.fetchOne(database)
    }) else { throw PassageProvenanceError.anchorEventMissing }

    guard let path = ProvenanceQueries.transcriptPath(in: event),
          FileManager.default.fileExists(atPath: path) else {
      return PassageWindow(passage: passage, sourceEvent: event, messages: [],
                           transcriptAvailable: false)
    }
    let session = TranscriptParser.parse(fileURL: URL(fileURLWithPath: path))
    return window(session: session, passage: passage, event: event, radius: radius)
  }

  /// The pure half, so a caller holding an already-parsed transcript does not re-parse it — the same
  /// split `ProvenanceQueries` makes for `ProvenanceLoader`.
  public static func window(session: ParsedSession, passage: Passage, event: Event,
                            radius: Int = 8) -> PassageWindow {
    // The one-part guard. `messageIndex` addresses `ParsedSession.messages`, which only holds
    // non-empty messages, so a compacted transcript can shift it — containment is what detects that.
    guard let cited = session.messages.first(where: { $0.index == passage.messageIndex }),
          cited.text.contains(passage.text) else {
      return PassageWindow(passage: passage, sourceEvent: event, messages: [],
                           transcriptAvailable: false)
    }
    let lower = max(0, passage.messageIndex - radius)
    let upper = passage.messageIndex + radius
    let messages = session.messages
      .filter { $0.index >= lower && $0.index <= upper }
      .map { ProvenanceMessage(index: $0.index, role: $0.role, text: $0.text,
                               isCited: $0.index == passage.messageIndex,
                               isUserPrompt: $0.isUserPrompt) }
    return PassageWindow(passage: passage, sourceEvent: event, messages: messages,
                         transcriptAvailable: true)
  }
}

public enum PassageProvenanceError: Error {
  /// The anchor event is gone but the passage is not. The FK cascades, so this means canonical
  /// integrity was violated rather than that the session was simply deleted.
  case anchorEventMissing
}
```

If `ProvenanceMessage`'s initializer is not `public`, make it so (it is a `public struct` with `public let`s, so it may only have the implicit internal memberwise init).

- [ ] **Step 4: Add `recall(passageID:)`**

In `SessionContextQueries`, beside the existing `recall`:

```swift
  /// `recall`, keyed by a passage instead of a loose end. Reuses `RecallBundle` unchanged: the shape
  /// is already "a cited thing, its verbatim text, and the window around it", and a passage is
  /// exactly that. `looseEndText` carries the node-facing label and `quote` the verbatim passage, so
  /// a client that already handles loose-end recall needs no new field.
  public static func recall(passageID: UUID, radius: Int,
                            _ database: any DatabaseReader) throws -> RecallBundle? {
    guard let passage = try database.read({ database in
      try Passage.where { $0.id.eq(passageID) }.fetchOne(database)
    }) else { return nil }
    let window = try PassageProvenance.window(database, passage: passage, radius: radius)
    return RecallBundle(
      looseEndText: passage.role == .prompt ? "You asked" : "Claude answered",
      quote: passage.text,
      transcriptAvailable: window.transcriptAvailable,
      sessionOccurredAt: window.sourceEvent.occurredAt,
      messages: window.messages.map { RecallMessage(index: $0.index, role: $0.role, text: $0.text,
                                                    isCited: $0.isCited,
                                                    isUserPrompt: $0.isUserPrompt) })
  }
```

- [ ] **Step 5: Wire MCP**

In `Mcp.swift`, `recall`'s schema gains `passage_id` and its `required` drops to none-of-two-but-one-needed:

```swift
      Tool(name: "recall",
           description: "Recall the surrounding transcript conversation around a loose end or a stored "
             + "passage — reconstruct how a discussion went and how it resolved. Pass a loose_end_id "
             + "from project_context, or a passage_id from search.",
           inputSchema: .object(["type": .string("object"), "properties": .object([
             "loose_end_id": .object(["type": .string("string"), "description": .string("UUID of a loose end from project_context")]),
             "passage_id": .object(["type": .string("string"), "description": .string("UUID of a passage item from search")]),
             "radius": .object(["type": .string("number"), "description": .string("messages of context each side (default 8)")]),
           ])]),
           annotations: .init(readOnlyHint: true, openWorldHint: false)),
```

`handleRecall` accepts either:

```swift
  private static func handleRecall(params: CallTool.Parameters) throws -> CallTool.Result {
    let radius = params.arguments?["radius"]?.intValue ?? 8
    if let raw = params.arguments?["loose_end_id"]?.stringValue, let id = UUID(uuidString: raw) {
      return PensieveMCP.result(try PensieveMCP.recallJSON(looseEndID: id, radius: radius))
    }
    if let raw = params.arguments?["passage_id"]?.stringValue, let id = UUID(uuidString: raw) {
      return PensieveMCP.result(try PensieveMCP.recallJSON(passageID: id, radius: radius))
    }
    return .init(content: [.text(text: "recall requires a valid loose_end_id or passage_id (UUID)",
                                 annotations: nil, _meta: nil)], isError: true)
  }
```

Add the sibling JSON builder next to `recallJSON`:

```swift
  static func recallJSON(passageID: UUID, radius: Int) throws -> Data {
    guard let database = try? openCanonicalReadOnly() else {
      return try makeEncoder().encode(Optional<RecallBundle>.none)
    }
    let bundle = try SessionContextQueries.recall(passageID: passageID, radius: radius, database)
    return try makeEncoder().encode(bundle)
  }
```

In `searchJSON`, append passage items after the ranked ones. Order is the contract, and passages come last because their scores are not comparable:

```swift
    let items = ranked.map { SearchItem(hit: $0) }
    // Appended, never interleaved: passage scores come from a different FTS5 table with a different
    // average document length, exactly like path hits. The array order is the contract the tool
    // description states, and this preserves it.
    let passages = PassageQueries.search(query: query, scope: scope, store: searchStore, database)
    return try makeEncoder().encode(
      SearchPayload(items: items + passages.map { SearchItem(passage: $0) },
                    indexState: searchStore.state()))
```

and give `SearchItem` the second initializer:

```swift
  /// A passage item. `kind` is `"passage"` and `id` is the passage UUID, which `recall`'s
  /// `passage_id` accepts — so a model that finds a conversation can read it back in one more call.
  init(passage: PassageHit) {
    id = passage.id.uuidString
    kind = "passage"
    nodeID = passage.nodeID.uuidString
    nodeName = passage.nodeName
    title = passage.role == .prompt ? "You asked" : "Claude answered"
    snippet = passage.snippet.leading + passage.snippet.match + passage.snippet.trailing
    score = passage.score
    archived = passage.isArchived
    closed = false   // a passage has no lifecycle of its own
  }
```

Update the `search` tool description to mention passages: append `"Results include stored conversation passages — pass a passage item's id to `recall` to read the surrounding discussion."`

- [ ] **Step 6: Run the tests and build the CLI**

Run: `make test FILTER=PassageQueriesTests` → PASS
Run: `make test` → PASS
Run: `make cli` → check for `** BUILD SUCCEEDED **` in the log (do not pipe to `tail` and read `$?`).

- [ ] **Step 7: Mutation-check the one-part guard**

Add `cited.isUserPrompt &&` to the guard and re-run: `aReplyPassageResolvesItsWindow` **must fail**. Remove it. That test exists solely to prevent someone "fixing" this guard into the loose-end one.

- [ ] **Step 8: Commit**

```bash
git add Sources/PensieveKit/Query/PassageProvenance.swift \
        Sources/PensieveKit/Query/SessionContextQueries.swift \
        Sources/pensieve/Commands/Mcp.swift Tests/PensieveKitTests/PassageQueriesTests.swift
git commit -F - <<'EOF'
feat: read a passage back with its surrounding conversation

The guard is containment-only, deliberately: the loose-end guard also
requires isUserPrompt, which is right for a loose end and would withhold the
window from every reply passage — half the corpus. Mutation-verified so
nobody "fixes" it into the two-part version.

MCP recall now takes a passage_id, and search appends passage items after the
ranked list, because their scores come from a different table.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_018KLCqkLxxL2THZNPFJpRkw
EOF
```

---

### Task 9: `pensieve backfill-passages` — win the retention race

**Files:**
- Create: `Sources/pensieve/Commands/BackfillPassages.swift`
- Modify: `Sources/pensieve/Pensieve.swift` (register the subcommand)

**Interfaces:**
- Consumes: `Passage`, `PassageExtractor`, `TranscriptParser`, `ProvenanceQueries.transcriptPath(in:)`, `SearchIndexer.production().syncPassages`.
- Produces: a CLI subcommand. No Kit API.

**Why this is its own task and runs late:** it needs everything above to exist, but it must run **as soon as it exists** — transcripts age out continuously and each one lost is permanent.

- [ ] **Step 1: Write the command**

Follow the established pattern of a neighbouring command in `Sources/pensieve/Commands/` (`ArgumentParser` `ParsableCommand`, `PensievePaths` for the store URL, honouring `PENSIEVE_DB`).

```swift
import ArgumentParser
import Foundation
import PensieveKit
import SQLiteData

/// One-time backfill of passages for already-ingested sessions whose transcripts still exist.
///
/// Idempotent: it rewrites each event's passages wholesale, exactly like the ingest path, so running
/// it twice is harmless and a partial run can simply be re-run. Reports what it could NOT do, because
/// a transcript that has aged out is unrecoverable and the count is the honest measure of what this
/// feature can still reach.
struct BackfillPassages: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "backfill-passages",
    abstract: "Extract passages from already-captured sessions whose transcripts still exist.")

  @Flag(name: .long, help: "Report what would be written without writing anything.")
  var dryRun = false

  func run() throws {
    let database = try openCanonicalDatabase(at: PensievePaths.canonicalURL())
    let events = try database.read { database in
      try Event.where { $0.kind.eq(CaptureKind.ccSession) }
        .order { ($0.occurredAt, $0.id) }
        .fetchAll(database)
    }
    var written = 0, sessionsCovered = 0, transcriptsGone = 0, alreadyHad = 0

    for event in events {
      guard let path = ProvenanceQueries.transcriptPath(in: event),
            FileManager.default.fileExists(atPath: path) else {
        transcriptsGone += 1
        continue
      }
      let existing = try database.read { database in
        try Passage.where { $0.eventID.eq(event.id) }.fetchCount(database)
      }
      let session = TranscriptParser.parse(fileURL: URL(fileURLWithPath: path))
      let passages = PassageExtractor.passages(from: session, nodeID: event.nodeID,
                                               eventID: event.id,
                                               fallbackDate: event.occurredAt)
      guard !passages.isEmpty else { continue }
      if existing > 0 { alreadyHad += 1 }
      sessionsCovered += 1
      written += passages.count
      guard !dryRun else { continue }
      try database.write { database in
        try Passage.where { $0.eventID.eq(event.id) }.delete().execute(database)
        for passage in passages { try Passage.insert { passage }.execute(database) }
      }
    }

    print("sessions with a live transcript: \(sessionsCovered) (\(alreadyHad) already had passages)")
    print("transcripts gone, unrecoverable:  \(transcriptsGone)")
    print("passages \(dryRun ? "that would be written" : "written"): \(written)")
    if !dryRun {
      // The index is derived; rebuild it once at the end rather than per session.
      SearchIndexer.production().syncPassages(database)
      print("passage index rebuilt")
    }
  }
}
```

Register it in `Pensieve.swift`'s `subcommands` array, alongside the existing commands.

- [ ] **Step 2: Build and dry-run against a THROWAWAY store**

```bash
make cli 2>&1 | tee /tmp/cli-build.log | grep -c "BUILD SUCCEEDED"
PENSIEVE_DB=/tmp/backfill-probe.sqlite PENSIEVE_CAPTURE_DB=/tmp/backfill-probe-capture.sqlite \
  ./.build-xcode/Build/Products/Debug/pensieve backfill-passages --dry-run
```

Expected: it runs, reports zeros (an empty throwaway store has no events), and does not touch the real store.

- [ ] **Step 3: Dry-run against the LIVE store**

**No `PENSIEVE_DB`.** Read-only in effect, since `--dry-run` writes nothing:

```bash
./.build-xcode/Build/Products/Debug/pensieve backfill-passages --dry-run
```

Sanity-check the output against Task 1's measurement: `sessions with a live transcript` should be ≈393 and `transcripts gone` ≈703. **If those numbers disagree materially with Task 1, STOP and report** — one of the two is wrong and writing 40k rows on a wrong premise is not recoverable by a rebuild.

- [ ] **Step 4: Run it for real**

```bash
./.build-xcode/Build/Products/Debug/pensieve backfill-passages
```

Then verify:

```bash
sqlite3 "file:$HOME/Library/Application Support/Pensieve/pensieve.sqlite?mode=ro" \
  "select role, count(*) from passages group by role;"
sqlite3 "file:$HOME/Library/Application Support/Pensieve/pensieve.sqlite?mode=ro" \
  "select count(distinct eventID) from passages;"
ls -lh "$HOME/Library/Application Support/Pensieve/pensieve.sqlite" \
       "$HOME/Library/Application Support/Pensieve/search-index.sqlite"
```

Record the real counts and the resulting file sizes in the Task 1 measurements README, next to the estimates. This is the number that either confirms or refutes the spec's ~30 MB projection.

- [ ] **Step 5: Re-run to prove idempotence**

Run it a second time. `passages written` should be identical and `already had passages` should now equal `sessions with a live transcript`. Confirm `select count(*) from passages` is unchanged.

- [ ] **Step 6: Commit**

```bash
git add Sources/pensieve/Commands/BackfillPassages.swift Sources/pensieve/Pensieve.swift \
        docs/superpowers/measurements/2026-08-14-passage-corpus/
git commit -F - <<'EOF'
feat(cli): backfill passages while the transcripts still exist

703 of 1,096 transcripts are already gone and the rest age out continuously,
so this runs the moment it exists. Idempotent (delete-then-insert per event),
and it reports the unrecoverable count rather than hiding it.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_018KLCqkLxxL2THZNPFJpRkw
EOF
```

---

### Task 10: The ⌥⌘F "From your conversations" section

**Files:**
- Create: `Sources/PensieveApp/PassageResultsSection.swift`
- Modify: `Sources/PensieveApp/AppModel.swift` (or `AppModel+Middle.swift` if search state lives there — check both; `AppModel.swift` is near the 400-line lint cap, so prefer the extension file)
- Modify: `Sources/PensieveApp/ContentListView.swift`
- Modify: `Sources/PensieveApp/Localizable.xcstrings`

**Interfaces:**
- Consumes: `PassageQueries.search(query:scope:store:_:)`, `PassageHit`, `PassageProvenance.window(_:passage:radius:)`, the existing `TranscriptMessageView` / `HighlightedText`.
- Produces: no Kit API. App-target only.

**Constraints specific to this task:**
- The app target **has no unit tests.** Verify with `make build` plus an eyeball pass; put no derivation logic here.
- `AppModel.swift` was at 404 lines once and had to be split. **Check `wc -l` before adding to it** and use `AppModel+Middle.swift` / a new extension file if it would cross 400.
- **String Catalog keys must be hand-authored.** `xcodebuild` does not extract them (IDE-only). A mis-keyed `de` value silently falls back to English — six such entries shipped once. After editing, verify with `plutil -p` on the built `de.lproj/Localizable.strings`.

- [ ] **Step 1: Add the search state**

Wherever `runSearch` lives, add a parallel `passageHits` published property and populate it in the same task, from the **same snapshotted scope** the exact search uses:

```swift
    // Same scope, same query, separate list — passage BM25 scores are not comparable to the ranked
    // list's, so they are appended as their own section rather than merged.
    let passages = PassageQueries.search(query: query, scope: scope, store: searchStore, database)
```

Snapshot the scope into a local before the `Task`, exactly as the include-archived work does — reading `self.searchScope` inside the task races the user changing it.

- [ ] **Step 2: Write the section view**

```swift
import PensieveKit
import SwiftUI

/// ⌥⌘F results from stored conversation passages, rendered as its own section BELOW the ranked list.
///
/// Not merged into that list, and this is a correctness point rather than a layout preference:
/// passage scores come from a different FTS5 table with a different average document length, so
/// interleaving them would order two incomparable scales against each other — the same reason
/// `SearchIndexStore.search` appends path hits instead of interleaving them.
struct PassageResultsSection: View {
  let hits: [PassageHit]
  let onOpen: (PassageHit) -> Void

  var body: some View {
    if !hits.isEmpty {
      Section {
        ForEach(hits) { hit in
          Button { onOpen(hit) } label: { PassageResultRow(hit: hit) }
            .buttonStyle(.plain)
        }
      } header: {
        Text("From your conversations")
      }
    }
  }
}

private struct PassageResultRow: View {
  let hit: PassageHit

  var body: some View {
    VStack(alignment: .leading, spacing: 3) {
      HStack(spacing: 6) {
        Image(systemName: hit.role == .prompt ? "person.crop.circle" : "sparkle")
          .foregroundStyle(.secondary)
        // Speaker is chrome and IS localized; the passage text below is captured content and is not.
        Text(hit.role == .prompt ? "You" : "Claude")
          .font(.system(size: 12, weight: .medium))
        Text(hit.nodeName)
          .font(.system(size: 12))
          .foregroundStyle(.secondary)
        Spacer(minLength: 0)
        Text(hit.occurredAt, format: .relative(presentation: .named))
          .font(.system(size: 12))
          .foregroundStyle(.secondary)
        if hit.isArchived {
          Text("Archived")
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
        }
      }
      SnippetText(snippet: hit.snippet)
        .font(.system(size: 13))
        .lineLimit(3)
    }
    .padding(.vertical, 2)
    // The row's whole width must be hoverable/clickable — a Spacer is dead space to hit-testing,
    // which is exactly how slice A shipped unreachable hover controls.
    .contentShape(Rectangle())
  }
}
```

Reuse the existing `SnippetText` (it is already expressed over `HighlightedText`); do not write a third highlight renderer.

- [ ] **Step 3: Mount it in `ContentListView`**

Add `PassageResultsSection(hits: model.passageHits) { model.openPassage($0) }` after the existing results section, inside the same `List`. `openPassage` navigates to `hit.nodeID` — reuse the existing node-selection path; opening the transcript window in place is **out of scope** for this task (the detail pane belongs to design slice C).

- [ ] **Step 4: Add the String Catalog entries by hand**

Three keys — `"From your conversations"`, `"You"`, `"Claude"` — each with an `en` and a `de` value. German: `"Aus deinen Gesprächen"`, `"Du"`, `"Claude"` (a proper name, unchanged). **Note the vocabulary check:** the catalog already renders a transcript speaker as `Du`, so reuse that spelling rather than introducing `Sie`.

- [ ] **Step 5: Build and smoke**

```bash
make build 2>&1 | tee /tmp/app-build.log | grep -c "BUILD SUCCEEDED"
plutil -p ./.build-xcode/Build/Products/Debug/Pensieve.app/Contents/Resources/de.lproj/Localizable.strings \
  | grep -i "Gespräch"
```

Then launch the built app against a **throwaway** store and confirm it starts:

```bash
PENSIEVE_DB=/tmp/smoke.sqlite PENSIEVE_CAPTURE_DB=/tmp/smoke-capture.sqlite \
  ./.build-xcode/Build/Products/Debug/Pensieve.app/Contents/MacOS/Pensieve &
sleep 4; kill %1
```

Be aware this smoke recipe is known **not** to exercise view code (`AppModel.start()` runs from `.task` on a rendered body, and a backgrounded direct-exec never renders one). It proves the binary links, nothing more. The real check is the eyeball pass below.

- [ ] **Step 6: Eyeball it against the live store**

`make run`, then ⌥⌘F a phrase you remember saying but never wrote into a loose end. Confirm: the section appears below the ranked list; the speaker/node/date line reads correctly; the snippet highlights the matched term; clicking navigates to the right node; a term with no passage match shows no empty section. Then relaunch with `-AppleLanguages '(de)'` and check the German heading does not truncate.

- [ ] **Step 7: Commit**

```bash
xcodegen generate
git add Sources/PensieveApp/ docs/
git commit -F - <<'EOF'
feat(app): find the conversation, not just the project

A separate section below the ranked list, because passage BM25 scores come
from a different table and interleaving would order two incomparable scales
against each other.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_018KLCqkLxxL2THZNPFJpRkw
EOF
```

---

## Verification before calling this done

- [ ] `make all` is green (lint + test + build + smoke, in CI's order).
- [ ] Task 1's measurement README records: parser-faithful corpus counts, the rebuild wall-clock, and the **real** post-backfill row counts and file sizes beside the spec's estimates.
- [ ] **All five mutation checks were actually run and actually failed** — not reasoned about, run:
  1. Task 3: `overlapLength = 0` → `windowsOverlapSoAStraddlingPhraseSurvives` fails.
  2. Task 5: drop the `Passage.where{}.delete()` → the re-ingest test fails on its `Set(...).count` assertion.
  3. Task 7: drop the `seenTurns` guard → `chunksOfOneTurnCollapseToASingleHit` fails.
  4. Task 7: drop `eventID` from `TurnKey` → `turnZeroOfTwoDifferentSessionsStaysTwoHits` fails.
  5. Task 8: add `cited.isUserPrompt &&` to the guard → `aReplyPassageResolvesItsWindow` fails.

  This project has shipped vacuous tests twice and caught them only by mutation — including a case where the plan's own test *and its first replacement* both passed with the method they tested deleted.
- [ ] `pensieve backfill-passages` run twice, second run idempotent.
- [ ] `pensieve mcp` from a real Claude Code session: `search` returns `kind: "passage"` items, and `recall` with that item's `passage_id` returns the window. **Requires reinstalling to `/Applications` first** (`make install`) — the bundled binary is what a session calls.
- [ ] Trust gate untouched: `git diff main --stat` shows **no** change to `TranscriptVocabulary.swift`, and `grep -rn "injectionMarkers" Sources/` shows no new call site.
- [ ] `SearchQueries.swift`, `SearchHit.swift` and `SearchHitResolver.swift` are **unmodified** (the plan-time deviation) — `git diff main --stat` should not list them.

## Human-verify carries (add to `CONTINUE.md` on merge)

- Does the passage section actually help, or does it bury the ranked list? The corpus is ~15× the existing one; if it dominates the page, the fix is a cap on the section, not a relevance floor (BM25 scores are unbounded and per-query-scaled — a rank cap is not a relevance threshold).
- German in situ for the three new keys.
- A passage from an **aged-out** session: does it still return, and does clicking it degrade honestly rather than looking broken?
- Does ⌥⌘F feel slower now that a second index is queried per keystroke?

## Self-review notes

**Spec coverage.** Every spec section maps to a task: storage/identity → 2; extraction vocabulary → 4; chunking + turn model → 3, 7; producer → 6; rebuild cost → 6 (with the gate); ingest + retention race → 5, 9; grounding/degrade → 8; surfaces → 8 (MCP), 10 (app); pre-registered gates → 1, 6, 9; testing → each task's tests.

**One spec requirement deliberately not implemented as written:** `SearchHit.Kind.passage`. Reasoned above under *Deviation*; `PassageHit` replaces it. The spec should be treated as superseded on that one line.

**Not covered, and correctly out of scope per the spec:** a detail-pane Conversations section, tool-output indexing, recovering the 703 lost transcripts, and purging the `claude -p` residue (`backlog.md`).
