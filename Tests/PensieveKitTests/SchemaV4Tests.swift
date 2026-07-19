import Foundation
import Testing
import SQLiteData
@testable import PensieveKit

@Test func v4RenamesProjectsToNodesWithTreeDefaults() throws {
  let db = try openCanonicalDatabase(at: tempURL("v4"))
  let node = Node(name: "Colibri")
  let source = Source(nodeID: node.id, kind: SourceKind.claudeCode, key: "/p/colibri")
  try db.write { db in
    try Node.insert { node }.execute(db)
    try Source.insert { source }.execute(db)
  }
  let fetched = try db.read { db in try Node.all.fetchAll(db) }.first
  #expect(fetched?.kind == NodeKind.project)       // existing rows migrate to top-level project nodes
  #expect(fetched?.parentID == nil)
  #expect(fetched?.description == "")
  #expect(fetched?.metadataJSON == "{}")
  #expect(fetched?.branchKey == nil)
  let src = try db.read { db in try Source.all.fetchAll(db) }.first
  #expect(src?.nodeID == node.id)           // FK column renamed and still joins
}
