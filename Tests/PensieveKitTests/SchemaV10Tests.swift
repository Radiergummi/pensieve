import Foundation
import Testing
import SQLiteData
@testable import PensieveKit

@Test func v10AddsWorkSummaryColumnNullableByDefault() throws {
  let db = try openCanonicalDatabase(at: tempURL("v10"))
  let node = Node(name: "Pensieve")
  let source = Source(nodeID: node.id, kind: SourceKind.claudeCode, key: "/tmp/pensieve")
  try db.write { db in
    try Node.insert { node }.execute(db)
    try Source.insert { source }.execute(db)
  }
  let event = Event(nodeID: node.id, sourceID: source.id, occurredAt: Date(),
                    kind: CaptureKind.ccSession, summary: "session (3 prompts)", detailJSON: "{}")
  try db.write { db in try Event.insert { event }.execute(db) }

  // New rows read nil (never enriched yet).
  let stored = try db.read { db in try Event.where { $0.id.eq(event.id) }.fetchOne(db) }
  #expect(stored?.workSummary == nil)

  // A value round-trips through the nullable column.
  try db.write { db in
    try Event.where { $0.id.eq(event.id) }.update { $0.workSummary = #bind("Built the sync daemon.") }.execute(db)
  }
  let updated = try db.read { db in try Event.where { $0.id.eq(event.id) }.fetchOne(db) }
  #expect(updated?.workSummary == "Built the sync daemon.")
}
