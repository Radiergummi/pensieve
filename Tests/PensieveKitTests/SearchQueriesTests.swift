import Foundation
import Testing
import SQLiteData
@testable import PensieveKit

/// Insert nodeA node + one event + loose ends; returns the node.
private func seed(_ database: any DatabaseWriter, name: String, description: String = "",
                  kind: NodeKind = .project,
                  ends: [(text: String, quote: String, label: String)] = []) throws -> Node {
  let node = Node(name: name, kind: kind, description: description)
  let source = Source(id: UUID(), nodeID: node.id, kind: SourceKind.claudeCode, key: "/p/\(node.id)")
  let event = Event(nodeID: node.id, sourceID: source.id, occurredAt: Date(),
                    kind: CaptureKind.ccSession, summary: "s", detailJSON: "{}", fingerprint: name)
  try database.write { database in
    try Node.insert { node }.execute(database)
    try Source.insert { source }.execute(database)
    try Event.insert { event }.execute(database)
    for looseEnd in ends {
      try LooseEnd.insert {
        LooseEnd(nodeID: node.id, sourceEventID: event.id, text: looseEnd.text, quote: looseEnd.quote,
                 role: "user", label: looseEnd.label)
      }.execute(database)
    }
  }
  return node
}

private func allVisible(_ database: any DatabaseReader) throws -> Set<UUID> {
  Set(try ProjectQueries.all(database).map(\.id))
}

private func makeEvent(_ database: any DatabaseWriter, node: Node, kind: String = CaptureKind.gitCommit,
                       summary: String = "did nodeA thing", workSummary: String? = nil) throws -> Event {
  let source = Source(nodeID: node.id, kind: SourceKind.gitRepo, key: "/p/\(node.id)")
  let event = Event(nodeID: node.id, sourceID: source.id, occurredAt: Date(), kind: kind,
                    summary: summary, detailJSON: "{}", workSummary: workSummary)
  try database.write { database in
    try Source.insert { source }.execute(database)
    try Event.insert { event }.execute(database)
  }
  return event
}

@Test func searchShortCircuitsBelowMinLength() throws {
  let database = try openCanonicalDatabase(at: tempURL("search-min"))
  _ = try seed(database, name: "Auth")
  #expect(try SearchQueries.search(query: "a", visibleNodeIDs: allVisible(database), database).isEmpty)
  #expect(try SearchQueries.search(query: "  ", visibleNodeIDs: allVisible(database), database).isEmpty)
  #expect(try SearchQueries.search(query: "🚀", visibleNodeIDs: allVisible(database), database).isEmpty) // 1 grapheme
}

@Test func searchMatchesNodeNameAndDescription() throws {
  let database = try openCanonicalDatabase(at: tempURL("search-node"))
  _ = try seed(database, name: "Authentication")
  _ = try seed(database, name: "Sync daemon", description: "handles authentication tokens")
  let results = try SearchQueries.search(query: "authentication", visibleNodeIDs: allVisible(database), database)
  #expect(results.nodes.count == 2)
  // name-match ("Authentication") ranks before description-only ("Sync daemon")
  #expect(results.nodes.first?.name == "Authentication")
  // matchedField drives the row layout: name hit first, description-only hit second.
  #expect(results.nodes.first?.matchedField == .name)
  #expect(results.nodes.last?.name == "Sync daemon")
  #expect(results.nodes.last?.matchedField == .description)
}

@Test func searchMatchesLooseEndTextAndQuote() throws {
  let database = try openCanonicalDatabase(at: tempURL("search-looseEnd"))
  _ = try seed(database, name: "P", ends: [
    (text: "finish the deploy pipeline", quote: "irrelevant", label: ""),
    (text: "unrelated", quote: "remember the deploy vars", label: ""),
  ])
  let results = try SearchQueries.search(query: "deploy", visibleNodeIDs: allVisible(database), database)
  #expect(results.looseEnds.count == 2)
  // text-match ranks before quote-only match
  #expect(results.looseEnds.first?.snippet.match == "deploy")
  #expect(results.looseEnds.first?.nodeName == "P")
}

@Test func searchExcludesResolvedAndNoiseLooseEnds() throws {
  let database = try openCanonicalDatabase(at: tempURL("search-noise"))
  _ = try seed(database, name: "P", ends: [
    (text: "open deploy item", quote: "q", label: ""),
    (text: "noisy deploy item", quote: "q", label: LooseEndLabel.noise),
  ])
  let results = try SearchQueries.search(query: "deploy", visibleNodeIDs: allVisible(database), database)
  #expect(results.looseEnds.count == 1)
  #expect(results.looseEnds.first?.snippet.match == "deploy")
}

@Test func searchExcludesNodesOutsideVisibleSet() throws {
  let database = try openCanonicalDatabase(at: tempURL("search-focus"))
  let nodeA = try seed(database, name: "Deploy A")
  _ = try seed(database, name: "Deploy B", ends: [(text: "deploy end", quote: "q", label: "")])
  let visible: Set<UUID> = [nodeA.id]   // only A visible
  let results = try SearchQueries.search(query: "deploy", visibleNodeIDs: visible, database)
  #expect(results.nodes.map(\.id) == [nodeA.id])
  #expect(results.looseEnds.isEmpty)      // B's loose end excluded with B
}

@Test func searchIsDeterministicOnTiedKeys() throws {
  let database = try openCanonicalDatabase(at: tempURL("search-tie"))
  // Two nodes with identical names → tiebreak withArchived id.uuidString, stable across runs.
  _ = try seed(database, name: "Dup deploy")
  _ = try seed(database, name: "Dup deploy")
  let firstRun = try SearchQueries.search(query: "deploy", visibleNodeIDs: allVisible(database), database)
  let secondRun = try SearchQueries.search(query: "deploy", visibleNodeIDs: allVisible(database), database)
  #expect(firstRun.nodes.map(\.id) == secondRun.nodes.map(\.id))
  #expect(firstRun.nodes.map(\.id) == firstRun.nodes.map(\.id).sorted { $0.uuidString < $1.uuidString })
}

@Test func searchCapsAtFiftyButReportsPreCapTotal() throws {
  let database = try openCanonicalDatabase(at: tempURL("search-cap"))
  for index in 0..<60 { _ = try seed(database, name: "deploy \(index)") }
  let results = try SearchQueries.search(query: "deploy", visibleNodeIDs: allVisible(database), database)
  #expect(results.nodes.count == 50)
  #expect(results.totalNodeMatches == 60)
}

@Test func searchEmptyDBReturnsEmpty() throws {
  let database = try openCanonicalDatabase(at: tempURL("search-empty"))
  #expect(try SearchQueries.search(query: "deploy", visibleNodeIDs: [], database).isEmpty)
}

@Test func searchExcludesArchivedNodesAndLooseEnds() throws {
  let database = try openCanonicalDatabase(at: tempURL("search-archived"))
  let active = try seed(database, name: "Deploy pipeline", ends: [("deploy the release", "ship it", "todo")])
  let archived = try seed(database, name: "Deploy legacy", ends: [("deploy old thing", "legacy", "todo")])
  #expect(try NodeCommands.archive(database, nodeID: archived.id))
  // allVisible includes the archived node (ProjectQueries.all is unfiltered), proving the
  // exclusion is by state, not by the visible set.
  let results = try SearchQueries.search(query: "deploy", visibleNodeIDs: allVisible(database), database)
  #expect(results.nodes.count == 1)
  #expect(results.nodes.first?.id == active.id)
  #expect(results.looseEnds.count == 1)
  #expect(results.looseEnds.first?.nodeID == active.id)
}

@Test func searchIncludesArchivedWhenFlagSet() throws {
  let database = try openCanonicalDatabase(at: tempURL("search-incl-archived"))
  let active = try seed(database, name: "Deploy pipeline", ends: [("deploy the release", "ship it", "todo")])
  let archived = try seed(database, name: "Deploy legacy", ends: [("deploy old thing", "legacy", "todo")])
  #expect(try NodeCommands.archive(database, nodeID: archived.id))

  // Flag OFF (default) → archived excluded (matches the existing exclusion test).
  let off = try SearchQueries.search(query: "deploy", visibleNodeIDs: allVisible(database), database)
  #expect(off.nodes.map(\.id) == [active.id])

  // Flag ON → both the active AND the archived node + their open loose ends surface.
  let withArchived = try SearchQueries.search(query: "deploy", visibleNodeIDs: allVisible(database),
                                    includeArchived: true, database)
  #expect(Set(withArchived.nodes.map(\.id)) == [active.id, archived.id])
  #expect(Set(withArchived.looseEnds.map(\.nodeID)) == [active.id, archived.id])
}

@Test func hitsCarryTheOwningNodesArchivedFlag() async throws {
  let database = try openCanonicalDatabase(at: tempURL("search-archived-flag"))
  let active = Node(name: "Refund handling", kind: NodeKind.project)
  let archived = Node(name: "Refund handling legacy", state: .archived, kind: NodeKind.project)
  try await database.write { database in
    try Node.insert { active }.execute(database)
    try Node.insert { archived }.execute(database)
  }
  let event = try makeEvent(database, node: archived)
  let looseEnd = LooseEnd(nodeID: archived.id, sourceEventID: event.id,
                    text: "refund the last batch", quote: "TODO refund")
  try await database.write { try LooseEnd.insert { looseEnd }.execute($0) }

  let results = try SearchQueries.search(query: "refund", visibleNodeIDs: [active.id, archived.id],
                                   includeArchived: true, database)

  #expect(results.nodes.first { $0.id == active.id }?.isArchived == false)
  #expect(results.nodes.first { $0.id == archived.id }?.isArchived == true)
  #expect(results.looseEnds.first { $0.id == looseEnd.id }?.isArchived == true)
}
