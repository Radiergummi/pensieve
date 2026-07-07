import Foundation
import Testing
@testable import PensieveKit

// Tree: work(domain, "work") > proj(project, "") > strand(strand, "")
//       personalProj(project, "personal")
//       loose(project, "")   ← never set anywhere
private func fixture() -> (work: Node, proj: Node, strand: Node, personal: Node, loose: Node, all: [Node]) {
  let work = Node(name: "Work", kind: NodeKind.domain, context: NodeContext.work)
  let proj = Node(name: "Colibri", parentID: work.id, kind: NodeKind.project)
  let strand = Node(name: "auth", parentID: proj.id, kind: NodeKind.strand)
  let personal = Node(name: "Garden", kind: NodeKind.project, context: NodeContext.personal)
  let loose = Node(name: "Scratch", kind: NodeKind.project)
  return (work, proj, strand, personal, loose, [work, proj, strand, personal, loose])
}

@Test func resolveInheritsNearestAncestor() {
  let f = fixture()
  #expect(NodeContextResolver.resolve(f.strand.id, in: f.all) == "work")   // inherited 2 levels up
  #expect(NodeContextResolver.resolve(f.proj.id, in: f.all) == "work")     // inherited 1 level up
  #expect(NodeContextResolver.resolve(f.work.id, in: f.all) == "work")     // own
  #expect(NodeContextResolver.resolve(f.personal.id, in: f.all) == "personal")
  #expect(NodeContextResolver.resolve(f.loose.id, in: f.all) == "")        // unset everywhere
}

@Test func resolveChildOverridesAncestor() {
  let work = Node(name: "Work", kind: NodeKind.domain, context: NodeContext.work)
  let odd = Node(name: "side", parentID: work.id, kind: NodeKind.strand, context: NodeContext.personal)
  #expect(NodeContextResolver.resolve(odd.id, in: [work, odd]) == "personal")   // own wins over ancestor
}

@Test func visiblePersonalFocusMutesWorkKeepsUnset() {
  let f = fixture()
  let vis = NodeContextResolver.visibleNodeIDs(for: NodeContext.personal, in: f.all)
  #expect(vis.contains(f.personal.id))   // personal shown
  #expect(vis.contains(f.loose.id))      // unset shown
  #expect(!vis.contains(f.work.id))      // work muted
  #expect(!vis.contains(f.proj.id))      // inherits work → muted
  #expect(!vis.contains(f.strand.id))    // inherits work → muted (subtree gone with its parent)
}

@Test func visibleWorkFocusMutesPersonal() {
  let f = fixture()
  let vis = NodeContextResolver.visibleNodeIDs(for: NodeContext.work, in: f.all)
  #expect(vis.contains(f.work.id) && vis.contains(f.proj.id) && vis.contains(f.strand.id))
  #expect(vis.contains(f.loose.id))       // unset shown
  #expect(!vis.contains(f.personal.id))   // personal muted
}

@Test func visibleNoFocusShowsEverything() {
  let f = fixture()
  let vis = NodeContextResolver.visibleNodeIDs(for: "", in: f.all)
  #expect(vis == Set(f.all.map(\.id)))
}

@Test func resolveIsCycleSafe() {
  // Corrupt parent cycle a→b→a must not loop; returns "" (no context found).
  var a = Node(name: "A", kind: NodeKind.project)
  var b = Node(name: "B", kind: NodeKind.project)
  a.parentID = b.id
  b.parentID = a.id
  #expect(NodeContextResolver.resolve(a.id, in: [a, b]) == "")
}
