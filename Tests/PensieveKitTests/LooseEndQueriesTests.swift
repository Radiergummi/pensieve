import Foundation
import Testing
import SQLiteData
@testable import PensieveKit

@Test func openLooseEndsCarrySourceAge() throws {
  let database = try openCanonicalDatabase(at: tempURL("le-q"))
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
    let le = LooseEnd(nodeID: node.id, sourceEventID: src.id, text: quote, quote: quote,
                      label: label, labelSuggestion: suggestion)
    try database.write { database in try LooseEnd.insert { le }.execute(database) }
    return le.id
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
