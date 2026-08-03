import Foundation
import Testing
import SQLiteData
@testable import PensieveKit

@Test func v8AddsAppearanceColumnsWithDefaults() throws {
  let database = try openCanonicalDatabase(at: tempURL("v8"))
  let node = Node(name: "Colibri")
  try database.write { database in try Node.insert { node }.execute(database) }

  // New rows default to empty appearance strings ("" == "use the kind default").
  let stored = try database.read { database in try Node.where { $0.id.eq(node.id) }.fetchOne(database) }
  #expect(stored?.icon == "")
  #expect(stored?.colorTag == "")

  // Non-empty values round-trip through the STRICT columns.
  try database.write { database in
    try Node.where { $0.id.eq(node.id) }.update {
      $0.icon = "emoji:🚀"
      $0.colorTag = "teal"
    }.execute(database)
  }
  let updated = try database.read { database in try Node.where { $0.id.eq(node.id) }.fetchOne(database) }
  #expect(updated?.icon == "emoji:🚀")
  #expect(updated?.colorTag == "teal")
}
