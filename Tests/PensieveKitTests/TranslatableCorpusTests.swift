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
    let source = Source(nodeID: node.id, kind: SourceKind.claudeCode, key: "/src/\(UUID().uuidString)")
    let event = Event(nodeID: node.id, sourceID: source.id, occurredAt: Date(),
                      kind: CaptureKind.ccSession, summary: "s", detailJSON: "{}")
    let looseEnd = LooseEnd(nodeID: node.id, sourceEventID: event.id, text: "Reinstall the agent",
                            quote: "we should reinstall the agent")
    try await database.write { database in
      try Node.insert { node }.execute(database)
      try Source.insert { source }.execute(database)
      try Event.insert { event }.execute(database)
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
    let source = Source(nodeID: active.id, kind: SourceKind.claudeCode, key: "/src/\(UUID().uuidString)")
    let event = Event(nodeID: active.id, sourceID: source.id, occurredAt: Date(),
                      kind: CaptureKind.ccSession, summary: "s", detailJSON: "{}")
    let looseEnd = LooseEnd(nodeID: active.id, sourceEventID: event.id, text: "A real end",
                            quote: "the verbatim quote")
    let noise = LooseEnd(nodeID: active.id, sourceEventID: event.id, text: "Not an end",
                         quote: "q", label: LooseEndLabel.noise)
    try await database.write { database in
      try Node.insert { muted }.execute(database)
      try Node.insert { active }.execute(database)
      try Source.insert { source }.execute(database)
      try Event.insert { event }.execute(database)
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
