import Foundation
import Testing
import SQLiteData
@testable import PensieveKit

@Test func v7AddsWatermarkColumnsWithDefaults() throws {
  let db = try openCanonicalDatabase(at: tempURL("v7"))
  let node = Node(name: "Colibri")
  let source = Source(nodeID: node.id, kind: SourceKind.claudeCode, key: "/p/colibri")
  let event = Event(nodeID: node.id, sourceID: source.id, occurredAt: Date(),
                    kind: CaptureKind.ccSession, summary: "s", detailJSON: "{}",
                    fingerprint: "fp-v7")
  try db.write { db in
    try Node.insert { node }.execute(db)
    try Source.insert { source }.execute(db)
    try Event.insert { event }.execute(db)
  }
  // New rows default to 0 for both watermark columns.
  let ev = try db.read { db in try Event.all.fetchAll(db) }.first
  #expect(ev?.extractedMessageCount == 0)
  #expect(ev?.extractedTranscriptSize == 0)

  // Non-zero values round-trip through the STRICT columns.
  try db.write { db in
    try Event.where { $0.id.eq(event.id) }.update {
      $0.extractedMessageCount = 5
      $0.extractedTranscriptSize = 1234
    }.execute(db)
  }
  let updated = try db.read { db in try Event.all.fetchAll(db) }.first
  #expect(updated?.extractedMessageCount == 5)
  #expect(updated?.extractedTranscriptSize == 1234)
}
