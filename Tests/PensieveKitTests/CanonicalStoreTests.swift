import Foundation
import Testing
import SQLiteData
@testable import PensieveKit

@Test func projectRoundTrips() throws {
  let url = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("pensieve-test-\(UUID().uuidString).sqlite")
  let db = try openCanonicalDatabase(at: url)

  let p = Project(name: "Cetacean")
  try db.write { db in try Project.insert { p }.execute(db) }

  let fetched = try db.read { db in try Project.all.fetchAll(db) }
  #expect(fetched.count == 1)
  #expect(fetched.first?.name == "Cetacean")
}
