# Ingestion Intelligence Quality Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Raise the quality of Pensieve's ingestion intelligence — narration that describes real work, narration that persists across launches, and loose ends that capture deferred/decision work instead of every prompt — on-device first, trust gate untouched.

**Architecture:** Three coordinated parts on the existing PensieveKit intelligence layer. **B** stores a grounded per-session `workSummary` on `cc.session` events (migration v10) and narrates over it under a bounded fact sheet. **C** persists narration prose in `UserDefaults` (per-DB-path) keyed by an order-independent invalidation key, regenerating only on change (⌘R force-regenerates the selection). **A** adds a `SalienceClassifier` stage after the verbatim gate plus a sharpened extractor prompt, gated by a hand-labeled eval, then a one-shot retroactive re-mine. Executed in the order **B+C → A → re-mine**.

**Tech Stack:** Swift 6, SQLiteData (GRDB), Apple FoundationModels (on-device default) / `claude -p` fallback via the `LLMProvider` protocol, SwiftUI (app target), Swift Testing, XcodeGen + Xcode for the app bundle.

## Global Constraints

- **Swift only. No Python, ever.**
- **The verbatim trust gate (`LooseEndVerifier`) is UNTOUCHED.** Every surfaced loose end still cites real user text.
- **The capture path and `Ingester.drain()` stay LLM-free and fast.** No new work goes into drain or the git hooks.
- **All new LLM judgments run on `makeDefaultLLMProvider()`** (Foundation Models when available, else `claude -p`). On-device first; the provider is the only swap seam.
- **SQLiteData predicates use `.eq(x)`, NOT `== x`.** Tables are `STRICT`; PKs are `UUID`; migrations are additive.
- **`workSummary` is best-effort:** `SessionSummarizer.summarize` is **non-throwing** (returns `String?`), computed **before** the synchronous `db.write` and never inside `ExtractionRunner`'s per-session `do/catch`. A nil/absent summary must never skip a loose-end insert or a watermark advance.
- **The app target (`Sources/PensieveApp/`) has no unit tests.** Verify app tasks with `xcodegen generate && xcodebuild -project Pensieve.xcodeproj -scheme Pensieve -configuration Debug -derivedDataPath ./.build-xcode build`, then a non-blocking smoke-launch of the inner binary (`./.build-xcode/Build/Products/Debug/Pensieve.app/Contents/MacOS/Pensieve`, background + `kill`) with throwaway `PENSIEVE_DB`/`PENSIEVE_CAPTURE_DB`. Keep derivation logic in tested PensieveKit; keep views thin.
- **Kit tests:** `./scripts/test.sh` (thin `swift test` passthrough), or `./scripts/test.sh --filter <name>`.
- **App chrome strings are localized** (English base + German `de`) via `Sources/PensieveApp/Localizable.xcstrings`, hand-reconciled (xcodebuild does not auto-populate keys). Content (node names, quotes, `workSummary`) is never localized.
- **Commit-message trailers** on every commit:
  ```
  Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_01Ya7ToQ9MrGVDLzHkDB1mg3
  ```
  Backticks in a `-m` message get shell-executed — use `git commit -F` with a quoted heredoc.

---

## File Structure

**Part B — narration substance**
- Modify `Sources/PensieveKit/Model/Event.swift` — add `workSummary: String?`.
- Modify `Sources/PensieveKit/Store/CanonicalStore.swift` — migration `v10-event-worksummary`.
- Create `Sources/PensieveKit/Intelligence/SessionSummarizer.swift` — best-effort, map-reduce, char-capped per-session summarizer.
- Modify `Sources/PensieveKit/Intelligence/SummaryBuilder.swift` — `assembleFacts` composes over `workSummary` under a fact-sheet budget.
- Modify `Sources/PensieveKit/Intelligence/ExtractionRunner.swift` — compute `workSummary` (`try?`, pre-write) and persist it.
- Modify `Sources/PensieveApp/DetailView.swift` + `Localizable.xcstrings` — "generated" affordance.

**Part C — narration persistence**
- Create `Sources/PensieveKit/Intelligence/NarrationCacheKey.swift` — order-independent invalidation key.
- Modify `Sources/PensieveApp/AppModel.swift` — persisted per-DB-path cache + key-based invalidation + ⌘R force.

**Part A — loose-end salience**
- Modify `Sources/PensieveKit/LLM/LLMProvider.swift` — `classifyNonSalientIndices` + default extension.
- Modify `Sources/PensieveKit/LLM/FoundationModelsProvider.swift` — schema override.
- Create `Sources/PensieveKit/Intelligence/SalienceClassifier.swift` — the drop stage.
- Modify `Sources/PensieveKit/Intelligence/LooseEndExtractor.swift` — sharpened `buildPrompt`.
- Modify `Sources/PensieveKit/Intelligence/ExtractionRunner.swift` — wire the stage after `verify`.
- Create the eval fixture + harness (`Tests/PensieveKitTests/Fixtures/salience-labels.json`, `SalienceEvalTests.swift`).
- `docs/superpowers/runbooks/2026-07-08-salience-retroactive-remine.md` — the one-shot cleanup runbook.

**Tests (create)**
- `Tests/PensieveKitTests/SchemaV10Tests.swift`
- `Tests/PensieveKitTests/SessionSummarizerTests.swift`
- `Tests/PensieveKitTests/NarrationCacheKeyTests.swift`
- `Tests/PensieveKitTests/SalienceClassifierTests.swift`
- extend `Tests/PensieveKitTests/SummaryBuilderTests.swift`, `ExtractionRunnerTests.swift`, `LooseEndExtractorTests.swift`.

---

# PART B — Narration substance

## Task B1: Migration v10 + `Event.workSummary`

**Files:**
- Modify: `Sources/PensieveKit/Model/Event.swift`
- Modify: `Sources/PensieveKit/Store/CanonicalStore.swift:140-143`
- Test: `Tests/PensieveKitTests/SchemaV10Tests.swift`

**Interfaces:**
- Produces: `Event.workSummary: String?` (canonical column `workSummary`, nullable).

- [ ] **Step 1: Write the failing test**

Create `Tests/PensieveKitTests/SchemaV10Tests.swift`:

```swift
import Foundation
import Testing
import SQLiteData
@testable import PensieveKit

@Test func v10AddsWorkSummaryColumnNullableByDefault() throws {
  let db = try openCanonicalDatabase(at: tempURL("v10"))
  let node = Node(name: "Pensieve")
  try db.write { db in try Node.insert { node }.execute(db) }
  let event = Event(nodeID: node.id, sourceID: UUID(), occurredAt: Date(),
                    kind: CaptureKind.ccSession, summary: "session (3 prompts)", detailJSON: "{}")
  try db.write { db in try Event.insert { event }.execute(db) }

  // New rows read nil (never enriched yet).
  let stored = try db.read { db in try Event.where { $0.id.eq(event.id) }.fetchOne(db) }
  #expect(stored?.workSummary == nil)

  // A value round-trips through the nullable column.
  try db.write { db in
    try Event.where { $0.id.eq(event.id) }.update { $0.workSummary = "Built the sync daemon." }.execute(db)
  }
  let updated = try db.read { db in try Event.where { $0.id.eq(event.id) }.fetchOne(db) }
  #expect(updated?.workSummary == "Built the sync daemon.")
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `./scripts/test.sh --filter v10AddsWorkSummaryColumnNullableByDefault`
Expected: FAIL — `Event` has no member `workSummary` (compile error).

- [ ] **Step 3: Add the field to `Event`**

In `Sources/PensieveKit/Model/Event.swift`, add the stored property after `createdAt` (line 18) and the init param + assignment. Full struct body:

```swift
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
  public var extractedTranscriptSize: Int // transcript byte size at last extraction; -1 = never watermarked
  public var workSummary: String?   // best-effort on-device recap of what this session did; nil = un-enriched
  public var createdAt: Date
  public init(id: UUID = UUID(), nodeID: UUID, sourceID: UUID, occurredAt: Date,
              kind: String, summary: String, detailJSON: String,
              fingerprint: String? = nil, branchKey: String? = nil, extractedAt: Date? = nil,
              extractedMessageCount: Int = 0, extractedTranscriptSize: Int = -1,
              workSummary: String? = nil, createdAt: Date = Date()) {
    self.id = id; self.nodeID = nodeID; self.sourceID = sourceID; self.occurredAt = occurredAt
    self.kind = kind; self.summary = summary; self.detailJSON = detailJSON
    self.fingerprint = fingerprint; self.branchKey = branchKey; self.extractedAt = extractedAt
    self.extractedMessageCount = extractedMessageCount; self.extractedTranscriptSize = extractedTranscriptSize
    self.workSummary = workSummary; self.createdAt = createdAt
  }
}
```

- [ ] **Step 4: Register migration v10**

In `Sources/PensieveKit/Store/CanonicalStore.swift`, add after the `v9-node-context` block (line 142), before `try migrator.migrate(db)`:

```swift
  migrator.registerMigration("v10-event-worksummary") { db in
    // Nullable: existing rows read NULL (un-enriched) and re-enrich on their next
    // size-changed extraction. Never gates anything — best-effort narration input.
    try #sql(#"ALTER TABLE "events" ADD COLUMN "workSummary" TEXT"#).execute(db)
  }
```

- [ ] **Step 5: Run test to verify it passes**

Run: `./scripts/test.sh --filter v10AddsWorkSummaryColumnNullableByDefault`
Expected: PASS.

- [ ] **Step 6: Run the full suite (no regressions from the new column)**

Run: `./scripts/test.sh`
Expected: PASS (existing `Event(...)` call sites compile via the defaulted param).

- [ ] **Step 7: Commit**

```bash
git add Sources/PensieveKit/Model/Event.swift Sources/PensieveKit/Store/CanonicalStore.swift Tests/PensieveKitTests/SchemaV10Tests.swift
git commit -F - <<'EOF'
feat(kit): add events.workSummary column (migration v10)

Nullable per-session work summary for narration; existing rows read nil
and re-enrich on next extraction. Additive; nothing gates on it.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01Ya7ToQ9MrGVDLzHkDB1mg3
EOF
```

---

## Task B2: `SessionSummarizer` (best-effort, map-reduce, char-capped)

**Files:**
- Create: `Sources/PensieveKit/Intelligence/SessionSummarizer.swift`
- Test: `Tests/PensieveKitTests/SessionSummarizerTests.swift`

**Interfaces:**
- Consumes: `LLMProvider.complete`, `TranscriptMessage`.
- Produces: `SessionSummarizer(provider:).summarize(_ messages: [TranscriptMessage]) async -> String?` — nil on no relevant messages or any provider failure/empty; output ≤ `SessionSummarizer.outputCap` chars.

- [ ] **Step 1: Write the failing tests**

Create `Tests/PensieveKitTests/SessionSummarizerTests.swift`:

```swift
import Foundation
import Testing
@testable import PensieveKit

private struct EchoLen: LLMProvider {
  func complete(prompt: String) async throws -> String { "SUMMARY(promptLen=\(prompt.count))" }
}
private struct ThrowingProvider: LLMProvider {
  func complete(prompt: String) async throws -> String { throw LLMError.providerFailed("boom") }
}
private struct FixedReply: LLMProvider {
  let reply: String
  func complete(prompt: String) async throws -> String { reply }
}

private func m(_ i: Int, _ role: String, _ text: String, user: Bool) -> TranscriptMessage {
  TranscriptMessage(index: i, role: role, text: text, timestamp: nil, isUserPrompt: user)
}

@Test func summarizerReturnsNilWhenNoRelevantMessages() async {
  // Only tool-result-ish / non-user, non-assistant content -> nothing to summarize.
  let msgs = [m(0, "tool", "some tool output", user: false)]
  let out = await SessionSummarizer(provider: EchoLen()).summarize(msgs)
  #expect(out == nil)
}

@Test func summarizerReturnsNilOnProviderFailure() async {
  let msgs = [m(0, "user", "let's build the parser", user: true)]
  let out = await SessionSummarizer(provider: ThrowingProvider()).summarize(msgs)
  #expect(out == nil)
}

@Test func summarizerCapsOutput() async {
  let long = String(repeating: "x", count: 5000)
  let msgs = [m(0, "assistant", "done", user: false)]
  let out = await SessionSummarizer(provider: FixedReply(reply: long)).summarize(msgs)
  #expect(out != nil)
  #expect(out!.count <= SessionSummarizer.outputCap)
}

@Test func summarizerIncludesUserAndAssistantOnly() {
  let msgs = [m(0, "user", "add auth", user: true),
              m(1, "assistant", "added auth", user: false),
              m(2, "user", "tool blob", user: false)]   // isUserPrompt false -> excluded
  let blob = SessionSummarizer.relevantBlob(msgs)
  #expect(blob.contains("add auth"))
  #expect(blob.contains("added auth"))
  #expect(!blob.contains("tool blob"))
}

@Test func summarizerMapReducesOverBudget() async {
  // Force > 1 chunk: input far exceeds inputBudget -> map (per-chunk) then a reduce call.
  actor Counter { var n = 0; func bump() { n += 1 }; func value() -> Int { n } }
  struct Counting: LLMProvider {
    let counter: Counter
    func complete(prompt: String) async throws -> String { await counter.bump(); return "part" }
  }
  let counter = Counter()
  let big = String(repeating: "word ", count: SessionSummarizer.inputBudget)  // ~5x budget
  let msgs = [m(0, "assistant", big, user: false)]
  let out = await SessionSummarizer(provider: Counting(counter: counter)).summarize(msgs)
  #expect(out != nil)
  #expect(await counter.value() >= 2)   // at least one map + one reduce
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `./scripts/test.sh --filter SessionSummarizer`
Expected: FAIL — `SessionSummarizer` undefined.

- [ ] **Step 3: Implement `SessionSummarizer`**

Create `Sources/PensieveKit/Intelligence/SessionSummarizer.swift`:

```swift
import Foundation

/// Produces a short, grounded "what was worked on this session" summary from a parsed
/// transcript. Best-effort prose that feeds narration (Part B) — it reads assistant turns
/// the loose-end trust gate deliberately never touches, so it is an explicit, bounded
/// groundedness exemption (like narration / strand naming), NOT part of the cited gate.
///
/// Bounded like the extractor: sessions are multi-MB, so a single `complete` over a whole
/// session overflows the ~3B window. The summarizer chunks the input, summarizes each chunk
/// (map), then summarizes the joined partials (reduce), and hard-caps the stored output.
/// Every failure path returns nil so a bad/absent summary never gates loose-end insertion.
public struct SessionSummarizer: Sendable {
  private let provider: any LLMProvider

  /// Max chars fed to the model in one `complete` call (keeps a single call within the window).
  public static let inputBudget = 6000
  /// Hard cap on the stored `workSummary` (a couple of sentences).
  public static let outputCap = 600

  public init(provider: any LLMProvider) { self.provider = provider }

  /// nil when there is nothing to summarize or the provider fails/returns empty.
  public func summarize(_ messages: [TranscriptMessage]) async -> String? {
    let blob = Self.relevantBlob(messages)
    guard !blob.isEmpty else { return nil }
    return await summarizeText(blob)
  }

  /// The developer's own prompts + the assistant's replies, in order — the material a
  /// "what was worked on" summary needs. Excludes tool results / meta / injected content
  /// (those are neither `isUserPrompt` nor `role == "assistant"`).
  static func relevantBlob(_ messages: [TranscriptMessage]) -> String {
    messages
      .filter { $0.isUserPrompt || $0.role == "assistant" }
      .map { "\($0.role): \($0.text)" }
      .joined(separator: "\n\n")
  }

  private func summarizeText(_ text: String) async -> String? {
    let chunks = Self.chunk(text, budget: Self.inputBudget)
    if chunks.count <= 1 {
      return await completeCapped(chunks.first ?? text)
    }
    var partials: [String] = []
    for c in chunks {
      if let s = await completeCapped(c) { partials.append(s) }
    }
    guard !partials.isEmpty else { return nil }
    let joined = partials.joined(separator: "\n")
    // One reduce level. If the partials themselves overflow, feed a truncated head; the
    // fallback (capped joined partials) still yields grounded-if-terse prose.
    return await completeCapped(String(joined.prefix(Self.inputBudget))) ?? String(joined.prefix(Self.outputCap))
  }

  private func completeCapped(_ body: String) async -> String? {
    guard let raw = try? await provider.complete(prompt: Self.prompt(body)) else { return nil }
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : String(trimmed.prefix(Self.outputCap))
  }

  static func prompt(_ body: String) -> String {
    """
    Summarize, in 1-2 sentences, ONLY the work actually done in the coding session below — \
    what was built, changed, investigated, or decided. Do not speculate, infer, or add \
    anything not present in the text. If the text is thin, be brief.

    \(body)
    """
  }

  /// Splits text into ≤-budget windows on whitespace boundaries (never mid-word unless a
  /// single token exceeds the budget).
  static func chunk(_ text: String, budget: Int) -> [String] {
    guard budget > 0, text.count > budget else { return text.isEmpty ? [] : [text] }
    var out: [String] = []
    var start = text.startIndex
    while start < text.endIndex {
      var end = text.index(start, offsetBy: budget, limitedBy: text.endIndex) ?? text.endIndex
      if end < text.endIndex, let ws = text[start..<end].lastIndex(where: { $0.isWhitespace }) {
        end = text.index(after: ws)
      }
      out.append(String(text[start..<end]))
      start = end
    }
    return out
  }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `./scripts/test.sh --filter SessionSummarizer`
Expected: PASS (all 5).

- [ ] **Step 5: Commit**

```bash
git add Sources/PensieveKit/Intelligence/SessionSummarizer.swift Tests/PensieveKitTests/SessionSummarizerTests.swift
git commit -F - <<'EOF'
feat(kit): add SessionSummarizer (best-effort, map-reduce, capped)

Grounded on-device recap of a session's user+assistant turns; chunks +
map-reduces to stay within the on-device window; hard output cap; nil on
any failure so it never gates extraction.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01Ya7ToQ9MrGVDLzHkDB1mg3
EOF
```

---

## Task B3: `assembleFacts` composes over `workSummary` (bounded)

**Files:**
- Modify: `Sources/PensieveKit/Intelligence/SummaryBuilder.swift:15-18`
- Test: `Tests/PensieveKitTests/SummaryBuilderTests.swift`

**Interfaces:**
- Consumes: `Event.workSummary`.
- Produces: `SummaryBuilder.assembleFacts(project:events:)` unchanged signature; new `SummaryBuilder.factSheetBudget`.

- [ ] **Step 1: Write the failing tests**

Append to `Tests/PensieveKitTests/SummaryBuilderTests.swift`:

```swift
@Test func assembleFactsPrefersWorkSummaryOverTerseSummary() {
  let node = Node(name: "Pensieve")
  let e = Event(nodeID: node.id, sourceID: UUID(), occurredAt: Date(),
                kind: CaptureKind.ccSession, summary: "session (9 prompts)", detailJSON: "{}",
                workSummary: "Wired the sync daemon and fixed the watermark.")
  let facts = SummaryBuilder.assembleFacts(project: node, events: [e])
  #expect(facts.contains("Wired the sync daemon and fixed the watermark."))
  #expect(!facts.contains("session (9 prompts)"))
}

@Test func assembleFactsFallsBackToTerseSummaryWhenNoWorkSummary() {
  let node = Node(name: "Pensieve")
  let e = Event(nodeID: node.id, sourceID: UUID(), occurredAt: Date(),
                kind: CaptureKind.gitCommit, summary: "fix: watermark off-by-one", detailJSON: "{}")
  let facts = SummaryBuilder.assembleFacts(project: node, events: [e])
  #expect(facts.contains("fix: watermark off-by-one"))
}

@Test func assembleFactsRespectsCharBudget() {
  let node = Node(name: "Pensieve")
  let events = (0..<15).map { i in
    Event(nodeID: node.id, sourceID: UUID(), occurredAt: Date(),
          kind: CaptureKind.ccSession, summary: "s", detailJSON: "{}",
          workSummary: String(repeating: "x", count: 400))
  }
  let facts = SummaryBuilder.assembleFacts(project: node, events: events)
  #expect(facts.count <= SummaryBuilder.factSheetBudget + 200)   // header + a few lines, never all 15
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `./scripts/test.sh --filter assembleFacts`
Expected: FAIL — `factSheetBudget` undefined / workSummary not used.

- [ ] **Step 3: Rewrite `assembleFacts`**

Replace `SummaryBuilder.assembleFacts` (lines 15-18) with:

```swift
  /// Total char budget for the narrator's fact sheet. `narrate`/`build` feed this to a single
  /// un-chunked `complete`; replacing terse lines with real `workSummary` prose can balloon it
  /// and overflow the window (→ narration vanishes). Bound it: include recent events until the
  /// budget is hit.
  public static let factSheetBudget = 1800

  /// Deterministic fact sheet the model is allowed to narrate — and nothing beyond it. Prefers
  /// each event's grounded `workSummary` (Part B); falls back to the terse `summary` when absent.
  public static func assembleFacts(project: Node, events: [Event]) -> String {
    var lines: [String] = []
    var used = 0
    for e in events.prefix(15) {
      let content = (e.workSummary.map { !$0.isEmpty } ?? false) ? e.workSummary! : e.summary
      let line = "- \(e.kind): \(content)"
      if used + line.count > factSheetBudget, !lines.isEmpty { break }
      lines.append(line)
      used += line.count
    }
    return "Project: \(project.name)\nRecent activity:\n\(lines.joined(separator: "\n"))"
  }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `./scripts/test.sh --filter assembleFacts`
Expected: PASS.

- [ ] **Step 5: Run the SummaryBuilder suite (no regressions)**

Run: `./scripts/test.sh --filter SummaryBuilder`
Expected: PASS — existing tests use events without `workSummary`, so `assembleFacts` still emits the terse line (unchanged output under budget).

- [ ] **Step 6: Commit**

```bash
git add Sources/PensieveKit/Intelligence/SummaryBuilder.swift Tests/PensieveKitTests/SummaryBuilderTests.swift
git commit -F - <<'EOF'
feat(kit): narrate over workSummary under a bounded fact sheet

assembleFacts prefers each event's grounded workSummary and falls back to
the terse summary; caps the sheet so the narrator's single complete call
never overflows on busy nodes.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01Ya7ToQ9MrGVDLzHkDB1mg3
EOF
```

---

## Task B4: Wire `SessionSummarizer` into `ExtractionRunner` (best-effort, pre-write)

**Files:**
- Modify: `Sources/PensieveKit/Intelligence/ExtractionRunner.swift:78-112`
- Test: `Tests/PensieveKitTests/ExtractionRunnerTests.swift`

**Interfaces:**
- Consumes: `SessionSummarizer`, `Event.workSummary`.
- Produces: `ExtractionRunner.run()` stores `workSummary` on the session event when the summarizer succeeds; a summarizer failure leaves the prior value and never blocks inserts/watermark.

- [ ] **Step 1: Write the failing tests**

Add to `Tests/PensieveKitTests/ExtractionRunnerTests.swift`. First a provider that summarizes but proposes no loose ends, and one whose summarizer throws while extraction succeeds. Model the test transcript on the existing tests in that file (reuse their fixture-writing helper). Add:

```swift
@Test func extractionStoresWorkSummary() async throws {
  // Uses the file's existing helper to write a transcript + seed a cc.session event.
  // (Follow the pattern already in ExtractionRunnerTests for building `db`, the transcript
  // file, and the event; only the assertions below are new.)
  let ctx = try makeExtractionContext(prompts: ["let's also migrate the auth tables later"])
  struct SummarizingProvider: LLMProvider {
    func complete(prompt: String) async throws -> String { "Migrated the auth tables." }
    func extractCandidates(prompt: String) async throws -> [LooseEndCandidate] { [] }
    func classifyGenuineIndices(prompt: String) async throws -> [Int] { [0] }
  }
  _ = try await ExtractionRunner(db: ctx.db, provider: SummarizingProvider()).run()
  let ev = try ctx.db.read { db in try Event.where { $0.id.eq(ctx.eventID) }.fetchOne(db) }
  #expect(ev?.workSummary == "Migrated the auth tables.")
}

@Test func summarizerFailureDoesNotBlockWatermark() async throws {
  let ctx = try makeExtractionContext(prompts: ["please read the spec"])
  struct FailSummaryProvider: LLMProvider {
    func complete(prompt: String) async throws -> String { throw LLMError.providerFailed("no summary") }
    func extractCandidates(prompt: String) async throws -> [LooseEndCandidate] { [] }
    func classifyGenuineIndices(prompt: String) async throws -> [Int] { [0] }
  }
  _ = try await ExtractionRunner(db: ctx.db, provider: FailSummaryProvider()).run()
  let ev = try ctx.db.read { db in try Event.where { $0.id.eq(ctx.eventID) }.fetchOne(db) }
  #expect(ev?.workSummary == nil)                 // best-effort: left unset
  #expect(ev?.extractedTranscriptSize != -1)      // watermark still advanced
}
```

> **Implementer note:** if `ExtractionRunnerTests.swift` has no shared `makeExtractionContext` helper, extract one from the existing tests (they already build a temp DB, write a `.jsonl` transcript, and insert a `cc.session` event pointing at it) and reuse it here. Do not duplicate that setup inline.

- [ ] **Step 2: Run tests to verify they fail**

Run: `./scripts/test.sh --filter "extractionStoresWorkSummary"`
Expected: FAIL — `workSummary` never written.

- [ ] **Step 3: Compute + persist `workSummary` (pre-write, `try?`)**

In `ExtractionRunner.run()`, after `let verified = candidates.compactMap { … }` (line 81) and **before** `let stamp = now()` (line 83), add:

```swift
        // Best-effort session recap for narration (Part B). `summarize` is non-throwing (nil on
        // failure), computed BEFORE the synchronous db.write and NEVER inside this session's
        // do/catch — a nil/absent summary must not skip the loose-end insert or the watermark
        // advance. Summarize the WHOLE session (stable per-session summary), not just the slice.
        let work = await SessionSummarizer(provider: provider).summarize(session.messages)
```

Then in the `db.write` closure, extend the watermark-advancing `update` (lines 106-110) to also set `workSummary`, preserving the prior value on failure:

```swift
          try Event.where { $0.id.eq(event.id) }.update {
            $0.extractedAt = #bind(stamp)
            $0.extractedMessageCount = messageCount
            $0.extractedTranscriptSize = size
            $0.workSummary = work ?? event.workSummary
          }.execute(db)
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `./scripts/test.sh --filter "extractionStoresWorkSummary summarizerFailureDoesNotBlockWatermark"`
Expected: PASS.

- [ ] **Step 5: Run the ExtractionRunner suite (no regressions)**

Run: `./scripts/test.sh --filter ExtractionRunner`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Sources/PensieveKit/Intelligence/ExtractionRunner.swift Tests/PensieveKitTests/ExtractionRunnerTests.swift
git commit -F - <<'EOF'
feat(kit): persist per-session workSummary during extraction

Best-effort SessionSummarizer over the whole session, computed try?
before the synchronous write; preserves the prior value on failure and
never blocks loose-end insertion or the watermark.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01Ya7ToQ9MrGVDLzHkDB1mg3
EOF
```

---

## Task B5: "Generated" affordance on the app's Last Work Done section

**Files:**
- Modify: `Sources/PensieveApp/DetailView.swift:42-50`
- Modify: `Sources/PensieveApp/Localizable.xcstrings`

**Interfaces:** app-target only; no unit tests. Verify by build + smoke.

- [ ] **Step 1: Add the affordance under the narration prose**

In `DetailView.swift`, replace the "LAST WORK DONE" block (lines 42-50) with a caption marking the prose as generated:

```swift
        // LAST WORK DONE (LLM narration; prose-first — a ready recap always wins over an in-flight
        // flag — and the section is omitted entirely when there's no genuine narration).
        if let lastWorkDone, loadedNodeID == node.id {
          section("Last Work Done") {
            VStack(alignment: .leading, spacing: 4) {
              Text(lastWorkDone).prose()
              Label("Generated summary", systemImage: "sparkles")
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
          }
        } else if isNarrating, loadedNodeID == node.id {
          section("Last Work Done") {
            ProgressView().controlSize(.small)
          }
        }
```

- [ ] **Step 2: Add the localized string**

In `Sources/PensieveApp/Localizable.xcstrings`, add a key `"Generated summary"` with English base `"Generated summary"` and German `"Automatisch erstellt"` (impersonal). Hand-author the entry to match the catalog's existing shape (a `localizations.en.stringUnit` + `localizations.de.stringUnit`, both `state: "translated"`). Do NOT rely on xcodebuild to populate it.

- [ ] **Step 3: Build the app**

Run:
```bash
xcodegen generate && xcodebuild -project Pensieve.xcodeproj -scheme Pensieve -configuration Debug -derivedDataPath ./.build-xcode build
```
Expected: BUILD SUCCEEDED. Discard any transient `Package.resolved` churn.

- [ ] **Step 4: Smoke-launch (non-blocking, throwaway store)**

Run:
```bash
PENSIEVE_DB=/tmp/pv-smoke.sqlite PENSIEVE_CAPTURE_DB=/tmp/pv-smoke-cap.sqlite \
  ./.build-xcode/Build/Products/Debug/Pensieve.app/Contents/MacOS/Pensieve &
PID=$!; sleep 4; kill $PID
```
Expected: launches and exits with no crash. (Human eyeball on a real store: the "Generated summary" caption shows under a narration.)

- [ ] **Step 5: Verify German**

Run `plutil -p ./.build-xcode/Build/Products/Debug/Pensieve.app/Contents/Resources/de.lproj/Localizable.strings | grep -i generated` and confirm `"Automatisch erstellt"` is present.

- [ ] **Step 6: Commit**

```bash
git add Sources/PensieveApp/DetailView.swift Sources/PensieveApp/Localizable.xcstrings
git commit -F - <<'EOF'
feat(app): mark Last Work Done as a generated summary

Subtle "Generated summary" caption under the narration prose (EN + DE),
honestly marking the widened ungrounded surface (workSummary is generated,
not verbatim).

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01Ya7ToQ9MrGVDLzHkDB1mg3
EOF
```

---

# PART C — Narration persistence

## Task C1: `NarrationCacheKey` (order-independent invalidation key)

**Files:**
- Create: `Sources/PensieveKit/Intelligence/NarrationCacheKey.swift`
- Test: `Tests/PensieveKitTests/NarrationCacheKeyTests.swift`

**Interfaces:**
- Consumes: `Event.id`, `Event.extractedAt`.
- Produces: `NarrationCacheKey.make(events: [Event]) -> String`.

- [ ] **Step 1: Write the failing tests**

Create `Tests/PensieveKitTests/NarrationCacheKeyTests.swift`:

```swift
import Foundation
import Testing
@testable import PensieveKit

private func ev(_ id: UUID, extracted: Date? = nil) -> Event {
  Event(nodeID: UUID(), sourceID: UUID(), occurredAt: Date(),
        kind: CaptureKind.ccSession, summary: "s", detailJSON: "{}", extractedAt: extracted)
}

@Test func keyIsOrderIndependent() {
  let a = ev(UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)
  let b = ev(UUID(uuidString: "00000000-0000-0000-0000-000000000002")!)
  #expect(NarrationCacheKey.make(events: [a, b]) == NarrationCacheKey.make(events: [b, a]))
}

@Test func keyChangesWhenEventAddedOrRemoved() {
  let a = ev(UUID())
  let b = ev(UUID())
  #expect(NarrationCacheKey.make(events: [a]) != NarrationCacheKey.make(events: [a, b]))
}

@Test func keyChangesWhenExtractedAtMoves() {
  let id = UUID()
  let before = NarrationCacheKey.make(events: [ev(id, extracted: Date(timeIntervalSince1970: 100))])
  let after  = NarrationCacheKey.make(events: [ev(id, extracted: Date(timeIntervalSince1970: 200))])
  #expect(before != after)   // a re-enriched workSummary moves extractedAt -> new key
}

@Test func keyStableWithAllNilExtractedAt() {
  let id = UUID()
  let k1 = NarrationCacheKey.make(events: [ev(id)])
  let k2 = NarrationCacheKey.make(events: [ev(id)])
  #expect(k1 == k2)   // git-only node (no extractedAt) is handled, not crashing/empty
  #expect(!k1.isEmpty)
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `./scripts/test.sh --filter NarrationCacheKey`
Expected: FAIL — undefined.

- [ ] **Step 3: Implement**

Create `Sources/PensieveKit/Intelligence/NarrationCacheKey.swift`:

```swift
import Foundation

/// Order-independent invalidation key for a node's persisted narration. Derived from exactly
/// the events `SummaryBuilder.assembleFacts` narrates (the caller passes the same top-N set):
/// the sorted event IDs (membership + count) plus the latest `extractedAt` over that set (which
/// moves whenever a session's `workSummary` is re-enriched). NOT keyed on "the latest event id":
/// `ProjectQueries.status` orders by `occurredAt` with no tiebreaker, so tied timestamps make the
/// top row nondeterministic and such a key would flip run-to-run.
public enum NarrationCacheKey {
  public static func make(events: [Event]) -> String {
    let ids = events.map { $0.id.uuidString }.sorted()
    let latestExtracted = events.compactMap { $0.extractedAt }.max()
    let stamp = latestExtracted.map { String($0.timeIntervalSince1970) } ?? "none"
    return "\(ids.joined(separator: ","))|\(stamp)"
  }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `./scripts/test.sh --filter NarrationCacheKey`
Expected: PASS (all 4).

- [ ] **Step 5: Commit**

```bash
git add Sources/PensieveKit/Intelligence/NarrationCacheKey.swift Tests/PensieveKitTests/NarrationCacheKeyTests.swift
git commit -F - <<'EOF'
feat(kit): add order-independent NarrationCacheKey

Invalidation key over the narrated event set (sorted ids + latest
extractedAt); order-independent so tied occurredAt timestamps don't flip
it; handles all-nil extractedAt.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01Ya7ToQ9MrGVDLzHkDB1mg3
EOF
```

---

## Task C2: Persisted, key-invalidated narration cache in `AppModel`

**Files:**
- Modify: `Sources/PensieveApp/AppModel.swift` (cache type + persistence + `cachedNarration`/`narration` + `drainThenRefresh`)
- Modify: `Sources/PensieveApp/DetailView.swift:88-105` (pass events + force on ⌘R)

**Interfaces:** app-target only; no unit tests. Verify by build + smoke. Relies on `NarrationCacheKey.make(events:)` (Task C1).

- [ ] **Step 1: Replace the in-memory cache with a persisted, keyed one**

In `AppModel.swift`, replace `private var narrationCache: [UUID: String] = [:]` (line 137) with a keyed struct persisted per DB path:

```swift
  /// Persisted narration: prose + the invalidation key it was generated for. Keyed per DB path
  /// (NEW pattern — lastOpenedAt is a single global key today) so throwaway smoke/test stores
  /// don't pollute the real cache. Device-local: narration is a derived, provider-specific
  /// output cache and must not sync.
  private struct CachedNarration: Codable { let prose: String; let key: String }
  private var narrationCache: [UUID: CachedNarration] = [:]

  private static func narrationCacheDefaultsKey() -> String {
    "pensieve.narrationCache." + Stores.canonicalURL.path
  }
  private func loadNarrationCache() {
    guard let data = UserDefaults.standard.data(forKey: Self.narrationCacheDefaultsKey()),
          let decoded = try? JSONDecoder().decode([UUID: CachedNarration].self, from: data)
    else { return }
    narrationCache = decoded
  }
  private func saveNarrationCache() {
    guard let data = try? JSONEncoder().encode(narrationCache) else { return }
    UserDefaults.standard.set(data, forKey: Self.narrationCacheDefaultsKey())
  }
```

- [ ] **Step 2: Load the cache on start**

In `start()` (after `db = try? openCanonicalDatabase(...)`, around line 155), add:

```swift
    loadNarrationCache()
```

- [ ] **Step 3: Make `cachedNarration`/`narration` key-aware and drop the blanket clear**

Replace `cachedNarration` and `narration` (lines 449-460) with:

```swift
  /// Cached narration for `node` IFF the stored key still matches the current events. Synchronous —
  /// lets the view render a valid cached recap instantly (including across launches).
  func cachedNarration(for node: Node, events: [Event]) -> String? {
    guard let entry = narrationCache[node.id],
          entry.key == NarrationCacheKey.make(events: events) else { return nil }
    return entry.prose
  }

  /// The "Last Work Done" narration for `node`. Returns the cached result when its key matches and
  /// `force` is false; otherwise regenerates off-main, stores prose+key, and returns it. `force`
  /// (⌘R on the selected node) bypasses the cache so the user can always refresh a bad recap.
  func narration(for node: Node, events: [Event], force: Bool = false) async -> String? {
    let key = NarrationCacheKey.make(events: events)
    if !force, let entry = narrationCache[node.id], entry.key == key { return entry.prose }
    let text = await summaryBuilder.narrate(project: node, events: events)
    if let text {
      narrationCache[node.id] = CachedNarration(prose: text, key: key)
      saveNarrationCache()
    }
    return text
  }
```

In `drainThenRefresh()` (line 196), **delete** the line `narrationCache.removeAll()`. Launch/liveness no longer blanket-clears; stale entries are dropped naturally by the key check, and ⌘R forces the selected node via the view (Step 4). Update the surrounding comment to:

```swift
    // launch/⌘R: do NOT blanket-clear — cachedNarration/narration are key-aware, so unchanged
    // nodes reuse persisted prose and only changed nodes regenerate. ⌘R force-refresh of the
    // selected node happens in DetailView (force: on same-node token bump).
```

- [ ] **Step 4: Update `DetailView` to pass events and force on ⌘R**

Replace the `.task` body (DetailView.swift lines 88-105) with:

```swift
    .task(id: DetailLoadKey(nodeID: node.id, token: model.refreshToken)) {
      // Same node + token bumped == a ⌘R refresh; a different node == navigation.
      let isRefresh = (loadedNodeID == node.id)
      if !isRefresh { lastWorkDone = nil }
      loadedNodeID = node.id
      isNarrating = false
      let d = model.detail(for: node)
      recentEvents = d.status.recentEvents
      looseEnds = d.looseEnds
      shareMarkdown = RecallMarkdown.render(node: node,
                                            narration: model.cachedNarration(for: node, events: recentEvents),
                                            looseEnds: looseEnds, events: recentEvents, now: Date())
      if !isRefresh, let cached = model.cachedNarration(for: node, events: recentEvents) {
        lastWorkDone = cached; return
      }
      isNarrating = true
      let prose = await model.narration(for: node, events: recentEvents, force: isRefresh)
      guard !Task.isCancelled else { return }   // superseded: new task owns state; don't touch isNarrating
      lastWorkDone = prose
      shareMarkdown = RecallMarkdown.render(node: node, narration: prose,
                                            looseEnds: looseEnds, events: recentEvents, now: Date())
      isNarrating = false
    }
```

> Note: any other caller of `model.cachedNarration(for:)` (e.g. `RecallWindowView`, share menus) must pass the node's `recentEvents`; grep for `cachedNarration(` and update call sites to the new signature.

- [ ] **Step 5: Build the app**

Run:
```bash
xcodegen generate && xcodebuild -project Pensieve.xcodeproj -scheme Pensieve -configuration Debug -derivedDataPath ./.build-xcode build
```
Expected: BUILD SUCCEEDED (all `cachedNarration(` call sites updated).

- [ ] **Step 6: Smoke-launch (non-blocking)**

Run:
```bash
PENSIEVE_DB=/tmp/pv-smoke.sqlite PENSIEVE_CAPTURE_DB=/tmp/pv-smoke-cap.sqlite \
  ./.build-xcode/Build/Products/Debug/Pensieve.app/Contents/MacOS/Pensieve &
PID=$!; sleep 4; kill $PID
```
Expected: launches and exits cleanly. (Human eyeball on a real store: reopening the app shows a prior recap instantly with no spinner; ⌘R on a node re-narrates; a node with new activity regenerates.)

- [ ] **Step 7: Commit**

```bash
git add Sources/PensieveApp/AppModel.swift Sources/PensieveApp/DetailView.swift
git commit -F - <<'EOF'
feat(app): persist narration; regenerate only on change

Per-DB-path UserDefaults cache of prose + NarrationCacheKey; unchanged
nodes reuse prose across launches with no LLM call; CmdR force-regenerates
the selected node; drop the blanket removeAll().

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01Ya7ToQ9MrGVDLzHkDB1mg3
EOF
```

---

# PART A — Loose-end salience

## Task A1: `classifyNonSalientIndices` provider method (+ FoundationModels schema)

> **Refinement of the spec (documented):** the spec named `classifySalientIndices` returning the *keep* set. The method here returns the **drop** set (indices that are clearly in-the-moment requests) instead, because it makes every fail mode safe: a hard error → fail open → keep all; a structured empty `[]` → nothing to drop → keep all. A keep-set formulation would make a structured `[]` mean "drop everything," the opposite of the required keep-on-low-confidence bias.

**Files:**
- Modify: `Sources/PensieveKit/LLM/LLMProvider.swift`
- Modify: `Sources/PensieveKit/LLM/FoundationModelsProvider.swift`
- Test: `Tests/PensieveKitTests/SalienceClassifierTests.swift` (default-extension behavior tested via the classifier in Task A2; a direct default-extension test here)

**Interfaces:**
- Produces: `LLMProvider.classifyNonSalientIndices(prompt:) async throws -> [Int]` (default: `complete` + `IntentClassifier.decodeIndices`, throws on unparseable so callers fail open).

- [ ] **Step 1: Write the failing test**

Create `Tests/PensieveKitTests/SalienceClassifierTests.swift` with the default-extension test first:

```swift
import Foundation
import Testing
@testable import PensieveKit

private struct RawReply: LLMProvider {
  let reply: String
  func complete(prompt: String) async throws -> String { reply }
}

@Test func nonSalientDefaultExtensionParsesIntArray() async throws {
  let idx = try await RawReply(reply: "drop: [1, 2]").classifyNonSalientIndices(prompt: "x")
  #expect(Set(idx) == Set([1, 2]))
}

@Test func nonSalientDefaultExtensionThrowsOnUnparseable() async {
  await #expect(throws: LLMError.self) {
    _ = try await RawReply(reply: "no array here").classifyNonSalientIndices(prompt: "x")
  }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `./scripts/test.sh --filter nonSalientDefaultExtension`
Expected: FAIL — method undefined.

- [ ] **Step 3: Add the protocol method + default extension**

In `Sources/PensieveKit/LLM/LLMProvider.swift`, add to the protocol (after `classifyGenuineIndices`, line 22):

```swift

  /// The `[n]` indices judged NOT loose ends (in-the-moment requests) for the given salience
  /// prompt — the DROP set. The default decodes JSON from `complete` and **throws** when the
  /// response is not a parseable index array (so the caller fails open → keeps all); the
  /// on-device provider overrides it with guided generation returning a real (possibly empty)
  /// array. An empty array means "drop nothing" (keep all) — the safe, keep-on-low-confidence default.
  func classifyNonSalientIndices(prompt: String) async throws -> [Int]
```

And to the extension (after `classifyGenuineIndices`, line 35):

```swift

  func classifyNonSalientIndices(prompt: String) async throws -> [Int] {
    guard let indices = IntentClassifier.decodeIndices(try await complete(prompt: prompt)) else {
      throw LLMError.providerFailed("salience response was not a parseable index array")
    }
    return Array(indices)
  }
```

- [ ] **Step 4: Add the FoundationModels override + schema**

In `Sources/PensieveKit/LLM/FoundationModelsProvider.swift`, add a method after `classifyGenuineIndices` (line 58):

```swift

  public func classifyNonSalientIndices(prompt: String) async throws -> [Int] {
    let session = LanguageModelSession()
    do {
      let content = try await session.respond(to: prompt, schema: Self.nonSalientIndicesSchema()).content
      guard case .structure(let root, _) = content.kind,
            case .array(let items)? = root["indices"]?.kind else { return [] }
      return items.compactMap { if case .number(let n) = $0.kind { return Int(n) } else { return nil } }
    } catch {
      throw LLMError.providerFailed("FoundationModels: \(error)")
    }
  }
```

And a schema after `genuineIndicesSchema()` (line 90):

```swift

  /// `{ indices: [Int] }` — the DROP set for salience.
  private static func nonSalientIndicesSchema() throws -> GenerationSchema {
    let root = DynamicGenerationSchema(name: "NonSalientIndices", properties: [
      .init(name: "indices",
            description: "The [n] indices of items that are clearly in-the-moment requests the assistant simply carried out — NOT deferred/parked/decision work left open. These will be dropped. Empty when every item is a genuine loose end; when unsure about an item, do NOT include it.",
            schema: DynamicGenerationSchema(arrayOf: DynamicGenerationSchema(type: Int.self))),
    ])
    return try GenerationSchema(root: root, dependencies: [])
  }
```

- [ ] **Step 5: Run to verify it passes**

Run: `./scripts/test.sh --filter nonSalientDefaultExtension`
Expected: PASS. (The FoundationModels override compiles under `swift build`; its runtime behavior is covered by the on-device acceptance run, not CI.)

- [ ] **Step 6: Commit**

```bash
git add Sources/PensieveKit/LLM/LLMProvider.swift Sources/PensieveKit/LLM/FoundationModelsProvider.swift Tests/PensieveKitTests/SalienceClassifierTests.swift
git commit -F - <<'EOF'
feat(kit): add classifyNonSalientIndices provider method

Returns the DROP set (clear in-the-moment requests); default fails open
on unparseable, FoundationModels overrides with a guided-generation
schema. Empty result keeps all (keep-on-low-confidence).

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01Ya7ToQ9MrGVDLzHkDB1mg3
EOF
```

---

## Task A2: `SalienceClassifier` (drop stage)

**Files:**
- Create: `Sources/PensieveKit/Intelligence/SalienceClassifier.swift`
- Test: `Tests/PensieveKitTests/SalienceClassifierTests.swift` (extend)

**Interfaces:**
- Consumes: `LLMProvider.classifyNonSalientIndices`, `VerifiedLooseEnd`, `TranscriptMessage`.
- Produces: `SalienceClassifier(provider:).filter(_ ends: [VerifiedLooseEnd], messages: [TranscriptMessage]) async -> [VerifiedLooseEnd]`.

- [ ] **Step 1: Write the failing tests**

Extend `Tests/PensieveKitTests/SalienceClassifierTests.swift`:

```swift
private struct DropIndices: LLMProvider {
  let drop: [Int]
  func complete(prompt: String) async throws -> String { "[]" }
  func classifyNonSalientIndices(prompt: String) async throws -> [Int] { drop }
}
private struct ThrowSalience: LLMProvider {
  func complete(prompt: String) async throws -> String { "[]" }
  func classifyNonSalientIndices(prompt: String) async throws -> [Int] { throw LLMError.providerFailed("boom") }
}

private func vle(_ quote: String, at index: Int) -> VerifiedLooseEnd {
  VerifiedLooseEnd(text: quote, quote: quote, role: "user", sourceMessageIndex: index)
}
private func um(_ i: Int, _ text: String) -> TranscriptMessage {
  TranscriptMessage(index: i, role: "user", text: text, timestamp: nil, isUserPrompt: true)
}

@Test func salienceDropsReturnedIndices() async {
  let ends = [vle("we should migrate the auth tables later", at: 0),
              vle("please read the spec now", at: 1)]
  let msgs = [um(0, "we should migrate the auth tables later"), um(1, "please read the spec now")]
  let kept = await SalienceClassifier(provider: DropIndices(drop: [1])).filter(ends, messages: msgs)
  #expect(kept.map(\.quote) == ["we should migrate the auth tables later"])
}

@Test func salienceKeepsAllOnEmptyDropSet() async {
  let ends = [vle("we should migrate the auth tables later", at: 0)]
  let msgs = [um(0, "we should migrate the auth tables later")]
  let kept = await SalienceClassifier(provider: DropIndices(drop: [])).filter(ends, messages: msgs)
  #expect(kept.count == 1)
}

@Test func salienceFailsOpenKeepingAllOnProviderError() async {
  let ends = [vle("a real deferred item to revisit", at: 0), vle("another to park for later", at: 1)]
  let msgs = [um(0, "a real deferred item to revisit"), um(1, "another to park for later")]
  let kept = await SalienceClassifier(provider: ThrowSalience()).filter(ends, messages: msgs)
  #expect(kept.count == 2)   // hard error -> keep all
}

@Test func salienceEmptyInputYieldsEmpty() async {
  let kept = await SalienceClassifier(provider: DropIndices(drop: [0])).filter([], messages: [])
  #expect(kept.isEmpty)
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `./scripts/test.sh --filter salience`
Expected: FAIL — `SalienceClassifier` undefined.

- [ ] **Step 3: Implement**

Create `Sources/PensieveKit/Intelligence/SalienceClassifier.swift`:

```swift
import Foundation

/// The salience gate: drops verified loose ends that are in-the-moment requests the assistant
/// simply carried out ("read the spec", "can you fix this?") rather than deferred/parked/decision
/// work the developer left open. Runs AFTER the verbatim gate, so it only ever judges real,
/// already-verified quotes and can never fabricate — it only filters.
///
/// Conservative by construction: the model returns the DROP set (clear non-loose-ends); a hard
/// provider error fails open (keep all) and an empty drop set keeps all, so every uncertain path
/// favors keeping. The verbatim trust gate is untouched.
public struct SalienceClassifier {
  private let provider: any LLMProvider
  private let batchCharBudget: Int

  public init(provider: any LLMProvider, batchCharBudget: Int = 2000) {
    self.provider = provider
    self.batchCharBudget = batchCharBudget
  }

  /// Messages each side of the cited one included as disambiguating context.
  static let contextNeighbors = 1
  /// Per-message char cap in the context window (keeps a batch bounded).
  static let messageHeadLimit = 300

  public func filter(_ ends: [VerifiedLooseEnd], messages: [TranscriptMessage]) async -> [VerifiedLooseEnd] {
    guard !ends.isEmpty else { return [] }
    var kept: [VerifiedLooseEnd] = []
    for batch in Self.batches(ends, messages: messages, budget: batchCharBudget) {
      let drop: Set<Int>
      if let idx = try? await provider.classifyNonSalientIndices(prompt: Self.buildPrompt(batch, messages: messages)) {
        drop = Set(idx)                       // structured answer: trust the drop set (empty = keep all)
      } else {
        drop = []                             // hard error: fail open, keep all
      }
      for (n, e) in batch.enumerated() where !drop.contains(n) { kept.append(e) }
    }
    return kept
  }

  /// Groups ends into batches whose per-item prompt cost (quote + capped context) stays within budget.
  static func batches(_ ends: [VerifiedLooseEnd], messages: [TranscriptMessage], budget: Int) -> [[VerifiedLooseEnd]] {
    var out: [[VerifiedLooseEnd]] = [], current: [VerifiedLooseEnd] = [], size = 0
    for e in ends {
      let cost = e.quote.count + contextWindow(for: e, messages: messages).count + 16
      if size + cost > budget, !current.isEmpty { out.append(current); current = []; size = 0 }
      current.append(e); size += cost
    }
    if !current.isEmpty { out.append(current) }
    return out
  }

  /// The cited message ± `contextNeighbors`, each capped, joined — the framing signal.
  static func contextWindow(for end: VerifiedLooseEnd, messages: [TranscriptMessage]) -> String {
    guard let pos = messages.firstIndex(where: { $0.index == end.sourceMessageIndex }) else { return "" }
    let lo = max(0, pos - contextNeighbors)
    let hi = min(messages.count - 1, pos + contextNeighbors)
    return messages[lo...hi].map { m in
      let head = m.text.count > messageHeadLimit ? String(m.text.prefix(messageHeadLimit)) + " …" : m.text
      return "\(m.role): \(head)"
    }.joined(separator: "\n")
  }

  static func buildPrompt(_ batch: [VerifiedLooseEnd], messages: [TranscriptMessage]) -> String {
    let body = batch.enumerated().map { (n, e) in
      "[\(n)] QUOTE: \(e.quote)\nCONTEXT:\n\(contextWindow(for: e, messages: messages))"
    }.joined(separator: "\n\n")
    return """
    Each item below is a candidate LOOSE END quoted from a developer's message, with surrounding \
    context. A LOOSE END is deferred, parked, or decision work the developer left open for later — \
    e.g. "we should also migrate the auth tables", "let's do X later", "TODO: wire up the webhook", \
    "let's go with A instead of B". It is NOT an in-the-moment request the assistant simply carried \
    out now — e.g. "read the spec", "can you fix this?", "run the tests", "subagent-driven, let's go".

    Return ONLY a JSON array of the [n] numbers that are clearly in-the-moment requests / NOT loose \
    ends (these will be dropped). When you are unsure about an item, do NOT include it (keep it). If \
    every item is a genuine loose end, return [].

    Items:
    \(body)
    """
  }
}
```

- [ ] **Step 4: Run to verify they pass**

Run: `./scripts/test.sh --filter salience`
Expected: PASS (all 4 + the two default-extension tests from A1).

- [ ] **Step 5: Commit**

```bash
git add Sources/PensieveKit/Intelligence/SalienceClassifier.swift Tests/PensieveKitTests/SalienceClassifierTests.swift
git commit -F - <<'EOF'
feat(kit): add SalienceClassifier drop stage

Post-verify on-device gate that drops in-the-moment requests, keeping
deferred/parked/decision loose ends. Judges the verbatim quote + a small
context window; batches; fail-open + empty-drop both keep all.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01Ya7ToQ9MrGVDLzHkDB1mg3
EOF
```

---

## Task A3: Sharpen `LooseEndExtractor.buildPrompt`

**Files:**
- Modify: `Sources/PensieveKit/Intelligence/LooseEndExtractor.swift:124-140`
- Test: `Tests/PensieveKitTests/LooseEndExtractorTests.swift`

**Interfaces:** unchanged signatures; only the prompt text changes.

- [ ] **Step 1: Write the failing test**

Add to `Tests/PensieveKitTests/LooseEndExtractorTests.swift`:

```swift
@Test func buildPromptCarriesSalienceDefinition() {
  let prompt = LooseEndExtractor.buildPrompt([PromptFragment(index: 0, text: "we should migrate later")])
  #expect(prompt.lowercased().contains("deferred"))
  #expect(prompt.contains("read the spec"))          // an explicit DROP example
  #expect(prompt.contains("[0]"))                    // still tags message indices
  #expect(prompt.contains("we should migrate later")) // still includes the body
}
```

> `PromptFragment` is `internal`; the test target uses `@testable import PensieveKit`, so it is accessible.

- [ ] **Step 2: Run to verify it fails**

Run: `./scripts/test.sh --filter buildPromptCarriesSalienceDefinition`
Expected: FAIL — current prompt lacks "deferred" / the drop example.

- [ ] **Step 3: Rewrite the prompt**

Replace the return in `LooseEndExtractor.buildPrompt` (lines 126-139) with:

```swift
    return """
    Extract LOOSE ENDS from a developer's own messages: DEFERRED, PARKED, or DECISION work they \
    left OPEN for later — e.g. "we should also migrate the auth tables", "let's do X later", \
    "TODO: wire up the webhook", "don't forget the rate limiter", "let's go with A instead of B". \
    Only use the text below.

    Do NOT extract in-the-moment requests the assistant simply carries out now (e.g. "read the \
    spec", "can you help me fix this?", "run the tests", "subagent-driven, let's go"), nor \
    acknowledgements, approvals, status checks, checklist items, or agent task briefs ("looks \
    good", "carry on", "are you done") — those are not loose ends.

    Return ONLY a JSON array. Each element: {"text": <short paraphrase>, "quote": <a VERBATIM \
    substring copied exactly from one message, including its original wording and casing>, \
    "messageIndex": <the [n] of the message the quote is from>}. The quote MUST be copied \
    character-for-character from a single message. If there are no loose ends, return [].

    Messages:
    \(body)
    """
```

- [ ] **Step 4: Run to verify it passes**

Run: `./scripts/test.sh --filter buildPromptCarriesSalienceDefinition`
Expected: PASS.

- [ ] **Step 5: Run the extractor suite (no regressions)**

Run: `./scripts/test.sh --filter LooseEndExtractor`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Sources/PensieveKit/Intelligence/LooseEndExtractor.swift Tests/PensieveKitTests/LooseEndExtractorTests.swift
git commit -F - <<'EOF'
feat(kit): sharpen the extractor prompt to salience

Redefine a loose end as deferred/parked/decision work with explicit drop
examples (in-the-moment requests). Reduces candidates at the source; the
SalienceClassifier is the guarantee.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01Ya7ToQ9MrGVDLzHkDB1mg3
EOF
```

---

## Task A4: Wire `SalienceClassifier` into `ExtractionRunner`

**Files:**
- Modify: `Sources/PensieveKit/Intelligence/ExtractionRunner.swift:79-104`
- Test: `Tests/PensieveKitTests/ExtractionRunnerTests.swift`

**Interfaces:** consumes `SalienceClassifier`.

- [ ] **Step 1: Write the failing test**

Add to `Tests/PensieveKitTests/ExtractionRunnerTests.swift`:

```swift
@Test func extractionAppliesSalienceGate() async throws {
  // Two candidates verified; the salience provider drops index 1. Only the salient one is stored.
  let ctx = try makeExtractionContext(prompts: [
    "we should also migrate the auth tables later",   // salient
    "please read the spec now",                        // in-the-moment -> dropped
  ])
  struct TwoThenDrop: LLMProvider {
    func complete(prompt: String) async throws -> String { "" }
    func classifyGenuineIndices(prompt: String) async throws -> [Int] { [0, 1] }
    func extractCandidates(prompt: String) async throws -> [LooseEndCandidate] {
      [LooseEndCandidate(text: "migrate auth", quote: "we should also migrate the auth tables later", messageIndex: 0),
       LooseEndCandidate(text: "read spec", quote: "please read the spec now", messageIndex: 1)]
    }
    func classifyNonSalientIndices(prompt: String) async throws -> [Int] { [1] }   // drop the request
  }
  _ = try await ExtractionRunner(db: ctx.db, provider: TwoThenDrop()).run()
  let stored = try ctx.db.read { db in try LooseEnd.where { $0.nodeID.eq(ctx.nodeID) }.fetchAll(db) }
  #expect(stored.map(\.quote) == ["we should also migrate the auth tables later"])
}
```

> Ensure the two `messageIndex` values map to real `isUserPrompt` messages in the fixture transcript so the verbatim gate passes both before salience runs. Adjust `makeExtractionContext` to emit those two user prompts as messages 0 and 1.

- [ ] **Step 2: Run to verify it fails**

Run: `./scripts/test.sh --filter extractionAppliesSalienceGate`
Expected: FAIL — both quotes stored (no salience gate yet).

- [ ] **Step 3: Insert the stage after verification**

In `ExtractionRunner.run()`, replace line 81:

```swift
        let verified = candidates.compactMap { LooseEndVerifier.verify($0, messages: session.messages) }
```

with:

```swift
        let verified = candidates.compactMap { LooseEndVerifier.verify($0, messages: session.messages) }
        // Salience gate: drop verified-but-in-the-moment requests (keeps deferred/decision work).
        // Runs on real, already-verified quotes; the verbatim gate is untouched.
        let salient = await SalienceClassifier(provider: provider).filter(verified, messages: session.messages)
```

Then change the insert loop to iterate `salient` instead of `verified`. In the `db.write` closure (lines 91-104), replace `if !verified.isEmpty {` with `if !salient.isEmpty {` and `for v in verified {` with `for v in salient {`. Keep the `ExtractionResult` `verified: verified.count` field as-is (proposed vs verified is still meaningful) but add the salient count is optional — leave `ExtractionResult` unchanged to avoid touching its consumers.

- [ ] **Step 4: Run to verify it passes**

Run: `./scripts/test.sh --filter extractionAppliesSalienceGate`
Expected: PASS.

- [ ] **Step 5: Run the ExtractionRunner suite (no regressions)**

Run: `./scripts/test.sh --filter ExtractionRunner`
Expected: PASS. (Existing tests use providers whose `classifyNonSalientIndices` inherits the default → their `complete` returns candidate JSON / `[]` → `decodeIndices` returns nil → the default throws → fail-open keeps all. Behavior unchanged.)

- [ ] **Step 6: Commit**

```bash
git add Sources/PensieveKit/Intelligence/ExtractionRunner.swift Tests/PensieveKitTests/ExtractionRunnerTests.swift
git commit -F - <<'EOF'
feat(kit): apply the salience gate in ExtractionRunner

Filter verified loose ends through SalienceClassifier before dedup/insert;
verbatim gate untouched; fail-open keeps existing tests green.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01Ya7ToQ9MrGVDLzHkDB1mg3
EOF
```

---

## Task A5: Salience eval (labeled fixture + go/no-go) — REVIEW-TIME, not CI

> This is the go/no-go gate for Part A, run **by hand at review time** against the real on-device model — **not** a deterministic CI test. It requires human labeling of real data (the reviewer/user). Do NOT let a subagent fabricate labels.

**Files:**
- Create: `Tests/PensieveKitTests/Fixtures/salience-labels.json`
- Create: `Tests/PensieveKitTests/SalienceEvalTests.swift` (env-gated; skipped unless `PENSIEVE_SALIENCE_EVAL=1`)

- [ ] **Step 1: Build the labeled fixture from the real store**

With the user, sample ~100–150 loose ends from the **live** store (weighted to the noisy nodes), and hand-label each `{ "quote": "...", "salient": true|false }` into `salience-labels.json`. Read from the live store read-only:

```bash
sqlite3 -json "$HOME/Library/Application Support/Pensieve/pensieve.sqlite" \
  "SELECT quote FROM looseEnds WHERE status='open' ORDER BY RANDOM() LIMIT 150;"
```
Label each row by hand (this is the human judgment the eval measures against).

- [ ] **Step 2: Write the env-gated eval harness**

Create `Tests/PensieveKitTests/SalienceEvalTests.swift`:

```swift
import Foundation
import Testing
@testable import PensieveKit

private struct Labeled: Codable { let quote: String; let salient: Bool }

/// Review-time eval against the REAL on-device model. Skipped in CI (no deterministic gate for a
/// probabilistic model). Run: PENSIEVE_SALIENCE_EVAL=1 ./scripts/test.sh --filter salienceEval
@Test func salienceEvalReport() async throws {
  guard ProcessInfo.processInfo.environment["PENSIEVE_SALIENCE_EVAL"] == "1" else { return }
  let url = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().appendingPathComponent("Fixtures/salience-labels.json")
  let labels = try JSONDecoder().decode([Labeled].self, from: Data(contentsOf: url))
  let provider = makeDefaultLLMProvider()
  let ends = labels.map { VerifiedLooseEnd(text: $0.quote, quote: $0.quote, role: "user", sourceMessageIndex: 0) }
  let msgs = labels.enumerated().map { TranscriptMessage(index: $0.offset, role: "user", text: $0.element.quote, timestamp: nil, isUserPrompt: true) }
  // (sourceMessageIndex is 0 for all here; give each end its own index if you want per-item context.)
  let kept = Set(await SalienceClassifier(provider: provider).filter(ends, messages: msgs).map(\.quote))

  let salientLabels = labels.filter { $0.salient }
  let keptSalient = salientLabels.filter { kept.contains($0.quote) }.count
  let keptTotal = labels.filter { kept.contains($0.quote) }.count
  let recall = Double(keptSalient) / Double(max(1, salientLabels.count))
  let precision = Double(keptSalient) / Double(max(1, keptTotal))
  print("SALIENCE EVAL — precision=\(precision) recall=\(recall) kept=\(keptTotal)/\(labels.count)")
}
```

- [ ] **Step 3: Run the eval and record the go/no-go**

Run: `PENSIEVE_SALIENCE_EVAL=1 ./scripts/test.sh --filter salienceEvalReport`
Record precision + recall. **Gate:** precision must rise materially over the un-gated baseline at a recall floor of **≥ 0.95** on the labeled-salient subset. Also run once with the extractor sharpening only (comment out the salience wiring) to confirm ② beats ① alone; if ① alone already hits the target, drop ② per the spec. If on-device fails the floor, escalate the salience judgment to `claude -p` via the provider (construct `SalienceClassifier(provider: ClaudeCLIProvider())` in `ExtractionRunner`) and re-run before merging A.

- [ ] **Step 4: Commit the fixture + harness**

```bash
git add Tests/PensieveKitTests/Fixtures/salience-labels.json Tests/PensieveKitTests/SalienceEvalTests.swift
git commit -F - <<'EOF'
test(kit): add salience eval (labeled fixture, env-gated)

Hand-labeled sample of real loose ends + a review-time precision/recall
harness (skipped in CI). Seed corpus for a future Create ML classifier.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01Ya7ToQ9MrGVDLzHkDB1mg3
EOF
```

---

## Task A6: Retroactive re-mine runbook (one-shot, after A+B merged)

> Executed **once, by hand, against the live store, only after A and B are both merged.** Not a CLI command, not code. The runbook documents the copy-first ritual.

**Files:**
- Create: `docs/superpowers/runbooks/2026-07-08-salience-retroactive-remine.md`

- [ ] **Step 1: Write the runbook**

Create `docs/superpowers/runbooks/2026-07-08-salience-retroactive-remine.md` with the exact procedure:

````markdown
# Retroactive salience re-mine (one-shot)

Run once, after the salience + workSummary work is merged and installed
(`~/.local/bin/pensieve` rebuilt). Rebuilds the live open loose-end set through
the salience gate and backfills `workSummary` in one full re-parse. The salience
gate is stochastic, so we dry-run on a COPY and diff before touching the live store.

Live store: `~/Library/Application Support/Pensieve/pensieve.sqlite`

## 1. Back up
```bash
cp ~/Library/Application\ Support/Pensieve/pensieve.sqlite /tmp/pensieve.backup.sqlite
```

## 2. Dry-run on a copy, diff the drops
```bash
cp ~/Library/Application\ Support/Pensieve/pensieve.sqlite /tmp/pensieve.copy.sqlite
# snapshot the current open set
sqlite3 /tmp/pensieve.copy.sqlite "SELECT quote FROM looseEnds WHERE status='open' ORDER BY quote;" > /tmp/before.txt
# reset watermarks so a re-mine re-parses every session
sqlite3 /tmp/pensieve.copy.sqlite "UPDATE events SET extractedMessageCount=0, extractedTranscriptSize=0 WHERE kind='cc.session';"
sqlite3 /tmp/pensieve.copy.sqlite "DELETE FROM looseEnds WHERE status='open';"
# re-mine the copy (honours PENSIEVE_DB)
PENSIEVE_DB=/tmp/pensieve.copy.sqlite pensieve ingest
sqlite3 /tmp/pensieve.copy.sqlite "SELECT quote FROM looseEnds WHERE status='open' ORDER BY quote;" > /tmp/after.txt
# eyeball what the salience gate dropped — every dropped item must be genuinely non-salient
diff /tmp/before.txt /tmp/after.txt | grep '^<'
```
STOP and reconsider (raise the keep bias / escalate to claude -p) if the diff drops anything genuinely deferred/decision. Proceed only when the drops are all in-the-moment noise.

## 3. Pre-flight transcript existence (live)
```bash
# For every open loose end, confirm its source transcript still exists; abort if any is missing
# (deleting it would be permanent). One-liner or a short check reading looseEnds -> events.detailJSON transcriptPath.
```

## 4. Quiesce the daemon
```bash
launchctl unload ~/Library/LaunchAgents/com.pensieve.sync.plist
```

## 5. Reset + delete + re-mine (live)
```bash
sqlite3 ~/Library/Application\ Support/Pensieve/pensieve.sqlite \
  "DELETE FROM looseEnds WHERE status='open';
   UPDATE events SET extractedMessageCount=0, extractedTranscriptSize=0 WHERE kind='cc.session';"
pensieve ingest    # rebuilds the salient open set AND backfills workSummary in one pass (slow)
```
Report before/after open counts.

## 6. Reload the daemon
```bash
launchctl load ~/Library/LaunchAgents/com.pensieve.sync.plist
```
````

- [ ] **Step 2: Commit**

```bash
git add docs/superpowers/runbooks/2026-07-08-salience-retroactive-remine.md
git commit -F - <<'EOF'
docs: add retroactive salience re-mine runbook (copy-first)

One-shot, hand-run cleanup: dry-run on a copy + diff the stochastic gate's
drops before touching the live store; one re-parse backfills workSummary.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01Ya7ToQ9MrGVDLzHkDB1mg3
EOF
```

---

## Final verification (whole branch)

- [ ] **Full Kit suite green**

Run: `./scripts/test.sh`
Expected: PASS (all prior tests + the new ones; existing behavior unchanged by fail-open + nil-fallback defaults).

- [ ] **App builds + smoke-launches**

Run:
```bash
xcodegen generate && xcodebuild -project Pensieve.xcodeproj -scheme Pensieve -configuration Debug -derivedDataPath ./.build-xcode build
PENSIEVE_DB=/tmp/pv-final.sqlite PENSIEVE_CAPTURE_DB=/tmp/pv-final-cap.sqlite \
  ./.build-xcode/Build/Products/Debug/Pensieve.app/Contents/MacOS/Pensieve & PID=$!; sleep 4; kill $PID
```
Expected: BUILD SUCCEEDED + clean launch/exit.

- [ ] **On-device acceptance run (final gate)**

With the user, on a copy of the real store: run `PENSIEVE_DB=<copy> pensieve ingest` and eyeball — (1) loose ends are deferred/decision items, not every prompt; (2) narration on a session-heavy node describes real work and shows the "Generated summary" mark; (3) 0 fabrication. This is the Phase-1B ritual and the merge gate for Part A.

- [ ] **Whole-branch review** via `superpowers:requesting-code-review` (Opus), then `superpowers:finishing-a-development-branch`.
