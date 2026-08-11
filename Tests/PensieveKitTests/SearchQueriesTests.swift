import Foundation
import Testing
import SQLiteData
@testable import PensieveKit

@Suite struct SearchQueriesTests {
  private func indexed(_ database: any DatabaseWriter) -> SearchIndexStore {
    let store = tempSearchStore()
    SearchIndexer(store: store).sync(database)
    return store
  }

  private func makeEvent(_ database: any DatabaseWriter, node: Node, summary: String,
                         files: String = "") throws -> Event {
    let source = Source(nodeID: node.id, kind: SourceKind.gitRepo, key: "/p/\(node.id)-\(UUID())")
    let detail = files.isEmpty ? "{}"
      : String(data: try JSONSerialization.data(withJSONObject: ["files": files]), encoding: .utf8)!
    let event = Event(nodeID: node.id, sourceID: source.id, occurredAt: Date(),
                      kind: CaptureKind.gitCommit, summary: summary, detailJSON: detail,
                      fingerprint: UUID().uuidString)
    try database.write { database in
      try Source.insert { source }.execute(database)
      try Event.insert { event }.execute(database)
    }
    return event
  }

  /// Over a corpus that WOULD match, and with the node visible — the previous version searched an
  /// empty database with an empty visible set, so deleting the guard entirely left it green.
  @Test func shortCircuitsBelowMinLength() async throws {
    let database = try openCanonicalDatabase(at: tempURL("searchq-short"))
    let node = Node(name: "Alpha", kind: NodeKind.project)
    try await database.write { database in try Node.insert { node }.execute(database) }
    let store = indexed(database)
    let scope = SearchScope(visibleNodeIDs: [node.id])
    #expect(SearchQueries.search(query: "A", scope: scope, store: store, database).isEmpty)
    // The same corpus and the same prefix, one character longer: proves the emptiness above came
    // from the length guard and not from the query failing to match anything.
    #expect(!SearchQueries.search(query: "Al", scope: scope, store: store, database).isEmpty)
  }

  /// A path directive typed INTO the query string, rather than passed as the structured `file`
  /// parameter — the only route into `.textRestrictedByPath` that had no test.
  @Test func rawFilesDirectiveCombinedWithTextRestrictsToBoth() async throws {
    let database = try openCanonicalDatabase(at: tempURL("searchq-rawfiles"))
    let node = Node(name: "Retrieval", kind: NodeKind.project)
    try await database.write { database in try Node.insert { node }.execute(database) }
    let wanted = try makeEvent(database, node: node, summary: "refactor the tokenizer",
                               files: "Sources/Lexer.swift")
    _ = try makeEvent(database, node: node, summary: "refactor the resolver",
                      files: "Sources/Other.swift")
    _ = try makeEvent(database, node: node, summary: "unrelated work", files: "Sources/Lexer.swift")
    let store = indexed(database)
    let hits = SearchQueries.search(query: "refactor tokenizer files:Lexer.swift ",
                                    scope: SearchScope(visibleNodeIDs: [node.id]), store: store,
                                    database)
    #expect(hits.map(\.id) == [wanted.id])
  }

  /// The matched field drives the snippet: a loose end whose query terms appear only in its cited
  /// quote must still show WHY it is in the results. Highlighting `text` alone returned a correct hit
  /// with an empty highlight, which in the UI is a row with no visible reason for being there.
  @Test func aQuoteOnlyMatchIsHighlightedInTheQuote() async throws {
    let database = try openCanonicalDatabase(at: tempURL("searchq-quotefield"))
    let node = Node(name: "Retrieval", kind: NodeKind.project)
    try await database.write { database in try Node.insert { node }.execute(database) }
    let event = try makeEvent(database, node: node, summary: "groundwork")
    let looseEnd = LooseEnd(nodeID: node.id, sourceEventID: event.id,
                            text: "Decide the ranking approach",
                            quote: "we should try sqlite-vec for this")
    try await database.write { database in try LooseEnd.insert { looseEnd }.execute(database) }
    let store = indexed(database)
    let hits = SearchQueries.search(query: "sqlite-vec ", scope: SearchScope(visibleNodeIDs: [node.id]),
                                    store: store, database)
    #expect(hits.map(\.id) == [looseEnd.id])
    #expect(hits.first?.snippet.match.lowercased() == "sqlite-vec")
  }

  @Test func findsANodeByName() async throws {
    let database = try openCanonicalDatabase(at: tempURL("searchq-node"))
    let node = Node(name: "Background sync agent", kind: NodeKind.project)
    try await database.write { database in try Node.insert { node }.execute(database) }
    let store = indexed(database)
    let hits = SearchQueries.search(query: "background sync ",
                                    scope: SearchScope(visibleNodeIDs: [node.id]),
                                    store: store, database)
    #expect(hits.map(\.id) == [node.id])
    #expect(hits[0].kind == .node)
    #expect((hits[0].score ?? 0) > 0)
  }

  @Test func findsAnEventTheOldSubstringMatcherCouldNotSee() async throws {
    let database = try openCanonicalDatabase(at: tempURL("searchq-event"))
    let node = Node(name: "Pensieve", kind: NodeKind.project)
    try await database.write { database in try Node.insert { node }.execute(database) }
    let event = try makeEvent(database, node: node, summary: "wire the focus filter intent")
    let store = indexed(database)
    // Multi-word, non-contiguous: the substring matcher returned nothing for this.
    let hits = SearchQueries.search(query: "focus intent ",
                                    scope: SearchScope(visibleNodeIDs: [node.id]),
                                    store: store, database)
    #expect(hits.contains { $0.id == event.id })
  }

  @Test func findsWorkByTheFilesItTouched() async throws {
    let database = try openCanonicalDatabase(at: tempURL("searchq-files"))
    let node = Node(name: "Pensieve", kind: NodeKind.project)
    try await database.write { database in try Node.insert { node }.execute(database) }
    let event = try makeEvent(database, node: node, summary: "unrelated subject",
                              files: "Sources/PensieveKit/Query/SemanticQueries.swift")
    let store = indexed(database)
    let bare = SearchQueries.search(query: "semanticqueries ",
                                    scope: SearchScope(visibleNodeIDs: [node.id]),
                                    store: store, database)
    #expect(bare.contains { $0.id == event.id })
    let structured = SearchQueries.search(query: "", file: "SemanticQueries.swift",
                                          scope: SearchScope(visibleNodeIDs: [node.id]),
                                          store: store, database)
    #expect(structured.contains { $0.id == event.id })
  }

  @Test func focusMutedNodesAreNeverReturned() async throws {
    let database = try openCanonicalDatabase(at: tempURL("searchq-mute"))
    let visible = Node(name: "Visible refunds work", kind: NodeKind.project)
    let muted = Node(name: "Muted refunds work", kind: NodeKind.project, context: "personal")
    try await database.write { database in
      try Node.insert { visible }.execute(database)
      try Node.insert { muted }.execute(database)
    }
    let store = indexed(database)
    let hits = SearchQueries.search(query: "refunds ",
                                    scope: SearchScope(visibleNodeIDs: [visible.id]),
                                    store: store, database)
    #expect(hits.map(\.nodeID) == [visible.id])
  }

  @Test func archivedIsExcludedByDefaultAndIncludedOnRequest() async throws {
    let database = try openCanonicalDatabase(at: tempURL("searchq-arch"))
    let live = Node(name: "Alpha refunds", kind: NodeKind.project)
    let old = Node(name: "Beta refunds", state: .archived, kind: NodeKind.project)
    try await database.write { database in
      try Node.insert { live }.execute(database)
      try Node.insert { old }.execute(database)
    }
    let store = indexed(database)
    let visible: Set<UUID> = [live.id, old.id]
    #expect(SearchQueries.search(query: "refunds ", scope: SearchScope(visibleNodeIDs: visible),
                                 store: store, database).map(\.nodeID) == [live.id])
    let widened = SearchQueries.search(
      query: "refunds ", scope: SearchScope(visibleNodeIDs: visible, includeArchived: true),
      store: store, database)
    #expect(Set(widened.map(\.nodeID)) == visible)
    #expect(widened.first { $0.nodeID == old.id }?.isArchived == true)
    #expect(widened.first { $0.nodeID == live.id }?.isArchived == false)
  }

  @Test func excludingIDsAreDropped() async throws {
    let database = try openCanonicalDatabase(at: tempURL("searchq-exclude"))
    let node = Node(name: "Refunds work", kind: NodeKind.project)
    try await database.write { database in try Node.insert { node }.execute(database) }
    let store = indexed(database)
    let hits = SearchQueries.search(
      query: "refunds ", scope: SearchScope(visibleNodeIDs: [node.id], excludingIDs: [node.id]),
      store: store, database)
    #expect(hits.isEmpty)
  }

  /// The last grounding defense: an index row whose canonical row is gone must never surface.
  @Test func staleIndexRowsAreDroppedByTheCanonicalReResolve() async throws {
    let database = try openCanonicalDatabase(at: tempURL("searchq-stale"))
    let node = Node(name: "Doomed refunds project", kind: NodeKind.project)
    try await database.write { database in try Node.insert { node }.execute(database) }
    let store = indexed(database)                       // index knows about it…
    try await database.write { database in              // …canonical no longer does
      try Node.delete().where { $0.id.eq(node.id) }.execute(database)
    }
    let hits = SearchQueries.search(query: "refunds ",
                                    scope: SearchScope(visibleNodeIDs: [node.id]),
                                    store: store, database)
    #expect(hits.isEmpty)
  }

  /// The same defense on the STATE axis, which the delete case above cannot reach: the canonical
  /// row still exists, so only the `eligible(node)` re-check can drop it. The index still holds the
  /// row as `active` (it was synced before the archive), so the store's own filter lets it through.
  @Test func nodesArchivedSinceTheLastSyncAreDroppedByTheCanonicalReResolve() async throws {
    let database = try openCanonicalDatabase(at: tempURL("searchq-archived-since"))
    let node = Node(name: "Refunds project", kind: NodeKind.project)
    try await database.write { database in try Node.insert { node }.execute(database) }
    let store = indexed(database)                       // indexed while active…
    try await database.write { database in              // …archived afterwards
      try Node.where { $0.id.eq(node.id) }.update { $0.state = NodeState.archived }.execute(database)
    }
    #expect(SearchQueries.search(query: "refunds ", scope: SearchScope(visibleNodeIDs: [node.id]),
                                 store: store, database).isEmpty)
  }

  @Test func closedLooseEndsAreDroppedByTheCanonicalReResolve() async throws {
    let database = try openCanonicalDatabase(at: tempURL("searchq-closed"))
    let node = Node(name: "Pensieve", kind: NodeKind.project)
    try await database.write { database in try Node.insert { node }.execute(database) }
    let event = try makeEvent(database, node: node, summary: "session")
    let looseEnd = LooseEnd(nodeID: node.id, sourceEventID: event.id,
                            text: "revisit the refunds flow", quote: "revisit the refunds flow",
                            role: "user")
    try await database.write { database in try LooseEnd.insert { looseEnd }.execute(database) }
    let store = indexed(database)
    #expect(SearchQueries.search(query: "refunds ", scope: SearchScope(visibleNodeIDs: [node.id]),
                                 store: store, database).contains { $0.id == looseEnd.id })
    try await database.write { database in
      try LooseEnd.where { $0.id.eq(looseEnd.id) }.update { $0.status = "resolved" }
        .execute(database)
    }
    #expect(!SearchQueries.search(query: "refunds ", scope: SearchScope(visibleNodeIDs: [node.id]),
                                  store: store, database).contains { $0.id == looseEnd.id })
  }

  @Test func resultsAreCappedAtFifty() async throws {
    let database = try openCanonicalDatabase(at: tempURL("searchq-cap"))
    let node = Node(name: "Pensieve", kind: NodeKind.project)
    try await database.write { database in try Node.insert { node }.execute(database) }
    for index in 0..<60 { _ = try makeEvent(database, node: node, summary: "refunds change \(index)") }
    let store = indexed(database)
    #expect(SearchQueries.search(query: "refunds ", scope: SearchScope(visibleNodeIDs: [node.id]),
                                 store: store, database).count == SearchQueries.resultCap)
  }

  // MARK: - Top Hit

  @Test func topHitMatchesAWordPrefixCaseAndDiacriticInsensitively() {
    let nodes = [Node(name: "Pensieve", kind: NodeKind.project),
                 Node(name: "Lösung Tracker", kind: NodeKind.project)]
    #expect(SearchQueries.topHit(query: "pens", in: nodes)?.nodeID == nodes[0].id)
    #expect(SearchQueries.topHit(query: "losung", in: nodes)?.nodeID == nodes[1].id)
    #expect(SearchQueries.topHit(query: "Tracker", in: nodes)?.nodeID == nodes[1].id)  // inner word
    #expect(SearchQueries.topHit(query: "racker", in: nodes) == nil)                   // mid-word: no
  }

  @Test func topHitCarriesNoScoreBecauseItDidNotComeFromTheRanking() {
    let nodes = [Node(name: "Pensieve", kind: NodeKind.project)]
    #expect(SearchQueries.topHit(query: "pens", in: nodes)?.score == nil)
  }

  @Test func topHitIsDeterministicAcrossEquallyGoodCandidates() {
    let nodes = [Node(name: "Refunds beta", kind: NodeKind.project),
                 Node(name: "Refunds alpha", kind: NodeKind.project)]
    #expect(SearchQueries.topHit(query: "refunds", in: nodes)?.title == "Refunds alpha")
  }

  /// The guarantee the pin exists for: a node ranked out of the capped result list is STILL
  /// offered for navigation, because topHit scans the node set rather than the returned hits.
  ///
  /// The crowding-out is asserted, not assumed. Note BM25's length normalisation favours SHORT
  /// documents, so a bare node name would actually OUTRANK 60 two-token event texts — the long
  /// description is what genuinely sinks this node below all of them and out of the 50-result cap.
  @Test func topHitSurvivesANodeRankedOutOfTheResultCap() async throws {
    let database = try openCanonicalDatabase(at: tempURL("searchq-tophit"))
    let filler = Array(repeating: "context", count: 300).joined(separator: " ")
    let target = Node(name: "Refunds", kind: NodeKind.project, description: filler)
    let noisy = Node(name: "Noise", kind: NodeKind.project)
    try await database.write { database in
      try Node.insert { target }.execute(database)
      try Node.insert { noisy }.execute(database)
    }
    for index in 0..<60 { _ = try makeEvent(database, node: noisy, summary: "refunds \(index)") }
    let store = indexed(database)
    let visible: Set<UUID> = [target.id, noisy.id]
    let hits = SearchQueries.search(query: "refunds ", scope: SearchScope(visibleNodeIDs: visible),
                                    store: store, database)
    #expect(hits.count == SearchQueries.resultCap)
    #expect(!hits.contains { $0.nodeID == target.id })   // genuinely crowded out of the ranking…
    let pinned = SearchQueries.topHit(query: "refunds", in: [target, noisy])
    #expect(pinned?.nodeID == target.id)                 // …and still offered for navigation.
  }
}
