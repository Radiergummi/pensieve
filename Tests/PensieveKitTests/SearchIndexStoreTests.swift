import Testing
import Foundation
@testable import PensieveKit

@Suite struct SearchIndexStoreTests {
  private func tempStore() -> SearchIndexStore {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("search-\(UUID().uuidString).sqlite")
    return SearchIndexStore(url: url)
  }

  private func item(_ itemID: String, _ text: String, files: String = "",
                    kind: String = "event", nodeID: String = "n1",
                    state: String = "active") -> EmbeddableItem {
    EmbeddableItem(itemID: itemID, kind: kind, nodeID: nodeID, state: state,
                   text: text, files: files)
  }

  @Test func freshStoreIsAvailableAndAbsent() {
    let store = tempStore()
    #expect(store.isAvailable)
    #expect(store.state() == .absent)
    #expect(store.storedCorpusHash() == nil)
  }

  @Test func rebuildMakesItReadyAndSearchable() {
    let store = tempStore()
    store.rebuild(items: [item("a", "background sync agent login items")], corpusHash: "h1")
    #expect(store.state() == .ready)
    #expect(store.storedCorpusHash() == "h1")
    let query = FTSQueryBuilder.build("background sync ")!
    #expect(store.search(query, limit: 10, includeArchived: false).map(\.itemID) == ["a"])
  }

  @Test func rebuildIsIdempotentAndReplacesRatherThanAppends() {
    let store = tempStore()
    store.rebuild(items: [item("a", "alpha")], corpusHash: "h1")
    store.rebuild(items: [item("a", "alpha")], corpusHash: "h1")
    let query = FTSQueryBuilder.build("alpha ")!
    #expect(store.search(query, limit: 10, includeArchived: false).count == 1)

    store.rebuild(items: [item("b", "beta")], corpusHash: "h2")
    #expect(store.search(query, limit: 10, includeArchived: false).isEmpty)
    #expect(store.storedCorpusHash() == "h2")
  }

  /// Pins the 0.1 `files` weight: a term matching in `text` must outrank the same term matching
  /// only in `files`. Measured on SQLite 3.51.0: 1.13e-06 vs 1.42e-07.
  @Test func textMatchOutranksFilesOnlyMatch() {
    let store = tempStore()
    store.rebuild(items: [item("text-match", "refactor the parser today"),
                          item("files-match", "unrelated commit subject",
                               files: "Sources/parser/Lexer.swift")],
                  corpusHash: "h")
    let hits = store.search(FTSQueryBuilder.build("parser ")!, limit: 10, includeArchived: false)
    #expect(hits.map(\.itemID) == ["text-match", "files-match"])
    #expect(hits[0].score > hits[1].score)
    // Pins the WEIGHT, not just the ordering: ordering survives uniform weighting, the gap does
    // not. Measured ~7.9x at weight 0.1 vs ~1.25x at 1.0, so this threshold separates them
    // decisively without being brittle about the exact bm25 arithmetic.
    #expect(hits[0].score / hits[1].score > 3)
  }

  @Test func archivedIsExcludedByDefaultAndIncludedOnRequest() {
    let store = tempStore()
    store.rebuild(items: [item("live", "shared phrase", nodeID: "n1", state: "active"),
                          item("old", "shared phrase", nodeID: "n2", state: "archived"),
                          item("hidden", "shared phrase", nodeID: "n3", state: "muted")],
                  corpusHash: "h")
    let query = FTSQueryBuilder.build("shared ")!
    #expect(store.search(query, limit: 10, includeArchived: false).map(\.itemID) == ["live"])
    let widened = Set(store.search(query, limit: 10, includeArchived: true).map(\.itemID))
    #expect(widened == ["live", "old"])   // muted is excluded in BOTH modes — allow-list, never deny-list
  }

  @Test func filesColumnIsSearchableByPathSegment() {
    let store = tempStore()
    store.rebuild(items: [item("a", "unrelated subject", files: "Sources/PensieveKit/Sync/SyncRunner.swift")],
                  corpusHash: "h")
    #expect(store.search(FTSQueryBuilder.build("syncrunner ")!, limit: 10,
                         includeArchived: false).map(\.itemID) == ["a"])
    #expect(store.search(FTSQueryBuilder.build("files:syncrunner ")!, limit: 10,
                         includeArchived: false).map(\.itemID) == ["a"])
  }

  @Test func diacriticsAreFoldedBothWays() {
    let store = tempStore()
    store.rebuild(items: [item("a", "Lösung für Umlaute")], corpusHash: "h")
    #expect(store.search(FTSQueryBuilder.build("losung ")!, limit: 10,
                         includeArchived: false).map(\.itemID) == ["a"])
    #expect(store.search(FTSQueryBuilder.build("Lösung ")!, limit: 10,
                         includeArchived: false).map(\.itemID) == ["a"])
  }

  @Test func hostileInputReturnsEmptyRatherThanThrowing() {
    let store = tempStore()
    store.rebuild(items: [item("a", "ordinary text")], corpusHash: "h")
    for raw in ["don't ", "C++ ", "a:b ", "\"unbalanced", "* ", "+++ "] {
      guard let query = FTSQueryBuilder.build(raw) else { continue }
      #expect(store.search(query, limit: 10, includeArchived: false).isEmpty)
    }
  }

  @Test func limitCapsResults() {
    let store = tempStore()
    let items = (0..<20).map { item("i\($0)", "common word \($0)") }
    store.rebuild(items: items, corpusHash: "h")
    #expect(store.search(FTSQueryBuilder.build("common ")!, limit: 5,
                         includeArchived: false).count == 5)
  }
}
