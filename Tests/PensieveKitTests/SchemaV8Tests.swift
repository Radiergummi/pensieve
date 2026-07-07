import Foundation
import Testing
import SQLiteData
@testable import PensieveKit

@Test func v8AddsAppearanceColumnsWithDefaults() throws {
  let db = try openCanonicalDatabase(at: tempURL("v8"))
  let node = Node(name: "Colibri")
  try db.write { db in try Node.insert { node }.execute(db) }

  // New rows default to empty appearance strings ("" == "use the kind default").
  let stored = try db.read { db in try Node.where { $0.id.eq(node.id) }.fetchOne(db) }
  #expect(stored?.icon == "")
  #expect(stored?.colorTag == "")

  // Non-empty values round-trip through the STRICT columns.
  try db.write { db in
    try Node.where { $0.id.eq(node.id) }.update {
      $0.icon = "emoji:🚀"
      $0.colorTag = "teal"
    }.execute(db)
  }
  let updated = try db.read { db in try Node.where { $0.id.eq(node.id) }.fetchOne(db) }
  #expect(updated?.icon == "emoji:🚀")
  #expect(updated?.colorTag == "teal")
}
