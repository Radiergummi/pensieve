import Foundation
import Testing
import SQLiteData
@testable import PensieveKit

@Test func v9AddsContextColumnWithDefault() throws {
  let db = try openCanonicalDatabase(at: tempURL("v9"))
  let node = Node(name: "Colibri")
  try db.write { db in try Node.insert { node }.execute(db) }

  // New rows default to "" (== unset / inherit).
  let stored = try db.read { db in try Node.where { $0.id.eq(node.id) }.fetchOne(db) }
  #expect(stored?.context == "")

  // A non-empty value round-trips through the STRICT column.
  try db.write { db in
    try Node.where { $0.id.eq(node.id) }.update { $0.context = "work" }.execute(db)
  }
  let updated = try db.read { db in try Node.where { $0.id.eq(node.id) }.fetchOne(db) }
  #expect(updated?.context == "work")
}
