import Foundation
import Testing
import SQLiteData
@testable import PensieveKit

@Test func v10AddsWorkSummaryColumnNullableByDefault() throws {
  let database = try openCanonicalDatabase(at: tempURL("v10"))
  let node = Node(name: "Pensieve")
  let source = Source(nodeID: node.id, kind: SourceKind.claudeCode, key: "/tmp/pensieve")
  try database.write { database in
    try Node.insert { node }.execute(database)
    try Source.insert { source }.execute(database)
  }
  let event = Event(nodeID: node.id, sourceID: source.id, occurredAt: Date(),
                    kind: CaptureKind.ccSession, summary: "session (3 prompts)", detailJSON: "{}")
  try database.write { database in try Event.insert { event }.execute(database) }

  // New rows read nil (never enriched yet).
  let stored = try database.read { database in try Event.where { $0.id.eq(event.id) }.fetchOne(database) }
  #expect(stored?.workSummary == nil)

  // A value round-trips through the nullable column.
  try database.write { database in
    try Event.where { $0.id.eq(event.id) }.update { $0.workSummary = #bind("Built the sync daemon.") }.execute(database)
  }
  let updated = try database.read { database in try Event.where { $0.id.eq(event.id) }.fetchOne(database) }
  #expect(updated?.workSummary == "Built the sync daemon.")
}
