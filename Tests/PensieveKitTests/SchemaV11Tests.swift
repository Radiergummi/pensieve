import Foundation
import Testing
import SQLiteData
@testable import PensieveKit

@Test func v11AddsLabelColumnsDefaultingToEmpty() throws {
  let database = try openCanonicalDatabase(at: tempURL("v11"))
  let node = Node(name: "Pensieve")
  let src = Source(nodeID: node.id, kind: SourceKind.gitRepo, key: "/p/pensieve/.git")
  let ev = Event(nodeID: node.id, sourceID: src.id, occurredAt: Date(),
                 kind: CaptureKind.gitCommit, summary: "x", detailJSON: "{}",
                 fingerprint: Fingerprint.commit(hash: "abc"))
  try database.write { database in
    try Node.insert { node }.execute(database)
    try Source.insert { src }.execute(database)
    try Event.insert { ev }.execute(database)
  }
  let le = LooseEnd(nodeID: node.id, sourceEventID: ev.id, text: "migrate auth later",
                    quote: "we should migrate the auth tables later")
  try database.write { database in try LooseEnd.insert { le }.execute(database) }

  // New rows default to "" (unlabeled), never NULL.
  let stored = try database.read { database in try LooseEnd.where { $0.id.eq(le.id) }.fetchOne(database) }
  #expect(stored?.label == "")
  #expect(stored?.labelSuggestion == "")

  // Values round-trip.
  try database.write { database in
    try LooseEnd.where { $0.id.eq(le.id) }
      .update { $0.label = LooseEndLabel.salient; $0.labelSuggestion = LooseEndLabel.noise }
      .execute(database)
  }
  let updated = try database.read { database in try LooseEnd.where { $0.id.eq(le.id) }.fetchOne(database) }
  #expect(updated?.label == "salient")
  #expect(updated?.labelSuggestion == "noise")
}
