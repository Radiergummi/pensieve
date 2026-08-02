import Testing
import Foundation
import SQLiteData
@testable import PensieveKit

/// Inserts a Source + Event under `node` so a LooseEnd's sourceEventID FK is satisfiable.
/// Mirrors the helpers in SemanticQueriesTests.swift / SemanticIndexerTests.swift.
private func makeRelatedEvent(_ db: any DatabaseWriter, node: Node,
                              kind: String = CaptureKind.gitCommit,
                              summary: String = "did a thing",
                              workSummary: String? = nil) throws -> Event {
  let source = Source(nodeID: node.id, kind: SourceKind.gitRepo, key: "/rel/\(node.id)")
  let event = Event(nodeID: node.id, sourceID: source.id, occurredAt: Date(), kind: kind,
                    summary: summary, detailJSON: "{}", workSummary: workSummary)
  try db.write { db in
    try Source.insert { source }.execute(db)
    try Event.insert { event }.execute(db)
  }
  return event
}

@Suite struct RelatedQueriesTests {
  private func store() -> TextIndexStore {
    TextIndexStore(url: URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("relq-\(UUID().uuidString).sqlite"))
  }

  /// Index straight from the live corpus, so these tests exercise the same producer production uses.
  private func indexed(_ db: any DatabaseReader) throws -> TextIndexStore {
    let s = store()
    s.rebuild(items: try EmbeddableCorpus.gather(db))
    return s
  }

  @Test func findsANodeByAWordInItsName() async throws {
    let db = try openCanonicalDatabase(at: tempURL("relq-basic"))
    let n = Node(name: "Refunds pipeline overhaul", kind: NodeKind.project)
    try await db.write { try Node.insert { n }.execute($0) }
    let s = try indexed(db)

    let hits = RelatedQueries.search(query: "refunds", visibleNodeIDs: [n.id],
                                     excludingIDs: [], k: 5, store: s, db)
    #expect(hits.map { $0.id } == [n.id])
    #expect(hits.first?.kind == "node")
    #expect(hits.first?.nodeName == "Refunds pipeline overhaul")
  }

  /// Focus muting is applied AFTER retrieval, on the caller's visible set.
  @Test func focusMutedNodesNeverSurface() async throws {
    let db = try openCanonicalDatabase(at: tempURL("relq-mute"))
    let visible = Node(name: "Visible refunds work", kind: NodeKind.project)
    let muted = Node(name: "Muted refunds work", kind: NodeKind.project, context: "personal")
    try await db.write { db in
      try Node.insert { visible }.execute(db)
      try Node.insert { muted }.execute(db)
    }
    let s = try indexed(db)

    let hits = RelatedQueries.search(query: "refunds", visibleNodeIDs: [visible.id],
                                     excludingIDs: [], k: 5, store: s, db)
    #expect(hits.contains { $0.nodeID == visible.id })
    #expect(!hits.contains { $0.nodeID == muted.id })
  }

  /// Regression guard for the over-fetch itself. 60 muted-context nodes match BOTH query terms in
  /// a short name; the one visible node matches only "refunds" inside a deliberately long name, so
  /// BM25's length normalisation ranks it **61st** — below the initial `kFetch = max(k*8, 50)`
  /// window. Only the grow-and-retry loop reaches it. (Ranking verified against SQLite's bm25()
  /// before this fixture was written; the muted names differ per-index so Task 1's text de-dup
  /// keeps all 60.)
  @Test func overFetchReachesAVisibleHitBuriedUnderMutedMatches() async throws {
    let db = try openCanonicalDatabase(at: tempURL("relq-overfetch"))
    let filler = (0..<60).map { "filler\($0)" }.joined(separator: " ")
    let visible = Node(name: "refunds \(filler)", kind: NodeKind.project)
    let muted = (0..<60).map {
      Node(name: "refunds pipeline k\($0)", kind: NodeKind.project, context: "personal")
    }
    try await db.write { db in
      try Node.insert { visible }.execute(db)
      for m in muted { try Node.insert { m }.execute(db) }
    }
    let s = try indexed(db)

    let hits = RelatedQueries.search(query: "refunds pipeline", visibleNodeIDs: [visible.id],
                                     excludingIDs: [], k: 2, store: s, db)
    #expect(hits.contains { $0.nodeID == visible.id })
  }

  @Test func excludedIDsAreDropped() async throws {
    let db = try openCanonicalDatabase(at: tempURL("relq-exclude"))
    let a = Node(name: "Refunds alpha", kind: NodeKind.project)
    let b = Node(name: "Refunds beta", kind: NodeKind.project)
    try await db.write { db in
      try Node.insert { a }.execute(db)
      try Node.insert { b }.execute(db)
    }
    let s = try indexed(db)

    let hits = RelatedQueries.search(query: "refunds", visibleNodeIDs: [a.id, b.id],
                                     excludingIDs: [a.id], k: 5, store: s, db)
    #expect(hits.map { $0.id } == [b.id])
  }

  @Test func archivedNodesSurfaceOnlyWhenAskedAndAreBadged() async throws {
    let db = try openCanonicalDatabase(at: tempURL("relq-archived"))
    let active = Node(name: "Refunds active", kind: NodeKind.project)
    let archived = Node(name: "Refunds archived", state: .archived, kind: NodeKind.project)
    try await db.write { db in
      try Node.insert { active }.execute(db)
      try Node.insert { archived }.execute(db)
    }
    let s = try indexed(db)
    let visible: Set<UUID> = [active.id, archived.id]

    let strict = RelatedQueries.search(query: "refunds", visibleNodeIDs: visible,
                                       excludingIDs: [], k: 5, store: s, db)
    #expect(strict.map { $0.id } == [active.id])

    let wide = RelatedQueries.search(query: "refunds", visibleNodeIDs: visible, excludingIDs: [],
                                     k: 5, includeArchived: true, store: s, db)
    #expect(Set(wide.map { $0.id }) == visible)
    #expect(wide.first { $0.id == archived.id }?.isArchived == true)
    #expect(wide.first { $0.id == active.id }?.isArchived == false)
  }

  /// The last grounding defense: a row that is still in the index but no longer in the live corpus
  /// must not surface. Index first, then close the loose end WITHOUT rebuilding.
  @Test func aStaleIndexRowNeverSurfacesAsALiveHit() async throws {
    let db = try openCanonicalDatabase(at: tempURL("relq-stale"))
    let n = Node(name: "Billing", kind: NodeKind.project)
    try await db.write { try Node.insert { n }.execute($0) }
    let ev = try makeRelatedEvent(db, node: n, kind: CaptureKind.ccSession,
                                  summary: "session", workSummary: "worked on invoices")
    let le = LooseEnd(nodeID: n.id, sourceEventID: ev.id,
                      text: "drop the legacy refunds table", quote: "TODO drop refunds")
    try await db.write { try LooseEnd.insert { le }.execute($0) }
    let s = try indexed(db)
    #expect(RelatedQueries.search(query: "refunds", visibleNodeIDs: [n.id],
                                  excludingIDs: [], k: 5, store: s, db).contains { $0.id == le.id })

    try await db.write { db in
      try LooseEnd.where { $0.id.eq(le.id) }.update { $0.status = "closed" }.execute(db)
    }
    let after = RelatedQueries.search(query: "refunds", visibleNodeIDs: [n.id],
                                      excludingIDs: [], k: 5, store: s, db)
    #expect(!after.contains { $0.id == le.id })   // index still holds it; canonical re-check drops it
  }

  /// Loose ends and events resolve to their own titles/snippets, not their node's.
  @Test func resolvesLooseEndsAndEventsWithTheirOwnText() async throws {
    let db = try openCanonicalDatabase(at: tempURL("relq-kinds"))
    let n = Node(name: "Billing", kind: NodeKind.project)
    try await db.write { try Node.insert { n }.execute($0) }
    let ev = try makeRelatedEvent(db, node: n, kind: CaptureKind.ccSession,
                                  summary: "session", workSummary: "rewrote the dunning emails")
    let le = LooseEnd(nodeID: n.id, sourceEventID: ev.id,
                      text: "verify the dunning schedule", quote: "check dunning")
    try await db.write { try LooseEnd.insert { le }.execute($0) }
    let s = try indexed(db)

    let hits = RelatedQueries.search(query: "dunning", visibleNodeIDs: [n.id],
                                     excludingIDs: [], k: 5, store: s, db)
    #expect(hits.first { $0.kind == "loose_end" }?.title == "verify the dunning schedule")
    #expect(hits.first { $0.kind == "event" }?.title == "rewrote the dunning emails")
    #expect(hits.allSatisfy { $0.nodeName == "Billing" })
  }

  @Test func shortOrEmptyQueriesReturnNothing() async throws {
    let db = try openCanonicalDatabase(at: tempURL("relq-short"))
    let n = Node(name: "Refunds", kind: NodeKind.project)
    try await db.write { try Node.insert { n }.execute($0) }
    let s = try indexed(db)

    #expect(RelatedQueries.search(query: "r", visibleNodeIDs: [n.id],
                                  excludingIDs: [], k: 5, store: s, db).isEmpty)
    #expect(RelatedQueries.search(query: "   ", visibleNodeIDs: [n.id],
                                  excludingIDs: [], k: 5, store: s, db).isEmpty)
  }

  /// Best-effort: an unavailable index degrades to no related results, never a throw. (`/dev/null`
  /// is a character device, so no directory can be created under it and the store's
  /// delete-and-retry recovery cannot rescue the path — see TextIndexStoreTests.)
  @Test func anUnavailableStoreReturnsNothing() async throws {
    let db = try openCanonicalDatabase(at: tempURL("relq-unavailable"))
    let n = Node(name: "Refunds", kind: NodeKind.project)
    try await db.write { try Node.insert { n }.execute($0) }
    let dead = TextIndexStore(url: URL(fileURLWithPath: "/dev/null/nope/text-index.sqlite"))

    #expect(RelatedQueries.search(query: "refunds", visibleNodeIDs: [n.id], excludingIDs: [],
                                  k: 5, store: dead, db).isEmpty)
  }

  @Test func resultsAreOrderedBestFirstAndCappedAtK() async throws {
    let db = try openCanonicalDatabase(at: tempURL("relq-order"))
    let strong = Node(name: "background sync agent login items", kind: NodeKind.project)
    let weak = Node(name: "sync notes", kind: NodeKind.project)
    let other = Node(name: "sync inbox", kind: NodeKind.project)
    try await db.write { db in
      try Node.insert { strong }.execute(db)
      try Node.insert { weak }.execute(db)
      try Node.insert { other }.execute(db)
    }
    let s = try indexed(db)
    let visible: Set<UUID> = [strong.id, weak.id, other.id]

    let hits = RelatedQueries.search(query: "background sync login", visibleNodeIDs: visible,
                                     excludingIDs: [], k: 2, store: s, db)
    #expect(hits.count == 2)
    #expect(hits.first?.id == strong.id)
    #expect(hits[0].similarity >= hits[1].similarity)
  }
}
