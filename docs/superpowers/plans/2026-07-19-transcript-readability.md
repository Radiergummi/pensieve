# Transcript Readability Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Render Claude Code transcript windows in the inline provenance view as readable chat — speaker-classified messages, recognised harness envelopes, callouts, and a calm type scale — instead of a flat list of raw-tagged text.

**Architecture:** Two sequenced parts at the Kit/app seam. **Part 1** adds a pure, tested PensieveKit parser (`TranscriptMarkup`) that turns one message's text into `[TranscriptSegment]`, plus a two-member `TranscriptVocabulary` that shares tag knowledge with `TranscriptParser.isInjectedOrCommand` **without** giving the renderer a write path into the trust gate. **Part 2** rewrites `LooseEndRow`'s two render paths over those segments — thin views, no logic. Part 2 depends on Part 1 being merged and green.

**Tech Stack:** Swift 6, Swift Testing (`@Test`/`#expect`), SwiftUI, MarkdownUI 2.4.1 (xcodebuild-only dependency), XcodeGen + Xcode 26.6.

**Spec:** `docs/superpowers/specs/2026-07-19-transcript-readability-design.md`

## Global Constraints

- **The trust gate is untouched.** `TranscriptVocabulary.injectionMarkers` must stay byte-identical to today's `isInjectedOrCommand` marker list. It gates `isUserPrompt`, which gates `LooseEndExtractor.swift:42` and `LooseEndVerifier.swift:28`. Changing it is out of scope for this feature.
- **Kit is tested; the app is not.** All logic lives in `Sources/PensieveKit/`; `Sources/PensieveApp/` stays thin. App verification is `xcodebuild` + smoke launch + the eyeball matrix in Task 8.
- **Test baseline is 465** (`./scripts/test.sh`, measured on `main` 2026-07-19). Part 1 adds ~28.
- **Chrome is localized; content is not.** Severity labels, harness block labels, and role display names are chrome → String Catalog. Tag names, message text, quotes, command names, and task summaries are content → verbatim, unlocalized.
- **No Python, ever.** Swift only.
- **SQLiteData predicates use `.eq(x)`, not `== x`** (not expected to arise here — no store changes).
- Run tests with `./scripts/test.sh` (optionally `--filter <name>`).
- Build the app with `xcodegen generate` then `xcodebuild -project Pensieve.xcodeproj -scheme Pensieve -configuration Debug -derivedDataPath ./.build-xcode build`.

## Deviations from the spec (decided here, with rationale)

Three spec sketches don't survive contact with the compiler or with MarkdownUI. Resolved as follows:

1. **`HarnessBlock` becomes a struct wrapping a kind enum.** The spec writes `public enum HarnessBlock { … public var raw: String { … } }`, but a Swift enum cannot store `raw` per case without threading it through every associated-value list. `HarnessBlock { kind: HarnessKind, raw: String }` gives every case `raw` for free and keeps I2 executable.
2. **`TaskNotificationBlock` drops its own `raw`.** The enclosing `HarnessBlock.raw` already covers the same span; two `raw`s for one span is a DRY violation and an invariant that could disagree with itself.
3. **Suppressed placeholders are backslash-escaped, not left bare.** The spec suppresses the `<NAME>` → `` `NAME` `` rewrite after an identifier char / `(` / `[` so `Optional<NSError>` survives. But left bare, `<NSError>` is valid CommonMark *raw HTML* and MarkdownUI will swallow it — the reader loses the text entirely, which is worse than the bug being fixed. Suppressed placeholders emit `Optional\<NSError\>` instead: inert, visible, no code span. Pinned by test in Task 4.

---

## File Structure

**Part 1 — PensieveKit (new + one edit):**

| File | Responsibility |
|---|---|
| `Sources/PensieveKit/Transcript/TranscriptVocabulary.swift` | **New.** The two-member vocabulary. The only shared surface between rendering and the trust gate. |
| `Sources/PensieveKit/Transcript/TranscriptSegment.swift` | **New.** The segment/callout/harness types + severity mapping. Pure data + one pure function. |
| `Sources/PensieveKit/Transcript/TranscriptMarkup.swift` | **New.** The scanner. One responsibility: `String` → `[TranscriptSegment]`. |
| `Sources/PensieveKit/Transcript/TranscriptParser.swift` | **Modify** `isInjectedOrCommand` only — inline list → `TranscriptVocabulary.injectionMarkers`. No behavior change. |

**Part 1 tests:**

| File | Responsibility |
|---|---|
| `Tests/PensieveKitTests/TranscriptVocabularyTests.swift` | **New.** The trust-gate pinning tests. |
| `Tests/PensieveKitTests/TranscriptMarkupTests.swift` | **New.** Invariants I1–I5, guards, severity, harness parsing. |

**Part 2 — PensieveApp (all thin):**

| File | Responsibility |
|---|---|
| `Sources/PensieveApp/TranscriptSegmentView.swift` | **New.** Renders one `TranscriptSegment` (markdown / callout / harness card) + the type scale. |
| `Sources/PensieveApp/TranscriptMessageView.swift` | **New.** Speaker classification → one message's container (bubble or strip) + cited highlight. |
| `Sources/PensieveApp/LooseEndRow.swift` | **Modify.** `messageRow` + `previewRow` delegate to the two views above; gains `compact: Bool`. |
| `Sources/PensieveApp/ContentListView.swift:145,160` | **Modify.** Pass `compact: true`. |
| `Sources/PensieveApp/DetailView.swift:67` | **Modify.** Pass `compact: false`. |
| `Sources/PensieveApp/Localizable.xcstrings` | **Modify.** Chrome keys, en + de, hand-authored. |

---

## Task 1: `TranscriptVocabulary` — the two-member split

The trust-gate-adjacent task. It goes first, alone, and changes no behavior.

**Files:**
- Create: `Sources/PensieveKit/Transcript/TranscriptVocabulary.swift`
- Modify: `Sources/PensieveKit/Transcript/TranscriptParser.swift:81-92`
- Test: `Tests/PensieveKitTests/TranscriptVocabularyTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `TranscriptVocabulary.harnessTagNames: [String]`, `TranscriptVocabulary.injectionMarkers: [String]`, `TranscriptVocabulary.gateExemptTagNames: Set<String>`.

- [ ] **Step 1: Write the failing tests**

Create `Tests/PensieveKitTests/TranscriptVocabularyTests.swift`:

```swift
import Foundation
import Testing
@testable import PensieveKit

/// The trust-gate pin. `injectionMarkers` feeds `isInjectedOrCommand` → `isUserPrompt` →
/// `LooseEndExtractor` and `LooseEndVerifier`. This literal is the pre-change list, copied
/// byte-for-byte. If a future rendering change edits the vocabulary, THIS fails — which is the
/// entire point of splitting the vocabulary into two members.
@Test func injectionMarkersAreUnchangedFromTheTrustGateBaseline() {
  #expect(TranscriptVocabulary.injectionMarkers == [
    "<command-name>", "<command-message>", "<command-args>",
    "<local-command-stdout>", "<local-command-stderr>",
    "<bash-input>", "<bash-stdout>", "<system-reminder>",
    "<task-notification>", "</tool_uses>", "<subagent",
    "[Request interrupted",
    "Base directory for this skill:",
    "Caveat: The messages below were generated by the user while running local commands",
  ])
}

/// Every renderable harness tag is either gated by an exact `<tag>` marker or explicitly
/// documented as exempt. Adding a tag to `harnessTagNames` without deciding its gate status
/// fails here rather than silently widening or narrowing extraction.
@Test func everyHarnessTagNameHasAnExplicitGateDecision() {
  for name in TranscriptVocabulary.harnessTagNames {
    let gated = TranscriptVocabulary.injectionMarkers.contains("<\(name)>")
    let exempt = TranscriptVocabulary.gateExemptTagNames.contains(name)
    #expect(gated || exempt, "harness tag '\(name)' has no gate decision")
  }
}

/// Exemptions must be real tags, not typos that would silently excuse a missing gate entry.
@Test func gateExemptionsReferenceRealHarnessTags() {
  for name in TranscriptVocabulary.gateExemptTagNames {
    #expect(TranscriptVocabulary.harnessTagNames.contains(name), "stale exemption '\(name)'")
  }
}

/// Tag names are bare — the scanner builds `<name>` / `</name>` itself.
@Test func harnessTagNamesCarryNoAngleBrackets() {
  for name in TranscriptVocabulary.harnessTagNames {
    #expect(!name.contains("<") && !name.contains(">"))
  }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `./scripts/test.sh --filter TranscriptVocabulary`
Expected: FAIL — `cannot find 'TranscriptVocabulary' in scope`.

- [ ] **Step 3: Write the implementation**

Create `Sources/PensieveKit/Transcript/TranscriptVocabulary.swift`:

```swift
import Foundation

/// The shared harness-tag vocabulary — deliberately **two members, not one list**.
///
/// `injectionMarkers` feeds `TranscriptParser.isInjectedOrCommand`, which gates `isUserPrompt`,
/// which gates what is eligible to become a loose end at all (`LooseEndExtractor`) and what the
/// trust gate will verify (`LooseEndVerifier`). `harnessTagNames` feeds the renderer
/// (`TranscriptMarkup`).
///
/// A single shared list would be wrong twice over. The shapes differ — the gate matches a closing
/// tag (`</tool_uses>`), a prefix (`<subagent`), and two prose sentences, none of which the scanner
/// can scan forward from. And a shared list would let a tag added for **display** silently change
/// **extraction**. Keeping them separate, with `TranscriptVocabularyTests` pinning the gate list,
/// means rendering can grow freely while the trust gate stays frozen.
public enum TranscriptVocabulary {
  /// Bare tag names the renderer recognises. The scanner composes `<name>` / `</name>` itself.
  /// Safe to extend: adding a name here changes display only.
  public static let harnessTagNames: [String] = [
    "command-name", "command-message", "command-args",
    "local-command-stdout", "local-command-stderr", "local-command-caveat",
    "bash-input", "bash-stdout",
    "system-reminder", "task-notification",
    "tool_uses", "tool_use_error",
  ]

  /// Harness tags with no exact `<tag>` entry in `injectionMarkers`, each for a recorded reason.
  /// An exemption is a statement that the gate's behavior for this tag is intentional.
  ///
  /// - `local-command-caveat`: gated upstream by its **prose** form ("Caveat: The messages
  ///   below…"), which is what Claude Code actually emits alongside the tag.
  /// - `tool_use_error`: never gated (2 occurrences in parser-visible input); it is display-only.
  /// - `tool_uses`: gated by its **closing** tag `</tool_uses>`, not its opening tag.
  public static let gateExemptTagNames: Set<String> = [
    "local-command-caveat", "tool_use_error", "tool_uses",
  ]

  /// **FROZEN — do not edit as part of a rendering change.** Substrings that mark a `type:"user"`
  /// record as machine-authored. Moved here verbatim from `TranscriptParser.isInjectedOrCommand`;
  /// `TranscriptVocabularyTests` pins the exact contents.
  public static let injectionMarkers: [String] = [
    "<command-name>", "<command-message>", "<command-args>",
    "<local-command-stdout>", "<local-command-stderr>",
    "<bash-input>", "<bash-stdout>", "<system-reminder>",
    "<task-notification>", "</tool_uses>", "<subagent",
    "[Request interrupted",
    "Base directory for this skill:",
    "Caveat: The messages below were generated by the user while running local commands",
  ]
}
```

- [ ] **Step 4: Point the trust gate at the shared constant**

In `Sources/PensieveKit/Transcript/TranscriptParser.swift`, replace the body of `isInjectedOrCommand` (keep the existing doc comment above it verbatim — it explains *why* the gate exists and is still accurate):

```swift
  private static func isInjectedOrCommand(_ text: String) -> Bool {
    TranscriptVocabulary.injectionMarkers.contains { text.contains($0) }
  }
```

- [ ] **Step 5: Run the full suite**

Run: `./scripts/test.sh`
Expected: PASS, **469 tests** (465 + 4 new). Every pre-existing extraction/verifier test still passes — this task is behavior-neutral by construction.

- [ ] **Step 6: Commit**

```bash
git add Sources/PensieveKit/Transcript/TranscriptVocabulary.swift \
        Sources/PensieveKit/Transcript/TranscriptParser.swift \
        Tests/PensieveKitTests/TranscriptVocabularyTests.swift
git commit -m 'feat(transcript): split the harness vocabulary from the trust-gate markers'
```

---

## Task 2: Segment types + severity mapping

Pure data and one pure function. No scanner yet.

**Files:**
- Create: `Sources/PensieveKit/Transcript/TranscriptSegment.swift`
- Test: `Tests/PensieveKitTests/TranscriptMarkupTests.swift` (created here, grown by Tasks 3–5)

**Interfaces:**
- Consumes: `TranscriptVocabulary` (Task 1).
- Produces: `TranscriptSegment` (`.markdown(String)`, `.callout(TranscriptCallout)`, `.harness(HarnessBlock)`, `var raw: String`); `TranscriptCallout(severity:tagName:body:raw:)`; `CalloutSeverity` (`.caution`, `.important`, `.neutral`); `HarnessBlock(kind:raw:)`; `HarnessKind`; `TaskNotificationBlock`; `CalloutSeverity.forTagName(_:) -> CalloutSeverity`.

- [ ] **Step 1: Write the failing tests**

Create `Tests/PensieveKitTests/TranscriptMarkupTests.swift`:

```swift
import Foundation
import Testing
@testable import PensieveKit

// MARK: - Severity mapping (token-based, never substring)

@Test func severityMatchesWholeTokens() {
  #expect(CalloutSeverity.forTagName("HARD-GATE") == .caution)
  #expect(CalloutSeverity.forTagName("SUBAGENT-STOP") == .caution)
  #expect(CalloutSeverity.forTagName("EXTREMELY-IMPORTANT") == .important)
}

/// The substring hazard the spec calls out: `GATE` lives inside `AUTHGW`, `STOP` inside `NON-STOP`'s
/// neighbours. Whole-token matching must not fire on either.
@Test func severityDoesNotFireOnSubstrings() {
  #expect(CalloutSeverity.forTagName("AUTHGW_RESOLVE_KEY_URL") == .neutral)
  #expect(CalloutSeverity.forTagName("NONSTOP") == .neutral)
  #expect(CalloutSeverity.forTagName("UNIMPORTANTLY") == .neutral)
}

@Test func severityTreatsDashAndUnderscoreAlike() {
  #expect(CalloutSeverity.forTagName("EXTREMELY_IMPORTANT") == .important)
  #expect(CalloutSeverity.forTagName("HARD_GATE") == .caution)
}

@Test func severityPrecedenceIsTableOrderCautionBeforeImportant() {
  // Contains both a caution token and an important token; caution wins.
  #expect(CalloutSeverity.forTagName("CRITICAL-MUST") == .caution)
}

@Test func severityFallsBackToNeutralForUnknownTags() {
  #expect(CalloutSeverity.forTagName("FUTURE-SKILL-TAG") == .neutral)
  #expect(CalloutSeverity.forTagName("") == .neutral)
}

// MARK: - `raw` reaches every case (the basis of I2)

@Test func rawRoundTripsForEverySegmentCase() {
  #expect(TranscriptSegment.markdown("hello").raw == "hello")

  let callout = TranscriptSegment.callout(
    .init(severity: .caution, tagName: "HARD-GATE", body: "stop", raw: "<HARD-GATE>stop</HARD-GATE>"))
  #expect(callout.raw == "<HARD-GATE>stop</HARD-GATE>")

  let harness = TranscriptSegment.harness(
    .init(kind: .systemReminder("note"), raw: "<system-reminder>note</system-reminder>"))
  #expect(harness.raw == "<system-reminder>note</system-reminder>")
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `./scripts/test.sh --filter TranscriptMarkup`
Expected: FAIL — `cannot find 'CalloutSeverity' in scope`.

- [ ] **Step 3: Write the implementation**

Create `Sources/PensieveKit/Transcript/TranscriptSegment.swift`:

```swift
import Foundation

/// One rendering unit of a transcript message. Every case carries `raw` — the exact source
/// substring it came from — which is what makes the no-loss invariant (I2) an executable property
/// test rather than an aspiration: `segments.map(\.raw).joined() == input`.
public enum TranscriptSegment: Equatable, Sendable {
  case markdown(String)
  case callout(TranscriptCallout)
  case harness(HarnessBlock)

  /// The exact source text this segment was parsed from.
  public var raw: String {
    switch self {
    case .markdown(let s): return s
    case .callout(let c): return c.raw
    case .harness(let h): return h.raw
    }
  }
}

/// A paired ALL-CAPS tag (`<HARD-GATE>…</HARD-GATE>`) — an emphasis envelope, rendered as a
/// severity-tinted block.
public struct TranscriptCallout: Equatable, Sendable {
  public let severity: CalloutSeverity
  /// Verbatim tag name, e.g. "HARD-GATE". **Content — never localized.**
  public let tagName: String
  /// The callout's interior, as markdown. Harness tags inside are NOT recursively parsed (I5).
  public let body: String
  public let raw: String

  public init(severity: CalloutSeverity, tagName: String, body: String, raw: String) {
    self.severity = severity; self.tagName = tagName; self.body = body; self.raw = raw
  }
}

/// Closed set → the labels are localizable chrome.
///
/// **Three cases, not six.** Parser-visible corpus counts justify no more: `HARD-GATE` 154,
/// `SUBAGENT-STOP` 1, `EXTREMELY-IMPORTANT` 1, everything else 0. `.warning` folds into `.caution`
/// (same visual register), `.tip`/`.note` into `.neutral`. Growing this enum later is additive and
/// every exhaustive `switch` becomes a compile error until handled — so grow it on evidence.
public enum CalloutSeverity: String, Equatable, Sendable {
  case caution, important, neutral

  private static let cautionTokens: Set<String> =
    ["STOP", "GATE", "CRITICAL", "DANGER", "NEVER", "WARNING", "CAUTION"]
  private static let importantTokens: Set<String> = ["IMPORTANT", "MUST", "REQUIRED"]

  /// Maps a tag name to a severity by splitting on `-`/`_` and matching **whole tokens**.
  /// Substring matching would mis-fire: `GATE` inside `AUTHGW`, `STOP` inside `NONSTOP`.
  /// Precedence is caution → important → neutral; first match wins.
  public static func forTagName(_ name: String) -> CalloutSeverity {
    let tokens = Set(
      name.split(whereSeparator: { $0 == "-" || $0 == "_" }).map { $0.uppercased() })
    if !tokens.isDisjoint(with: cautionTokens) { return .caution }
    if !tokens.isDisjoint(with: importantTokens) { return .important }
    return .neutral
  }
}

/// A machine envelope — the harness talking, not a person. A struct wrapping a kind enum so every
/// case gets `raw` without threading it through each associated-value list.
public struct HarnessBlock: Equatable, Sendable {
  public let kind: HarnessKind
  public let raw: String

  public init(kind: HarnessKind, raw: String) { self.kind = kind; self.raw = raw }
}

public enum HarnessKind: Equatable, Sendable {
  case command(name: String, message: String?, args: String?)
  case taskNotification(TaskNotificationBlock)
  case systemReminder(String)
  case commandCaveat(String)
  /// `local-command-stdout` / `local-command-stderr`.
  case commandOutput(String)
  case bashIO(input: String?, output: String?)
  case toolUses(String)
  case toolUseError(String)
  /// "[Request interrupted…"
  case interrupted
  /// "Base directory for this skill: <path>"
  case skillPreamble(path: String)
  /// An allowlisted tag whose children we don't model.
  case unknown(tag: String, body: String)
}

/// `<task-notification>`'s modelled children. Children are recognised **only inside** a matched
/// task-notification span, never at top level — `<summary>` appears 958 times against
/// task-notification's 969, i.e. it is overwhelmingly a child, but at top level it is ordinary HTML.
public struct TaskNotificationBlock: Equatable, Sendable {
  public let taskID: String?
  public let toolUseID: String?
  public let outputFile: String?
  public let status: String?
  public let summary: String?
  public let note: String?
  /// Nothing is silently dropped: unmodelled children land here.
  public let unrecognisedChildren: [String: String]

  public init(taskID: String? = nil, toolUseID: String? = nil, outputFile: String? = nil,
              status: String? = nil, summary: String? = nil, note: String? = nil,
              unrecognisedChildren: [String: String] = [:]) {
    self.taskID = taskID; self.toolUseID = toolUseID; self.outputFile = outputFile
    self.status = status; self.summary = summary; self.note = note
    self.unrecognisedChildren = unrecognisedChildren
  }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `./scripts/test.sh --filter TranscriptMarkup`
Expected: PASS, 6 tests.

- [ ] **Step 5: Commit**

```bash
git add Sources/PensieveKit/Transcript/TranscriptSegment.swift \
        Tests/PensieveKitTests/TranscriptMarkupTests.swift
git commit -m 'feat(transcript): segment types + token-based callout severity'
```

---

## Task 3: The scanner skeleton — passthrough, code protection, no-loss

The scanner recognises **no tags yet**. It establishes I1, I2, I3 — the safety floor everything else is added on top of.

**Files:**
- Create: `Sources/PensieveKit/Transcript/TranscriptMarkup.swift`
- Test: `Tests/PensieveKitTests/TranscriptMarkupTests.swift` (append)

**Interfaces:**
- Consumes: `TranscriptSegment`, `TranscriptCallout`, `HarnessBlock` (Task 2).
- Produces: `TranscriptMarkup.parse(_ input: String) -> [TranscriptSegment]`; internal `Scanner` with `flushPending()`, `atLineStart`, `consumeFencedBlock()`, `consumeIndentedCodeLine()`, `consumeInlineCode()` — Tasks 4 and 5 add cases to its main loop.

- [ ] **Step 1: Write the failing tests**

Append to `Tests/PensieveKitTests/TranscriptMarkupTests.swift`:

```swift
// MARK: - I1 passthrough

@Test func plainProseRoundTripsByteIdentical() {
  let input = "Just some prose.\n\nWith a second paragraph."
  #expect(TranscriptMarkup.parse(input) == [.markdown(input)])
}

@Test func emptyInputYieldsNoSegments() {
  #expect(TranscriptMarkup.parse("").isEmpty)
}

// MARK: - I3 code is sacred

@Test func fencedBlockContentIsNotTransformed() {
  let input = "before\n```\n<HARD-GATE>not a callout</HARD-GATE>\n```\nafter"
  #expect(TranscriptMarkup.parse(input) == [.markdown(input)])
}

@Test func fourBacktickFenceIsNotClosedByThreeBackticks() {
  let input = "````\n```\n<system-reminder>x</system-reminder>\n````"
  #expect(TranscriptMarkup.parse(input) == [.markdown(input)])
}

@Test func tildeFenceProtectsItsContent() {
  let input = "~~~\n<task-notification>x</task-notification>\n~~~"
  #expect(TranscriptMarkup.parse(input) == [.markdown(input)])
}

@Test func fenceIndentedUpToThreeSpacesStillOpens() {
  let input = "   ```\n<HARD-GATE>x</HARD-GATE>\n   ```"
  #expect(TranscriptMarkup.parse(input) == [.markdown(input)])
}

@Test func unterminatedFenceRunsToEndOfMessage() {
  let input = "text\n```\n<HARD-GATE>x</HARD-GATE>\nstill in the fence"
  #expect(TranscriptMarkup.parse(input) == [.markdown(input)])
}

/// MarkdownUI renders a 4-space-indented block as code, so transforming it would violate I3 from
/// the reader's point of view even though CommonMark calls it a different construct.
@Test func fourSpaceIndentedBlockIsProtected() {
  let input = "prose\n\n    <system-reminder>x</system-reminder>\n"
  #expect(TranscriptMarkup.parse(input) == [.markdown(input)])
}

@Test func inlineCodeSpanProtectsItsContent() {
  let input = "use `<HARD-GATE>` carefully"
  #expect(TranscriptMarkup.parse(input) == [.markdown(input)])
}

// MARK: - I2 no loss, as a property

@Test func rawJoinReconstructsTheInputForMixedContent() {
  let input = """
  Intro prose.

  ```swift
  let x = "<HARD-GATE>"
  ```

  Trailing prose with `inline <code>` in it.
  """
  let segments = TranscriptMarkup.parse(input)
  #expect(segments.map(\.raw).joined() == input)
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `./scripts/test.sh --filter TranscriptMarkup`
Expected: FAIL — `cannot find 'TranscriptMarkup' in scope`.

- [ ] **Step 3: Write the implementation**

Create `Sources/PensieveKit/Transcript/TranscriptMarkup.swift`:

```swift
import Foundation

/// Splits one transcript message into rendering segments.
///
/// **A single left-to-right scan in which the outermost construct wins.** A multi-pass pipeline
/// (harness first, then callouts) is self-contradictory: a callout containing a `<system-reminder>`
/// gets split into two unpaired fragments, both demoted to raw text, and the callout vanishes.
///
/// Precedence at each position: code → callout → harness → placeholder → orphan close → prose.
/// Tasks 4 and 5 add the middle four; this file starts with code and prose.
public enum TranscriptMarkup {
  public static func parse(_ input: String) -> [TranscriptSegment] {
    var scanner = Scanner(input)
    scanner.run()
    return scanner.out
  }
}

/// The scan state. Prose accumulates into `pending` and is flushed as one `.markdown` segment
/// whenever a non-prose construct is emitted, so consecutive prose never fragments.
struct Scanner {
  let text: String
  var i: String.Index
  var out: [TranscriptSegment] = []
  var pending = ""

  init(_ text: String) {
    self.text = text
    self.i = text.startIndex
  }

  mutating func run() {
    while i < text.endIndex {
      if atLineStart, consumeFencedBlock() { continue }
      if atLineStart, consumeIndentedCodeLine() { continue }
      if text[i] == "`", consumeInlineCode() { continue }
      // Tasks 4-5 insert callout / harness / placeholder / orphan-close handling here.
      pending.append(text[i])
      i = text.index(after: i)
    }
    flushPending()
  }

  /// Emits accumulated prose as one segment. No-op when empty, so we never emit `.markdown("")`.
  mutating func flushPending() {
    guard !pending.isEmpty else { return }
    out.append(.markdown(pending))
    pending = ""
  }

  var atLineStart: Bool {
    i == text.startIndex || text[text.index(before: i)] == "\n"
  }

  /// The line starting at `i`, excluding its newline, plus the index just past its newline.
  func line(at start: String.Index) -> (content: Substring, next: String.Index) {
    guard let nl = text[start...].firstIndex(of: "\n") else {
      return (text[start...], text.endIndex)
    }
    return (text[start..<nl], text.index(after: nl))
  }

  /// CommonMark fenced block, pinned: an opening fence is >=3 identical backticks or tildes with
  /// <=3 leading spaces; it closes only on >=N of the *same* character; an unterminated fence runs
  /// to end of message. Consumed verbatim into prose — never transformed (I3).
  mutating func consumeFencedBlock() -> Bool {
    let (first, afterFirst) = line(at: i)
    let indent = first.prefix { $0 == " " }
    guard indent.count <= 3 else { return false }
    let rest = first.dropFirst(indent.count)
    guard let fenceChar = rest.first, fenceChar == "`" || fenceChar == "~" else { return false }
    let openCount = rest.prefix { $0 == fenceChar }.count
    guard openCount >= 3 else { return false }

    pending += text[i..<afterFirst]
    var cursor = afterFirst
    while cursor < text.endIndex {
      let (l, next) = line(at: cursor)
      pending += text[cursor..<next]
      cursor = next
      let li = l.drop { $0 == " " }
      if li.prefix(while: { $0 == fenceChar }).count >= openCount,
         li.allSatisfy({ $0 == fenceChar || $0 == " " }) {
        break
      }
    }
    i = cursor
    return true
  }

  /// A 4-space-indented line. Only treated as code when it can actually start an indented block —
  /// i.e. the previous line is blank or absent — so continuation lines of a paragraph that merely
  /// happen to be indented are left as prose.
  mutating func consumeIndentedCodeLine() -> Bool {
    guard previousLineIsBlank else { return false }
    let (l, next) = line(at: i)
    guard l.hasPrefix("    ") else { return false }
    pending += text[i..<next]
    i = next
    return true
  }

  private var previousLineIsBlank: Bool {
    guard i > text.startIndex else { return true }
    let beforeNewline = text.index(before: i)          // the "\n" that put us at a line start
    guard beforeNewline > text.startIndex else { return true }
    var cursor = text.index(before: beforeNewline)
    var sawContent = false
    while true {
      if text[cursor] == "\n" { break }
      if text[cursor] != " " && text[cursor] != "\t" { sawContent = true; break }
      if cursor == text.startIndex { break }
      cursor = text.index(before: cursor)
    }
    return !sawContent
  }

  /// An inline code span: N backticks closed by exactly N backticks. Pairs left-to-right; an
  /// unbalanced trailing backtick protects nothing and is emitted as ordinary prose.
  mutating func consumeInlineCode() -> Bool {
    let openCount = text[i...].prefix { $0 == "`" }.count
    let afterOpen = text.index(i, offsetBy: openCount)
    guard afterOpen < text.endIndex else { return false }

    var cursor = afterOpen
    while cursor < text.endIndex {
      guard let tick = text[cursor...].firstIndex(of: "`") else { return false }
      let runLength = text[tick...].prefix { $0 == "`" }.count
      if runLength == openCount {
        let end = text.index(tick, offsetBy: runLength)
        pending += text[i..<end]
        i = end
        return true
      }
      cursor = text.index(tick, offsetBy: runLength)
    }
    return false
  }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `./scripts/test.sh --filter TranscriptMarkup`
Expected: PASS, 16 tests.

- [ ] **Step 5: Commit**

```bash
git add Sources/PensieveKit/Transcript/TranscriptMarkup.swift \
        Tests/PensieveKitTests/TranscriptMarkupTests.swift
git commit -m 'feat(transcript): scanner skeleton with code protection and no-loss property'
```

---

## Task 4: Callouts, placeholders, orphan closes

Adds precedence levels 2, 4, and 5. Harness tags (level 3) come in Task 5.

**Files:**
- Modify: `Sources/PensieveKit/Transcript/TranscriptMarkup.swift`
- Test: `Tests/PensieveKitTests/TranscriptMarkupTests.swift` (append)

**Interfaces:**
- Consumes: `Scanner` (Task 3), `CalloutSeverity.forTagName` (Task 2).
- Produces: `Scanner.consumeCallout()`, `Scanner.consumePlaceholderOrOrphan()`, `Scanner.tagName(at:)`.

- [ ] **Step 1: Write the failing tests**

Append to `Tests/PensieveKitTests/TranscriptMarkupTests.swift`:

```swift
// MARK: - Callouts

@Test func matchedAllCapsTagBecomesACallout() {
  let input = "<HARD-GATE>Do not skip this.</HARD-GATE>"
  #expect(TranscriptMarkup.parse(input) == [
    .callout(.init(severity: .caution, tagName: "HARD-GATE",
                   body: "Do not skip this.", raw: input))
  ])
}

@Test func calloutKeepsSurroundingProseAsSeparateSegments() {
  let input = "before <HARD-GATE>x</HARD-GATE> after"
  let segments = TranscriptMarkup.parse(input)
  #expect(segments.count == 3)
  #expect(segments.first == .markdown("before "))
  #expect(segments.last == .markdown(" after"))
  #expect(segments.map(\.raw).joined() == input)
}

/// Outermost-wins: the callout survives whole and its interior is NOT recursively parsed (I5).
/// A harness-first pipeline would split this into unpaired fragments and lose the callout.
@Test func calloutContainingAHarnessTagSurvivesWhole() {
  let input = "<HARD-GATE>read <system-reminder>this</system-reminder> first</HARD-GATE>"
  let segments = TranscriptMarkup.parse(input)
  #expect(segments.count == 1)
  guard case .callout(let c) = segments[0] else { Issue.record("not a callout"); return }
  #expect(c.tagName == "HARD-GATE")
  #expect(c.body == "read <system-reminder>this</system-reminder> first")
}

@Test func calloutPairsWithTheNearestMatchingClose() {
  let input = "<TAG>one</TAG> mid <TAG>two</TAG>"
  let segments = TranscriptMarkup.parse(input)
  #expect(segments.count == 3)
  guard case .callout(let first) = segments[0] else { Issue.record("not a callout"); return }
  #expect(first.body == "one")
}

// MARK: - I4 unmatched tolerance

@Test func unmatchedOpenBecomesAPlaceholderAndDoesNotSwallowToEndOfMessage() {
  let input = "<HARD-GATE> and then ordinary prose continues"
  let segments = TranscriptMarkup.parse(input)
  #expect(segments == [.markdown("`HARD-GATE` and then ordinary prose continues")])
}

/// Orphan closes are the commonest real shape (`</FUTURE-SKILL-TAG>` 8, `</SUBAGENT-STOP>` 2).
/// Backward pairing is forbidden — it would swallow unrelated earlier content.
@Test func orphanCloseIsInertAndNeverPairsBackwards() {
  let input = "important text </FUTURE-SKILL-TAG> more text"
  let segments = TranscriptMarkup.parse(input)
  #expect(segments == [.markdown("important text `/FUTURE-SKILL-TAG` more text")])
}

@Test func aCloseWithNoOpenDoesNotConsumeAnEarlierCallout() {
  let input = "<TAG>body</TAG> then </OTHER>"
  let segments = TranscriptMarkup.parse(input)
  guard case .callout(let c) = segments[0] else { Issue.record("not a callout"); return }
  #expect(c.body == "body")
  #expect(segments.last == .markdown(" then `/OTHER`"))
}

// MARK: - Placeholder guards

/// Swift generics in prose: these are Swift-project transcripts, so this is common, not theoretical.
/// Suppressed placeholders are backslash-escaped rather than left bare — bare `<NSError>` is valid
/// CommonMark raw HTML and MarkdownUI would swallow it, losing the text entirely.
@Test func genericsInProseAreEscapedNotCodeSpanned() {
  #expect(TranscriptMarkup.parse("Optional<NSError> is returned")
          == [.markdown("Optional\\<NSError\\> is returned")])
}

@Test func linkDestinationsDoNotGetACodeSpan() {
  #expect(TranscriptMarkup.parse("see [docs](<PROJECT>/readme)")
          == [.markdown("see [docs](\\<PROJECT\\>/readme)")])
}

@Test func placeholderAfterAnOpenParenIsSuppressed() {
  #expect(TranscriptMarkup.parse("call(<ARG>)") == [.markdown("call(\\<ARG\\>)")])
}

@Test func placeholderAfterWhitespaceIsRewritten() {
  #expect(TranscriptMarkup.parse("the <PLACEHOLDER> value")
          == [.markdown("the `PLACEHOLDER` value")])
}

/// A placeholder adjacent to existing backticks must not produce unbalanced delimiters.
@Test func placeholderAdjacentToBackticksStaysBalanced() {
  let out = TranscriptMarkup.parse("`code` <NAME> `more`")
  guard case .markdown(let s) = out[0] else { Issue.record("not markdown"); return }
  #expect(s.filter { $0 == "`" }.count % 2 == 0)
}

@Test func lowercaseUnknownTagIsNotTreatedAsAPlaceholder() {
  // Not ALL-CAPS and not allowlisted: left alone as ordinary text, escaped so it stays visible.
  #expect(TranscriptMarkup.parse("a <div> here") == [.markdown("a \\<div\\> here")])
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `./scripts/test.sh --filter TranscriptMarkup`
Expected: FAIL — callouts come back as plain `.markdown`.

- [ ] **Step 3: Write the implementation**

In `Sources/PensieveKit/Transcript/TranscriptMarkup.swift`, replace the placeholder comment in `run()`:

```swift
      // Tasks 4-5 insert callout / harness / placeholder / orphan-close handling here.
```

with:

```swift
      if text[i] == "<" {
        if consumeCallout() { continue }
        // Task 5 inserts `if consumeHarness() { continue }` here.
        if consumePlaceholderOrOrphan() { continue }
      }
```

and append these methods to `Scanner`:

```swift
  /// Parses `<NAME>` or `</NAME>` at `i`. Returns the bare name, whether it was a close tag, and
  /// the index just past `>`. Returns nil for anything that isn't a well-formed simple tag.
  func tagName(at start: String.Index) -> (name: String, isClose: Bool, end: String.Index)? {
    guard start < text.endIndex, text[start] == "<" else { return nil }
    var cursor = text.index(after: start)
    guard cursor < text.endIndex else { return nil }
    let isClose = text[cursor] == "/"
    if isClose { cursor = text.index(after: cursor) }
    guard let gt = text[cursor...].firstIndex(of: ">") else { return nil }
    let name = String(text[cursor..<gt])
    guard !name.isEmpty,
          name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" })
    else { return nil }
    return (name, isClose, text.index(after: gt))
  }

  private func isAllCaps(_ name: String) -> Bool {
    name.contains { $0.isLetter } && !name.contains { $0.isLetter && $0.isLowercase }
  }

  /// Precedence 2: a paired ALL-CAPS tag, matched forward to the NEAREST matching close in the
  /// same message. The interior is emitted as markdown only — harness tags inside are not
  /// recursively parsed (I5).
  mutating func consumeCallout() -> Bool {
    guard let open = tagName(at: i), !open.isClose, isAllCaps(open.name) else { return false }
    guard let closeRange = text.range(of: "</\(open.name)>", range: open.end..<text.endIndex)
    else { return false }

    flushPending()
    let body = String(text[open.end..<closeRange.lowerBound])
    let raw = String(text[i..<closeRange.upperBound])
    out.append(.callout(.init(severity: .forTagName(open.name),
                              tagName: open.name, body: body, raw: raw)))
    i = closeRange.upperBound
    return true
  }

  /// Precedence 4 and 5: an unmatched ALL-CAPS open, or ANY orphan close, becomes an inert
  /// monospace run. Backward pairing is forbidden — an orphan close pairing with a distant earlier
  /// open would swallow unrelated content, which is exactly what I4 exists to prevent.
  ///
  /// The rewrite is suppressed when the preceding character is an identifier char, `(`, or `[`,
  /// which kills two real hazards in one predicate: Swift generics in prose (`Optional<NSError>`)
  /// and link destinations (`[docs](<PROJECT>/readme)`). Suppressed tags are backslash-escaped
  /// rather than left bare, because bare `<NSError>` is valid CommonMark raw HTML that MarkdownUI
  /// would swallow — losing the text is worse than the bug being fixed.
  mutating func consumePlaceholderOrOrphan() -> Bool {
    guard let tag = tagName(at: i) else { return false }
    guard tag.isClose || isAllCaps(tag.name) else {
      // A lowercase, unallowlisted open tag: escape so it stays visible, don't code-span it.
      pending += "\\<\(tag.name)\\>"
      i = tag.end
      return true
    }

    if suppressRewriteAtCurrentPosition {
      pending += "\\<\(tag.isClose ? "/" : "")\(tag.name)\\>"
    } else {
      pending += "`\(tag.isClose ? "/" : "")\(tag.name)`"
    }
    i = tag.end
    return true
  }

  private var suppressRewriteAtCurrentPosition: Bool {
    guard i > text.startIndex else { return false }
    let prev = text[text.index(before: i)]
    return prev.isLetter || prev.isNumber || prev == "_" || prev == "(" || prev == "["
  }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `./scripts/test.sh --filter TranscriptMarkup`
Expected: PASS, 29 tests.

- [ ] **Step 5: Verify I2 still holds with the documented exception**

The placeholder rewrite is I2's **one** documented exception. Confirm `rawJoinReconstructsTheInputForMixedContent` still passes (its fixture contains no bare tags) — it does, because the exception only fires on placeholder/orphan input.

Run: `./scripts/test.sh --filter rawJoinReconstructs`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Sources/PensieveKit/Transcript/TranscriptMarkup.swift \
        Tests/PensieveKitTests/TranscriptMarkupTests.swift
git commit -m 'feat(transcript): callouts, placeholder guards, inert orphan closes'
```

---

## Task 5: Harness blocks

Adds precedence level 3 plus the two prose-matched kinds.

**Files:**
- Modify: `Sources/PensieveKit/Transcript/TranscriptMarkup.swift`
- Test: `Tests/PensieveKitTests/TranscriptMarkupTests.swift` (append)

**Interfaces:**
- Consumes: `Scanner`, `TranscriptVocabulary.harnessTagNames`, `HarnessBlock`, `HarnessKind`, `TaskNotificationBlock`.
- Produces: `Scanner.consumeHarness()`, `Scanner.consumeProseHarness()`.

- [ ] **Step 1: Write the failing tests**

Append to `Tests/PensieveKitTests/TranscriptMarkupTests.swift`:

```swift
// MARK: - Harness blocks

@Test func systemReminderBecomesAHarnessBlock() {
  let input = "<system-reminder>Do the thing.</system-reminder>"
  #expect(TranscriptMarkup.parse(input) == [
    .harness(.init(kind: .systemReminder("Do the thing."), raw: input))
  ])
}

@Test func theCommandTrioCollapsesIntoOneBlock() {
  let input = "<command-name>/clear</command-name>"
    + "<command-message>clear</command-message><command-args></command-args>"
  let segments = TranscriptMarkup.parse(input)
  #expect(segments.count == 1)
  guard case .harness(let h) = segments[0],
        case .command(let name, let message, let args) = h.kind
  else { Issue.record("not a command block"); return }
  #expect(name == "/clear")
  #expect(message == "clear")
  #expect(args == "")
  #expect(h.raw == input)
}

@Test func commandNameAloneStillFormsACommandBlock() {
  let input = "<command-name>/commit</command-name>"
  let segments = TranscriptMarkup.parse(input)
  guard case .harness(let h) = segments[0], case .command(let name, let m, let a) = h.kind
  else { Issue.record("not a command block"); return }
  #expect(name == "/commit")
  #expect(m == nil)
  #expect(a == nil)
}

@Test func taskNotificationChildrenAreParsed() {
  let input = "<task-notification><task-id>abc</task-id><status>done</status>"
    + "<summary>Finished the work</summary></task-notification>"
  let segments = TranscriptMarkup.parse(input)
  guard case .harness(let h) = segments[0], case .taskNotification(let t) = h.kind
  else { Issue.record("not a task notification"); return }
  #expect(t.taskID == "abc")
  #expect(t.status == "done")
  #expect(t.summary == "Finished the work")
  #expect(t.unrecognisedChildren.isEmpty)
}

@Test func unrecognisedTaskNotificationChildrenArePreservedNotDropped() {
  let input = "<task-notification><status>ok</status>"
    + "<duration_ms>1200</duration_ms></task-notification>"
  let segments = TranscriptMarkup.parse(input)
  guard case .harness(let h) = segments[0], case .taskNotification(let t) = h.kind
  else { Issue.record("not a task notification"); return }
  #expect(t.unrecognisedChildren["duration_ms"] == "1200")
}

/// `<summary>` (958) is near-1:1 with task-notification (969), i.e. overwhelmingly a child.
/// At top level it is ordinary HTML and must not be hijacked.
@Test func summaryAtTopLevelIsNotTreatedAsATaskNotificationChild() {
  let segments = TranscriptMarkup.parse("<summary>standalone</summary>")
  for segment in segments {
    if case .harness = segment { Issue.record("top-level summary became a harness block") }
  }
}

@Test func bashInputAndOutputCollapseIntoOneBlock() {
  let input = "<bash-input>ls</bash-input><bash-stdout>a.txt</bash-stdout>"
  let segments = TranscriptMarkup.parse(input)
  guard case .harness(let h) = segments[0], case .bashIO(let inp, let outp) = h.kind
  else { Issue.record("not a bashIO block"); return }
  #expect(inp == "ls")
  #expect(outp == "a.txt")
}

@Test func commandCaveatIsRecognisedInBothTagAndProseForm() {
  let tagged = TranscriptMarkup.parse("<local-command-caveat>note</local-command-caveat>")
  guard case .harness(let h) = tagged[0], case .commandCaveat = h.kind
  else { Issue.record("tag form not recognised"); return }

  let prose = TranscriptMarkup.parse(
    "Caveat: The messages below were generated by the user while running local commands")
  guard case .harness(let p) = prose[0], case .commandCaveat = p.kind
  else { Issue.record("prose form not recognised"); return }
}

@Test func interruptionNoticeIsRecognised() {
  let segments = TranscriptMarkup.parse("[Request interrupted by user]")
  guard case .harness(let h) = segments[0], case .interrupted = h.kind
  else { Issue.record("not an interruption"); return }
}

/// Anchored with `hasPrefix`, not `contains` — a mid-message mention is prose, not a preamble.
@Test func skillPreambleIsAnchoredToTheStartOfTheMessage() {
  let atStart = TranscriptMarkup.parse("Base directory for this skill: /path/to/skill")
  guard case .harness(let h) = atStart[0], case .skillPreamble(let path) = h.kind
  else { Issue.record("not a skill preamble"); return }
  #expect(path == "/path/to/skill")

  let midMessage = TranscriptMarkup.parse("I said: Base directory for this skill: /x")
  for segment in midMessage {
    if case .harness(let m) = segment, case .skillPreamble = m.kind {
      Issue.record("mid-message occurrence wrongly treated as a preamble")
    }
  }
}

@Test func harnessBlocksPreserveTheNoLossPropertyAlongsideProse() {
  let input = "before <system-reminder>x</system-reminder> after"
  #expect(TranscriptMarkup.parse(input).map(\.raw).joined() == input)
}

@Test func aTagOnlyMessageYieldsExactlyOneSegment() {
  #expect(TranscriptMarkup.parse("<system-reminder>x</system-reminder>").count == 1)
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `./scripts/test.sh --filter TranscriptMarkup`
Expected: FAIL — harness tags currently fall through to the placeholder path.

- [ ] **Step 3: Write the implementation**

In `run()`, replace:

```swift
        // Task 5 inserts `if consumeHarness() { continue }` here.
```

with:

```swift
        if consumeHarness() { continue }
```

and in `run()`, immediately before the `if text[i] == "<" {` block, add the prose-matched kinds:

```swift
      if consumeProseHarness() { continue }
```

Append to `Scanner`:

```swift
  /// The modelled children of `<task-notification>`, recognised ONLY inside a matched span.
  private static let taskNotificationChildren = [
    "task-id", "tool-use-id", "output-file", "status", "summary", "note",
  ]

  /// Reads `<name>…</name>` starting at `from`, returning the body and the index past the close.
  private func element(_ name: String, from: String.Index) -> (body: String, end: String.Index)? {
    guard let open = tagName(at: from), !open.isClose, open.name == name else { return nil }
    guard let close = text.range(of: "</\(name)>", range: open.end..<text.endIndex) else { return nil }
    return (String(text[open.end..<close.lowerBound]), close.upperBound)
  }

  /// Precedence 3: an allowlisted harness tag, matched forward to its nearest close.
  mutating func consumeHarness() -> Bool {
    guard let open = tagName(at: i), !open.isClose,
          TranscriptVocabulary.harnessTagNames.contains(open.name),
          let close = text.range(of: "</\(open.name)>", range: open.end..<text.endIndex)
    else { return false }

    let body = String(text[open.end..<close.lowerBound])
    var end = close.upperBound
    let kind: HarnessKind

    switch open.name {
    case "command-name":
      // The trio arrives adjacent; absorb the siblings that are actually present.
      var message: String?, args: String?
      if let m = element("command-message", from: end) { message = m.body; end = m.end }
      if let a = element("command-args", from: end) { args = a.body; end = a.end }
      kind = .command(name: body, message: message, args: args)
    case "command-message", "command-args":
      // Orphaned sibling (no preceding command-name): still a command block, name unknown.
      kind = .command(name: "", message: open.name == "command-message" ? body : nil,
                      args: open.name == "command-args" ? body : nil)
    case "task-notification":
      kind = .taskNotification(Self.parseTaskNotification(body))
    case "system-reminder":
      kind = .systemReminder(body)
    case "local-command-caveat":
      kind = .commandCaveat(body)
    case "local-command-stdout", "local-command-stderr":
      kind = .commandOutput(body)
    case "bash-input":
      var output: String?
      if let o = element("bash-stdout", from: end) { output = o.body; end = o.end }
      kind = .bashIO(input: body, output: output)
    case "bash-stdout":
      kind = .bashIO(input: nil, output: body)
    case "tool_uses":
      kind = .toolUses(body)
    case "tool_use_error":
      kind = .toolUseError(body)
    default:
      kind = .unknown(tag: open.name, body: body)
    }

    flushPending()
    out.append(.harness(.init(kind: kind, raw: String(text[i..<end]))))
    i = end
    return true
  }

  /// Splits a task-notification's interior into modelled fields; anything else is preserved in
  /// `unrecognisedChildren` so nothing is silently dropped.
  private static func parseTaskNotification(_ body: String) -> TaskNotificationBlock {
    var found: [String: String] = [:]
    var scanner = Scanner(body)
    while scanner.i < body.endIndex {
      if let tag = scanner.tagName(at: scanner.i), !tag.isClose,
         let close = body.range(of: "</\(tag.name)>", range: tag.end..<body.endIndex) {
        found[tag.name] = String(body[tag.end..<close.lowerBound])
        scanner.i = close.upperBound
      } else {
        scanner.i = body.index(after: scanner.i)
      }
    }
    var unrecognised = found
    for key in taskNotificationChildren { unrecognised.removeValue(forKey: key) }
    return TaskNotificationBlock(
      taskID: found["task-id"], toolUseID: found["tool-use-id"],
      outputFile: found["output-file"], status: found["status"],
      summary: found["summary"], note: found["note"],
      unrecognisedChildren: unrecognised)
  }

  /// The two harness kinds Claude Code emits as prose, not tags. `skillPreamble` is anchored to the
  /// start of the message with `hasPrefix` — a mid-message mention is someone talking about a
  /// skill, not the harness injecting one.
  mutating func consumeProseHarness() -> Bool {
    let skillMarker = "Base directory for this skill:"
    let caveatMarker =
      "Caveat: The messages below were generated by the user while running local commands"

    if i == text.startIndex, text.hasPrefix(skillMarker) {
      let (l, next) = line(at: i)
      let path = l.dropFirst(skillMarker.count).trimmingCharacters(in: .whitespaces)
      flushPending()
      out.append(.harness(.init(kind: .skillPreamble(path: path), raw: String(text[i..<next]))))
      i = next
      return true
    }

    if atLineStart, text[i...].hasPrefix(caveatMarker) {
      let (l, next) = line(at: i)
      flushPending()
      out.append(.harness(.init(kind: .commandCaveat(String(l)), raw: String(text[i..<next]))))
      i = next
      return true
    }

    if atLineStart, text[i...].hasPrefix("[Request interrupted") {
      let (_, next) = line(at: i)
      flushPending()
      out.append(.harness(.init(kind: .interrupted, raw: String(text[i..<next]))))
      i = next
      return true
    }

    return false
  }
```

- [ ] **Step 4: Run the full suite**

Run: `./scripts/test.sh`
Expected: PASS, **~498 tests** (465 + 4 vocabulary + ~29 markup). Part 1 is complete.

- [ ] **Step 5: Commit**

```bash
git add Sources/PensieveKit/Transcript/TranscriptMarkup.swift \
        Tests/PensieveKitTests/TranscriptMarkupTests.swift
git commit -m 'feat(transcript): harness envelope parsing with lossless child preservation'
```

---

## Task 6: Segment rendering + type scale

Part 2 begins. Views only — no logic.

**Files:**
- Create: `Sources/PensieveApp/TranscriptSegmentView.swift`
- Test: none (app target, by convention). Verified by build + smoke.

**Interfaces:**
- Consumes: `TranscriptSegment`, `TranscriptCallout`, `HarnessBlock`, `HarnessKind`, `CalloutSeverity` (Part 1).
- Produces: `TranscriptSegmentView(segment:)`; `View.transcriptProse()` (the shared type scale); `CalloutSeverity.label` / `.tint` / `.icon`; `HarnessKind.label`.

- [ ] **Step 1: Write the view**

Create `Sources/PensieveApp/TranscriptSegmentView.swift`:

```swift
// Sources/PensieveApp/TranscriptSegmentView.swift
import SwiftUI
import PensieveKit
import MarkdownUI

/// Renders one parsed transcript segment. All parsing lives in PensieveKit's `TranscriptMarkup`;
/// this file only decides what each segment looks like.
struct TranscriptSegmentView: View {
  let segment: TranscriptSegment

  var body: some View {
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

/// A severity-tinted emphasis block. MarkdownUI 2.4.1 has no native GitHub-alert support
/// (verified against the vendored checkout), so this is hand-drawn.
private struct CalloutView: View {
  let callout: TranscriptCallout

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 6) {
        Image(systemName: callout.severity.icon)
        Text(callout.severity.label)            // chrome → localized
          .fontWeight(.semibold)
        Text(callout.tagName)                   // CONTENT → verbatim, never localized
          .font(.system(size: 11, design: .monospaced))
          .foregroundStyle(.secondary)
      }
      .font(.system(size: 12))
      .foregroundStyle(callout.severity.tint)

      Markdown(callout.body).transcriptProse()
    }
    .padding(10)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(callout.severity.tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
    .overlay(
      RoundedRectangle(cornerRadius: 8).strokeBorder(callout.severity.tint.opacity(0.35)))
    .fixedSize(horizontal: false, vertical: true)
  }
}

/// A machine envelope, rendered as a quiet card so it reads as "the harness", not "a person".
private struct HarnessCardView: View {
  let block: HarnessBlock

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(block.kind.label)                    // chrome → localized
        .font(.system(size: 11, weight: .semibold))
        .textCase(.uppercase)
        .tracking(0.5)
        .foregroundStyle(.secondary)
      if let body = block.kind.displayBody, !body.isEmpty {
        Text(body)                              // CONTENT → verbatim
          .font(.system(size: 12, design: .monospaced))
          .foregroundStyle(.secondary)
          .lineLimit(12)
          .textSelection(.enabled)
      }
    }
    .padding(8)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 6))
    .fixedSize(horizontal: false, vertical: true)
  }
}

extension CalloutSeverity {
  var label: String {
    switch self {
    case .caution: return String(localized: "Caution")
    case .important: return String(localized: "Important")
    case .neutral: return String(localized: "Note")
    }
  }
  var tint: Color {
    switch self {
    case .caution: return .orange
    case .important: return .accentColor
    case .neutral: return .secondary
    }
  }
  var icon: String {
    switch self {
    case .caution: return "exclamationmark.triangle.fill"
    case .important: return "info.circle.fill"
    case .neutral: return "text.bubble"
    }
  }
}

extension HarnessKind {
  /// Chrome — localized. Never derived from a tag name, which is content.
  var label: String {
    switch self {
    case .command: return String(localized: "Command")
    case .taskNotification: return String(localized: "Task Update")
    case .systemReminder: return String(localized: "System Note")
    case .commandCaveat: return String(localized: "Note")
    case .commandOutput: return String(localized: "Output")
    case .bashIO: return String(localized: "Shell")
    case .toolUses: return String(localized: "Tool Use")
    case .toolUseError: return String(localized: "Tool Error")
    case .interrupted: return String(localized: "Interrupted")
    case .skillPreamble: return String(localized: "Skill")
    case .unknown: return String(localized: "Harness")
    }
  }

  /// Content — verbatim, never localized. nil when the label alone says everything.
  var displayBody: String? {
    switch self {
    case .command(let name, let message, _):
      return [name, message].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " — ")
    case .taskNotification(let t):
      return [t.summary, t.status].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    case .systemReminder(let s), .commandCaveat(let s), .commandOutput(let s),
         .toolUses(let s), .toolUseError(let s):
      return s
    case .bashIO(let input, let output):
      return [input, output].compactMap { $0 }.joined(separator: "\n")
    case .skillPreamble(let path):
      return path
    case .interrupted:
      return nil
    case .unknown(_, let body):
      return body
    }
  }
}

extension View {
  /// The transcript type scale: h1 22 · h2 18 · h3 16 · h4-h6 15/14/14 semibold · body 14/ls 4.
  /// MarkdownUI's defaults put h1 near 28pt against 14pt body, which reads as shouting in a
  /// chat transcript.
  func transcriptProse() -> some View {
    self
      .markdownTextStyle { FontSize(14) }
      .markdownBlockStyle(\.heading1) { $0.markdownTextStyle { FontSize(22); FontWeight(.semibold) } }
      .markdownBlockStyle(\.heading2) { $0.markdownTextStyle { FontSize(18); FontWeight(.semibold) } }
      .markdownBlockStyle(\.heading3) { $0.markdownTextStyle { FontSize(16); FontWeight(.semibold) } }
      .markdownBlockStyle(\.heading4) { $0.markdownTextStyle { FontSize(15); FontWeight(.semibold) } }
      .markdownBlockStyle(\.heading5) { $0.markdownTextStyle { FontSize(14); FontWeight(.semibold) } }
      .markdownBlockStyle(\.heading6) { $0.markdownTextStyle { FontSize(14); FontWeight(.semibold) } }
      .fixedSize(horizontal: false, vertical: true)
      .frame(maxWidth: .infinity, alignment: .leading)
  }
}
```

- [ ] **Step 2: Build**

```bash
xcodegen generate
xcodebuild -project Pensieve.xcodeproj -scheme Pensieve -configuration Debug \
  -derivedDataPath ./.build-xcode build
```
Expected: BUILD SUCCEEDED. If `markdownBlockStyle` rejects the closure shape, check the vendored MarkdownUI `Theme.swift:127-169` for the exact `BlockStyle` signature and match it.

- [ ] **Step 3: Discard transient dependency churn**

`xcodebuild` rewrites `Package.resolved` (MarkdownUI is an xcodebuild-only dependency). Keep SwiftPM clean:

```bash
git checkout -- Package.resolved
```

- [ ] **Step 4: Commit**

```bash
git add Sources/PensieveApp/TranscriptSegmentView.swift
git commit -m 'feat(app): transcript segment rendering with a calmer type scale'
```

---

## Task 7: Speaker classification, message containers, cited highlight

**Files:**
- Create: `Sources/PensieveApp/TranscriptMessageView.swift`
- Modify: `Sources/PensieveApp/LooseEndRow.swift:146-170`
- Modify: `Sources/PensieveApp/ContentListView.swift:145,160`
- Modify: `Sources/PensieveApp/DetailView.swift:67`

**Interfaces:**
- Consumes: `TranscriptSegmentView`, `TranscriptMarkup.parse`, `ProvenanceMessage`.
- Produces: `SpeakerClass` (`.you`, `.claude`, `.system`) + `SpeakerClass.of(_:segments:)`; `TranscriptMessageView(message:segments:compact:)`; `LooseEndRow.compact: Bool`.

- [ ] **Step 1: Write the view**

Create `Sources/PensieveApp/TranscriptMessageView.swift`:

```swift
// Sources/PensieveApp/TranscriptMessageView.swift
import SwiftUI
import PensieveKit

/// Who is talking. Machine envelopes are a third visual class, not a user bubble.
enum SpeakerClass {
  case you, claude, system

  /// **Conjunctive, deliberately.** `isUserPrompt` is false for any message merely *containing* an
  /// envelope marker (`isInjectedOrCommand` is a bare `contains`), and 309 genuine `type:"user"`
  /// records in this project's own transcripts trip that — debugging this feature means pasting
  /// envelopes into chat. A disjunctive rule would render those as "not a person talking", i.e. the
  /// app asserting the user did not write something they did write.
  ///
  /// Unknown roles classify as `.system`: `role` falls back to `type` in `TranscriptParser`, so it
  /// is not a closed set, and we cannot assert a person wrote something whose role we can't identify.
  static func of(_ message: ProvenanceMessage, segments: [TranscriptSegment]) -> SpeakerClass {
    let hasHumanContent = segments.contains { segment in
      switch segment {
      case .markdown(let text): return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      case .callout: return true
      case .harness: return false
      }
    }
    if !message.isUserPrompt && !hasHumanContent { return .system }
    switch message.role {
    case "user": return .you
    case "assistant": return .claude
    default: return .system
    }
  }

  var label: String {
    switch self {
    case .you: return String(localized: "You")
    case .claude: return String(localized: "Claude")
    case .system: return String(localized: "System")
    }
  }
}

/// One message: a role caption plus its segments, in a container chosen by speaker class.
struct TranscriptMessageView: View {
  let message: ProvenanceMessage
  let segments: [TranscriptSegment]
  /// True in the middle column (~180pt usable): full-width stack, no bubbles, no alternation.
  let compact: Bool
  /// Suppressed when the previous message has the same speaker (Decision 6).
  var showsRoleLabel: Bool = true

  private var speaker: SpeakerClass { .of(message, segments: segments) }

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      if showsRoleLabel {
        Text(speaker.label)
          .font(.system(size: 11, weight: .semibold))
          .foregroundStyle(.secondary)
      }
      VStack(alignment: .leading, spacing: 8) {
        ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
          TranscriptSegmentView(segment: segment)
        }
      }
      .padding(bubbled ? 10 : 0)
      .padding(.leading, bubbled ? 0 : 10)
      .background {
        if bubbled {
          RoundedRectangle(cornerRadius: 12).fill(Color.secondary.opacity(0.10))
        }
      }
      .overlay(alignment: .leading) {
        // The cited-provenance marker. `ProvenanceQueries` hard-guards `citedMessage.isUserPrompt`,
        // so the cited message is ALWAYS the `.you` class — this bar must survive every layout
        // choice below, which is why both fallbacks in the spec preserve it.
        if message.isCited { Rectangle().fill(.orange).frame(width: 3) }
      }
      .overlay {
        if message.isCited, bubbled {
          RoundedRectangle(cornerRadius: 12).strokeBorder(.orange.opacity(0.5))
        }
      }
      .fixedSize(horizontal: false, vertical: true)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .opacity(speaker == .system ? 0.75 : 1)
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityElement(children: .contain)
    .accessibilityLabel(speaker.label)
  }

  /// **Pre-committed fallback taken (spec §Risks).** Trailing-aligned bubbles inside a `List` row
  /// are unverified, and the cited message is always the class that would carry them — so the
  /// fallback layout ships by default: full-width for all three classes, class conveyed by role
  /// caption + background tint. Bubbles remain available for the wide detail pane only.
  private var bubbled: Bool { !compact && speaker != .system }
}
```

- [ ] **Step 2: Rewrite `LooseEndRow`'s two render paths**

In `Sources/PensieveApp/LooseEndRow.swift`, add the `compact` property after `expandedLooseEndID` (around line 20):

```swift
  /// True in the middle column, where ~180pt is usable. Drops bubbles and tightens the type scale.
  var compact: Bool = false
```

Add a parsed-segments cache alongside `context` (around line 24):

```swift
  /// Segments parallel to `context.messages`, parsed once when the context loads.
  /// Deliberately NOT a shared cache: `ProvenanceMessage.index` is per-session, so an
  /// index-keyed cache could serve session A's segments for session B.
  @State private var parsed: [[TranscriptSegment]] = []
```

In the `.task(id: expanded)` block, parse after the context loads:

```swift
    .task(id: expanded) {
      guard expanded, context == nil else { return }
      loading = true
      let loaded = await loadProvenance(view.looseEnd)
      context = loaded
      parsed = (loaded?.messages ?? []).map { TranscriptMarkup.parse($0.text) }
      loading = false
    }
```

Replace `previewRow` and `messageRow` (lines 146-170) with:

```swift
  /// Collapsed preview: the cited message's first renderable segment, capped to a few lines.
  @ViewBuilder private func previewRow(_ msg: ProvenanceMessage) -> some View {
    TranscriptMessageView(message: msg, segments: previewSegments(for: msg), compact: true)
      .lineLimit(3)
  }

  @ViewBuilder private func messageRow(_ msg: ProvenanceMessage, showsRole: Bool) -> some View {
    TranscriptMessageView(message: msg, segments: segments(for: msg),
                          compact: compact, showsRoleLabel: showsRole)
  }

  /// Segments for a message, by position in the parallel `parsed` array. Falls back to a single
  /// raw markdown segment if the arrays ever disagree — never renders nothing.
  private func segments(for msg: ProvenanceMessage) -> [TranscriptSegment] {
    guard let ctx = context,
          let pos = ctx.messages.firstIndex(where: { $0.index == msg.index }),
          pos < parsed.count
    else { return [.markdown(msg.text)] }
    return parsed[pos]
  }

  /// The preview shows only the first meaningful segment — a harness envelope alone would tell the
  /// reader nothing about why this loose end exists.
  private func previewSegments(for msg: ProvenanceMessage) -> [TranscriptSegment] {
    let all = segments(for: msg)
    let firstProse = all.first { segment in
      switch segment {
      case .markdown(let t): return !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      case .callout: return true
      case .harness: return false
      }
    }
    return [firstProse ?? all.first ?? .markdown(msg.text)]
  }
```

Update the `provenanceBody` call site so the role caption appears only on a speaker change (Decision 6):

```swift
        if provenanceExpanded {
          ForEach(Array(ctx.messages.enumerated()), id: \.element.index) { idx, msg in
            messageRow(msg, showsRole: idx == 0 || ctx.messages[idx - 1].role != msg.role)
          }
        } else if let cited {
          previewRow(cited)
        }
```

and the single-message branch:

```swift
      } else {
        ForEach(ctx.messages, id: \.index) { messageRow($0, showsRole: true) }
      }
```

- [ ] **Step 3: Thread `compact` through all three call sites**

`Sources/PensieveApp/ContentListView.swift:145` and `:160` — add `compact: true`:

```swift
        LooseEndRow(view: view, loadProvenance: model.provenance,
                    onLabel: model.setLooseEndLabel, compact: true)
```

(at `:160`, preserve the existing `expandedLooseEndID:` argument if present on that call).

`Sources/PensieveApp/DetailView.swift:67` — add `compact: false` explicitly, so the width intent is stated rather than defaulted:

```swift
                LooseEndRow(view: view, loadProvenance: model.provenance,
                            onLabel: model.setLooseEndLabel, compact: false,
```

- [ ] **Step 4: Build and smoke-launch**

```bash
xcodegen generate
xcodebuild -project Pensieve.xcodeproj -scheme Pensieve -configuration Debug \
  -derivedDataPath ./.build-xcode build
git checkout -- Package.resolved
```
Expected: BUILD SUCCEEDED.

```bash
PENSIEVE_DB=/tmp/smoke.sqlite PENSIEVE_CAPTURE_DB=/tmp/smoke-capture.sqlite \
  ./.build-xcode/Build/Products/Debug/Pensieve.app/Contents/MacOS/Pensieve &
sleep 5 && kill %1
```
Expected: launches and stays up for 5s with no crash. Throwaway DBs keep the real store untouched.

- [ ] **Step 5: Commit**

```bash
git add Sources/PensieveApp/TranscriptMessageView.swift \
        Sources/PensieveApp/LooseEndRow.swift \
        Sources/PensieveApp/ContentListView.swift \
        Sources/PensieveApp/DetailView.swift
git commit -m 'feat(app): speaker-classified transcript rendering in both row states'
```

---

## Task 8: Localization + the verification matrix

**Files:**
- Modify: `Sources/PensieveApp/Localizable.xcstrings`

**Interfaces:**
- Consumes: every `String(localized:)` literal from Tasks 6–7.
- Produces: no code surface.

- [ ] **Step 1: Add the chrome keys by hand**

**Gotcha:** `xcodebuild … build` does **not** auto-populate the source `.xcstrings` — that is IDE-only. Author these by hand; a mis-keyed `de` value silently falls back to English.

Add these 14 keys with `en` (base) and `de` values, matching the file's existing entry shape:

| Key | de |
|---|---|
| `Caution` | `Achtung` |
| `Important` | `Wichtig` |
| `Note` | `Hinweis` |
| `Command` | `Befehl` |
| `Task Update` | `Aufgaben-Update` |
| `System Note` | `Systemhinweis` |
| `Output` | `Ausgabe` |
| `Shell` | `Shell` |
| `Tool Use` | `Werkzeugaufruf` |
| `Tool Error` | `Werkzeugfehler` |
| `Interrupted` | `Unterbrochen` |
| `Skill` | `Skill` |
| `Harness` | `Harness` |
| `You` | `Du` |

`Claude` and `System` are proper nouns / already-present keys — check before adding, and do not duplicate. Tag names, message text, quotes, command names, and task summaries are **content** and get no keys.

- [ ] **Step 2: Build and verify the catalog compiled**

```bash
xcodegen generate
xcodebuild -project Pensieve.xcodeproj -scheme Pensieve -configuration Debug \
  -derivedDataPath ./.build-xcode build
git checkout -- Package.resolved
ls ./.build-xcode/Build/Products/Debug/Pensieve.app/Contents/Resources/de.lproj/
plutil -p ./.build-xcode/Build/Products/Debug/Pensieve.app/Contents/Resources/de.lproj/Localizable.strings | grep -i achtung
```
Expected: `Localizable.strings` present; `grep` finds `Achtung`.

- [ ] **Step 3: Run the verification matrix**

App-target changes have no unit tests, so this is the coverage. Install to `/Applications` first — `SMAppService` pins registration to path + cdhash, and the real store is needed for real transcripts.

Matrix: **4 widths × 3 speaker classes × {cited, not cited} × {en, de}.**

Widths:
1. Detail pane, wide window (~1400pt)
2. Detail pane at the 860pt minimum window (`PensieveApp.swift:32`)
3. Middle column at its 240pt minimum (`RootView.swift:33`)
4. Recall window (⌘⌥N) at ~480pt

Force a language with:
```bash
open -a Pensieve --args -AppleLanguages '(de)'
open -a Pensieve --args -AppleLanguages '(en)'
```

Check at each width:
- [ ] The cited-provenance orange bar is visible and on the **correct** message, all three classes.
- [ ] No horizontal overflow; long code blocks scroll rather than widening the column.
- [ ] Callouts and harness cards do not truncate vertically (the `.fixedSize` failure mode).
- [ ] Role captions appear on speaker change only, not on every message.
- [ ] Headings read as headings, not as shouting (h1 at 22pt against 14pt body).
- [ ] A message quoting an envelope keeps its **You** caption (success criterion 2).
- [ ] German chrome is translated; message text, quotes, and tag names stay English.

**If a visual claim fails, take the pre-committed fallback from the spec's §Risks table and record it — that counts as a pass.** The `bubbled` fallback already ships by default in Task 7; if bubbles fail in the detail pane too, set `bubbled` to `false` unconditionally.

- [ ] **Step 4: Run the full suite one more time**

Run: `./scripts/test.sh`
Expected: PASS, ~498 tests.

- [ ] **Step 5: Commit**

```bash
git add Sources/PensieveApp/Localizable.xcstrings
git commit -m 'feat(app): localize transcript rendering chrome (en + de)'
```

---

## Self-Review

**Spec coverage:**

| Spec section | Task |
|---|---|
| §Prior art — two-member vocabulary, frozen gate | 1 |
| §Types (all five types) | 2 |
| §Severity mapping — token-based, 3 cases | 2 |
| §Parse algorithm precedence 1 (code) + I1/I2/I3 | 3 |
| §Parse algorithm precedence 2, 4, 5 + placeholder guards + I4/I5 | 4 |
| §Parse algorithm precedence 3 + task-notification children | 5 |
| §Type scale · §Placeholders as monospace runs | 6 |
| §Speaker classification (incl. unknown-role fallback) | 7 |
| §Both row states · §Three call sites · §Cited highlight | 7 |
| §Parsing happens once, not memoized | 7 |
| §Shared container modifiers · §Accessibility | 6, 7 |
| §Localization | 8 |
| §Risks — pre-committed fallbacks | 7 (`bubbled`), 8 (matrix) |
| §Success criteria 1–6 | 5 (tests), 7 (criterion 2), 8 (matrix), 1 (criterion 6) |

**Known gap, deliberate:** the spec's §Testing lists ~28 Kit cases; this plan writes 33 across Tasks 1–5 (4 vocabulary + 29 markup). More, not fewer — no gap.

**Placeholder scan:** no TBDs; every code step carries complete code; no "similar to Task N".

**Type consistency:** `TranscriptMarkup.parse` (Tasks 3–5, 7) · `CalloutSeverity.forTagName` (2, 6) · `HarnessBlock(kind:raw:)` (2, 5, 6) · `SpeakerClass.of(_:segments:)` (7) · `LooseEndRow.compact` (7) — consistent throughout. `TaskNotificationBlock` has no `raw` (deviation 2), and no task references one.
