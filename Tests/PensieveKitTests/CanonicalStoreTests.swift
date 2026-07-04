import Foundation
import Testing
import SQLiteData
@testable import PensieveKit

@Test func projectRoundTrips() throws {
  let db = try openCanonicalDatabase(at: tempURL("pensieve-test"))

  let p = Node(name: "Cetacean")
  try db.write { db in try Node.insert { p }.execute(db) }

  let fetched = try db.read { db in try Node.all.fetchAll(db) }
  #expect(fetched.count == 1)
  #expect(fetched.first?.name == "Cetacean")
}
