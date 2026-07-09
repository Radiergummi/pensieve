import Foundation
import Testing
import SQLiteData
@testable import PensieveKit

@Test func v11AddsLabelColumnsDefaultingToEmpty() throws {
  let db = try openCanonicalDatabase(at: tempURL("v11"))
  let node = Node(name: "Pensieve")
  let src = Source(nodeID: node.id, kind: SourceKind.gitRepo, key: "/p/pensieve/.git")
  let ev = Event(nodeID: node.id, sourceID: src.id, occurredAt: Date(),
                 kind: CaptureKind.gitCommit, summary: "x", detailJSON: "{}",
                 fingerprint: Fingerprint.commit(hash: "abc"))
  try db.write { db in
    try Node.insert { node }.execute(db)
    try Source.insert { src }.execute(db)
    try Event.insert { ev }.execute(db)
  }
  let le = LooseEnd(nodeID: node.id, sourceEventID: ev.id, text: "migrate auth later",
                    quote: "we should migrate the auth tables later")
  try db.write { db in try LooseEnd.insert { le }.execute(db) }

  // New rows default to "" (unlabeled), never NULL.
  let stored = try db.read { db in try LooseEnd.where { $0.id.eq(le.id) }.fetchOne(db) }
  #expect(stored?.label == "")
  #expect(stored?.labelSuggestion == "")

  // Values round-trip.
  try db.write { db in
    try LooseEnd.where { $0.id.eq(le.id) }
      .update { $0.label = LooseEndLabel.salient; $0.labelSuggestion = LooseEndLabel.noise }
      .execute(db)
  }
  let updated = try db.read { db in try LooseEnd.where { $0.id.eq(le.id) }.fetchOne(db) }
  #expect(updated?.label == "salient")
  #expect(updated?.labelSuggestion == "noise")
}
