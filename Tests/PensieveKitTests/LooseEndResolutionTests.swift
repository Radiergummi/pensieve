import Foundation
import Testing
import SQLiteData
@testable import PensieveKit

/// Seeds one node + source + event + loose end, and returns the loose end's id.
/// File-private on purpose: two other suites already declare a `seedLooseEnd`, and an internal one
/// here would make the call ambiguous in those files.
@discardableResult
private func seedLooseEnd(_ database: any DatabaseWriter, text: String = "t", quote: String = "q",
                          status: LooseEndStatus = .open, label: String = "",
                          resolvedAt: Date? = nil, daysAgo: Int = 0) throws -> UUID {
  let node = Node(name: "N")
  let source = Source(nodeID: node.id, kind: SourceKind.claudeCode, key: "/src/\(UUID().uuidString)")
  let when = Calendar.current.date(byAdding: .day, value: -daysAgo, to: Date())!
  let event = Event(nodeID: node.id, sourceID: source.id, occurredAt: when,
                    kind: CaptureKind.ccSession, summary: "s", detailJSON: "{}")
  let looseEnd = LooseEnd(nodeID: node.id, sourceEventID: event.id, text: text, quote: quote,
                          status: status, label: label, resolvedAt: resolvedAt)
  try database.write { database in
    try Node.insert { node }.execute(database)
    try Source.insert { source }.execute(database)
    try Event.insert { event }.execute(database)
    try LooseEnd.insert { looseEnd }.execute(database)
  }
  return looseEnd.id
}

@Test func looseEndStatusRoundTripsThroughTheStore() throws {
  let database = try openCanonicalDatabase(at: tempURL("les-roundtrip"))
  let openID = try seedLooseEnd(database, quote: "still open")
  let doneID = try seedLooseEnd(database, quote: "finished", status: .done)
  let droppedID = try seedLooseEnd(database, quote: "abandoned", status: .dropped)
  let stored = try database.read { try LooseEnd.all.fetchAll($0) }
  #expect(stored.first { $0.id == openID }?.status == .open)
  #expect(stored.first { $0.id == doneID }?.status == .done)
  #expect(stored.first { $0.id == droppedID }?.status == .dropped)
}

/// The on-disk spelling must stay exactly what the shipped store holds, so no migration is needed
/// for the type change. Reads the raw column, deliberately bypassing the enum.
@Test func looseEndStatusStoresItsRawStringUnchanged() throws {
  let database = try openCanonicalDatabase(at: tempURL("les-raw"))
  try seedLooseEnd(database, quote: "open one")
  try seedLooseEnd(database, quote: "done one", status: .done)
  let raw = try database.read { database in
    try String.fetchAll(database, sql: #"SELECT "status" FROM "looseEnds" ORDER BY "status""#)
  }
  #expect(raw == ["done", "open"])
}

/// The whole feature rests on this: `isOpen` was not edited, and the new states fall out of it.
@Test func isOpenExcludesDoneAndDroppedWithoutBeingEdited() throws {
  let database = try openCanonicalDatabase(at: tempURL("les-isopen"))
  let openID = try seedLooseEnd(database, quote: "open one")
  try seedLooseEnd(database, quote: "done one", status: .done)
  try seedLooseEnd(database, quote: "dropped one", status: .dropped)
  try seedLooseEnd(database, quote: "noisy one", label: LooseEndLabel.noise)
  let open = try database.read { try LooseEnd.where { LooseEnd.isOpen($0) }.fetchAll($0) }
  #expect(open.map(\.id) == [openID])
}

@Test func resolvedAtDefaultsToNilAndPersists() throws {
  let database = try openCanonicalDatabase(at: tempURL("les-resolvedat"))
  let stamp = Date(timeIntervalSince1970: 1_700_000_000)
  try seedLooseEnd(database, quote: "never resolved")
  try seedLooseEnd(database, quote: "resolved", status: .done, resolvedAt: stamp)
  let stored = try database.read { try LooseEnd.all.fetchAll($0) }
  #expect(stored.filter { $0.resolvedAt == nil }.count == 1)
  #expect(stored.compactMap(\.resolvedAt).first.map { Int($0.timeIntervalSince1970) } == 1_700_000_000)
}

@Test func resolveStampsResolvedAtAndClearsItOnReopen() throws {
  let database = try openCanonicalDatabase(at: tempURL("les-resolve"))
  let id = try seedLooseEnd(database, quote: "work item")
  let closedAt = Date(timeIntervalSince1970: 1_700_000_000)

  #expect(try LooseEndCommands.resolve(database, id: id, status: .done, now: closedAt))
  var stored = try database.read { try LooseEnd.where { $0.id.eq(id) }.fetchOne($0) }
  #expect(stored?.status == .done)
  #expect(stored?.resolvedAt.map { Int($0.timeIntervalSince1970) } == 1_700_000_000)

  #expect(try LooseEndCommands.resolve(database, id: id, status: .open, now: Date()))
  stored = try database.read { try LooseEnd.where { $0.id.eq(id) }.fetchOne($0) }
  #expect(stored?.status == .open)
  #expect(stored?.resolvedAt == nil)   // a reopened end is indistinguishable from one never closed
}

@Test func resolveRefusesAnUnknownLooseEndWithoutWriting() throws {
  let database = try openCanonicalDatabase(at: tempURL("les-resolve-unknown"))
  let id = try seedLooseEnd(database, quote: "real one")
  #expect(try LooseEndCommands.resolve(database, id: UUID(), status: .done) == false)
  let stored = try database.read { try LooseEnd.where { $0.id.eq(id) }.fetchOne($0) }
  #expect(stored?.status == .open)     // the real row is untouched
}

@Test func resolveSwitchesBetweenDoneAndDroppedAndRestamps() throws {
  let database = try openCanonicalDatabase(at: tempURL("les-resolve-flip"))
  let id = try seedLooseEnd(database, quote: "flip me")
  let first = Date(timeIntervalSince1970: 1_700_000_000)
  let second = Date(timeIntervalSince1970: 1_700_009_999)
  #expect(try LooseEndCommands.resolve(database, id: id, status: .done, now: first))
  #expect(try LooseEndCommands.resolve(database, id: id, status: .dropped, now: second))
  let stored = try database.read { try LooseEnd.where { $0.id.eq(id) }.fetchOne($0) }
  #expect(stored?.status == .dropped)
  #expect(stored?.resolvedAt.map { Int($0.timeIntervalSince1970) } == 1_700_009_999)
}

/// Seeds a node in a given state with one loose end, returning both ids.
private func seedIn(_ database: any DatabaseWriter, nodeState: NodeState,
                    status: LooseEndStatus, resolvedAt: Date? = nil, label: String = "",
                    suggestion: String = "", daysAgo: Int = 0) throws -> (node: UUID, looseEnd: UUID) {
  let node = Node(name: "N", state: nodeState)
  let source = Source(nodeID: node.id, kind: SourceKind.claudeCode, key: "/src/\(UUID().uuidString)")
  let when = Calendar.current.date(byAdding: .day, value: -daysAgo, to: Date())!
  let event = Event(nodeID: node.id, sourceID: source.id, occurredAt: when,
                    kind: CaptureKind.ccSession, summary: "s", detailJSON: "{}")
  let looseEnd = LooseEnd(nodeID: node.id, sourceEventID: event.id, text: "t", quote: "q",
                          status: status, label: label, labelSuggestion: suggestion,
                          resolvedAt: resolvedAt)
  try database.write { database in
    try Node.insert { node }.execute(database)
    try Source.insert { source }.execute(database)
    try Event.insert { event }.execute(database)
    try LooseEnd.insert { looseEnd }.execute(database)
  }
  return (node.id, looseEnd.id)
}

@Test func openAcrossNodesIsOldestFirstAndActiveVisibleOnly() throws {
  let database = try openCanonicalDatabase(at: tempURL("les-feed-open"))
  let newer = try seedIn(database, nodeState: .active, status: .open, daysAgo: 1)
  let older = try seedIn(database, nodeState: .active, status: .open, daysAgo: 30)
  let archived = try seedIn(database, nodeState: .archived, status: .open, daysAgo: 10)
  let muted = try seedIn(database, nodeState: .muted, status: .open, daysAgo: 10)
  let hidden = try seedIn(database, nodeState: .active, status: .open, daysAgo: 5)
  try seedIn(database, nodeState: .active, status: .done, daysAgo: 2)   // closed: never in this feed

  let visible: Set<UUID> = [newer.node, older.node, archived.node, muted.node]
  let feed = try LooseEndQueries.openAcrossNodes(database, visibleNodeIDs: visible, now: Date())
  #expect(feed.map(\.looseEnd.id) == [older.looseEnd, newer.looseEnd])   // oldest source first
  #expect(!feed.map(\.looseEnd.id).contains(archived.looseEnd))          // archived node excluded
  #expect(!feed.map(\.looseEnd.id).contains(muted.looseEnd))             // muted node excluded
  #expect(!feed.map(\.looseEnd.id).contains(hidden.looseEnd))            // outside the Focus set
}

/// The measured reason the queue is not pure oldest-first: a machine-suggested-salient item leads,
/// so the scarce positives come forward instead of grinding through the oldest three repos.
@Test func openAcrossNodesLeadsWithSuggestedSalient() throws {
  let database = try openCanonicalDatabase(at: tempURL("les-feed-salient"))
  let olderPlain = try seedIn(database, nodeState: .active, status: .open, daysAgo: 30)
  let newerSuggested = try seedIn(database, nodeState: .active, status: .open,
                                  suggestion: LooseEndLabel.salient, daysAgo: 1)
  let visible: Set<UUID> = [olderPlain.node, newerSuggested.node]
  let feed = try LooseEndQueries.openAcrossNodes(database, visibleNodeIDs: visible, now: Date())
  #expect(feed.map(\.looseEnd.id) == [newerSuggested.looseEnd, olderPlain.looseEnd])
}

@Test func closedAcrossNodesIsMostRecentlyResolvedFirst() throws {
  let database = try openCanonicalDatabase(at: tempURL("les-feed-closed"))
  let old = try seedIn(database, nodeState: .active, status: .done,
                       resolvedAt: Date(timeIntervalSince1970: 1_700_000_000))
  let recent = try seedIn(database, nodeState: .active, status: .dropped,
                          resolvedAt: Date(timeIntervalSince1970: 1_700_009_999))
  let stillOpen = try seedIn(database, nodeState: .active, status: .open)

  let visible: Set<UUID> = [old.node, recent.node, stillOpen.node]
  let feed = try LooseEndQueries.closedAcrossNodes(database, visibleNodeIDs: visible, now: Date())
  #expect(feed.map(\.looseEnd.id) == [recent.looseEnd, old.looseEnd])
}

@Test func closedForOneNodeReturnsOnlyThatNodesClosedEnds() throws {
  let database = try openCanonicalDatabase(at: tempURL("les-feed-node"))
  let mine = try seedIn(database, nodeState: .active, status: .done,
                        resolvedAt: Date(timeIntervalSince1970: 1_700_000_000))
  let other = try seedIn(database, nodeState: .active, status: .done,
                         resolvedAt: Date(timeIntervalSince1970: 1_700_000_500))
  let openOnMine = try database.write { database -> UUID in
    let looseEnd = LooseEnd(nodeID: mine.node,
                            sourceEventID: try Event.where { $0.nodeID.eq(mine.node) }
                              .fetchOne(database)!.id,
                            text: "t", quote: "open", status: .open)
    try LooseEnd.insert { looseEnd }.execute(database)
    return looseEnd.id
  }
  let feed = try LooseEndQueries.closed(database, nodeID: mine.node, now: Date())
  #expect(feed.map(\.looseEnd.id) == [mine.looseEnd])
  #expect(!feed.map(\.looseEnd.id).contains(other.looseEnd))
  #expect(!feed.map(\.looseEnd.id).contains(openOnMine))
}

/// A 👎 item the user declared was never a loose end has no place in a record of their own work.
/// Both closed feeds must exclude it — the per-node one and the cross-node one.
@Test func bothClosedFeedsExcludeNoiseLabelledEnds() throws {
  let database = try openCanonicalDatabase(at: tempURL("les-feed-noise"))
  let kept = try seedIn(database, nodeState: .active, status: .done,
                        resolvedAt: Date(timeIntervalSince1970: 1_700_000_000))
  let noisy = try seedIn(database, nodeState: .active, status: .done,
                         resolvedAt: Date(timeIntervalSince1970: 1_700_009_999),
                         label: LooseEndLabel.noise)
  let across = try LooseEndQueries.closedAcrossNodes(database, visibleNodeIDs: [kept.node, noisy.node],
                                                     now: Date())
  #expect(across.map(\.looseEnd.id) == [kept.looseEnd])
  #expect(try LooseEndQueries.closed(database, nodeID: noisy.node, now: Date()).isEmpty)
}

/// The triage queue is a worklist, so it must show exactly what `isOpen` admits — a 👎 end the user
/// declared was never a loose end is not work. Pinned because `openViews` reads `isOpen` while the
/// closed feeds spell the two halves out separately; nothing else would catch them diverging.
@Test func openAcrossNodesExcludesNoiseLabelledEnds() throws {
  let database = try openCanonicalDatabase(at: tempURL("les-feed-open-noise"))
  let real = try seedIn(database, nodeState: .active, status: .open)
  let noisy = try seedIn(database, nodeState: .active, status: .open, label: LooseEndLabel.noise)
  let feed = try LooseEndQueries.openAcrossNodes(database, visibleNodeIDs: [real.node, noisy.node],
                                                now: Date())
  #expect(feed.map(\.looseEnd.id) == [real.looseEnd])
}

/// The count the sidebar shows and the feed the column renders must agree, or the badge lies about
/// the list beneath it. They are different queries (one counts, one joins events), so this pins them.
@Test func theTriageCountMatchesTheTriageFeed() throws {
  let database = try openCanonicalDatabase(at: tempURL("les-count"))
  let first = try seedIn(database, nodeState: .active, status: .open)
  let second = try seedIn(database, nodeState: .active, status: .open)
  try seedIn(database, nodeState: .active, status: .open, label: LooseEndLabel.noise)
  try seedIn(database, nodeState: .active, status: .done)
  try seedIn(database, nodeState: .archived, status: .open)
  let visible = Set(try database.read { try Node.all.fetchAll($0) }.map(\.id))
  let feed = try LooseEndQueries.openAcrossNodes(database, visibleNodeIDs: visible, now: Date())
  let count = try LooseEndQueries.openCountAcrossNodes(database, visibleNodeIDs: visible)
  #expect(feed.count == 2)
  #expect(count == feed.count)
  #expect(Set(feed.map(\.looseEnd.id)) == [first.looseEnd, second.looseEnd])
}

/// Bulk close must close exactly what the confirmation dialog counted. The dialog reads
/// `NodeRowFacts.openLooseEnds` (= `openSQLPredicate`, which excludes 👎), so closing by `status`
/// alone made a node with one real and three 👎 open ends say "Close 1" and close 4 — and the three
/// then showed on no surface at all, since both closed feeds exclude noise.
@Test func bulkCloseClosesOnlyWhatTheOpenCountPromised() throws {
  let database = try openCanonicalDatabase(at: tempURL("les-bulk-noise"))
  let node = Node(name: "N")
  let source = Source(nodeID: node.id, kind: SourceKind.claudeCode, key: "/src/\(UUID().uuidString)")
  let event = Event(nodeID: node.id, sourceID: source.id, occurredAt: Date(),
                    kind: CaptureKind.ccSession, summary: "s", detailJSON: "{}")
  let real = LooseEnd(nodeID: node.id, sourceEventID: event.id, text: "real", quote: "real")
  let noisy = LooseEnd(nodeID: node.id, sourceEventID: event.id, text: "noise", quote: "noise",
                       label: LooseEndLabel.noise)
  try database.write { database in
    try Node.insert { node }.execute(database)
    try Source.insert { source }.execute(database)
    try Event.insert { event }.execute(database)
    try LooseEnd.insert { real }.execute(database)
    try LooseEnd.insert { noisy }.execute(database)
  }
  let promised = try NodeFactsQueries.rowFacts(database)[node.id]?.openLooseEnds
  let closed = try LooseEndCommands.resolveAllOpen(database, nodeID: node.id, status: .done)
  #expect(promised == 1)
  #expect(closed == [real.id])
  let stored = try database.read { try LooseEnd.all.fetchAll($0) }
  #expect(stored.first { $0.id == noisy.id }?.status == .open)   // left alone, still reachable
}

/// Undo restores the PAIR, not just the status: `resolve` derives the stamp from the target status, so
/// without an explicit override an undone done→dropped flip re-stamped `resolvedAt` to now and pinned
/// week-old work to the top of the Completed feed, which orders on that column.
@Test func restoringAResolvedAtPutsTheOriginalStampBack() throws {
  let database = try openCanonicalDatabase(at: tempURL("les-restore-stamp"))
  let original = Date(timeIntervalSince1970: 1_700_000_000)
  let id = try seedLooseEnd(database, quote: "finished last week", status: .done,
                            resolvedAt: original)

  // The flip stamps "now"…
  #expect(try LooseEndCommands.resolve(database, id: id, status: .dropped,
                                       now: Date(timeIntervalSince1970: 1_800_000_000)))
  // …and the undo puts the original stamp back, not another "now".
  #expect(try LooseEndCommands.resolve(database, id: id, status: .done,
                                       now: Date(timeIntervalSince1970: 1_900_000_000),
                                       restoringResolvedAt: original))
  let stored = try database.read { try LooseEnd.where { $0.id.eq(id) }.fetchOne($0) }
  #expect(stored?.status == .done)
  #expect(stored?.resolvedAt.map { Int($0.timeIntervalSince1970) } == 1_700_000_000)
}

/// Reopening ignores a restore stamp: an open end with a `resolvedAt` would be a row claiming to be
/// both live and finished, and every feed reads the pair.
@Test func reopeningIgnoresARestoreStampAndClearsTheColumn() throws {
  let database = try openCanonicalDatabase(at: tempURL("les-restore-open"))
  let id = try seedLooseEnd(database, quote: "was done", status: .done,
                            resolvedAt: Date(timeIntervalSince1970: 1_700_000_000))
  #expect(try LooseEndCommands.resolve(database, id: id, status: .open,
                                       restoringResolvedAt: Date(timeIntervalSince1970: 1_700_000_000)))
  let stored = try database.read { try LooseEnd.where { $0.id.eq(id) }.fetchOne($0) }
  #expect(stored?.status == .open)
  #expect(stored?.resolvedAt == nil)
}

@Test func bulkCloseClosesOnlyThisNodesOpenEndsAndReportsThem() throws {
  let database = try openCanonicalDatabase(at: tempURL("les-bulk"))
  let mine = try seedIn(database, nodeState: .active, status: .open)
  let other = try seedIn(database, nodeState: .active, status: .open)
  let alreadyClosed = try database.write { database -> UUID in
    let event = try Event.where { $0.nodeID.eq(mine.node) }.fetchOne(database)!
    let looseEnd = LooseEnd(nodeID: mine.node, sourceEventID: event.id, text: "t", quote: "already",
                            status: .dropped,
                            resolvedAt: Date(timeIntervalSince1970: 1_700_000_000))
    try LooseEnd.insert { looseEnd }.execute(database)
    return looseEnd.id
  }

  let closed = try LooseEndCommands.resolveAllOpen(database, nodeID: mine.node, status: .done,
                                                   now: Date())
  #expect(closed == [mine.looseEnd])   // only the OPEN one, and only on this node

  let stored = try database.read { try LooseEnd.all.fetchAll($0) }
  #expect(stored.first { $0.id == other.looseEnd }?.status == .open)      // other node untouched
  #expect(stored.first { $0.id == alreadyClosed }?.status == .dropped)    // not re-stamped
  #expect(stored.first { $0.id == alreadyClosed }?.resolvedAt
            .map { Int($0.timeIntervalSince1970) } == 1_700_000_000)
}

/// Closing the last open end must remove a node from What's Next but NOT from Dormant — it is
/// finished, not neglected, and the two lists answer different questions.
@Test func closingTheLastEndLeavesWhatsNextButStaysDormant() throws {
  let database = try openCanonicalDatabase(at: tempURL("les-actionable"))
  let node = Node(name: "Finished")
  let source = Source(nodeID: node.id, kind: SourceKind.gitRepo, key: "/repo/\(UUID().uuidString)")
  let longAgo = Calendar.current.date(byAdding: .day, value: -40, to: Date())!
  let event = Event(nodeID: node.id, sourceID: source.id, occurredAt: longAgo,
                    kind: CaptureKind.gitCommit, summary: "s", detailJSON: "{}")
  let looseEnd = LooseEnd(nodeID: node.id, sourceEventID: event.id, text: "t", quote: "q")
  try database.write { database in
    try Node.insert { node }.execute(database)
    try Source.insert { source }.execute(database)
    try Event.insert { event }.execute(database)
    try LooseEnd.insert { looseEnd }.execute(database)
  }

  var lists = try SmartLists.compute(database, now: Date())
  #expect(lists.whatsNext.map(\.project.id).contains(node.id))
  #expect(lists.dormant.map(\.project.id).contains(node.id))

  #expect(try LooseEndCommands.resolve(database, id: looseEnd.id, status: .done))

  lists = try SmartLists.compute(database, now: Date())
  #expect(!lists.whatsNext.map(\.project.id).contains(node.id))   // nothing to pick up
  #expect(lists.dormant.map(\.project.id).contains(node.id))      // still quiet, still listed
}

@Test func rankedContextOmitsNodesWithNoOpenEnds() throws {
  let database = try openCanonicalDatabase(at: tempURL("les-ranked-context"))
  let withWork = try seedIn(database, nodeState: .active, status: .open, daysAgo: 5)
  let finished = try seedIn(database, nodeState: .active, status: .done, daysAgo: 5)
  let items = try SessionContextQueries.rankedContext(limit: 10, context: nil, database, now: Date())
  #expect(items.map(\.nodeID).contains(withWork.node))
  #expect(!items.map(\.nodeID).contains(finished.node))
}

/// THE test that guards the 123-node case. A git-only node never produces a loose end, so "no open
/// ends" cannot mean "finished" for it — it means never measured, and unmeasured work must keep
/// showing up. Without this, the naive predicate removes 130 of 162 nodes on day one.
@Test func aNodeThatNeverHadALooseEndStaysInWhatsNext() throws {
  let database = try openCanonicalDatabase(at: tempURL("les-never-measured"))
  let node = Node(name: "Git only")
  let source = Source(nodeID: node.id, kind: SourceKind.gitRepo, key: "/repo/\(UUID().uuidString)")
  let event = Event(nodeID: node.id, sourceID: source.id, occurredAt: Date(),
                    kind: CaptureKind.gitCommit, summary: "commit", detailJSON: "{}")
  try database.write { database in
    try Node.insert { node }.execute(database)
    try Source.insert { source }.execute(database)
    try Event.insert { event }.execute(database)
  }
  let lists = try SmartLists.compute(database, now: Date())
  #expect(lists.whatsNext.map(\.project.id).contains(node.id))
}
