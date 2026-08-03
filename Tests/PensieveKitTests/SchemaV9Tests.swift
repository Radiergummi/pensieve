import Foundation
import Testing
import SQLiteData
@testable import PensieveKit

@Test func v9AddsContextColumnWithDefault() throws {
  let database = try openCanonicalDatabase(at: tempURL("v9"))
  let node = Node(name: "Colibri")
  try database.write { database in try Node.insert { node }.execute(database) }

  // New rows default to "" (== unset / inherit).
  let stored = try database.read { database in try Node.where { $0.id.eq(node.id) }.fetchOne(database) }
  #expect(stored?.context == "")

  // A non-empty value round-trips through the STRICT column.
  try database.write { database in
    try Node.where { $0.id.eq(node.id) }.update { $0.context = "work" }.execute(database)
  }
  let updated = try database.read { database in try Node.where { $0.id.eq(node.id) }.fetchOne(database) }
  #expect(updated?.context == "work")
}
