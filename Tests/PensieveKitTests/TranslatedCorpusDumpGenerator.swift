import Foundation
import Testing
import SQLiteData
#if canImport(Translation)
import Translation
#endif
@testable import PensieveKit

/// NOT a test — Task 12's bulk-translation companion to `dumpCorpusForMeasurement`. Produces the
/// TREATED corpus arm (`corpus_de.jsonl`) for the pre-registered ranking gate
/// (`.superpowers/sdd/2026-08-12-on-device-translation/task-12-brief.md`) by calling the real
/// `SystemTranslator` + `TranslationStore` + `EmbeddableCorpus.gather(translations:language:)` exactly
/// as production would, then writing the translated JSONL extract beside the baseline one.
///
/// No-ops unless BOTH `PENSIEVE_MEASURE_DIR` and `PENSIEVE_MEASURE_DB` are set (same env vars as
/// `dumpCorpusForMeasurement`), AND the machine is macOS 26+ with the en→de language pack installed —
/// otherwise it prints why and returns rather than writing a mostly-untranslated corpus and calling it
/// a treated arm.
///
/// Usage:
///   PENSIEVE_MEASURE_DIR=/scratch PENSIEVE_MEASURE_DB=/scratch/snapshot.sqlite \
///     ./scripts/test.sh --filter dumpTranslatedCorpusForMeasurement
///
/// Writes `translations.sqlite` (a throwaway `TranslationStore`, inside `PENSIEVE_MEASURE_DIR`) and
/// `corpus_de.jsonl` (the treated corpus arm). Both are real captured/generated work text — delete
/// them when the measurement run is done, same as `corpus.jsonl`.
@Test func dumpTranslatedCorpusForMeasurement() async throws {
  let environment = ProcessInfo.processInfo.environment
  guard let directory = environment["PENSIEVE_MEASURE_DIR"],
        let snapshotPath = environment["PENSIEVE_MEASURE_DB"] else { return }
  guard #available(macOS 26, *) else {
    print("dumpTranslatedCorpusForMeasurement: skipped — needs macOS 26+")
    return
  }
  let sourceLanguage = Locale.Language(identifier: "en")
  let targetLanguage = Locale.Language(identifier: "de")
  let availability = await LanguageAvailability().status(from: sourceLanguage, to: targetLanguage)
  guard availability == .installed else {
    print("dumpTranslatedCorpusForMeasurement: skipped — en→de language pack not installed (\(availability))")
    return
  }

  let database = try openCanonicalDatabase(at: URL(fileURLWithPath: snapshotPath))
  let translationStoreURL = URL(fileURLWithPath: directory).appendingPathComponent("translations.sqlite")
  let translations = TranslationStore(url: translationStoreURL)
  #expect(translations.isAvailable)
  let translator = SystemTranslator()
  var tally = TranslationTally()

  // Mirrors gather's own eligibility exactly: nodes it embeds are active-or-archived, and loose ends
  // it embeds are open AND under such a node. Translating anything gather would never look up would
  // just be wasted API calls, not a different corpus.
  let allNodes = try await database.read { database in try Node.all.fetchAll(database) }
  let eligibleNodes = allNodes.filter { $0.state == .active || $0.state == .archived }
  let eligibleNodeIDs = Set(eligibleNodes.map(\.id))
  let openLooseEnds = try await database.read { database in
    try LooseEnd.where { LooseEnd.isOpen($0) }.fetchAll(database)
  }.filter { eligibleNodeIDs.contains($0.nodeID) }

  let nodesWithDescription = eligibleNodes.filter { !$0.description.isEmpty }
  for (index, node) in eligibleNodes.enumerated() {
    await tally.translate(node.name, field: .nodeName, using: translator, into: translations)
    if !node.description.isEmpty {
      await tally.translate(node.description, field: .nodeDescription, using: translator, into: translations)
    }
    if index % 50 == 0 { print("  nodes \(index)/\(eligibleNodes.count)") }
  }
  for (index, looseEnd) in openLooseEnds.enumerated() {
    await tally.translate(looseEnd.text, field: .looseEndText, using: translator, into: translations)
    if index % 100 == 0 { print("  loose ends \(index)/\(openLooseEnds.count)") }
  }
  print("translation: \(tally.translated) newly translated, \(tally.alreadyPresent) already present, "
       + "\(tally.skippedNil) nil/skipped, out of "
       + "\(tally.translated + tally.alreadyPresent + tally.skippedNil) attempted "
       + "(\(eligibleNodes.count) node names, \(nodesWithDescription.count) node descriptions, "
       + "\(openLooseEnds.count) open loose ends)")

  let corpus = try EmbeddableCorpus.gather(database, translations: translations, language: "de")
  try writeTranslatedCorpus(corpus, to: URL(fileURLWithPath: directory).appendingPathComponent("corpus_de.jsonl"))
}

/// Writes one JSONL line per item (same shape as `dumpCorpusForMeasurement`, plus `language`) and
/// prints the composition table `tprobe.swift`'s README compares against. Split out purely to keep
/// `dumpTranslatedCorpusForMeasurement` under SwiftLint's function-body-length cap.
private func writeTranslatedCorpus(_ corpus: [EmbeddableItem], to destination: URL) throws {
  var lines: [String] = []
  let encoder = JSONEncoder()
  encoder.outputFormatting = .sortedKeys
  for item in corpus {
    let record = ["kind": item.kind, "itemID": item.itemID, "nodeID": item.nodeID,
                  "state": item.state, "text": item.text, "files": item.files, "language": item.language]
    lines.append(String(data: try encoder.encode(record), encoding: .utf8) ?? "")
  }
  try lines.joined(separator: "\n").write(to: destination, atomically: true, encoding: .utf8)

  var kindCounts: [String: Int] = [:]
  var languageCounts: [String: Int] = [:]
  for item in corpus {
    kindCounts[item.kind, default: 0] += 1
    languageCounts[item.language, default: 0] += 1
  }
  print("corpus_de.jsonl written: \(corpus.count) items kinds=\(kindCounts.sorted { $0.key < $1.key }) "
       + "languages=\(languageCounts.sorted { $0.key < $1.key })")
}

/// A running count of translate/put attempts, kept as a tiny struct rather than inout Int pairs so
/// each call site above reads as one line. Throwaway measurement infra; not meant to be reused.
///
/// Check-then-skip on `TranslationStore.translation` before calling the translator: the store is
/// keyed by `(field, source-text hash, language)`, so a source text already translated is a cheap
/// point lookup — this makes re-running the whole pass after an interrupted run pay only for what is
/// still missing, rather than re-translating everything from scratch.
@available(macOS 26, *)
private struct TranslationTally {
  var translated = 0
  var alreadyPresent = 0
  var skippedNil = 0

  mutating func translate(_ sourceText: String, field: TranslationField, using translator: SystemTranslator,
                          into translations: TranslationStore) async {
    if translations.translation(field: field, sourceText: sourceText, language: "de") != nil {
      alreadyPresent += 1
      return
    }
    guard let translated = await translator.translate(sourceText, from: "en", to: "de") else {
      skippedNil += 1
      return
    }
    translations.put(field: field, sourceText: sourceText, language: "de", text: translated)
    self.translated += 1
  }
}
