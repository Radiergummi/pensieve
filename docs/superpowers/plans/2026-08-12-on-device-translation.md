# On-Device Translation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Read Pensieve's model-generated text (narration automatically; loose-end summaries and node names on demand) in a chosen language, with each translation stored and indexed so the German you read is also the German you can find.

**Architecture:** A disposable `translation-cache.sqlite` keyed on `(field, sourceTextHash, language)` holds translations. `EmbeddableCorpus.gather` emits them as *additional* FTS5 documents sharing the original's `item_id`, distinguished by a new `language UNINDEXED` column. `SearchHitResolver` dedups on `item_id` and offers the translated body as a snippet candidate so a German-only match still highlights. A separate async wrapper adds a translate-and-retry backstop for queries that return nothing, leaving the synchronous search path byte-identical.

**Tech Stack:** Swift 6, SwiftUI, GRDB via SQLiteData 1.6.6, FTS5, macOS `Translation` framework (`TranslationSession`), Swift Testing.

## Global Constraints

- **Spec:** `docs/superpowers/specs/2026-08-12-on-device-translation-design.md`. All line references are against `main` at `907b4fc`.
- **No Python, ever.** Swift only.
- **Explicit names, no abbreviations** — `database`, `looseEnd`, `translation`, never `db`/`le`/`tr`. Genuine wire keys (`item_id`, `node_id`) stay snake_case in SQL only.
- **SQLiteData predicates use `.eq(x)`, never `== x`.**
- **SwiftLint `--strict` runs in CI**; 400-line file cap. Do not relax `.swiftlint.yml`.
- **Availability:** headless `TranslationSession(installedSource:target:)` is macOS 26.0+; `TranslationSession.Strategy` is 26.4+. `Package.swift` stays `.macOS(.v14)` and `project.yml` stays `15.0` — use `@available(macOS 26, *)` and return nil below it.
- **Trust gate:** no `TranslationField` case may name a quote or a transcript message. `TranscriptVocabulary.injectionMarkers` and `TranscriptParser.isInjectedOrCommand` must not be read, written, or referenced by any file in this plan.
- **Best-effort everywhere:** every failure returns the English original. Nothing throws into a render, capture, or ingest path.
- **Off means off:** with the target language unset, no store file is created, no index rows are produced, and no model asset is loaded.
- **Tests must never require an installed language pack or macOS 26.** Inject a stub `Translator`.
- Kit tests: `./scripts/test.sh --filter <SuiteName>`. App target has no unit tests — verify with `xcodebuild` plus a non-blocking smoke-launch of the inner binary.

## Two corrections this plan carries beyond the spec

Both found by reading the code while planning. They are folded into Tasks 4 and 7.

1. **`corpusHash` is non-deterministic once two items share an `itemID`.** `SearchIndexer.corpusHash` sorts `items.sorted(by: { $0.itemID < $1.itemID })`; Swift's sort is not stable, so an original and its translation may hash in either order. The `hash != storedCorpusHash()` guard would then fire on *every* sync, rebuilding the whole index forever. Fixed in Task 4 by sorting on `(itemID, language)`.
2. **A German-only match would render with no highlight.** `SearchHitResolver.snippet(preferring:)` offers only canonical English bodies, and returns the first candidate that actually contains the query. A hit found via a German document would fall through to the unhighlighted fallback — the same "correct hit with NO visible reason for being in the results" regression the BM25 review fixed for matched fields. Fixed in Task 7 by appending the translated body as a candidate.

## File Structure

**Created (Kit):**
- `Sources/PensieveKit/Translation/TranslationField.swift` — the four translatable fields. The trust-gate boundary as a type.
- `Sources/PensieveKit/Translation/TranslationStore.swift` — the disposable store. Owns source-text hashing so no caller sees a hash.
- `Sources/PensieveKit/Translation/Translator.swift` — the protocol seam, the `TranslationSession` implementation, and the factory.
- `Sources/PensieveKit/Translation/TranslationTarget.swift` — resolves the persisted target language.

**Created (tests):**
- `Tests/PensieveKitTests/TranslationStoreTests.swift`
- `Tests/PensieveKitTests/TranslationTargetTests.swift`
- `Tests/PensieveKitTests/TranslatedCorpusTests.swift`
- `Tests/PensieveKitTests/TranslatedSearchTests.swift`

**Modified (Kit):**
- `Sources/PensieveKit/Search/EmbeddableItem.swift` — `language` field; `gather` emits translated documents.
- `Sources/PensieveKit/Search/SearchIndexer.swift` — hash determinism.
- `Sources/PensieveKit/Search/SearchIndexStore.swift` — schema v3, `language UNINDEXED`.
- `Sources/PensieveKit/Query/SearchHitResolver.swift` — translated snippet candidates.
- `Sources/PensieveKit/Query/SearchQueries.swift` — `item_id` dedup; async backstop wrapper.
- `Sources/PensieveKit/Support/PensievePaths.swift` — `translationCacheURL()`.
- `Sources/PensieveKit/Support/PensieveDefaults.swift` — `translationTargetKey`.

**Modified (app):**
- `Sources/PensieveApp/AppModel.swift` — retained `translationStore` + `translator`.
- `Sources/PensieveApp/AppModel+Narration.swift` — display-translation accessors.
- `Sources/PensieveApp/AppModel+Translation.swift` *(new)* — the on-demand translate action.
- `Sources/PensieveApp/DetailView.swift` — four narration call sites; loose-end context menu.
- `Sources/PensieveApp/SettingsView.swift` — target picker + language-pack download.
- `Sources/PensieveApp/Localizable.xcstrings` — new chrome keys, en + de.

---

### Task 1: `TranslationField` and `TranslationStore`

**Files:**
- Create: `Sources/PensieveKit/Translation/TranslationField.swift`
- Create: `Sources/PensieveKit/Translation/TranslationStore.swift`
- Modify: `Sources/PensieveKit/Support/PensievePaths.swift` (after `searchIndexURL()`, line 21)
- Test: `Tests/PensieveKitTests/TranslationStoreTests.swift`

**Interfaces:**
- Consumes: `PensievePaths.ensureParentDirectory(of:)`, `StableHash`.
- Produces: `TranslationField` (`.narration`, `.looseEndText`, `.nodeName`, `.nodeDescription`); `TranslationStore(url:)`, `.isAvailable`, `.translation(field:sourceText:language:) -> String?`, `.put(field:sourceText:language:text:)`, `.pruneKeeping(sourceTexts:)`; `PensievePaths.translationCacheURL()`.

- [ ] **Step 1: Write the failing test**

```swift
// Tests/PensieveKitTests/TranslationStoreTests.swift
import Testing
import Foundation
@testable import PensieveKit

@Suite struct TranslationStoreTests {
  private func store(_ name: String) -> TranslationStore {
    TranslationStore(url: tempURL(name))
  }

  @Test func roundTripsATranslation() {
    let translationStore = store("translation-roundtrip")
    translationStore.put(field: .narration, sourceText: "Fixed the sync agent",
                         language: "de", text: "Den Sync-Agenten reparoiert")
    #expect(translationStore.translation(field: .narration, sourceText: "Fixed the sync agent",
                                         language: "de") == "Den Sync-Agenten reparoiert")
  }

  @Test func missesOnADifferentField() {
    let translationStore = store("translation-field-miss")
    translationStore.put(field: .narration, sourceText: "same text", language: "de", text: "gleich")
    #expect(translationStore.translation(field: .looseEndText, sourceText: "same text",
                                        language: "de") == nil)
  }

  @Test func missesOnADifferentLanguage() {
    let translationStore = store("translation-language-miss")
    translationStore.put(field: .nodeName, sourceText: "Background sync", language: "de",
                         text: "Hintergrund-Synchronisierung")
    #expect(translationStore.translation(field: .nodeName, sourceText: "Background sync",
                                        language: "fr") == nil)
  }

  /// The invalidation mechanism: the key is derived from the source text, so editing the source
  /// orphans the old row rather than returning it. No explicit staleness check anywhere.
  @Test func changedSourceTextMissesRatherThanReturningStaleText() {
    let translationStore = store("translation-stale")
    translationStore.put(field: .looseEndText, sourceText: "the original summary",
                         language: "de", text: "die ursprüngliche Zusammenfassung")
    #expect(translationStore.translation(field: .looseEndText, sourceText: "the edited summary",
                                        language: "de") == nil)
  }

  @Test func pruningDropsOrphansAndKeepsLiveRows() {
    let translationStore = store("translation-prune")
    translationStore.put(field: .nodeName, sourceText: "live", language: "de", text: "lebendig")
    translationStore.put(field: .nodeName, sourceText: "orphan", language: "de", text: "Waise")
    translationStore.pruneKeeping(sourceTexts: ["live"])
    #expect(translationStore.translation(field: .nodeName, sourceText: "live", language: "de") == "lebendig")
    #expect(translationStore.translation(field: .nodeName, sourceText: "orphan", language: "de") == nil)
  }

  /// The trust gate as a type: there is no case that could name a quote or a transcript message.
  @Test func fieldsAreExactlyTheFourTranslatableOnes() {
    #expect(Set(TranslationField.allCases.map(\.rawValue))
            == ["narration", "looseEndText", "nodeName", "nodeDescription"])
  }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `./scripts/test.sh --filter TranslationStoreTests`
Expected: FAIL — `cannot find 'TranslationStore' in scope`.

- [ ] **Step 3: Write the implementation**

```swift
// Sources/PensieveKit/Translation/TranslationField.swift
import Foundation

/// The fields Pensieve may translate — every one of them text its own models produced.
///
/// This enum IS the trust-gate boundary, expressed as a type rather than a convention. There is
/// deliberately no case naming a loose end's `quote` or a transcript message: verbatim provenance is
/// the north star, and a translated quote would no longer match the transcript it cites. A future
/// contributor cannot translate one by accident, because there is no value to pass.
public enum TranslationField: String, CaseIterable, Sendable {
  case narration
  case looseEndText
  case nodeName
  case nodeDescription
}
```

```swift
// Sources/PensieveKit/Translation/TranslationStore.swift
import Foundation
import GRDB

/// Translations of model-generated text, keyed by `(field, source-text hash, language)`.
///
/// Disposable and never synced, like `narration-cache.sqlite` and `search-index.sqlite`. Losing the
/// file costs re-translation, nothing more — which is exactly why it is NOT in the canonical store:
/// `pensieve.sqlite` is the only store that will ever sync, and derived regenerable data does not
/// belong in CloudKit's future surface.
///
/// Invalidation is structural rather than swept: the key is derived from the source text, so
/// re-extraction changes the text, changes the hash, and orphans the stale row. Nothing ever reads a
/// translation of text that is no longer there. `pruneKeeping` only reclaims disk.
///
/// Hashing lives here so no caller ever handles a hash — `translation(field:sourceText:language:)`
/// and `put` both take the source text itself, which makes it impossible for a reader and a writer to
/// disagree about how the key was derived.
public struct TranslationStore: Sendable {
  private let database: (any DatabaseWriter)?

  public init(url: URL) {
    database = Self.open(url)
  }

  public var isAvailable: Bool { database != nil }

  private static func open(_ url: URL) -> (any DatabaseWriter)? {
    do {
      try PensievePaths.ensureParentDirectory(of: url)
      var configuration = Configuration()
      configuration.busyMode = .timeout(5)   // app and CLI/daemon both open this file
      let pool = try DatabasePool(path: url.path, configuration: configuration)
      try pool.write { database in
        try database.execute(sql: """
          CREATE TABLE IF NOT EXISTS translation (
            field TEXT NOT NULL, source_hash TEXT NOT NULL, language TEXT NOT NULL,
            text TEXT NOT NULL,
            PRIMARY KEY (field, source_hash, language))
          """)
      }
      return pool
    } catch {
      Log.search.error("TranslationStore: failed to open at \(url.path, privacy: .public): \(error, privacy: .public)")
      return nil
    }
  }

  /// Stable across processes and runs — `String.hashValue` is per-process salted and must never be
  /// used here. Same `StableHash` primitive `EmbeddableItem.contentHash` uses.
  static func sourceHash(_ text: String) -> String {
    var hash = StableHash()
    hash.absorb(text)
    return hash.hexValue
  }

  public func translation(field: TranslationField, sourceText: String, language: String) -> String? {
    guard let database, !language.isEmpty, !sourceText.isEmpty else { return nil }
    return try? database.read { database in
      try String.fetchOne(database, sql: """
        SELECT text FROM translation WHERE field = ? AND source_hash = ? AND language = ?
        """, arguments: [field.rawValue, Self.sourceHash(sourceText), language])
    }
  }

  public func put(field: TranslationField, sourceText: String, language: String, text: String) {
    guard let database, !language.isEmpty, !sourceText.isEmpty, !text.isEmpty else { return }
    do {
      try database.write { database in
        try database.execute(sql: """
          INSERT OR REPLACE INTO translation(field, source_hash, language, text) VALUES (?, ?, ?, ?)
          """, arguments: [field.rawValue, Self.sourceHash(sourceText), language, text])
      }
    } catch {
      Log.search.error("TranslationStore: put failed: \(error, privacy: .public)")
    }
  }

  /// Reclaim rows whose source text is no longer live. Purely disk hygiene — an orphan is already
  /// unreachable, because a lookup derives its key from text that no longer exists.
  public func pruneKeeping(sourceTexts: Set<String>) {
    guard let database else { return }
    let liveHashes = sourceTexts.map { Self.sourceHash($0) }
    do {
      try database.write { database in
        guard !liveHashes.isEmpty else {
          try database.execute(sql: "DELETE FROM translation")
          return
        }
        let placeholders = Array(repeating: "?", count: liveHashes.count).joined(separator: ",")
        try database.execute(sql: "DELETE FROM translation WHERE source_hash NOT IN (\(placeholders))",
                             arguments: StatementArguments(liveHashes))
      }
    } catch {
      Log.search.error("TranslationStore: prune failed: \(error, privacy: .public)")
    }
  }
}
```

Add to `Sources/PensieveKit/Support/PensievePaths.swift` immediately after `searchIndexURL()`:

```swift
  /// Disposable, never synced, rebuildable by re-translating. Sibling of the narration cache and the
  /// search index, and deliberately not part of the canonical store.
  public static func translationCacheURL() -> URL {
    supportDirectory().appendingPathComponent("translation-cache.sqlite")
  }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `./scripts/test.sh --filter TranslationStoreTests`
Expected: PASS (6 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/PensieveKit/Translation Sources/PensieveKit/Support/PensievePaths.swift Tests/PensieveKitTests/TranslationStoreTests.swift
git commit -m "feat(kit): a disposable store for translations of generated text"
```

---

### Task 2: The `Translator` seam

**Files:**
- Create: `Sources/PensieveKit/Translation/Translator.swift`
- Test: none of its own — the protocol is exercised by every later task's stub. The system implementation cannot be unit-tested without a language pack, which the Global Constraints forbid depending on.

**Interfaces:**
- Consumes: nothing.
- Produces: `protocol Translator: Sendable { func translate(_ text: String, from: String, to: String) async -> String? }`; `makeDefaultTranslator() -> Translator?`; `SystemTranslator` (macOS 26+).

- [ ] **Step 1: Write the implementation**

There is no failing-test step here: the deliverable is a protocol plus a wrapper over a system framework whose behavior is not reachable in tests. Verification is that the package builds and the seam is usable — Tasks 6, 7 and 8 are where behavior gets tested, through stubs.

```swift
// Sources/PensieveKit/Translation/Translator.swift
import Foundation
#if canImport(Translation)
import Translation
#endif

/// Translates model-generated text. Mirrors `LLMProvider`: Kit declares the seam, the system-backed
/// implementation is availability-gated, and every caller treats nil as "show the original".
///
/// Languages are BCP-47 codes ("en", "de") rather than `Locale.Language` so the seam matches what is
/// persisted in UserDefaults and stays trivially stubbable in tests.
public protocol Translator: Sendable {
  /// Returns nil on any failure — unsupported pair, uninstalled language pack, cancellation,
  /// pre-macOS 26. Never throws: a translation is best-effort by definition.
  func translate(_ text: String, from source: String, to target: String) async -> String?
}

/// The `Translation` framework, on-device.
///
/// Uses the headless `TranslationSession(installedSource:target:)` added in macOS 26 — macOS 15
/// offered only the SwiftUI-attached `.translationTask`, which could not have served a query path.
/// `installedSource` means the language pack must already exist; a headless session cannot prompt for
/// a download, which is why Settings hosts one `.translationTask` view for first-run acquisition.
@available(macOS 26, *)
public struct SystemTranslator: Translator {
  public init() {}

  public func translate(_ text: String, from source: String, to target: String) async -> String? {
    guard !text.isEmpty, !source.isEmpty, !target.isEmpty, source != target else { return nil }
    let sourceLanguage = Locale.Language(identifier: source)
    let targetLanguage = Locale.Language(identifier: target)
    guard await LanguageAvailability().status(from: sourceLanguage, to: targetLanguage) == .installed
    else { return nil }
    let session = TranslationSession(installedSource: sourceLanguage, target: targetLanguage)
    do {
      return try await session.translate(text).targetText
    } catch {
      Log.llm.debug("SystemTranslator: \(source, privacy: .public)→\(target, privacy: .public) failed: \(error, privacy: .public)")
      return nil
    }
  }
}

/// The translator this machine can actually run, or nil below macOS 26. Callers that get nil skip
/// translation entirely and show the English original — the same shape as an unavailable LLM provider.
public func makeDefaultTranslator() -> Translator? {
  if #available(macOS 26, *) { return SystemTranslator() }
  return nil
}
```

- [ ] **Step 2: Verify it builds**

Run: `swift build`
Expected: builds clean. If `Log.llm` is not the right logger category, use the existing category from `Sources/PensieveKit/Support/` rather than adding one.

- [ ] **Step 3: Run the whole suite to confirm nothing regressed**

Run: `./scripts/test.sh`
Expected: PASS, count unchanged from baseline (589 at `907b4fc`).

- [ ] **Step 4: Commit**

```bash
git add Sources/PensieveKit/Translation/Translator.swift
git commit -m "feat(kit): a Translator seam over the macOS 26 headless TranslationSession"
```

---

### Task 3: `TranslationTarget` — the persisted target language

**Files:**
- Create: `Sources/PensieveKit/Translation/TranslationTarget.swift`
- Modify: `Sources/PensieveKit/Support/PensieveDefaults.swift` (add key beside `cloudModelKey`, line 12)
- Test: `Tests/PensieveKitTests/TranslationTargetTests.swift`

**Interfaces:**
- Consumes: `PensieveDefaults.shared()`.
- Produces: `TranslationTarget.off` (`""`), `TranslationTarget.sourceLanguage` (`"en"`), `TranslationTarget.supported` (`["de"]`), `TranslationTarget.resolved(defaults:) -> String`; `PensieveDefaults.translationTargetKey`.

- [ ] **Step 1: Write the failing test**

```swift
// Tests/PensieveKitTests/TranslationTargetTests.swift
import Testing
import Foundation
@testable import PensieveKit

@Suite struct TranslationTargetTests {
  /// A fresh suite name per test: these run in parallel with everything else, and a shared domain
  /// would race.
  private func defaults(_ name: String) -> UserDefaults {
    let defaults = UserDefaults(suiteName: "pensieve.tests.translation.\(name)")!
    defaults.removePersistentDomain(forName: "pensieve.tests.translation.\(name)")
    return defaults
  }

  /// Off is the default, and off must mean off — no store, no index rows, no model load. The vector
  /// engine shipped "default-off" that a stale persisted `true` silently overrode; this pins that an
  /// unset value reads as off rather than as a language.
  @Test func unsetResolvesToOff() {
    #expect(TranslationTarget.resolved(defaults: defaults("unset")) == TranslationTarget.off)
    #expect(TranslationTarget.off.isEmpty)
  }

  @Test func aSupportedLanguageResolvesToItself() {
    let store = defaults("supported")
    store.set("de", forKey: PensieveDefaults.translationTargetKey)
    #expect(TranslationTarget.resolved(defaults: store) == "de")
  }

  /// An unsupported or garbage persisted value degrades to off rather than being handed to the
  /// framework, which would fail per call and log on every render.
  @Test func anUnsupportedLanguageResolvesToOff() {
    let store = defaults("unsupported")
    store.set("klingon", forKey: PensieveDefaults.translationTargetKey)
    #expect(TranslationTarget.resolved(defaults: store) == TranslationTarget.off)
  }

  /// English is the source, never a target: translating en→en is a no-op that would still cost a
  /// store write and an index row per item.
  @Test func englishResolvesToOff() {
    let store = defaults("english")
    store.set("en", forKey: PensieveDefaults.translationTargetKey)
    #expect(TranslationTarget.resolved(defaults: store) == TranslationTarget.off)
  }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `./scripts/test.sh --filter TranslationTargetTests`
Expected: FAIL — `cannot find 'TranslationTarget' in scope`.

- [ ] **Step 3: Write the implementation**

Add to `Sources/PensieveKit/Support/PensieveDefaults.swift` after `cloudModelKey`:

```swift
  public static let translationTargetKey = "translationTarget"
```

```swift
// Sources/PensieveKit/Translation/TranslationTarget.swift
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
  /// Languages offered. Narrow on purpose — each one added doubles a slice of the search index, which
  /// is a measured cost (see the plan's verification gate), not a free dropdown entry.
  public static let supported = ["de"]

  /// The persisted target, or `off` for unset, English, or anything not in `supported`. An
  /// unrecognised value degrades to off rather than reaching the framework, which would fail per call
  /// and log on every render.
  public static func resolved(defaults: UserDefaults = PensieveDefaults.shared()) -> String {
    let stored = defaults.string(forKey: PensieveDefaults.translationTargetKey) ?? off
    return supported.contains(stored) ? stored : off
  }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `./scripts/test.sh --filter TranslationTargetTests`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/PensieveKit/Translation/TranslationTarget.swift Sources/PensieveKit/Support/PensieveDefaults.swift Tests/PensieveKitTests/TranslationTargetTests.swift
git commit -m "feat(kit): the translation target is a setting, not the runtime locale"
```

---

### Task 4: `EmbeddableItem.language` and the `corpusHash` determinism fix

**Files:**
- Modify: `Sources/PensieveKit/Search/EmbeddableItem.swift:5-25`
- Modify: `Sources/PensieveKit/Search/SearchIndexer.swift:45-52` (`corpusHash`)
- Test: `Tests/PensieveKitTests/SearchIndexTests.swift` (extend the existing `SearchIndexerTests` suite)

**Interfaces:**
- Consumes: `EmbeddableItem` as it stands.
- Produces: `EmbeddableItem.language: String` (defaulted `""`), and a `corpusHash` that is order-independent even when two items share an `itemID`.

- [ ] **Step 1: Write the failing test**

Append to the existing `@Suite struct SearchIndexerTests` in `Tests/PensieveKitTests/SearchIndexTests.swift`:

```swift
  /// Two documents share an `item_id` once a translation exists, and `corpusHash` sorts by `itemID`.
  /// Swift's sort is NOT stable, so without `language` in the sort key the hash depends on input
  /// order — and the rebuild guard (`hash != storedCorpusHash()`) would then fire on every sync,
  /// rebuilding the whole index forever.
  @Test func corpusHashIsOrderIndependentForItemsSharingAnItemID() {
    let english = EmbeddableItem(itemID: "a", kind: "node", nodeID: "n1", state: "active",
                                 text: "Background sync")
    let german = EmbeddableItem(itemID: "a", kind: "node", nodeID: "n1", state: "active",
                                text: "Hintergrund-Synchronisierung", language: "de")
    #expect(SearchIndexer.corpusHash([english, german])
            == SearchIndexer.corpusHash([german, english]))
  }

  @Test func corpusHashNoticesALanguageOnlyChange() {
    let untagged = EmbeddableItem(itemID: "a", kind: "node", nodeID: "n1", state: "active",
                                  text: "same text")
    let tagged = EmbeddableItem(itemID: "a", kind: "node", nodeID: "n1", state: "active",
                                text: "same text", language: "de")
    #expect(SearchIndexer.corpusHash([untagged]) != SearchIndexer.corpusHash([tagged]))
  }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `./scripts/test.sh --filter SearchIndexerTests`
Expected: FAIL — `extra argument 'language' in call`.

- [ ] **Step 3: Add the field**

In `Sources/PensieveKit/Search/EmbeddableItem.swift`, add the stored property and initializer parameter:

```swift
  /// "" for the original text, a BCP-47 code ("de") for a translation of it. A translation is a
  /// SEPARATE document sharing the original's `itemID`, never an extra column beside it: FTS5
  /// normalises `bm25()` by a row's TOTAL token count across all columns, so German text sharing a
  /// row with English would discount every English match. The index carries this as
  /// `language UNINDEXED`, which contributes no tokens.
  public let language: String
```

Add `language: String = ""` as the last initializer parameter (after `files`) and assign it:

```swift
  public init(itemID: String, kind: String, nodeID: String, state: String, text: String,
              files: String = "", language: String = "") {
    self.itemID = itemID; self.kind = kind; self.nodeID = nodeID
    self.state = state; self.text = text; self.files = files; self.language = language
  }
```

- [ ] **Step 4: Fix the hash**

In `Sources/PensieveKit/Search/SearchIndexer.swift`, replace the body of `corpusHash`. Extend the doc comment's final sentence to record why the sort key is a pair:

```swift
  /// FNV-1a over every field the index stores, sorted by (item id, language) so gather order cannot
  /// change the hash. `contentHash` covers `text`; `files` is folded in separately because
  /// `contentHash` deliberately excludes it (paths must never force a re-embed on the semantic side).
  ///
  /// The sort key is a PAIR, not just `itemID`: a translated document shares its original's item id,
  /// and Swift's sort is not stable, so sorting on the id alone would hash those two rows in
  /// arbitrary order. The rebuild guard compares this hash to the stored one, so a non-deterministic
  /// hash means a whole-corpus rebuild on every single sync.
  public static func corpusHash(_ items: [EmbeddableItem]) -> String {
    var hash = StableHash()
    for item in items.sorted(by: { ($0.itemID, $0.language) < ($1.itemID, $1.language) }) {
      hash.absorbField(item.itemID); hash.absorbField(item.contentHash)
      hash.absorbField(item.files); hash.absorbField(item.kind)
      hash.absorbField(item.nodeID); hash.absorbField(item.state)
      hash.absorbField(item.language)
    }
    return hash.hexValue
  }
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `./scripts/test.sh --filter SearchIndexerTests`
Expected: PASS, including the pre-existing `corpusHashIsStableAndOrderIndependent`.

- [ ] **Step 6: Commit**

```bash
git add Sources/PensieveKit/Search/EmbeddableItem.swift Sources/PensieveKit/Search/SearchIndexer.swift Tests/PensieveKitTests/SearchIndexTests.swift
git commit -m "fix(kit): corpusHash must be deterministic when two documents share an item_id"
```

---

### Task 5: `SearchIndexStore` schema v3 with a `language UNINDEXED` column

**Files:**
- Modify: `Sources/PensieveKit/Search/SearchIndexStore.swift:20` (version), `:63-76` (schema), `:112-140` (rebuild)
- Test: `Tests/PensieveKitTests/SearchIndexTests.swift`

**Interfaces:**
- Consumes: `EmbeddableItem.language` (Task 4).
- Produces: an index whose `documents` rows carry `language`; unchanged public API — `rebuild(items:corpusHash:)` and `search(_:limit:includeArchived:)` keep their signatures.

- [ ] **Step 1: Write the failing test**

Append to `@Suite struct SearchIndexerTests`:

```swift
  /// The German document must be findable on its own terms, and must carry the SAME item_id as its
  /// original so the query layer can dedup on it.
  @Test func aTranslatedDocumentIsIndexedUnderTheOriginalItemID() {
    let store = tempSearchStore()
    let english = EmbeddableItem(itemID: "item-1", kind: "node", nodeID: "n1", state: "active",
                                 text: "Background sync agent")
    let german = EmbeddableItem(itemID: "item-1", kind: "node", nodeID: "n1", state: "active",
                                text: "Hintergrund-Synchronisierungsagent", language: "de")
    store.rebuild(items: [english, german], corpusHash: "hash-1")

    let germanHits = store.search(FTSQueryBuilder.build("Hintergrund ")!, limit: 10,
                                 includeArchived: false)
    #expect(germanHits.map(\.itemID) == ["item-1"])

    let englishHits = store.search(FTSQueryBuilder.build("background ")!, limit: 10,
                                  includeArchived: false)
    #expect(englishHits.map(\.itemID) == ["item-1"])
  }

  /// A schema bump must rebuild rather than read a table without the new column. Free, because the
  /// store is disposable.
  @Test func aVersionMismatchRebuildsInsteadOfFailing() throws {
    let url = tempURL("searchidx-v3-migrate")
    let first = SearchIndexStore(url: url)
    first.rebuild(items: [EmbeddableItem(itemID: "a", kind: "node", nodeID: "n1",
                                         state: "active", text: "alpha")],
                  corpusHash: "hash-a")
    #expect(first.state() == .ready)
    // Reopening at the same version must NOT discard the index.
    let reopened = SearchIndexStore(url: url)
    #expect(reopened.storedCorpusHash() == "hash-a")
  }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `./scripts/test.sh --filter SearchIndexerTests`
Expected: FAIL — the German query returns no rows, because `rebuild` does not yet insert a second document.

- [ ] **Step 3: Bump the version and the schema**

`Sources/PensieveKit/Search/SearchIndexStore.swift` line 20:

```swift
  private static let schemaVersion = 3
```

In the `CREATE VIRTUAL TABLE ... documents` statement, add `language UNINDEXED` to the metadata columns:

```swift
        try database.execute(sql: """
          CREATE VIRTUAL TABLE IF NOT EXISTS documents USING fts5(
            text,
            item_id UNINDEXED, kind UNINDEXED, node_id UNINDEXED, state UNINDEXED,
            language UNINDEXED,
            tokenize = 'unicode61 remove_diacritics 2')
          """)
```

Leave `document_files` untouched: a translated item carries `files: ""` and therefore never reaches the path table.

- [ ] **Step 4: Insert the column in `rebuild`**

Replace the `documentInsert` statement and its `execute` call:

```swift
        let documentInsert = try database.cachedStatement(sql: """
          INSERT INTO documents(text, item_id, kind, node_id, state, language)
          VALUES (?, ?, ?, ?, ?, ?)
          """)
```

```swift
          try documentInsert.execute(
            arguments: [item.text, item.itemID, item.kind, item.nodeID, item.state, item.language])
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `./scripts/test.sh --filter SearchIndexerTests`
Expected: PASS. Then `./scripts/test.sh` — the whole suite, because the schema bump invalidates every developer's local index and any test asserting on index internals must still hold.

- [ ] **Step 6: Commit**

```bash
git add Sources/PensieveKit/Search/SearchIndexStore.swift Tests/PensieveKitTests/SearchIndexTests.swift
git commit -m "feat(kit): index schema v3 tags each document with its language"
```

---

### Task 6: `EmbeddableCorpus.gather` emits translated documents

**Files:**
- Modify: `Sources/PensieveKit/Search/EmbeddableItem.swift:41-90` (`gather`)
- Modify: `Sources/PensieveKit/Search/SearchIndexer.swift:29` (`sync` passes the translation store)
- Test: `Tests/PensieveKitTests/TranslatedCorpusTests.swift`

**Interfaces:**
- Consumes: `TranslationStore.translation(field:sourceText:language:)` (Task 1), `TranslationTarget.resolved` (Task 3), `EmbeddableItem.language` (Task 4).
- Produces: `EmbeddableCorpus.gather(_:translations:language:)` with both new parameters defaulted (`nil` / `TranslationTarget.off`), so every existing caller and test compiles unchanged. `SearchIndexer.init(store:translations:language:)` likewise defaulted.

- [ ] **Step 1: Write the failing test**

```swift
// Tests/PensieveKitTests/TranslatedCorpusTests.swift
import Testing
import Foundation
import SQLiteData
@testable import PensieveKit

@Suite struct TranslatedCorpusTests {
  @Test func gatherEmitsATranslatedDocumentBesideTheOriginal() async throws {
    let database = try openCanonicalDatabase(at: tempURL("corpus-translated"))
    let node = Node(name: "Background sync", kind: NodeKind.project)
    try await database.write { database in try Node.insert { node }.execute(database) }

    let translations = TranslationStore(url: tempURL("corpus-translated-cache"))
    // gather indexes a node as "name — description"; with an empty description that is just the name.
    translations.put(field: .nodeName, sourceText: "Background sync", language: "de",
                     text: "Hintergrund-Synchronisierung")

    let items = try EmbeddableCorpus.gather(database, translations: translations, language: "de")
    let forNode = items.filter { $0.itemID == node.id.uuidString }
    #expect(forNode.count == 2)
    #expect(forNode.contains { $0.language == "" && $0.text == "Background sync" })
    #expect(forNode.contains { $0.language == "de" && $0.text == "Hintergrund-Synchronisierung" })
  }

  /// The trust gate, tested: the translated loose-end document carries the summary only. `gather`
  /// indexes the original as "text — quote"; the translation must NOT re-append the English quote,
  /// which would both translate-adjacent a verbatim citation and manufacture a duplicate hit.
  @Test func theTranslatedLooseEndDocumentExcludesTheQuote() async throws {
    let database = try openCanonicalDatabase(at: tempURL("corpus-translated-quote"))
    let node = Node(name: "Project", kind: NodeKind.project)
    let source = Source(nodeID: node.id, kind: SourceKind.gitRepo, key: "/p/\(node.id)")
    let event = Event(nodeID: node.id, sourceID: source.id, occurredAt: Date(),
                      kind: CaptureKind.ccSession, summary: "a session",
                      detailJSON: "{}", fingerprint: "session-1")
    let looseEnd = LooseEnd(nodeID: node.id, sourceEventID: event.id, text: "Ship the sync agent",
                            quote: "we should ship the sync agent this week")
    try await database.write { database in
      try Node.insert { node }.execute(database)
      try Source.insert { source }.execute(database)
      try Event.insert { event }.execute(database)
      try LooseEnd.insert { looseEnd }.execute(database)
    }
    let translations = TranslationStore(url: tempURL("corpus-translated-quote-cache"))
    translations.put(field: .looseEndText, sourceText: "Ship the sync agent", language: "de",
                     text: "Den Sync-Agenten ausliefern")

    let items = try EmbeddableCorpus.gather(database, translations: translations, language: "de")
    let translated = items.filter { $0.itemID == looseEnd.id.uuidString && $0.language == "de" }
    #expect(translated.count == 1)
    #expect(translated[0].text == "Den Sync-Agenten ausliefern")
    #expect(!translated[0].text.contains("this week"))
  }

  /// Off means off: no translated rows, and no reason for the corpus hash to move.
  @Test func gatherEmitsNoTranslationsWhenTheTargetIsOff() async throws {
    let database = try openCanonicalDatabase(at: tempURL("corpus-translated-off"))
    let node = Node(name: "Background sync", kind: NodeKind.project)
    try await database.write { database in try Node.insert { node }.execute(database) }
    let translations = TranslationStore(url: tempURL("corpus-translated-off-cache"))
    translations.put(field: .nodeName, sourceText: "Background sync", language: "de",
                     text: "Hintergrund-Synchronisierung")

    let items = try EmbeddableCorpus.gather(database, translations: translations,
                                           language: TranslationTarget.off)
    #expect(items.allSatisfy { $0.language.isEmpty })
  }

  /// An untranslated item yields exactly one document. Sparse translation is the expected steady
  /// state — the on-demand action translates what the user reads, not the whole corpus.
  @Test func anUntranslatedItemYieldsOneDocument() async throws {
    let database = try openCanonicalDatabase(at: tempURL("corpus-translated-sparse"))
    let node = Node(name: "Never translated", kind: NodeKind.project)
    try await database.write { database in try Node.insert { node }.execute(database) }
    let items = try EmbeddableCorpus.gather(database,
                                           translations: TranslationStore(url: tempURL("corpus-sparse-cache")),
                                           language: "de")
    #expect(items.filter { $0.itemID == node.id.uuidString }.count == 1)
  }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `./scripts/test.sh --filter TranslatedCorpusTests`
Expected: FAIL — `extra argument 'translations' in call`.

- [ ] **Step 3: Implement the producer**

In `Sources/PensieveKit/Search/EmbeddableItem.swift`, change `gather`'s signature and add translated emission. The two new parameters are defaulted so no existing caller changes:

```swift
  /// `translations` + `language` add a SECOND document per item whose generated text has a stored
  /// translation, sharing the original's `itemID`. Defaulted to off, so a caller that has no opinion
  /// (every test, the CLI paths that only read) produces exactly the corpus it did before.
  public static func gather(_ database: any DatabaseReader,
                            translations: TranslationStore? = nil,
                            language: String = TranslationTarget.off) throws -> [EmbeddableItem] {
```

Inside the `database.read` block, add a local helper immediately after `out` is declared:

```swift
      // A translated document, or nothing. Off, no store, or no stored translation all mean "the
      // original is the only document for this item" — sparse translation is the steady state.
      //
      // `kind` is a parameter, not a constant: a translated document MUST carry the same kind as the
      // original it shadows, because `buildHits` maps `kind` to `SearchHit.Kind` and resolves the item
      // through that branch. A translated loose end tagged "node" would resolve against the Node
      // table by a loose-end id and silently vanish.
      func translated(_ field: TranslationField, of sourceText: String, kind: String,
                      itemID: String, nodeID: String, state: String) -> EmbeddableItem? {
        guard !language.isEmpty, let translations,
              let text = translations.translation(field: field, sourceText: sourceText,
                                                  language: language)
        else { return nil }
        return EmbeddableItem(itemID: itemID, kind: kind, nodeID: nodeID, state: state,
                              text: text, language: language)
      }
```

The node loop does not use that helper — a node has TWO translatable fields (`name` and `description`) that must be joined into one document the same way the original joins them, so it composes them inline. In the node loop, after the existing `out.append`:

```swift
        // Name and description are separate fields with separate translations, joined the same way
        // the original document joins them.
        let translatedName = translations?.translation(field: .nodeName, sourceText: node.name,
                                                       language: language)
        let translatedDescription = node.description.isEmpty ? nil
          : translations?.translation(field: .nodeDescription, sourceText: node.description,
                                      language: language)
        if !language.isEmpty, translatedName != nil || translatedDescription != nil {
          let text = [translatedName ?? node.name, translatedDescription ?? node.description]
            .filter { !$0.isEmpty }.joined(separator: " — ")
          out.append(.init(itemID: node.id.uuidString, kind: "node", nodeID: node.id.uuidString,
                           state: node.state.rawValue, text: text, language: language))
        }
```

In the loose-end loop, after the existing `out.append`:

```swift
        // Text ONLY — never the quote. The original document is "text — quote"; a translated
        // document that re-appended the English quote would manufacture a duplicate hit, and the
        // quote is verbatim provenance that must never be adjacent to a translation.
        if let text = translated(.looseEndText, of: looseEnd.text, kind: "loose_end",
                                 itemID: looseEnd.id.uuidString,
                                 nodeID: looseEnd.nodeID.uuidString, state: state) {
          out.append(text)
        }
```

Events get no translated document: their text is captured content (a commit subject) or an enriched summary that is out of scope per the spec.

- [ ] **Step 4: Thread it through `SearchIndexer`**

In `Sources/PensieveKit/Search/SearchIndexer.swift`, add stored properties and pass them to `gather`:

```swift
  let store: SearchIndexStore
  let translations: TranslationStore?
  let language: String
  public init(store: SearchIndexStore, translations: TranslationStore? = nil,
              language: String = TranslationTarget.off) {
    self.store = store
    self.translations = translations
    self.language = language
  }
```

```swift
  public static func production() -> SearchIndexer {
    let language = TranslationTarget.resolved()
    // Off means off: do not even open the translation store, so no file is created.
    let translations = language.isEmpty ? nil
      : TranslationStore(url: PensievePaths.translationCacheURL())
    return SearchIndexer(store: SearchIndexStore(url: PensievePaths.searchIndexURL()),
                         translations: translations, language: language)
  }
```

In `sync`, pass them through:

```swift
    guard let corpus = try? EmbeddableCorpus.gather(database, translations: translations,
                                                   language: language) else { return }
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `./scripts/test.sh --filter TranslatedCorpusTests` then `./scripts/test.sh`
Expected: both PASS. `EmbeddableCorpusHygieneTests` must still pass untouched — the hygiene rules are unchanged.

- [ ] **Step 6: Commit**

```bash
git add Sources/PensieveKit/Search Tests/PensieveKitTests/TranslatedCorpusTests.swift
git commit -m "feat(kit): translated text joins the corpus as its own document"
```

---

### Task 7: Dedup on `item_id` and translated snippet candidates

**Files:**
- Modify: `Sources/PensieveKit/Query/SearchQueries.swift:96-124` (`buildHits`)
- Modify: `Sources/PensieveKit/Query/SearchHitResolver.swift:32-45` (properties), `:46-61` (node and loose-end cases), `:89-96` (`snippet`)
- Test: `Tests/PensieveKitTests/TranslatedSearchTests.swift`

**Interfaces:**
- Consumes: everything from Tasks 1–6.
- Produces: `SearchQueries.search(query:file:scope:store:translations:language:_:)` — two new defaulted parameters; `SearchHitResolver.translations: (TranslationField, String) -> String?` defaulted to `{ _, _ in nil }`.

This is the task that closes correction 2. A German-only match currently resolves against canonical English fields, and `snippet(preferring:)` returns the first candidate that *contains* the query — so it would fall through to the unhighlighted fallback and render a hit with no visible reason for being there.

- [ ] **Step 1: Write the failing test**

```swift
// Tests/PensieveKitTests/TranslatedSearchTests.swift
import Testing
import Foundation
import SQLiteData
@testable import PensieveKit

@Suite struct TranslatedSearchTests {
  private struct Fixture {
    let database: any DatabaseReader
    let store: SearchIndexStore
    let translations: TranslationStore
    let node: Node
    let scope: SearchScope
  }

  private func fixture(_ name: String) async throws -> Fixture {
    let database = try openCanonicalDatabase(at: tempURL("\(name)-canonical"))
    let node = Node(name: "Background sync", kind: NodeKind.project)
    try await database.write { database in try Node.insert { node }.execute(database) }
    let translations = TranslationStore(url: tempURL("\(name)-translations"))
    translations.put(field: .nodeName, sourceText: "Background sync", language: "de",
                     text: "Hintergrund-Synchronisierung")
    let store = tempSearchStore()
    SearchIndexer(store: store, translations: translations, language: "de").sync(database)
    return Fixture(database: database, store: store, translations: translations, node: node,
                   scope: SearchScope(visibleNodeIDs: [node.id]))
  }

  @Test func aGermanQueryFindsTheNodeThroughItsTranslation() async throws {
    let fixture = try await fixture("german-query")
    let hits = SearchQueries.search(query: "Hintergrund", scope: fixture.scope,
                                    store: fixture.store, translations: fixture.translations,
                                    language: "de", fixture.database)
    #expect(hits.map(\.nodeID) == [fixture.node.id])
  }

  /// Correction 2. A hit the user cannot see the reason for is a bug, not a cosmetic issue: the
  /// resolver highlights against canonical ENGLISH text, so without the translated body as a
  /// candidate this row renders with an empty match.
  @Test func aGermanOnlyMatchIsHighlighted() async throws {
    let fixture = try await fixture("german-highlight")
    let hits = SearchQueries.search(query: "Hintergrund", scope: fixture.scope,
                                    store: fixture.store, translations: fixture.translations,
                                    language: "de", fixture.database)
    #expect(hits.count == 1)
    #expect(!hits[0].snippet.match.isEmpty)
  }

  /// Both language documents match "sync" (it appears in the German compound too, and the tokenizer
  /// is diacritic-insensitive), so the same node must not appear twice.
  @Test func aTermMatchingBothLanguagesYieldsOneHit() async throws {
    let fixture = try await fixture("dedup")
    let hits = SearchQueries.search(query: "Synchronisierung", scope: fixture.scope,
                                    store: fixture.store, translations: fixture.translations,
                                    language: "de", fixture.database)
    #expect(hits.filter { $0.nodeID == fixture.node.id }.count == 1)
  }

  /// The English path must be unaffected — same hit, same highlight, translations present or not.
  @Test func theEnglishPathIsUnchangedByThePresenceOfATranslation() async throws {
    let fixture = try await fixture("english-unchanged")
    let hits = SearchQueries.search(query: "background", scope: fixture.scope,
                                    store: fixture.store, translations: fixture.translations,
                                    language: "de", fixture.database)
    #expect(hits.count == 1)
    #expect(hits[0].snippet.match.lowercased() == "background")
  }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `./scripts/test.sh --filter TranslatedSearchTests`
Expected: FAIL — `extra argument 'translations' in call`.

- [ ] **Step 3: Give the resolver translated snippet candidates**

In `Sources/PensieveKit/Query/SearchHitResolver.swift`, add the property after `highlight`:

```swift
  /// A stored translation of one generated field, or nil. Present so a match found ONLY in a
  /// translated document still highlights: this resolver re-reads canonical, which holds English, and
  /// `snippet(preferring:)` returns the first candidate that actually contains the query — so without
  /// the translated body in that list a German hit renders with no visible reason for being there.
  var translations: (TranslationField, String) -> String? = { _, _ in nil }
```

In the `.node` case, replace the `snippet(preferring:)` argument:

```swift
      return SearchHit(id: node.id, kind: .node, nodeID: node.id, nodeName: node.name,
                       title: node.name,
                       snippet: snippet(preferring: [node.description, node.name,
                                                     translations(.nodeDescription, node.description) ?? "",
                                                     translations(.nodeName, node.name) ?? ""]),
                       score: score, isArchived: node.state == .archived)
```

In the `.looseEnd` case:

```swift
                       snippet: snippet(preferring: [looseEnd.text, looseEnd.quote,
                                                     translations(.looseEndText, looseEnd.text) ?? ""]),
```

Translations go LAST in every candidate list: an English match must keep winning, and the translated body is reached only on fallthrough. `snippet(preferring:)` already skips empty candidates, so a nil translation costs nothing. `title` stays canonical — the row is titled by the node's real name and the *snippet* shows why it matched.

- [ ] **Step 4: Dedup and thread the closure through `buildHits`**

In `Sources/PensieveKit/Query/SearchQueries.swift`, add the two defaulted parameters to `search` and pass them to `buildHits`:

```swift
  public static func search(query rawQuery: String,
                            file: String? = nil,
                            scope: SearchScope,
                            store: SearchIndexStore,
                            translations: TranslationStore? = nil,
                            language: String = TranslationTarget.off,
                            _ database: any DatabaseReader) -> [SearchHit] {
```

```swift
      let hits = buildHits(candidates, terms: ftsQuery.terms, scope: scope,
                           translations: translations, language: language, database)
```

Then in `buildHits`:

```swift
  private static func buildHits(_ candidates: [SearchIndexHit], terms: [String],
                                scope: SearchScope,
                                translations: TranslationStore?, language: String,
                                _ database: any DatabaseReader) -> [SearchHit] {
    let resolver = SearchHitResolver(
      includeArchived: scope.includeArchived,
      highlight: { SnippetMaker.make(from: $0, matchingAny: terms) },
      translations: { field, sourceText in
        guard let translations, !language.isEmpty else { return nil }
        return translations.translation(field: field, sourceText: sourceText, language: language)
      })
```

Inside the loop, add dedup immediately after the `itemID` guard, before resolving:

```swift
        // One hit per item, even when both its language documents matched. Deduped BEFORE resolving
        // so a duplicate costs no canonical read. The `limit` shortfall this can cause is absorbed by
        // the caller's grow-`k` loop, which already exists for Focus-muting and stale rows.
        var seenItemIDs = Set<UUID>()
```

(declare `seenItemIDs` beside `hits`, above the `for` loop), and in the loop after the `excludingIDs` guard:

```swift
          guard seenItemIDs.insert(itemID).inserted else { continue }
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `./scripts/test.sh --filter TranslatedSearchTests` then `./scripts/test.sh`
Expected: both PASS. Every pre-existing search test must pass untouched — the new parameters are defaulted and the English path is unchanged.

- [ ] **Step 6: Commit**

```bash
git add Sources/PensieveKit/Query Tests/PensieveKitTests/TranslatedSearchTests.swift
git commit -m "feat(kit): dedup language documents and highlight German-only matches"
```

---

### Task 8: The zero-result query backstop

**Files:**
- Modify: `Sources/PensieveKit/Query/SearchQueries.swift` (add a new static function; do not touch `search`)
- Test: `Tests/PensieveKitTests/TranslatedSearchTests.swift`

**Interfaces:**
- Consumes: `SearchQueries.search(...)` from Task 7, `Translator` from Task 2.
- Produces: `SearchQueries.searchTranslatingOnEmpty(query:file:scope:store:translations:language:translator:_:) async -> [SearchHit]`.

The existing synchronous `search` is left **byte-identical**. That is what makes "the backstop cannot regress a query that currently returns rows" a structural claim rather than a promise: the wrapper calls the untouched function first and only acts on an empty result.

- [ ] **Step 1: Write the failing test**

Append to `@Suite struct TranslatedSearchTests`:

```swift
  /// A translator that records its calls, so the negative assertion below is real.
  private actor RecordingTranslator: Translator {
    private(set) var calls: [String] = []
    private let mapping: [String: String]
    init(mapping: [String: String]) { self.mapping = mapping }
    func translate(_ text: String, from source: String, to target: String) async -> String? {
      await record(text)
      return mapping[text]
    }
    private func record(_ text: String) { calls.append(text) }
    func callCount() -> Int { calls.count }
  }

  @Test func aGermanQueryOverUntranslatedContentIsRetriedInEnglish() async throws {
    let database = try openCanonicalDatabase(at: tempURL("backstop-canonical"))
    let node = Node(name: "Pensieve", kind: NodeKind.project)
    let source = Source(nodeID: node.id, kind: SourceKind.gitRepo, key: "/p/\(node.id)")
    let event = Event(nodeID: node.id, sourceID: source.id, occurredAt: Date(),
                      kind: CaptureKind.gitCommit, summary: "fix the background sync agent",
                      detailJSON: "{}", fingerprint: "commit-backstop-1")
    try await database.write { database in
      try Node.insert { node }.execute(database)
      try Source.insert { source }.execute(database)
      try Event.insert { event }.execute(database)
    }
    let store = tempSearchStore()
    SearchIndexer(store: store).sync(database)
    let translator = RecordingTranslator(mapping: ["Hintergrund": "background"])

    // A commit subject is captured content and never gets a stored translation, so the literal
    // German query cannot match — this is exactly the residual gap the backstop exists for.
    let literal = SearchQueries.search(query: "Hintergrund",
                                       scope: SearchScope(visibleNodeIDs: [node.id]),
                                       store: store, database)
    #expect(literal.isEmpty)

    let hits = await SearchQueries.searchTranslatingOnEmpty(
      query: "Hintergrund", scope: SearchScope(visibleNodeIDs: [node.id]), store: store,
      translations: nil, language: "de", translator: translator, database)
    #expect(hits.contains { $0.nodeID == node.id })
  }

  /// The safety property, asserted rather than assumed. Mutation-check this both ways: delete the
  /// `guard hits.isEmpty` in the implementation and this test MUST fail. A test that only checked
  /// "results came back" would pass with the guard removed.
  @Test func aQueryThatAlreadyHasResultsNeverReachesTheTranslator() async throws {
    let database = try openCanonicalDatabase(at: tempURL("backstop-noop-canonical"))
    let node = Node(name: "Background sync", kind: NodeKind.project)
    try await database.write { database in try Node.insert { node }.execute(database) }
    let store = tempSearchStore()
    SearchIndexer(store: store).sync(database)
    let translator = RecordingTranslator(mapping: [:])

    let hits = await SearchQueries.searchTranslatingOnEmpty(
      query: "background", scope: SearchScope(visibleNodeIDs: [node.id]), store: store,
      translations: nil, language: "de", translator: translator, database)
    #expect(!hits.isEmpty)
    #expect(await translator.callCount() == 0)
  }

  @Test func offMeansTheTranslatorIsNeverReachedEvenOnZeroResults() async throws {
    let database = try openCanonicalDatabase(at: tempURL("backstop-off-canonical"))
    let node = Node(name: "Background sync", kind: NodeKind.project)
    try await database.write { database in try Node.insert { node }.execute(database) }
    let store = tempSearchStore()
    SearchIndexer(store: store).sync(database)
    let translator = RecordingTranslator(mapping: ["Hintergrund": "background"])

    let hits = await SearchQueries.searchTranslatingOnEmpty(
      query: "Hintergrund", scope: SearchScope(visibleNodeIDs: [node.id]), store: store,
      translations: nil, language: TranslationTarget.off, translator: translator, database)
    #expect(hits.isEmpty)
    #expect(await translator.callCount() == 0)
  }

  /// Exactly one retry. A translation that also finds nothing is the end of the road — there is no
  /// second language to try and no reason to re-query.
  @Test func theBackstopRetriesAtMostOnce() async throws {
    let database = try openCanonicalDatabase(at: tempURL("backstop-once-canonical"))
    let node = Node(name: "Background sync", kind: NodeKind.project)
    try await database.write { database in try Node.insert { node }.execute(database) }
    let store = tempSearchStore()
    SearchIndexer(store: store).sync(database)
    let translator = RecordingTranslator(mapping: ["Nichtvorhanden": "nonexistent"])

    let hits = await SearchQueries.searchTranslatingOnEmpty(
      query: "Nichtvorhanden", scope: SearchScope(visibleNodeIDs: [node.id]), store: store,
      translations: nil, language: "de", translator: translator, database)
    #expect(hits.isEmpty)
    #expect(await translator.callCount() == 1)
  }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `./scripts/test.sh --filter TranslatedSearchTests`
Expected: FAIL — `type 'SearchQueries' has no member 'searchTranslatingOnEmpty'`.

- [ ] **Step 3: Write the implementation**

Add to `Sources/PensieveKit/Query/SearchQueries.swift`, after `search`:

```swift
  /// `search`, plus one retry in English when the literal query found nothing.
  ///
  /// A wrapper rather than a change to `search` for two reasons. `search` is synchronous and every
  /// caller depends on that; and keeping it byte-identical is what makes the safety property
  /// STRUCTURAL — this can never regress a query that already returns rows, because it only runs when
  /// the result was already empty.
  ///
  /// No language detection. Detection over a two-word query is unreliable, and it is unnecessary:
  /// translating an already-English query yields a no-op or nonsense, and since there was nothing to
  /// lose, nothing is lost. The residual value is over content that never gets a stored
  /// translation — commit subjects, event summaries, file paths — plus German compounding, where a
  /// typed `Hintergrundsync` misses a stored `Hintergrund-Synchronisierung` under AND semantics.
  public static func searchTranslatingOnEmpty(query rawQuery: String,
                                              file: String? = nil,
                                              scope: SearchScope,
                                              store: SearchIndexStore,
                                              translations: TranslationStore? = nil,
                                              language: String = TranslationTarget.off,
                                              translator: Translator? = nil,
                                              _ database: any DatabaseReader) async -> [SearchHit] {
    let hits = search(query: rawQuery, file: file, scope: scope, store: store,
                      translations: translations, language: language, database)
    guard hits.isEmpty, !language.isEmpty, let translator else { return hits }
    let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    guard query.count >= minQueryLength,
          let english = await translator.translate(query, from: language,
                                                   to: TranslationTarget.sourceLanguage),
          english.caseInsensitiveCompare(query) != .orderedSame
    else { return hits }
    return search(query: english, file: file, scope: scope, store: store,
                  translations: translations, language: language, database)
  }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `./scripts/test.sh --filter TranslatedSearchTests`
Expected: PASS (8 tests).

- [ ] **Step 5: Mutation-check the negative assertion**

Temporarily delete `hits.isEmpty` from the `guard` (leaving `!language.isEmpty, let translator`), then run:

Run: `./scripts/test.sh --filter TranslatedSearchTests`
Expected: FAIL on `aQueryThatAlreadyHasResultsNeverReachesTheTranslator`. **Restore the guard.** If it passed, the test is vacuous — fix the test, not the guard. This step exists because the BM25 review found two tests that still passed with the behavior removed entirely.

- [ ] **Step 6: Commit**

```bash
git add Sources/PensieveKit/Query/SearchQueries.swift Tests/PensieveKitTests/TranslatedSearchTests.swift
git commit -m "feat(kit): retry an empty search in English, never a search that found rows"
```

---

### Task 9: Settings — target picker and language-pack download

**Files:**
- Modify: `Sources/PensieveApp/SettingsView.swift` (Intelligence tab)
- Modify: `Sources/PensieveApp/Localizable.xcstrings`

**Interfaces:**
- Consumes: `TranslationTarget`, `PensieveDefaults.translationTargetKey`.
- Produces: a persisted target language, and the one `.translationTask` view in the codebase.

- [ ] **Step 1: Read the file and locate the Intelligence tab**

Run: `grep -n "Intelligence\|Section\|@AppStorage" Sources/PensieveApp/SettingsView.swift`

Match the surrounding section's idiom exactly rather than inventing a layout.

- [ ] **Step 2: Add the picker and the download affordance**

```swift
// In the Intelligence tab, as its own Section.
Section {
  Picker(LocalizedStringKey("Translate generated text to"), selection: $translationTarget) {
    Text(LocalizedStringKey("Off")).tag(TranslationTarget.off)
    Text(verbatim: "Deutsch").tag("de")
  }
  if translationTarget != TranslationTarget.off {
    // The ONLY view-attached translation in the app. A headless TranslationSession cannot request a
    // download (`canRequestDownloads`), so first-run pack acquisition has to happen here; everywhere
    // else uses the headless session and degrades to English when the pack is absent.
    if #available(macOS 26, *) {
      Text(LocalizedStringKey("Prepare translation"))
        .translationTask(source: Locale.Language(identifier: TranslationTarget.sourceLanguage),
                         target: Locale.Language(identifier: translationTarget)) { session in
          try? await session.prepareTranslation()
        }
    } else {
      Text(LocalizedStringKey("Translation requires macOS 26 or later."))
        .foregroundStyle(.secondary)
    }
  }
} header: {
  Text(LocalizedStringKey("Translation"))
} footer: {
  Text(LocalizedStringKey("Generated summaries are translated on this device. Captured text, cited quotes and transcripts are never translated."))
    .font(.caption)
    .foregroundStyle(.secondary)
}
```

Declare the binding beside the view's other `@AppStorage` properties, using the shared suite so the CLI and agent read the same value:

```swift
  @AppStorage(PensieveDefaults.translationTargetKey, store: PensieveDefaults.shared())
  private var translationTarget: String = TranslationTarget.off
```

- [ ] **Step 3: Add the String Catalog keys**

Add these keys to `Sources/PensieveApp/Localizable.xcstrings` by hand, both `en` and `de`. `xcodebuild` does **not** auto-populate the source catalog — that is IDE-only, and a mis-keyed `de` value silently falls back to English.

| Key | de |
|---|---|
| `Translation` | `Übersetzung` |
| `Translate generated text to` | `Generierte Texte übersetzen nach` |
| `Off` | `Aus` |
| `Prepare translation` | `Übersetzung vorbereiten` |
| `Translation requires macOS 26 or later.` | `Übersetzung erfordert macOS 26 oder neuer.` |
| `Generated summaries are translated on this device. Captured text, cited quotes and transcripts are never translated.` | `Generierte Zusammenfassungen werden auf diesem Gerät übersetzt. Erfasste Texte, zitierte Passagen und Transkripte werden nie übersetzt.` |

Impersonal/infinitive German, per the project's convention. "Deutsch" is a proper name and stays untranslated in both locales.

- [ ] **Step 4: Build and smoke-launch**

```bash
xcodegen generate
xcodebuild -project Pensieve.xcodeproj -scheme Pensieve -configuration Debug \
  -derivedDataPath ./.build-xcode build 2>&1 | tail -5
PENSIEVE_DB=/tmp/smoke.sqlite PENSIEVE_CAPTURE_DB=/tmp/smoke-capture.sqlite \
  ./.build-xcode/Build/Products/Debug/Pensieve.app/Contents/MacOS/Pensieve &
sleep 5 && kill %1
```

Expected: builds clean, launches without crashing. Then discard the transient `Package.resolved` churn an `xcodebuild` produces.

- [ ] **Step 5: Verify the German keys reached the bundle**

```bash
plutil -p ./.build-xcode/Build/Products/Debug/Pensieve.app/Contents/Resources/de.lproj/Localizable.strings | grep -i "bersetz"
```

Expected: the six German values above. An absent key means the catalog edit did not take.

- [ ] **Step 6: Commit**

```bash
git add Sources/PensieveApp/SettingsView.swift Sources/PensieveApp/Localizable.xcstrings
git commit -m "feat(app): choose a translation target, and acquire its language pack"
```

---

### Task 10: Narration renders translated — one string, every consumer

**Files:**
- Modify: `Sources/PensieveApp/AppModel.swift` (retained store + translator)
- Modify: `Sources/PensieveApp/AppModel+Narration.swift` (display accessors)
- Modify: `Sources/PensieveApp/DetailView.swift:120-135` (four narration reads)

**Interfaces:**
- Consumes: `TranslationStore`, `makeDefaultTranslator()`, `TranslationTarget.resolved()`.
- Produces: `AppModel.cachedDisplayNarration(for:events:) -> String?`, `AppModel.displayNarration(for:events:force:) async -> String?`.

The English prose stays canonical in `NarrationCache` — it is shared with the CLI and `pensieve mcp`, which feed Claude Code and want English. Only the *display* string is translated.

- [ ] **Step 1: Retain the store and translator on `AppModel`**

Beside the existing `searchStore` property:

```swift
  @ObservationIgnored lazy var translationStore = TranslationStore(url: PensievePaths.translationCacheURL())
  @ObservationIgnored lazy var translator: Translator? = makeDefaultTranslator()
```

`lazy` matters: with the target off, neither is ever touched, so no store file is created and no model asset loads.

- [ ] **Step 2: Add the display accessors**

In `Sources/PensieveApp/AppModel+Narration.swift`:

```swift
  /// The narration as it should RENDER: the English prose, or its stored translation when a target
  /// language is set. Synchronous, so the view can render a cached recap instantly — a point lookup
  /// against a small local file, the same shape as `isDescribable`'s canonical read.
  func cachedDisplayNarration(for node: Node, events: [Event]) -> String? {
    guard let prose = cachedNarration(for: node, events: events) else { return nil }
    return displayText(prose)
  }

  /// Generate (or reuse) the narration, then resolve its display form — translating and storing it if
  /// this is the first time this prose has been seen in the target language.
  ///
  /// Translation happens BEFORE the view first renders the prose, giving one atomic spinner → German
  /// transition. An English→German flicker would be worse, and would add a second stale-render window
  /// to a state machine that needed two adversarial reviews plus an Opus review to get right.
  func displayNarration(for node: Node, events: [Event], force: Bool = false) async -> String? {
    guard let prose = await narration(for: node, events: events, force: force) else { return nil }
    let language = TranslationTarget.resolved()
    guard !language.isEmpty else { return prose }
    if let stored = translationStore.translation(field: .narration, sourceText: prose,
                                                 language: language) { return stored }
    guard let translator,
          let translated = await translator.translate(prose,
                                                      from: TranslationTarget.sourceLanguage,
                                                      to: language)
    else { return prose }   // best-effort: the English original is always an acceptable answer
    translationStore.put(field: .narration, sourceText: prose, language: language, text: translated)
    return translated
  }

  /// A stored translation of `text`, or `text` itself. Never generates — the synchronous callers
  /// cannot await, and a missing translation must render as English rather than as nothing.
  private func displayText(_ text: String) -> String {
    let language = TranslationTarget.resolved()
    guard !language.isEmpty else { return text }
    return translationStore.translation(field: .narration, sourceText: text, language: language) ?? text
  }
```

- [ ] **Step 3: Switch DetailView's four narration reads**

In `Sources/PensieveApp/DetailView.swift`, inside the `.task`, replace each narration read with its display variant. There are four, and **all four must change** — the type's contract is that what is rendered, what ⌘G walks, and what Share exports are the same string:

- line ~120, the pre-generation `shareMarkdown` render: `model.cachedNarration(for: node, events: recentEvents)` → `model.cachedDisplayNarration(for: node, events: recentEvents)`
- line ~124, the cached fast path: `model.cachedNarration(...)` → `model.cachedDisplayNarration(...)`
- line ~130: `let prose = await model.narration(for: node, events: recentEvents, force: isRefresh)` → `let prose = await model.displayNarration(for: node, events: recentEvents, force: isRefresh)`
- lines ~131-135 already use `prose` for `lastWorkDone`, `resetFind(narration:)` and `shareMarkdown` — leave them, since `prose` is now the display string.

Do not introduce a second local. One value, four consumers, is the invariant.

- [ ] **Step 4: Build and smoke-launch**

Run the same commands as Task 9 Step 4.
Expected: builds clean, launches, no crash.

- [ ] **Step 5: Commit**

```bash
git add Sources/PensieveApp/AppModel.swift Sources/PensieveApp/AppModel+Narration.swift Sources/PensieveApp/DetailView.swift
git commit -m "feat(app): the narration renders, finds and shares as one display string"
```

---

### Task 11: The on-demand Translate action

**Files:**
- Create: `Sources/PensieveApp/AppModel+Translation.swift`
- Modify: `Sources/PensieveApp/DetailView.swift` (loose-end row context menu)
- Modify: `Sources/PensieveApp/Localizable.xcstrings`

**Interfaces:**
- Consumes: `TranslationStore`, `Translator`, `TranslationTarget`, `AppModel.syncSearchIndexes()`.
- Produces: `AppModel.translate(field:sourceText:) async`, `AppModel.displayed(field:sourceText:) -> String`.

- [ ] **Step 1: Write the action**

```swift
// Sources/PensieveApp/AppModel+Translation.swift
import Foundation
import PensieveKit

extension AppModel {
  /// Translate one generated field on demand, store it, and make it findable.
  ///
  /// The write lands in `translation-cache.sqlite`, NOT the canonical store, so it cannot trip the
  /// canonical `ValueObservation` — the same shape as slice 4's Node-only writes, which needed an
  /// explicit refresh. Reindexing is therefore explicit, and debounced: translating eight loose ends
  /// in a row must not cause eight whole-corpus rebuilds.
  func translate(field: TranslationField, sourceText: String) async {
    let language = TranslationTarget.resolved()
    guard !language.isEmpty, !sourceText.isEmpty, let translator else { return }
    guard translationStore.translation(field: field, sourceText: sourceText,
                                       language: language) == nil else { return }
    guard let translated = await translator.translate(sourceText,
                                                      from: TranslationTarget.sourceLanguage,
                                                      to: language) else { return }
    translationStore.put(field: field, sourceText: sourceText, language: language, text: translated)
    await translationDebouncer.schedule()
  }

  /// The stored translation of `sourceText`, or `sourceText` itself. Never generates.
  func displayed(field: TranslationField, sourceText: String) -> String {
    let language = TranslationTarget.resolved()
    guard !language.isEmpty else { return sourceText }
    return translationStore.translation(field: field, sourceText: sourceText,
                                        language: language) ?? sourceText
  }
}
```

Add the debouncer beside `translationStore` on `AppModel`. `Debouncer` takes its action at `init` and `schedule()` takes no arguments (`Sources/PensieveKit/Support/Debouncer.swift:15`, `:25`), so the reindex is baked in at construction — and `lazy` is what makes capturing `self` legal here:

```swift
  /// Trailing-edge: translating eight loose ends in a row must cause ONE whole-corpus rebuild, not
  /// eight. The same coalescer the liveness watches run through.
  @ObservationIgnored lazy var translationDebouncer = Debouncer(interval: 0.4) { [weak self] in
    await MainActor.run { self?.syncSearchIndexes() }
  }
```

- [ ] **Step 2: Add the context menu**

On the loose-end row inside `DetailView`, add to its existing `.contextMenu` (or add one if absent):

```swift
        if TranslationTarget.resolved() != TranslationTarget.off {
          Button(LocalizedStringKey("Translate")) {
            Task { await model.translate(field: .looseEndText, sourceText: view.looseEnd.text) }
          }
        }
```

Render the loose-end summary through `model.displayed(field: .looseEndText, sourceText:)` at its display site so the translation appears once stored. The cited quote below it is untouched — that is the honest pairing, and it is what keeps the citation checkable.

- [ ] **Step 3: Add the String Catalog key**

| Key | de |
|---|---|
| `Translate` | `Übersetzen` |

- [ ] **Step 4: Build and smoke-launch**

Run the same commands as Task 9 Step 4.
Expected: builds clean, launches, no crash.

- [ ] **Step 5: Commit**

```bash
git add Sources/PensieveApp/AppModel+Translation.swift Sources/PensieveApp/AppModel.swift Sources/PensieveApp/DetailView.swift Sources/PensieveApp/Localizable.xcstrings
git commit -m "feat(app): translate a loose-end summary on demand, then reindex"
```

---

### Task 12: The pre-registered verification gate

**Files:**
- Create: `docs/superpowers/measurements/2026-08-12-translation-ranking/README.md`
- Reuse: the probes and gold set at `docs/superpowers/measurements/2026-07-28-retrieval-recall/`

This task decides whether the design ships as built or falls back. Run it **before** merging, not after.

- [ ] **Step 1: Read the existing harness**

Run: `ls docs/superpowers/measurements/2026-07-28-retrieval-recall/ && cat docs/superpowers/measurements/2026-07-28-retrieval-recall/README.md`

Reuse its gold set and its P@1 computation verbatim. Do not write a second harness — a differently-computed baseline is not comparable to 0.395.

- [ ] **Step 2: Record the baseline on the current index**

Build the index with `language: TranslationTarget.off` and run the gold set. Confirm P@1 reproduces the committed **0.395**. If it does not, stop: the harness or the corpus has drifted, and nothing measured after this point is comparable.

- [ ] **Step 3: Bulk-translate the eval corpus**

Write a throwaway probe (Swift, in the measurements directory) that walks every node name, node description and open loose-end text, calls `SystemTranslator`, and writes the result into a **throwaway** `TranslationStore` — never the live `translation-cache.sqlite`. Point it at a copy of the corpus via `PENSIEVE_DB`.

This is the eager translation cost the product design avoids paying; here it is necessary, because a gate run against an empty German index measures nothing.

- [ ] **Step 4: Measure with the German index populated**

Rebuild the index with `language: "de"` against the populated translation store, then re-run the same gold set. Record P@1 and the paired per-query outcomes.

- [ ] **Step 5: Apply the decision rule**

Compute McNemar's test on the paired outcomes, n = 1500 as before.

- **P@1 not significantly worse at p < 0.05** → ship as built. Record the numbers in the new README.
- **Significantly worse** → ship the pre-specified fallback: a **separate FTS table per language** in `SearchIndexStore` (`documents_de` mirroring `documents`), queried in addition to `documents` and merged by the same `item_id` dedup Task 7 added. English ranking then becomes byte-identical *by construction* rather than by measurement, because no German row shares a table with an English one. This is the same fallback that shipped for `document_files`.

Do not reinterpret the rule after seeing the numbers. That is the entire point of pre-registering it.

- [ ] **Step 6: Commit the measurement**

```bash
git add docs/superpowers/measurements/2026-08-12-translation-ranking
git commit -m "measure: German documents' effect on English BM25 ranking"
```

---

## Self-Review

**Spec coverage.** Every spec section maps to a task: `TranslationStore` → 1; `Translator` seam and the macOS 26 floor → 2; target-as-setting and off-means-off → 3; extra-rows-not-columns and `language UNINDEXED` → 4 and 5; corpus producer with the quote excluded → 6; resolver dedup → 7; query backstop → 8; Settings and first-run pack → 9; narration automatic with one display string → 10; on-demand action with debounced reindex → 11; verification gate → 12. Trust gate is enforced by Task 1's type and asserted in Tasks 1 and 6. Degradation is covered by the `guard`s in 6, 8, 10 and 11 plus Task 3's tests.

**Two spec amendments this plan adds**, both from reading code: the `corpusHash` sort-stability bug (Task 4) and translated snippet candidates (Task 7). Both are latent defects the spec's design would otherwise have shipped. Fold them back into the spec when the branch merges.

**Deliberate omissions.** No bulk "translate all" action, no translated node-name context menu in Task 11 (the mechanism is there via `TranslationField.nodeName` and `displayed(field:sourceText:)`; adding the menu item is trivial once the loose-end path is proven, and doing both at once doubles the eyeball surface for one review). Events are never translated. MCP is untouched — `pensieve mcp` reads translations through `gather` automatically once the setting is on, and gains no new parameter.

**Type consistency.** `TranslationField` cases are `narration`/`looseEndText`/`nodeName`/`nodeDescription` in Tasks 1, 6, 7, 10, 11. `TranslationStore.translation(field:sourceText:language:)` and `.put(field:sourceText:language:text:)` keep those labels throughout. `EmbeddableItem.language` is the last defaulted parameter in Tasks 4, 5, 6. `TranslationTarget.off`/`.sourceLanguage`/`.resolved(defaults:)` are used consistently. `SearchQueries.search` gains `translations:` and `language:` before the unlabeled database argument in both Task 7 and Task 8.

## Human-verify carries

Need the built app at `/Applications`, a real store, and a plain `open` — not the smoke launch:

- A German narration renders as one atomic spinner → German transition, with no English flicker.
- ⌘F inside a node finds a phrase in the **translated** narration, and ⌘G walks it in on-screen order.
- Share/copy exports the German the pane is showing.
- Translate on a loose end: the summary switches to German, the cited quote below it stays English, and the loose end then becomes findable by a German phrase via ⌥⌘F.
- Settings ▸ Intelligence: switching the target Off removes German everywhere on next open, and no new `translation-cache.sqlite` appears when the target was never set.
- `pensieve list` and `pensieve mcp search` still return English node names.
- German in-situ tone pass on the six new Settings strings.
