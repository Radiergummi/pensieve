import Foundation
import Testing
import SQLiteData
@testable import PensieveKit

@Test func projectRoundTrips() throws {
  let database = try openCanonicalDatabase(at: tempURL("pensieve-test"))

  let node = Node(name: "Cetacean")
  try database.write { database in try Node.insert { node }.execute(database) }

  let fetched = try database.read { database in try Node.all.fetchAll(database) }
  #expect(fetched.count == 1)
  #expect(fetched.first?.name == "Cetacean")
}
