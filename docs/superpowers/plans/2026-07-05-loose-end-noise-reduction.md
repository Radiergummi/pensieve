# Loose-End Noise Reduction Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Raise loose-end precision on the live corpus by deterministically filtering pasted agent briefs, checklist/tool-output, closures/acks/status-checks, and truncation artifacts — without dropping any real loose end and without touching the verbatim trust gate.

**Architecture:** Two new pure, deterministic modules (`StructuralNoiseFilter` at message level, `CandidateFilter` at candidate level) slot into the existing extraction chain around the unchanged `IntentClassifier` and `LooseEndVerifier`. Truncation noise is fixed at its source (whitespace-boundary chunk splitting) rather than guessed downstream. A one-time retroactive re-extraction rebuilds the live open loose-end set.

**Tech Stack:** Swift 6, Swift Testing (`@Test`/`#expect`), SQLiteData/GRDB. Build with `swift build`; **run tests with `./scripts/test.sh` (NOT `swift test`)**, optionally `--filter <name>`.

## Global Constraints

- **The verbatim trust gate (`LooseEndVerifier`) is untouched.** No task modifies it.
- **The capture/ingest paths are untouched.** Filters live only in the extraction/intelligence layer.
- Swift only. No Python.
- Predicates use `.eq(x)`, not `== x`. Reuse `SourceKind`/`CaptureKind` constants.
- No shared mutable `static ISO8601DateFormatter`.
- New modules are `public enum` namespaces with `static` methods, matching `LooseEndVerifier`/`ProjectQueries`.
- Filters are **pure**: no DB, no LLM, no I/O. `[X] -> [X]`.
- Definition boundary: keep terse-but-substantive questions/directives; drop only pure filler + structural noise. Err toward recall on any doubt.
- Spec: `docs/superpowers/specs/2026-07-05-loose-end-noise-design.md`.

---

### Task 1: `StructuralNoiseFilter` (message-level, briefs only)

Drops long, template-structured agent briefs / review-packages from the user-prompt set before mining. Never touches short messages (so terse human directives that open like a brief survive — the Critical carve-out from adversarial review).

**Files:**
- Create: `Sources/PensieveKit/Intelligence/StructuralNoiseFilter.swift`
- Test: `Tests/PensieveKitTests/StructuralNoiseFilterTests.swift`

**Interfaces:**
- Consumes: `TranscriptMessage` (existing: has `.text: String`, `.isUserPrompt: Bool`, `.index: Int`).
- Produces: `StructuralNoiseFilter.strip(_ messages: [TranscriptMessage]) -> [TranscriptMessage]`.

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/PensieveKitTests/StructuralNoiseFilterTests.swift
import Foundation
import Testing
@testable import PensieveKit

private func msg(_ text: String) -> TranscriptMessage {
  TranscriptMessage(index: 0, role: "user", text: text, timestamp: nil, isUserPrompt: true)
}

/// An 800+ char generated SDD brief: opener + meta-instruction + "Task N" + headers.
private let brief = """
You are implementing Task 4 of the "Organization Foundation" plan. Read the spec first.

## Files
- Create: Sources/Foo/Bar.swift

## Steps
Do not deviate from the steps. Return ONLY the final diff.
Acceptance criteria: all tests pass.
""" + String(repeating: "Context line explaining the surrounding system in detail. ", count: 15)

@Test func stripsLongTemplateStructuredBrief() {
  #expect(brief.count >= 800)
  #expect(StructuralNoiseFilter.strip([msg(brief)]).isEmpty)
}

@Test func keepsShortDirectivesThatOpenLikeABrief() {
  // The Critical carve-out: imperative instruction to Claude IS genuine intent.
  let kept = [
    "You are absolutely right, let's fix the migration before the auth refactor.",
    "Your task is to wire up the webhook, forget the refactor.",
    "You are implementing #2 first, then stop.",
    "High-scrutiny review please — does the token exchange look right?",
  ].map(msg)
  #expect(StructuralNoiseFilter.strip(kept).count == kept.count)
}

@Test func keepsLongHumanProseWithoutTemplateStructure() {
  // Long but only ONE signal (no meta/Task/headers) → not a brief.
  let longProse = "You are reviewing " + String(repeating: "my reasoning about the caching layer and whether it is sound. ", count: 20)
  #expect(longProse.count >= 800)
  #expect(StructuralNoiseFilter.strip([msg(longProse)]).count == 1)
}

@Test func keepsRealAskWrappedAroundAChecklist() {
  // Checklists are handled at candidate level, NOT here (old M4 bug).
  let m = msg("Please also do these before merge:\n- [ ] fix the flaky auth test\n- [ ] bump the deploy tag\nand don't forget to update the changelog.")
  #expect(StructuralNoiseFilter.strip([m]).count == 1)
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `./scripts/test.sh --filter StructuralNoiseFilter`
Expected: FAIL — `cannot find 'StructuralNoiseFilter' in scope`.

- [ ] **Step 3: Write the implementation**

```swift
// Sources/PensieveKit/Intelligence/StructuralNoiseFilter.swift
import Foundation

/// Drops long, template-structured agent briefs / review-packages from the set of user
/// prompts BEFORE loose-end mining. Pure and deterministic. Deliberately never touches
/// SHORT messages: in a coding-agent session a terse imperative ("You are absolutely
/// right, fix X") IS the developer's genuine intent, so brief detection is gated on
/// length AND template structure — not on conversational openers. Checklists are handled
/// at the candidate level (see CandidateFilter), not here, so a real ask wrapped around a
/// checklist survives. See docs/superpowers/specs/2026-07-05-loose-end-noise-design.md.
public enum StructuralNoiseFilter {
  /// A message must be at least this long to even be considered a brief. No terse human
  /// directive reaches this; generated briefs are multi-paragraph.
  static let minBriefLength = 800

  public static func strip(_ messages: [TranscriptMessage]) -> [TranscriptMessage] {
    messages.filter { !isBrief($0.text) }
  }

  static func isBrief(_ text: String) -> Bool {
    text.count >= minBriefLength && templateSignals(in: text) >= 2
  }

  /// Distinct generated-brief signals present in `text` (max 4).
  static func templateSignals(in text: String) -> Int {
    var n = 0
    if hasOpener(text) { n += 1 }
    if hasMetaInstruction(text) { n += 1 }
    if text.range(of: #"Task \d+"#, options: .regularExpression) != nil { n += 1 }
    if sectionHeaderCount(text) >= 2 { n += 1 }
    return n
  }

  private static let openers = [
    "You are implementing", "You are reviewing", "You are RE-reviewing",
    "You are dispatched", "High-scrutiny",
  ]
  static func hasOpener(_ text: String) -> Bool {
    let head = text.trimmingCharacters(in: .whitespacesAndNewlines)
    return openers.contains { head.hasPrefix($0) }
  }

  private static let metaPhrases = [
    "Return ONLY", "Do not ", "Acceptance criteria", "Deliverable:",
    "Your job is", "task-brief", "review-package",
  ]
  static func hasMetaInstruction(_ text: String) -> Bool {
    metaPhrases.contains { text.contains($0) }
  }

  /// Markdown section headers: a line starting with 1-6 `#` + space, or a bold label
  /// line like `**Foo:**`.
  static func sectionHeaderCount(_ text: String) -> Int {
    text.split(separator: "\n").reduce(0) { acc, line in
      let l = line.trimmingCharacters(in: .whitespaces)
      let heading = l.range(of: #"^#{1,6}\s"#, options: .regularExpression) != nil
        || l.range(of: #"^\*\*.+:\*\*"#, options: .regularExpression) != nil
      return acc + (heading ? 1 : 0)
    }
  }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `./scripts/test.sh --filter StructuralNoiseFilter`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/PensieveKit/Intelligence/StructuralNoiseFilter.swift Tests/PensieveKitTests/StructuralNoiseFilterTests.swift
git commit -m "feat: StructuralNoiseFilter drops long template-structured briefs"
```

---

### Task 2: `CandidateFilter` (candidate-level)

Drops candidate loose ends whose quote is a pure closure/ack, a bare status-check, or a checklist/tool-output line. Keeps closure-*prefixed* directives, substantive questions, and legitimate mid-sentence quotes.

**Files:**
- Create: `Sources/PensieveKit/Intelligence/CandidateFilter.swift`
- Test: `Tests/PensieveKitTests/CandidateFilterTests.swift`

**Interfaces:**
- Consumes: `LooseEndCandidate` (existing: `.text`, `.quote`, `.messageIndex`).
- Produces: `CandidateFilter.strip(_ candidates: [LooseEndCandidate]) -> [LooseEndCandidate]`.

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/PensieveKitTests/CandidateFilterTests.swift
import Foundation
import Testing
@testable import PensieveKit

private func cand(_ quote: String) -> LooseEndCandidate {
  LooseEndCandidate(text: "paraphrase", quote: quote, messageIndex: 0)
}
private func quotesKept(_ quotes: [String]) -> [String] {
  CandidateFilter.strip(quotes.map(cand)).map(\.quote)
}

@Test func dropsPureClosuresAndStatusChecks() {
  let dropped = [
    "looks good, yes.", "all good, carry on", "sounds good, thanks",
    "are you done yet?", "is the research still running?", "what's the status?",
  ]
  #expect(quotesKept(dropped).isEmpty)
}

@Test func keepsClosurePrefixedDirectivesAndSubstantiveQuestions() {
  let kept = [
    "yes, let's fix 2 and 3 too",
    "approved, write up the spec",
    "can we fix this?",
    "still need to migrate the auth tables before launch",  // legit mid-sentence quote
    "are you done with the auth refactor and did you handle the migration?",  // substantive remainder
  ]
  #expect(Set(quotesKept(kept)) == Set(kept))
}

@Test func dropsChecklistAndToolOutputLinesButKeepsOpenTodos() {
  #expect(quotesKept(["✅ declare(strict_types=1); present"]).isEmpty)
  #expect(quotesKept(["❌ missing coverage on the error path"]).isEmpty)
  #expect(quotesKept(["@@ -1,4 +1,6 @@ func foo()"]).isEmpty)
  // An OPEN todo bullet is a REAL loose end — must be KEPT (not a completion marker).
  #expect(quotesKept(["- [ ] fix the flaky auth test"]) == ["- [ ] fix the flaky auth test"])
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `./scripts/test.sh --filter CandidateFilter`
Expected: FAIL — `cannot find 'CandidateFilter' in scope`.

- [ ] **Step 3: Write the implementation**

```swift
// Sources/PensieveKit/Intelligence/CandidateFilter.swift
import Foundation

/// Drops candidate loose ends whose quote is not actually a loose end: a pure
/// closure/acknowledgement, a bare status-check, or a pasted checklist / tool-output
/// line. Pure and deterministic; runs after extraction, before the verbatim gate.
///
/// Recall-first by construction: a closure that PREFIXES a substantive directive or
/// question is KEPT ("yes, let's fix 2 and 3 too"), and there is NO truncation heuristic
/// (a legitimate mid-sentence quote like "still need to migrate the auth tables" starts
/// lowercase and must survive — truncation is fixed at its source in LooseEndExtractor).
/// See docs/superpowers/specs/2026-07-05-loose-end-noise-design.md.
public enum CandidateFilter {
  public static func strip(_ candidates: [LooseEndCandidate]) -> [LooseEndCandidate] {
    candidates.filter { !isNoise($0.quote) }
  }

  static func isNoise(_ quote: String) -> Bool {
    if isChecklistOrToolOutput(quote) { return true }
    let q = quote.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if q.isEmpty { return true }
    if isPureStatusCheck(q) { return true }
    if isPureClosure(q) { return true }
    return false
  }

  /// Completion / tool-output markers only. Deliberately EXCLUDES `- [ ]` / `- [x]`
  /// todo bullets: an unchecked box is a real open todo the user wants surfaced.
  static func isChecklistOrToolOutput(_ quote: String) -> Bool {
    let head = quote.trimmingCharacters(in: .whitespacesAndNewlines)
    let markers = ["✅", "❌", "☑", "+++", "@@", "```"]
    return markers.contains { head.hasPrefix($0) }
  }

  private static let closureTokens: Set<String> = [
    "looks good", "sounds good", "all good", "carry on", "go ahead",
    "approved", "perfect", "great", "nice", "thanks", "thank you",
    "yes", "yeah", "yep", "ok", "okay", "done", "lgtm",
  ]

  /// True iff EVERY clause (split on , ; . — ! ?) is itself a closure token. Any
  /// substantive clause → keep.
  static func isPureClosure(_ normalized: String) -> Bool {
    let clauses = normalized
      .split(whereSeparator: { ",;.—!?".contains($0) })
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { !$0.isEmpty }
    guard !clauses.isEmpty else { return false }
    return clauses.allSatisfy { closureTokens.contains($0) }
  }

  /// Whole-quote match against bare progress queries — never a prefix match (a status
  /// phrase followed by substantive content, e.g. "are you done with the auth refactor",
  /// must be KEPT).
  static func isPureStatusCheck(_ normalized: String) -> Bool {
    let core = normalized.trimmingCharacters(in: CharacterSet(charactersIn: " .!?"))
    let patterns = [
      #"^are you done( yet)?$"#,
      #"^is it done( yet)?$"#,
      #"^did you finish( yet)?$"#,
      #"^are we ready( to \w+)?$"#,
      #"^what'?s the status$"#,
      #"^is .{1,40} still (running|going|open)$"#,
    ]
    return patterns.contains { core.range(of: $0, options: .regularExpression) != nil }
  }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `./scripts/test.sh --filter CandidateFilter`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/PensieveKit/Intelligence/CandidateFilter.swift Tests/PensieveKitTests/CandidateFilterTests.swift
git commit -m "feat: CandidateFilter drops closures/status/tool-output, keeps directives"
```

---

### Task 3: Whitespace-boundary chunk splitting (fix truncation at source)

`splitIntoFragments`/`splitChunk` cut oversized messages on raw character boundaries, mid-word, producing verbatim-but-truncated quotes (`"om. #479 untouched."`). Break on the nearest whitespace instead.

**Files:**
- Modify: `Sources/PensieveKit/Intelligence/LooseEndExtractor.swift` (`splitIntoFragments`, `splitChunk`)
- Test: `Tests/PensieveKitTests/LooseEndExtractorTests.swift` (append)

**Interfaces:**
- Consumes/Produces: unchanged signatures — `static func chunkFragments(_ prompts: [TranscriptMessage], budget: Int) -> [[PromptFragment]]`, `static func splitChunk(_ fragments: [PromptFragment]) -> [[PromptFragment]]`. Invariant preserved: every fragment's `text.count <= budget`.

- [ ] **Step 1: Write the failing test (append to LooseEndExtractorTests.swift)**

```swift
@Test func chunkingBreaksOnWhitespaceNotMidWord() {
  let text = "alpha bravo charlie delta echo foxtrot golf hotel"
  let words = Set(text.split(separator: " ").map(String.init))
  let msg = TranscriptMessage(index: 0, role: "user", text: text, timestamp: nil, isUserPrompt: true)
  let chunks = LooseEndExtractor.chunkFragments([msg], budget: 12)
  // Reconstruction is exact and no fragment contains a partial (mid-cut) word.
  let joined = chunks.flatMap { $0 }.map(\.text).joined()
  #expect(joined == text)
  for chunk in chunks {
    for f in chunk {
      for w in f.text.split(separator: " ") { #expect(words.contains(String(w))) }
      #expect(f.text.count <= 12)   // budget invariant preserved
    }
  }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `./scripts/test.sh --filter chunkingBreaksOnWhitespace`
Expected: FAIL — a fragment contains a partial word (e.g. `"charl"`), so `words.contains` fails.

- [ ] **Step 3: Modify `splitIntoFragments`**

Replace the body of `splitIntoFragments` with:

```swift
  private static func splitIntoFragments(index: Int, text: String, budget: Int) -> [PromptFragment] {
    guard budget > 0, text.count > budget else { return [PromptFragment(index: index, text: text)] }
    var fragments: [PromptFragment] = []
    var start = text.startIndex
    while start < text.endIndex {
      var end = text.index(start, offsetBy: budget, limitedBy: text.endIndex) ?? text.endIndex
      // Back up to the last whitespace in the window so we never cut mid-word (which
      // yields verbatim-but-truncated quotes). If the window is one giant token with no
      // whitespace, keep the hard cut — it can't be avoided.
      if end < text.endIndex, let ws = text[start..<end].lastIndex(where: { $0.isWhitespace }) {
        end = text.index(after: ws)
      }
      fragments.append(PromptFragment(index: index, text: String(text[start..<end])))
      start = end
    }
    return fragments
  }
```

- [ ] **Step 4: Modify `splitChunk`'s single-fragment branch**

In `splitChunk`, replace the single-oversized-fragment split (the `guard let only …` block) with:

```swift
    guard let only = fragments.first, only.text.count > 1 else { return [fragments] }
    var mid = only.text.index(only.text.startIndex, offsetBy: only.text.count / 2)
    // Back up to whitespace so the split point isn't mid-word.
    if let ws = only.text[..<mid].lastIndex(where: { $0.isWhitespace }) {
      mid = only.text.index(after: ws)
    }
    return [[PromptFragment(index: only.index, text: String(only.text[..<mid]))],
            [PromptFragment(index: only.index, text: String(only.text[mid...]))]]
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `./scripts/test.sh --filter LooseEndExtractor`
Expected: PASS (all existing extractor tests + the new one).

- [ ] **Step 6: Commit**

```bash
git add Sources/PensieveKit/Intelligence/LooseEndExtractor.swift Tests/PensieveKitTests/LooseEndExtractorTests.swift
git commit -m "fix: chunk splitting breaks on whitespace, not mid-word (kills truncation noise)"
```

---

### Task 4: Wire filters into the pipeline + extractor prompt nudge

Integrate `StructuralNoiseFilter` into `LooseEndExtractor.extract`, `CandidateFilter` into `ExtractionRunner.run`, and add the prompt sentence to `buildPrompt`.

**Files:**
- Modify: `Sources/PensieveKit/Intelligence/LooseEndExtractor.swift` (`extract`, `buildPrompt`)
- Modify: `Sources/PensieveKit/Intelligence/ExtractionRunner.swift` (line ~79)
- Test: `Tests/PensieveKitTests/LooseEndExtractorTests.swift` and `Tests/PensieveKitTests/ExtractionRunnerTests.swift` (append)

**Interfaces:**
- Consumes: `StructuralNoiseFilter.strip`, `CandidateFilter.strip` (Tasks 1–2).
- Produces: no signature changes; behavior change only.

- [ ] **Step 1: Write the failing integration tests**

Append to `LooseEndExtractorTests.swift` (the brief message must never reach the model):

```swift
@Test func extractDropsBriefMessagesBeforeMining() async throws {
  let brief = "You are implementing Task 4 of the plan. Return ONLY the diff. Do not deviate.\n## Files\n## Steps\n"
    + String(repeating: "Detailed surrounding context for the task at hand. ", count: 20)
  #expect(brief.count >= 800)
  let messages = [
    TranscriptMessage(index: 0, role: "user", text: brief, timestamp: nil, isUserPrompt: true),
    TranscriptMessage(index: 1, role: "user", text: "we still need to add rate limiting", timestamp: nil, isUserPrompt: true),
  ]
  let stub = StubProvider { prompt in
    #expect(!prompt.contains("You are implementing Task 4"))   // brief stripped before classify AND extract
    return #"[{"text":"add rate limiting","quote":"we still need to add rate limiting","messageIndex":1}]"#
  }
  let out = try await LooseEndExtractor(provider: stub).extract(from: messages)
  #expect(out.map(\.quote) == ["we still need to add rate limiting"])
}
```

Append to `ExtractionRunnerTests.swift` (a closure candidate is filtered before verify/insert):

```swift
@Test func runnerFiltersClosureCandidatesBeforeInsert() async throws {
  let db = try openCanonicalDatabase(at: tempURL("cf"))
  let transcript = try writeTranscript([
    "we still need to migrate the auth tables before launch",   // index 0 — real
    "looks good, yes.",                                          // index 1 — closure noise
  ])
  let event = try makeSessionEvent(db: db, transcript: transcript)
  let provider = SliceAwareProvider(genuine: [
    (quote: "we still need to migrate the auth tables before launch", index: 0),
    (quote: "looks good, yes.", index: 1),
  ])
  _ = try await ExtractionRunner(db: db, provider: provider).run()
  let quotes = try db.read { db in try LooseEnd.order { $0.sourceMessageIndex }.fetchAll(db).map(\.quote) }
  #expect(quotes == ["we still need to migrate the auth tables before launch"])  // closure dropped
  _ = event
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `./scripts/test.sh --filter "extractDropsBriefMessages|runnerFiltersClosure"`
Expected: FAIL — brief text still in prompt / closure still inserted.

- [ ] **Step 3: Wire `StructuralNoiseFilter` into `extract`**

In `LooseEndExtractor.extract`, change the first line from:

```swift
    let prompts = messages.filter { $0.isUserPrompt }
```
to:
```swift
    let prompts = StructuralNoiseFilter.strip(messages.filter { $0.isUserPrompt })
```

- [ ] **Step 4: Add the prompt nudge in `buildPrompt`**

In `LooseEndExtractor.buildPrompt`, change the first paragraph from:

```swift
    You extract LOOSE ENDS from a developer's own messages: things they said they would \
    do, planned, or left unfinished, but which may not be done. Only use the text below.
```
to:
```swift
    You extract LOOSE ENDS from a developer's own messages: things they said they would \
    do, planned, or left unfinished, but which may not be done. Only use the text below. \
    Do not extract acknowledgements, approvals, status checks, checklist items, or agent \
    task briefs (e.g. 'looks good', 'carry on', 'are you done') — those are not loose ends.
```

- [ ] **Step 5: Wire `CandidateFilter` into `ExtractionRunner.run`**

In `ExtractionRunner.run`, change (around line 79):

```swift
        let candidates = try await LooseEndExtractor(provider: provider).extract(from: slice)
```
to:
```swift
        let candidates = CandidateFilter.strip(
          try await LooseEndExtractor(provider: provider).extract(from: slice))
```

- [ ] **Step 6: Run the full suite**

Run: `./scripts/test.sh`
Expected: PASS (all tests, including the two new integration tests).

- [ ] **Step 7: Commit**

```bash
git add Sources/PensieveKit/Intelligence/LooseEndExtractor.swift Sources/PensieveKit/Intelligence/ExtractionRunner.swift Tests/PensieveKitTests/LooseEndExtractorTests.swift Tests/PensieveKitTests/ExtractionRunnerTests.swift
git commit -m "feat: wire StructuralNoiseFilter + CandidateFilter into extraction pipeline"
```

---

### Task 5: Adversarial recall fixture (real loose ends that resemble noise)

A frozen regression test of hand-authored cases that MUST survive the filters — the guard the precision fixture structurally cannot provide (adversarial review, Major 3).

**Files:**
- Create: `Tests/PensieveKitTests/NoiseFilterRecallFixtureTests.swift`

**Interfaces:**
- Consumes: `StructuralNoiseFilter.strip`, `CandidateFilter.strip`.

- [ ] **Step 1: Write the fixture test (it should pass immediately if Tasks 1–2 are correct; it exists to lock recall)**

```swift
// Tests/PensieveKitTests/NoiseFilterRecallFixtureTests.swift
import Foundation
import Testing
@testable import PensieveKit

/// Real loose ends that LOOK like noise. Every one MUST survive both filters. This is the
/// recall half of the guard — hand-authored raw cases, NOT sampled pipeline survivors, so
/// it certifies recall on the exact inputs the new drops are most likely to over-kill.

/// Whole messages a developer plausibly types that must NOT be dropped as "briefs".
private let recallMessages: [String] = [
  "You are absolutely right, let's fix the migration before the auth refactor.",
  "Your task is to wire up the webhook, forget the refactor.",
  "You are implementing #2 first, then stop.",
  "High-scrutiny review please — does the token exchange look right?",
  "Please also do these before merge:\n- [ ] fix the flaky auth test\n- [ ] bump the deploy tag\nand don't forget to update the changelog.",
]

/// Candidate quotes that must NOT be dropped by CandidateFilter.
private let recallQuotes: [String] = [
  "yes, let's fix 2 and 3 too",
  "approved, write up the spec",
  "can we fix this?",
  "still need to migrate the auth tables before launch",
  "are you done with the auth refactor and did you handle the migration?",
  "- [ ] fix the flaky auth test",
]

@Test func structuralFilterKeepsEveryAdversarialRecallMessage() {
  let msgs = recallMessages.map { TranscriptMessage(index: 0, role: "user", text: $0, timestamp: nil, isUserPrompt: true) }
  #expect(StructuralNoiseFilter.strip(msgs).count == msgs.count)
}

@Test func candidateFilterKeepsEveryAdversarialRecallQuote() {
  let cands = recallQuotes.map { LooseEndCandidate(text: "p", quote: $0, messageIndex: 0) }
  #expect(CandidateFilter.strip(cands).map(\.quote) == recallQuotes)
}
```

- [ ] **Step 2: Run the fixture**

Run: `./scripts/test.sh --filter "AdversarialRecall"`
Expected: PASS (2 tests). If any case fails, the filter over-kills — fix the filter (Task 1/2), not the fixture.

- [ ] **Step 3: Commit**

```bash
git add Tests/PensieveKitTests/NoiseFilterRecallFixtureTests.swift
git commit -m "test: adversarial recall fixture locks real-loose-ends-that-look-like-noise"
```

---

### Task 6: Precision fixture from the live corpus — **MAIN AGENT ONLY**

> **Not a subagent task.** Requires read access to the live store and human-in-the-loop labeling judgment. The main agent (with the user) samples and labels.

**Files:**
- Create: `Tests/PensieveKitTests/Fixtures/loose-end-precision-sample.json` (labeled sample)
- Create: `Tests/PensieveKitTests/NoiseFilterPrecisionFixtureTests.swift`

- [ ] **Step 1: Sample ~80–100 live open loose ends, weighted to the noisy nodes**

Read-only from the live store:
```bash
DB="$HOME/Library/Application Support/Pensieve/pensieve.sqlite"
sqlite3 "file:$DB?mode=ro" "SELECT quote FROM looseEnds WHERE status='open';" > /tmp/loose-ends-sample.txt
```
Pull the full set (or a weighted sample if large), present quotes to the user, and label each `looseEnd` (real) or `noise`. Write the labeled result as JSON:
```json
[{"quote": "looks good, yes.", "label": "noise"},
 {"quote": "we still need to migrate the auth tables", "label": "looseEnd"}]
```
Save to `Tests/PensieveKitTests/Fixtures/loose-end-precision-sample.json`.

- [ ] **Step 2: Write the precision regression test**

```swift
// Tests/PensieveKitTests/NoiseFilterPrecisionFixtureTests.swift
import Foundation
import Testing
@testable import PensieveKit

private struct LabeledQuote: Codable { let quote: String; let label: String }

private func loadFixture() throws -> [LabeledQuote] {
  let url = Bundle.module.url(forResource: "loose-end-precision-sample", withExtension: "json",
                             subdirectory: "Fixtures")!
  return try JSONDecoder().decode([LabeledQuote].self, from: Data(contentsOf: url))
}

@Test func precisionRisesAndNoRealLooseEndDropped() throws {
  let fixture = try loadFixture()
  // Model CandidateFilter's decision on each quote (message-level briefs are tested separately).
  func dropped(_ q: String) -> Bool { CandidateFilter.strip([LooseEndCandidate(text: "p", quote: q, messageIndex: 0)]).isEmpty }

  let reals = fixture.filter { $0.label == "looseEnd" }
  let noise = fixture.filter { $0.label == "noise" }

  // HARD recall guard: zero real loose ends dropped.
  for r in reals { #expect(!dropped(r.quote), "dropped a REAL loose end: \(r.quote)") }

  // Precision: a material fraction of labeled noise is removed.
  let noiseDropped = noise.filter { dropped($0.quote) }.count
  #expect(noiseDropped >= noise.count / 2, "expected to drop >=50% of labeled noise, dropped \(noiseDropped)/\(noise.count)")
}
```

> **Note on `Bundle.module`:** `Package.swift`'s test target already has `resources: [.copy("Fixtures")]`, and existing tests (e.g. `TranscriptParserTests`) already load fixtures via `Bundle.module.url(forResource:…subdirectory:"Fixtures")`. Just drop the new JSON into `Tests/PensieveKitTests/Fixtures/` — no `Package.swift` change needed.

- [ ] **Step 3: Run, iterate the filter vocab if needed, commit**

Run: `./scripts/test.sh --filter precisionRises`
Expected: PASS. If a real loose end is dropped, fix the filter (Tasks 1/2) and its unit tests — never relax the recall assertion. If precision is under 50%, note residual classes; do not over-tighten past the recall guard.
```bash
git add Tests/PensieveKitTests/Fixtures/loose-end-precision-sample.json Tests/PensieveKitTests/NoiseFilterPrecisionFixtureTests.swift
git commit -m "test: precision fixture from live corpus (recall-guarded)"
```

---

### Task 7: On-device acceptance run + retroactive live-store cleanup — **MAIN AGENT ONLY**

> **Not a subagent task.** Runs Foundation Models on this machine and mutates the LIVE store. Do this only after Tasks 1–6 are merged and the release binary is rebuilt.

- [ ] **Step 1: Rebuild + reinstall the release binary (daemon runs this path)**

```bash
swift build -c release
cp .build/release/pensieve "$HOME/.local/bin/pensieve"
```

- [ ] **Step 2: On-device acceptance run (throwaway store, real Foundation Models)**

Point the env overrides at a throwaway store, ingest a couple of the noisy real transcripts, and eyeball the output for 0-noise / 0-fabrication and that real loose ends survive. (Use `PENSIEVE_DB`/`PENSIEVE_CAPTURE_DB` temp paths — NEVER on the live store for the acceptance run.) Confirm briefs, closures, checklists, and truncation artifacts are gone and real loose ends remain.

- [ ] **Step 3: Retroactive cleanup of the LIVE store (backup first; per spec §Retroactive)**

```bash
DB="$HOME/Library/Application Support/Pensieve/pensieve.sqlite"
cp "$DB" "$DB.bak-noise-$(date +%Y%m%d%H%M%S)"                 # 1. backup
launchctl unload ~/Library/LaunchAgents/com.pensieve.sync.plist  # 2. quiesce daemon
```
3. **Pre-flight existence check** — for every open loose end, confirm its backing transcript still exists; ABORT if any is missing:
```bash
sqlite3 "file:$DB?mode=ro" "
  SELECT DISTINCT json_extract(e.detailJSON,'\$.transcriptPath')
  FROM looseEnds l JOIN events e ON e.id=l.sourceEventID WHERE l.status='open';" |
while IFS= read -r p; do [ -r "$p" ] || echo "MISSING: $p"; done
```
Proceed only if this prints nothing. Then:
```bash
sqlite3 "$DB" "DELETE FROM looseEnds WHERE status='open';"     # 4. delete open (keep resolved)
sqlite3 "$DB" "UPDATE events SET extractedMessageCount=0, extractedTranscriptSize=0 WHERE kind='cc.session';"  # 5. reset watermarks (0, not -1)
"$HOME/.local/bin/pensieve" sync                                # 6. re-mine clean
launchctl load ~/Library/LaunchAgents/com.pensieve.sync.plist   # 7. reload daemon
```

- [ ] **Step 4: Verify before/after**

```bash
sqlite3 "$DB" "SELECT count(*) FROM looseEnds WHERE status='open';"
"$HOME/.local/bin/pensieve" looseends | head -40
```
Confirm the count dropped materially and the surviving quotes read as real loose ends. Report before/after counts to the user. If anything looks wrong, restore from `$DB.bak-noise-*`.

---

## Self-Review

**Spec coverage:** ① StructuralNoiseFilter → Task 1; ② CandidateFilter → Task 2; ③ source-level truncation fix → Task 3; pipeline wiring + prompt nudge → Task 4; adversarial recall fixture → Task 5; precision fixture → Task 6; on-device acceptance + retroactive cleanup (backup, daemon-unload, pre-flight existence check, watermark reset) → Task 7. All spec sections covered.

**Deviation from spec (intentional, noted):** the spec's ② listed `- [ ]`/`- [x]` among checklist markers; the plan drops only completion/tool-output markers (`✅ ❌ ☑`, diff/fence) and KEEPS `- [ ]` todo bullets, because an unchecked box is a real open loose end. Task 2 + Task 5 encode this.

**Type consistency:** `StructuralNoiseFilter.strip([TranscriptMessage]) -> [TranscriptMessage]` and `CandidateFilter.strip([LooseEndCandidate]) -> [LooseEndCandidate]` used identically in Tasks 1/2 (definition), Task 4 (wiring), Task 5/6 (fixtures). `LooseEndCandidate(text:quote:messageIndex:)` and `TranscriptMessage(index:role:text:timestamp:isUserPrompt:)` match existing initializers.
