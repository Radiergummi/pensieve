import Foundation
import Testing
import SQLiteData
@testable import PensieveKit

@Test func addNestRenameRetype() throws {
  let database = try openCanonicalDatabase(at: tempURL("nodecmd"))
  let domain = try NodeCommands.add(database, name: "Work", kind: .domain, parent: nil, description: "")
  #expect(domain != nil)
  let proj = try NodeCommands.add(database, name: "colibri", kind: .project, parent: "Work", description: "hummingbird")
  #expect(proj?.parentID == domain?.id)

  #expect(try NodeCommands.nest(database, child: "colibri", under: "Work"))
  #expect(try NodeCommands.rename(database, node: "colibri", to: "Colibri"))
  #expect(try NodeCommands.retype(database, node: "Colibri", to: .initiative))

  let renamed = try database.read { database in try Node.where { $0.name.eq("Colibri") }.fetchOne(database) }
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
  let database = try openCanonicalDatabase(at: tempURL("reparent-cycle"))
  let nodeA = try #require(try NodeCommands.add(database, name: "A", kind: .domain, parent: nil, description: ""))
  let nodeB = try #require(try NodeCommands.add(database, name: "B", kind: .project, parent: "A", description: ""))
  let nodeC = try #require(try NodeCommands.add(database, name: "C", kind: .strand, parent: "B", description: ""))

  // Move A under its own grandchild C → cycle → refused.
  #expect(try NodeCommands.reparent(database, nodeID: nodeA.id, newParentID: nodeC.id) == false)
  // Move B under itself → refused.
  #expect(try NodeCommands.reparent(database, nodeID: nodeB.id, newParentID: nodeB.id) == false)

  let reloadedA = try database.read { database in try Node.where { $0.id.eq(nodeA.id) }.fetchOne(database) }
  #expect(reloadedA?.parentID == nil)   // A still nodeA root; nothing was written
}

@Test func reparentLegalAndToRoot() throws {
  let database = try openCanonicalDatabase(at: tempURL("reparent-legal"))
  let nodeA = try #require(try NodeCommands.add(database, name: "A", kind: .domain, parent: nil, description: ""))
  let nodeB = try #require(try NodeCommands.add(database, name: "B", kind: .project, parent: nil, description: ""))

  #expect(try NodeCommands.reparent(database, nodeID: nodeB.id, newParentID: nodeA.id))
  #expect(try database.read { database in try Node.where { $0.id.eq(nodeB.id) }.fetchOne(database) }?.parentID == nodeA.id)

  #expect(try NodeCommands.reparent(database, nodeID: nodeB.id, newParentID: nil))   // move back to root
  #expect(try database.read { database in try Node.where { $0.id.eq(nodeB.id) }.fetchOne(database) }?.parentID == nil)
}

@Test func reparentUnknownIDReturnsFalse() throws {
  let database = try openCanonicalDatabase(at: tempURL("reparent-unknown"))
  #expect(try NodeCommands.reparent(database, nodeID: UUID(), newParentID: nil) == false)
}

@Test func nestRejectsCycleViaWrapper() throws {
  let database = try openCanonicalDatabase(at: tempURL("nest-cycle"))
  _ = try NodeCommands.add(database, name: "A", kind: .domain, parent: nil, description: "")
  _ = try NodeCommands.add(database, name: "B", kind: .project, parent: "A", description: "")
  // Nest A under its own child B → refused, tree unchanged.
  #expect(try NodeCommands.nest(database, child: "A", under: "B") == false)
  let nodeA = try database.read { database in try Node.where { $0.name.eq("A") }.fetchOne(database) }
  #expect(nodeA?.parentID == nil)
}

@Test func addWritesAppearanceAtomically() throws {
  let database = try openCanonicalDatabase(at: tempURL("add-appearance"))
  let node = try #require(try NodeCommands.add(database, name: "Recipes", kind: .project,
                                            parent: nil, description: "",
                                            icon: "emoji:🍲", colorTag: "orange"))
  let stored = try database.read { database in try Node.where { $0.id.eq(node.id) }.fetchOne(database) }
  #expect(stored?.icon == "emoji:🍲")
  #expect(stored?.colorTag == "orange")

  // Defaults keep the appearance empty (existing call sites unaffected).
  let plain = try #require(try NodeCommands.add(database, name: "Plain", kind: .project,
                                                parent: nil, description: ""))
  #expect(plain.icon == "")
  #expect(plain.colorTag == "")
}

@Test func deleteSourceFreeSubtreeCascades() throws {
  let database = try openCanonicalDatabase(at: tempURL("delete-cascade"))
  let root = try #require(try NodeCommands.add(database, name: "Root", kind: .domain, parent: nil, description: ""))
  let child = try #require(try NodeCommands.add(database, name: "Child", kind: .project, parent: "Root", description: ""))
  let sibling = try #require(try NodeCommands.add(database, name: "Sibling", kind: .project, parent: nil, description: ""))

  // A source-free child event + loose end (source-free: no Source row is attached to root/child —
  // the deleted subtree — though events.sourceID still needs nodeA real row to satisfy its FK, so the
  // backing source is attached to the untouched sibling instead).
  let unrelatedSource = Source(nodeID: sibling.id, kind: SourceKind.gitRepo, key: "/p/sibling")
  let event = Event(nodeID: child.id, sourceID: unrelatedSource.id, occurredAt: Date(),
                 kind: CaptureKind.ccSession, summary: "s", detailJSON: "{}")
  let looseEnd = LooseEnd(nodeID: child.id, sourceEventID: event.id, text: "todo", quote: "q")
  try database.write { database in
    try Source.insert { unrelatedSource }.execute(database)
    try Event.insert { event }.execute(database)
    try LooseEnd.insert { looseEnd }.execute(database)
  }

  let result = try NodeCommands.delete(database, nodeID: root.id)
  #expect(result == .deleted(nodes: 2, events: 1, looseEnds: 1))   // root + child

  // Root + child gone; their event + loose end gone; sibling untouched.
  #expect(try database.read { database in try Node.where { $0.id.eq(root.id) }.fetchOne(database) } == nil)
  #expect(try database.read { database in try Node.where { $0.id.eq(child.id) }.fetchOne(database) } == nil)
  #expect(try database.read { database in try Node.where { $0.id.eq(sibling.id) }.fetchOne(database) } != nil)
  #expect(try database.read { database in try Event.fetchCount(database) } == 0)
  #expect(try database.read { database in try LooseEnd.fetchCount(database) } == 0)
}

@Test func deleteBlockedWhenSubtreeHasSource() throws {
  let database = try openCanonicalDatabase(at: tempURL("delete-blocked"))
  let root = try #require(try NodeCommands.add(database, name: "Root", kind: .domain, parent: nil, description: ""))
  let child = try #require(try NodeCommands.add(database, name: "Child", kind: .project, parent: "Root", description: ""))
  // A live source on the *descendant* must block deleting the ancestor.
  try database.write { database in
    try Source.insert { Source(nodeID: child.id, kind: SourceKind.gitRepo, key: "/p/child") }.execute(database)
  }

  #expect(try NodeCommands.subtreeIsActivityBorn(database, nodeID: root.id) == true)
  #expect(try NodeCommands.delete(database, nodeID: root.id) == .blocked)
  // Nothing was deleted.
  #expect(try database.read { database in try Node.where { $0.id.eq(root.id) }.fetchOne(database) } != nil)
  #expect(try database.read { database in try Node.where { $0.id.eq(child.id) }.fetchOne(database) } != nil)
}

@Test func deleteLeafAndUnknown() throws {
  let database = try openCanonicalDatabase(at: tempURL("delete-leaf"))
  let leaf = try #require(try NodeCommands.add(database, name: "Leaf", kind: .project, parent: nil, description: ""))
  #expect(try NodeCommands.subtreeIsActivityBorn(database, nodeID: leaf.id) == false)
  #expect(try NodeCommands.delete(database, nodeID: leaf.id) == .deleted(nodes: 1, events: 0, looseEnds: 0))
  #expect(try NodeCommands.delete(database, nodeID: UUID()) == .notFound)
}

@Test func deleteBlockedForAutoBirthedStrand() throws {
  let database = try openCanonicalDatabase(at: tempURL("delete-blocked-strand"))
  // A source-free project (manual node) with an auto-birthed strand child — the strand has NO
  // Source of its own (its events were repointed from the parent'state source), so the old
  // source-only guard would have let it through.
  let project = try #require(try NodeCommands.add(database, name: "Colibri", kind: .project, parent: nil, description: ""))
  let strand = Node(name: "feat", parentID: project.id, kind: NodeKind.strand, branchKey: "feat")
  try database.write { database in try Node.insert { strand }.execute(database) }

  #expect(try NodeCommands.subtreeIsActivityBorn(database, nodeID: strand.id) == true)
  #expect(try NodeCommands.delete(database, nodeID: strand.id) == .blocked)
  #expect(try database.read { database in try Node.where { $0.id.eq(strand.id) }.fetchOne(database) } != nil)   // still present

  // Deleting the source-free parent is blocked too — it has nodeA branchKey descendant.
  #expect(try NodeCommands.subtreeIsActivityBorn(database, nodeID: project.id) == true)
  #expect(try NodeCommands.delete(database, nodeID: project.id) == .blocked)
  #expect(try database.read { database in try Node.where { $0.id.eq(project.id) }.fetchOne(database) } != nil)
}

@Test func updateEditsAllFieldsAtomically() throws {
  let database = try openCanonicalDatabase(at: tempURL("node-update"))
  let node = try #require(try NodeCommands.add(database, name: "Old", kind: .project, parent: nil, description: "keep"))
  #expect(try NodeCommands.update(database, nodeID: node.id, name: "New", kind: .strand,
                                  icon: "sf:flag", colorTag: "pink"))
  let stored = try database.read { database in try Node.where { $0.id.eq(node.id) }.fetchOne(database) }
  #expect(stored?.name == "New")
  #expect(stored?.kind == NodeKind.strand)
  #expect(stored?.icon == "sf:flag")
  #expect(stored?.colorTag == "pink")
  #expect(stored?.description == "keep")   // untouched fields preserved
  // Unknown id → false, nothing written.
  #expect(try NodeCommands.update(database, nodeID: UUID(), name: "x", kind: .task, icon: "", colorTag: "") == false)
}

@Test func addAndUpdateRoundTripContext() throws {
  let database = try openCanonicalDatabase(at: tempURL("nodecmd-context"))
  let proj = try #require(try NodeCommands.add(database, name: "Garden", kind: .project,
                                               parent: nil, description: "", context: "personal"))
  #expect(proj.context == "personal")

  #expect(try NodeCommands.update(database, nodeID: proj.id, name: "Garden", kind: .project,
                                  icon: "", colorTag: "", context: "work"))
  let reloaded = try database.read { database in try Node.where { $0.id.eq(proj.id) }.fetchOne(database) }
  #expect(reloaded?.context == "work")
}

@Test func archiveAndUnarchiveWholeSubtree() throws {
  let database = try openCanonicalDatabase(at: tempURL("archive"))
  let proj = try #require(try NodeCommands.add(database, name: "Colibri", kind: .project, parent: nil, description: ""))
  let strandA = try #require(try NodeCommands.add(database, name: "auth", kind: .strand, parent: "Colibri", description: ""))
  let strandB = try #require(try NodeCommands.add(database, name: "ui", kind: .strand, parent: "Colibri", description: ""))

  // Archive the project → whole subtree archived.
  #expect(try NodeCommands.archive(database, nodeID: proj.id))
  func state(_ id: UUID) throws -> String? {
    try database.read { database in try Node.where { $0.id.eq(id) }.fetchOne(database)?.state.rawValue }
  }
  #expect(try state(proj.id) == "archived")
  #expect(try state(strandA.id) == "archived")
  #expect(try state(strandB.id) == "archived")

  // Unarchive → whole subtree active again.
  #expect(try NodeCommands.unarchive(database, nodeID: proj.id))
  #expect(try state(proj.id) == "active")
  #expect(try state(strandA.id) == "active")
  #expect(try state(strandB.id) == "active")

  // Unknown id → false, writes nothing.
  #expect(try NodeCommands.archive(database, nodeID: UUID()) == false)
}

@Test func unarchiveNestedChildRestoresSubtreeAndArchivedAncestorsButNotMuted() throws {
  let database = try openCanonicalDatabase(at: tempURL("unarchive-nested"))
  let root = try #require(try NodeCommands.add(database, name: "Root", kind: .domain, parent: nil, description: ""))
  let proj = try #require(try NodeCommands.add(database, name: "Colibri", kind: .project, parent: "Root", description: ""))
  let strand = try #require(try NodeCommands.add(database, name: "auth", kind: .strand, parent: "Colibri", description: ""))
  let leaf = try #require(try NodeCommands.add(database, name: "auth-detail", kind: .strand, parent: "auth", description: ""))

  func state(_ id: UUID) throws -> String? {
    try database.read { database in try Node.where { $0.id.eq(id) }.fetchOne(database)?.state.rawValue }
  }
  func setState(_ id: UUID, _ state: NodeState) throws {
    try database.write { database in try Node.where { $0.id.eq(id) }.update { $0.state = state }.execute(database) }
  }

  // Archive the whole tree, then mute the root (simulating the sticky, write-path-less "muted" state).
  #expect(try NodeCommands.archive(database, nodeID: root.id))
  try setState(root.id, .muted)

  // Unarchive the NESTED strand: its own subtree restores, and its archived ancestor (proj)
  // restores too — but the muted root is left untouched.
  #expect(try NodeCommands.unarchive(database, nodeID: strand.id))
  #expect(try state(strand.id) == "active")
  #expect(try state(leaf.id) == "active")
  #expect(try state(proj.id) == "active")
  #expect(try state(root.id) == "muted")
}
