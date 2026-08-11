import Testing
import Foundation
@testable import PensieveKit

@Suite struct SearchIndexStoreTests {
  private func item(_ itemID: String, _ text: String, files: String = "",
                    kind: String = "event", nodeID: String = "n1",
                    state: String = "active") -> EmbeddableItem {
    EmbeddableItem(itemID: itemID, kind: kind, nodeID: nodeID, state: state,
                   text: text, files: files)
  }

  @Test func freshStoreIsAvailableAndAbsent() {
    let store = tempSearchStore()
    #expect(store.isAvailable)
    #expect(store.state() == .absent)
    #expect(store.storedCorpusHash() == nil)
  }

  @Test func rebuildMakesItReadyAndSearchable() {
    let store = tempSearchStore()
    store.rebuild(items: [item("a", "background sync agent login items")], corpusHash: "h1")
    #expect(store.state() == .ready)
    #expect(store.storedCorpusHash() == "h1")
    let query = FTSQueryBuilder.build("background sync ")!
    #expect(store.search(query, limit: 10, includeArchived: false).map(\.itemID) == ["a"])
  }

  @Test func rebuildIsIdempotentAndReplacesRatherThanAppends() {
    let store = tempSearchStore()
    store.rebuild(items: [item("a", "alpha")], corpusHash: "h1")
    store.rebuild(items: [item("a", "alpha")], corpusHash: "h1")
    let query = FTSQueryBuilder.build("alpha ")!
    #expect(store.search(query, limit: 10, includeArchived: false).count == 1)

    store.rebuild(items: [item("b", "beta")], corpusHash: "h2")
    #expect(store.search(query, limit: 10, includeArchived: false).isEmpty)
    #expect(store.storedCorpusHash() == "h2")
  }

  /// Pins the merge order: everything the TEXT index found comes first, then rows only the path
  /// index found. This is structural, not a scoring accident — the two bm25 scores come from
  /// different tables with different average document lengths and are never comparable, so a
  /// path-only hit can no longer outrank a real text match by arithmetic coincidence.
  @Test func textMatchesComeBeforePathOnlyMatches() {
    let store = tempSearchStore()
    store.rebuild(items: [item("text-match", "refactor the parser today"),
                          item("files-match", "unrelated commit subject",
                               files: "Sources/parser/Lexer.swift")],
                  corpusHash: "h")
    let hits = store.search(FTSQueryBuilder.build("parser ")!, limit: 10, includeArchived: false)
    #expect(hits.map(\.itemID) == ["text-match", "files-match"])
  }

  /// The reason the tables are split at all: a path must not lengthen the text row and discount its
  /// text matches. Two identical texts, one carrying a long path — they must score identically.
  @Test func pathsDoNotDiscountTheTextTheyAccompany() {
    let store = tempSearchStore()
    store.rebuild(items: [item("bare", "refactor the parser today"),
                          item("pathful", "refactor the parser today",
                               files: "Sources/PensieveKit/Search/SearchIndexStore.swift\n"
                                    + "Sources/PensieveKit/Search/FTSQuery.swift")],
                  corpusHash: "h")
    let hits = store.search(FTSQueryBuilder.build("parser ")!, limit: 10, includeArchived: false)
    #expect(hits.count == 2)
    #expect(hits[0].score == hits[1].score)
  }

  @Test func archivedIsExcludedByDefaultAndIncludedOnRequest() {
    let store = tempSearchStore()
    store.rebuild(items: [item("live", "shared phrase", nodeID: "n1", state: "active"),
                          item("old", "shared phrase", nodeID: "n2", state: "archived"),
                          item("hidden", "shared phrase", nodeID: "n3", state: "muted")],
                  corpusHash: "h")
    let query = FTSQueryBuilder.build("shared ")!
    #expect(store.search(query, limit: 10, includeArchived: false).map(\.itemID) == ["live"])
    let widened = Set(store.search(query, limit: 10, includeArchived: true).map(\.itemID))
    #expect(widened == ["live", "old"])   // muted is excluded in BOTH modes — allow-list, never deny-list
  }

  @Test func pathsAreSearchableByPathSegment() {
    let store = tempSearchStore()
    store.rebuild(items: [item("a", "unrelated subject", files: "Sources/PensieveKit/Sync/SyncRunner.swift")],
                  corpusHash: "h")
    // Bare term: found via the opportunistic path probe, even though the text says nothing of it.
    #expect(store.search(FTSQueryBuilder.build("syncrunner ")!, limit: 10,
                         includeArchived: false).map(\.itemID) == ["a"])
    // Explicit directive: found via the path restriction.
    #expect(store.search(FTSQueryBuilder.build("files:syncrunner ")!, limit: 10,
                         includeArchived: false).map(\.itemID) == ["a"])
  }

  /// A structured `file:` parameter RESTRICTS — it is an AND across the two tables (a join), not a
  /// second list merged in. "work about the parser that touched Lexer.swift" must not also return
  /// work about the parser that touched something else.
  @Test func structuredFileParameterRestrictsRatherThanWidens() {
    let store = tempSearchStore()
    store.rebuild(items: [item("both", "refactor the parser", files: "Sources/parser/Lexer.swift"),
                          item("text-only", "refactor the parser", files: "Sources/other/Thing.swift"),
                          item("path-only", "unrelated subject", files: "Sources/parser/Lexer.swift")],
                  corpusHash: "h")
    let query = FTSQueryBuilder.build("parser ", file: "Lexer.swift")!
    #expect(store.search(query, limit: 10, includeArchived: false).map(\.itemID) == ["both"])
  }

  /// The path index must honour the same state allow-list the text index does — otherwise a bare
  /// filename would surface archived or muted work the text path correctly hides.
  @Test func pathProbeHonoursTheStateAllowList() {
    let store = tempSearchStore()
    store.rebuild(items: [item("live", "unrelated", files: "Sources/Shared.swift", nodeID: "n1", state: "active"),
                          item("old", "unrelated", files: "Sources/Shared.swift", nodeID: "n2", state: "archived"),
                          item("hidden", "unrelated", files: "Sources/Shared.swift", nodeID: "n3", state: "muted")],
                  corpusHash: "h")
    let query = FTSQueryBuilder.build("shared ")!
    #expect(store.search(query, limit: 10, includeArchived: false).map(\.itemID) == ["live"])
    #expect(Set(store.search(query, limit: 10, includeArchived: true).map(\.itemID)) == ["live", "old"])
  }

  @Test func diacriticsAreFoldedBothWays() {
    let store = tempSearchStore()
    store.rebuild(items: [item("a", "Lösung für Umlaute")], corpusHash: "h")
    #expect(store.search(FTSQueryBuilder.build("losung ")!, limit: 10,
                         includeArchived: false).map(\.itemID) == ["a"])
    #expect(store.search(FTSQueryBuilder.build("Lösung ")!, limit: 10,
                         includeArchived: false).map(\.itemID) == ["a"])
  }

  @Test func hostileInputReturnsEmptyRatherThanThrowing() {
    let store = tempSearchStore()
    store.rebuild(items: [item("a", "ordinary text")], corpusHash: "h")
    for raw in ["don't ", "C++ ", "a:b ", "\"unbalanced", "* ", "+++ "] {
      guard let query = FTSQueryBuilder.build(raw) else { continue }
      #expect(store.search(query, limit: 10, includeArchived: false).isEmpty)
    }
  }

  @Test func limitCapsResults() {
    let store = tempSearchStore()
    let items = (0..<20).map { item("i\($0)", "common word \($0)") }
    store.rebuild(items: items, corpusHash: "h")
    #expect(store.search(FTSQueryBuilder.build("common ")!, limit: 5,
                         includeArchived: false).count == 5)
  }
}
