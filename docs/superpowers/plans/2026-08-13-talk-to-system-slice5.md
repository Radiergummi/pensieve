# Talk to the System, Stage 1 — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Type a description into the New Node modal and get a node whose name is a readable label, whose description is your text verbatim, and whose kind and parent are derived deterministically.

**Architecture:** A shared label gate moves into `TextQuality`, joined by a deterministic word-boundary shortening. `NodeLabeler` routes by detected language — English to the on-device model, everything else to the shortening — and never returns nil except for empty input, so the modal always has a name. `NodeFields` grows a compulsory `description` so the app can finally write one. All model work is best-effort and outside the cited trust gate; the user confirms every field before anything is written.

**Tech Stack:** Swift 6, SwiftUI, SQLiteData (GRDB), Swift Testing, `NaturalLanguage` (`NLLanguageRecognizer`), Foundation Models via the existing `LLMProvider` seam.

**Spec:** `docs/superpowers/specs/2026-08-13-talk-to-system-slice5-design.md`
**Evidence:** `docs/superpowers/measurements/2026-08-13-slice5-label-quality/`

## Global Constraints

- **No new `LLMProvider` method, no `GenerationSchema`, no guided generation.** One `complete` call. The first draft's structured machinery constrained `kind` and `parent`, which are no longer model outputs.
- **Never translate.** Non-English input takes the deterministic path. Node names and descriptions are captured content and are never localized; only chrome goes in the String Catalog.
- **Trust gate untouched.** Do not read, write, or reference `TranscriptVocabulary.injectionMarkers`, `TranscriptParser.isInjectedOrCommand`, `isUserPrompt`, or `LooseEndVerifier`.
- **Do NOT register an `EvalTask`.** Decided 2026-08-13 (spec § "Three interactions that need an explicit decision", item 2): this task is the same shape as the unregistered `Ingester.nameStrand`, and `CorpusBuilder` has two hardcoded task lists the registry↔config test does not check, so a bespoke bar would look like coverage without being coverage. Quality is pinned by the committed probes instead. The gap is logged in `backlog.md` ▸ "Naming has no eval coverage".
- **The app target has NO unit tests.** Keep derivation in PensieveKit; verify app changes with `make build` plus a non-blocking smoke-launch. Never invent app-target unit tests.
- **Naming:** no abbreviations — `database`, `node`, `looseEnd`, `provider`, not `db`, `n`, `le`, `p`. SwiftLint runs `--strict` in CI; files cap at **400 lines**.
- **SQLiteData predicates use `.eq(x)`, never `== x`.**
- **Commit messages:** backticks inside `git commit -m "…"` get shell-executed. Use `git commit -F -` with a quoted-`EOF` heredoc.
- **Do NOT set `PENSIEVE_DB` / `PENSIEVE_CAPTURE_DB` when touching the live store**; smoke-launches SHOULD set them to `/tmp` paths.
- **Do not stage files you did not change.** `Package.resolved` churns on every `xcodebuild` — leave it alone.
- Tests: `./scripts/test.sh --filter <Name>` for one, `make test` for the suite. Build: `make build`.

---

## File Structure

**Kit — created**
- `Sources/PensieveKit/Intelligence/NodeLabeler.swift` — language routing, the prompt, the fallback chain.
- `Tests/PensieveKitTests/TextQualityLabelTests.swift` — the label gate and the shortening.
- `Tests/PensieveKitTests/NodeLabelerTests.swift` — routing and failure behaviour.

**Kit — modified**
- `Sources/PensieveKit/Support/TextQuality.swift` — gains `sanitizeLabel` (moved) and `shorten` (new).
- `Sources/PensieveKit/Ingest/Ingester.swift` — loses `sanitizeStrandName`; two call sites retargeted.
- `Sources/PensieveKit/Query/NodeCommands.swift` — `NodeFields.description`; `update` writes it.
- `Tests/PensieveKitTests/StrandBirthTests.swift` — two test functions move out.
- `Tests/PensieveKitTests/NodeCommandsTests.swift` — call sites updated; a description round-trip added.

**App — modified**
- `Sources/PensieveApp/AppModel+Organizing.swift` — `suggestName`; description threaded through both writes; new-node parent defaults to the selection.
- `Sources/PensieveApp/NodeOrganizing.swift` — the Description field and the Suggest button.
- `Sources/PensieveApp/Localizable.xcstrings` — new chrome strings, en + de.

## Deviation from the spec, decided while planning

The spec describes the modal growing **two** fields: a "Describe it" prompt and a separate
"Description". **They are the same field.** The design has the description be the typed text
verbatim, so two fields would show identical text twice and force the user to choose which one to
edit.

**So the modal grows ONE field — `Description` — plus a "Suggest name" button beside it** that
derives `Name` from whatever the field currently holds. This is strictly simpler and resolves the
spec's open Return-versus-`.defaultAction` question outright: the button *is* the explicit
affordance the spec required, so `Save` keeps `.defaultAction` unchallenged and no `onSubmit` is
introduced into a sheet (a pattern with no precedent in this codebase).

The invariant is unaffected: the description is still the user's words, verbatim.

---

### Task 1: Move the label gate into `TextQuality`

The gate that `Ingester` uses for auto-birthed strand names becomes shared, because `NodeLabeler`
needs exactly the same shape check. Pure move — no behaviour change, proven by the existing tests
passing at their new home.

**Files:**
- Modify: `Sources/PensieveKit/Support/TextQuality.swift`
- Modify: `Sources/PensieveKit/Ingest/Ingester.swift:257-270` (delete), `:322`, `:383` (retarget)
- Create: `Tests/PensieveKitTests/TextQualityLabelTests.swift`
- Modify: `Tests/PensieveKitTests/StrandBirthTests.swift:164-186` (remove the two moved tests)

**Interfaces:**
- Consumes: `TextQuality.isTerseLabel(_:)`, `TextQuality.labelLengthCap` (both already exist).
- Produces: `TextQuality.sanitizeLabel(_ raw: String) -> String?` — used by Task 3 and by `Ingester`.

- [ ] **Step 1: Move the two existing tests to a new file, retargeted**

Create `Tests/PensieveKitTests/TextQualityLabelTests.swift`:

```swift
import Testing
@testable import PensieveKit

@Test func sanitizeLabelStripsListMarkersQuotesAndTrailingPunctuation() {
  #expect(TextQuality.sanitizeLabel("1. Event Watermark Fields") == "Event Watermark Fields")
  #expect(TextQuality.sanitizeLabel("2) Drop Rows") == "Drop Rows")
  #expect(TextQuality.sanitizeLabel("- Sync daemon") == "Sync daemon")
  #expect(TextQuality.sanitizeLabel("Security enhancement with admin bypass.") == "Security enhancement with admin bypass")
  #expect(TextQuality.sanitizeLabel("\"Quoted Name\"") == "Quoted Name")
  #expect(TextQuality.sanitizeLabel("Already Clean") == "Already Clean")
  #expect(TextQuality.sanitizeLabel("   ") == nil)
}

@Test func sanitizeLabelRejectsSentencesAndOverlongOutput() {
  #expect(TextQuality.sanitizeLabel("Wire noise filters into pipeline. Fixes chunk splitting issue") == nil)
  #expect(TextQuality.sanitizeLabel(
    "A really long strand name that runs well past the sixty character cap we enforce") == nil)
  #expect(TextQuality.sanitizeLabel(
    "Refactor the ingest pipeline. Then rename the strand accordingly") == nil)
  // Internal dots that are not sentence boundaries must survive.
  #expect(TextQuality.sanitizeLabel("v3.1 migration") == "v3.1 migration")
  #expect(TextQuality.sanitizeLabel("Fix auth.middleware") == "Fix auth.middleware")
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `./scripts/test.sh --filter TextQualityLabel`
Expected: FAIL — `type 'TextQuality' has no member 'sanitizeLabel'`.

- [ ] **Step 3: Add `sanitizeLabel` to `TextQuality`**

Append inside `enum TextQuality` in `Sources/PensieveKit/Support/TextQuality.swift`, after `isTerseLabel`:

```swift
  /// Cleans a model-proposed label into a terse organizational name: strips a leading
  /// list/enumeration marker ("1. ", "2) ", "- ", "* ", "• "), wrapping quotes or backticks, and
  /// trailing sentence punctuation. Returns nil when nothing usable survives, so the caller keeps
  /// its own deterministic fallback. Deterministic — the namers sit outside the cited trust gate,
  /// but their output still shouldn't read like a numbered list item or a full sentence.
  ///
  /// Two callers: `Ingester` (auto-birthed strand + project names) and `NodeLabeler` (a user's
  /// typed description). It lived on `Ingester` until the second arrived; the shape recurs, so the
  /// gate is shared rather than copied.
  static func sanitizeLabel(_ raw: String) -> String? {
    var sanitized = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if let marker = sanitized.range(of: #"^(\d+[.)]|[-*•])\s+"#, options: .regularExpression) {
      sanitized.removeSubrange(marker)
    }
    sanitized = sanitized.trimmingCharacters(in: CharacterSet(charactersIn: "\"'`"))
    sanitized = sanitized.trimmingCharacters(in: CharacterSet(charactersIn: ".!?"))
    sanitized = sanitized.trimmingCharacters(in: .whitespaces)
    // Enforce the "terse label, not a sentence" contract. Observed failures: a 101-char name and
    // multi-sentence commit-message-shaped output sitting in the sidebar. nil → the caller keeps
    // its deterministic fallback.
    guard isTerseLabel(sanitized) else { return nil }
    return sanitized
  }
```

- [ ] **Step 4: Delete the original and retarget its callers**

In `Sources/PensieveKit/Ingest/Ingester.swift`, delete the whole `sanitizeStrandName` function
(its doc comment through its closing brace, around `:250-270`), then change both call sites:

- `:322` — `let name = Self.sanitizeStrandName(firstLine)` → `let name = TextQuality.sanitizeLabel(firstLine)`
- `:383` — `guard let first = lines.first, let name = Self.sanitizeStrandName(first) else { return }` → `guard let first = lines.first, let name = TextQuality.sanitizeLabel(first) else { return }`

- [ ] **Step 5: Remove the moved tests from their old home**

In `Tests/PensieveKitTests/StrandBirthTests.swift`, delete the two functions
`sanitizeStrandNameStripsListMarkersQuotesAndTrailingPunctuation` and
`sanitizeStrandNameRejectsSentencesAndOverlongOutput` (around `:164-186`), including their `@Test`
attributes and any comment block introducing them. Leave every other test in that file untouched.

- [ ] **Step 6: Run the full suite**

Run: `make test`
Expected: PASS, with the same total as before the task (two tests moved, none added or lost).
If `Ingester.sanitizeStrandName` is referenced anywhere else, the compiler will say so — retarget
those too rather than reinstating the old function.

- [ ] **Step 7: Commit**

```bash
git add Sources/PensieveKit/Support/TextQuality.swift Sources/PensieveKit/Ingest/Ingester.swift \
        Tests/PensieveKitTests/TextQualityLabelTests.swift Tests/PensieveKitTests/StrandBirthTests.swift
git commit -F - <<'EOF'
refactor(kit): the label gate moves to where two callers can share it

sanitizeStrandName leaves Ingester for TextQuality, beside the
isTerseLabel it already called. A second caller is arriving — a user's
typed description — and the shape check is identical, so the gate is
shared rather than copied. Pure move: the same tests pass at their new
home.
EOF
```

---

### Task 2: `TextQuality.shorten` — a label from the user's own words

The deterministic arm. Used for non-English input and for every model failure, which is what keeps
the modal's name field from ever being empty.

**Files:**
- Modify: `Sources/PensieveKit/Support/TextQuality.swift`
- Modify: `Tests/PensieveKitTests/TextQualityLabelTests.swift`

**Interfaces:**
- Produces: `TextQuality.shorten(_ text: String, cap: Int = labelLengthCap) -> String?` — used by Task 3.

- [ ] **Step 1: Write the failing tests**

Append to `Tests/PensieveKitTests/TextQualityLabelTests.swift`:

```swift
@Test func shortenReturnsShortInputWhole() {
  // The measured common case: quick-add sentences usually already fit, so most inputs
  // pass through untouched. Nine of eleven probe inputs were <= the cap.
  #expect(TextQuality.shorten("look into why the sync agent stopped") == "look into why the sync agent stopped")
  #expect(TextQuality.shorten("Steuerunterlagen für 2025 zusammenstellen") == "Steuerunterlagen für 2025 zusammenstellen")
  #expect(TextQuality.shorten("  padded  ") == "padded")
}

@Test func shortenBreaksOnWordBoundariesNeverMidWord() {
  let long = "I want to eventually get around to reconsidering whether projects and strands are the same kind of thing"
  let shortened = TextQuality.shorten(long)
  #expect(shortened != nil)
  #expect(shortened!.count <= TextQuality.labelLengthCap)
  // Every kept word must be a whole word from the input — a cut word reads as corruption.
  let inputWords = Set(long.split(separator: " ").map(String.init))
  #expect(shortened!.split(separator: " ").allSatisfy { inputWords.contains(String($0)) })
  #expect(long.hasPrefix(shortened!))
}

@Test func shortenHandlesASingleOverlongWordAndEmptyInput() {
  // No boundary to preserve, so cutting is the only option.
  let oneWord = String(repeating: "a", count: 80)
  #expect(TextQuality.shorten(oneWord)?.count == TextQuality.labelLengthCap)
  #expect(TextQuality.shorten("") == nil)
  #expect(TextQuality.shorten("   \n  ") == nil)
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `./scripts/test.sh --filter shorten`
Expected: FAIL — `type 'TextQuality' has no member 'shorten'`.

- [ ] **Step 3: Implement**

Append inside `enum TextQuality`, after `sanitizeLabel`:

```swift
  /// A label built from the user's own words: the text itself when it already fits, otherwise as
  /// many whole words as fit within `cap`. Never cuts mid-word — a broken word reads as corruption
  /// — except for a single word longer than the cap, where there is no boundary to keep. Returns
  /// nil only for empty input.
  ///
  /// This is `NodeLabeler`'s non-English and provider-failure arm. It is not a consolation prize:
  /// most quick-add sentences already fit, so it usually returns them whole, in the user's own
  /// words, guaranteed correct. See `measurements/2026-08-13-slice5-label-quality/`.
  static func shorten(_ text: String, cap: Int = labelLengthCap) -> String? {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    guard trimmed.count > cap else { return trimmed }
    var kept = ""
    for word in trimmed.split(separator: " ") {
      if kept.isEmpty {
        kept = String(word)
      } else if kept.count + 1 + word.count <= cap {
        kept += " " + word
      } else {
        break
      }
    }
    return kept.count <= cap ? kept : String(kept.prefix(cap))
  }
```

- [ ] **Step 4: Run to verify they pass**

Run: `./scripts/test.sh --filter shorten`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/PensieveKit/Support/TextQuality.swift Tests/PensieveKitTests/TextQualityLabelTests.swift
git commit -F - <<'EOF'
feat(kit): a label from the user's own words, no model involved

Whole words within the cap, the text itself when it already fits. This is
the arm that runs for non-English input and for every model failure, and
it is why the name field can never end up empty.
EOF
```

---

### Task 3: `NodeLabeler` — route by language, never translate

The measured core of the slice. English goes to the model; everything else does not, because the
on-device model translates non-English input and no prompt instruction stops it.

**Files:**
- Create: `Sources/PensieveKit/Intelligence/NodeLabeler.swift`
- Create: `Tests/PensieveKitTests/NodeLabelerTests.swift`

**Interfaces:**
- Consumes: `TextQuality.sanitizeLabel(_:)` (Task 1), `TextQuality.shorten(_:cap:)` (Task 2), `LLMProvider.complete(prompt:)`.
- Produces: `NodeLabeler.label(for:provider:) async -> String?` — used by Task 5.

- [ ] **Step 1: Write the failing tests**

Create `Tests/PensieveKitTests/NodeLabelerTests.swift`:

```swift
import Testing
@testable import PensieveKit

/// Returns a fixed label. The marker text is deliberately distinctive so a test can assert the
/// model was NOT consulted by checking the result is something else.
private struct StubLabelLLM: LLMProvider {
  let text: String
  func complete(prompt: String) async throws -> String { text }
}

private struct FailingLabelLLM: LLMProvider {
  func complete(prompt: String) async throws -> String { throw LLMError.providerFailed("nope") }
}

@Test func englishInputUsesTheModelsLabel() async {
  let label = await NodeLabeler.label(for: "look into why the background sync agent stopped spawning",
                                      provider: StubLabelLLM(text: "Background Sync Agent Issue"))
  #expect(label == "Background Sync Agent Issue")
}

@Test func germanInputNeverReachesTheModel() async {
  // The decisive routing test. The provider would return this marker if consulted; the German
  // arm must return the deterministic shortening of the user's own words instead. Measured
  // rationale: the on-device model translates German, once returning "Train Advertisement Claim"
  // for a delayed-train complaint, and a "do not translate" instruction does not fix it.
  let typed = "die Bahn-Reklamation für die verspätete Fahrt einreichen"
  let label = await NodeLabeler.label(for: typed, provider: StubLabelLLM(text: "MODEL-WAS-CONSULTED"))
  #expect(label != "MODEL-WAS-CONSULTED")
  #expect(label == TextQuality.shorten(typed))
}

@Test func everyModelFailureFallsBackToTheDeterministicLabel() async {
  let typed = "migrate the loose end resolution verbs into the CLI"
  let expected = TextQuality.shorten(typed)

  // A throwing provider.
  #expect(await NodeLabeler.label(for: typed, provider: FailingLabelLLM()) == expected)
  // No provider at all.
  #expect(await NodeLabeler.label(for: typed, provider: nil) == expected)
  // Empty output.
  #expect(await NodeLabeler.label(for: typed, provider: StubLabelLLM(text: "   ")) == expected)
  // Output the gate rejects: multi-sentence, and over the cap.
  #expect(await NodeLabeler.label(for: typed,
                                  provider: StubLabelLLM(text: "Migrate the verbs. Then update the CLI")) == expected)
  #expect(await NodeLabeler.label(
    for: typed,
    provider: StubLabelLLM(text: String(repeating: "long ", count: 30))) == expected)
}

@Test func onlyEmptyInputYieldsNil() async {
  #expect(await NodeLabeler.label(for: "", provider: nil) == nil)
  #expect(await NodeLabeler.label(for: "   \n ", provider: nil) == nil)
}

@Test func languageRoutingMatchesTheMeasuredProbe() {
  #expect(NodeLabeler.isEnglish("look into why the background sync agent stopped spawning"))
  #expect(NodeLabeler.isEnglish("fix the German truncation in the menu bar footer"))
  #expect(!NodeLabeler.isEnglish("Steuerunterlagen für 2025 zusammenstellen"))
  #expect(!NodeLabeler.isEnglish("Geschenk für Mamas Geburtstag besorgen"))
  // Undetectable input must take the safe (deterministic) arm, not the model.
  #expect(!NodeLabeler.isEnglish(""))
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `./scripts/test.sh --filter NodeLabeler`
Expected: FAIL — `cannot find 'NodeLabeler' in scope`.

- [ ] **Step 3: Implement**

Create `Sources/PensieveKit/Intelligence/NodeLabeler.swift`:

```swift
import Foundation
import NaturalLanguage

/// A node name derived from the user's own typed description. Best-effort, and **routed by
/// language**.
///
/// English input goes to the model, which produces a better sidebar label than the sentence it came
/// from (measured: 21/21 through the gate, 16/16 usable). **Every other language takes a
/// deterministic shortening instead**, because the on-device model translates non-English input —
/// once returning "Train Advertisement Claim" for a German delayed-train complaint, where a
/// *Reklamation* is a complaint — and an explicit "write it in the same language" instruction does
/// not fix it: the model either ignores it or emits broken German. The failure is also
/// non-deterministic, so it cannot be prompted away or caught reliably by a test.
///
/// Translating would additionally violate the project rule that node names are captured content and
/// are never localized.
///
/// Evidence and probes: `docs/superpowers/measurements/2026-08-13-slice5-label-quality/`.
///
/// Outside the cited trust gate, like strand naming and narration — the user reads and confirms the
/// name in the modal before anything is written.
public enum NodeLabeler {
  /// Whether `text`'s dominant language is English. Anything else — including text whose language
  /// cannot be determined — routes to the deterministic arm, so the safe path is the default.
  static func isEnglish(_ text: String) -> Bool {
    let recognizer = NLLanguageRecognizer()
    recognizer.processString(text)
    return recognizer.dominantLanguage == .english
  }

  /// Mirrors `Ingester`'s proven strand-naming prompt shape: one line, a word count, and an
  /// explicit "label only" so a conversational model doesn't wrap it in prose.
  static func prompt(for typed: String) -> String {
    """
    Below is a developer's own description of a piece of work they are about to start. In 3-6 \
    words, give it a human-readable name — a plain label for a sidebar, not numbered or bulleted, \
    no trailing period. Reply with the label only, nothing else. Do not invent facts beyond the \
    description.

    \(typed)
    """
  }

  /// A label for `typed`. Returns nil **only** for empty input: every other outcome — non-English,
  /// no provider, a throw, empty or gate-rejected model output — falls through to the deterministic
  /// shortening. That is what lets the modal always show a name, so `Save` is never stuck disabled.
  public static func label(for typed: String, provider: (any LLMProvider)?) async -> String? {
    let trimmed = typed.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let fallback = TextQuality.shorten(trimmed) else { return nil }
    guard isEnglish(trimmed), let provider else { return fallback }
    guard let raw = try? await provider.complete(prompt: prompt(for: trimmed)),
          let label = TextQuality.sanitizeLabel(raw) else { return fallback }
    return label
  }
}
```

- [ ] **Step 4: Run to verify they pass**

Run: `./scripts/test.sh --filter NodeLabeler`
Expected: PASS (5 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/PensieveKit/Intelligence/NodeLabeler.swift Tests/PensieveKitTests/NodeLabelerTests.swift
git commit -F - <<'EOF'
feat(kit): name a node from your own words, and never translate them

English input goes to the model, which writes a better sidebar label than
the sentence it came from. Nothing else does. The on-device model
translates German and once got it wrong — a Reklamation is a complaint,
not an advertisement — and telling it not to translate either gets
ignored or produces broken German. The failure is non-deterministic, so
routing is the only fix that holds.

nil comes back only for empty input. Every other failure falls through to
the deterministic shortening, so the modal always has a name to show.
EOF
```

---

### Task 4: `NodeFields` carries a description, and `update` writes it

Closes the gap that made this slice necessary: the app has never been able to set a description.

**`description` gets NO default value.** There is exactly one production caller of
`NodeCommands.update`, and a defaulted empty string would silently blank a description for any
caller that forgot it. A compulsory parameter makes the compiler enumerate the sites instead.

**Files:**
- Modify: `Sources/PensieveKit/Query/NodeCommands.swift:7-21` (`NodeFields`), `:107-119` (`update`)
- Modify: `Tests/PensieveKitTests/NodeCommandsTests.swift:168-188`

**Interfaces:**
- Produces: `NodeFields(name:kind:description:icon:colorTag:context:)` and an `update` that writes `description` — used by Task 5.

- [ ] **Step 1: Write the failing test**

Add to `Tests/PensieveKitTests/NodeCommandsTests.swift`:

```swift
@Test func updateWritesTheDescriptionAndRoundTripsAnUnchangedOne() throws {
  let database = try openCanonicalDatabase(at: tempURL("update-description"))
  let node = try #require(try NodeCommands.add(database, name: "Sync", kind: .project,
                                               parent: nil, description: "the original text"))

  // Editing other fields while passing the existing description back must preserve it — this is
  // the Edit modal's round trip, and the regression this task's compulsory parameter guards.
  #expect(try NodeCommands.update(database, nodeID: node.id,
                                  fields: NodeFields(name: "Sync Agent", kind: .project,
                                                     description: "the original text")))
  var stored = try #require(try database.read { try Node.where { $0.id.eq(node.id) }.fetchOne($0) })
  #expect(stored.name == "Sync Agent")
  #expect(stored.description == "the original text")

  // And a real description edit lands.
  #expect(try NodeCommands.update(database, nodeID: node.id,
                                  fields: NodeFields(name: "Sync Agent", kind: .project,
                                                     description: "rewritten by hand")))
  stored = try #require(try database.read { try Node.where { $0.id.eq(node.id) }.fetchOne($0) })
  #expect(stored.description == "rewritten by hand")
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `./scripts/test.sh --filter updateWritesTheDescription`
Expected: FAIL — `NodeFields` has no `description` parameter.

- [ ] **Step 3: Add the field**

In `Sources/PensieveKit/Query/NodeCommands.swift`, replace the `NodeFields` struct with:

```swift
/// The user-facing fields of the New/Edit node modal, carried as one value so the write APIs that
/// all take the same values share one shape.
///
/// `description` has **no default on purpose**: it is written by `update`, so a defaulted empty
/// string would silently blank an existing description for any caller that forgot to pass it.
/// Compulsory means the compiler names every site instead.
public struct NodeFields: Sendable {
  public var name: String
  public var kind: NodeKind
  public var description: String
  public var icon: String
  public var colorTag: String
  public var context: String

  public init(name: String, kind: NodeKind, description: String,
              icon: String = "", colorTag: String = "", context: String = "") {
    self.name = name
    self.kind = kind
    self.description = description
    self.icon = icon
    self.colorTag = colorTag
    self.context = context
  }
}
```

- [ ] **Step 4: Write the description in `update`**

Replace `update`'s doc comment and assignment block:

```swift
  /// Atomic edit of a node's user-facing fields (the app's Edit modal). Leaves parentID, state and
  /// branchKey untouched. Returns false — writing nothing — for an unknown id.
  @discardableResult
  public static func update(_ database: any DatabaseWriter, nodeID: UUID, fields: NodeFields) throws -> Bool {
    try database.write { database in
      guard try Node.where({ $0.id.eq(nodeID) }).fetchOne(database) != nil else { return false }
      try Node.where { $0.id.eq(nodeID) }.update {
        $0.name = fields.name; $0.kind = fields.kind; $0.icon = fields.icon
        $0.colorTag = fields.colorTag; $0.context = fields.context
        $0.description = fields.description
      }.execute(database)
      return true
    }
  }
```

- [ ] **Step 5: Fix the call sites the compiler names**

Build and let the compiler enumerate them: `make test` will fail to compile until each
`NodeFields(...)` call passes `description:`. Expect these, and change nothing else:

- `Tests/PensieveKitTests/NodeCommandsTests.swift:169` → add `description: ""`
- `Tests/PensieveKitTests/NodeCommandsTests.swift:178` → add `description: ""`
- `Tests/PensieveKitTests/NodeCommandsTests.swift:188` → add `description: ""`
- `Sources/PensieveApp/NodeOrganizing.swift:109` → Task 5 rewrites this line; for now add
  `description: ""` so the app target still builds.

- [ ] **Step 6: Run the full suite**

Run: `make test`
Expected: PASS, one test more than before.

- [ ] **Step 7: Commit**

```bash
git add Sources/PensieveKit/Query/NodeCommands.swift Tests/PensieveKitTests/NodeCommandsTests.swift \
        Sources/PensieveApp/NodeOrganizing.swift
git commit -F - <<'EOF'
feat(kit): a node's description becomes writable from the modal

NodeFields carries a description and update writes it, closing the gap
that made this slice necessary: nothing in the app could ever set one.

The parameter deliberately has no default. update is the only writer, so
a defaulted empty string would blank an existing description for any
caller that forgot it — compulsory means the compiler names every site.
EOF
```

---

### Task 5: `AppModel` — suggest a name, and carry the description through

**Files:**
- Modify: `Sources/PensieveApp/AppModel+Organizing.swift:157-180` (`commitNewNode`), `:182-195` (`updateNode`)

**Interfaces:**
- Consumes: `NodeLabeler.label(for:provider:)` (Task 3), `NodeFields.description` (Task 4), the existing `descriptionProvider` property (`AppModel.swift:96`, kept current by `rebuildSummaryBuilder()`).
- Produces: `AppModel.suggestName(for:) async -> String?` — used by Task 6.

- [ ] **Step 1: Add `suggestName`**

Append to the extension in `Sources/PensieveApp/AppModel+Organizing.swift`:

```swift
  /// A suggested node name for a typed description, off-main via the retained provider.
  /// Best-effort: returns nil only for empty input, so the caller always has something to show.
  /// Reuses `descriptionProvider` — the same resolved provider `rebuildSummaryBuilder()` keeps
  /// current — rather than holding a second one whose configuration could drift.
  func suggestName(for typed: String) async -> String? {
    await NodeLabeler.label(for: typed, provider: descriptionProvider)
  }
```

- [ ] **Step 2: Pass the description through both writes**

In `commitNewNode`, replace the `description: ""` argument with the real value:

```swift
      guard let new = try NodeCommands.add(database, name: trimmed, kind: fields.kind,
                                           parent: parentID?.uuidString, description: fields.description,
                                           icon: fields.icon, colorTag: fields.colorTag, context: fields.context) else {
```

`updateNode` needs no change — it already forwards `fields` wholesale to `NodeCommands.update`,
which now writes the description.

- [ ] **Step 3: Verify the app builds**

Run: `make build`
Expected: `** BUILD SUCCEEDED **`.

> Check the marker in the output, not `$?` after a pipe: `xcodebuild … | tail` reports `tail`'s
> exit code, so a failed build can look successful.

- [ ] **Step 4: Commit**

```bash
git add Sources/PensieveApp/AppModel+Organizing.swift
git commit -F - <<'EOF'
feat(app): the model suggests a name, and descriptions reach the store

suggestName routes a typed description through NodeLabeler on the
retained provider, and commitNewNode stops hardcoding an empty
description. updateNode needed nothing — it already forwards the fields
whole.
EOF
```

---

### Task 6: The modal grows a Description field and a Suggest button

**Files:**
- Modify: `Sources/PensieveApp/NodeOrganizing.swift:9-115` (`NodeEditor`)

**Interfaces:**
- Consumes: `AppModel.suggestName(for:)` (Task 5), `NodeFields(name:kind:description:icon:colorTag:context:)` (Task 4).

**Design notes for the implementer:**
- **One field, not two** — see "Deviation from the spec" above. The Description field *is* the
  typed description; the button derives the name from it.
- **The clobber rule is stateless:** capture the name before awaiting, and only assign the
  suggestion if the name is still exactly that. If the user typed while the model was thinking,
  their text wins. No dirty flag, no `onChange`.
- **Do not touch `Save`'s `.keyboardShortcut(.defaultAction)`.** The button is the affordance; no
  `onSubmit` goes into this sheet.

- [ ] **Step 1: Add the state**

In `struct NodeEditor`, beside the existing `@State` properties:

```swift
  @State private var nodeDescription = ""   // NOT `description` — that shadows CustomStringConvertible
  @State private var isSuggesting = false
```

- [ ] **Step 2: Render the field and the button**

Inside the left-hand `VStack`, immediately after the closing brace of the existing `Form { … }`
block and before the `Color` section:

```swift
          VStack(alignment: .leading, spacing: 6) {
            HStack {
              Text("Description").font(.caption).foregroundStyle(.secondary)
              Spacer()
              Button {
                Task { await suggestName() }
              } label: {
                if isSuggesting {
                  ProgressView().controlSize(.small)
                } else {
                  Text("Suggest name")
                }
              }
              .buttonStyle(.link)
              .disabled(isSuggesting || nodeDescription.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            TextField("What is this about?", text: $nodeDescription, axis: .vertical)
              .lineLimit(2...5)
              .textFieldStyle(.roundedBorder)
          }
```

- [ ] **Step 3: Add the suggest action with the clobber rule**

Add to `NodeEditor`, beside `commit()`:

```swift
  /// Fill `name` from the typed description. The suggestion is discarded if the user edited the
  /// name while it was in flight — comparing against the value captured before the await is all
  /// the bookkeeping that needs, and it means their typing always wins.
  private func suggestName() async {
    let typed = nodeDescription
    let nameBeforeSuggesting = name
    isSuggesting = true
    defer { isSuggesting = false }
    guard let suggested = await model.suggestName(for: typed) else { return }
    guard name == nameBeforeSuggesting else { return }
    name = suggested
  }
```

- [ ] **Step 4: Load and commit the description**

In `load()`, add `nodeDescription = ""` to the `.new` branch and
`nodeDescription = node.description` to the `.edit` branch.

In `commit()`, replace the fields construction:

```swift
    let fields = NodeFields(name: name, kind: kind, description: nodeDescription,
                            icon: icon, colorTag: colorTag, context: context)
```

- [ ] **Step 5: Build and smoke-launch**

```bash
make build
PENSIEVE_DB=/tmp/slice5-smoke.sqlite PENSIEVE_CAPTURE_DB=/tmp/slice5-smoke-capture.sqlite \
  ./.build-xcode/Build/Products/Debug/Pensieve.app/Contents/MacOS/Pensieve &
sleep 5 && kill %1
```

Expected: `** BUILD SUCCEEDED **`, and the app launches and exits without crashing.

- [ ] **Step 6: Check the file did not cross the line cap**

Run: `make lint`
Expected: PASS. `NodeOrganizing.swift` holds several types; if this pushes it past **400 lines**,
extract `NodeEditor` into `Sources/PensieveApp/NodeEditor.swift` (moving only that struct) rather
than relaxing the rule.

- [ ] **Step 7: Commit**

```bash
git add Sources/PensieveApp/NodeOrganizing.swift
git commit -F - <<'EOF'
feat(app): describe a node, and let the model name it

The New/Edit modal grows a Description field and a Suggest name button
beside it. One field rather than the spec's two: the description IS the
typed text, so a separate prompt field would have shown the same words
twice and made the user pick which to edit. The button is also the
explicit affordance the spec asked for, so Save keeps the default action
uncontested and no onSubmit goes into a sheet.

A suggestion is discarded if the name changed while it was in flight,
compared against the value captured before the await — so typing always
beats the model.
EOF
```

---

### Task 7: A new node lands under what you are looking at

Today ⌘N and the toolbar "+" both pass `nil`, so every quick-add lands at top level regardless of
context. Worth having on its own, and it is what "sensibly parented" means now that model-assisted
parenting is deferred.

**Files:**
- Modify: `Sources/PensieveApp/AppModel+Organizing.swift:31-32`
- Modify: `Sources/PensieveApp/PensieveApp.swift:45`, `Sources/PensieveApp/RootView.swift:48`

- [ ] **Step 1: Add the defaulted entry point**

In `Sources/PensieveApp/AppModel+Organizing.swift`, beside `presentNewNode`:

```swift
  /// Open the New Node modal parented at what the user is currently looking at. An archived
  /// selection falls back to the top level: a child of an archived node would be created `active`
  /// and immediately read as a phantom root, which is why the context menu hides "New Child…"
  /// on archived rows too.
  func presentNewNodeAtSelection() {
    guard let selectedNodeID, let selected = node(selectedNodeID), selected.state != .archived else {
      presentNewNode(under: nil)
      return
    }
    presentNewNode(under: selected.id)
  }
```

- [ ] **Step 2: Point both fast paths at it**

- `Sources/PensieveApp/PensieveApp.swift:45` — `Button("New Node") { model.presentNewNode(under: nil) }` → `Button("New Node") { model.presentNewNodeAtSelection() }`
- `Sources/PensieveApp/RootView.swift:48` — `Button { model.presentNewNode(under: nil) } label: { Image(systemName: "plus") }` → `Button { model.presentNewNodeAtSelection() } label: { Image(systemName: "plus") }`

Leave `NodeOrganizing.swift:129` (`New Child…`) alone — it already passes the intended parent.

- [ ] **Step 3: Build and smoke-launch**

```bash
make build
PENSIEVE_DB=/tmp/slice5-smoke.sqlite PENSIEVE_CAPTURE_DB=/tmp/slice5-smoke-capture.sqlite \
  ./.build-xcode/Build/Products/Debug/Pensieve.app/Contents/MacOS/Pensieve &
sleep 5 && kill %1
```

Expected: `** BUILD SUCCEEDED **` and a clean launch.

- [ ] **Step 4: Commit**

```bash
git add Sources/PensieveApp/AppModel+Organizing.swift Sources/PensieveApp/PensieveApp.swift \
        Sources/PensieveApp/RootView.swift
git commit -F - <<'EOF'
feat(app): a new node lands under what you are looking at

Both fast paths passed nil, so every quick-add landed at top level no
matter which project was on screen. They now parent at the selection, and
an archived selection still falls back to the top level rather than
creating a phantom active child under it.
EOF
```

---

### Task 8: Localize the new chrome

Only chrome. The name and description are captured content and are **never** localized.

**Files:**
- Modify: `Sources/PensieveApp/Localizable.xcstrings`

- [ ] **Step 1: Add the three keys by hand**

`xcodebuild` does not populate the catalog (IDE-only), so author these against the Swift literals
exactly as written in Task 6. For each key add an `en` and a `de` entry in the file's existing
shape (`"extractionState": "manual"`, `"localizations": { "en": { "stringUnit": { "state": "translated", "value": … } }, "de": { … } }`), matching the neighbouring entries' formatting:

| key | en | de |
|---|---|---|
| `Description` | Description | Beschreibung |
| `Suggest name` | Suggest name | Namen vorschlagen |
| `What is this about?` | What is this about? | Worum geht es? |

- [ ] **Step 2: Verify each new key carries a German value**

A key present with no `de` value silently falls back to English — the failure mode that shipped six
mis-keyed entries before. Check each of the three:

```bash
for key in "Description" "Suggest name" "What is this about?"; do
  printf '%s -> ' "$key"
  plutil -extract "strings.$key.localizations.de.stringUnit.value" raw \
    Sources/PensieveApp/Localizable.xcstrings 2>/dev/null || echo "MISSING de"
done
```

Expected: `Beschreibung`, `Namen vorschlagen`, `Worum geht es?` — no `MISSING de`.

- [ ] **Step 3: Build**

Run: `make build`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Commit**

```bash
git add Sources/PensieveApp/Localizable.xcstrings
git commit -F - <<'EOF'
i18n: the description field and its suggest button speak German

Chrome only. The description and the name are captured content and stay
in whatever language they were typed.
EOF
```

---

### Task 9: Full verification and the changelog

**Files:**
- Modify: `CLAUDE.md` (Status bullet), `docs/superpowers/backlog.md` (the three-pane slice list)

- [ ] **Step 1: Run everything CI runs**

Run: `make all`
Expected: lint, the full test suite, the build and the embedded-CLI smoke all pass. Record the test
count — it should be **prior total + 9** (2 moved in Task 1 are not new; +3 shorten, +5 NodeLabeler,
+1 NodeCommands).

- [ ] **Step 2: Confirm the trust gate was not touched**

```bash
git diff main --stat -- Sources/PensieveKit/Transcript Sources/PensieveKit/Intelligence/LooseEndVerifier.swift
```
Expected: **empty**. If anything appears, stop and report it — this slice must not touch extraction.

- [ ] **Step 3: Confirm nothing unrelated is staged**

```bash
git diff main --stat
```
Expected: only the files this plan names. `Package.resolved` must **not** appear — discard it with
`git checkout Package.resolved` if an `xcodebuild` churned it.

- [ ] **Step 4: Update the changelog**

Add a Status bullet to `CLAUDE.md` following the shape of its neighbours: what shipped, the Kit
units, the app change, the measured reason naming routes by language, the deferred parenting
increment and its trigger, and the new test count. Mark slice 5 done in the backlog's three-pane
list (`Pending pillars` → item 2), noting that the parenting half is deferred with its own trigger.

- [ ] **Step 5: Commit**

```bash
git add CLAUDE.md docs/superpowers/backlog.md
git commit -F - <<'EOF'
docs: slice 5 ships describe-it-get-a-node

Names route by language on measured evidence, descriptions are writable
from the app for the first time, and a new node lands under what you are
looking at. Model-assisted parenting stays deferred behind its own
measurement.
EOF
```

---

## Human-verify carries

The app target has no unit tests, so these need the built app at `/Applications` and the real store.
Install with `make install`, then launch with `make run` (never `open ./.build-xcode/…`, which
launches whichever bundle Spotlight picks).

- Type an **English** sentence, press Suggest — a terse readable label appears in Name, and the
  sentence stays in Description untouched.
- Type a **German** sentence, press Suggest — the name comes back **in German**, never translated.
  This is the whole reason the routing exists.
- Press Suggest, then immediately type in Name — your text survives; the suggestion is discarded.
- Select a cloud provider with no API key, press Suggest — a name still appears (the deterministic
  shortening), no error, and Save is enabled.
- Edit an existing node: its description loads, edits save, and editing only the *name* leaves the
  description intact.
- ⌘N with a project selected creates **under it**; with an archived node selected, at top level.
- Pressing Return in the Description field does not trigger Save.
- `pensieve list` shows the node where the app said it would.
- German in situ: `open -a Pensieve --args -AppleLanguages '(de)'` — check "Beschreibung",
  "Namen vorschlagen", "Worum geht es?" and that none of them truncate.

## Gotchas carried into this work

- **`log` is shadowed by a shell function here** — use `/usr/bin/log`.
- **`xcodebuild … | tail` reports `tail`'s exit code.** Grep for `** BUILD SUCCEEDED **`.
- On a SwiftSyntax/macro linker error, `rm -rf .build` and retry.
- **Never `rm -rf .build-xcode`** while `/Applications/Pensieve.app` is registered with SMAppService.
- The user may be committing on `main` in parallel — **stage only the files you changed**, never
  `git add -A`.
