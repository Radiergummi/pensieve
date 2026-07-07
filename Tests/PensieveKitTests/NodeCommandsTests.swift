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

@Test func reparentRejectsCycle() throws {
  let db = try openCanonicalDatabase(at: tempURL("reparent-cycle"))
  let a = try #require(try NodeCommands.add(db, name: "A", kind: "domain", parent: nil, description: ""))
  let b = try #require(try NodeCommands.add(db, name: "B", kind: "project", parent: "A", description: ""))
  let c = try #require(try NodeCommands.add(db, name: "C", kind: "strand", parent: "B", description: ""))

  // Move A under its own grandchild C → cycle → refused.
  #expect(try NodeCommands.reparent(db, nodeID: a.id, newParentID: c.id) == false)
  // Move B under itself → refused.
  #expect(try NodeCommands.reparent(db, nodeID: b.id, newParentID: b.id) == false)

  let reloadedA = try db.read { db in try Node.where { $0.id.eq(a.id) }.fetchOne(db) }
  #expect(reloadedA?.parentID == nil)   // A still a root; nothing was written
}

@Test func reparentLegalAndToRoot() throws {
  let db = try openCanonicalDatabase(at: tempURL("reparent-legal"))
  let a = try #require(try NodeCommands.add(db, name: "A", kind: "domain", parent: nil, description: ""))
  let b = try #require(try NodeCommands.add(db, name: "B", kind: "project", parent: nil, description: ""))

  #expect(try NodeCommands.reparent(db, nodeID: b.id, newParentID: a.id))
  #expect(try db.read { db in try Node.where { $0.id.eq(b.id) }.fetchOne(db) }?.parentID == a.id)

  #expect(try NodeCommands.reparent(db, nodeID: b.id, newParentID: nil))   // move back to root
  #expect(try db.read { db in try Node.where { $0.id.eq(b.id) }.fetchOne(db) }?.parentID == nil)
}

@Test func reparentUnknownIDReturnsFalse() throws {
  let db = try openCanonicalDatabase(at: tempURL("reparent-unknown"))
  #expect(try NodeCommands.reparent(db, nodeID: UUID(), newParentID: nil) == false)
}

@Test func nestRejectsCycleViaWrapper() throws {
  let db = try openCanonicalDatabase(at: tempURL("nest-cycle"))
  _ = try NodeCommands.add(db, name: "A", kind: "domain", parent: nil, description: "")
  _ = try NodeCommands.add(db, name: "B", kind: "project", parent: "A", description: "")
  // Nest A under its own child B → refused, tree unchanged.
  #expect(try NodeCommands.nest(db, child: "A", under: "B") == false)
  let a = try db.read { db in try Node.where { $0.name.eq("A") }.fetchOne(db) }
  #expect(a?.parentID == nil)
}

@Test func addWritesAppearanceAtomically() throws {
  let db = try openCanonicalDatabase(at: tempURL("add-appearance"))
  let n = try #require(try NodeCommands.add(db, name: "Recipes", kind: "project",
                                            parent: nil, description: "",
                                            icon: "emoji:🍲", colorTag: "orange"))
  let stored = try db.read { db in try Node.where { $0.id.eq(n.id) }.fetchOne(db) }
  #expect(stored?.icon == "emoji:🍲")
  #expect(stored?.colorTag == "orange")

  // Defaults keep the appearance empty (existing call sites unaffected).
  let plain = try #require(try NodeCommands.add(db, name: "Plain", kind: "project",
                                                parent: nil, description: ""))
  #expect(plain.icon == "")
  #expect(plain.colorTag == "")
}
