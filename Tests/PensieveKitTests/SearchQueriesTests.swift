import Foundation
import Testing
import SQLiteData
@testable import PensieveKit

/// Insert a node + one event + loose ends; returns the node.
private func seed(_ db: any DatabaseWriter, name: String, description: String = "",
                  kind: String = NodeKind.project,
                  ends: [(text: String, quote: String, label: String)] = []) throws -> Node {
  let node = Node(name: name, kind: kind, description: description)
  let source = Source(id: UUID(), nodeID: node.id, kind: SourceKind.claudeCode, key: "/p/\(node.id)")
  let event = Event(nodeID: node.id, sourceID: source.id, occurredAt: Date(),
                    kind: CaptureKind.ccSession, summary: "s", detailJSON: "{}", fingerprint: name)
  try db.write { db in
    try Node.insert { node }.execute(db)
    try Source.insert { source }.execute(db)
    try Event.insert { event }.execute(db)
    for e in ends {
      try LooseEnd.insert {
        LooseEnd(nodeID: node.id, sourceEventID: event.id, text: e.text, quote: e.quote,
                 role: "user", label: e.label)
      }.execute(db)
    }
  }
  return node
}

private func allVisible(_ db: any DatabaseReader) throws -> Set<UUID> {
  Set(try ProjectQueries.all(db).map(\.id))
}

@Test func searchShortCircuitsBelowMinLength() throws {
  let db = try openCanonicalDatabase(at: tempURL("search-min"))
  _ = try seed(db, name: "Auth")
  #expect(try SearchQueries.search(query: "a", visibleNodeIDs: allVisible(db), db).isEmpty)
  #expect(try SearchQueries.search(query: "  ", visibleNodeIDs: allVisible(db), db).isEmpty)
  #expect(try SearchQueries.search(query: "🚀", visibleNodeIDs: allVisible(db), db).isEmpty) // 1 grapheme
}

@Test func searchMatchesNodeNameAndDescription() throws {
  let db = try openCanonicalDatabase(at: tempURL("search-node"))
  _ = try seed(db, name: "Authentication")
  _ = try seed(db, name: "Sync daemon", description: "handles authentication tokens")
  let r = try SearchQueries.search(query: "authentication", visibleNodeIDs: allVisible(db), db)
  #expect(r.nodes.count == 2)
  // name-match ("Authentication") ranks before description-only ("Sync daemon")
  #expect(r.nodes.first?.name == "Authentication")
}

@Test func searchMatchesLooseEndTextAndQuote() throws {
  let db = try openCanonicalDatabase(at: tempURL("search-le"))
  _ = try seed(db, name: "P", ends: [
    (text: "finish the deploy pipeline", quote: "irrelevant", label: ""),
    (text: "unrelated", quote: "remember the deploy vars", label: ""),
  ])
  let r = try SearchQueries.search(query: "deploy", visibleNodeIDs: allVisible(db), db)
  #expect(r.looseEnds.count == 2)
  // text-match ranks before quote-only match
  #expect(r.looseEnds.first?.snippet.match == "deploy")
  #expect(r.looseEnds.first?.nodeName == "P")
}

@Test func searchExcludesResolvedAndNoiseLooseEnds() throws {
  let db = try openCanonicalDatabase(at: tempURL("search-noise"))
  _ = try seed(db, name: "P", ends: [
    (text: "open deploy item", quote: "q", label: ""),
    (text: "noisy deploy item", quote: "q", label: LooseEndLabel.noise),
  ])
  let r = try SearchQueries.search(query: "deploy", visibleNodeIDs: allVisible(db), db)
  #expect(r.looseEnds.count == 1)
  #expect(r.looseEnds.first?.snippet.match == "deploy")
}

@Test func searchExcludesNodesOutsideVisibleSet() throws {
  let db = try openCanonicalDatabase(at: tempURL("search-focus"))
  let a = try seed(db, name: "Deploy A")
  _ = try seed(db, name: "Deploy B", ends: [(text: "deploy end", quote: "q", label: "")])
  let visible: Set<UUID> = [a.id]   // only A visible
  let r = try SearchQueries.search(query: "deploy", visibleNodeIDs: visible, db)
  #expect(r.nodes.map(\.id) == [a.id])
  #expect(r.looseEnds.isEmpty)      // B's loose end excluded with B
}

@Test func searchIsDeterministicOnTiedKeys() throws {
  let db = try openCanonicalDatabase(at: tempURL("search-tie"))
  // Two nodes with identical names → tiebreak on id.uuidString, stable across runs.
  _ = try seed(db, name: "Dup deploy")
  _ = try seed(db, name: "Dup deploy")
  let r1 = try SearchQueries.search(query: "deploy", visibleNodeIDs: allVisible(db), db)
  let r2 = try SearchQueries.search(query: "deploy", visibleNodeIDs: allVisible(db), db)
  #expect(r1.nodes.map(\.id) == r2.nodes.map(\.id))
  #expect(r1.nodes.map(\.id) == r1.nodes.map(\.id).sorted { $0.uuidString < $1.uuidString })
}

@Test func searchCapsAtFiftyButReportsPreCapTotal() throws {
  let db = try openCanonicalDatabase(at: tempURL("search-cap"))
  for i in 0..<60 { _ = try seed(db, name: "deploy \(i)") }
  let r = try SearchQueries.search(query: "deploy", visibleNodeIDs: allVisible(db), db)
  #expect(r.nodes.count == 50)
  #expect(r.totalNodeMatches == 60)
}

@Test func searchEmptyDBReturnsEmpty() throws {
  let db = try openCanonicalDatabase(at: tempURL("search-empty"))
  #expect(try SearchQueries.search(query: "deploy", visibleNodeIDs: [], db).isEmpty)
}
