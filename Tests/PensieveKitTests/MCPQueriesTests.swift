import Foundation
import Testing
import SQLiteData
@testable import PensieveKit

// MARK: - fixtures
//
// Free functions in the style TestSupport.swift establishes. Private to this file.

private func insertGitEvent(_ database: any DatabaseWriter, node: Node, summary: String) throws -> Event {
  let source = Source(nodeID: node.id, kind: SourceKind.gitRepo, key: "/repo/\(UUID())")
  let event = Event(nodeID: node.id, sourceID: source.id, occurredAt: Date(),
                    kind: CaptureKind.gitCommit, summary: summary, detailJSON: "{}",
                    fingerprint: UUID().uuidString)
  try database.write { database in
    try Source.insert { source }.execute(database)
    try Event.insert { event }.execute(database)
  }
  return event
}

@discardableResult
private func insertPassage(_ database: any DatabaseWriter, node: Node, event: Event,
                           messageIndex: Int, text: String) throws -> Passage {
  let passage = Passage(nodeID: node.id, eventID: event.id, turnIndex: messageIndex,
                        messageIndex: messageIndex, role: .prompt, text: text,
                        occurredAt: Date(timeIntervalSince1970: 1_700_000_000))
  try database.write { database in try Passage.insert { passage }.execute(database) }
  return passage
}

private func indexed(_ database: any DatabaseWriter) -> SearchIndexStore {
  let store = tempSearchStore()
  let indexer = SearchIndexer(store: store)
  indexer.sync(database)
  indexer.syncPassages(database)
  return store
}

private func payload(_ json: Data) throws -> [String: Any] {
  try #require(try JSONSerialization.jsonObject(with: json) as? [String: Any])
}

private func items(_ json: Data) throws -> [[String: Any]] {
  try #require(try payload(json)["items"] as? [[String: Any]])
}

/// The MCP derivation that used to live in the CLI target, where `PensieveKitTests` could not reach
/// a line of it: store degradation, scope construction, the passage budget and payload assembly.
@Suite struct MCPQueriesTests {
  // MARK: - store availability (finding 2.20)

  /// "There is no store" and "the store is there and will not open" are different answers, and
  /// conflating them under one `try?` made MCP tell the model no work had ever been captured on a
  /// machine whose store was merely corrupt.
  @Test func anAbsentStoreIsNil() throws {
    #expect(try MCPQueries.openCanonicalIfPresent(at: tempURL("mcp-missing")) == nil)
  }

  @Test func aStoreThatExistsAndWillNotOpenIsAnError() throws {
    let url = tempURL("mcp-corrupt")
    // A directory at the store's path: present on disk, impossible for SQLite to open. A file of
    // garbage bytes is NOT a reliable fixture — SQLite defers the header check, so a read-only
    // pool can open one without complaint.
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    #expect(throws: MCPFailure.canonicalStoreUnreadable(path: url.path)) {
      try MCPQueries.openCanonicalIfPresent(at: url)
    }
  }

  // MARK: - scope construction (findings 3.4 / 1.36)

  /// `include_archived` must gate the VISIBLE SET too. Gating only the query layer lets an archived
  /// hit through the index and then filters it back out here, which reads as "no results".
  @Test func includeArchivedWidensTheVisibleNodeSet() throws {
    let database = try openCanonicalDatabase(at: tempURL("mcp-scope"))
    let active = Node(name: "Active", kind: NodeKind.project)
    let archived = Node(name: "Archived", state: .archived, kind: NodeKind.project)
    let muted = Node(name: "Muted", state: .muted, kind: NodeKind.project)
    try database.write { database in
      try Node.insert { active }.execute(database)
      try Node.insert { archived }.execute(database)
      try Node.insert { muted }.execute(database)
    }
    #expect(try MCPQueries.searchableNodeIDs(includeArchived: false, database) == [active.id])
    #expect(try MCPQueries.searchableNodeIDs(includeArchived: true, database) == [active.id, archived.id],
            "muted is excluded in BOTH modes — the rule is an allow-list, not a deny-list")
  }

  @Test func archivedWorkIsOnlyFoundWhenAskedFor() throws {
    let database = try openCanonicalDatabase(at: tempURL("mcp-archived"))
    let archived = Node(name: "Archived", state: .archived, kind: NodeKind.project)
    try database.write { database in try Node.insert { archived }.execute(database) }
    _ = try insertGitEvent(database, node: archived, summary: "rework the tokenizer")
    let store = indexed(database)

    let narrow = try MCPQueries.searchJSON(MCPSearchRequest(query: "tokenizer"),
                                           store: store, database)
    #expect(try items(narrow).isEmpty)
    let wide = try MCPQueries.searchJSON(MCPSearchRequest(query: "tokenizer", includeArchived: true),
                                         store: store, database)
    #expect(try items(wide).count == 1)
    #expect(try items(wide)[0]["archived"] as? Bool == true)
  }

  // MARK: - the passage budget (finding 3.4)

  /// Passages get their OWN budget — half the ranked limit, floored at two — rather than sharing
  /// `limit`. Sharing it would delete the conversation list entirely whenever the ranked list is
  /// already full, which is the common case.
  @Test func passagesGetHalfTheRankedBudgetFlooredAtTwo() {
    let scope = SearchScope(visibleNodeIDs: [], limit: 8)
    #expect(MCPQueries.passageScope(from: scope).limit == 4)
    #expect(MCPQueries.passageScope(from: SearchScope(visibleNodeIDs: [], limit: 1)).limit == 2)
    #expect(MCPQueries.passageScope(from: SearchScope(visibleNodeIDs: [], limit: 3)).limit == 2)
    // Derived from the ranked scope, not the raw request, so the two dimensions cannot drift.
    let wide = SearchScope(visibleNodeIDs: [], limit: 8, includeArchived: true, includeClosed: true)
    #expect(MCPQueries.passageScope(from: wide).includeArchived)
    #expect(MCPQueries.passageScope(from: wide).includeClosed)
  }

  /// End to end: the ranked half honours `limit`, the passage half honours its own smaller budget,
  /// and the passages are APPENDED rather than interleaved — the array order is the tool's contract.
  @Test func passagesAreAppendedAfterRankedItemsUnderTheirOwnBudget() throws {
    let database = try openCanonicalDatabase(at: tempURL("mcp-budget"))
    let node = Node(name: "Retrieval", kind: NodeKind.project)
    try database.write { database in try Node.insert { node }.execute(database) }
    // Six ranked candidates and six passages, all matching the same term.
    for index in 0..<6 {
      _ = try insertGitEvent(database, node: node, summary: "tokenizer work \(index)")
    }
    let anchor = try insertGitEvent(database, node: node, summary: "anchor session")
    for index in 0..<6 {
      try insertPassage(database, node: node, event: anchor, messageIndex: index,
                        text: "we should rewrite the tokenizer, take \(index)")
    }
    let store = indexed(database)

    let json = try MCPQueries.searchJSON(MCPSearchRequest(query: "tokenizer", limit: 4),
                                         store: store, database)
    let kinds = try items(json).map { $0["kind"] as? String }
    #expect(kinds.filter { $0 != "passage" }.count == 4, "the ranked half honours `limit`")
    #expect(kinds.filter { $0 == "passage" }.count == 2, "the passage half gets limit/2, not `limit`")
    #expect(kinds.drop(while: { $0 != "passage" }).allSatisfy { $0 == "passage" },
            "passages are appended in one block at the end, never interleaved")
  }

  // MARK: - payload assembly (findings 3.4 / 1.22)

  /// The response wire keys, which a client's parser is written against.
  @Test func theSearchPayloadUsesItsDocumentedWireKeys() throws {
    let database = try openCanonicalDatabase(at: tempURL("mcp-keys"))
    let node = Node(name: "Retrieval", kind: NodeKind.project)
    try database.write { database in try Node.insert { node }.execute(database) }
    _ = try insertGitEvent(database, node: node, summary: "rework the tokenizer")
    let json = try MCPQueries.searchJSON(MCPSearchRequest(query: "tokenizer"),
                                         store: indexed(database), database)
    #expect(try payload(json)["index_state"] as? String == SearchIndexState.ready.rawValue)
    let first = try #require(try items(json).first)
    #expect(first["node_id"] as? String == node.id.uuidString)
    #expect(first["node_name"] as? String == "Retrieval")
  }

  /// An unbuilt index reports `absent` rather than looking like a genuine miss — the distinction the
  /// tool description promises.
  @Test func anUnbuiltIndexIsReportedRatherThanLookingLikeAMiss() throws {
    let database = try openCanonicalDatabase(at: tempURL("mcp-noindex"))
    let json = try MCPQueries.searchJSON(MCPSearchRequest(query: "tokenizer"),
                                         store: tempSearchStore(), database)
    #expect(try payload(json)["index_state"] as? String == SearchIndexState.absent.rawValue)
    #expect(try items(json).isEmpty)
  }

  // MARK: - recall / whats_next dispatch

  @Test func recallPrefersTheLooseEndWhenBothIDsAreGiven() throws {
    let database = try openCanonicalDatabase(at: tempURL("mcp-recall"))
    let node = Node(name: "Retrieval", kind: NodeKind.project)
    try database.write { database in try Node.insert { node }.execute(database) }
    let event = try insertGitEvent(database, node: node, summary: "session")
    let looseEnd = LooseEnd(nodeID: node.id, sourceEventID: event.id,
                            text: "decide the ranking approach", quote: "let us try BM25")
    try database.write { database in try LooseEnd.insert { looseEnd }.execute(database) }
    let passage = try insertPassage(database, node: node, event: event, messageIndex: 0,
                                    text: "a completely different sentence")

    let json = try MCPQueries.recallJSON(
      MCPRecallRequest(looseEndID: looseEnd.id, passageID: passage.id), database)
    let bundle = try #require(try JSONSerialization.jsonObject(with: json) as? [String: Any])
    #expect(bundle["quote"] as? String == "let us try BM25")
  }

  @Test func whatsNextHonoursItsLimit() throws {
    let database = try openCanonicalDatabase(at: tempURL("mcp-next"))
    for index in 0..<4 {
      let node = Node(name: "Project \(index)", kind: NodeKind.project)
      try database.write { database in try Node.insert { node }.execute(database) }
      _ = try insertGitEvent(database, node: node, summary: "work \(index)")
    }
    let json = try MCPQueries.whatsNextJSON(MCPWhatsNextRequest(limit: 2), database)
    let rows = try #require(try JSONSerialization.jsonObject(with: json) as? [[String: Any]])
    #expect(rows.count == 2)
  }
}
