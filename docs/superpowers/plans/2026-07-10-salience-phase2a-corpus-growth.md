# Salience Phase 2a — Corpus-Growth Engine Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Grow the human-confirmed salience corpus (~40 → ~150+ salient) with an offline Haiku bootstrap labeler over the stored loose-end backlog plus a bulk in-app audit surface — producing the training corpus for the deferred Phase 2b classifier.

**Architecture:** A new CLI subcommand `pensieve label-suggest` runs a store-facing `SalienceSuggester` (Kit) that re-parses each loose end's transcript for context, classifies via `claude -p` Haiku, and writes `labelSuggestion` only — never the human `label`. A sibling `--import` mode folds parked hand-labels into `label`. A read-only `SalienceReviewQueries` backs a new "Review Suggestions" sidebar surface where the human confirms suggestions into the corpus. The existing inline ghost pre-fill on `LooseEndRow` (already shipped in Phase 1) needs no change.

**Tech Stack:** Swift 6, SwiftUI (app target), SQLiteData/GRDB (canonical store), ArgumentParser (CLI), Swift Testing, `claude -p` (Haiku provider via the existing `LLMProvider` seam).

## Global Constraints

- **SQLiteData predicates use `.eq(x)` / `.neq(x)`, NOT `==`** (e.g. `.where { $0.label.eq("") }`).
- **Label string values come from `LooseEndLabel`** (`unlabeled` = `""`, `salient`, `noise`) — never hardcode.
- **The human is the only writer of `label`.** The bootstrap writes `labelSuggestion` only (`LooseEndCommands.suggest`); `label` is written only by human confirmation (`setLabel`) or the `--import` of prior human adjudication.
- **No schema migration** — `label`/`labelSuggestion` already exist (Phase 1, migration v11).
- **No change to `Ingester.drain()`, capture, the sync daemon, `LooseEndVerifier`, or `ExtractionRunner`'s pipeline.** The bootstrap is an offline, manually-run CLI.
- **No trained classifier, no Core ML, no auto-hiding, no change to `LooseEnd.isOpen`** — all deferred to Phase 2b.
- **No Python. Swift only.**
- **Kit stays SwiftUI-free and testable; app views stay thin** (derivation in Kit). App target has no unit tests — verify via `xcodebuild` build + non-blocking smoke-launch of the inner binary.
- **App chrome strings are localized (en + de)** via `Localizable.xcstrings`, reconciled by hand (xcodebuild does not auto-populate keys). Node/loose-end content is never localized.
- Run tests with `./scripts/test.sh` (optionally `--filter <name>`). Build the app with `xcodegen generate && xcodebuild -project Pensieve.xcodeproj -scheme Pensieve -configuration Debug -derivedDataPath ./.build-xcode build`.
- Commit messages: use `git commit -F <<'EOF' … EOF` (backticks in `-m "…"` get shell-executed); keep the `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>` trailer.

---

## File Structure

- **Modify** `Sources/PensieveKit/Intelligence/SalienceClassifier.swift` — extract a `[(quote, context)]` prompt-builder overload; the existing `(batch, messages)` builder delegates to it (behavior-preserving).
- **Create** `Sources/PensieveKit/Intelligence/SalienceSuggester.swift` — store-facing bootstrap engine.
- **Create** `Sources/PensieveKit/Query/SalienceReviewQueries.swift` — read-only audit-queue query + count.
- **Modify** `Sources/PensieveKit/Query/LooseEndCommands.swift` — add `importLabels`.
- **Create** `Sources/pensieve/Commands/LabelSuggest.swift` — CLI (suggest + import modes).
- **Modify** `Sources/pensieve/Pensieve.swift` — register the subcommand.
- **Modify** `Sources/PensieveApp/AppModel.swift` — `SidebarSelection`/`MiddleKind` review cases, `reviewItems()`, `reviewCount`, `middleKind()`.
- **Modify** `Sources/PensieveApp/SidebarView.swift` — "Review Suggestions" entry.
- **Modify** `Sources/PensieveApp/ContentListView.swift` — render the review case; fix `MiddleLoadKey` to distinguish it.
- **Modify** `Sources/PensieveApp/Localizable.xcstrings` — new keys (en + de).
- **Create** `Tests/PensieveKitTests/SalienceSuggesterTests.swift`, `Tests/PensieveKitTests/SalienceReviewQueriesTests.swift`; **extend** `Tests/PensieveKitTests/LooseEndCommandsTests.swift` (import).

---

## Task 1: Refactor `SalienceClassifier.buildPrompt` to a pairs overload

Extract the prompt body so a caller can pass pre-rendered `(quote, context)` pairs (needed by the suggester, which batches across event-groups). Behavior-preserving: the existing overload delegates, so `SalienceClassifierTests` stay green.

**Files:**
- Modify: `Sources/PensieveKit/Intelligence/SalienceClassifier.swift:63-81`
- Test: `Tests/PensieveKitTests/SalienceClassifierTests.swift` (existing; must stay green)

**Interfaces:**
- Produces: `static func buildPrompt(_ items: [(quote: String, context: String)]) -> String` — the salience prompt over pre-rendered pairs, emitting `[n] QUOTE: <quote>\nCONTEXT:\n<context>` items exactly as before.
- Produces (unchanged signature, now delegating): `static func buildPrompt(_ batch: [VerifiedLooseEnd], messages: [TranscriptMessage]) -> String`.

- [ ] **Step 1: Add a test pinning the pairs overload's format**

Add to `Tests/PensieveKitTests/SalienceClassifierTests.swift`:

```swift
@Test func buildPromptPairsOverloadEmitsQuoteAndContext() {
  let p = SalienceClassifier.buildPrompt([(quote: "migrate the auth tables later", context: "user: migrate the auth tables later")])
  #expect(p.contains("[0] QUOTE: migrate the auth tables later"))
  #expect(p.contains("CONTEXT:\nuser: migrate the auth tables later"))
  #expect(p.contains("Return ONLY a JSON array"))
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `./scripts/test.sh --filter buildPromptPairsOverloadEmitsQuoteAndContext`
Expected: FAIL to compile — `buildPrompt` has no `[(quote:context:)]` overload.

- [ ] **Step 3: Refactor `buildPrompt`**

Replace `SalienceClassifier.swift:63-81` (the existing `buildPrompt(_ batch:messages:)`) with:

```swift
  static func buildPrompt(_ batch: [VerifiedLooseEnd], messages: [TranscriptMessage]) -> String {
    buildPrompt(batch.map { (quote: $0.quote, context: contextWindow(for: $0, messages: messages)) })
  }

  /// The salience prompt over pre-rendered (quote, context) pairs. Kept as ONE definition so the
  /// live `filter` path and the offline `SalienceSuggester` never drift.
  static func buildPrompt(_ items: [(quote: String, context: String)]) -> String {
    let body = items.enumerated().map { (n, it) in
      "[\(n)] QUOTE: \(it.quote)\nCONTEXT:\n\(it.context)"
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
```

- [ ] **Step 4: Run the full SalienceClassifier suite**

Run: `./scripts/test.sh --filter Salience`
Expected: PASS — the new format test plus all existing `salience*` tests (esp. `salienceMapsDropIndicesPerBatchNotGlobally`, which asserts `QUOTE: <quote>` appears in the prompt).

- [ ] **Step 5: Commit**

```bash
git add Sources/PensieveKit/Intelligence/SalienceClassifier.swift Tests/PensieveKitTests/SalienceClassifierTests.swift
git commit -F - <<'EOF'
refactor(kit): SalienceClassifier.buildPrompt pairs overload

Extract the salience prompt over pre-rendered (quote, context) pairs so the
offline suggester can batch across event-groups through the same prompt
definition. The (batch, messages) overload delegates — behavior-preserving.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
```

---

## Task 2: `SalienceSuggester` (Kit) — the store-facing bootstrap engine

Selects unlabeled open loose ends, re-parses each one's transcript for context (quote-only fallback when absent), classifies in batches via the injected provider, and writes `labelSuggestion` — writing nothing for a batch whose provider call fails (so a re-run retries).

**Files:**
- Create: `Sources/PensieveKit/Intelligence/SalienceSuggester.swift`
- Test: `Tests/PensieveKitTests/SalienceSuggesterTests.swift`

**Interfaces:**
- Consumes: `SalienceClassifier.buildPrompt(_:[(quote:context:)])` and `SalienceClassifier.contextWindow(for:messages:)` (Task 1); `LooseEndCommands.suggest`; `LooseEndLabel`; `VerifiedLooseEnd`; `TranscriptParser.parse(fileURL:)`; `ParsedSession`.
- Produces:
  - `struct SalienceSuggester` with `init(provider: any LLMProvider, batchCharBudget: Int = 2000, parse: @escaping @Sendable (URL) -> ParsedSession = { TranscriptParser.parse(fileURL: $0) })`.
  - `func run(_ db: any DatabaseWriter, limit: Int?, force: Bool) async throws -> SalienceSuggester.Summary`.
  - `struct SalienceSuggester.Summary: Sendable, Equatable { let candidates, suggested, salient, noise, quoteOnly, skippedBatches: Int }`.

- [ ] **Step 1: Write the failing tests**

Create `Tests/PensieveKitTests/SalienceSuggesterTests.swift`:

```swift
import Foundation
import Testing
import SQLiteData
@testable import PensieveKit

/// Stub provider: returns a fixed drop set (never throws) — success path.
private struct DropSet: LLMProvider {
  let drop: [Int]
  func complete(prompt: String) async throws -> String { "[]" }
  func classifyNonSalientIndices(prompt: String) async throws -> [Int] { drop }
}
/// Stub provider: always throws — the write-nothing path.
private struct AlwaysThrows: LLMProvider {
  func complete(prompt: String) async throws -> String { "[]" }
  func classifyNonSalientIndices(prompt: String) async throws -> [Int] { throw LLMError.providerFailed("x") }
}

/// Seeds one node+source+event and a loose end on it. Returns (looseEndID, eventID).
@discardableResult
private func seedLE(_ db: any DatabaseWriter, quote: String, label: String = "",
                    suggestion: String = "", status: String = "open",
                    messageIndex: Int = 0) throws -> (UUID, UUID) {
  let node = Node(name: "N")
  let source = Source(nodeID: node.id, kind: SourceKind.claudeCode, key: "/src/\(UUID().uuidString)")
  let ev = Event(nodeID: node.id, sourceID: source.id, occurredAt: Date(),
                 kind: CaptureKind.ccSession, summary: "s",
                 detailJSON: "{\"transcriptPath\":\"/tmp/does-not-exist-\(UUID().uuidString).jsonl\"}")
  let le = LooseEnd(nodeID: node.id, sourceEventID: ev.id, text: quote, quote: quote,
                    status: status, sourceMessageIndex: messageIndex,
                    label: label, labelSuggestion: suggestion)
  try db.write { db in
    try Node.insert { node }.execute(db)
    try Source.insert { source }.execute(db)
    try Event.insert { ev }.execute(db)
    try LooseEnd.insert { le }.execute(db)
  }
  return (le.id, ev.id)
}

private func labelOf(_ db: any DatabaseWriter, _ id: UUID) throws -> (label: String, suggestion: String) {
  let row = try db.read { db in try LooseEnd.where { $0.id.eq(id) }.fetchOne(db) }!
  return (row.label, row.labelSuggestion)
}

// A parse stub that returns no messages → forces the quote-only path for every event.
private let noMessages: @Sendable (URL) -> ParsedSession = { _ in
  ParsedSession(sessionID: "s", cwd: nil, startedAt: nil, endedAt: nil, userPromptCount: 0, messages: [])
}

@Test func suggesterWritesSuggestionMatchingDropSet() async throws {
  let db = try openCanonicalDatabase(at: tempURL("sug-drop"))
  let (keep, _) = try seedLE(db, quote: "we should migrate the auth tables later")
  let (drop, _) = try seedLE(db, quote: "please read the spec right now")
  // Drop index 1 within the (single) batch. Both share one batch under the default budget.
  let summary = try await SalienceSuggester(provider: DropSet(drop: [1]), parse: noMessages)
    .run(db, limit: nil, force: false)
  // The suggester classifies in stored order; assert by resulting suggestion, not index.
  let all = [keep, drop].map { try! labelOf(db, $0) }
  #expect(all.contains { $0.suggestion == "salient" })
  #expect(all.contains { $0.suggestion == "noise" })
  #expect(summary.suggested == 2)
  #expect(summary.quoteOnly == 2)   // both had no transcript
  #expect(try labelOf(db, keep).label == "")   // never writes the human label
}

@Test func suggesterWritesNothingWhenProviderFails() async throws {
  let db = try openCanonicalDatabase(at: tempURL("sug-throw"))
  let (id, _) = try seedLE(db, quote: "a genuinely deferred item to revisit later")
  let summary = try await SalienceSuggester(provider: AlwaysThrows(), parse: noMessages)
    .run(db, limit: nil, force: false)
  #expect(try labelOf(db, id).suggestion == "")   // untouched → a re-run retries
  #expect(summary.suggested == 0)
  #expect(summary.skippedBatches >= 1)
}

@Test func suggesterSkipsLabeledAndAlreadySuggested() async throws {
  let db = try openCanonicalDatabase(at: tempURL("sug-skip"))
  let (labeled, _) = try seedLE(db, quote: "already human labeled here", label: LooseEndLabel.salient)
  let (suggested, _) = try seedLE(db, quote: "already machine suggested here", suggestion: LooseEndLabel.noise)
  let (fresh, _) = try seedLE(db, quote: "fresh unlabeled candidate here")
  let summary = try await SalienceSuggester(provider: DropSet(drop: []), parse: noMessages)
    .run(db, limit: nil, force: false)
  #expect(summary.candidates == 1)                      // only `fresh`
  #expect(try labelOf(db, labeled).label == "salient")  // untouched
  #expect(try labelOf(db, suggested).suggestion == "noise")   // untouched
  #expect(try labelOf(db, fresh).suggestion == "salient")     // empty drop set → salient
}

@Test func suggesterForceReincludesAlreadySuggested() async throws {
  let db = try openCanonicalDatabase(at: tempURL("sug-force"))
  let (suggested, _) = try seedLE(db, quote: "already machine suggested here", suggestion: LooseEndLabel.salient)
  let summary = try await SalienceSuggester(provider: DropSet(drop: [0]), parse: noMessages)
    .run(db, limit: nil, force: true)
  #expect(summary.candidates == 1)
  #expect(try labelOf(db, suggested).suggestion == "noise")   // re-suggested (drop [0] → noise)
}

@Test func suggesterRespectsLimit() async throws {
  let db = try openCanonicalDatabase(at: tempURL("sug-limit"))
  for i in 0..<5 { try seedLE(db, quote: "candidate number \(i) to consider") }
  let summary = try await SalienceSuggester(provider: DropSet(drop: []), parse: noMessages)
    .run(db, limit: 2, force: false)
  #expect(summary.candidates == 2)
  #expect(summary.suggested == 2)
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `./scripts/test.sh --filter suggester`
Expected: FAIL to compile — no `SalienceSuggester`.

- [ ] **Step 3: Implement `SalienceSuggester`**

Create `Sources/PensieveKit/Intelligence/SalienceSuggester.swift`:

```swift
import Foundation
import SQLiteData
import GRDB

/// The offline bootstrap labeler: over the STORED loose-end backlog (not live extraction), it
/// re-parses each loose end's transcript for context, classifies deferred-vs-in-the-moment via the
/// injected provider (Haiku, from the CLI), and writes `labelSuggestion` ONLY. Never touches the
/// human `label`. A batch whose provider call fails writes nothing, so a re-run retries it.
public struct SalienceSuggester {
  public struct Summary: Sendable, Equatable {
    public let candidates: Int, suggested: Int, salient: Int, noise: Int
    public let quoteOnly: Int, skippedBatches: Int
  }

  private let provider: any LLMProvider
  private let batchCharBudget: Int
  private let parse: @Sendable (URL) -> ParsedSession

  public init(provider: any LLMProvider, batchCharBudget: Int = 2000,
              parse: @escaping @Sendable (URL) -> ParsedSession = { TranscriptParser.parse(fileURL: $0) }) {
    self.provider = provider
    self.batchCharBudget = batchCharBudget
    self.parse = parse
  }

  private struct Item { let id: UUID; let quote: String; let context: String }

  public func run(_ db: any DatabaseWriter, limit: Int?, force: Bool) async throws -> Summary {
    // 1. Candidates: open + unlabeled; skip already-suggested unless `force`. Deterministic order
    //    (createdAt) so `--limit` is reproducible.
    let candidates: [LooseEnd] = try db.read { db in
      let rows = try LooseEnd.where { $0.status.eq("open") && $0.label.eq("") }.fetchAll(db)
      return rows.filter { force || $0.labelSuggestion.isEmpty }
                 .sorted { $0.createdAt < $1.createdAt }
    }
    let capped = limit.map { Array(candidates.prefix($0)) } ?? candidates

    // 2. Group by source event; parse each transcript ONCE; render each item's context window.
    //    A missing/empty transcript → quote-only ("" context).
    var items: [Item] = []
    var quoteOnly = 0
    let byEvent = Dictionary(grouping: capped, by: { $0.sourceEventID })
    for (eventID, group) in byEvent {
      let messages = try messages(db, eventID: eventID)
      for le in group {
        let vle = VerifiedLooseEnd(text: le.text, quote: le.quote, role: le.role,
                                   sourceMessageIndex: le.sourceMessageIndex)
        let ctx = messages.isEmpty ? "" : SalienceClassifier.contextWindow(for: vle, messages: messages)
        if messages.isEmpty { quoteOnly += 1 }
        items.append(Item(id: le.id, quote: le.quote, context: ctx))
      }
    }

    // 3. Batch flat by cost; classify; write. Provider failure (nil) → skip the batch (write nothing).
    var suggested = 0, salient = 0, noise = 0, skipped = 0
    for batch in Self.batches(items, budget: batchCharBudget) {
      let prompt = SalienceClassifier.buildPrompt(batch.map { (quote: $0.quote, context: $0.context) })
      guard let dropIdx = try? await provider.classifyNonSalientIndices(prompt: prompt) else {
        skipped += batch.count
        continue
      }
      let dropSet = Set(dropIdx)
      for (n, it) in batch.enumerated() {
        let label = dropSet.contains(n) ? LooseEndLabel.noise : LooseEndLabel.salient
        _ = try? LooseEndCommands.suggest(db, id: it.id, label: label)
        suggested += 1
        if label == LooseEndLabel.salient { salient += 1 } else { noise += 1 }
      }
    }
    return Summary(candidates: capped.count, suggested: suggested, salient: salient,
                   noise: noise, quoteOnly: quoteOnly, skippedBatches: skipped)
  }

  /// Parse the event's transcript (best-effort). Returns [] on missing event / no path / empty parse.
  private func messages(_ db: any DatabaseWriter, eventID: UUID) throws -> [TranscriptMessage] {
    guard let ev = try db.read({ db in try Event.where { $0.id.eq(eventID) }.fetchOne(db) }) else { return [] }
    let detail = (try? JSONDecoder().decode([String: String].self, from: Data(ev.detailJSON.utf8))) ?? [:]
    guard let path = detail["transcriptPath"], !path.isEmpty else { return [] }
    return parse(URL(fileURLWithPath: path)).messages
  }

  /// Flat cost-bounded batching (quote + context + tag overhead), mirroring SalienceClassifier.batches
  /// but over pre-rendered items rather than (ends, shared messages).
  static func batches(_ items: [Item], budget: Int) -> [[Item]] {
    var out: [[Item]] = [], current: [Item] = [], size = 0
    for it in items {
      let cost = it.quote.count + it.context.count + 16
      if size + cost > budget, !current.isEmpty { out.append(current); current = []; size = 0 }
      current.append(it); size += cost
    }
    if !current.isEmpty { out.append(current) }
    return out
  }
}
```

- [ ] **Step 4: Run the suggester tests**

Run: `./scripts/test.sh --filter suggester`
Expected: PASS (all five).

- [ ] **Step 5: Commit**

```bash
git add Sources/PensieveKit/Intelligence/SalienceSuggester.swift Tests/PensieveKitTests/SalienceSuggesterTests.swift
git commit -F - <<'EOF'
feat(kit): SalienceSuggester — offline Haiku bootstrap over the backlog

Over stored unlabeled open loose ends: re-parse each transcript for context
(quote-only fallback), batch-classify via the injected provider, write
labelSuggestion only. Provider failure writes nothing (re-run retries).
Never touches the human label. Injected parse for deterministic tests.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
```

---

## Task 3: `LooseEndCommands.importLabels` (Kit) — fold parked hand-labels into `label`

Quote-match a list of `(quote, label)` to stored loose ends and write the **human** `label`; skip non-matches. Whitespace-normalized match (quotes may differ in spacing). Idempotent.

**Files:**
- Modify: `Sources/PensieveKit/Query/LooseEndCommands.swift`
- Test: `Tests/PensieveKitTests/LooseEndCommandsTests.swift` (extend)

**Interfaces:**
- Consumes: `normalizeWhitespace(_:)` (public, `TextNormalization.swift`); `LooseEndCommands.setLabel`.
- Produces: `static func importLabels(_ db: any DatabaseWriter, _ entries: [(quote: String, label: String)]) throws -> (matched: Int, skipped: Int)`.

- [ ] **Step 1: Write the failing tests**

Add to `Tests/PensieveKitTests/LooseEndCommandsTests.swift`:

```swift
@Test func importLabelsMatchesByNormalizedQuoteAndSkipsUnmatched() throws {
  let db = try openCanonicalDatabase(at: tempURL("cmd-import"))
  let a = try seedLooseEnd(db, quote: "we should migrate the auth tables later")
  let b = try seedLooseEnd(db, quote: "read the spec now")
  // Entry quote differs only by whitespace; entry 3 matches nothing.
  let result = try LooseEndCommands.importLabels(db, [
    (quote: "we should migrate   the auth tables later", label: LooseEndLabel.salient),
    (quote: "read the spec now", label: LooseEndLabel.noise),
    (quote: "this quote is not in the store at all", label: LooseEndLabel.salient),
  ])
  #expect(result.matched == 2)
  #expect(result.skipped == 1)
  #expect(try db.read { db in try LooseEnd.where { $0.id.eq(a) }.fetchOne(db) }?.label == "salient")
  #expect(try db.read { db in try LooseEnd.where { $0.id.eq(b) }.fetchOne(db) }?.label == "noise")
}

@Test func importLabelsIsIdempotent() throws {
  let db = try openCanonicalDatabase(at: tempURL("cmd-import-idem"))
  let a = try seedLooseEnd(db, quote: "park the canvas idea for now")
  _ = try LooseEndCommands.importLabels(db, [(quote: "park the canvas idea for now", label: LooseEndLabel.salient)])
  let second = try LooseEndCommands.importLabels(db, [(quote: "park the canvas idea for now", label: LooseEndLabel.salient)])
  #expect(second.matched == 1)   // matches again; a no-op write
  #expect(try db.read { db in try LooseEnd.where { $0.id.eq(a) }.fetchOne(db) }?.label == "salient")
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `./scripts/test.sh --filter importLabels`
Expected: FAIL to compile — no `importLabels`.

- [ ] **Step 3: Implement `importLabels`**

Add to `LooseEndCommands` (in `Sources/PensieveKit/Query/LooseEndCommands.swift`, inside the enum):

```swift
  /// Fold externally hand-adjudicated labels into the human `label` by verbatim (whitespace-
  /// normalized) quote match. Skips entries matching no stored loose end. Idempotent. This writes
  /// the CORPUS `label` (not a suggestion) because the entries are prior human adjudication.
  public static func importLabels(_ db: any DatabaseWriter,
                                  _ entries: [(quote: String, label: String)]) throws -> (matched: Int, skipped: Int) {
    // Build a normalized-quote -> [id] index once (a quote may recur across nodes; label them all).
    let index: [String: [UUID]] = try db.read { db in
      var map: [String: [UUID]] = [:]
      for le in try LooseEnd.all.fetchAll(db) {
        map[normalizeWhitespace(le.quote), default: []].append(le.id)
      }
      return map
    }
    var matched = 0, skipped = 0
    for entry in entries {
      guard let ids = index[normalizeWhitespace(entry.quote)], !ids.isEmpty else { skipped += 1; continue }
      for id in ids { _ = try setLabel(db, id: id, label: entry.label) }
      matched += 1
    }
    return (matched, skipped)
  }
```

Note: `LooseEnd.all.fetchAll(db)` — if `.all` is not the correct SQLiteData all-rows accessor in this codebase, use `LooseEnd.where { $0.id.neq(UUID()) }.fetchAll(db)` or the same pattern `LooseEndQueries`/`corpus` use (`LooseEnd.where { … }.fetchAll`). Confirm against `LooseEndCommands.corpus` (which uses `LooseEnd.where { $0.label.neq("") }.fetchAll(db)`); mirror that call style.

- [ ] **Step 4: Run the import tests**

Run: `./scripts/test.sh --filter importLabels`
Expected: PASS (both).

- [ ] **Step 5: Commit**

```bash
git add Sources/PensieveKit/Query/LooseEndCommands.swift Tests/PensieveKitTests/LooseEndCommandsTests.swift
git commit -F - <<'EOF'
feat(kit): LooseEndCommands.importLabels — fold parked hand-labels

Quote-match (whitespace-normalized) externally hand-adjudicated labels to
stored loose ends and write the human `label`; skip non-matches. Idempotent.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
```

---

## Task 4: `SalienceReviewQueries` (Kit) — the audit-queue read

Open, unlabeled loose ends that carry a machine suggestion, ordered **suggested-salient first** then oldest-source-first. Plus a cheap count for the sidebar badge.

**Files:**
- Create: `Sources/PensieveKit/Query/SalienceReviewQueries.swift`
- Test: `Tests/PensieveKitTests/SalienceReviewQueriesTests.swift`

**Interfaces:**
- Consumes: `LooseEndView` (`LooseEndQueries.swift`); `LooseEnd`; `Event`.
- Produces:
  - `static func pending(_ db: any DatabaseReader, now: Date) throws -> [LooseEndView]`.
  - `static func pendingCount(_ db: any DatabaseReader) throws -> Int`.

- [ ] **Step 1: Write the failing tests**

Create `Tests/PensieveKitTests/SalienceReviewQueriesTests.swift`:

```swift
import Foundation
import Testing
import SQLiteData
@testable import PensieveKit

@discardableResult
private func seed(_ db: any DatabaseWriter, quote: String, label: String, suggestion: String,
                 status: String = "open", daysAgo: Int = 0) throws -> UUID {
  let node = Node(name: "N")
  let source = Source(nodeID: node.id, kind: SourceKind.claudeCode, key: "/src/\(UUID().uuidString)")
  let when = Calendar.current.date(byAdding: .day, value: -daysAgo, to: Date())!
  let ev = Event(nodeID: node.id, sourceID: source.id, occurredAt: when,
                 kind: CaptureKind.ccSession, summary: "s", detailJSON: "{}")
  let le = LooseEnd(nodeID: node.id, sourceEventID: ev.id, text: quote, quote: quote,
                    status: status, label: label, labelSuggestion: suggestion)
  try db.write { db in
    try Node.insert { node }.execute(db)
    try Source.insert { source }.execute(db)
    try Event.insert { ev }.execute(db)
    try LooseEnd.insert { le }.execute(db)
  }
  return le.id
}

@Test func reviewPendingReturnsOnlyUnlabeledSuggestedOpen() throws {
  let db = try openCanonicalDatabase(at: tempURL("rev-filter"))
  let want = try seed(db, quote: "unlabeled with suggestion", label: "", suggestion: LooseEndLabel.salient)
  _ = try seed(db, quote: "already human labeled", label: LooseEndLabel.salient, suggestion: LooseEndLabel.salient)
  _ = try seed(db, quote: "unlabeled no suggestion", label: "", suggestion: "")
  _ = try seed(db, quote: "resolved one", label: "", suggestion: LooseEndLabel.noise, status: "resolved")
  let pending = try SalienceReviewQueries.pending(db, now: Date())
  #expect(pending.map(\.looseEnd.id) == [want])
  #expect(try SalienceReviewQueries.pendingCount(db) == 1)
}

@Test func reviewPendingOrdersSuggestedSalientFirst() throws {
  let db = try openCanonicalDatabase(at: tempURL("rev-order"))
  let noiseOld = try seed(db, quote: "noise suggested older", label: "", suggestion: LooseEndLabel.noise, daysAgo: 10)
  let salientNew = try seed(db, quote: "salient suggested newer", label: "", suggestion: LooseEndLabel.salient, daysAgo: 1)
  let pending = try SalienceReviewQueries.pending(db, now: Date())
  // Salient-suggested first regardless of age; then the noise one.
  #expect(pending.map(\.looseEnd.id) == [salientNew, noiseOld])
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `./scripts/test.sh --filter reviewPending`
Expected: FAIL to compile — no `SalienceReviewQueries`.

- [ ] **Step 3: Implement `SalienceReviewQueries`**

Create `Sources/PensieveKit/Query/SalienceReviewQueries.swift`:

```swift
import Foundation
import SQLiteData

/// The audit queue backing the app's "Review Suggestions" surface: open, unlabeled loose ends that
/// carry a machine `labelSuggestion`, ordered suggested-salient FIRST (harvest the scarce positives
/// — Haiku's high recall puts nearly all true positives in its salient bucket) then oldest source
/// first. Read-only; reuses `LooseEndView`.
public enum SalienceReviewQueries {
  public static func pending(_ db: any DatabaseReader, now: Date) throws -> [LooseEndView] {
    try db.read { db in
      let ends = try LooseEnd
        .where { $0.status.eq("open") && $0.label.eq("") && $0.labelSuggestion.neq("") }
        .fetchAll(db)
      var views: [LooseEndView] = []
      for le in ends {
        guard let event = try Event.where({ $0.id.eq(le.sourceEventID) }).fetchOne(db) else { continue }
        let days = Calendar.current.dateComponents([.day], from: event.occurredAt, to: now).day ?? 0
        views.append(LooseEndView(looseEnd: le, occurredAt: event.occurredAt, ageDays: days))
      }
      // Suggested-salient first (0 before 1), then oldest source first.
      return views.sorted { a, b in
        let aRank = a.looseEnd.labelSuggestion == LooseEndLabel.salient ? 0 : 1
        let bRank = b.looseEnd.labelSuggestion == LooseEndLabel.salient ? 0 : 1
        if aRank != bRank { return aRank < bRank }
        return a.occurredAt < b.occurredAt
      }
    }
  }

  public static func pendingCount(_ db: any DatabaseReader) throws -> Int {
    try db.read { db in
      try LooseEnd.where { $0.status.eq("open") && $0.label.eq("") && $0.labelSuggestion.neq("") }.fetchCount(db)
    }
  }
}
```

Note: if `.fetchCount(db)` is not the count API in this SQLiteData version, use `try LooseEnd.where { … }.fetchAll(db).count`.

- [ ] **Step 4: Run the review-query tests**

Run: `./scripts/test.sh --filter reviewPending`
Expected: PASS (both).

- [ ] **Step 5: Commit**

```bash
git add Sources/PensieveKit/Query/SalienceReviewQueries.swift Tests/PensieveKitTests/SalienceReviewQueriesTests.swift
git commit -F - <<'EOF'
feat(kit): SalienceReviewQueries — the audit queue

Open, unlabeled loose ends carrying a machine suggestion, ordered
suggested-salient first then oldest source first. Plus pendingCount for the
sidebar badge. Read-only; reuses LooseEndView.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
```

---

## Task 5: CLI `pensieve label-suggest` (suggest + import) + register

Thin command: suggest mode builds a Haiku `claude -p` provider and runs `SalienceSuggester`; import mode reads a `[{quote, salient}]` JSON and runs `importLabels`.

**Files:**
- Create: `Sources/pensieve/Commands/LabelSuggest.swift`
- Modify: `Sources/pensieve/Pensieve.swift:11-18` (subcommands array)

**Interfaces:**
- Consumes: `openCanonical()` (`Pensieve.swift`); `SalienceSuggester` (Task 2); `LooseEndCommands.importLabels` (Task 3); `ClaudeCLIProvider`; `LLMError`; `LooseEndLabel`.
- Produces: `struct LabelSuggest: AsyncParsableCommand` registered under `pensieve`.

- [ ] **Step 1: Create the command**

Create `Sources/pensieve/Commands/LabelSuggest.swift`:

```swift
import ArgumentParser
import Foundation
import PensieveKit

/// Offline salience bootstrap. Default: pre-label the unlabeled open backlog with Haiku (writes
/// labelSuggestion only). `--import`: fold prior hand-adjudicated labels into the human `label`.
struct LabelSuggest: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "label-suggest",
    abstract: "Pre-label open loose ends with Haiku (suggestion only), or import hand-labels.")

  @Option(name: .long, help: "Import human labels from a JSON file of {quote, salient} instead of suggesting.")
  var `import`: String?

  @Option(name: .long, help: "Cap the number of loose ends suggested in this run.")
  var limit: Int?

  @Flag(name: .long, help: "Re-suggest loose ends that already have a suggestion.")
  var force: Bool = false

  @Option(name: .long, help: "Model for the suggestion pass (claude -p).")
  var model: String = "claude-haiku-4-5-20251001"

  func run() async throws {
    let db = try openCanonical()

    if let path = `import` {
      let entries = try Self.decodeLabels(at: path)
      let result = try LooseEndCommands.importLabels(db, entries)
      print("Imported: \(result.matched) matched, \(result.skipped) skipped (no matching quote).")
      return
    }

    let modelName = model
    let provider = ClaudeCLIProvider(run: { try Self.claudeRun($0, model: modelName) })
    let s = try await SalienceSuggester(provider: provider).run(db, limit: limit, force: force)
    print("""
    Suggested \(s.suggested)/\(s.candidates) candidates: \(s.salient) salient / \(s.noise) noise \
    (\(s.quoteOnly) quote-only, \(s.skippedBatches) skipped on provider error).
    """)
  }

  /// A JSON `[{ "quote": String, "salient": Bool }]` → (quote, label) entries.
  static func decodeLabels(at path: String) throws -> [(quote: String, label: String)] {
    struct Entry: Decodable { let quote: String; let salient: Bool }
    let data = try Data(contentsOf: URL(fileURLWithPath: path))
    return try JSONDecoder().decode([Entry].self, from: data).map {
      (quote: $0.quote, label: $0.salient ? LooseEndLabel.salient : LooseEndLabel.noise)
    }
  }

  /// Runs `claude -p --model <model>` with the prompt on stdin; trimmed stdout. Mirrors the eval
  /// harness's helper (salience prompts are small, so writing stdin before draining can't deadlock).
  static func claudeRun(_ prompt: String, model: String) throws -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    p.arguments = ["claude", "-p", "--model", model]
    let stdin = Pipe(), stdout = Pipe()
    p.standardInput = stdin; p.standardOutput = stdout; p.standardError = FileHandle.nullDevice
    try p.run()
    try? stdin.fileHandleForWriting.write(contentsOf: Data(prompt.utf8))
    try? stdin.fileHandleForWriting.close()
    let out = stdout.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    guard p.terminationStatus == 0 else { throw LLMError.providerFailed("claude -p exit \(p.terminationStatus)") }
    return String(decoding: out, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
  }
}
```

- [ ] **Step 2: Register the subcommand**

In `Sources/pensieve/Pensieve.swift`, add `LabelSuggest.self` to the `subcommands:` array (e.g. after `Sync.self`):

```swift
      InstallDaemon.self, Sync.self, LabelSuggest.self,
```

- [ ] **Step 3: Build and check help**

Run: `swift build && swift run pensieve label-suggest --help`
Expected: builds; help lists `--import`, `--limit`, `--force`, `--model`.

- [ ] **Step 4: Smoke-test the import path against a throwaway store**

Run:
```bash
export PENSIEVE_DB=$(mktemp -u /tmp/pensieve-labelsuggest-XXXX.sqlite)
export PENSIEVE_CAPTURE_DB=$(mktemp -u /tmp/pensieve-cap-XXXX.sqlite)
echo '[{"quote":"nothing matches this","salient":true}]' > /tmp/ls-import.json
swift run pensieve label-suggest --import /tmp/ls-import.json
unset PENSIEVE_DB PENSIEVE_CAPTURE_DB
```
Expected: prints `Imported: 0 matched, 1 skipped (no matching quote).` (empty store → all skipped; no crash).

- [ ] **Step 5: Commit**

```bash
git add Sources/pensieve/Commands/LabelSuggest.swift Sources/pensieve/Pensieve.swift
git commit -F - <<'EOF'
feat(cli): pensieve label-suggest — Haiku bootstrap + label import

Suggest mode pre-labels the open backlog via claude -p Haiku through
SalienceSuggester (labelSuggestion only). --import folds a {quote,salient}
JSON into the human label via LooseEndCommands.importLabels.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
```

---

## Task 6: App — "Review Suggestions" surface

Add a sidebar entry + middle-column rendering of the cross-node audit queue, reusing `LooseEndRow` (whose ghost pre-fill + confirm already exist from Phase 1). Fix `MiddleLoadKey` so the review case reloads correctly.

**Files:**
- Modify: `Sources/PensieveApp/AppModel.swift` (`SidebarSelection`, `MiddleKind`, `middleKind()`, `refresh()`, new `reviewItems()` + `reviewCount`)
- Modify: `Sources/PensieveApp/SidebarView.swift`
- Modify: `Sources/PensieveApp/ContentListView.swift`
- Modify: `Sources/PensieveApp/Localizable.xcstrings`

**Interfaces:**
- Consumes: `SalienceReviewQueries.pending` / `.pendingCount` (Task 4); existing `LooseEndRow`, `model.provenance`, `model.setLooseEndLabel`, `model.node(_:)`.

- [ ] **Step 1: AppModel — selection/middle cases + review reads**

In `Sources/PensieveApp/AppModel.swift`:

Add a case to `SidebarSelection` (around line 42):
```swift
enum SidebarSelection: Hashable {
  case briefing
  case reviewSuggestions
  case smartList(SmartListKind)
  case node(UUID)
}
```

Add a case to `MiddleKind` (around line 50):
```swift
enum MiddleKind: Equatable {
  case nodes([Node])
  case looseEndsOf(UUID)
  case reviewSuggestions
}
```

Add a published count near the other `@Published` vars (around line 100):
```swift
  /// Count of open, unlabeled, machine-suggested loose ends — the "Review Suggestions" badge.
  @Published var reviewCount = 0
```

In `middleKind()` (around line 352), add the case:
```swift
    case .reviewSuggestions:
      return .reviewSuggestions
```

In `refresh()` (after the forest block, around line 342), refresh the badge:
```swift
    reviewCount = (try? SalienceReviewQueries.pendingCount(db)) ?? 0
```

Add the review-items read near `looseEnds(forNode:)` (around line 426):
```swift
  /// The cross-node audit queue for the Review Suggestions surface. Loaded off-`body` via `.task`.
  func reviewItems() -> [LooseEndView] {
    guard let db else { return [] }
    return (try? SalienceReviewQueries.pending(db, now: Date())) ?? []
  }
```

- [ ] **Step 2: SidebarView — the Review entry**

In `Sources/PensieveApp/SidebarView.swift`, after the `Briefing` label (line 20-21) add:
```swift
      Label {
        HStack {
          Text("Review Suggestions")
          Spacer()
          if model.reviewCount > 0 {
            Text("\(model.reviewCount)").foregroundStyle(.secondary).monospacedDigit()
          }
        }
      } icon: {
        Image(systemName: "checklist").foregroundStyle(.orange)
      }
      .tag(SidebarSelection.reviewSuggestions)
```

The existing selection `Binding.set` already routes any non-`.node` selection to `selectedNodeID = nil` (line 17-18), so `.reviewSuggestions` clears the detail correctly — no change needed there.

- [ ] **Step 3: ContentListView — render the review list + fix MiddleLoadKey**

In `Sources/PensieveApp/ContentListView.swift`:

Add review state next to `looseEnds` (line 8):
```swift
  @State private var reviewItems: [LooseEndView] = []
```

Extend the `switch kind` in `body` (line 12-19):
```swift
      switch kind {
      case .nodes(let items):
        nodeList(items)
      case .looseEndsOf:
        looseEndList()
      case .reviewSuggestions:
        reviewList()
      }
```

Extend the `.task` loader (line 24-30):
```swift
    .task(id: MiddleLoadKey(kind: kind, token: model.refreshToken)) {
      switch kind {
      case .looseEndsOf(let id): looseEnds = model.looseEnds(forNode: id)
      case .reviewSuggestions: reviewItems = model.reviewItems()
      case .nodes: looseEnds = []; reviewItems = []
      }
    }
```

Add the review list builder (after `looseEndList()`, line 61):
```swift
  @ViewBuilder private func reviewList() -> some View {
    List {
      ForEach(reviewItems, id: \.looseEnd.id) { view in
        VStack(alignment: .leading, spacing: 2) {
          if let name = model.node(view.looseEnd.nodeID)?.name {
            Text(name).font(.caption).foregroundStyle(.secondary)
          }
          LooseEndRow(view: view, loadProvenance: model.provenance, onLabel: model.setLooseEndLabel)
        }
      }
    }
    .overlay {
      if reviewItems.isEmpty {
        ContentUnavailableView("No suggestions to review", systemImage: "checklist")
      }
    }
  }
```

Extend `subtitle(for:)` (line 63-71):
```swift
    case .reviewSuggestions:
      return String(localized: "\(reviewItems.count) to review")
```

Replace `MiddleLoadKey` (line 76-86) so the review case is distinct from `.nodes` (both otherwise map to `nodeID = nil` and would collide, suppressing the `.task` reload on switch):
```swift
private struct MiddleLoadKey: Hashable {
  enum Tag: Hashable { case nodes, looseEnds(UUID), review }
  let tag: Tag
  let token: Int
  init(kind: MiddleKind, token: Int) {
    switch kind {
    case .looseEndsOf(let id): tag = .looseEnds(id)
    case .reviewSuggestions: tag = .review
    case .nodes: tag = .nodes
    }
    self.token = token
  }
}
```

- [ ] **Step 4: Localize the new chrome (en + de)**

Add these keys to `Sources/PensieveApp/Localizable.xcstrings` by hand (English base + German `de`). Match the existing entry shape in the catalog (a `localizations` map per key with `en`/`de` `stringUnit`s). German (impersonal/infinitive):

| key | en | de |
|---|---|---|
| `Review Suggestions` | Review Suggestions | Vorschläge prüfen |
| `%lld to review` | %lld to review | %lld zu prüfen |
| `No suggestions to review` | No suggestions to review | Keine Vorschläge zu prüfen |

After editing, confirm the JSON parses:
Run: `plutil -lint Sources/PensieveApp/Localizable.xcstrings`
Expected: `… OK`

- [ ] **Step 5: Build the app and smoke-launch**

Run:
```bash
xcodegen generate && xcodebuild -project Pensieve.xcodeproj -scheme Pensieve -configuration Debug -derivedDataPath ./.build-xcode build
```
Expected: `** BUILD SUCCEEDED **`

Then a non-blocking smoke-launch against throwaway stores:
```bash
BIN=./.build-xcode/Build/Products/Debug/Pensieve.app/Contents/MacOS/Pensieve
PENSIEVE_DB=$(mktemp -u /tmp/pensieve-app-XXXX.sqlite) \
PENSIEVE_CAPTURE_DB=$(mktemp -u /tmp/pensieve-appcap-XXXX.sqlite) \
"$BIN" & APP_PID=$!; sleep 4; kill $APP_PID 2>/dev/null
```
Expected: launches and is killed cleanly (no crash in the ~4s window).

- [ ] **Step 6: Verify the whole Kit suite is green**

Run: `./scripts/test.sh`
Expected: PASS — all prior tests plus the new suggester/review/import tests (≈ 296 + new).

- [ ] **Step 7: Commit**

```bash
git add Sources/PensieveApp/ Tests/
git commit -F - <<'EOF'
feat(app): Review Suggestions audit surface

A sidebar entry + middle-column list of the cross-node audit queue
(SalienceReviewQueries), reusing LooseEndRow (its ghost pre-fill + confirm
shipped in Phase 1). MiddleLoadKey gains a case tag so the review list
reloads on switch. German l10n for the new chrome.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
```

---

## Self-Review

**Spec coverage:**
- CLI `label-suggest` suggest mode (Haiku bootstrap, quote+context, quote-only fallback, labelSuggestion-only, never-force-overwrites-label) → Task 2 (`SalienceSuggester`) + Task 5 (CLI). ✅
- CLI `--import` (quote-match parked hand-labels → human `label`, skip non-matches) → Task 3 + Task 5. ✅
- Kit `SalienceSuggester` + `SalienceReviewQueries`, tested with a stub provider → Tasks 2, 4. ✅
- App Review Suggestions surface (dedicated, salient-first, node context, confirm via setLabel) → Task 6. ✅
- Inline ghost pre-fills → **already shipped in Phase 1** (`LooseEndRow.thumb`), no task needed (noted in spec/plan). ✅
- No migration, no pipeline/capture/trust-gate change, no auto-hiding → honored across all tasks. ✅
- Testing: `SalienceReviewQueries`, `SalienceSuggester` (stub), import — deterministic CI (Tasks 2-4); app via xcodebuild + smoke-launch (Task 6); manual Haiku run is dogfooding, not CI. ✅

**Placeholder scan:** No TBD/TODO. Two explicit "if the API differs, mirror X" notes (`.all`/`.fetchCount`) point at a concrete in-repo reference (`LooseEndCommands.corpus` / `LooseEndQueries`) rather than leaving a blank — acceptable guidance, not a placeholder.

**Type consistency:** `SalienceSuggester.Summary` fields (`candidates/suggested/salient/noise/quoteOnly/skippedBatches`) match between the interface block, the implementation, and the CLI print. `SalienceReviewQueries.pending`/`pendingCount` signatures match their callers (`reviewItems()`, `refresh()`). `importLabels` return `(matched, skipped)` matches the CLI print. `MiddleKind.reviewSuggestions` (no payload) is consistent across `AppModel.middleKind()`, `ContentListView` switch, and `MiddleLoadKey`. `SidebarSelection.reviewSuggestions` consistent across `SidebarView` tag and the binding.

## Execution Handoff

Plan complete. Recommended: **subagent-driven-development** in an isolated worktree (Sonnet implementers + task-reviewers per task; Opus whole-branch review; then finishing-a-development-branch → merge to main). Task order: 1 → 2 → (3, 4 independent) → 5 (needs 2+3) → 6 (needs 4).
