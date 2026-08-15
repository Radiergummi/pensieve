import Foundation
import Testing
import SQLiteData
@testable import PensieveKit

// MARK: - fixtures
//
// Free functions in the style `Tests/PensieveKitTests/TestSupport.swift` already establishes
// (`tempURL`, `tempSearchStore`, `makeCommittedRepo`). There are NO harness structs in this suite —
// do not introduce the first one. These stay `private` to this file because only it uses them;
// promote to `TestSupport.swift` only if a second file needs them.
//
// `tempSearchStore()` ALREADY EXISTS in TestSupport.swift — use it rather than constructing a
// `SearchIndexStore` by hand.

private func makePassageStore() throws -> any DatabaseWriter {
  try openCanonicalDatabase(at: tempURL("passage-canon"))
}

private func insertNode(_ database: any DatabaseWriter, name: String,
                        state: NodeState = .active) throws -> Node {
  let node = Node(name: name, state: state)
  try database.write { database in try Node.insert { node }.execute(database) }
  return node
}

/// A `cc.session` event with its `Source`. `transcriptPath` is written into `detailJSON` under the
/// same key `Ingester` uses, because that is where `ProvenanceQueries.transcriptPath(in:)` reads it.
private func insertSessionEvent(_ database: any DatabaseWriter, nodeID: UUID,
                                transcriptPath: String = "") throws -> Event {
  let source = Source(nodeID: nodeID, kind: SourceKind.claudeCode,
                      key: tempURL("repo", ext: nil).path)
  let detail = try encodeJSON(["sessionID": UUID().uuidString, "prompts": "1",
                               "transcriptPath": transcriptPath])
  let event = Event(nodeID: nodeID, sourceID: source.id, occurredAt: Date(),
                    kind: CaptureKind.ccSession, summary: "session", detailJSON: detail)
  try database.write { database in
    try Source.insert { source }.execute(database)
    try Event.insert { event }.execute(database)
  }
  return event
}

@discardableResult
private func insertPassage(_ database: any DatabaseWriter, nodeID: UUID, eventID: UUID,
                           // Defaulted ONLY to keep this fixture under SwiftLint's
                           // `function_parameter_count` cap (which excludes defaulted parameters
                           // from its count, the same device `SearchQueries.buildHits` uses). Every
                           // call site still passes both explicitly.
                           turnIndex: Int = 0, messageIndex: Int = 0, role: PassageRole,
                           text: String,
                           occurredAt: Date = Date(timeIntervalSince1970: 1_700_000_000)) throws -> Passage {
  let passage = Passage(nodeID: nodeID, eventID: eventID, turnIndex: turnIndex,
                        messageIndex: messageIndex, role: role, text: text,
                        occurredAt: occurredAt)
  try database.write { database in try Passage.insert { passage }.execute(database) }
  return passage
}

private func passageItem(_ text: String, nodeID: UUID, state: NodeState = .active,
                         itemID: UUID = UUID()) -> EmbeddableItem {
  EmbeddableItem(itemID: itemID.uuidString, kind: "passage", nodeID: nodeID.uuidString,
                 state: state.rawValue, text: text)
}

/// A transcript file of alternating prompt/reply pairs, named `<sessionID>.jsonl` — load-bearing,
/// because `TranscriptParser` derives the session id from the FILENAME, not from the JSON. The
/// assistant content is an ARRAY of `text` blocks, matching the real format `extractText` reads.
private func writeTranscript(_ pairs: [(prompt: String, reply: String)]) throws -> URL {
  let id = UUID().uuidString
  let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("\(id).jsonl")
  var lines: [String] = []
  for pair in pairs {
    lines.append("""
      {"type":"user","cwd":"/tmp","sessionId":"\(id)","timestamp":"2026-06-30T10:00:00Z",\
      "message":{"role":"user","content":"\(pair.prompt)"}}
      """)
    lines.append("""
      {"type":"assistant","sessionId":"\(id)","timestamp":"2026-06-30T10:00:01Z",\
      "message":{"role":"assistant","content":[{"type":"text","text":"\(pair.reply)"}]}}
      """)
  }
  try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
  return url
}

@Suite struct PassageQueriesTests {
  @Test func passagesAreSearchableInTheirOwnTable() throws {
    let store = tempSearchStore()
    let nodeID = UUID()
    store.rebuildPassages(items: [passageItem("the LWCR is stale so launchd rejects the spawn",
                                              nodeID: nodeID)],
                          passagesHash: "h1")
    let query = try #require(FTSQueryBuilder.build("launchd spawn", file: nil))
    let hits = store.searchPassages(query, limit: 10, includeArchived: false)
    #expect(hits.count == 1)
    #expect(hits.first?.kind == "passage")
  }

  /// The whole reason passages get their own table: writing them must not touch `documents`,
  /// so the existing text ranking is byte-identical by construction.
  @Test func rebuildingPassagesLeavesTheTextIndexAlone() throws {
    let store = tempSearchStore()
    let nodeID = UUID()
    store.rebuild(items: [EmbeddableItem(itemID: UUID().uuidString, kind: "node",
                                         nodeID: nodeID.uuidString, state: NodeState.active.rawValue,
                                         text: "launchd sync agent")],
                  corpusHash: "text-1")
    store.rebuildPassages(items: [passageItem("something about launchd entirely", nodeID: nodeID)],
                          passagesHash: "pass-1")
    let query = try #require(FTSQueryBuilder.build("launchd", file: nil))
    #expect(store.search(query, limit: 10, includeArchived: false).count == 1,
            "the node document survives a passage rebuild")
    #expect(store.storedCorpusHash() == "text-1", "and its hash is untouched")
  }

  /// Symmetry: a text rebuild must not wipe passages. Without a separate hash and a separate
  /// DELETE, every new commit would silently clear the passage index.
  @Test func rebuildingTheTextIndexLeavesPassagesAlone() throws {
    let store = tempSearchStore()
    let nodeID = UUID()
    store.rebuildPassages(items: [passageItem("passage about the retrieval index", nodeID: nodeID)],
                          passagesHash: "pass-1")
    store.rebuild(items: [], corpusHash: "text-2")
    let query = try #require(FTSQueryBuilder.build("retrieval", file: nil))
    #expect(store.searchPassages(query, limit: 10, includeArchived: false).count == 1)
    #expect(store.storedPassagesHash() == "pass-1")
  }

  @Test func archivedPassagesRequireOptIn() throws {
    let store = tempSearchStore()
    let nodeID = UUID()
    store.rebuildPassages(items: [passageItem("archived talk about launchd", nodeID: nodeID,
                                              state: .archived)],
                          passagesHash: "h1")
    let query = try #require(FTSQueryBuilder.build("launchd", file: nil))
    #expect(store.searchPassages(query, limit: 10, includeArchived: false).isEmpty)
    #expect(store.searchPassages(query, limit: 10, includeArchived: true).count == 1)
  }

  /// `gatherPassages` decides what is eligible to be searched at all, so it is worth pinning
  /// directly rather than through the store. Three properties in one pass: an item carries its
  /// OWNING node's state (a passage has none of its own), a node in a state the corpus does not
  /// index contributes nothing, and the order is deterministic — the corpus hash is computed over
  /// this array, so an order that depended on SQLite's whim would rebuild the whole index on every
  /// sync with nothing changed.
  @Test func gatherPassagesCarriesOwningNodeStateInDeterministicOrder() throws {
    let database = try makePassageStore()
    let active = try insertNode(database, name: "Active")
    let archived = try insertNode(database, name: "Archived", state: .archived)
    let muted = try insertNode(database, name: "Muted", state: .muted)
    let activeEvent = try insertSessionEvent(database, nodeID: active.id)
    let archivedEvent = try insertSessionEvent(database, nodeID: archived.id)
    let mutedEvent = try insertSessionEvent(database, nodeID: muted.id)
    try insertPassage(database, nodeID: active.id, eventID: activeEvent.id, role: .prompt,
                      text: "second in time, first alphabetically is irrelevant",
                      occurredAt: Date(timeIntervalSince1970: 2_000))
    try insertPassage(database, nodeID: archived.id, eventID: archivedEvent.id, role: .reply,
                      text: "earliest of the three",
                      occurredAt: Date(timeIntervalSince1970: 1_000))
    try insertPassage(database, nodeID: muted.id, eventID: mutedEvent.id, role: .prompt,
                      text: "a muted node contributes nothing",
                      occurredAt: Date(timeIntervalSince1970: 3_000))

    let items = try EmbeddableCorpus.gatherPassages(database)
    #expect(items.count == 2, "the muted node's passage is not part of the corpus")
    #expect(items.allSatisfy { $0.kind == "passage" })
    #expect(items.map(\.state) == [NodeState.archived.rawValue, NodeState.active.rawValue],
            "each item carries its owning node's state, ordered by occurredAt")
    #expect(try EmbeddableCorpus.gatherPassages(database).map(\.itemID) == items.map(\.itemID),
            "a second gather returns the same order")
  }

  /// Turn dedupe: overlap and long replies both put several chunks of ONE conversation in the
  /// candidate list, and the user must see one row, ranked by its best chunk.
  @Test func chunksOfOneTurnCollapseToASingleHit() throws {
    let database = try makePassageStore()
    let store = tempSearchStore()
    let node = try insertNode(database, name: "Pensieve")
    let event = try insertSessionEvent(database, nodeID: node.id)
    let first = try insertPassage(database, nodeID: node.id, eventID: event.id, turnIndex: 0,
                                 messageIndex: 1, role: .reply,
                                 text: "launchd refuses the spawn because the LWCR is stale")
    let second = try insertPassage(database, nodeID: node.id, eventID: event.id, turnIndex: 0,
                                  messageIndex: 1, role: .reply,
                                  text: "the LWCR is stale, so launchd refuses it again")
    store.rebuildPassages(items: try EmbeddableCorpus.gatherPassages(database),
                          passagesHash: "h1")

    let hits = PassageQueries.search(query: "launchd",
                                     scope: SearchScope(visibleNodeIDs: [node.id]),
                                     store: store, database)
    #expect(hits.count == 1, "two chunks of one turn are one conversation")
    #expect([first.id, second.id].contains(hits[0].id))
  }

  @Test func twoDifferentTurnsStayTwoHits() throws {
    let database = try makePassageStore()
    let store = tempSearchStore()
    let node = try insertNode(database, name: "Pensieve")
    let event = try insertSessionEvent(database, nodeID: node.id)
    try insertPassage(database, nodeID: node.id, eventID: event.id, turnIndex: 0,
                      messageIndex: 0, role: .prompt, text: "why does launchd refuse")
    try insertPassage(database, nodeID: node.id, eventID: event.id, turnIndex: 1,
                      messageIndex: 2, role: .prompt, text: "does launchd log the reason")
    store.rebuildPassages(items: try EmbeddableCorpus.gatherPassages(database),
                          passagesHash: "h1")
    let hits = PassageQueries.search(query: "launchd",
                                     scope: SearchScope(visibleNodeIDs: [node.id]),
                                     store: store, database)
    #expect(hits.count == 2)
  }

  /// Turn 0 exists in EVERY session, so a dedupe key of `turnIndex` alone would collapse two
  /// unrelated conversations into one row. This pins that the key includes the event.
  @Test func turnZeroOfTwoDifferentSessionsStaysTwoHits() throws {
    let database = try makePassageStore()
    let store = tempSearchStore()
    let node = try insertNode(database, name: "Pensieve")
    let firstEvent = try insertSessionEvent(database, nodeID: node.id)
    let secondEvent = try insertSessionEvent(database, nodeID: node.id)
    try insertPassage(database, nodeID: node.id, eventID: firstEvent.id, turnIndex: 0,
                      messageIndex: 0, role: .prompt, text: "why does launchd refuse the spawn")
    try insertPassage(database, nodeID: node.id, eventID: secondEvent.id, turnIndex: 0,
                      messageIndex: 0, role: .prompt, text: "launchd again, a different session")
    store.rebuildPassages(items: try EmbeddableCorpus.gatherPassages(database),
                          passagesHash: "h1")
    let hits = PassageQueries.search(query: "launchd",
                                     scope: SearchScope(visibleNodeIDs: [node.id]),
                                     store: store, database)
    #expect(hits.count == 2)
  }

  /// The last line of grounding defense. A passage deleted from canonical after the index was built
  /// must not surface, even though its index row still matches.
  @Test func aPassageDeletedFromCanonicalDoesNotSurface() throws {
    let database = try makePassageStore()
    let store = tempSearchStore()
    let node = try insertNode(database, name: "Pensieve")
    let event = try insertSessionEvent(database, nodeID: node.id)
    let passage = try insertPassage(database, nodeID: node.id, eventID: event.id, turnIndex: 0,
                                   messageIndex: 0, role: .prompt,
                                   text: "why does launchd refuse the spawn")
    store.rebuildPassages(items: try EmbeddableCorpus.gatherPassages(database),
                          passagesHash: "h1")
    try database.write { database in
      try Passage.where { $0.id.eq(passage.id) }.delete().execute(database)
    }

    let hits = PassageQueries.search(query: "launchd",
                                     scope: SearchScope(visibleNodeIDs: [node.id]),
                                     store: store, database)
    #expect(hits.isEmpty)
  }

  /// Focus muting is applied after the index, like every other search path.
  @Test func aMutedNodesPassagesAreFilteredOut() throws {
    let database = try makePassageStore()
    let store = tempSearchStore()
    let node = try insertNode(database, name: "Pensieve")
    let event = try insertSessionEvent(database, nodeID: node.id)
    try insertPassage(database, nodeID: node.id, eventID: event.id, turnIndex: 0,
                      messageIndex: 0, role: .prompt, text: "why does launchd refuse")
    store.rebuildPassages(items: try EmbeddableCorpus.gatherPassages(database),
                          passagesHash: "h1")
    #expect(PassageQueries.search(query: "launchd", scope: SearchScope(visibleNodeIDs: []),
                                  store: store, database).isEmpty)
  }

  @Test func theSnippetHighlightsWhyTheRowMatched() throws {
    let database = try makePassageStore()
    let store = tempSearchStore()
    let node = try insertNode(database, name: "Pensieve")
    let event = try insertSessionEvent(database, nodeID: node.id)
    try insertPassage(database, nodeID: node.id, eventID: event.id, turnIndex: 0,
                      messageIndex: 0, role: .prompt,
                      text: "why does launchd refuse the spawn")
    store.rebuildPassages(items: try EmbeddableCorpus.gatherPassages(database),
                          passagesHash: "h1")
    let hits = PassageQueries.search(query: "launchd",
                                     scope: SearchScope(visibleNodeIDs: [node.id]),
                                     store: store, database)
    #expect(hits.first?.snippet.match.isEmpty == false)
    #expect(hits.first?.snippet.match.lowercased().contains("launchd") == true)
  }

  /// The collapse makes the candidate:hit ratio structurally worse than 1:1, so a single-shot
  /// over-fetch can starve the page. Ten turns, each split into several chunks, must still return
  /// ten hits rather than however many survive one fixed window.
  @Test func manyChunkedTurnsStillFillThePage() throws {
    let database = try makePassageStore()
    let store = tempSearchStore()
    let node = try insertNode(database, name: "Pensieve")
    let event = try insertSessionEvent(database, nodeID: node.id)
    // Explicit, strictly turn-major occurredAt: `gatherPassages` orders by `(occurredAt, id)`, so
    // this pins the corpus (and therefore the index insertion / rowid) order to turn-major,
    // chunk-minor — the layout that makes a single fixed-size window land on only the first few
    // turns rather than a random cross-section of all twenty.
    for turn in 0..<20 {
      for chunk in 0..<10 {
        try insertPassage(database, nodeID: node.id, eventID: event.id, turnIndex: turn,
                          messageIndex: turn * 2, role: .reply,
                          text: "launchd refuses the spawn, chunk \(chunk) of turn \(turn)",
                          occurredAt: Date(timeIntervalSince1970: 1_700_000_000
                                           + Double(turn * 10 + chunk)))
      }
    }
    store.rebuildPassages(items: try EmbeddableCorpus.gatherPassages(database),
                          passagesHash: "h1")
    let hits = PassageQueries.search(query: "launchd",
                                     scope: SearchScope(visibleNodeIDs: [node.id], limit: 10),
                                     store: store, database)
    #expect(hits.count == 10, "ten distinct turns, one hit each")
  }
}
