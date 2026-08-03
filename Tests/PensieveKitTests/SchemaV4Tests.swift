import Foundation
import Testing
import SQLiteData
@testable import PensieveKit

@Test func v4RenamesProjectsToNodesWithTreeDefaults() throws {
  let database = try openCanonicalDatabase(at: tempURL("v4"))
  let node = Node(name: "Colibri")
  let source = Source(nodeID: node.id, kind: SourceKind.claudeCode, key: "/p/colibri")
  try database.write { database in
    try Node.insert { node }.execute(database)
    try Source.insert { source }.execute(database)
  }
  let fetched = try database.read { database in try Node.all.fetchAll(database) }.first
  #expect(fetched?.kind == NodeKind.project)       // existing rows migrate to top-level project nodes
  #expect(fetched?.parentID == nil)
  #expect(fetched?.description == "")
  #expect(fetched?.metadataJSON == "{}")
  #expect(fetched?.branchKey == nil)
  let src = try database.read { database in try Source.all.fetchAll(database) }.first
  #expect(src?.nodeID == node.id)           // FK column renamed and still joins
}
