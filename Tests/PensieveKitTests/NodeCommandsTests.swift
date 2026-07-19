import Foundation
import Testing
import SQLiteData
@testable import PensieveKit

@Test func addNestRenameRetype() throws {
  let db = try openCanonicalDatabase(at: tempURL("nodecmd"))
  let domain = try NodeCommands.add(db, name: "Work", kind: .domain, parent: nil, description: "")
  #expect(domain != nil)
  let proj = try NodeCommands.add(db, name: "colibri", kind: .project, parent: "Work", description: "hummingbird")
  #expect(proj?.parentID == domain?.id)

  #expect(try NodeCommands.nest(db, child: "colibri", under: "Work"))
  #expect(try NodeCommands.rename(db, node: "colibri", to: "Colibri"))
  #expect(try NodeCommands.retype(db, node: "Colibri", to: .initiative))

  let renamed = try db.read { db in try Node.where { $0.name.eq("Colibri") }.fetchOne(db) }
  #expect(renamed?.kind == NodeKind.initiative)
  #expect(renamed?.description == "hummingbird")
}

@Test func rendersIndentedTree() throws {
  let root = Node(name: "Work", kind: .domain)
  let child = Node(name: "Colibri", parentID: root.id, kind: .project)
  let strand = Node(name: "auth", parentID: child.id, kind: .strand, branchKey: "auth")
  let lines = NodeTree.render([strand, root, child])   // order-independent
  #expect(lines == [
    "Work (domain)  [active]",
    "  Colibri  [active]",
    "    auth (strand)  [active]",
  ])
}

@Test func reparentRejectsCycle() throws {
  let db = try openCanonicalDatabase(at: tempURL("reparent-cycle"))
  let a = try #require(try NodeCommands.add(db, name: "A", kind: .domain, parent: nil, description: ""))
  let b = try #require(try NodeCommands.add(db, name: "B", kind: .project, parent: "A", description: ""))
  let c = try #require(try NodeCommands.add(db, name: "C", kind: .strand, parent: "B", description: ""))

  // Move A under its own grandchild C → cycle → refused.
  #expect(try NodeCommands.reparent(db, nodeID: a.id, newParentID: c.id) == false)
  // Move B under itself → refused.
  #expect(try NodeCommands.reparent(db, nodeID: b.id, newParentID: b.id) == false)

  let reloadedA = try db.read { db in try Node.where { $0.id.eq(a.id) }.fetchOne(db) }
  #expect(reloadedA?.parentID == nil)   // A still a root; nothing was written
}

@Test func reparentLegalAndToRoot() throws {
  let db = try openCanonicalDatabase(at: tempURL("reparent-legal"))
  let a = try #require(try NodeCommands.add(db, name: "A", kind: .domain, parent: nil, description: ""))
  let b = try #require(try NodeCommands.add(db, name: "B", kind: .project, parent: nil, description: ""))

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
  _ = try NodeCommands.add(db, name: "A", kind: .domain, parent: nil, description: "")
  _ = try NodeCommands.add(db, name: "B", kind: .project, parent: "A", description: "")
  // Nest A under its own child B → refused, tree unchanged.
  #expect(try NodeCommands.nest(db, child: "A", under: "B") == false)
  let a = try db.read { db in try Node.where { $0.name.eq("A") }.fetchOne(db) }
  #expect(a?.parentID == nil)
}

@Test func addWritesAppearanceAtomically() throws {
  let db = try openCanonicalDatabase(at: tempURL("add-appearance"))
  let n = try #require(try NodeCommands.add(db, name: "Recipes", kind: .project,
                                            parent: nil, description: "",
                                            icon: "emoji:🍲", colorTag: "orange"))
  let stored = try db.read { db in try Node.where { $0.id.eq(n.id) }.fetchOne(db) }
  #expect(stored?.icon == "emoji:🍲")
  #expect(stored?.colorTag == "orange")

  // Defaults keep the appearance empty (existing call sites unaffected).
  let plain = try #require(try NodeCommands.add(db, name: "Plain", kind: .project,
                                                parent: nil, description: ""))
  #expect(plain.icon == "")
  #expect(plain.colorTag == "")
}

@Test func deleteSourceFreeSubtreeCascades() throws {
  let db = try openCanonicalDatabase(at: tempURL("delete-cascade"))
  let root = try #require(try NodeCommands.add(db, name: "Root", kind: .domain, parent: nil, description: ""))
  let child = try #require(try NodeCommands.add(db, name: "Child", kind: .project, parent: "Root", description: ""))
  let sibling = try #require(try NodeCommands.add(db, name: "Sibling", kind: .project, parent: nil, description: ""))

  // A source-free child event + loose end (source-free: no Source row is attached to root/child —
  // the deleted subtree — though events.sourceID still needs a real row to satisfy its FK, so the
  // backing source is attached to the untouched sibling instead).
  let unrelatedSource = Source(nodeID: sibling.id, kind: SourceKind.gitRepo, key: "/p/sibling")
  let ev = Event(nodeID: child.id, sourceID: unrelatedSource.id, occurredAt: Date(),
                 kind: CaptureKind.ccSession, summary: "s", detailJSON: "{}")
  let le = LooseEnd(nodeID: child.id, sourceEventID: ev.id, text: "todo", quote: "q")
  try db.write { db in
    try Source.insert { unrelatedSource }.execute(db)
    try Event.insert { ev }.execute(db)
    try LooseEnd.insert { le }.execute(db)
  }

  let result = try NodeCommands.delete(db, nodeID: root.id)
  #expect(result == .deleted(nodes: 2, events: 1, looseEnds: 1))   // root + child

  // Root + child gone; their event + loose end gone; sibling untouched.
  #expect(try db.read { db in try Node.where { $0.id.eq(root.id) }.fetchOne(db) } == nil)
  #expect(try db.read { db in try Node.where { $0.id.eq(child.id) }.fetchOne(db) } == nil)
  #expect(try db.read { db in try Node.where { $0.id.eq(sibling.id) }.fetchOne(db) } != nil)
  #expect(try db.read { db in try Event.fetchCount(db) } == 0)
  #expect(try db.read { db in try LooseEnd.fetchCount(db) } == 0)
}

@Test func deleteBlockedWhenSubtreeHasSource() throws {
  let db = try openCanonicalDatabase(at: tempURL("delete-blocked"))
  let root = try #require(try NodeCommands.add(db, name: "Root", kind: .domain, parent: nil, description: ""))
  let child = try #require(try NodeCommands.add(db, name: "Child", kind: .project, parent: "Root", description: ""))
  // A live source on the *descendant* must block deleting the ancestor.
  try db.write { db in
    try Source.insert { Source(nodeID: child.id, kind: SourceKind.gitRepo, key: "/p/child") }.execute(db)
  }

  #expect(try NodeCommands.subtreeIsActivityBorn(db, nodeID: root.id) == true)
  #expect(try NodeCommands.delete(db, nodeID: root.id) == .blocked)
  // Nothing was deleted.
  #expect(try db.read { db in try Node.where { $0.id.eq(root.id) }.fetchOne(db) } != nil)
  #expect(try db.read { db in try Node.where { $0.id.eq(child.id) }.fetchOne(db) } != nil)
}

@Test func deleteLeafAndUnknown() throws {
  let db = try openCanonicalDatabase(at: tempURL("delete-leaf"))
  let leaf = try #require(try NodeCommands.add(db, name: "Leaf", kind: .project, parent: nil, description: ""))
  #expect(try NodeCommands.subtreeIsActivityBorn(db, nodeID: leaf.id) == false)
  #expect(try NodeCommands.delete(db, nodeID: leaf.id) == .deleted(nodes: 1, events: 0, looseEnds: 0))
  #expect(try NodeCommands.delete(db, nodeID: UUID()) == .notFound)
}

@Test func deleteBlockedForAutoBirthedStrand() throws {
  let db = try openCanonicalDatabase(at: tempURL("delete-blocked-strand"))
  // A source-free project (manual node) with an auto-birthed strand child — the strand has NO
  // Source of its own (its events were repointed from the parent's source), so the old
  // source-only guard would have let it through.
  let project = try #require(try NodeCommands.add(db, name: "Colibri", kind: .project, parent: nil, description: ""))
  let strand = Node(name: "feat", parentID: project.id, kind: NodeKind.strand, branchKey: "feat")
  try db.write { db in try Node.insert { strand }.execute(db) }

  #expect(try NodeCommands.subtreeIsActivityBorn(db, nodeID: strand.id) == true)
  #expect(try NodeCommands.delete(db, nodeID: strand.id) == .blocked)
  #expect(try db.read { db in try Node.where { $0.id.eq(strand.id) }.fetchOne(db) } != nil)   // still present

  // Deleting the source-free parent is blocked too — it has a branchKey descendant.
  #expect(try NodeCommands.subtreeIsActivityBorn(db, nodeID: project.id) == true)
  #expect(try NodeCommands.delete(db, nodeID: project.id) == .blocked)
  #expect(try db.read { db in try Node.where { $0.id.eq(project.id) }.fetchOne(db) } != nil)
}

@Test func updateEditsAllFieldsAtomically() throws {
  let db = try openCanonicalDatabase(at: tempURL("node-update"))
  let n = try #require(try NodeCommands.add(db, name: "Old", kind: .project, parent: nil, description: "keep"))
  #expect(try NodeCommands.update(db, nodeID: n.id, name: "New", kind: .strand,
                                  icon: "sf:flag", colorTag: "pink"))
  let stored = try db.read { db in try Node.where { $0.id.eq(n.id) }.fetchOne(db) }
  #expect(stored?.name == "New")
  #expect(stored?.kind == NodeKind.strand)
  #expect(stored?.icon == "sf:flag")
  #expect(stored?.colorTag == "pink")
  #expect(stored?.description == "keep")   // untouched fields preserved
  // Unknown id → false, nothing written.
  #expect(try NodeCommands.update(db, nodeID: UUID(), name: "x", kind: .task, icon: "", colorTag: "") == false)
}

@Test func addAndUpdateRoundTripContext() throws {
  let db = try openCanonicalDatabase(at: tempURL("nodecmd-context"))
  let proj = try #require(try NodeCommands.add(db, name: "Garden", kind: .project,
                                               parent: nil, description: "", context: "personal"))
  #expect(proj.context == "personal")

  #expect(try NodeCommands.update(db, nodeID: proj.id, name: "Garden", kind: .project,
                                  icon: "", colorTag: "", context: "work"))
  let reloaded = try db.read { db in try Node.where { $0.id.eq(proj.id) }.fetchOne(db) }
  #expect(reloaded?.context == "work")
}

@Test func archiveAndUnarchiveWholeSubtree() throws {
  let db = try openCanonicalDatabase(at: tempURL("archive"))
  let proj = try #require(try NodeCommands.add(db, name: "Colibri", kind: .project, parent: nil, description: ""))
  let strandA = try #require(try NodeCommands.add(db, name: "auth", kind: .strand, parent: "Colibri", description: ""))
  let strandB = try #require(try NodeCommands.add(db, name: "ui", kind: .strand, parent: "Colibri", description: ""))

  // Archive the project → whole subtree archived.
  #expect(try NodeCommands.archive(db, nodeID: proj.id))
  func state(_ id: UUID) throws -> String? {
    try db.read { db in try Node.where { $0.id.eq(id) }.fetchOne(db)?.state.rawValue }
  }
  #expect(try state(proj.id) == "archived")
  #expect(try state(strandA.id) == "archived")
  #expect(try state(strandB.id) == "archived")

  // Unarchive → whole subtree active again.
  #expect(try NodeCommands.unarchive(db, nodeID: proj.id))
  #expect(try state(proj.id) == "active")
  #expect(try state(strandA.id) == "active")
  #expect(try state(strandB.id) == "active")

  // Unknown id → false, writes nothing.
  #expect(try NodeCommands.archive(db, nodeID: UUID()) == false)
}

@Test func unarchiveNestedChildRestoresSubtreeAndArchivedAncestorsButNotMuted() throws {
  let db = try openCanonicalDatabase(at: tempURL("unarchive-nested"))
  let root = try #require(try NodeCommands.add(db, name: "Root", kind: .domain, parent: nil, description: ""))
  let proj = try #require(try NodeCommands.add(db, name: "Colibri", kind: .project, parent: "Root", description: ""))
  let strand = try #require(try NodeCommands.add(db, name: "auth", kind: .strand, parent: "Colibri", description: ""))
  let leaf = try #require(try NodeCommands.add(db, name: "auth-detail", kind: .strand, parent: "auth", description: ""))

  func state(_ id: UUID) throws -> String? {
    try db.read { db in try Node.where { $0.id.eq(id) }.fetchOne(db)?.state.rawValue }
  }
  func setState(_ id: UUID, _ s: NodeState) throws {
    try db.write { db in try Node.where { $0.id.eq(id) }.update { $0.state = s }.execute(db) }
  }

  // Archive the whole tree, then mute the root (simulating the sticky, write-path-less "muted" state).
  #expect(try NodeCommands.archive(db, nodeID: root.id))
  try setState(root.id, .muted)

  // Unarchive the NESTED strand: its own subtree restores, and its archived ancestor (proj)
  // restores too — but the muted root is left untouched.
  #expect(try NodeCommands.unarchive(db, nodeID: strand.id))
  #expect(try state(strand.id) == "active")
  #expect(try state(leaf.id) == "active")
  #expect(try state(proj.id) == "active")
  #expect(try state(root.id) == "muted")
}
