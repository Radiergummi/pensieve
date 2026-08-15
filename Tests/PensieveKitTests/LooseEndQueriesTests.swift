import Foundation
import Testing
import SQLiteData
@testable import PensieveKit

@Test func openLooseEndsCarrySourceAge() throws {
  let database = try openCanonicalDatabase(at: tempURL("looseEnd-q"))
  let (project, source) = try ProjectResolver(database: database).resolve(path: "/p/x", kind: SourceKind.claudeCode)
  let occurred = Calendar.current.date(byAdding: .day, value: -10, to: Date())!
  let event = Event(nodeID: project.id, sourceID: source.id, occurredAt: occurred,
                    kind: CaptureKind.ccSession, summary: "s", detailJSON: "{}", fingerprint: "f")
  try database.write { database in
    try Event.insert { event }.execute(database)
    try LooseEnd.insert {
      LooseEnd(nodeID: project.id, sourceEventID: event.id, text: "t",
               quote: "we still need to finish the migration", role: "user", sourceMessageIndex: 0)
    }.execute(database)
  }
  let views = try LooseEndQueries.open(database, nodeID: project.id, now: Date())
  #expect(views.count == 1)
  #expect(views.first?.ageDays == 10)
}

@Test func openExcludesConfirmedNoiseButKeepsSalientUnlabeledAndSuggested() throws {
  let database = try openCanonicalDatabase(at: tempURL("open-filter"))
  let node = Node(name: "N")
  // Full FK chain: looseEnds.sourceEventID -> events.id -> sources.id.
  let source = Source(nodeID: node.id, kind: SourceKind.claudeCode, key: "/src/\(UUID().uuidString)")
  let src = Event(nodeID: node.id, sourceID: source.id, occurredAt: Date(),
                  kind: CaptureKind.ccSession, summary: "s", detailJSON: "{}")
  try database.write { database in
    try Node.insert { node }.execute(database)
    try Source.insert { source }.execute(database)
    try Event.insert { src }.execute(database)
  }
  func add(_ quote: String, label: String = "", suggestion: String = "") throws -> UUID {
    let looseEnd = LooseEnd(nodeID: node.id, sourceEventID: src.id, text: quote, quote: quote,
                      label: label, labelSuggestion: suggestion)
    try database.write { database in try LooseEnd.insert { looseEnd }.execute(database) }
    return looseEnd.id
  }
  _ = try add("unlabeled item")
  _ = try add("confirmed salient", label: LooseEndLabel.salient)
  _ = try add("confirmed noise", label: LooseEndLabel.noise)               // excluded
  _ = try add("only suggested noise", suggestion: LooseEndLabel.noise)     // kept (suggestion != decision)

  let open = try LooseEndQueries.open(database, nodeID: node.id, now: Date())
  let texts = Set(open.map { $0.looseEnd.text })
  #expect(texts == ["unlabeled item", "confirmed salient", "only suggested noise"])
  #expect(!texts.contains("confirmed noise"))
}

/// Each loose end must carry ITS OWN source event's date, including when several share one event and
/// the events are inserted out of date order.
///
/// This is a refactor guard, and it is aimed at one specific way of getting batching wrong. The
/// sibling test above already happens to put four loose ends on one event, but it asserts only WHICH
/// rows come back — so an implementation that fetched the distinct events in one query and then
/// zipped them onto the ends positionally would pass everything previously green while silently
/// pairing ends with the wrong dates. `ageDays` is the field that would lie, and it is what the
/// What's Next ranking, the triage feed and the detail pane all read.
///
/// Mutation-verified: a positional-zip implementation fails this; the shipped per-row loop and a
/// correct id-keyed batch both pass.
@Test func eachLooseEndResolvesItsOwnSourceEvent() throws {
  let database = try openCanonicalDatabase(at: tempURL("loose-end-event-mapping"))
  let node = Node(name: "N")
  let source = Source(nodeID: node.id, kind: SourceKind.claudeCode, key: "/src/\(UUID().uuidString)")
  // Deliberately NOT in date order, and `recent` is shared by two ends: an implementation that
  // pairs sorted-by-something events against sorted-by-something-else ends must not survive.
  let old = Event(nodeID: node.id, sourceID: source.id,
                  occurredAt: Calendar.current.date(byAdding: .day, value: -30, to: Date())!,
                  kind: CaptureKind.ccSession, summary: "old", detailJSON: "{}")
  let recent = Event(nodeID: node.id, sourceID: source.id,
                     occurredAt: Calendar.current.date(byAdding: .day, value: -2, to: Date())!,
                     kind: CaptureKind.ccSession, summary: "recent", detailJSON: "{}")
  try database.write { database in
    try Node.insert { node }.execute(database)
    try Source.insert { source }.execute(database)
    try Event.insert { recent }.execute(database)   // inserted before `old` on purpose
    try Event.insert { old }.execute(database)
    try LooseEnd.insert {
      LooseEnd(nodeID: node.id, sourceEventID: old.id, text: "from the old event", quote: "q1")
    }.execute(database)
    try LooseEnd.insert {
      LooseEnd(nodeID: node.id, sourceEventID: recent.id, text: "from the recent event", quote: "q2")
    }.execute(database)
    try LooseEnd.insert {
      LooseEnd(nodeID: node.id, sourceEventID: recent.id, text: "also from the recent event", quote: "q3")
    }.execute(database)
  }

  let views = try LooseEndQueries.open(database, nodeID: node.id, now: Date())
  let ageByText = Dictionary(uniqueKeysWithValues: views.map { ($0.looseEnd.text, $0.ageDays) })
  #expect(ageByText == ["from the old event": 30,
                        "from the recent event": 2,
                        "also from the recent event": 2])
}
