import Foundation
import Testing
import SQLiteData
@testable import PensieveKit

@Test func v7AddsWatermarkColumnsWithDefaults() throws {
  let database = try openCanonicalDatabase(at: tempURL("v7"))
  let node = Node(name: "Colibri")
  let source = Source(nodeID: node.id, kind: SourceKind.claudeCode, key: "/p/colibri")
  let event = Event(nodeID: node.id, sourceID: source.id, occurredAt: Date(),
                    kind: CaptureKind.ccSession, summary: "s", detailJSON: "{}",
                    fingerprint: "fp-v7")
  try database.write { database in
    try Node.insert { node }.execute(database)
    try Source.insert { source }.execute(database)
    try Event.insert { event }.execute(database)
  }
  // New rows default to 0 messages and the -1 "never watermarked" sentinel for the size.
  let storedEvent = try database.read { database in try Event.all.fetchAll(database) }.first
  #expect(storedEvent?.extractedMessageCount == 0)
  #expect(storedEvent?.extractedTranscriptSize == -1)

  // Non-zero values round-trip through the STRICT columns.
  try database.write { database in
    try Event.where { $0.id.eq(event.id) }.update {
      $0.extractedMessageCount = 5
      $0.extractedTranscriptSize = 1234
    }.execute(database)
  }
  let updated = try database.read { database in try Event.all.fetchAll(database) }.first
  #expect(updated?.extractedMessageCount == 5)
  #expect(updated?.extractedTranscriptSize == 1234)
}
