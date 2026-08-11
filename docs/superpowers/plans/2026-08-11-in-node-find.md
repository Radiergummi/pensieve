# In-Node Find (⌘F) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give the detail pane its own find bar on ⌘F — literal substring search over everything that pane can render for the open node, including transcript windows behind collapsed loose ends, highlighted in place — and move the existing search-everything field to ⌥⌘F.

**Architecture:** Match order is *data*, not view structure: a tested PensieveKit kernel (`FindMatcher` → `NodeFindDocument` → `FindSession`) owns matching, document order and navigation; the app layer is a thin `@Observable` wrapper plus a find bar and highlight renderer. Transcript content reaches the document through a batch `ProvenanceLoader` that parses each transcript once and shares its parsed segments with the views, so document segment ordinals and rendered segment ordinals are identical by construction.

**Tech Stack:** Swift 6, SwiftUI (macOS 15 target), Swift Testing (`swift test`), SQLiteData/GRDB, MarkdownUI 2.4.1 (xcodebuild-only dependency), XcodeGen.

**Spec:** `docs/superpowers/specs/2026-08-11-in-node-find-design.md` — read it first. It records four Critical findings from two adversarial reviews and *why* each mechanism here is shaped the way it is. Deviating from the spec's mechanisms will reintroduce the defects it documents.

## Global Constraints

- **Names are explicit — no abbreviations, no single letters.** Write `database`/`node`/`looseEnd`/`event`, not `db`/`n`/`le`/`ev`. SwiftLint `identifier_name` is enforced in CI (`swiftlint lint --strict`); do not relax it.
- **SwiftLint runs strict in CI.** `.swiftlint.yml` at repo root is the authority; do not silence findings that should be fixed in code.
- **SQLiteData 1.6.6 predicates use `.eq(x)`, NOT `== x`.** `==` is `unavailable` and will not compile.
- **Kit tests only.** `Sources/PensieveApp/` has no unit tests; app tasks verify by `xcodebuild` build + non-blocking smoke-launch of the inner binary + eyeball. Keep derivation in Kit, views thin.
- **Run tests with `./scripts/test.sh`** (optionally `--filter <name>`). Build the app with `xcodegen generate` then `xcodebuild -project Pensieve.xcodeproj -scheme Pensieve -configuration Debug -derivedDataPath ./.build-xcode build`.
- **Smoke-launch the inner binary**, never the bundle: `./.build-xcode/Build/Products/Debug/Pensieve.app/Contents/MacOS/Pensieve`, backgrounded then killed, with throwaway `PENSIEVE_DB`/`PENSIEVE_CAPTURE_DB` env vars. A bundle launch would touch the real store and real Login Items.
- **Discard transient `Package.resolved` churn after an `xcodebuild`** — MarkdownUI is an xcodebuild-only dependency and `swift test` must stay unaffected.
- **Chrome is localized; content never is.** Find-bar labels, menu items and counts → `Localizable.xcstrings` (en + de). Node names, descriptions, loose-end text, quotes, transcript text, harness tag names, event summaries → verbatim, untouched.
- **`xcodebuild` does not populate the String Catalog** (IDE-only). Author keys by hand against the Swift literals; a mis-keyed `de` value falls back to English silently.
- **The trust gate is untouched.** Do not read, write, or reference `TranscriptVocabulary.injectionMarkers` or `TranscriptParser.isInjectedOrCommand` in any file this plan touches. `isUserPrompt` is read only *transitively*, through the existing two-part guard in `ProvenanceQueries` — never re-implemented.
- **Commit after every task.** Conventional-commit prefixes as used in this repo (`feat(kit)`, `fix(app)`, `refactor(search)`, `docs`).
- **Never `try?`-swallow a new failure path in app writes.** This feature is read-only; if you find yourself adding a write, stop and re-read the spec.

## File Structure

**Create (Kit):**
- `Sources/PensieveKit/Support/FindMatcher.swift` — `FindRun`, `FindMatcher` (shared compare options, all-ranges, runs).
- `Sources/PensieveKit/Query/NodeFindDocument.swift` — `FindAnchor`, `FindUnit`, `FindMatch`, `FindMatchIdentity`, `NodeFindDocument` (ordered slots, in-place provenance fill).
- `Sources/PensieveKit/Query/FindSession.swift` — pure navigation state machine (query, matches, current identity, next/previous, re-anchor).
- `Sources/PensieveKit/Query/ProvenanceLoader.swift` — `actor`; batch load, `(size, mtime)`-validated cache, LRU bound.

**Create (App):**
- `Sources/PensieveApp/NodeFindState.swift` — `@Observable` wrapper over `FindSession` + sweep + pending scroll + forced expansions.
- `Sources/PensieveApp/FindBar.swift` — the bar chrome.
- `Sources/PensieveApp/FindCommands.swift` — `Commands` struct (property wrappers cannot live in an inline `.commands` block).
- `Sources/PensieveApp/HighlightedText.swift` — the single highlight renderer.

**Modify (Kit):**
- `Sources/PensieveKit/Query/Snippet.swift` — `SnippetMaker` re-expressed over `FindMatcher`; its own options constant retired.
- `Sources/PensieveKit/Transcript/TranscriptSegment.swift` — gains `HarnessKind.displayBody` (moved from the app) and `TranscriptSegment.findableText`.
- `Sources/PensieveKit/Query/ProvenanceQueries.swift` — gains the session-taking overload; existing entry point becomes a wrapper.

**Modify (App):**
- `Sources/PensieveApp/PensieveApp.swift:37-56` — `FindCommands` added; `Go ▸ Find` becomes `Go ▸ Search Everything` on ⌥⌘F.
- `Sources/PensieveApp/DetailView.swift` — owns `NodeFindState`, mounts `FindBar`, publishes the focused scene value, carries `.id(FindAnchor)` on findable sites, drives the mount-driven scroll.
- `Sources/PensieveApp/LooseEndRow.swift` — reads context+segments from the loader; threads highlights and find-driven expansion.
- `Sources/PensieveApp/TranscriptMessageView.swift` / `TranscriptSegmentView.swift` — accept per-segment highlights; `displayBody` extension removed (moved to Kit).
- `Sources/PensieveApp/ContentListView.swift:189-197` — `SnippetText` re-expressed over `HighlightedText`.
- `Sources/PensieveApp/AppModel+Recall.swift:49-55` — `provenance(for:)` routes through `ProvenanceLoader`.
- `Sources/PensieveApp/Localizable.xcstrings`, `README.md:101`, `CLAUDE.md`.

**Test:** `Tests/PensieveKitTests/{FindMatcherTests,NodeFindDocumentTests,FindSessionTests,FindableTextTests,ProvenanceSessionOverloadTests,ProvenanceLoaderTests}.swift`

---

## Phase 1 — The matching kernel (Kit, no UI)

### Task 1: `FindMatcher` + one shared compare-options definition

**Files:**
- Create: `Sources/PensieveKit/Support/FindMatcher.swift`
- Modify: `Sources/PensieveKit/Query/Snippet.swift:26-38` (`make(from:matching:window:)`)
- Test: `Tests/PensieveKitTests/FindMatcherTests.swift`

**Interfaces:**
- Produces: `FindRun` (`.plain(String)` / `.match(String)`), `FindMatcher.options: String.CompareOptions`, `FindMatcher.ranges(in:query:) -> [Range<String.Index>]`, `FindMatcher.runs(in:ranges:) -> [FindRun]`.
- Consumes: nothing.

**Why:** `Snippet.swift:47-50` already documents a shipped bug where two code paths disagreed on their compare options. There must be exactly one definition of `[.caseInsensitive, .diacriticInsensitive]` in the codebase after this task.

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/PensieveKitTests/FindMatcherTests.swift
import Foundation
import Testing
@testable import PensieveKit

@Test func findsEveryOccurrenceLeftToRight() {
  let source = "sync the sync gap and sync again"
  let ranges = FindMatcher.ranges(in: source, query: "sync")
  #expect(ranges.count == 3)
  #expect(source[ranges[0]] == "sync")
  #expect(ranges[0].lowerBound < ranges[1].lowerBound)
  #expect(ranges[1].lowerBound < ranges[2].lowerBound)
}

@Test func matchingIsCaseAndDiacriticInsensitive() {
  // Agrees with the FTS5 remove_diacritics 2 tokenizer: typing `losung` must find `Lösung`.
  let ranges = FindMatcher.ranges(in: "Die Lösung war einfach", query: "losung")
  #expect(ranges.count == 1)
  #expect("Die Lösung war einfach"[ranges[0]] == "Lösung")
}

@Test func emptyQueryOrEmptySourceYieldsNoRanges() {
  #expect(FindMatcher.ranges(in: "anything", query: "").isEmpty)
  #expect(FindMatcher.ranges(in: "", query: "anything").isEmpty)
}

@Test func adjacentOccurrencesAreBothFound() {
  let ranges = FindMatcher.ranges(in: "abab", query: "ab")
  #expect(ranges.count == 2)
}

@Test func overlappingCandidatesDoNotDoubleCount() {
  // "aaa" contains "aa" at offsets 0 and 1; non-overlapping left-to-right yields exactly one.
  let ranges = FindMatcher.ranges(in: "aaa", query: "aa")
  #expect(ranges.count == 1)
}

@Test func runsRoundTripToTheSource() {
  let source = "fix the sync gap before the sync ships"
  let runs = FindMatcher.runs(in: source, ranges: FindMatcher.ranges(in: source, query: "sync"))
  let rebuilt = runs.map { run in
    switch run { case .plain(let text), .match(let text): return text }
  }.joined()
  #expect(rebuilt == source)
  #expect(runs.filter { if case .match = $0 { return true } else { return false } }.count == 2)
}

@Test func runsWithNoRangesIsASinglePlainRun() {
  let runs = FindMatcher.runs(in: "nothing here", ranges: [])
  #expect(runs == [.plain("nothing here")])
}

@Test func snippetMakerStillProducesTheSameHighlightAfterUnification() {
  // Regression pin on the SHIPPED search-results highlight — Snippet is the N=1 case of FindMatcher.
  let snippet = SnippetMaker.make(from: "the quick brown fox", matching: "quick")
  #expect(snippet.leading == "the ")
  #expect(snippet.match == "quick")
  #expect(snippet.trailing == " brown fox")
  #expect(snippet.leading + snippet.match + snippet.trailing == "the quick brown fox")
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `./scripts/test.sh --filter FindMatcher`
Expected: FAIL — `cannot find 'FindMatcher' in scope`.

- [ ] **Step 3: Write `FindMatcher`**

```swift
// Sources/PensieveKit/Support/FindMatcher.swift
import Foundation

/// One rendering run of a searched string: either untouched text or a matched span. Generalizes
/// `Snippet`'s three-run trick from one match to N, so a view renders `Text` concatenations with
/// ZERO index conversion — the same reason `Snippet` exists.
public enum FindRun: Equatable, Sendable {
  case plain(String)
  case match(String)

  /// The run's text, whichever case it is.
  public var text: String {
    switch self {
    case .plain(let text), .match(let text): return text
    }
  }
}

/// Literal substring matching for in-node find — Safari semantics: no regex, no whole-word, no
/// stemming.
public enum FindMatcher {
  /// **The single definition of how Pensieve compares a query to captured text.** `SnippetMaker`
  /// reads this rather than declaring its own copy: `Snippet.swift` already carries a scar comment
  /// about two paths disagreeing on these options, and a fourth copy would invite the same bug.
  ///
  /// Diacritic folding matches the retrieval engine — the FTS5 index is built with
  /// `remove_diacritics 2`, so typing `losung` genuinely retrieves `Lösung`; comparing case-only
  /// here would hand back a real hit that the view then renders with nothing highlighted.
  public static let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]

  /// Every occurrence of `query` in `source`, left to right, non-overlapping. Unicode-safe: all
  /// bounds are `String.Index`. Note a matched range may differ in length from `query` — diacritic
  /// folding compares `Lösung` equal to `losung`.
  public static func ranges(in source: String, query: String) -> [Range<String.Index>] {
    guard !query.isEmpty, !source.isEmpty else { return [] }
    var found: [Range<String.Index>] = []
    var searchStart = source.startIndex
    while searchStart < source.endIndex,
          let range = source.range(of: query, options: options,
                                   range: searchStart..<source.endIndex) {
      found.append(range)
      // A zero-width match would spin forever; advance one character in that (defensive) case.
      searchStart = range.upperBound > range.lowerBound
        ? range.upperBound
        : source.index(after: range.lowerBound)
    }
    return found
  }

  /// Splits `source` into alternating plain/match runs. Invariant: joining every run's text
  /// reproduces `source` exactly — the property the round-trip test pins.
  public static func runs(in source: String, ranges: [Range<String.Index>]) -> [FindRun] {
    guard !ranges.isEmpty else { return source.isEmpty ? [] : [.plain(source)] }
    var runs: [FindRun] = []
    var cursor = source.startIndex
    for range in ranges {
      if cursor < range.lowerBound {
        runs.append(.plain(String(source[cursor..<range.lowerBound])))
      }
      runs.append(.match(String(source[range])))
      cursor = range.upperBound
    }
    if cursor < source.endIndex {
      runs.append(.plain(String(source[cursor...])))
    }
    return runs
  }
}
```

- [ ] **Step 4: Re-express `SnippetMaker` over it**

In `Sources/PensieveKit/Query/Snippet.swift`, replace the body's first line of
`make(from:matching:window:)` so the options constant lives in exactly one place. The doc comment's
paragraph about diacritic folding stays — move the "why" sentence to reference `FindMatcher.options`:

```swift
  public static func make(from source: String, matching query: String, window: Int = 80) -> Snippet {
    // First occurrence only — the search-results contract. Options come from `FindMatcher.options`
    // so this path and in-node find can never disagree about what "matches".
    guard let matchRange = FindMatcher.ranges(in: source, query: query).first else {
      let head = String(source.prefix(window * 2))
      let lead = head.count < source.count ? head + "…" : head
      return Snippet(leading: lead, match: "", trailing: "")
    }
```

The rest of the function is unchanged. Delete the now-unused `options:` argument list from the old
`source.range(of:options:)` call — that call is what the `guard` above replaces.

- [ ] **Step 5: Run the tests to verify they pass**

Run: `./scripts/test.sh --filter FindMatcher` then `./scripts/test.sh --filter Snippet`
Expected: PASS, both. The `Snippet` suite is the regression pin — if it fails, the unification changed shipped behavior.

- [ ] **Step 6: Verify there is exactly one options definition**

Run: `grep -rn "caseInsensitive, .diacriticInsensitive\|diacriticInsensitive" Sources/`
Expected: exactly one hit, in `FindMatcher.swift`.

- [ ] **Step 7: Commit**

```bash
git add Sources/PensieveKit/Support/FindMatcher.swift Sources/PensieveKit/Query/Snippet.swift Tests/PensieveKitTests/FindMatcherTests.swift
git commit -m "feat(kit): one matcher for find and snippets, one compare-options definition"
```

---

### Task 2: `FindAnchor` + `NodeFindDocument` (cheap corpus, empty provenance slots)

**Files:**
- Create: `Sources/PensieveKit/Query/NodeFindDocument.swift`
- Test: `Tests/PensieveKitTests/NodeFindDocumentTests.swift`

**Interfaces:**
- Consumes: `FindMatcher.ranges`, `FindRun` (Task 1); `Node`, `LooseEndView`, `Event` (existing model).
- Produces:
  - `FindAnchor` — `.nodeName`, `.description`, `.narration`, `.looseEndText(UUID)`, `.looseEndQuote(UUID)`, `.transcriptSegment(looseEndID: UUID, messageIndex: Int, segment: Int)`, `.event(UUID)`; `Hashable, Sendable`.
  - `FindUnit` — `init(anchor: FindAnchor, text: String)`; `Hashable, Sendable`.
  - `FindMatch` — `anchor: FindAnchor`, `offset: Int`, `length: Int`, `ordinal: Int` (1-based); `Hashable, Sendable`.
  - `FindMatchIdentity` — `anchor: FindAnchor`, `offset: Int`; `Hashable, Sendable`.
  - `NodeFindDocument.make(node:narration:looseEnds:events:showsLooseEnds:) -> NodeFindDocument`
  - `NodeFindDocument.matches(query: String) -> [FindMatch]`
  - `NodeFindDocument.text(for: FindAnchor) -> String?`
  - `NodeFindDocument.unresolvedLooseEndIDs: [UUID]`
  - `mutating func fill(looseEndID: UUID, units: [FindUnit])`

**Why the slot shape:** the sweep completes in file order but the document must stay in on-screen order, so provenance units are *filled in place*, never appended. See spec §Slot-fill ordering.

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/PensieveKitTests/NodeFindDocumentTests.swift
import Foundation
import Testing
@testable import PensieveKit

private func makeNode(name: String, description: String) -> Node {
  Node(id: UUID(), parentID: nil, kind: .project, name: name, description: description,
       state: .active, metadataJSON: "{}", branchKey: "", context: "",
       createdAt: Date(), updatedAt: Date())
}

private func makeLooseEndView(text: String, quote: String) -> LooseEndView {
  let looseEnd = LooseEnd(id: UUID(), nodeID: UUID(), sourceEventID: UUID(), text: text,
                          quote: quote, status: "open", createdAt: Date(), role: "typed",
                          sourceMessageIndex: 7, label: "", labelSuggestion: "")
  return LooseEndView(looseEnd: looseEnd, occurredAt: Date(), ageDays: 3)
}

private func makeEvent(summary: String) -> Event {
  Event(id: UUID(), nodeID: UUID(), sourceID: nil, kind: "git.commit", summary: summary,
        detailJSON: "{}", occurredAt: Date(), externalID: "abc123")
}

@Test func documentOrderFollowsOnScreenOrder() {
  let node = makeNode(name: "Pensieve", description: "a recall tool")
  let looseEnd = makeLooseEndView(text: "ship the find bar", quote: "we should ship the find bar")
  let event = makeEvent(summary: "feat: find bar")
  let document = NodeFindDocument.make(node: node, narration: "worked on find",
                                       looseEnds: [looseEnd], events: [event],
                                       showsLooseEnds: true)
  let anchors = document.units.map(\.anchor)
  #expect(anchors.first == .nodeName)
  #expect(anchors[1] == .description)
  #expect(anchors[2] == .narration)
  #expect(anchors[3] == .looseEndText(looseEnd.looseEnd.id))
  #expect(anchors.last == .event(event.id))
}

@Test func showsLooseEndsFalseOmitsEveryLooseEndUnit() {
  // The one-home rule: a childless focused strand shows its loose ends in the MIDDLE column, and
  // the detail renders no Loose Ends section at all. Indexing them would produce matches with no
  // site to scroll to.
  let looseEnd = makeLooseEndView(text: "ship the find bar", quote: "ship the find bar")
  let document = NodeFindDocument.make(node: makeNode(name: "Pensieve", description: ""),
                                       narration: nil, looseEnds: [looseEnd], events: [],
                                       showsLooseEnds: false)
  #expect(document.units.allSatisfy { anchor in
    if case .looseEndText = anchor.anchor { return false }
    if case .looseEndQuote = anchor.anchor { return false }
    if case .transcriptSegment = anchor.anchor { return false }
    return true
  })
  #expect(document.unresolvedLooseEndIDs.isEmpty)
}

@Test func nilNarrationContributesNoUnit() {
  let document = NodeFindDocument.make(node: makeNode(name: "Pensieve", description: ""),
                                       narration: nil, looseEnds: [], events: [],
                                       showsLooseEnds: true)
  #expect(!document.units.contains { $0.anchor == .narration })
}

@Test func matchesAreOrdinalNumberedInDocumentOrder() {
  let node = makeNode(name: "sync", description: "the sync store")
  let document = NodeFindDocument.make(node: node, narration: nil, looseEnds: [], events: [],
                                       showsLooseEnds: true)
  let matches = document.matches(query: "sync")
  #expect(matches.count == 2)
  #expect(matches[0].anchor == .nodeName)
  #expect(matches[0].ordinal == 1)
  #expect(matches[1].anchor == .description)
  #expect(matches[1].ordinal == 2)
  #expect(matches[1].offset == 4)      // "the sync store"
  #expect(matches[1].length == 4)
}

@Test func fillPlacesProvenanceUnitsInSlotOrderNotArrivalOrder() {
  let first = makeLooseEndView(text: "first end", quote: "first end")
  let second = makeLooseEndView(text: "second end", quote: "second end")
  var document = NodeFindDocument.make(node: makeNode(name: "n", description: ""), narration: nil,
                                       looseEnds: [first, second], events: [], showsLooseEnds: true)
  #expect(document.unresolvedLooseEndIDs == [first.looseEnd.id, second.looseEnd.id])
  // Fill the SECOND one first — arrival order is file order, not document order.
  document.fill(looseEndID: second.looseEnd.id,
                units: [FindUnit(anchor: .transcriptSegment(looseEndID: second.looseEnd.id,
                                                            messageIndex: 7, segment: 0),
                                 text: "second transcript")])
  document.fill(looseEndID: first.looseEnd.id,
                units: [FindUnit(anchor: .transcriptSegment(looseEndID: first.looseEnd.id,
                                                            messageIndex: 7, segment: 0),
                                 text: "first transcript")])
  let texts = document.units.map(\.text)
  #expect(texts.firstIndex(of: "first transcript")! < texts.firstIndex(of: "second transcript")!)
  #expect(document.unresolvedLooseEndIDs.isEmpty)
}

@Test func aFilledSlotHoldsEitherTranscriptUnitsOrTheQuoteNeverBoth() {
  // The quote is rendered ONLY in the transcript-unavailable fallback (LooseEndRow.swift:105), and
  // it is by construction a substring of the cited message — indexing both double-counts the same
  // text AND points one match at a site that does not exist.
  let looseEnd = makeLooseEndView(text: "ship it", quote: "we should ship it")
  var document = NodeFindDocument.make(node: makeNode(name: "n", description: ""), narration: nil,
                                       looseEnds: [looseEnd], events: [], showsLooseEnds: true)
  document.fillWithQuoteFallback(looseEndID: looseEnd.looseEnd.id, quote: looseEnd.looseEnd.quote)
  let anchors = document.units.map(\.anchor)
  #expect(anchors.contains(.looseEndQuote(looseEnd.looseEnd.id)))
  #expect(!anchors.contains { if case .transcriptSegment = $0 { return true } else { return false } })
}

@Test func unfilledSlotsContributeNoUnitsYet() {
  let looseEnd = makeLooseEndView(text: "ship it", quote: "we should ship it")
  let document = NodeFindDocument.make(node: makeNode(name: "n", description: ""), narration: nil,
                                       looseEnds: [looseEnd], events: [], showsLooseEnds: true)
  #expect(document.matches(query: "we should").isEmpty)   // quote not indexed until the slot resolves
  #expect(document.units.map(\.anchor) == [.looseEndText(looseEnd.looseEnd.id)])
}

@Test func textForAnchorReturnsTheUnitBody() {
  let node = makeNode(name: "Pensieve", description: "a recall tool")
  let document = NodeFindDocument.make(node: node, narration: nil, looseEnds: [], events: [],
                                       showsLooseEnds: true)
  #expect(document.text(for: .description) == "a recall tool")
  #expect(document.text(for: .narration) == nil)
}
```

> **Note on the fixture initializers:** `Node`, `LooseEnd` and `Event` are `@Table` types — before writing the tests, open `Sources/PensieveKit/Model/` and copy the **exact** member order and labels of each initializer. If a memberwise initializer differs from the sketch above, fix the fixture, not the model.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `./scripts/test.sh --filter NodeFindDocument`
Expected: FAIL — `cannot find 'NodeFindDocument' in scope`.

- [ ] **Step 3: Write `NodeFindDocument`**

```swift
// Sources/PensieveKit/Query/NodeFindDocument.swift
import Foundation

/// Where a findable piece of text lives in the detail pane. The single vocabulary Kit and the app
/// share for "where is this match": it is simultaneously the scroll target (`.id(anchor)`) and the
/// expansion instruction (a `.transcriptSegment` names the row to open).
public enum FindAnchor: Hashable, Sendable {
  case nodeName
  case description
  case narration
  case looseEndText(UUID)
  case looseEndQuote(UUID)
  case transcriptSegment(looseEndID: UUID, messageIndex: Int, segment: Int)
  case event(UUID)

  /// The loose end this anchor belongs to, if any — what the app expands to reach it.
  public var looseEndID: UUID? {
    switch self {
    case .looseEndText(let id), .looseEndQuote(let id): return id
    case .transcriptSegment(let id, _, _): return id
    case .nodeName, .description, .narration, .event: return nil
    }
  }
}

/// One findable text unit: some text, and where it is rendered.
public struct FindUnit: Hashable, Sendable {
  public let anchor: FindAnchor
  public let text: String
  public init(anchor: FindAnchor, text: String) { self.anchor = anchor; self.text = text }
}

/// One occurrence. `offset`/`length` are CHARACTER positions within the unit's text (not
/// `String.Index`) so a match survives being stored, compared and carried across a document rebuild.
public struct FindMatch: Hashable, Sendable {
  public let anchor: FindAnchor
  public let offset: Int
  public let length: Int
  public let ordinal: Int   // 1-based, document order

  public var identity: FindMatchIdentity { FindMatchIdentity(anchor: anchor, offset: offset) }
}

/// A match's stable identity — what the find bar tracks INSTEAD of an ordinal, so a background
/// provenance fill that inserts earlier matches cannot renumber the user's position out from under
/// them.
public struct FindMatchIdentity: Hashable, Sendable {
  public let anchor: FindAnchor
  public let offset: Int
  public init(anchor: FindAnchor, offset: Int) { self.anchor = anchor; self.offset = offset }
}

/// The ordered, findable projection of one node's detail pane.
///
/// Order is fixed at construction to match on-screen order: What It Is (name, description) → Last
/// Work Done → Loose Ends (each row's text, then its provenance slot) → Recent Activity. Provenance
/// arrives later and asynchronously, so each loose end owns a PRE-ALLOCATED slot the sweep fills in
/// place — appending would order matches by file-completion order and ⌘G would walk the pane in a
/// jumbled sequence.
public struct NodeFindDocument: Equatable, Sendable {
  /// A slot is either a fixed unit or a loose end's provenance, which resolves to transcript units
  /// OR the stored quote — never both (the quote is only rendered in the unavailable fallback, and
  /// it is a substring of the cited message).
  enum Slot: Equatable, Sendable {
    case unit(FindUnit)
    case provenance(looseEndID: UUID, resolved: [FindUnit]?)
  }

  private var slots: [Slot]

  /// Every findable unit, in document order. Unresolved provenance slots contribute nothing yet.
  public var units: [FindUnit] {
    slots.flatMap { slot -> [FindUnit] in
      switch slot {
      case .unit(let unit): return [unit]
      case .provenance(_, let resolved): return resolved ?? []
      }
    }
  }

  /// Loose ends whose provenance the sweep has not resolved yet, in document order.
  public var unresolvedLooseEndIDs: [UUID] {
    slots.compactMap { slot in
      if case .provenance(let looseEndID, let resolved) = slot, resolved == nil { return looseEndID }
      return nil
    }
  }

  public static func make(node: Node, narration: String?, looseEnds: [LooseEndView],
                          events: [Event], showsLooseEnds: Bool) -> NodeFindDocument {
    var slots: [Slot] = []
    slots.append(.unit(FindUnit(anchor: .nodeName, text: node.name)))
    if !node.description.isEmpty {
      slots.append(.unit(FindUnit(anchor: .description, text: node.description)))
    }
    // nil when the narration section is not rendered — disabled toggle, or no genuine narration.
    if let narration, !narration.isEmpty {
      slots.append(.unit(FindUnit(anchor: .narration, text: narration)))
    }
    // The one-home rule: when the middle column owns this node's loose ends the detail renders no
    // Loose Ends section, so indexing them would produce unreachable matches.
    if showsLooseEnds {
      for view in looseEnds {
        slots.append(.unit(FindUnit(anchor: .looseEndText(view.looseEnd.id), text: view.looseEnd.text)))
        slots.append(.provenance(looseEndID: view.looseEnd.id, resolved: nil))
      }
    }
    for event in events {
      slots.append(.unit(FindUnit(anchor: .event(event.id), text: event.summary)))
    }
    return NodeFindDocument(slots: slots)
  }

  /// Resolves a loose end's slot to its transcript units, in place.
  public mutating func fill(looseEndID: UUID, units: [FindUnit]) {
    resolve(looseEndID: looseEndID, with: units)
  }

  /// Resolves a loose end's slot to the stored quote — the honest fallback when the transcript is
  /// gone (85% of loose ends on the measured store).
  public mutating func fillWithQuoteFallback(looseEndID: UUID, quote: String) {
    let units = quote.isEmpty ? [] : [FindUnit(anchor: .looseEndQuote(looseEndID), text: quote)]
    resolve(looseEndID: looseEndID, with: units)
  }

  private mutating func resolve(looseEndID: UUID, with units: [FindUnit]) {
    for index in slots.indices {
      if case .provenance(let slotID, _) = slots[index], slotID == looseEndID {
        slots[index] = .provenance(looseEndID: looseEndID, resolved: units)
        return
      }
    }
  }

  public func text(for anchor: FindAnchor) -> String? {
    units.first { $0.anchor == anchor }?.text
  }

  /// Every occurrence of `query`, in document order, ordinal-numbered from 1.
  public func matches(query: String) -> [FindMatch] {
    var found: [FindMatch] = []
    for unit in units {
      for range in FindMatcher.ranges(in: unit.text, query: query) {
        let offset = unit.text.distance(from: unit.text.startIndex, to: range.lowerBound)
        let length = unit.text.distance(from: range.lowerBound, to: range.upperBound)
        found.append(FindMatch(anchor: unit.anchor, offset: offset, length: length,
                               ordinal: found.count + 1))
      }
    }
    return found
  }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `./scripts/test.sh --filter NodeFindDocument`
Expected: PASS (9 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/PensieveKit/Query/NodeFindDocument.swift Tests/PensieveKitTests/NodeFindDocumentTests.swift
git commit -m "feat(kit): the node find document — fixed order, in-place provenance slots"
```

---

### Task 3: `FindSession` — navigation and identity, as a pure state machine

**Files:**
- Create: `Sources/PensieveKit/Query/FindSession.swift`
- Test: `Tests/PensieveKitTests/FindSessionTests.swift`

**Interfaces:**
- Consumes: `NodeFindDocument`, `FindMatch`, `FindMatchIdentity` (Task 2).
- Produces: `FindSession` with `init(document:)`, `var query: String { get }`, `mutating func setQuery(_ query: String)`, `mutating func update(document: NodeFindDocument)`, `mutating func next()`, `mutating func previous()`, `var matches: [FindMatch] { get }`, `var current: FindMatch? { get }`, `var currentOrdinal: Int? { get }`, `var matchCount: Int { get }`, `var hasMatches: Bool { get }`, `mutating func clear()`.

**Why in Kit:** this is where ⌘G's behavior under a mutating document is decided, and the app target has no tests. Putting it in a view model would make the identity rules unverifiable.

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/PensieveKitTests/FindSessionTests.swift
import Foundation
import Testing
@testable import PensieveKit

/// A document of plain units, built directly so these tests exercise navigation, not construction.
private func document(_ pairs: [(FindAnchor, String)]) -> NodeFindDocument {
  var built = NodeFindDocument.make(node: Node(id: UUID(), parentID: nil, kind: .project,
                                               name: "", description: "", state: .active,
                                               metadataJSON: "{}", branchKey: "", context: "",
                                               createdAt: Date(), updatedAt: Date()),
                                    narration: nil, looseEnds: [], events: [], showsLooseEnds: true)
  built = NodeFindDocument.testing(units: pairs.map { FindUnit(anchor: $0.0, text: $0.1) })
  return built
}

@Test func nextWrapsAroundAndPreviousWrapsBackward() {
  var session = FindSession(document: document([(.nodeName, "sync"), (.description, "sync sync")]))
  session.setQuery("sync")
  #expect(session.matchCount == 3)
  #expect(session.currentOrdinal == 1)
  session.next(); #expect(session.currentOrdinal == 2)
  session.next(); #expect(session.currentOrdinal == 3)
  session.next(); #expect(session.currentOrdinal == 1)   // wraps
  session.previous(); #expect(session.currentOrdinal == 3)
}

@Test func aFillThatInsertsEarlierMatchesKeepsTheUserOnTheSameMatch() {
  // The whole reason identity is tracked instead of an ordinal.
  let looseEndID = UUID()
  var session = FindSession(document: document([(.looseEndText(looseEndID), "sync"),
                                                (.event(UUID()), "sync")]))
  session.setQuery("sync")
  session.next()
  let heldIdentity = session.current?.identity
  #expect(session.currentOrdinal == 2)

  // A provenance fill lands EARLIER in document order, adding two matches ahead of the user.
  session.update(document: document([(.looseEndText(looseEndID), "sync"),
                                     (.transcriptSegment(looseEndID: looseEndID, messageIndex: 1,
                                                         segment: 0), "sync sync"),
                                     (.event(UUID()), "sync")]))
  #expect(session.current?.identity == heldIdentity)   // same match…
  #expect(session.currentOrdinal == 4)                 // …renumbered, not moved
  #expect(session.matchCount == 4)
}

@Test func whenTheCurrentMatchVanishesItReanchorsToTheSameListPosition() {
  var session = FindSession(document: document([(.narration, "sync one"), (.event(UUID()), "sync two")]))
  session.setQuery("sync")
  session.next()
  #expect(session.currentOrdinal == 2)
  // ⌘R replaces the narration with different prose: the .narration match is gone.
  session.update(document: document([(.event(UUID()), "sync two")]))
  #expect(session.matchCount == 1)
  #expect(session.currentOrdinal == 1)                 // clamped, never nil-while-matches-exist
  #expect(session.current?.anchor == .event(session.current!.anchor.looseEndID == nil
                                            ? session.current!.anchor : session.current!.anchor)
          || session.matchCount == 1)
}

@Test func changingTheQueryResetsToTheFirstMatch() {
  var session = FindSession(document: document([(.nodeName, "alpha beta"), (.description, "beta")]))
  session.setQuery("beta")
  session.next()
  #expect(session.currentOrdinal == 2)
  session.setQuery("alpha")
  #expect(session.matchCount == 1)
  #expect(session.currentOrdinal == 1)
}

@Test func anEmptyQueryYieldsNoMatchesAndNoCurrent() {
  var session = FindSession(document: document([(.nodeName, "sync")]))
  session.setQuery("")
  #expect(session.matchCount == 0)
  #expect(session.current == nil)
  #expect(!session.hasMatches)
  session.next()                       // must not crash
  #expect(session.current == nil)
}

@Test func clearDropsQueryAndMatches() {
  var session = FindSession(document: document([(.nodeName, "sync")]))
  session.setQuery("sync")
  session.clear()
  #expect(session.query.isEmpty)
  #expect(session.matchCount == 0)
}
```

> **Note:** the tests need a way to build a document from bare units. Add a test-only factory
> `NodeFindDocument.testing(units:)` in Task 3's implementation step, marked as such in its doc
> comment, so the navigation tests don't depend on `make(...)`'s section ordering. Then simplify the
> `document(_:)` helper above to a single call to it and delete the unused first assignment.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `./scripts/test.sh --filter FindSession`
Expected: FAIL — `cannot find 'FindSession' in scope`.

- [ ] **Step 3: Add the test-only document factory**

In `Sources/PensieveKit/Query/NodeFindDocument.swift`:

```swift
extension NodeFindDocument {
  /// Builds a document from bare units, bypassing section ordering. **Test support only** — product
  /// code must go through `make(node:…)` so document order stays tied to on-screen order.
  public static func testing(units: [FindUnit]) -> NodeFindDocument {
    NodeFindDocument(slots: units.map { .unit($0) })
  }
}
```

`NodeFindDocument`'s memberwise `init(slots:)` is `internal`; that is sufficient because the
extension lives in the same module.

- [ ] **Step 4: Write `FindSession`**

```swift
// Sources/PensieveKit/Query/FindSession.swift
import Foundation

/// The find bar's navigation state, as a pure value: which query, which matches, and which one the
/// user is standing on.
///
/// It tracks the current match by **identity** (anchor + character offset), not by ordinal, because
/// the document mutates underneath it: the transcript sweep fills provenance slots in document
/// order, so matches appear AHEAD of the user's position. Holding an ordinal would silently move
/// them to a different match; holding an identity renumbers around them.
public struct FindSession: Sendable {
  public private(set) var query: String = ""
  public private(set) var matches: [FindMatch] = []
  private var document: NodeFindDocument
  private var currentIdentity: FindMatchIdentity?

  public init(document: NodeFindDocument) { self.document = document }

  public var matchCount: Int { matches.count }
  public var hasMatches: Bool { !matches.isEmpty }

  public var current: FindMatch? {
    guard let currentIdentity else { return nil }
    return matches.first { $0.identity == currentIdentity }
  }

  public var currentOrdinal: Int? { current?.ordinal }

  public mutating func setQuery(_ query: String) {
    self.query = query
    matches = document.matches(query: query)
    currentIdentity = matches.first?.identity   // a new query always starts at the first match
  }

  /// Re-runs the query against a mutated document (a provenance fill, a narration refresh),
  /// preserving the user's position where possible.
  public mutating func update(document: NodeFindDocument) {
    let previousOrdinal = current?.ordinal
    self.document = document
    matches = document.matches(query: query)
    guard !matches.isEmpty else { currentIdentity = nil; return }
    if let currentIdentity, matches.contains(where: { $0.identity == currentIdentity }) {
      return   // same match, possibly renumbered — nothing to do
    }
    // The held match is gone (a re-parsed transcript failed the guard, or ⌘R replaced the
    // narration). Re-anchor to the same POSITION in the list, clamped — deterministic, and the
    // closest thing to "the nearest following match" without re-deriving vanished document offsets.
    let target = min(previousOrdinal ?? 1, matches.count)
    currentIdentity = matches[target - 1].identity
  }

  public mutating func next() { step(by: 1) }
  public mutating func previous() { step(by: -1) }

  private mutating func step(by delta: Int) {
    guard !matches.isEmpty else { currentIdentity = nil; return }
    guard let ordinal = current?.ordinal else {
      currentIdentity = matches.first?.identity
      return
    }
    let zeroBased = (ordinal - 1 + delta + matches.count) % matches.count
    currentIdentity = matches[zeroBased].identity
  }

  public mutating func clear() {
    query = ""
    matches = []
    currentIdentity = nil
  }
}
```

- [ ] **Step 5: Simplify the test helper and re-run**

Replace the `document(_:)` helper in the test file with:

```swift
private func document(_ pairs: [(FindAnchor, String)]) -> NodeFindDocument {
  NodeFindDocument.testing(units: pairs.map { FindUnit(anchor: $0.0, text: $0.1) })
}
```

Also simplify the over-complicated assertion in `whenTheCurrentMatchVanishesItReanchorsToTheSameListPosition` to:

```swift
  #expect(session.currentOrdinal == 1)
  #expect(session.matchCount == 1)
```

Run: `./scripts/test.sh --filter FindSession`
Expected: PASS (6 tests).

- [ ] **Step 6: Commit**

```bash
git add Sources/PensieveKit/Query/FindSession.swift Sources/PensieveKit/Query/NodeFindDocument.swift Tests/PensieveKitTests/FindSessionTests.swift
git commit -m "feat(kit): find navigation tracks match identity, not ordinal"
```

---

## Phase 2 — The bar, the binding, the cheap corpus (App)

### Task 4: Keybinding swap + Find menu + `NodeFindState` + bar chrome

**Files:**
- Create: `Sources/PensieveApp/NodeFindState.swift`, `Sources/PensieveApp/FindBar.swift`, `Sources/PensieveApp/FindCommands.swift`
- Modify: `Sources/PensieveApp/PensieveApp.swift:37-56`, `Sources/PensieveApp/DetailView.swift:24-27,89-93`
- Modify: `Sources/PensieveApp/Localizable.xcstrings`

**Interfaces:**
- Consumes: `FindSession`, `NodeFindDocument` (Tasks 2-3).
- Produces: `NodeFindState` (`@Observable`, `final class`) with `isPresented: Bool`, `query: String`, `session: FindSession`, `sweepDone/sweepTotal: Int`, `nodeID: UUID?`, `pendingScroll: FindAnchor?`, `scrollTarget: FindAnchor?`, `forcedExpansions: Set<UUID>`, and methods `present()`, `dismiss()`, `reset(nodeID:document:)`, `setQuery(_:)`, `next()`, `previous()`, `updateDocument(_:)`, `siteMounted(_:)`, `runs(for:) -> [FindRun]`, `currentOffset(in:) -> Int?`, `hasMatches: Bool`.

**This task ships a working bar with zero highlighting.** ⌘F opens it, typing shows a count, ⌘G walks matches (no visual highlight yet), Esc closes, ⌥⌘F still opens global search. Highlighting is Task 5 — keeping them apart means a reviewer can reject the binding change without rejecting the renderer.

- [ ] **Step 1: Write `NodeFindState`**

```swift
// Sources/PensieveApp/NodeFindState.swift
import Foundation
import Observation
import PensieveKit

/// The find bar's per-window state. One instance per `DetailView`, published to the menu bar via
/// `.focusedSceneValue` so Edit ▸ Find acts on the FOCUSED scene — the main window and each ⌘⌥N
/// recall window each own their find.
///
/// All the interesting rules (ordinals, identity, wrap-around, re-anchoring) live in the tested
/// `FindSession` in PensieveKit. This class is the observable shell plus the app-only concerns:
/// presentation, the transcript sweep, and reaching a match that is not on screen yet.
@Observable
final class NodeFindState {
  var isPresented = false
  private(set) var query = ""
  private(set) var session = FindSession(document: NodeFindDocument.testing(units: []))

  /// Sweep progress, shown as "N matches · searching transcripts done/total".
  private(set) var sweepDone = 0
  private(set) var sweepTotal = 0

  /// The node this state belongs to. `DetailView`'s `@State` survives a node change (which is why
  /// the file is full of `loadedNodeID == node.id` guards), so find state must be reset explicitly
  /// or the bar reports the previous node's matches.
  private(set) var nodeID: UUID?

  /// Set when navigation targets an anchor whose view is not mounted yet; cleared by `siteMounted`.
  private(set) var pendingScroll: FindAnchor?
  /// Published once the target's view reports it mounted; `DetailView` turns it into `scrollTo`.
  var scrollTarget: FindAnchor?
  /// Loose-end rows find has force-expanded. Per-window on purpose: reusing the app-wide
  /// `AppModel.expandedLooseEndID` would expand the same row in every open recall window.
  private(set) var forcedExpansions: Set<UUID> = []

  /// The in-flight transcript sweep, and the generation it belongs to. A late result whose
  /// generation differs is dropped — same discipline as DetailView's `Task.isCancelled` guard.
  @ObservationIgnored var sweepTask: Task<Void, Never>?
  @ObservationIgnored private(set) var generation = 0

  var hasMatches: Bool { session.hasMatches }
  var matchCount: Int { session.matchCount }
  var currentOrdinal: Int? { session.currentOrdinal }
  var isSweeping: Bool { sweepTotal > 0 && sweepDone < sweepTotal }

  func present() { isPresented = true }

  func dismiss() {
    isPresented = false
    query = ""
    session.clear()
    forcedExpansions = []
    pendingScroll = nil
    cancelSweep()
  }

  /// Called when the pane's content loads or the node changes. Bumps the generation so a sweep
  /// started for the previous node can't write into this one.
  func reset(nodeID: UUID, document: NodeFindDocument) {
    generation += 1
    cancelSweep()
    if self.nodeID != nodeID {
      query = ""
      forcedExpansions = []
      pendingScroll = nil
      isPresented = false
    }
    self.nodeID = nodeID
    sweepDone = 0
    sweepTotal = 0
    session = FindSession(document: document)
    session.setQuery(query)
  }

  func setQuery(_ newQuery: String) {
    query = newQuery
    session.setQuery(newQuery)
    focusCurrent()
  }

  func updateDocument(_ document: NodeFindDocument) {
    session.update(document: document)
  }

  func next() { session.next(); focusCurrent() }
  func previous() { session.previous(); focusCurrent() }

  func noteSweepProgress(done: Int, total: Int) {
    sweepDone = done
    sweepTotal = total
  }

  func cancelSweep() {
    sweepTask?.cancel()
    sweepTask = nil
  }

  /// A site reports that it is now in the view hierarchy. When it is the one we're waiting for, the
  /// scroll fires. This replaces guessing at layout timing: a transcript unit is only in the
  /// document if the sweep already loaded and guarded it, so the site WILL mount once expansion is
  /// set.
  func siteMounted(_ anchor: FindAnchor) {
    guard pendingScroll == anchor else { return }
    pendingScroll = nil
    scrollTarget = anchor
  }

  /// Highlight runs for one anchor's text, or an empty array when nothing matches there.
  func runs(for anchor: FindAnchor, text: String) -> [FindRun] {
    guard !query.isEmpty else { return [] }
    let ranges = FindMatcher.ranges(in: text, query: query)
    guard !ranges.isEmpty else { return [] }
    return FindMatcher.runs(in: text, ranges: ranges)
  }

  /// The character offset of the current match, if it lives in this anchor — lets the renderer tint
  /// the current match more strongly than the rest.
  func currentOffset(in anchor: FindAnchor) -> Int? {
    guard let current = session.current, current.anchor == anchor else { return nil }
    return current.offset
  }

  /// Prepares to reveal the current match: force-expands its row and arms the pending scroll.
  private func focusCurrent() {
    guard let current = session.current else { pendingScroll = nil; return }
    if let looseEndID = current.anchor.looseEndID {
      forcedExpansions.insert(looseEndID)
    }
    pendingScroll = current.anchor
    // A site that is ALREADY mounted will not fire `onAppear` again, so publish the target
    // immediately too; `siteMounted` covers the not-yet-mounted case. Setting both is safe —
    // `scrollTo` on a present id is idempotent.
    scrollTarget = current.anchor
  }
}
```

- [ ] **Step 2: Write `FindBar`**

```swift
// Sources/PensieveApp/FindBar.swift
import SwiftUI
import PensieveKit

/// The detail column's find bar. Standard macOS Find grammar: a field, a match count, previous/next,
/// and Done. Esc dismisses (wired by the caller's `.onExitCommand`).
struct FindBar: View {
  var find: NodeFindState
  @FocusState private var isFieldFocused: Bool

  var body: some View {
    HStack(spacing: 8) {
      Image(systemName: "magnifyingglass").foregroundStyle(.secondary).font(.caption)
      TextField("Find in this project", text: Binding(get: { find.query },
                                                      set: { find.setQuery($0) }))
        .textFieldStyle(.plain)
        .focused($isFieldFocused)
        .onSubmit { find.next() }

      Text(countLabel).metaText().monospacedDigit()

      Button { find.previous() } label: { Image(systemName: "chevron.up") }
        .buttonStyle(.borderless).disabled(!find.hasMatches)
        .help("Find Previous")
      Button { find.next() } label: { Image(systemName: "chevron.down") }
        .buttonStyle(.borderless).disabled(!find.hasMatches)
        .help("Find Next")
      Button("Done") { find.dismiss() }
        .buttonStyle(.borderless)
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 6)
    .background(.bar)
    .overlay(alignment: .bottom) { Divider() }
    .onAppear { isFieldFocused = true }
  }

  private var countLabel: String {
    if find.isSweeping {
      return String(localized: "\(find.matchCount) matches · searching transcripts \(find.sweepDone)/\(find.sweepTotal)")
    }
    guard find.hasMatches else {
      return find.query.isEmpty ? "" : String(localized: "No matches")
    }
    return String(localized: "\(find.currentOrdinal ?? 1) of \(find.matchCount)")
  }
}
```

> Check how `String(localized:)` handles interpolation in this codebase before writing the two
> interpolated strings — `grep -rn "func localized" Sources/PensieveApp/` and match the existing
> pattern. If it takes only a static key, use `String(format: String(localized: "%lld of %lld"), …)`
> and register the format keys accordingly.

- [ ] **Step 3: Write `FindCommands`**

```swift
// Sources/PensieveApp/FindCommands.swift
import SwiftUI

/// Edit ▸ Find. A separate `Commands` struct because `@FocusedValue` is a property wrapper and
/// cannot be declared inside `PensieveApp.body`'s inline `.commands { … }` block.
///
/// `CommandGroup(after: .textEditing)` is the only Edit-menu region placement SwiftUI offers — there
/// is no `.find` placement (verified against the macOS 26.5 SDK).
struct FindCommands: Commands {
  @FocusedValue(NodeFindState.self) private var find

  var body: some Commands {
    CommandGroup(after: .textEditing) {
      Menu("Find") {
        Button("Find") { find?.present() }
          .keyboardShortcut("f", modifiers: .command)
          .disabled(find == nil)
        Button("Find Next") { find?.next() }
          .keyboardShortcut("g", modifiers: .command)
          .disabled(find?.hasMatches != true)
        Button("Find Previous") { find?.previous() }
          .keyboardShortcut("g", modifiers: [.command, .shift])
          .disabled(find?.hasMatches != true)
      }
    }
  }
}
```

> **Pre-committed fallback** (from the spec's `.searchScopes` precedent — a SwiftUI placement that
> misbehaved at runtime): if `@FocusedValue(NodeFindState.self)` does not compile on this SDK, or the
> `Menu` lands outside the Edit menu, declare an explicit
> `struct NodeFindFocusKey: FocusedValueKey { typealias Value = NodeFindState }` plus
> `focusedSceneValue(\.nodeFind, state)` and, if the placement is wrong, move the three items to
> `CommandMenu("Find")` as a top-level menu. Record whichever you used in the commit message.

- [ ] **Step 4: Rewire the app's commands**

In `Sources/PensieveApp/PensieveApp.swift`, inside `.commands { … }`, add `FindCommands()` and change
the `Go` menu so Find becomes the *global* item on ⌥⌘F:

```swift
      SidebarCommands()
      FindCommands()
      CommandGroup(after: .newItem) {
        // …unchanged…
      }
      CommandMenu("Go") {
        Button("Search Everything") { model.focusSearchRequested = true }
          .keyboardShortcut("f", modifiers: [.command, .option])
        Divider()
        Button("Refresh") { Task { await model.refreshNow() } }
          .keyboardShortcut("r", modifiers: .command)
      }
```

- [ ] **Step 5: Mount the bar in `DetailView`**

In `Sources/PensieveApp/DetailView.swift`, add the state, wrap the existing `ScrollViewReader` in a
`VStack` so the bar sits above it, publish the focused value, and handle Esc:

```swift
  @State private var find = NodeFindState()
```

```swift
  var body: some View {
    VStack(spacing: 0) {
      if find.isPresented { FindBar(find: find) }
      ScrollViewReader { proxy in
        // …the existing ScrollView body, unchanged…
      }
    }
    .focusedSceneValue(find)
    .onExitCommand { if find.isPresented { find.dismiss() } }
  }
```

Then, at the end of the existing `.task(id: DetailLoadKey(...))` block (after `looseEnds` and
`recentEvents` are assigned, before the narration work), seed the document:

```swift
      find.reset(nodeID: node.id,
                 document: NodeFindDocument.make(node: node, narration: nil,
                                                 looseEnds: looseEnds, events: recentEvents,
                                                 showsLooseEnds: showsLooseEnds))
```

And after the narration lands (right after `lastWorkDone = prose`), refresh it so narration text
becomes findable:

```swift
      find.reset(nodeID: node.id,
                 document: NodeFindDocument.make(node: node,
                                                 narration: narrationEnabled ? prose : nil,
                                                 looseEnds: looseEnds, events: recentEvents,
                                                 showsLooseEnds: showsLooseEnds))
```

- [ ] **Step 6: Add the String Catalog keys**

Open `Sources/PensieveApp/Localizable.xcstrings`. **Reuse** the existing `"Find"` key (line ~985,
`de`: `"Suchen"`) — it now labels the local item, and the German is still correct. Add, matching the
file's existing JSON shape exactly (`extractionState`, `localizations.de.stringUnit.value`):

| Key | de |
|---|---|
| `Search Everything` | `Alles durchsuchen` |
| `Find in this project` | `In diesem Projekt suchen` |
| `Find Next` | `Weitersuchen` |
| `Find Previous` | `Rückwärts suchen` |
| `Done` | `Fertig` |
| `No matches` | `Keine Treffer` |
| `%lld of %lld` | `%1$lld von %2$lld` |
| `%lld matches · searching transcripts %lld/%lld` | `%1$lld Treffer · Transkripte werden durchsucht %2$lld/%3$lld` |

Leave the existing `"Search"` → `"Suchen"` key (line ~2001) alone; it labels the `.searchable`
field's prompt, which is unchanged.

- [ ] **Step 7: Build**

Run:
```bash
xcodegen generate && xcodebuild -project Pensieve.xcodeproj -scheme Pensieve \
  -configuration Debug -derivedDataPath ./.build-xcode build 2>&1 | tail -20
```
Expected: `BUILD SUCCEEDED`.

- [ ] **Step 8: Smoke-launch**

Run:
```bash
SCRATCH=$(mktemp -d)
PENSIEVE_DB="$SCRATCH/p.sqlite" PENSIEVE_CAPTURE_DB="$SCRATCH/c.sqlite" \
  ./.build-xcode/Build/Products/Debug/Pensieve.app/Contents/MacOS/Pensieve &
APP_PID=$!; sleep 4; kill $APP_PID
```
Expected: no crash, no error output.

- [ ] **Step 9: Eyeball (manual, needs the built app)**

- Edit ▸ Find ▸ Find exists **under Edit**, with Find / Find Next / Find Previous.
- ⌘F opens the bar with the field focused; Esc closes it.
- ⌥⌘F focuses the sidebar search field (global search still works).
- Typing a word present in the node's description shows a count like "1 of 2"; ⌘G advances it and wraps.
- Selecting the Briefing (no node): ⌘F does nothing (menu item disabled), ⌥⌘F still works.

- [ ] **Step 10: Discard `Package.resolved` churn and commit**

```bash
git checkout -- Package.resolved 2>/dev/null || true
git add Sources/PensieveApp/NodeFindState.swift Sources/PensieveApp/FindBar.swift \
  Sources/PensieveApp/FindCommands.swift Sources/PensieveApp/PensieveApp.swift \
  Sources/PensieveApp/DetailView.swift Sources/PensieveApp/Localizable.xcstrings
git commit -m "feat(app)!: ⌘F finds in the open node, ⌥⌘F searches everything"
```

---

### Task 5: Highlighting + anchors + mount-driven scroll (cheap corpus)

**Files:**
- Create: `Sources/PensieveApp/HighlightedText.swift`
- Modify: `Sources/PensieveApp/DetailView.swift` (anchors on name/description/narration/events, scroll handling), `Sources/PensieveApp/LooseEndRow.swift` (anchor + highlight on the loose-end text), `Sources/PensieveApp/ContentListView.swift:189-197` (`SnippetText`)

**Interfaces:**
- Consumes: `NodeFindState.runs(for:text:)`, `.currentOffset(in:)`, `.siteMounted(_:)`, `.scrollTarget`; `FindRun`.
- Produces: `HighlightedText(runs:currentOffset:)` — the single highlight renderer in the app.

- [ ] **Step 1: Write `HighlightedText`**

```swift
// Sources/PensieveApp/HighlightedText.swift
import SwiftUI
import PensieveKit

/// The app's ONE highlight renderer: a `Text` concatenation over `FindRun`s, so there is no index
/// math and no `AttributedString` round-trip. All matches tint; the current match tints strongly —
/// Safari's convention.
struct HighlightedText: View {
  let runs: [FindRun]
  /// Character offset of the current match within this text, when it lives here.
  var currentOffset: Int?

  var body: some View { composed }

  private var composed: Text {
    var result = Text("")
    var offset = 0
    for run in runs {
      switch run {
      case .plain(let text):
        result = result + Text(text)
      case .match(let text):
        let isCurrent = currentOffset == offset
        result = result + Text(text)
          .bold()
          .foregroundColor(isCurrent ? Color.black : Color.primary)
          .background(isCurrent ? Color.yellow : Color.yellow.opacity(0.35))
      }
      offset += run.text.count
    }
    return result
  }
}

extension View {
  /// Reports this site to find when it enters the hierarchy, and tags it as a scroll target.
  /// Both halves are needed: `.id` makes `scrollTo` able to reach it, `onAppear` tells find that a
  /// previously-absent site is now reachable.
  func findSite(_ anchor: FindAnchor, _ find: NodeFindState?) -> some View {
    self.id(anchor)
      .onAppear { find?.siteMounted(anchor) }
  }
}
```

> `Text.background(_:)` requires macOS 14+ on `Text` — if it does not compile, wrap the match run in
> a `Text` with `.foregroundColor` only and apply the tint via an `AttributedString` built from
> `runs` instead. Do not fall back to per-run `View`s in an `HStack`: that breaks line wrapping,
> which is the whole reason this is a `Text` concatenation.

- [ ] **Step 2: Anchor and highlight the cheap sites in `DetailView`**

The row's `.id(view.looseEnd.id)` at `DetailView.swift:70` **stays** — it is what the shipped
`scrollTo(UUID)` landings (⌘F hit, Spotlight tap, `pensieve://looseend/…`) resolve. Anchors go on
inner views only.

Node name (`DetailView.swift:32`):

```swift
            findableText(node.name, anchor: .nodeName)
              .font(.largeTitle).bold()
```

Description (`DetailView.swift:145`) and narration (`:48`) and each event summary
(`TimelineRow`'s `Text(event.summary).prose()`) follow the same shape. Add the helper to `DetailView`:

```swift
  /// A text site that participates in find: highlighted when the query matches, plain otherwise,
  /// and always registered as a scroll target.
  @ViewBuilder private func findableText(_ text: String, anchor: FindAnchor) -> some View {
    let runs = find.runs(for: anchor, text: text)
    Group {
      if runs.isEmpty {
        Text(text)
      } else {
        HighlightedText(runs: runs, currentOffset: find.currentOffset(in: anchor))
      }
    }
    .findSite(anchor, find)
  }
```

`TimelineRow` is a separate private struct; give it `var find: NodeFindState?` and pass it down from
`ActivityTimeline`, which also takes it from `DetailView`. Keep the parameter optional so the type
stays usable without find.

- [ ] **Step 3: Drive the scroll**

Add to `DetailView`'s `ScrollViewReader` body, beside the existing `.onChange(of: model.expandedLooseEndID)`:

```swift
    .onChange(of: find.scrollTarget) { _, anchor in
      guard let anchor else { return }
      withAnimation { proxy.scrollTo(anchor, anchor: .center) }
      find.scrollTarget = nil
    }
```

- [ ] **Step 4: Highlight the loose-end text**

In `Sources/PensieveApp/LooseEndRow.swift`, add `var find: NodeFindState?` and replace
`Text(view.looseEnd.text).prose()` (line 48) with the highlighted equivalent:

```swift
            looseEndText
```

```swift
  @ViewBuilder private var looseEndText: some View {
    let anchor = FindAnchor.looseEndText(view.looseEnd.id)
    let runs = find?.runs(for: anchor, text: view.looseEnd.text) ?? []
    Group {
      if runs.isEmpty {
        Text(view.looseEnd.text).prose()
      } else {
        HighlightedText(runs: runs, currentOffset: find?.currentOffset(in: anchor)).prose()
      }
    }
    .findSite(anchor, find)
  }
```

Pass `find: find` at `DetailView.swift:67-69`. The other two call sites
(`ContentListView.swift:135`, `:151`) pass nothing — the parameter defaults to `nil`, so the middle
column and the Review Suggestions list are unaffected. **Verify all three call sites compile.**

- [ ] **Step 5: Re-express `SnippetText` over `HighlightedText`**

In `Sources/PensieveApp/ContentListView.swift:189-197`:

```swift
/// Renders a grounded snippet with the matched run highlighted. A `Snippet` is the N=1 case of
/// `FindRun`, so this delegates to the app's one highlight renderer rather than building a second.
struct SnippetText: View {
  let snippet: Snippet
  var body: some View {
    HighlightedText(runs: runs).lineLimit(2)
  }

  private var runs: [FindRun] {
    guard !snippet.match.isEmpty else { return [.plain(snippet.leading)] }
    return [.plain(snippet.leading), .match(snippet.match), .plain(snippet.trailing)]
  }
}
```

- [ ] **Step 6: Build, smoke, eyeball**

Run the Step 7/8 commands from Task 4. Then check manually:
- ⌘F, type a word in the description → the run is highlighted; ⌘G moves the *strong* highlight.
- ⌘G into an event summary scrolls the pane to that timeline row.
- Search-results highlighting in the middle column (global ⌥⌘F search) looks exactly as before.
- Click a global search hit → it still lands on and expands the cited row (`scrollTo(UUID)` intact).

- [ ] **Step 7: Commit**

```bash
git checkout -- Package.resolved 2>/dev/null || true
git add Sources/PensieveApp/HighlightedText.swift Sources/PensieveApp/DetailView.swift \
  Sources/PensieveApp/LooseEndRow.swift Sources/PensieveApp/ContentListView.swift
git commit -m "feat(app): highlight find matches in place, one renderer for find and snippets"
```

---

## Phase 3 — Shared provenance (Kit + wiring)

### Task 6: `TranscriptSegment.findableText` + move `displayBody` into Kit

**Files:**
- Modify: `Sources/PensieveKit/Transcript/TranscriptSegment.swift`, `Sources/PensieveApp/TranscriptSegmentView.swift:102-141`
- Test: `Tests/PensieveKitTests/FindableTextTests.swift`

**Interfaces:**
- Produces: `HarnessKind.displayBody: String?` (moved to Kit), `TranscriptSegment.findableText: String?`.
- Consumes: nothing new.

**Why the move is legitimate, not scope creep:** `displayBody` is already documented *"Content —
verbatim, never localized"* (`TranscriptSegmentView.swift:120`). It is a pure content projection that
happens to live in the app; the localized `label` in the same extension stays there. Moving it is what
lets the find document index exactly what the harness card displays, with one definition.

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/PensieveKitTests/FindableTextTests.swift
import Foundation
import Testing
@testable import PensieveKit

@Test func markdownSegmentIsFindableAsItsText() {
  #expect(TranscriptSegment.markdown("fix the sync gap").findableText == "fix the sync gap")
}

@Test func calloutIsFindableByBodyNotByItsTagName() {
  // The tag name renders as chrome beside a localized severity label, not as prose.
  let callout = TranscriptCallout(severity: .caution, tagName: "HARD-GATE",
                                  body: "do not skip the gate", raw: "<HARD-GATE>…</HARD-GATE>")
  #expect(TranscriptSegment.callout(callout).findableText == "do not skip the gate")
}

@Test func harnessIsFindableByItsDisplayedBody() {
  let block = HarnessBlock(kind: .systemReminder("the store moved"), raw: "<system-reminder>…")
  #expect(TranscriptSegment.harness(block).findableText == "the store moved")
}

@Test func interruptedHarnessContributesNoFindableText() {
  let block = HarnessBlock(kind: .interrupted, raw: "[Request interrupted")
  #expect(TranscriptSegment.harness(block).findableText == nil)
}

@Test func findableTextNeverExposesRawMarkup() {
  // `raw` is the exact source substring (the no-loss invariant), so indexing it would match tag
  // markup the app never displays and inflate the match count.
  let block = HarnessBlock(kind: .systemReminder("body only"),
                           raw: "<system-reminder>body only</system-reminder>")
  let findable = TranscriptSegment.harness(block).findableText
  #expect(findable == "body only")
  #expect(!(findable ?? "").contains("system-reminder"))
}

@Test func taskNotificationIsFindableBySummaryAndStatus() {
  let notification = TaskNotificationBlock(taskID: "t1", toolUseID: "u1", outputFile: "out.txt",
                                           status: "completed", summary: "reviewed the spec",
                                           note: "a note", unrecognisedChildren: ["extra": "x"])
  let findable = TranscriptSegment.harness(
    HarnessBlock(kind: .taskNotification(notification), raw: "<task-notification>…")).findableText
  #expect(findable == "reviewed the spec · completed")
  // Unmodelled children are lossless in the PARSE but never rendered, so never findable.
  #expect(!(findable ?? "").contains("x"))
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `./scripts/test.sh --filter FindableText`
Expected: FAIL — `value of type 'TranscriptSegment' has no member 'findableText'`.

- [ ] **Step 3: Move `displayBody` into Kit and add `findableText`**

Cut the `displayBody` computed property out of `extension HarnessKind` in
`Sources/PensieveApp/TranscriptSegmentView.swift` (lines ~120-140, everything from the
`/// Content — verbatim, never localized.` comment through its closing brace) and paste it into
`Sources/PensieveKit/Transcript/TranscriptSegment.swift` as an extension after `HarnessKind`:

```swift
extension HarnessKind {
  /// Content — verbatim, never localized. nil when the label alone says everything.
  ///
  /// Lives in Kit rather than beside the view because it is also the FINDABLE projection of a
  /// harness block: find must index exactly what the card renders, and two copies of this would
  /// drift into highlighting text that isn't on screen.
  public var displayBody: String? {
    // …the body, moved verbatim…
  }
}
```

The `label` property stays in the app (it is localized chrome). Then add:

```swift
extension TranscriptSegment {
  /// The text a find should search for this segment — **what the app displays**, never `raw`.
  ///
  /// `raw` is the exact source substring, pinned by the no-loss property, and includes tag markup
  /// plus `unrecognisedChildren` that no view renders. Indexing it would produce matches in
  /// invisible bytes and inflate the count. nil when the segment renders no body at all.
  public var findableText: String? {
    switch self {
    case .markdown(let text):
      return text.isEmpty ? nil : text
    case .callout(let callout):
      // The tagName renders as chrome beside a localized severity label, not as prose.
      return callout.body.isEmpty ? nil : callout.body
    case .harness(let block):
      guard let body = block.kind.displayBody, !body.isEmpty else { return nil }
      return body
    }
  }
}
```

- [ ] **Step 4: Run the tests and build the app**

Run: `./scripts/test.sh --filter FindableText`
Expected: PASS (6 tests).

Run: `xcodegen generate && xcodebuild -project Pensieve.xcodeproj -scheme Pensieve -configuration Debug -derivedDataPath ./.build-xcode build 2>&1 | tail -5`
Expected: `BUILD SUCCEEDED` — the app's `HarnessCardView` now reads the Kit `displayBody` with no code change, because the property name and semantics are identical.

- [ ] **Step 5: Commit**

```bash
git checkout -- Package.resolved 2>/dev/null || true
git add Sources/PensieveKit/Transcript/TranscriptSegment.swift \
  Sources/PensieveApp/TranscriptSegmentView.swift Tests/PensieveKitTests/FindableTextTests.swift
git commit -m "refactor(kit): one definition of a segment's displayed text, now findable"
```

---

### Task 7: `ProvenanceQueries` session-taking overload

**Files:**
- Modify: `Sources/PensieveKit/Query/ProvenanceQueries.swift:24-61`
- Test: `Tests/PensieveKitTests/ProvenanceSessionOverloadTests.swift`

**Interfaces:**
- Produces: `ProvenanceQueries.context(session: ParsedSession, looseEnd: LooseEnd, event: Event, radius: Int = 4) -> ProvenanceContext`; the existing `context(_ database:looseEnd:radius:)` becomes a wrapper over it.
- Consumes: `ParsedSession`, `TranscriptMessage` (existing).

**Why:** the batch loader must not own a second copy of the two-part guard
(`citedMessage.isUserPrompt` + normalized-quote `contains`) — that guard is the reason this surface
can claim it never highlights a wrong message. One definition, two callers.

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/PensieveKitTests/ProvenanceSessionOverloadTests.swift
import Foundation
import Testing
@testable import PensieveKit

private func message(_ index: Int, _ role: String, _ text: String, isUserPrompt: Bool) -> TranscriptMessage {
  TranscriptMessage(index: index, role: role, text: text, timestamp: nil, isUserPrompt: isUserPrompt)
}

private func session(_ messages: [TranscriptMessage]) -> ParsedSession {
  ParsedSession(sessionID: "s1", cwd: nil, startedAt: nil, endedAt: nil, messages: messages)
}

private func looseEnd(quote: String, messageIndex: Int) -> LooseEnd {
  LooseEnd(id: UUID(), nodeID: UUID(), sourceEventID: UUID(), text: "an end", quote: quote,
           status: "open", createdAt: Date(), role: "typed", sourceMessageIndex: messageIndex,
           label: "", labelSuggestion: "")
}

private func event() -> Event {
  Event(id: UUID(), nodeID: UUID(), sourceID: nil, kind: "cc.session", summary: "a session",
        detailJSON: "{}", occurredAt: Date(), externalID: "s1")
}

@Test func slicesTheWindowAroundTheCitedMessage() {
  let messages = (0..<10).map { message($0, $0 == 5 ? "user" : "assistant", "text \($0)",
                                        isUserPrompt: $0 == 5) }
  let context = ProvenanceQueries.context(session: session(messages),
                                          looseEnd: looseEnd(quote: "text 5", messageIndex: 5),
                                          event: event(), radius: 2)
  #expect(context.transcriptAvailable)
  #expect(context.messages.map(\.index) == [3, 4, 5, 6, 7])
  #expect(context.messages.first { $0.isCited }?.index == 5)
}

@Test func aCitedMessageThatIsNotAUserPromptDegradesHonestly() {
  // Half of the two-part guard. Shared with the one-shot path — this test is what pins it shared.
  let messages = [message(0, "assistant", "text 0", isUserPrompt: false)]
  let context = ProvenanceQueries.context(session: session(messages),
                                          looseEnd: looseEnd(quote: "text 0", messageIndex: 0),
                                          event: event())
  #expect(!context.transcriptAvailable)
  #expect(context.messages.isEmpty)
}

@Test func aQuoteThatNoLongerAppearsDegradesHonestly() {
  let messages = [message(0, "user", "the message changed", isUserPrompt: true)]
  let context = ProvenanceQueries.context(session: session(messages),
                                          looseEnd: looseEnd(quote: "a quote since edited away",
                                                             messageIndex: 0),
                                          event: event())
  #expect(!context.transcriptAvailable)
}

@Test func quoteWhitespaceIsNormalizedBeforeComparison() {
  let messages = [message(0, "user", "we should  fix\nthe sync gap", isUserPrompt: true)]
  let context = ProvenanceQueries.context(session: session(messages),
                                          looseEnd: looseEnd(quote: "we should fix the sync gap",
                                                             messageIndex: 0),
                                          event: event())
  #expect(context.transcriptAvailable)
}

@Test func anUnknownMessageIndexDegradesHonestly() {
  let messages = [message(0, "user", "text", isUserPrompt: true)]
  let context = ProvenanceQueries.context(session: session(messages),
                                          looseEnd: looseEnd(quote: "text", messageIndex: 99),
                                          event: event())
  #expect(!context.transcriptAvailable)
}
```

> Check `ParsedSession`'s memberwise initializer in `Sources/PensieveKit/Transcript/ParsedSession.swift`
> before writing the helper — it has more fields than `messages` and the labels must match exactly.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `./scripts/test.sh --filter ProvenanceSessionOverload`
Expected: FAIL — no `context(session:looseEnd:event:radius:)` overload.

- [ ] **Step 3: Split `context` into a session-taking core and a one-shot wrapper**

In `Sources/PensieveKit/Query/ProvenanceQueries.swift`, restructure so lines 41-60's logic lives in
the new overload and the existing entry point calls it. **Move the guard verbatim — do not retype it.**

```swift
  /// The one-shot path: resolve the event, read the transcript, then slice. Unchanged behavior.
  public static func context(_ database: any DatabaseReader, looseEnd: LooseEnd,
                             radius: Int = 4) throws -> ProvenanceContext {
    let event = try database.read { database in
      try Event.where { $0.id.eq(looseEnd.sourceEventID) }.fetchOne(database)
    }
    guard let event else { throw ProvenanceError.missingSourceEvent }
    guard let path = transcriptPath(in: event), FileManager.default.fileExists(atPath: path) else {
      return unavailable(looseEnd: looseEnd, event: event)
    }
    let session = TranscriptParser.parse(fileURL: URL(fileURLWithPath: path))
    return context(session: session, looseEnd: looseEnd, event: event, radius: radius)
  }

  /// The batch path: slice a window out of an ALREADY-PARSED session. `ProvenanceLoader` parses each
  /// transcript once and calls this per loose end, so the two-part guard below has exactly one
  /// definition — a second copy is how a wrong-provenance highlight would get shipped.
  public static func context(session: ParsedSession, looseEnd: LooseEnd, event: Event,
                             radius: Int = 4) -> ProvenanceContext {
    // Resolve by identity (index), not bare position — robust to parser-version drift.
    guard let citedPosition = session.messages.firstIndex(where: {
      $0.index == looseEnd.sourceMessageIndex
    }) else { return unavailable(looseEnd: looseEnd, event: event) }

    // Two-part guard so "never a wrong highlight" holds: the cited message must be a user prompt
    // AND still contain the stored quote. Either fails → honest fallback. Normalize both sides the
    // same way LooseEndVerifier did when it accepted the quote.
    let citedMessage = session.messages[citedPosition]
    guard citedMessage.isUserPrompt,
          normalizeWhitespace(citedMessage.text).contains(normalizeWhitespace(looseEnd.quote))
    else { return unavailable(looseEnd: looseEnd, event: event) }

    let lowerIndex = max(0, citedPosition - radius)
    let upperIndex = min(session.messages.count - 1, citedPosition + radius)
    let window = session.messages[lowerIndex...upperIndex].map {
      ProvenanceMessage(index: $0.index, role: $0.role, text: $0.text,
                        isCited: $0.index == looseEnd.sourceMessageIndex,
                        isUserPrompt: $0.isUserPrompt)
    }
    return ProvenanceContext(looseEnd: looseEnd, sourceEvent: event, messages: window,
                             transcriptAvailable: true)
  }

  /// transcriptPath lives in the cc.session detailJSON (see Ingester); decoded as [String: String].
  static func transcriptPath(in event: Event) -> String? {
    (try? JSONDecoder().decode([String: String].self, from: Data(event.detailJSON.utf8)))?["transcriptPath"]
  }

  private static func unavailable(looseEnd: LooseEnd, event: Event) -> ProvenanceContext {
    ProvenanceContext(looseEnd: looseEnd, sourceEvent: event, messages: [],
                      transcriptAvailable: false)
  }
```

- [ ] **Step 4: Run the full suite**

Run: `./scripts/test.sh --filter Provenance`
Expected: PASS — the new overload's tests **and** every pre-existing `ProvenanceQueries` /
`ProvenanceContext` test. Those existing tests are the proof the wrapper preserved behavior.

- [ ] **Step 5: Commit**

```bash
git add Sources/PensieveKit/Query/ProvenanceQueries.swift Tests/PensieveKitTests/ProvenanceSessionOverloadTests.swift
git commit -m "refactor(kit): one two-part provenance guard, two callers"
```

---

### Task 8: `ProvenanceLoader` — parse once, cache with `(size, mtime)` validation

**Files:**
- Create: `Sources/PensieveKit/Query/ProvenanceLoader.swift`
- Test: `Tests/PensieveKitTests/ProvenanceLoaderTests.swift`

**Interfaces:**
- Produces: `actor ProvenanceLoader` with
  `init(database: any DatabaseReader, cacheLimit: Int = 200)`,
  `func load(_ looseEnd: LooseEnd) async -> LoadedProvenance?`,
  `func load(all looseEnds: [LooseEnd], onProgress: @Sendable (Int, Int) -> Void) async -> [UUID: LoadedProvenance]`,
  and `struct LoadedProvenance: Sendable { let context: ProvenanceContext; let segments: [[TranscriptSegment]] }`.
- Consumes: `ProvenanceQueries.context(session:looseEnd:event:radius:)` (Task 7), `TranscriptMarkup.parse` (existing).

**Why it caches segments too:** the document's `segment` ordinal and the view's rendered segment
ordinal must be the same number. Parsing twice (once for the sweep, once in the row) lets them
disagree. `TranscriptMessageView` enumerates `segments` by offset, so sharing one parsed array makes
them equal by construction.

**Why keying on loose-end ID is safe:** `LooseEndRow.swift:26-29` warns against caching segments keyed
on `ProvenanceMessage.index`, which is per-session and collides across sessions. A loose end has
exactly one `sourceEventID`, hence one session — so this key cannot serve session A's data for
session B.

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/PensieveKitTests/ProvenanceLoaderTests.swift
import Foundation
import Testing
@testable import PensieveKit

/// Writes a minimal Claude Code JSONL transcript and returns its URL.
private func writeTranscript(_ directory: URL, name: String, userText: String) throws -> URL {
  let url = directory.appendingPathComponent("\(name).jsonl")
  let lines = [
    #"{"type":"user","message":{"role":"user","content":"\#(userText)"}}"#,
    #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"acknowledged"}]}}"#
  ]
  try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
  return url
}

@Test func parsesOneTranscriptOnceForManyLooseEndsSharingIt() async throws {
  // The pre-existing waste this closes: five rows from one session parse that file five times.
  let directory = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }

  let transcript = try writeTranscript(directory, name: "session", userText: "fix the sync gap")
  let store = try TestStore.make()                     // see note below
  let event = try store.insertSessionEvent(transcriptPath: transcript.path)
  let ends = try (0..<3).map { _ in
    try store.insertLooseEnd(sourceEventID: event.id, quote: "fix the sync gap", messageIndex: 0)
  }

  let loader = ProvenanceLoader(database: store.database, parseCounter: store.parseCounter)
  let loaded = await loader.load(all: ends, onProgress: { _, _ in })
  #expect(loaded.count == 3)
  #expect(store.parseCounter.value == 1)               // ONE parse, three windows
  #expect(loaded[ends[0].id]?.context.transcriptAvailable == true)
  #expect(loaded[ends[0].id]?.segments.count == loaded[ends[0].id]?.context.messages.count)
}

@Test func aSecondLoadOfTheSameLooseEndHitsTheCache() async throws { /* …as above, then: */ }

@Test func aChangedTranscriptInvalidatesTheCachedEntry() async throws {
  // The case the spec's first draft got wrong: a LIVE session grows while the user sits on the node.
  // Invalidation is per-entry (size, mtime), not an app refresh signal.
}

@Test func aVanishedTranscriptIsRejectedWithoutParsing() async throws {
  // 24 of 37 referenced transcripts are gone on the measured store — they must cost a stat, not a parse.
}

@Test func theCacheIsBoundedByItsLimit() async throws { /* cacheLimit: 2, load 3, expect 2 held */ }
```

> **Test-support note:** these tests need a temp canonical store with an inserted `cc.session` event
> and loose ends, plus a way to count parses. Look at
> `Tests/PensieveKitTests/LooseEndQueriesTests.swift` and `CanonicalStoreTests.swift` for the
> established temp-store helper and reuse it — do **not** invent a new one. For the parse count,
> inject a counting hook: give `ProvenanceLoader` an internal
> `init(database:cacheLimit:parse: @Sendable (URL) -> ParsedSession = TranscriptParser.parse)` seam
> and pass a counting closure in tests. Fill in the four sketched test bodies completely following
> the first test's shape — a sketched test is a plan failure, so write them out before implementing.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `./scripts/test.sh --filter ProvenanceLoader`
Expected: FAIL — `cannot find 'ProvenanceLoader' in scope`.

- [ ] **Step 3: Write `ProvenanceLoader`**

```swift
// Sources/PensieveKit/Query/ProvenanceLoader.swift
import Foundation
import SQLiteData

/// A loose end's resolved provenance: the surrounding-transcript window AND its parsed segments,
/// parallel to `context.messages`.
public struct LoadedProvenance: Sendable {
  public let context: ProvenanceContext
  /// One segment array per message in `context.messages`, same order. Shared with the view so the
  /// find document's segment ordinals and the rendered ordinals are the same numbers.
  public let segments: [[TranscriptSegment]]
}

/// Resolves provenance for loose ends, parsing each transcript at most once.
///
/// Two things it fixes at once: the sweep needs every loose end's window without parsing a 3 MB
/// JSONL per loose end, and the shipped row-expansion path re-parses the same file once per expanded
/// row. Both go through here.
public actor ProvenanceLoader {
  private let database: any DatabaseReader
  private let parse: @Sendable (URL) -> ParsedSession
  private let cacheLimit: Int

  /// A cached window, plus the file fingerprint it was sliced from. Live sessions GROW, so an entry
  /// is only served while its transcript's `(size, mtime)` is unchanged — the app's `refreshToken`
  /// would not do: it never bumps on the FSEvents watch path (`AppModel.swift:98-99`), i.e. exactly
  /// the growing-live-session case would have gone stale until ⌘R.
  private struct Entry {
    let loaded: LoadedProvenance
    let fingerprint: Fingerprint?
    var lastUsed: Int
  }

  private struct Fingerprint: Equatable {
    let size: Int
    let modified: Date
  }

  private var cache: [UUID: Entry] = [:]
  private var clock = 0

  public init(database: any DatabaseReader, cacheLimit: Int = 200) {
    self.init(database: database, cacheLimit: cacheLimit, parse: TranscriptParser.parse(fileURL:))
  }

  init(database: any DatabaseReader, cacheLimit: Int = 200,
       parse: @escaping @Sendable (URL) -> ParsedSession) {
    self.database = database
    self.cacheLimit = cacheLimit
    self.parse = parse
  }

  public func load(_ looseEnd: LooseEnd) async -> LoadedProvenance? {
    await load(all: [looseEnd], onProgress: { _, _ in })[looseEnd.id]
  }

  /// Loads every loose end's provenance, grouped by transcript path so each file is parsed once.
  /// `onProgress` reports `(pathsDone, pathsTotal)` for the find bar.
  public func load(all looseEnds: [LooseEnd],
                   onProgress: @Sendable (Int, Int) -> Void) async -> [UUID: LoadedProvenance] {
    var result: [UUID: LoadedProvenance] = [:]
    var pending: [LooseEnd] = []
    for looseEnd in looseEnds {
      if let cached = validEntry(for: looseEnd.id) {
        result[looseEnd.id] = cached
      } else {
        pending.append(looseEnd)
      }
    }
    guard !pending.isEmpty else {
      onProgress(0, 0)
      return result
    }

    // Resolve every source event in ONE read, then group by transcript path.
    let eventIDs = Set(pending.map(\.sourceEventID))
    let events = (try? database.read { database in
      try Event.where { eventIDs.contains($0.id) }.fetchAll(database)
    }) ?? []
    let eventsByID = Dictionary(uniqueKeysWithValues: events.map { ($0.id, $0) })

    var byPath: [String: [(looseEnd: LooseEnd, event: Event)]] = [:]
    for looseEnd in pending {
      guard let event = eventsByID[looseEnd.sourceEventID] else { continue }
      guard let path = ProvenanceQueries.transcriptPath(in: event) else {
        store(looseEnd.id, LoadedProvenance(context: unavailable(looseEnd, event), segments: []),
              fingerprint: nil)
        result[looseEnd.id] = cache[looseEnd.id]?.loaded
        continue
      }
      byPath[path, default: []].append((looseEnd, event))
    }

    let paths = byPath.keys.sorted()
    onProgress(0, paths.count)
    for (index, path) in paths.enumerated() {
      if Task.isCancelled { return result }
      let group = byPath[path] ?? []
      let fingerprint = self.fingerprint(ofPath: path)
      if fingerprint == nil {
        // Gone: a stat, never a parse. 24 of 37 referenced transcripts are in this state.
        for item in group {
          let loaded = LoadedProvenance(context: unavailable(item.looseEnd, item.event), segments: [])
          store(item.looseEnd.id, loaded, fingerprint: nil)
          result[item.looseEnd.id] = loaded
        }
        onProgress(index + 1, paths.count)
        continue
      }
      let session = parse(URL(fileURLWithPath: path))
      for item in group {
        let context = ProvenanceQueries.context(session: session, looseEnd: item.looseEnd,
                                                event: item.event)
        let segments = context.messages.map { TranscriptMarkup.parse($0.text) }
        let loaded = LoadedProvenance(context: context, segments: segments)
        store(item.looseEnd.id, loaded, fingerprint: fingerprint)
        result[item.looseEnd.id] = loaded
      }
      // The ParsedSession goes out of scope here: TranscriptParser builds each message's text as an
      // independent String, so the non-windowed messages are genuinely released.
      onProgress(index + 1, paths.count)
    }
    return result
  }

  private func validEntry(for looseEndID: UUID) -> LoadedProvenance? {
    guard var entry = cache[looseEndID] else { return nil }
    if let fingerprint = entry.fingerprint {
      guard let path = ProvenanceQueries.transcriptPath(in: entry.loaded.context.sourceEvent),
            self.fingerprint(ofPath: path) == fingerprint
      else { cache[looseEndID] = nil; return nil }
    }
    clock += 1
    entry.lastUsed = clock
    cache[looseEndID] = entry
    return entry.loaded
  }

  private func store(_ looseEndID: UUID, _ loaded: LoadedProvenance, fingerprint: Fingerprint?) {
    clock += 1
    cache[looseEndID] = Entry(loaded: loaded, fingerprint: fingerprint, lastUsed: clock)
    guard cache.count > cacheLimit else { return }
    let excess = cache.count - cacheLimit
    for (key, _) in cache.sorted(by: { $0.value.lastUsed < $1.value.lastUsed }).prefix(excess) {
      cache[key] = nil
    }
  }

  private func fingerprint(ofPath path: String) -> Fingerprint? {
    guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
          let size = attributes[.size] as? Int,
          let modified = attributes[.modificationDate] as? Date
    else { return nil }
    return Fingerprint(size: size, modified: modified)
  }

  private func unavailable(_ looseEnd: LooseEnd, _ event: Event) -> ProvenanceContext {
    ProvenanceContext(looseEnd: looseEnd, sourceEvent: event, messages: [],
                      transcriptAvailable: false)
  }
}
```

> If `Event.where { eventIDs.contains($0.id) }` does not compile under SQLiteData 1.6.6, fall back to
> a per-event `.where { $0.id.eq(id) }.fetchOne` loop inside a single `database.read` block — still
> one connection, and correctness beats one query.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `./scripts/test.sh --filter ProvenanceLoader`
Expected: PASS (5 tests), including `parseCounter.value == 1` for three loose ends on one transcript.

- [ ] **Step 5: Run the whole suite**

Run: `./scripts/test.sh`
Expected: all tests pass. Record the new total in the commit message.

- [ ] **Step 6: Commit**

```bash
git add Sources/PensieveKit/Query/ProvenanceLoader.swift Tests/PensieveKitTests/ProvenanceLoaderTests.swift
git commit -m "feat(kit): parse each transcript once, cache windows by file fingerprint"
```

---

### Task 9: Route the app's provenance through the loader

**Files:**
- Modify: `Sources/PensieveApp/AppModel+Recall.swift:49-55`, `Sources/PensieveApp/AppModel.swift` (the lazy loader property), `Sources/PensieveApp/LooseEndRow.swift:24-29,72-79,168-174`

**Interfaces:**
- Consumes: `ProvenanceLoader`, `LoadedProvenance` (Task 8).
- Produces: `AppModel.provenance(for:) async -> LoadedProvenance?` (return type **changes** from `ProvenanceContext?`), `AppModel.provenanceLoader`.

- [ ] **Step 1: Add the loader to `AppModel`**

In `Sources/PensieveApp/AppModel.swift`, beside the existing `lazy var searchStore`:

```swift
  /// Shared across every window and both loose-end surfaces so a transcript is parsed once, not
  /// once per expanded row. Invalidation is per-entry file-fingerprint, inside the loader.
  @ObservationIgnored lazy var provenanceLoader: ProvenanceLoader? = {
    guard let database else { return nil }
    return ProvenanceLoader(database: database)
  }()
```

- [ ] **Step 2: Rewrite `provenance(for:)`**

In `Sources/PensieveApp/AppModel+Recall.swift`:

```swift
  /// Surrounding-transcript provenance for a loose end, plus its parsed segments — resolved off the
  /// main actor (file I/O) by a shared `ProvenanceLoader`, so N rows from one session cost one parse.
  /// nil only when there is no database or the source event is missing; a present-but-unavailable
  /// transcript returns a context with `transcriptAvailable == false`.
  func provenance(for looseEnd: LooseEnd) async -> LoadedProvenance? {
    guard let provenanceLoader else { return nil }
    return await provenanceLoader.load(looseEnd)
  }
```

- [ ] **Step 3: Take segments from the loader in `LooseEndRow`**

`loadProvenance`'s type becomes `(LooseEnd) async -> LoadedProvenance?`. Replace the local parse
(`LooseEndRow.swift:72-79`) so both context and segments come from one source:

```swift
    .task(id: expanded) {
      guard expanded, context == nil else { return }
      loading = true
      let loaded = await loadProvenance(view.looseEnd)
      context = loaded?.context
      // Segments come from the loader, NOT a second TranscriptMarkup.parse here: the find document
      // indexes these exact arrays by position, so a separate parse could disagree about ordinals.
      parsed = loaded?.segments ?? []
      loading = false
    }
```

Update the stale comment at `LooseEndRow.swift:26-29` — the "deliberately NOT a shared cache" warning
was about caching keyed on the per-session `ProvenanceMessage.index`; the loader keys on loose-end ID,
which cannot collide across sessions. Say that, rather than deleting the reasoning.

- [ ] **Step 4: Build, smoke, eyeball**

Run Task 4's Step 7/8 commands. Then:
- Expand a loose end with a live transcript → the window renders as before.
- Expand a second loose end from the *same* session → renders immediately (cache hit).
- Expand a loose end whose transcript is gone → the stored quote plus the honest note, as before.

- [ ] **Step 5: Commit**

```bash
git checkout -- Package.resolved 2>/dev/null || true
git add Sources/PensieveApp/AppModel.swift Sources/PensieveApp/AppModel+Recall.swift \
  Sources/PensieveApp/LooseEndRow.swift
git commit -m "fix(app): one transcript parse per session, shared across rows and windows"
```

---

## Phase 4 — Transcripts in the document

### Task 10: Transcript units, filled in place

**Files:**
- Modify: `Sources/PensieveKit/Query/NodeFindDocument.swift`
- Test: `Tests/PensieveKitTests/NodeFindDocumentTests.swift` (extend)

**Interfaces:**
- Produces: `NodeFindDocument.units(from: LoadedProvenance, looseEndID: UUID) -> [FindUnit]` — the one place that turns a loaded window into findable units, so the app cannot invent its own anchors.
- Consumes: `LoadedProvenance` (Task 8), `TranscriptSegment.findableText` (Task 6).

- [ ] **Step 1: Write the failing tests**

```swift
// Append to Tests/PensieveKitTests/NodeFindDocumentTests.swift

@Test func transcriptUnitsCarryMessageIndexAndSegmentOrdinal() {
  let looseEndID = UUID()
  let messages = [
    ProvenanceMessage(index: 4, role: "user", text: "fix the sync gap", isCited: true,
                      isUserPrompt: true),
    ProvenanceMessage(index: 5, role: "assistant", text: "on it", isCited: false,
                      isUserPrompt: false)
  ]
  let loaded = LoadedProvenance(
    context: ProvenanceContext(looseEnd: makeLooseEndView(text: "t", quote: "q").looseEnd,
                               sourceEvent: makeEvent(summary: "s"), messages: messages,
                               transcriptAvailable: true),
    segments: [[.markdown("fix the sync gap")], [.markdown("on it")]])
  let units = NodeFindDocument.units(from: loaded, looseEndID: looseEndID)
  #expect(units.count == 2)
  #expect(units[0].anchor == .transcriptSegment(looseEndID: looseEndID, messageIndex: 4, segment: 0))
  #expect(units[0].text == "fix the sync gap")
  #expect(units[1].anchor == .transcriptSegment(looseEndID: looseEndID, messageIndex: 5, segment: 0))
}

@Test func segmentsWithNoFindableTextContributeNoUnit() {
  let looseEndID = UUID()
  let messages = [ProvenanceMessage(index: 1, role: "user", text: "x", isCited: true,
                                    isUserPrompt: true)]
  let loaded = LoadedProvenance(
    context: ProvenanceContext(looseEnd: makeLooseEndView(text: "t", quote: "q").looseEnd,
                               sourceEvent: makeEvent(summary: "s"), messages: messages,
                               transcriptAvailable: true),
    segments: [[.harness(HarnessBlock(kind: .interrupted, raw: "[Request interrupted")),
                .markdown("real prose")]])
  let units = NodeFindDocument.units(from: loaded, looseEndID: looseEndID)
  #expect(units.count == 1)
  // Segment ORDINAL is the position in the rendered array — 1, not 0 — because the view enumerates
  // the same array by offset. Renumbering here would scroll to the wrong segment.
  #expect(units[0].anchor == .transcriptSegment(looseEndID: looseEndID, messageIndex: 1, segment: 1))
}

@Test func anUnavailableTranscriptYieldsNoUnitsSoTheCallerFallsBackToTheQuote() {
  let loaded = LoadedProvenance(
    context: ProvenanceContext(looseEnd: makeLooseEndView(text: "t", quote: "q").looseEnd,
                               sourceEvent: makeEvent(summary: "s"), messages: [],
                               transcriptAvailable: false),
    segments: [])
  #expect(NodeFindDocument.units(from: loaded, looseEndID: UUID()).isEmpty)
}
```

- [ ] **Step 2: Run to verify failure**

Run: `./scripts/test.sh --filter NodeFindDocument`
Expected: FAIL — no `units(from:looseEndID:)`.

- [ ] **Step 3: Implement**

```swift
extension NodeFindDocument {
  /// Turns a loaded provenance window into findable units. The ONE place transcript anchors are
  /// minted, so the app cannot invent an ordinal the view doesn't render.
  ///
  /// `segment` is the index in the message's FULL segment array — the same array
  /// `TranscriptMessageView` enumerates by offset. Segments with no displayed text are skipped but
  /// do NOT shift their neighbours' ordinals.
  public static func units(from loaded: LoadedProvenance, looseEndID: UUID) -> [FindUnit] {
    guard loaded.context.transcriptAvailable else { return [] }
    var units: [FindUnit] = []
    for (position, message) in loaded.context.messages.enumerated() {
      guard position < loaded.segments.count else { continue }
      for (ordinal, segment) in loaded.segments[position].enumerated() {
        guard let text = segment.findableText else { continue }
        units.append(FindUnit(anchor: .transcriptSegment(looseEndID: looseEndID,
                                                         messageIndex: message.index,
                                                         segment: ordinal),
                              text: text))
      }
    }
    return units
  }
}
```

- [ ] **Step 4: Run to verify pass, then commit**

Run: `./scripts/test.sh --filter NodeFindDocument`
Expected: PASS (12 tests).

```bash
git add Sources/PensieveKit/Query/NodeFindDocument.swift Tests/PensieveKitTests/NodeFindDocumentTests.swift
git commit -m "feat(kit): transcript units keep the view's segment ordinals"
```

---

### Task 11: The sweep + reaching a collapsed transcript match

**Files:**
- Modify: `Sources/PensieveApp/NodeFindState.swift`, `Sources/PensieveApp/DetailView.swift`, `Sources/PensieveApp/LooseEndRow.swift`

**Interfaces:**
- Consumes: `ProvenanceLoader.load(all:onProgress:)` (Task 8), `NodeFindDocument.units(from:looseEndID:)` / `.fill` / `.fillWithQuoteFallback` / `.unresolvedLooseEndIDs` (Tasks 2, 10).
- Produces: `NodeFindState.startSweep(looseEnds:loader:)`; `LooseEndRow` honors `find.forcedExpansions` and always opens "Show more" for a find target.

- [ ] **Step 1: Add the sweep to `NodeFindState`**

```swift
  /// Loads every unresolved loose end's provenance and fills its document slot in place. Streams:
  /// the count grows as sessions resolve, shown as progress. Carries the generation it started in,
  /// so a sweep for the previous node cannot write into this one.
  @MainActor
  func startSweep(looseEnds: [LooseEndView], loader: ProvenanceLoader?) {
    guard let loader, isPresented else { return }
    let unresolved = Set(document.unresolvedLooseEndIDs)
    let pending = looseEnds.filter { unresolved.contains($0.looseEnd.id) }
    guard !pending.isEmpty else { return }
    let startedGeneration = generation
    cancelSweep()
    sweepTask = Task { [weak self] in
      let loaded = await loader.load(all: pending.map(\.looseEnd)) { done, total in
        Task { @MainActor [weak self] in
          guard let self, self.generation == startedGeneration else { return }
          self.noteSweepProgress(done: done, total: total)
        }
      }
      await MainActor.run { [weak self] in
        guard let self, self.generation == startedGeneration else { return }
        var document = self.document
        for view in pending {
          let looseEndID = view.looseEnd.id
          let units = loaded[looseEndID].map {
            NodeFindDocument.units(from: $0, looseEndID: looseEndID)
          } ?? []
          if units.isEmpty {
            // Transcript gone or guarded out — the row shows the stored quote, so index that.
            document.fillWithQuoteFallback(looseEndID: looseEndID, quote: view.looseEnd.quote)
          } else {
            document.fill(looseEndID: looseEndID, units: units)
          }
        }
        self.document = document
        self.updateDocument(document)
      }
    }
  }
```

This needs `NodeFindState` to hold the document: add `private(set) var document: NodeFindDocument`
set in `reset(nodeID:document:)` and in `updateDocument(_:)`.

- [ ] **Step 2: Start the sweep when the bar opens**

In `DetailView`, after the `VStack`'s `.focusedSceneValue(find)`:

```swift
    .onChange(of: find.isPresented) { _, presented in
      if presented { find.startSweep(looseEnds: looseEnds, loader: model.provenanceLoader) }
    }
```

- [ ] **Step 3: Honor find-driven expansion in `LooseEndRow`**

`LooseEndRow` already expands on `expandedLooseEndID`. Add the per-window find channel — **alongside**
the app-wide property, never replacing it, or a find in the main window would expand rows in every
recall window:

```swift
    .onChange(of: find?.forcedExpansions.contains(view.looseEnd.id) ?? false) { _, forced in
      guard forced else { return }
      expanded = true
      // ALWAYS open "Show more" for a find target: the collapsed preview renders ONE segment
      // (skipping every .harness) under lineLimit(3), so a match in any other segment — or past
      // three lines of the first — has no site to scroll to.
      provenanceExpanded = true
    }
    .onAppear {
      if find?.forcedExpansions.contains(view.looseEnd.id) == true {
        expanded = true
        provenanceExpanded = true
      }
    }
```

Merge this with the existing `.onAppear` at `LooseEndRow.swift:80` rather than adding a second one.

- [ ] **Step 4: Anchor the transcript segments**

In `Sources/PensieveApp/TranscriptMessageView.swift`, the `ForEach` over segments takes the anchor and
highlight per segment. Add two parameters:

```swift
  /// Per-segment find state, keyed by segment ordinal. Empty when find is closed or not matching.
  var highlights: [Int: SegmentHighlight] = [:]
  /// Builds the anchor for a segment ordinal, when this message participates in find.
  var anchorForSegment: ((Int) -> FindAnchor)?
  var find: NodeFindState?
```

```swift
        ForEach(Array(segments.enumerated()), id: \.offset) { ordinal, segment in
          let anchored = anchorForSegment?(ordinal)
          TranscriptSegmentView(segment: segment, highlight: highlights[ordinal])
            .modifier(OptionalFindSite(anchor: anchored, find: find))
        }
```

```swift
/// Applies `.findSite` only when this segment participates in find, so non-find surfaces (the middle
/// column, Review Suggestions) keep their current view identity.
private struct OptionalFindSite: ViewModifier {
  let anchor: FindAnchor?
  let find: NodeFindState?
  func body(content: Content) -> some View {
    if let anchor { content.findSite(anchor, find) } else { content }
  }
}
```

In `LooseEndRow.messageRow`, build both:

```swift
  @ViewBuilder private func messageRow(_ msg: ProvenanceMessage, showsRole: Bool) -> some View {
    let segments = segments(for: msg)
    TranscriptMessageView(message: msg, segments: segments, compact: compact,
                          showsRoleLabel: showsRole,
                          highlights: highlights(for: msg, segments: segments),
                          anchorForSegment: { ordinal in
                            .transcriptSegment(looseEndID: view.looseEnd.id,
                                               messageIndex: msg.index, segment: ordinal)
                          },
                          find: find)
  }

  /// Highlight runs per segment ordinal — only for segments that actually match.
  private func highlights(for msg: ProvenanceMessage,
                          segments: [TranscriptSegment]) -> [Int: SegmentHighlight] {
    guard let find else { return [:] }
    var result: [Int: SegmentHighlight] = [:]
    for (ordinal, segment) in segments.enumerated() {
      guard let text = segment.findableText else { continue }
      let anchor = FindAnchor.transcriptSegment(looseEndID: view.looseEnd.id,
                                                messageIndex: msg.index, segment: ordinal)
      let runs = find.runs(for: anchor, text: text)
      guard !runs.isEmpty else { continue }
      result[ordinal] = SegmentHighlight(runs: runs, currentOffset: find.currentOffset(in: anchor))
    }
    return result
  }
```

`previewRow` passes neither highlights nor anchors — a find target always opens "Show more", so the
preview is never a navigation target.

- [ ] **Step 5: Build, smoke, eyeball**

Run Task 4's Step 7/8 commands. Then the load-bearing check — **this is the C1 case the first draft
got wrong**:

- Open a node with a loose end whose transcript is live. Collapse every row. ⌘F a phrase that appears
  only *inside* that transcript window, several segments deep.
- Expected: the count includes it; ⌘G to it expands the row, opens Show more, and **scrolls to that
  segment**. It must not scroll to nothing.
- Expected: the bar shows "searching transcripts N/M" briefly while the sweep runs.
- Open the same node in a ⌘⌥N recall window; find in the main window. The recall window's rows must
  **not** expand.

- [ ] **Step 6: Commit**

```bash
git checkout -- Package.resolved 2>/dev/null || true
git add Sources/PensieveApp/NodeFindState.swift Sources/PensieveApp/DetailView.swift \
  Sources/PensieveApp/LooseEndRow.swift Sources/PensieveApp/TranscriptMessageView.swift
git commit -m "feat(app): find reaches transcript matches behind collapsed rows"
```

---

### Task 12: Flatten-on-match rendering

**Files:**
- Modify: `Sources/PensieveApp/TranscriptSegmentView.swift:8-21`

**Interfaces:**
- Produces: `SegmentHighlight` (`runs: [FindRun]`, `currentOffset: Int?`), `TranscriptSegmentView(segment:highlight:)`.
- Consumes: `HighlightedText` (Task 5).

**The accepted trade-off** (spec §Decisions 2): MarkdownUI 2.4.1 cannot style a substring inside a
rendered block — `InlineNode`, `BlockNode` and `MarkdownContent.blocks` are all `internal`. So a
matched segment renders as plain highlighted text and its raw syntax shows until the bar closes.
Unmatched segments are untouched.

- [ ] **Step 1: Add the highlight parameter**

```swift
/// A matched segment's highlight runs, plus which match is current.
struct SegmentHighlight {
  let runs: [FindRun]
  let currentOffset: Int?
}

struct TranscriptSegmentView: View {
  let segment: TranscriptSegment
  /// Non-nil only while a find is open AND this segment matches. When set, the segment renders as
  /// plain highlighted text instead of Markdown: MarkdownUI 2.4.1 exposes no way to style a
  /// substring inside a rendered block (its AST types are internal), so this is the only way to
  /// highlight the phrase in place. The cost is visible raw syntax until the find bar closes.
  var highlight: SegmentHighlight?

  var body: some View {
    if let highlight {
      HighlightedText(runs: highlight.runs, currentOffset: highlight.currentOffset)
        .transcriptProse()
    } else {
      unhighlighted
    }
  }

  @ViewBuilder private var unhighlighted: some View {
    switch segment {
    case .markdown(let text):
      Markdown(text).transcriptProse()
    case .callout(let callout):
      CalloutView(callout: callout)
    case .harness(let block):
      HarnessCardView(block: block)
    }
  }
}
```

> `.transcriptProse()` is defined for MarkdownUI's `Markdown` view. Check whether it applies to a
> plain `View` — `grep -n "func transcriptProse" Sources/PensieveApp/TranscriptSegmentView.swift`. If
> it is `Markdown`-specific, add a sibling `View` extension applying the same font/line-spacing so a
> flattened segment keeps the transcript type scale instead of jumping to default body text.

- [ ] **Step 2: Build, smoke, eyeball**

Run Task 4's Step 7/8 commands. Then:
- ⌘F a word inside a transcript message that contains **bold** or a code fence. The matched segment
  flattens (raw syntax visible) with the phrase highlighted; sibling segments still render as
  Markdown; closing the bar restores full Markdown everywhere.
- The cited-provenance orange bar still marks the **correct** message in all three speaker classes.
- A callout segment (`<HARD-GATE>`) that matches highlights its body; its severity chrome is
  unaffected when it doesn't match.

- [ ] **Step 3: Commit**

```bash
git checkout -- Package.resolved 2>/dev/null || true
git add Sources/PensieveApp/TranscriptSegmentView.swift
git commit -m "feat(app): a matched transcript segment highlights in place"
```

---

### Task 13: Docs, README, and the status record

**Files:**
- Modify: `README.md:101`, `CLAUDE.md` (Status section), `CONTINUE.md`

- [ ] **Step 1: Fix the README's search sentence**

`README.md:101` currently reads "…and ⌘F search across both exact and semantic recall." Replace the
⌘F clause with: "…⌥⌘F search across the captured corpus and ⌘F find-within-a-project…".

**Do not** silently rewrite the same line's two *pre-existing* inaccuracies (semantic recall was
removed in `6737d82`; the provenance inspector was retired when provenance went inline). Note them in
the commit message as follow-ups instead — they are not this feature's scope.

- [ ] **Step 2: Add the CLAUDE.md status bullet**

Add a bullet to the Status list following the established shape: what shipped, the Kit/app split, the
load-bearing gotchas, the test count, and the spec/plan paths. It must record:
- ⌘F is now in-node find; **⌥⌘F is search-everything** (the muscle-memory change).
- `FindMatcher` is the single definition of Pensieve's compare options; `SnippetMaker` reads it.
- `ProvenanceQueries` has one two-part guard with two callers; `ProvenanceLoader` parses each
  transcript once and invalidates on `(size, mtime)` — **not** `refreshToken`, which never bumps on
  the watch path.
- The find document respects `showsLooseEnds`, and a slot resolves to transcript units **XOR** the
  quote.
- Flatten-on-match is a deliberate trade-off forced by MarkdownUI's internal AST.
- The measured reality: 18 of 122 open loose ends on the `Pensieve` node have a live transcript.

- [ ] **Step 3: Record the human-verify carries in CONTINUE.md**

List the eyeball items that need the built app at `/Applications` with the real store: the collapsed-
transcript navigation case; cross-window non-contamination; the three shipped `scrollTo(UUID)`
landings still working; German in situ (including the two interpolated format strings); Edit ▸ Find
placement.

- [ ] **Step 4: Run the full suite and commit**

Run: `./scripts/test.sh`
Expected: all pass. Put the total in the commit message.

```bash
git add README.md CLAUDE.md CONTINUE.md
git commit -m "docs: in-node find shipped — ⌘F is local, ⌥⌘F is global"
```

---

## Self-Review

**Spec coverage.** Every spec section maps to a task: prior art / keybindings → Task 4; decision 2
(flatten) → Task 12; decision 5 (matching) → Task 1; §Kit kernel → Tasks 1-3, 6, 10; §Document scope
gates 1-3 → Task 2 (`showsLooseEnds`, narration) and Tasks 2+11 (quote XOR transcript); §Provenance
loading → Tasks 7-9; §Slot-fill ordering + identity → Tasks 2, 3, 11; §Reaching a match → Tasks 5, 11;
§App layer → Tasks 4, 5, 11, 12; §Localization + README → Tasks 4, 13; §Testing → each task's test
step. **Gap accepted deliberately:** the spec's `ProvenanceLoader` LRU bound and cancel-on-query-change
are implemented but only the bound is unit-tested; cancellation is covered by the generation guard and
eyeballed, because a deterministic test for it would need a fake clock the codebase does not have.

**Placeholders.** Task 8's Step 1 contains four *sketched* test bodies with an explicit instruction to
write them out before implementing, plus a pointer to the existing temp-store helper. That is the one
place this plan asks the implementer to author test code from a described behavior rather than copy it
— it is called out rather than hidden, because inventing a second temp-store helper would be worse
than reusing the established one. Every other code step is complete.

**Type consistency.** `LoadedProvenance` (Task 8) is the return type of `AppModel.provenance` (Task 9)
and the input to `NodeFindDocument.units(from:looseEndID:)` (Task 10) — consistent. `SegmentHighlight`
is produced in Task 11 (`LooseEndRow.highlights`) and consumed in Task 12
(`TranscriptSegmentView.highlight`) — consistent, and Task 11 is written first so the type exists when
Task 12 lands. `FindRun` flows from Task 1 through `HighlightedText` (Task 5) to `SegmentHighlight`.
`NodeFindState.document` is introduced in Task 4 and read by Task 11's sweep — Task 11's Step 1 says
so explicitly. `find.runs(for:text:)` keeps the same signature at all three call sites (Tasks 5, 11).
