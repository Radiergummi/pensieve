# Translation Settings — Pack Management, Coverage & Backfill Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give Settings ▸ Intelligence a real translation surface — a picker over the languages this
Mac can actually translate into, language-pack status with a download button and a link to the OS pane
that owns pack lifecycle, a measured coverage readout, and one explicit cancellable resumable backfill
that translates the rest of the corpus.

**Architecture:** Three new tested PensieveKit types (`TranslatableCorpus`, `TranslationCoverage`,
`TranslationBackfill`) plus one predicate extraction inside `EmbeddableCorpus` so the backfill and the
search corpus cannot disagree about what is translatable. The app half is thin: one new
`TranslationSettingsSection.swift` doing an async `LanguageAvailability` probe, and three methods on
`AppModel` that own the backfill task so closing Settings does not kill a run.

**Tech Stack:** Swift 6, SwiftUI, Swift Testing, GRDB/SQLiteData, the macOS `Translation` framework
(`LanguageAvailability` 15+, `TranslationSession(installedSource:)` 26+), XcodeGen + xcodebuild.

**Spec:** `docs/superpowers/specs/2026-08-14-translation-settings-coverage-design.md`

## Global Constraints

- **Trust gate untouched.** No case is added to `TranslationField`. Nothing here reads or writes a
  loose end's `quote`, a transcript message, or any captured text. No `LLMProvider` is involved.
- **No `EvalTask`.** Translation is not LLM-backed, so the `registry ↔ config` test is unaffected.
- **Explicit names, no abbreviations.** Write `database`/`node`/`looseEnd`/`translation`, never
  `db`/`n`/`le`. SwiftLint's `identifier_name` is enforced in CI and must not be relaxed.
- **SwiftLint `--strict` in CI**, `.swiftlint.yml` at the repo root, **400-line file cap**.
  `IntelligenceSettingsTab.swift` is already 261 lines — that is why Task 5 creates a new file.
- **SQLiteData 1.6.6 predicates use `.eq(x)` / `.neq(x)`, never `== x`** (`==` is `unavailable` and
  will not compile).
- **Swift only. No Python, ever.**
- **Run everything through `make`:** `make test [FILTER=<name>]`, `make lint`, `make build`,
  `make all`. `make build` runs `xcodegen generate` first — **required** after adding an app file,
  since `Pensieve.xcodeproj` is generated and gitignored.
- **The String Catalog is hand-authored.** `xcodebuild … build` does **not** populate
  `Sources/PensieveApp/Localizable.xcstrings` (IDE-only). Keys must match the Swift literals exactly;
  a mis-keyed `de` value silently falls back to English. Use `%lld` for integers and positional
  `%1$lld` / `%2$lld` in German where word order differs. German is impersonal/infinitive.
- **Chrome is localized; content is not.** Language display names come from `Locale` and are rendered
  with `Text(verbatim:)` — never a catalog key.
- **Availability floors:** app deployment target is ~~15.0~~ **26.0** (`project.yml:9` — corrected
  2026-08-14 during the pre-flight scan; harmless in both directions), so `LanguageAvailability`
  (15+) needs no annotation in the app target — but it also means every `if #available(macOS 26, *)`
  guard below is always-true and the pre-26 fallback text is unreachable in this build. Both were kept
  deliberately: the spec's degradation table calls for them and they mirror surrounding code. `Package.swift` stays `.macOS(.v14)`, so **no Kit file added by this
  plan may import `Translation`** — Kit's only `Translation` use stays the existing
  `@available(macOS 26, *) SystemTranslator`. Translating and downloading stay behind
  `if #available(macOS 26, *)`.
- **The app target has no unit tests.** App tasks verify with `make build` + `make lint` and hand off
  to the human-verify checklist in Task 8. Note the known limitation recorded in `CLAUDE.md`: the
  documented smoke-launch recipe renders no view body, so it does not exercise `AppModel` or any
  `.task`.

---

### Task 1: Shared eligibility + `TranslatableCorpus`

The set of `(field, sourceText)` pairs the search corpus will look up a translation for. Eligibility is
**extracted** from `EmbeddableCorpus.gather` rather than restated, because this project's recurring
defect is two paths that were supposed to agree and drifted (`SearchHitResolver` had to be extracted
for exactly this reason; the loose-end-resolution branch found the index filter and the canonical
re-check disagreeing about `isOpen`).

**Files:**
- Create: `Sources/PensieveKit/Translation/TranslatableCorpus.swift`
- Modify: `Sources/PensieveKit/Search/EmbeddableItem.swift:94-95` (node fetch), `:111` (loose-end
  fetch) — extract both into shared internal helpers; add `import GRDB`
- Test: `Tests/PensieveKitTests/TranslatableCorpusTests.swift`

**Interfaces:**
- Consumes: `TranslationField` (`Sources/PensieveKit/Translation/TranslationField.swift`) — cases
  `narration`, `looseEndText`, `nodeName`, `nodeDescription`; `TranslationStore.put/translation`;
  `EmbeddableCorpus.gather(_:translations:language:)`.
- Produces:
  ```swift
  public struct TranslatableUnit: Hashable, Sendable {
    public let field: TranslationField
    public let sourceText: String
    public init(field: TranslationField, sourceText: String)
  }
  public enum TranslatableCorpus {
    public static func gather(_ database: any DatabaseReader) throws -> [TranslatableUnit]
  }
  // internal, inside EmbeddableCorpus:
  static func corpusNodes(_ database: Database) throws -> [Node]
  static func corpusLooseEnds(_ database: Database) throws -> [LooseEnd]
  ```

- [ ] **Step 1: Write the failing tests**

Create `Tests/PensieveKitTests/TranslatableCorpusTests.swift`:

```swift
// Tests/PensieveKitTests/TranslatableCorpusTests.swift
import Testing
import Foundation
import SQLiteData
@testable import PensieveKit

@Suite struct TranslatableCorpusTests {
  /// Direction 1 of the anti-drift pin: every unit the producer emits must be a lookup `gather`
  /// actually performs. Asserted on the translated document's TEXT, not just its existence — a node
  /// emits ONE document for name+description, so a count-only assertion would still pass if
  /// `.nodeDescription` were dropped from the unit set.
  ///
  /// FAILS UNDER MUTATION: remove `.nodeDescription` (or `.nodeName`, or `.looseEndText`) from
  /// `TranslatableCorpus.gather`.
  @Test func everyUnitIsALookupTheCorpusPerforms() async throws {
    let database = try openCanonicalDatabase(at: tempURL("translatable-covers"))
    let node = Node(name: "Background sync", kind: NodeKind.project,
                    description: "The launchd agent")
    let looseEnd = LooseEnd(nodeID: node.id, sourceEventID: UUID(), text: "Reinstall the agent",
                            quote: "we should reinstall the agent")
    try await database.write { database in
      try Node.insert { node }.execute(database)
      try LooseEnd.insert { looseEnd }.execute(database)
    }

    let units = try TranslatableCorpus.gather(database)
    let store = TranslationStore(url: tempURL("translatable-covers-cache"))
    // Translate via the unit set ONLY. Anything gather looks up that the units missed stays English.
    for unit in units {
      store.put(field: unit.field, sourceText: unit.sourceText, language: "xx",
                text: "xx:" + unit.sourceText)
    }

    let items = try EmbeddableCorpus.gather(database, translations: store, language: "xx")
    let translatedNode = items.first { $0.itemID == node.id.uuidString && $0.language == "xx" }
    let translatedEnd = items.first { $0.itemID == looseEnd.id.uuidString && $0.language == "xx" }
    #expect(translatedNode?.text == "xx:Background sync — xx:The launchd agent")
    #expect(translatedEnd?.text == "xx:Reinstall the agent")
  }

  /// Direction 2: the producer must not emit units for text `gather` never looks up. A quote is the
  /// trust-gate case (verbatim provenance is never translated) and a muted node is the eligibility
  /// case.
  ///
  /// FAILS UNDER MUTATION: add the quote, or drop the `state` filter, in `TranslatableCorpus.gather`.
  @Test func noUnitExistsForTextTheCorpusNeverLooksUp() async throws {
    let database = try openCanonicalDatabase(at: tempURL("translatable-excludes"))
    // Argument order follows the declaration: `state` precedes `kind` in `Node.init`.
    let muted = Node(name: "Muted project", state: .muted, kind: NodeKind.project)
    let active = Node(name: "Active project", kind: NodeKind.project)
    let looseEnd = LooseEnd(nodeID: active.id, sourceEventID: UUID(), text: "A real end",
                            quote: "the verbatim quote")
    let noise = LooseEnd(nodeID: active.id, sourceEventID: UUID(), text: "Not an end",
                         quote: "q", label: LooseEndLabel.noise)
    try await database.write { database in
      try Node.insert { muted }.execute(database)
      try Node.insert { active }.execute(database)
      try LooseEnd.insert { looseEnd }.execute(database)
      try LooseEnd.insert { noise }.execute(database)
    }

    let texts = Set(try TranslatableCorpus.gather(database).map(\.sourceText))
    #expect(texts.contains("Active project"))
    #expect(texts.contains("A real end"))
    #expect(!texts.contains("the verbatim quote"))   // trust gate
    #expect(!texts.contains("Muted project"))
    #expect(!texts.contains("Not an end"))
  }

  /// Coverage is counted by DISTINCT text because `TranslationStore` is keyed by
  /// `(field, source_hash, language)`: two nodes named "Agent" collapse onto one stored row. The eval
  /// run measured this — 278 node names, 272 distinct strings. A row-count denominator could never
  /// reach 100%.
  @Test func identicalTextsCollapseToOneUnit() async throws {
    let database = try openCanonicalDatabase(at: tempURL("translatable-dedupe"))
    let first = Node(name: "Agent", kind: NodeKind.project)
    let second = Node(name: "Agent", kind: NodeKind.project)
    try await database.write { database in
      try Node.insert { first }.execute(database)
      try Node.insert { second }.execute(database)
    }
    let names = try TranslatableCorpus.gather(database).filter { $0.field == .nodeName }
    #expect(names.count == 1)
  }

  /// An empty description is not a translatable unit — `gather` joins only non-empty halves, so a
  /// unit for "" would be a denominator entry that can never be satisfied.
  @Test func emptyDescriptionsAreNotUnits() async throws {
    let database = try openCanonicalDatabase(at: tempURL("translatable-empty"))
    let node = Node(name: "No description", kind: NodeKind.project)
    try await database.write { database in try Node.insert { node }.execute(database) }
    let units = try TranslatableCorpus.gather(database)
    #expect(units.count == 1)
    #expect(units.allSatisfy { $0.field == .nodeName })
  }

  /// Narration is display-only and lives in a separate disposable cache; it is not corpus content and
  /// must never enter the backfill denominator.
  @Test func narrationIsNeverAUnit() async throws {
    let database = try openCanonicalDatabase(at: tempURL("translatable-no-narration"))
    let node = Node(name: "Some project", kind: NodeKind.project)
    try await database.write { database in try Node.insert { node }.execute(database) }
    #expect(try TranslatableCorpus.gather(database).allSatisfy { $0.field != .narration })
  }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
make test FILTER=TranslatableCorpusTests
```

Expected: compile failure — `cannot find 'TranslatableCorpus' in scope`.

- [ ] **Step 3: Extract the two eligibility predicates**

In `Sources/PensieveKit/Search/EmbeddableItem.swift`, add `import GRDB` beside the existing
`import SQLiteData` (the inner closure parameter is a GRDB `Database`, and the helpers name that type
explicitly). Then add these two helpers to `EmbeddableCorpus`, directly above `gather`:

```swift
  /// The nodes the corpus covers: active AND archived. Archiving hides work from the normal views, it
  /// does not make the work unrecallable; `muted` stays out entirely.
  ///
  /// Extracted so `TranslatableCorpus` reads eligibility from HERE rather than restating it. The
  /// backfill's denominator and the corpus's lookups have to be the same set, and two copies of a
  /// filter are how they stop being.
  static func corpusNodes(_ database: Database) throws -> [Node] {
    try Node.all.fetchAll(database).filter { $0.state == .active || $0.state == .archived }
  }

  /// Open AND closed loose ends, `noise` excluded. `isOpen` conflates the two, so the predicate is
  /// spelled out: 👎 asserts the text was never a loose end, whereas a closed end was real work.
  /// Shared with `TranslatableCorpus` — see `corpusNodes`.
  static func corpusLooseEnds(_ database: Database) throws -> [LooseEnd] {
    try LooseEnd.where { $0.label.neq(LooseEndLabel.noise) }.fetchAll(database)
  }
```

Now replace the two inline fetches in `gather` with calls to them. The node fetch at `:94-95`:

```swift
      let nodes = try Self.corpusNodes(database)
```

and the loose-end fetch at `:111`:

```swift
      let ends = try Self.corpusLooseEnds(database)
```

Leave every surrounding comment and every other line of `gather` untouched — this is a refactor, and
the existing suite is the evidence for that claim.

- [ ] **Step 4: Write `TranslatableCorpus`**

Create `Sources/PensieveKit/Translation/TranslatableCorpus.swift`:

```swift
import Foundation
import SQLiteData

/// One piece of generated text that can be translated, identified the way `TranslationStore` keys it:
/// by field and by the source text itself. No ids — the store is content-keyed, so an id would be a
/// second identity for the same row and a way for a reader and a writer to disagree.
public struct TranslatableUnit: Hashable, Sendable {
  public let field: TranslationField
  public let sourceText: String
  public init(field: TranslationField, sourceText: String) {
    self.field = field
    self.sourceText = sourceText
  }
}

/// Every `(field, text)` pair `EmbeddableCorpus.gather` will look up a translation for, deduplicated.
///
/// This is the denominator of the coverage readout and the work list of the backfill — deliberately
/// one type serving both, so the number shown and the work done cannot disagree.
///
/// Eligibility is NOT restated here: the node and loose-end fetches come from
/// `EmbeddableCorpus.corpusNodes`/`corpusLooseEnds`, which `gather` itself uses. A translation of text
/// the corpus never looks up is wasted work that no surface can ever show, and a unit the corpus DOES
/// look up but this producer omits is a permanently untranslated document. `TranslatableCorpusTests`
/// pins both directions.
///
/// `TranslationField.narration` is absent by construction: narration lives in the disposable
/// `NarrationCache`, is not corpus content, and already translates automatically on open.
public enum TranslatableCorpus {
  public static func gather(_ database: any DatabaseReader) throws -> [TranslatableUnit] {
    try database.read { database in
      var seen: Set<TranslatableUnit> = []
      var units: [TranslatableUnit] = []
      // Deduplicated on the way in rather than at the end, so ORDER is the corpus's own walk order
      // (nodes then loose ends) and the progress readout advances the way the tree reads.
      func append(_ field: TranslationField, _ sourceText: String) {
        guard !sourceText.isEmpty else { return }
        let unit = TranslatableUnit(field: field, sourceText: sourceText)
        guard seen.insert(unit).inserted else { return }
        units.append(unit)
      }
      let nodes = try EmbeddableCorpus.corpusNodes(database)
      for node in nodes {
        append(.nodeName, node.name)
        append(.nodeDescription, node.description)
      }
      // The same join `gather` performs via its `stateByNodeID` lookup: a loose end under a node the
      // corpus does not cover produces no document, so it is not translatable work.
      let coveredNodeIDs = Set(nodes.map(\.id))
      for looseEnd in try EmbeddableCorpus.corpusLooseEnds(database)
      where coveredNodeIDs.contains(looseEnd.nodeID) {
        // Text ONLY, never the quote. The quote is verbatim provenance: translating it would break
        // the citation it exists to prove. `TranslationField` has no case for it; this comment
        // records why the omission is deliberate rather than forgotten.
        append(.looseEndText, looseEnd.text)
      }
      return units
    }
  }
}
```

- [ ] **Step 5: Run the new tests and the corpus suites**

```bash
make test FILTER=TranslatableCorpusTests
make test FILTER=TranslatedCorpusTests
make test FILTER=EmbeddableCorpusHygieneTests
make test FILTER=CorpusHashTests
```

Expected: all PASS. The last three are the evidence that the extraction changed no behaviour.

- [ ] **Step 6: Run the full suite and lint**

```bash
make test
make lint
```

Expected: PASS, 0 violations.

- [ ] **Step 7: Commit**

```bash
git add Sources/PensieveKit/Translation/TranslatableCorpus.swift \
        Sources/PensieveKit/Search/EmbeddableItem.swift \
        Tests/PensieveKitTests/TranslatableCorpusTests.swift
git commit -m "feat(kit): the corpus tells the backfill what is translatable"
```

---

### Task 2: `TranslationCoverage`

What is translated, what is missing, per field. Pure over one store read per unit.

**Files:**
- Create: `Sources/PensieveKit/Translation/TranslationCoverage.swift`
- Test: `Tests/PensieveKitTests/TranslationCoverageTests.swift`

**Interfaces:**
- Consumes: `TranslatableUnit`, `TranslationStore.translation(field:sourceText:language:)`,
  `TranslationTarget.off`.
- Produces:
  ```swift
  public struct TranslationCoverage: Sendable {
    public struct Field: Sendable, Hashable {
      public let field: TranslationField
      public let translated: Int
      public let total: Int
    }
    public let fields: [Field]
    public let missing: [TranslatableUnit]
    public var translated: Int { get }
    public var total: Int { get }
    public static func measure(units: [TranslatableUnit], store: TranslationStore,
                               language: String) -> TranslationCoverage
  }
  ```

- [ ] **Step 1: Write the failing tests**

Create `Tests/PensieveKitTests/TranslationCoverageTests.swift`:

```swift
// Tests/PensieveKitTests/TranslationCoverageTests.swift
import Testing
import Foundation
@testable import PensieveKit

@Suite struct TranslationCoverageTests {
  private func units() -> [TranslatableUnit] {
    [TranslatableUnit(field: .nodeName, sourceText: "Background sync"),
     TranslatableUnit(field: .nodeDescription, sourceText: "The launchd agent"),
     TranslatableUnit(field: .looseEndText, sourceText: "Reinstall the agent"),
     TranslatableUnit(field: .looseEndText, sourceText: "Check the log")]
  }

  @Test func partialCoverageCountsPerFieldAndInTotal() {
    let store = TranslationStore(url: tempURL("coverage-partial"))
    store.put(field: .nodeName, sourceText: "Background sync", language: "de", text: "Hintergrund")
    store.put(field: .looseEndText, sourceText: "Check the log", language: "de", text: "Log prüfen")

    let coverage = TranslationCoverage.measure(units: units(), store: store, language: "de")
    #expect(coverage.translated == 2)
    #expect(coverage.total == 4)
    #expect(coverage.fields.first { $0.field == .looseEndText }?.translated == 1)
    #expect(coverage.fields.first { $0.field == .looseEndText }?.total == 2)
    #expect(coverage.fields.first { $0.field == .nodeDescription }?.translated == 0)
  }

  /// `missing` is what the backfill consumes, so it must be exactly the complement of what is stored.
  /// One list, two uses — the readout and the work cannot disagree.
  @Test func missingIsExactlyTheComplementOfWhatIsStored() {
    let store = TranslationStore(url: tempURL("coverage-missing"))
    store.put(field: .nodeName, sourceText: "Background sync", language: "de", text: "Hintergrund")

    let coverage = TranslationCoverage.measure(units: units(), store: store, language: "de")
    #expect(coverage.missing.count == 3)
    #expect(!coverage.missing.contains(TranslatableUnit(field: .nodeName,
                                                        sourceText: "Background sync")))
    #expect(coverage.missing.contains(TranslatableUnit(field: .looseEndText,
                                                       sourceText: "Check the log")))
  }

  /// A translation stored for a DIFFERENT language does not count. Coverage is always per current
  /// target: switching languages must show 0, not the previous language's progress.
  @Test func anotherLanguageDoesNotCount() {
    let store = TranslationStore(url: tempURL("coverage-other-language"))
    store.put(field: .nodeName, sourceText: "Background sync", language: "de", text: "Hintergrund")
    let coverage = TranslationCoverage.measure(units: units(), store: store, language: "fr")
    #expect(coverage.translated == 0)
    #expect(coverage.missing.count == 4)
  }

  /// Off means off: a zeroed coverage, and no store read at all.
  @Test func offYieldsZeroAndNothingMissing() {
    let store = TranslationStore(url: tempURL("coverage-off"))
    store.put(field: .nodeName, sourceText: "Background sync", language: "de", text: "Hintergrund")
    let coverage = TranslationCoverage.measure(units: units(), store: store,
                                              language: TranslationTarget.off)
    #expect(coverage.total == 0)
    #expect(coverage.translated == 0)
    #expect(coverage.missing.isEmpty)
  }

  /// A field with no units must not appear at all, rather than appearing as "0 of 0" — a zero-total
  /// row reads as a failure in a UI that lists it.
  @Test func fieldsWithNoUnitsAreAbsent() {
    let store = TranslationStore(url: tempURL("coverage-absent-field"))
    let coverage = TranslationCoverage.measure(
      units: [TranslatableUnit(field: .nodeName, sourceText: "Only a name")],
      store: store, language: "de")
    #expect(coverage.fields.count == 1)
    #expect(coverage.fields.first?.field == .nodeName)
  }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
make test FILTER=TranslationCoverageTests
```

Expected: compile failure — `cannot find 'TranslationCoverage' in scope`.

- [ ] **Step 3: Write the implementation**

Create `Sources/PensieveKit/Translation/TranslationCoverage.swift`:

```swift
import Foundation

/// How much of the translatable corpus is actually translated, and what is left.
///
/// Exists because the feature is otherwise indistinguishable from a broken one: on 2026-08-14 the live
/// store held 2 translations against 1,294 translatable texts, and nothing said so. Two of the three
/// fields the corpus looks up had no writer at all.
///
/// Counted by DISTINCT source text, because that is how `TranslationStore` is keyed — see
/// `TranslatableCorpus`.
public struct TranslationCoverage: Sendable {
  public struct Field: Sendable, Hashable {
    public let field: TranslationField
    public let translated: Int
    public let total: Int
    public init(field: TranslationField, translated: Int, total: Int) {
      self.field = field
      self.translated = translated
      self.total = total
    }
  }

  /// Only fields with at least one unit. A "0 of 0" row reads as a failure in a list.
  public let fields: [Field]
  /// The units with no stored translation, in corpus order — the backfill's work list. The same list
  /// the count above is derived from, so the readout and the work can never disagree.
  public let missing: [TranslatableUnit]

  public var translated: Int { fields.reduce(0) { $0 + $1.translated } }
  public var total: Int { fields.reduce(0) { $0 + $1.total } }

  public init(fields: [Field], missing: [TranslatableUnit]) {
    self.fields = fields
    self.missing = missing
  }

  /// One store read per unit. `language == off` returns an empty coverage WITHOUT reading, so a
  /// disabled feature opens no file — the same "off means off" rule the lazy stores in `AppModel`
  /// follow.
  public static func measure(units: [TranslatableUnit], store: TranslationStore,
                             language: String) -> TranslationCoverage {
    guard !language.isEmpty else { return TranslationCoverage(fields: [], missing: []) }
    var totals: [TranslationField: Int] = [:]
    var translatedCounts: [TranslationField: Int] = [:]
    var missing: [TranslatableUnit] = []
    for unit in units {
      totals[unit.field, default: 0] += 1
      if store.translation(field: unit.field, sourceText: unit.sourceText, language: language) != nil {
        translatedCounts[unit.field, default: 0] += 1
      } else {
        missing.append(unit)
      }
    }
    // `allCases` order, so the readout is stable across runs rather than dictionary order.
    let fields = TranslationField.allCases.compactMap { field -> Field? in
      guard let total = totals[field] else { return nil }
      return Field(field: field, translated: translatedCounts[field] ?? 0, total: total)
    }
    return TranslationCoverage(fields: fields, missing: missing)
  }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

```bash
make test FILTER=TranslationCoverageTests
```

Expected: all PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/PensieveKit/Translation/TranslationCoverage.swift \
        Tests/PensieveKitTests/TranslationCoverageTests.swift
git commit -m "feat(kit): count what is translated, and what is left"
```

---

### Task 3: `TranslationBackfill`

The bulk pass. Five properties, four of them scars from the eval run that already did this work once
(`docs/superpowers/measurements/2026-08-12-translation-ranking/README.md` § "What surprised us").

**Files:**
- Create: `Sources/PensieveKit/Translation/TranslationBackfill.swift`
- Test: `Tests/PensieveKitTests/TranslationBackfillTests.swift`

**Interfaces:**
- Consumes: `TranslatableUnit`, `TranslationStore`, `Translator.translate(_:from:to:)`,
  `TranslationTarget.sourceLanguage`.
- Produces:
  ```swift
  public enum TranslationBackfill {
    /// Returns the number of translations newly written.
    public static func run(units: [TranslatableUnit], store: TranslationStore,
                           translator: any Translator, language: String,
                           progress: @Sendable (Int, Int) -> Void) async -> Int
  }
  ```

- [ ] **Step 1: Write the failing tests**

Create `Tests/PensieveKitTests/TranslationBackfillTests.swift`. The `GateTranslator` is what makes the
cancellation test deterministic rather than timing-dependent — slice 3b already rejected flaky timing
tests in this codebase, so the stub parks the run at a known point instead of racing it:

```swift
// Tests/PensieveKitTests/TranslationBackfillTests.swift
import Testing
import Foundation
@testable import PensieveKit

@Suite struct TranslationBackfillTests {
  /// Records every call, so negative assertions ("it did not call the translator again") are real
  /// rather than inferred from the store. Same shape as `TranslatedSearchTests.RecordingTranslator`.
  private actor RecordingTranslator: Translator {
    private(set) var calls: [String] = []
    private let prefix: String
    private let returnsNil: Bool
    init(prefix: String = "de:", returnsNil: Bool = false) {
      self.prefix = prefix
      self.returnsNil = returnsNil
    }
    func translate(_ text: String, from source: String, to target: String) async -> String? {
      calls.append(text)
      return returnsNil ? nil : prefix + text
    }
    func callCount() -> Int { calls.count }
  }

  /// Parks inside the first `translate` call until the test opens the gate, so cancellation lands at
  /// a KNOWN point. Without this the loop can finish before `cancel()` is observed, and the test
  /// passes or fails by scheduling luck.
  private actor GateTranslator: Translator {
    private(set) var calls: [String] = []
    private var arrived: CheckedContinuation<Void, Never>?
    private var release: CheckedContinuation<Void, Never>?
    private var isOpen = false

    func translate(_ text: String, from source: String, to target: String) async -> String? {
      calls.append(text)
      arrived?.resume()
      arrived = nil
      if !isOpen {
        await withCheckedContinuation { continuation in release = continuation }
      }
      return "de:" + text
    }

    /// Returns once the run has entered its first `translate`.
    func waitForFirstCall() async {
      guard calls.isEmpty else { return }
      await withCheckedContinuation { continuation in arrived = continuation }
    }

    /// Lets the parked call finish, and stops parking later ones.
    func open() {
      isOpen = true
      release?.resume()
      release = nil
    }

    func callCount() -> Int { calls.count }
  }

  private let units = [TranslatableUnit(field: .nodeName, sourceText: "one"),
                       TranslatableUnit(field: .nodeName, sourceText: "two"),
                       TranslatableUnit(field: .looseEndText, sourceText: "three")]

  @Test func writesEveryMissingUnitAndReportsProgress() async {
    let store = TranslationStore(url: tempURL("backfill-writes"))
    let translator = RecordingTranslator()
    let reported = Reported()
    let written = await TranslationBackfill.run(units: units, store: store, translator: translator,
                                                language: "de") { done, total in
      reported.record(done: done, total: total)
    }
    #expect(written == 3)
    #expect(store.translation(field: .nodeName, sourceText: "two", language: "de") == "de:two")
    #expect(store.translation(field: .looseEndText, sourceText: "three", language: "de") == "de:three")
    #expect(reported.pairs == [(1, 3), (2, 3), (3, 3)])
  }

  /// Idempotence — the property the eval generator lacked, which is why it could not be re-run after
  /// dying at 522/870. A second press must pay only for what is missing.
  ///
  /// FAILS UNDER MUTATION: remove the check-then-skip guard.
  @Test func aSecondRunTranslatesNothing() async {
    let store = TranslationStore(url: tempURL("backfill-idempotent"))
    let first = RecordingTranslator()
    _ = await TranslationBackfill.run(units: units, store: store, translator: first,
                                      language: "de", progress: { _, _ in })
    let second = RecordingTranslator()
    let written = await TranslationBackfill.run(units: units, store: store, translator: second,
                                                language: "de", progress: { _, _ in })
    #expect(written == 0)
    #expect(await second.callCount() == 0)
  }

  /// Cancellation stops the run and keeps what already landed. Deterministic via `GateTranslator`.
  ///
  /// FAILS UNDER MUTATION: remove the `Task.isCancelled` check — call count becomes 3.
  @Test func cancellationKeepsWhatLandedAndStops() async {
    let store = TranslationStore(url: tempURL("backfill-cancel"))
    let translator = GateTranslator()
    let work = Task {
      await TranslationBackfill.run(units: units, store: store, translator: translator,
                                    language: "de", progress: { _, _ in })
    }
    await translator.waitForFirstCall()   // parked inside unit 1
    work.cancel()
    await translator.open()               // let unit 1 finish; the loop then sees the cancellation
    let written = await work.value

    #expect(written == 1)
    #expect(await translator.callCount() == 1)
    #expect(store.translation(field: .nodeName, sourceText: "one", language: "de") == "de:one")
    #expect(store.translation(field: .nodeName, sourceText: "two", language: "de") == nil)
  }

  /// A nil is skipped, counted as attempted, and NOT retried within the run — an absent language pack
  /// nils every call, and 1,294 retries of a condition that cannot change mid-run is a hang wearing a
  /// progress bar. A later run tries again, which is honest: the pack may since have installed.
  @Test func nilTranslationsAreSkippedNotRetried() async {
    let store = TranslationStore(url: tempURL("backfill-nil"))
    let translator = RecordingTranslator(returnsNil: true)
    let written = await TranslationBackfill.run(units: units, store: store, translator: translator,
                                                language: "de", progress: { _, _ in })
    #expect(written == 0)
    #expect(await translator.callCount() == 3)
    #expect(store.translation(field: .nodeName, sourceText: "one", language: "de") == nil)
  }

  /// Off means off: no translator call, no store write.
  @Test func offTranslatesNothing() async {
    let store = TranslationStore(url: tempURL("backfill-off"))
    let translator = RecordingTranslator()
    let written = await TranslationBackfill.run(units: units, store: store, translator: translator,
                                                language: TranslationTarget.off,
                                                progress: { _, _ in })
    #expect(written == 0)
    #expect(await translator.callCount() == 0)
  }

  /// Collects progress callbacks. A plain `final class` guarded by the test's own single-threaded use;
  /// `@unchecked Sendable` because the callback is `@Sendable` but the run is serial by construction.
  private final class Reported: @unchecked Sendable {
    private(set) var pairs: [(Int, Int)] = []
    func record(done: Int, total: Int) { pairs.append((done, total)) }
  }
}
```

> Note on `#expect(reported.pairs == [(1, 3), (2, 3), (3, 3)])`: tuple arrays are `Equatable` in Swift
> for arities up to 6, so this compiles as written. If the toolchain rejects it, compare
> `reported.pairs.map(\.0) == [1, 2, 3]` and `reported.pairs.allSatisfy { $0.1 == 3 }` instead —
> assert both, not just the first.

- [ ] **Step 2: Run the tests to verify they fail**

```bash
make test FILTER=TranslationBackfillTests
```

Expected: compile failure — `cannot find 'TranslationBackfill' in scope`.

- [ ] **Step 3: Write the implementation**

Create `Sources/PensieveKit/Translation/TranslationBackfill.swift`:

```swift
import Foundation

/// Translates the corpus that on-demand translation left behind.
///
/// On-demand translation is the steady state for text you are looking at; it is not a way to get a
/// corpus translated. Measured on 2026-08-14: 2 stored translations against 1,294 translatable texts,
/// with `nodeName` and `nodeDescription` never written by any production caller at all. This is the
/// explicit pass that closes that gap, and the ONLY bulk writer — the launchd sync agent and the CLI
/// read translations and never write them.
///
/// Four of its five properties are scars from the eval run that already did this work once
/// (`measurements/2026-08-12-translation-ranking/README.md`):
///
/// - **Serial.** The generator that completed was serial; on-device throughput under concurrency is
///   unmeasured, and a bulk pass over someone's whole history is not where to find out.
/// - **Idempotent.** Check-then-skip against the content-keyed store, so a re-press pays only for
///   what is missing. The generator lacked this, died at 522/870, and had to be given it.
/// - **Resumable by construction.** Each `put` commits its own row, so a cancel, a crash or a quit
///   keeps every translation already made. There is no checkpoint to corrupt because there is none.
/// - **Cancellable.** Checked per unit; partial work stands.
/// - **Never throws, and never retries a nil.** An absent pack nils every call; retrying inside one
///   run cannot change that, and a later run genuinely might.
public enum TranslationBackfill {
  /// - Returns: the number of translations newly written, so the caller knows whether a reindex is
  ///   even warranted.
  public static func run(units: [TranslatableUnit], store: TranslationStore,
                         translator: any Translator, language: String,
                         progress: @Sendable (Int, Int) -> Void) async -> Int {
    guard !language.isEmpty else { return 0 }
    let total = units.count
    var written = 0
    for (index, unit) in units.enumerated() {
      // Checked BEFORE the work, not after: cancelling must stop the next model call, and the unit
      // already in flight is allowed to finish and be stored rather than thrown away.
      if Task.isCancelled { return written }
      if store.translation(field: unit.field, sourceText: unit.sourceText, language: language) == nil,
         let text = await translator.translate(unit.sourceText,
                                               from: TranslationTarget.sourceLanguage, to: language) {
        store.put(field: unit.field, sourceText: unit.sourceText, language: language, text: text)
        written += 1
      }
      progress(index + 1, total)
    }
    return written
  }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

```bash
make test FILTER=TranslationBackfillTests
```

Expected: all PASS.

- [ ] **Step 5: Verify the two mutation claims**

Both tests exist because this project has shipped tests that passed with the behaviour deleted. Prove
they do not:

```bash
# 1. Delete the `if Task.isCancelled { return written }` line, then:
make test FILTER=TranslationBackfillTests   # expect cancellationKeepsWhatLandedAndStops to FAIL
# 2. Restore it. Now delete the `store.translation(...) == nil` guard from the condition, then:
make test FILTER=TranslationBackfillTests   # expect aSecondRunTranslatesNothing to FAIL
# 3. Restore it and re-run: all PASS.
```

Expected: each mutation fails the named test; the restored file passes everything.

- [ ] **Step 6: Commit**

```bash
git add Sources/PensieveKit/Translation/TranslationBackfill.swift \
        Tests/PensieveKitTests/TranslationBackfillTests.swift
git commit -m "feat(kit): one explicit pass over everything still in English"
```

---

### Task 4: `TranslationTarget` — any language the framework offers

Retire the `supported = ["de"]` allow-list and add the display-name helper the picker needs.

**Files:**
- Modify: `Sources/PensieveKit/Translation/TranslationTarget.swift` (whole file)
- Modify: `Tests/PensieveKitTests/TranslationTargetTests.swift:28-36` (the unsupported-value test) and
  add two new tests

**Interfaces:**
- Produces:
  ```swift
  public enum TranslationTarget {
    public static let off: String            // "" — unchanged
    public static let sourceLanguage: String // "en" — unchanged
    public static func resolved(defaults: UserDefaults = PensieveDefaults.shared()) -> String
    public static func displayName(for language: String) -> String
    // REMOVED: public static let supported: [String]
  }
  ```

- [ ] **Step 1: Write the failing tests**

In `Tests/PensieveKitTests/TranslationTargetTests.swift`, replace the `anUnsupportedLanguageResolvesToOff`
test with this one (keeping its name and its intent — garbage must still degrade to off) and append the
three that follow:

```swift
  /// Garbage still degrades to off. The guard is now SHAPE rather than membership: `klingon` is not an
  /// ISO 639 subtag, so it never reaches the framework. Probed: `de`/`zh-Hans`/`pt-BR`/`de-DE` pass,
  /// `klingon` does not.
  @Test func anUnsupportedLanguageResolvesToOff() {
    let store = defaults("unsupported")
    store.set("klingon", forKey: PensieveDefaults.translationTargetKey)
    #expect(TranslationTarget.resolved(defaults: store) == TranslationTarget.off)
  }

  /// The allow-list is gone, so a region- or script-qualified target the framework offers resolves to
  /// itself. `zh-HK` must NOT collapse to `zh`: the framework reports them as different languages
  /// (`zh-Hant-HK` vs `zh-Hans-CN`), and collapsing them would translate into the wrong script.
  @Test func regionQualifiedTargetsResolveToThemselves() {
    let hongKong = defaults("zh-hk")
    hongKong.set("zh-HK", forKey: PensieveDefaults.translationTargetKey)
    #expect(TranslationTarget.resolved(defaults: hongKong) == "zh-HK")

    let portugal = defaults("pt-pt")
    portugal.set("pt-PT", forKey: PensieveDefaults.translationTargetKey)
    #expect(TranslationTarget.resolved(defaults: portugal) == "pt-PT")
  }

  /// Display names must use `forIdentifier:`, not `forLanguageCode:`. Probed: the latter renders all
  /// three Chinese options as an identical "中文", making the picker unusable.
  @Test func displayNamesKeepTheirQualifier() {
    #expect(TranslationTarget.displayName(for: "de") == "Deutsch")
    #expect(TranslationTarget.displayName(for: "zh-HK") != TranslationTarget.displayName(for: "zh"))
  }

  /// An identifier Locale cannot name falls back to the identifier itself, so a row is never blank.
  @Test func anUnnameableIdentifierFallsBackToItself() {
    #expect(TranslationTarget.displayName(for: "zz-Zzzz") == "zz-Zzzz")
  }
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
make test FILTER=TranslationTargetTests
```

Expected: FAIL — `regionQualifiedTargetsResolveToThemselves` returns `""` (blocked by the allow-list)
and `displayName` does not exist.

- [ ] **Step 3: Rewrite `TranslationTarget`**

Replace `Sources/PensieveKit/Translation/TranslationTarget.swift` in full:

```swift
import Foundation

/// Which language generated text is translated into, read from UserDefaults so the app, the CLI and
/// the launchd agent all agree — they must, because the agent builds the search index and therefore
/// decides which translated documents it contains.
///
/// Deliberately NOT the app's runtime locale. Tying the two would make the feature inert unless the
/// whole UI were switched, and would let a locale the user never chose (system French, app falling
/// back to English) silently select a translation target. A setting also decouples reading language
/// from UI language, which is the likelier want: German summaries with English chrome.
public enum TranslationTarget {
  /// Translation disabled. Off means off: no store file, no index rows, no model asset loaded.
  public static let off = ""
  /// Generated text is written in English; that is the source of every display translation and the
  /// target of the query backstop.
  public static let sourceLanguage = "en"

  /// The persisted target, or `off` for unset, English, or a malformed identifier.
  ///
  /// There is deliberately NO allow-list of languages. The original `supported = ["de"]` existed on
  /// the argument that each language "doubles a slice of the search index, which is a measured cost" —
  /// and that argument was retired by its own measurement: the pre-registered ranking gate shipped as
  /// built with English P@1 statistically indistinguishable from baseline (McNemar p = 1.000,
  /// `measurements/2026-08-12-translation-ranking/`). Only one target is active at a time, so the
  /// doubling is bounded at exactly the case that gate cleared.
  ///
  /// The check is SHAPE, not membership, and the framework is where unsupported languages degrade:
  /// `SystemTranslator.translate` verifies `status(from:to:) == .installed` before constructing a
  /// session, and `AppModel.displayed(field:sourceText:)` is a pure store lookup that never reaches
  /// the framework at all. So an exotic-but-valid code costs one availability check and shows English;
  /// it cannot fail per render. (The previous comment here claimed otherwise; it was written when
  /// nothing downstream guarded.)
  public static func resolved(defaults: UserDefaults = PensieveDefaults.shared()) -> String {
    let stored = defaults.string(forKey: PensieveDefaults.translationTargetKey) ?? off
    guard !stored.isEmpty, stored != sourceLanguage,
          let code = Locale.Language(identifier: stored).languageCode,
          Locale.LanguageCode.isoLanguageCodes.contains(code)
    else { return off }
    return stored
  }

  /// The language's name in its own language — "Deutsch", "Deutsch (Schweiz)", "中文（香港）".
  ///
  /// `forIdentifier:`, NOT `forLanguageCode:`: the latter drops the region/script qualifier, which
  /// renders `zh`, `zh-HK` and `zh-TW` as three identical rows labelled "中文". Falls back to the
  /// identifier so a row is never blank.
  public static func displayName(for language: String) -> String {
    Locale(identifier: language).localizedString(forIdentifier: language) ?? language
  }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

```bash
make test FILTER=TranslationTargetTests
make test FILTER=TranslatedSearchTests
make test FILTER=TranslatedCorpusTests
```

Expected: all PASS. If anything still references `TranslationTarget.supported`, the compiler names it;
the only known reader was the Settings picker, which Task 5 replaces.

- [ ] **Step 5: Full suite, then commit**

```bash
make test
make lint
git add Sources/PensieveKit/Translation/TranslationTarget.swift \
        Tests/PensieveKitTests/TranslationTargetTests.swift
git commit -m "feat(kit): any language the framework offers, not the one we listed"
```

---

### Task 5: The Settings language picker, pack status, and download

Replaces `IntelligenceSettingsTab`'s two-item picker and its always-attached `.translationTask`.

**Files:**
- Create: `Sources/PensieveApp/Settings/TranslationSettingsSection.swift`
- Modify: `Sources/PensieveApp/Settings/IntelligenceSettingsTab.swift:95-130` — delete the
  `translationSection` computed property and its `@AppStorage(PensieveDefaults.translationTargetKey)`,
  and render the new view in the existing `Section`; drop the now-unused
  `@preconcurrency import Translation` if nothing else in the file needs it

**Interfaces:**
- Consumes: `TranslationTarget.off` / `.sourceLanguage` / `.displayName(for:)`,
  `PensieveDefaults.translationTargetKey`.
- Produces:
  ```swift
  struct TranslationLanguageOption: Identifiable, Hashable {
    let code: String        // Locale.Language.minimalIdentifier — the persisted value
    let name: String        // endonym via TranslationTarget.displayName(for:)
    let isInstalled: Bool
    var id: String { code }
  }
  enum TranslationLanguageCatalog {
    static func load() async -> [TranslationLanguageOption]
  }
  struct TranslationSettingsSection: View { var model: AppModel }
  ```

- [ ] **Step 1: Write the section**

Create `Sources/PensieveApp/Settings/TranslationSettingsSection.swift`:

```swift
import SwiftUI
// Load-bearing and FILE-SCOPED: `@preconcurrency` suppresses this file's Sendable warnings from the
// `Translation` framework's un-audited types (`LanguageAvailability`, the `.translationTask` below).
@preconcurrency import Translation
import PensieveKit

/// One offered target language.
struct TranslationLanguageOption: Identifiable, Hashable {
  /// `Locale.Language.minimalIdentifier`, and the value persisted to UserDefaults.
  ///
  /// Probed against this Mac's 29 offered targets: every minimal identifier round-trips through
  /// `Locale.Language(identifier:)` unchanged, and the framework reports script/region variants as
  /// distinct entries (`zh` = zh-Hans-CN, `zh-HK` = zh-Hant-HK, `pt` = pt-Latn-BR, `pt-PT`). So the
  /// minimal form loses nothing, whereas `maximalIdentifier` would store `zh-Hans-CN` for a user who
  /// chose `zh`, and a bare language code would collapse `zh-HK` onto `zh` — the wrong script.
  let code: String
  let name: String
  let isInstalled: Bool
  var id: String { code }
}

/// What this Mac can translate English into.
///
/// `LanguageAvailability` is macOS 15+ (only `TranslationSession(installedSource:)` is 26+), and the
/// app's deployment target is 15.0, so this needs no availability annotation. Measured on this
/// machine: 38 supported languages, of which 9 are English variants reporting `.unsupported` (en→en)
/// and drop out by that status alone — no hand-maintained exclusion list.
enum TranslationLanguageCatalog {
  static func load() async -> [TranslationLanguageOption] {
    let availability = LanguageAvailability()
    let english = Locale.Language(identifier: TranslationTarget.sourceLanguage)
    var options: [TranslationLanguageOption] = []
    // Serial rather than a TaskGroup: the probe returned all 38 statuses instantly, so concurrency
    // would buy nothing measurable and cost deterministic ordering. (The spec says "concurrently";
    // this is a deliberate simplification, recorded rather than silent.)
    for language in await availability.supportedLanguages {
      let status = await availability.status(from: english, to: language)
      guard status != .unsupported else { continue }
      let code = language.minimalIdentifier
      options.append(TranslationLanguageOption(code: code,
                                               name: TranslationTarget.displayName(for: code),
                                               isInstalled: status == .installed))
    }
    return options.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
  }

  /// Whether the pack for `language` is installed right now. Re-read after a download so the status
  /// line reflects reality rather than the fact that a sheet was shown.
  static func isInstalled(_ language: String) async -> Bool {
    guard !language.isEmpty else { return false }
    let status = await LanguageAvailability().status(
      from: Locale.Language(identifier: TranslationTarget.sourceLanguage),
      to: Locale.Language(identifier: language))
    return status == .installed
  }
}

/// Settings ▸ Intelligence ▸ Translation. The target picker, language-pack status with a download
/// affordance, a link to the OS pane that owns pack lifecycle, and the coverage/backfill row.
///
/// Extracted from `IntelligenceSettingsTab` rather than grown inside it: that file is 261 lines and CI
/// runs `swiftlint --strict` with a 400-line cap.
struct TranslationSettingsSection: View {
  var model: AppModel
  @AppStorage(PensieveDefaults.translationTargetKey) private var translationTarget = TranslationTarget.off

  @State private var options: [TranslationLanguageOption] = []
  @State private var isInstalled = false
  @State private var isDownloading = false

  private var isOff: Bool { translationTarget == TranslationTarget.off }

  var body: some View {
    Picker("Translate generated text to", selection: $translationTarget) {
      Text("Off").tag(TranslationTarget.off)
      ForEach(options) { option in
        // Content, not chrome: a language's own name is never a catalog key.
        Text(verbatim: option.isInstalled ? option.name : "\(option.name) ⤓").tag(option.code)
      }
      // A persisted target the framework no longer reports still shows as selected rather than
      // blanking the picker.
      if !isOff, !options.contains(where: { $0.code == translationTarget }) {
        Text(verbatim: TranslationTarget.displayName(for: translationTarget)).tag(translationTarget)
      }
    }
    .task { options = await TranslationLanguageCatalog.load() }

    if !isOff {
      if #available(macOS 26, *) {
        packStatus
      } else {
        Text("Translation requires macOS 26 or later.")
          .font(.caption).foregroundStyle(.secondary)
      }
      Button("Manage installed languages in System Settings…") {
        // Verified present on macOS 26: this extension owns the "Translation Languages" UI. Deleting
        // a pack is OS-only, so linking out is the honest ceiling of "manage".
        if let url = URL(string: "x-apple.systempreferences:com.apple.Localization-Settings.extension") {
          NSWorkspace.shared.open(url)
        }
      }
      .buttonStyle(.link)
      .font(.caption)
    }
  }

  @available(macOS 26, *)
  @ViewBuilder private var packStatus: some View {
    HStack {
      if isDownloading {
        // The ONLY view-attached translation in the app, and now it is attached only while a download
        // is actually running. Previously it was mounted whenever a target was set, so it re-fired on
        // every Settings open and reported nothing.
        //
        // A headless `TranslationSession(installedSource:)` cannot request a download
        // (`canRequestDownloads`), which is why first-run acquisition has to happen in a view.
        ProgressView().controlSize(.small)
        Text("Preparing the language…")
          .font(.caption).foregroundStyle(.secondary)
          .translationTask(source: Locale.Language(identifier: TranslationTarget.sourceLanguage),
                           target: Locale.Language(identifier: translationTarget)) { session in
            try? await session.prepareTranslation()
            isInstalled = await TranslationLanguageCatalog.isInstalled(translationTarget)
            isDownloading = false
          }
      } else if isInstalled {
        Label("Ready to translate on this Mac.", systemImage: "checkmark.circle")
          .font(.caption).foregroundStyle(.secondary)
      } else {
        Label("This language isn’t downloaded yet.", systemImage: "arrow.down.circle")
          .font(.caption).foregroundStyle(.secondary)
        Spacer()
        Button("Download…") { isDownloading = true }
      }
    }
    .task(id: translationTarget) {
      isDownloading = false
      isInstalled = await TranslationLanguageCatalog.isInstalled(translationTarget)
    }
  }
}
```

- [ ] **Step 2: Wire it into the Intelligence tab**

In `Sources/PensieveApp/Settings/IntelligenceSettingsTab.swift`, delete the `translationSection`
computed property (`:110-130`) and the `translationTarget` `@AppStorage` line (`:20`) — the new view
owns both — and replace the section body at `:95-100`:

```swift
      Section { TranslationSettingsSection(model: model) } header: {
        Text("Translation")
      } footer: {
        Text("Generated summaries are translated on this device. Captured text, cited quotes and transcripts are never translated.")
          .font(.caption).foregroundStyle(.secondary)
      }
```

If `@preconcurrency import Translation` at `:6` is now unused (nothing else in the file touches the
framework), delete it — leaving it would keep a Sendable-warning suppression alive in a file that no
longer needs one.

- [ ] **Step 3: Regenerate the project and build**

`Pensieve.xcodeproj` is generated and gitignored, and this task adds a file — without regenerating,
the build fails with `cannot find 'TranslationSettingsSection' in scope`.

```bash
make build
make lint
```

Expected: build succeeds, 0 lint violations.

- [ ] **Step 4: Commit**

```bash
git add Sources/PensieveApp/Settings/TranslationSettingsSection.swift \
        Sources/PensieveApp/Settings/IntelligenceSettingsTab.swift
git commit -m "feat(app): pick any offered language, and see whether it is ready"
```

---

### Task 6: Coverage readout and the backfill button

**Files:**
- Modify: `Sources/PensieveApp/AppModel.swift:117` area — add three properties
- Modify: `Sources/PensieveApp/AppModel+Translation.swift` — add three methods
- Modify: `Sources/PensieveApp/Settings/TranslationSettingsSection.swift` — add the coverage row

**Interfaces:**
- Consumes: `TranslatableCorpus.gather(_:)`, `TranslationCoverage.measure(units:store:language:)`,
  `TranslationBackfill.run(units:store:translator:language:progress:)`, and the existing
  `AppModel.translationStore` / `translator` / `translationRevision` / `translationDebouncer` /
  `database`.
- Produces:
  ```swift
  // AppModel
  var translationCoverage: TranslationCoverage?
  var translationBackfillProgress: (done: Int, total: Int)?
  @ObservationIgnored var translationBackfillTask: Task<Int, Never>?
  // AppModel+Translation
  func measureTranslationCoverage() async
  func startTranslationBackfill()
  func cancelTranslationBackfill()
  ```

- [ ] **Step 1: Add the observable state**

In `Sources/PensieveApp/AppModel.swift`, directly below `translationRevision` (`:117`):

```swift
  /// Coverage as last measured, or nil when the target is off / not yet measured. Measured on demand
  /// from Settings, not on launch: it is 1,294 store reads today and nothing outside Settings shows it.
  var translationCoverage: TranslationCoverage?
  /// Non-nil while a bulk translation is running: (done, total). Lives on the model, not the view, so
  /// closing Settings does not kill a run and reopening it shows the run still going.
  var translationBackfillProgress: (done: Int, total: Int)?
  /// The running backfill. `Task.detached` deliberately — see `startTranslationBackfill`.
  @ObservationIgnored var translationBackfillTask: Task<Int, Never>?
```

- [ ] **Step 2: Add the three methods**

Append to `Sources/PensieveApp/AppModel+Translation.swift`:

```swift
  /// Measure coverage off the main actor. Pre-Task locals are read here (on the main actor) rather
  /// than inside the detached closure — the same shape `AppModel+Search.runSearch` uses.
  func measureTranslationCoverage() async {
    let language = TranslationTarget.resolved()
    guard !language.isEmpty, let database else {
      translationCoverage = nil
      return
    }
    let store = translationStore
    translationCoverage = await Task.detached {
      guard let units = try? TranslatableCorpus.gather(database) else { return nil }
      return TranslationCoverage.measure(units: units, store: store, language: language)
    }.value
  }

  /// Translate everything the corpus can use and this store does not have yet.
  ///
  /// The work runs in a `Task.detached` that is stored and cancelled directly, NOT wrapped in an outer
  /// task: a detached task does not inherit cancellation, so cancelling a parent would leave the run
  /// going while the UI claimed it had stopped.
  func startTranslationBackfill() {
    guard translationBackfillTask == nil, let translator else { return }
    let language = TranslationTarget.resolved()
    guard !language.isEmpty, let missing = translationCoverage?.missing, !missing.isEmpty else { return }
    let store = translationStore
    translationBackfillProgress = (done: 0, total: missing.count)
    // Built HERE, on the main actor, so `self` is captured before the detached task exists. `AppModel`
    // is `@MainActor`-isolated and therefore implicitly `Sendable`, so the weak capture crosses the
    // isolation boundary legally. There is no `AppModel.shared` in this codebase — do not add one.
    let report: @Sendable (Int, Int) -> Void = { [weak self] done, total in
      Task { @MainActor in
        // Only while this run still owns the progress: a completion that already cleared it must not
        // be re-populated by a late callback.
        guard let self, self.translationBackfillTask != nil else { return }
        self.translationBackfillProgress = (done: done, total: total)
      }
    }
    let work = Task.detached {
      await TranslationBackfill.run(units: missing, store: store, translator: translator,
                                    language: language, progress: report)
    }
    translationBackfillTask = work
    Task { @MainActor in
      let written = await work.value
      translationBackfillTask = nil
      translationBackfillProgress = nil
      await measureTranslationCoverage()
      guard written > 0 else { return }
      translationRevision += 1              // repaint panes with the new text
      await translationDebouncer.schedule()  // ONE whole-corpus rebuild, not one per item
    }
  }

  /// Stops after the unit in flight. Everything already written stays; re-pressing resumes.
  func cancelTranslationBackfill() {
    translationBackfillTask?.cancel()
  }
```

> **Why the progress closure is built before the detached task:** capturing `self` inside
> `Task.detached { … }` would capture it from a non-isolated context. Declaring `report` on the main
> actor first keeps the capture legal and keeps the main-actor hop in one place. ~1,294 hops over a
> multi-minute run is not a load worth throttling; SwiftUI coalesces the renders.

- [ ] **Step 3: Add the coverage row to the section**

In `TranslationSettingsSection.swift`, add to `body` inside the existing `if !isOff {` block, directly
after `packStatus` / the macOS-26 fallback and before the System Settings link:

```swift
      if #available(macOS 26, *) { coverageRow }
```

and add this property to the view, plus `.task(id: translationTarget) { await model.measureTranslationCoverage() }`
on the outermost `Picker` (beside the existing catalog `.task`):

```swift
  /// Coverage plus the one button that starts or stops the bulk pass. Disabled when the pack is not
  /// installed: 1,294 calls that each nil out is not a run worth starting, and the Download button
  /// directly above is the actual next step.
  @available(macOS 26, *)
  @ViewBuilder private var coverageRow: some View {
    if let progress = model.translationBackfillProgress {
      VStack(alignment: .leading, spacing: 4) {
        ProgressView(value: Double(progress.done), total: Double(max(progress.total, 1)))
        HStack {
          Text("\(progress.done) of \(progress.total) translated")
            .font(.caption).foregroundStyle(.secondary)
          Spacer()
          Button("Stop") { model.cancelTranslationBackfill() }
        }
      }
    } else if let coverage = model.translationCoverage {
      HStack {
        Text("\(coverage.translated) of \(coverage.total) translated")
          .font(.caption).foregroundStyle(.secondary)
        Spacer()
        if coverage.missing.isEmpty {
          Text("Everything is translated.").font(.caption).foregroundStyle(.secondary)
        } else {
          Button("Translate remaining") { model.startTranslationBackfill() }
            .disabled(!isInstalled)
        }
      }
    }
  }
```

- [ ] **Step 4: Build and lint**

```bash
make build
make lint
```

Expected: build succeeds, 0 violations. If `AppModel.swift` crosses 400 lines, move the three new
translation properties into a small `AppModel+Translation.swift`-adjacent extension rather than
relaxing the rule — the same move the slice-A merge made for `commitNewNode`/`updateNode`.

- [ ] **Step 5: Commit**

```bash
git add Sources/PensieveApp/AppModel.swift \
        Sources/PensieveApp/AppModel+Translation.swift \
        Sources/PensieveApp/Settings/TranslationSettingsSection.swift
git commit -m "feat(app): see how much is translated, and translate the rest"
```

---

### Task 7: Localize the new chrome

**Files:**
- Modify: `Sources/PensieveApp/Localizable.xcstrings`

Hand-authored: `xcodebuild … build` does not populate the catalog. Keys must match the Swift literals
byte-for-byte, including the typographic apostrophe in "isn’t".

- [ ] **Step 1: Remove the retired key**

Delete the `"Prepare translation"` entry (`:2125`). Its view is gone.

- [ ] **Step 2: Add the new keys**

Add these entries with `"state" : "translated"` for `de`, matching the file's existing shape. German is
impersonal/infinitive:

| key (English literal) | `de` value |
|---|---|
| `Ready to translate on this Mac.` | `Bereit zum Übersetzen auf diesem Mac.` |
| `This language isn’t downloaded yet.` | `Diese Sprache ist noch nicht heruntergeladen.` |
| `Preparing the language…` | `Sprache wird vorbereitet …` |
| `Download…` | `Herunterladen …` |
| `Manage installed languages in System Settings…` | `Installierte Sprachen in den Systemeinstellungen verwalten …` |
| `Translating %lld of %lld…` | `%1$lld von %2$lld werden übersetzt …` |
| `%lld of %lld translated` | `%1$lld von %2$lld übersetzt` |
| `Translate remaining` | `Restliche übersetzen` |
| `Stop` | `Stoppen` |

*Corrected 2026-08-14, before Task 7 ran: Task 6's fix round gave the progress row its own literal
(`Translating %lld of %lld…`) and deleted `Everything is translated.` from the source, so that key was
never authored. The `Prepare translation` entry to delete was at `:3086`, not `:2125`. Nine keys shipped.*

Two things to get right: `%lld of %lld translated` needs **positional** `%1$lld` / `%2$lld` in German
because the numbers precede the verb; and `Stop` may already exist in the catalog — check before adding
a duplicate key.

- [ ] **Step 3: Verify the catalog is valid and the keys land in the bundle**

```bash
make build
plutil -p .build-xcode/Build/Products/Debug/Pensieve.app/Contents/Resources/de.lproj/Localizable.strings \
  | grep -i "übersetz\|heruntergeladen\|Systemeinstellungen"
```

Expected: the German values appear. A missing key means the Swift literal and the catalog key differ —
the failure mode is a silent English fallback, so this grep is the test.

- [ ] **Step 4: Commit**

```bash
git add Sources/PensieveApp/Localizable.xcstrings
git commit -m "i18n: the translation settings speak German"
```

---

### Task 8: Full verification, docs, and the human-verify ledger

**Files:**
- Modify: `CLAUDE.md` (a Status bullet)
- Modify: `docs/superpowers/backlog.md` (close the translation slice's deferred
  "per-node bulk translation" item; record the follow-ups this plan defers)
- Modify: `docs/superpowers/plans/2026-08-14-translation-settings-coverage.md` (this file — the
  human-verify checklist below)

- [ ] **Step 1: Run everything CI runs**

```bash
make all
```

Expected: lint clean, full suite PASS (Kit gains ~18 tests: 5 + 6 + 6 in Tasks 1–3, plus 2 in Task 4),
app builds, embedded-CLI smoke passes. Record the final test count for the CLAUDE.md bullet.

*Actual (2026-08-14): **703 tests in 12 suites**, up from a 685 baseline — the predicted +18, distributed
5 + 5 + 5 in Tasks 1–3 and +3 in Task 4. Lint 0 violations; app builds; embedded-CLI smoke passes.*

- [ ] **Step 2: Install and drive it once, for real**

```bash
make run   # all + install + launch the installed bundle — never Spotlight
```

Then work the checklist. This is the only verification that touches the actual feature: the app target
has no unit tests, and the documented smoke-launch recipe renders no view body, so nothing before this
step has executed a single line of `TranslationSettingsSection` or `AppModel+Translation`.

> **Not run by the implementation session (2026-08-14), deliberately.** `make run` replaces the live
> `/Applications/Pensieve.app` and re-mints the bundled sync helper's cdhash — an outward side effect on
> a running system. Step 1 (`make all`) is green: lint 0 violations, **703 tests in 12 suites** (up from
> 685), app builds, embedded-CLI smoke passes. The install and Step 3 are the human's.

- [ ] **Step 3: Human-verify checklist**

*Corrected 2026-08-14 to match what actually shipped: the running row is `Translating N of M…` (its own
key — Kit's counter advances on every unit ATTEMPTED, not every one written), there is no "Everything is
translated." sentence (deleted as redundant with the count), and coverage now carries the language it was
measured for, so it renders nothing rather than a stale number during a re-measure.*

- [ ] Settings ▸ Intelligence ▸ Translation lists **29 languages** (not 1), each in its own language,
      with `Deutsch` and `Français` unmarked and `polski` / `русский` carrying the `⤓` marker.
- [ ] `zh`, `zh-HK`, `zh-TW` appear as **three distinguishable rows**, not three identical `中文`.
- [ ] Opening Settings with a target already set does **not** trigger a download sheet (the old
      always-attached `.translationTask` did).
- [ ] Picking an undownloaded language shows "isn’t downloaded yet" + Download; pressing Download shows
      the system sheet, and on completion the line flips to "Ready to translate".
- [ ] **Switch the picker to another language while a download is running.** No download prompt may
      appear for the newly selected language, and the row must show that language's own status (ready /
      needs download). This is the review-found defect: the old `Bool` flag was reset only inside a
      `.task(id:)` body, which never runs synchronously with the change to its id.
- [ ] With no pack installed, **Translate remaining is disabled**.
- [ ] Coverage reads `0 of 1294` on first open with German selected (the live store held 2 narration
      rows and nothing else on 2026-08-14).
- [ ] Pressing **Translate remaining** advances the bar, and the running row reads
      **"Translating N of M…"** — not "N of M translated".
- [ ] **Stop** halts it; the count keeps what landed. Pressing again resumes from there.
- [ ] Closing Settings mid-run and reopening it shows the run **still going** (and the bar, not a
      button).
- [ ] **Switch the target language mid-run: the run stops.** The bar may linger for up to one unit
      while the in-flight translation returns; it must not keep climbing.
- [ ] Quitting mid-run and relaunching: coverage shows the partial total, and pressing the button again
      resumes rather than restarting (watch the count start from where it stopped, not from 0).
- [ ] At 100%: the row shows **only** the count, with no button and **no** second sentence beside it.
- [ ] After a completed run: ⌘F (and MCP `search`) finds a node by a **German** word from its name or
      its description — the tree itself keeps rendering in English (`displayed(field:)` is only ever
      called with `.looseEndText`, so `nodeName`/`nodeDescription` translations are search-only). This
      is still the payoff: those two fields previously had no writer at all.
- [ ] Cited quotes and transcript windows are **still English** everywhere. This is the trust gate; if
      any quote is German, stop and file it.
- [ ] "Manage installed languages in System Settings…" opens Language & Region, showing Translation
      Languages.
- [ ] Switching to another language shows **no coverage row at all** for the moment the re-measure
      takes (never the previous language's numbers), then `0 of 1294`; a new backfill then works. If the
      row stays blank, closing and reopening Settings must recover it — that residual is a known,
      recorded minor.
- [ ] Launch with `-AppleLanguages '(de)'`: every new string is German, and language names stay in
      their own language. The nine new values to check: `Bereit zum Übersetzen auf diesem Mac.` ·
      `Diese Sprache ist noch nicht heruntergeladen.` · `Sprache wird vorbereitet …` ·
      `Herunterladen …` · `Installierte Sprachen in den Systemeinstellungen verwalten …` ·
      `%1$lld von %2$lld werden übersetzt …` · `%1$lld von %2$lld übersetzt` · `Restliche übersetzen` ·
      `Stoppen`. (`Prepare translation` / `Übersetzung vorbereiten` must be **gone**.)

- [ ] **Step 4: Update the docs**

Add a `CLAUDE.md` Status bullet in the established voice, covering: the picker over the 29 offered
targets (measured, not guessed) and why `TranslationTarget.supported` is gone (its stated cost was
refuted by its own ranking gate, p = 1.000); pack status with a download that is no longer a permanent
resident of the view hierarchy; coverage counted by **distinct text** with the measured 0-of-1,294
starting point and the fact that `nodeName`/`nodeDescription` had **no production writer** before this;
the explicit serial idempotent resumable backfill and the four eval-run scars it carries; the
extraction of `corpusNodes`/`corpusLooseEnds` so the backfill's denominator and the corpus's lookups
cannot drift; `Task.detached` not inheriting cancellation as the trap that shaped
`startTranslationBackfill`; and the new test count. State plainly that the trust gate is untouched and
that no `EvalTask` is registered because nothing here is LLM-backed.

In `docs/superpowers/backlog.md`: mark the translation slice's deferred "per-node bulk translation" as
**subsumed** by the global backfill, and record what this plan deliberately left open — an ETA (needs
one observed run's throughput), concurrent backfill (needs a throughput measurement first), RTL layout
for `ar-AE` content, ambient translation in the sync agent (explicitly rejected: the agent stays a
reader), and pruning a previous language's rows after a switch (disposable file, disk only).

- [ ] **Step 5: Commit**

```bash
git add CLAUDE.md docs/superpowers/backlog.md \
        docs/superpowers/plans/2026-08-14-translation-settings-coverage.md
git commit -m "docs: translation gets a control surface, and coverage stops being invisible"
```

---

## Notes for the executor

- **Kit must not import `Translation`.** `Package.swift` is `.macOS(.v14)`; `LanguageAvailability` is
  15+. Everything framework-touching added by this plan lives in the app target. Kit's only
  `Translation` use stays the pre-existing `@available(macOS 26, *) SystemTranslator`.
- **`Task.detached` does not inherit cancellation.** This is why Task 6 stores the detached task and
  cancels it directly. Wrapping it in an outer `Task` and cancelling that would leave the run going
  while the UI said it stopped — and the resulting bug would look like "Stop doesn't work sometimes".
- **`make build` needs `xcodegen generate` first** (it runs it), and Task 5 adds a file. Skipping it
  fails with `cannot find 'TranslationSettingsSection' in scope`.
- **Do not touch `TranslationField`, `TranslationParser`-adjacent code, `TranslationVocabulary`, or
  anything reading a loose end's `quote`.** The trust gate is the north star; if a task seems to
  require it, stop and ask.
- **Other people's changes are in this working tree.** `git add` only the files each task names; never
  `git add -A`.
