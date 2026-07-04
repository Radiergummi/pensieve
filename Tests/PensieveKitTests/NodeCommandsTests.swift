import Foundation
import Testing
import SQLiteData
@testable import PensieveKit

@Test func addNestRenameRetype() throws {
  let db = try openCanonicalDatabase(at: tempURL("nodecmd"))
  let domain = try NodeCommands.add(db, name: "Work", kind: "domain", parent: nil, description: "")
  #expect(domain != nil)
  let proj = try NodeCommands.add(db, name: "colibri", kind: "project", parent: "Work", description: "hummingbird")
  #expect(proj?.parentID == domain?.id)

  #expect(try NodeCommands.nest(db, child: "colibri", under: "Work"))
  #expect(try NodeCommands.rename(db, node: "colibri", to: "Colibri"))
  #expect(try NodeCommands.retype(db, node: "Colibri", to: "initiative"))

  let renamed = try db.read { db in try Node.where { $0.name.eq("Colibri") }.fetchOne(db) }
  #expect(renamed?.kind == "initiative")
  #expect(renamed?.description == "hummingbird")
}

@Test func rendersIndentedTree() throws {
  let root = Node(name: "Work", kind: "domain")
  let child = Node(name: "Colibri", parentID: root.id, kind: "project")
  let strand = Node(name: "auth", parentID: child.id, kind: "strand", branchKey: "auth")
  let lines = NodeTree.render([strand, root, child])   // order-independent
  #expect(lines == [
    "Work (domain)  [active]",
    "  Colibri  [active]",
    "    auth (strand)  [active]",
  ])
}
