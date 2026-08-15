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

  @Test func partialCoverageCounts() {
    let store = TranslationStore(url: tempURL("coverage-partial"))
    store.put(field: .nodeName, sourceText: "Background sync", language: "de", text: "Hintergrund")
    store.put(field: .looseEndText, sourceText: "Check the log", language: "de", text: "Log prüfen")

    let coverage = TranslationCoverage.measure(units: units(), store: store, language: "de")
    #expect(coverage.translated == 2)
    #expect(coverage.total == 4)
    // `translated` is derived from `missing`, so the two can never contradict each other.
    #expect(coverage.translated == coverage.total - coverage.missing.count)
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

  /// The measurement carries the language it was made FOR. Load-bearing, not decoration: the backfill
  /// refuses a coverage whose language is not the current target, which is what stops a run started
  /// after a language switch from translating language A's missing list into language B.
  @Test func coverageCarriesTheLanguageItWasMeasuredFor() {
    let store = TranslationStore(url: tempURL("coverage-language-tag"))
    #expect(TranslationCoverage.measure(units: units(), store: store, language: "de").language == "de")
    #expect(TranslationCoverage.measure(units: units(), store: store, language: "fr").language == "fr")
  }
}
