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

  /// Asserts POSITIVE hits, not just "no crash". `search` cannot throw — `fetch` degrades a hard
  /// SQLite error to `[]` — so an all-`isEmpty` version of this test passed identically whether the
  /// operator characters were neutralised or blew the MATCH expression apart, which made the one test
  /// named for the injection surface unable to see a regression in it.
  @Test func hostileInputIsMatchedLiterallyRatherThanAsOperators() throws {
    let store = tempSearchStore()
    store.rebuild(items: [item("a", "don't C++ a:b ordinary text")], corpusHash: "h")
    for raw in ["don't ", "C++ ", "a:b "] {
      let query = try #require(FTSQueryBuilder.build(raw))
      #expect(store.search(query, limit: 10, includeArchived: false).map(\.itemID) == ["a"],
              "\(raw) should match the document containing it literally")
    }
    // Pure-operator input tokenizes to nothing, so it matches nothing — but must not error, and must
    // not leave the index unusable for the next real query.
    for raw in ["\"unbalanced", "* ", "+++ "] {
      guard let query = FTSQueryBuilder.build(raw) else { continue }
      _ = store.search(query, limit: 10, includeArchived: false)
    }
    let stillWorks = try #require(FTSQueryBuilder.build("ordinary "))
    #expect(store.search(stillWorks, limit: 10, includeArchived: false).map(\.itemID) == ["a"])
  }

  /// Finding 1.15. The tokenizer spec was written out once per `CREATE VIRTUAL TABLE`; only
  /// `documents` was covered by a test (`diacriticsAreFoldedBothWays`), so a change to one table's
  /// spelling could leave the other two behind unnoticed. All three tables must fold diacritics —
  /// which is also the property `FindMatcher.options` is coupled to.
  @Test func allThreeTablesShareTheTokenizer() throws {
    let store = tempSearchStore()
    // `documents` (text) and `document_files` (paths) live in the same rebuild.
    store.rebuild(items: [item("text", "Lösung für Umlaute"),
                          item("path", "unrelated subject", files: "Sources/Lösung/Übersicht.swift")],
                  corpusHash: "h")
    store.rebuildPassages(items: [item("passage", "die Lösung war einfach")], passagesHash: "p")

    let folded = try #require(FTSQueryBuilder.build("losung "))
    let accented = try #require(FTSQueryBuilder.build("Lösung "))
    // documents + document_files: the merged text-then-path list, both spellings.
    #expect(Set(store.search(folded, limit: 10, includeArchived: false).map(\.itemID)) == ["text", "path"])
    #expect(Set(store.search(accented, limit: 10, includeArchived: false).map(\.itemID)) == ["text", "path"])
    // document_passages, its own table and its own query path.
    #expect(store.searchPassages(folded, limit: 10, includeArchived: false).map(\.itemID) == ["passage"])
    #expect(store.searchPassages(accented, limit: 10, includeArchived: false).map(\.itemID) == ["passage"])
  }

  /// Finding 2.34. The delete-and-retry must clear the whole index — a WAL-mode SQLite database is
  /// three files, the same enumeration `StoreRelocator.canonicalStoreFileNames` makes for the
  /// canonical store. Asserted on the removal itself rather than end to end: SQLite validates a WAL
  /// header against its database and discards a mismatched one, so an orphaned sidecar could not be
  /// made to change the retry's outcome (see `removeIndexFiles`).
  @Test func deleteAndRetryClearsTheWalAndShmSiblingsToo() throws {
    let url = tempURL("stale-sidecar-index")
    let sidecars = [url.path + "-wal", url.path + "-shm"]
    try Data("this is not a sqlite database at all".utf8).write(to: url)
    for path in sidecars { try Data("STALE".utf8).write(to: URL(fileURLWithPath: path)) }

    SearchIndexStore.removeIndexFiles(at: url)
    #expect(!FileManager.default.fileExists(atPath: url.path))
    for path in sidecars {
      #expect(!FileManager.default.fileExists(atPath: path), "\(path) survived the delete")
    }

    // And the corrupt file is still recovered into a usable, freshly-built index.
    let store = SearchIndexStore(url: url)
    #expect(store.isAvailable)
    #expect(store.state() == .absent)
  }

  @Test func limitCapsResults() {
    let store = tempSearchStore()
    let items = (0..<20).map { item("i\($0)", "common word \($0)") }
    store.rebuild(items: items, corpusHash: "h")
    #expect(store.search(FTSQueryBuilder.build("common ")!, limit: 5,
                         includeArchived: false).count == 5)
  }
}
