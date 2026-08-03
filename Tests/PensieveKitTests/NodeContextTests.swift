import Foundation
import Testing
@testable import PensieveKit

// Tree: work(domain, "work") > proj(project, "") > strand(strand, "")
//       personalProj(project, "personal")
//       loose(project, "")   ← never set anywhere
private struct NodeContextFixture {
  let work: Node
  let proj: Node
  let strand: Node
  let personal: Node
  let loose: Node
  let all: [Node]
}

private func fixture() -> NodeContextFixture {
  let work = Node(name: "Work", kind: NodeKind.domain, context: NodeContext.work)
  let proj = Node(name: "Colibri", parentID: work.id, kind: NodeKind.project)
  let strand = Node(name: "auth", parentID: proj.id, kind: NodeKind.strand)
  let personal = Node(name: "Garden", kind: NodeKind.project, context: NodeContext.personal)
  let loose = Node(name: "Scratch", kind: NodeKind.project)
  return NodeContextFixture(work: work, proj: proj, strand: strand, personal: personal, loose: loose,
                             all: [work, proj, strand, personal, loose])
}

@Test func resolveInheritsNearestAncestor() {
  let treeFixture = fixture()
  #expect(NodeContextResolver.resolve(treeFixture.strand.id, in: treeFixture.all) == "work")   // inherited 2 levels up
  #expect(NodeContextResolver.resolve(treeFixture.proj.id, in: treeFixture.all) == "work")     // inherited 1 level up
  #expect(NodeContextResolver.resolve(treeFixture.work.id, in: treeFixture.all) == "work")     // own
  #expect(NodeContextResolver.resolve(treeFixture.personal.id, in: treeFixture.all) == "personal")
  #expect(NodeContextResolver.resolve(treeFixture.loose.id, in: treeFixture.all) == "")        // unset everywhere
}

@Test func resolveChildOverridesAncestor() {
  let work = Node(name: "Work", kind: NodeKind.domain, context: NodeContext.work)
  let odd = Node(name: "side", parentID: work.id, kind: NodeKind.strand, context: NodeContext.personal)
  #expect(NodeContextResolver.resolve(odd.id, in: [work, odd]) == "personal")   // own wins over ancestor
}

@Test func visiblePersonalFocusMutesWorkKeepsUnset() {
  let treeFixture = fixture()
  let vis = NodeContextResolver.visibleNodeIDs(for: NodeContext.personal, in: treeFixture.all)
  #expect(vis.contains(treeFixture.personal.id))   // personal shown
  #expect(vis.contains(treeFixture.loose.id))      // unset shown
  #expect(!vis.contains(treeFixture.work.id))      // work muted
  #expect(!vis.contains(treeFixture.proj.id))      // inherits work → muted
  #expect(!vis.contains(treeFixture.strand.id))    // inherits work → muted (subtree gone with its parent)
}

@Test func visibleWorkFocusMutesPersonal() {
  let treeFixture = fixture()
  let vis = NodeContextResolver.visibleNodeIDs(for: NodeContext.work, in: treeFixture.all)
  #expect(vis.contains(treeFixture.work.id) && vis.contains(treeFixture.proj.id) && vis.contains(treeFixture.strand.id))
  #expect(vis.contains(treeFixture.loose.id))       // unset shown
  #expect(!vis.contains(treeFixture.personal.id))   // personal muted
}

@Test func visibleNoFocusShowsEverything() {
  let treeFixture = fixture()
  let vis = NodeContextResolver.visibleNodeIDs(for: "", in: treeFixture.all)
  #expect(vis == Set(treeFixture.all.map(\.id)))
}

@Test func resolveIsCycleSafe() {
  // Corrupt parent cycle a→b→a must not loop; returns "" (no context found).
  var nodeA = Node(name: "A", kind: NodeKind.project)
  var nodeB = Node(name: "B", kind: NodeKind.project)
  nodeA.parentID = nodeB.id
  nodeB.parentID = nodeA.id
  #expect(NodeContextResolver.resolve(nodeA.id, in: [nodeA, nodeB]) == "")
}
