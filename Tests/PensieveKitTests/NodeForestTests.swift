import Foundation
import Testing
@testable import PensieveKit

@Test func buildsNestedForestSortedByName() {
  let root = Node(name: "alpha", kind: "project")
  let childB = Node(name: "b-strand", parentID: root.id, kind: "strand")
  let childA = Node(name: "a-strand", parentID: root.id, kind: "strand")
  let grandchild = Node(name: "deep", parentID: childA.id, kind: "strand")
  let other = Node(name: "zeta", kind: "project")

  let forest = NodeForest.build([grandchild, childB, root, other, childA])

  #expect(forest.map(\.node.name) == ["alpha", "zeta"])           // roots sorted
  #expect(forest[0].children.map(\.node.name) == ["a-strand", "b-strand"])  // children sorted
  #expect(forest[0].children[0].children.map(\.node.name) == ["deep"])
  #expect(forest[1].children.isEmpty)
}

@Test func promotesOrphanWithMissingParentToRoot() {
  let ghostParent = UUID()
  let orphan = Node(name: "orphan", parentID: ghostParent, kind: "strand")
  let realRoot = Node(name: "real", kind: "project")

  let forest = NodeForest.build([orphan, realRoot])

  // parent isn't in the set → orphan is promoted, never dropped
  #expect(Set(forest.map(\.node.name)) == ["orphan", "real"])
}

@Test func descendantIDsTransitiveExcludesSelf() {
  let a = Node(name: "A", kind: "domain")
  let b = Node(name: "B", parentID: a.id, kind: "project")
  let c = Node(name: "C", parentID: b.id, kind: "strand")
  let d = Node(name: "D", kind: "project")   // unrelated root
  let nodes = [a, b, c, d]

  #expect(NodeForest.descendantIDs(of: a.id, in: nodes) == [b.id, c.id])
  #expect(!NodeForest.descendantIDs(of: a.id, in: nodes).contains(a.id))
  #expect(NodeForest.descendantIDs(of: c.id, in: nodes).isEmpty)   // leaf
  #expect(NodeForest.descendantIDs(of: d.id, in: nodes).isEmpty)   // childless root
  #expect(NodeForest.descendantIDs(of: UUID(), in: nodes).isEmpty) // unknown id
}

@Test func childrenReturnsDirectChildrenNameSorted() {
  let root = Node(name: "root", kind: "project")
  let b = Node(name: "b", parentID: root.id, kind: "strand")
  let a = Node(name: "a", parentID: root.id, kind: "strand")
  let grand = Node(name: "grand", parentID: a.id, kind: "strand")   // grandchild, NOT a direct child of root
  let other = Node(name: "other", kind: "project")
  let nodes = [grand, b, root, other, a]

  #expect(NodeForest.children(of: root.id, in: nodes).map(\.name) == ["a", "b"])   // direct + name-sorted
  #expect(NodeForest.children(of: a.id, in: nodes).map(\.name) == ["grand"])       // one level only
  #expect(NodeForest.children(of: b.id, in: nodes).isEmpty)                        // leaf
  #expect(NodeForest.children(of: other.id, in: nodes).isEmpty)                    // childless root
  #expect(NodeForest.children(of: UUID(), in: nodes).isEmpty)                      // unknown id
}

@Test func archivedOnlySubsetReRootsUnderAbsentParent() {
  // Active parent P, archived child C: an archived-only forest promotes C to a root.
  let p = Node(name: "P", kind: "project", description: "")   // active
  let c = Node(name: "C", state: "archived", parentID: p.id, kind: "strand", description: "")
  let archived = [p, c].filter { $0.state == "archived" }
  let forest = NodeForest.build(archived)
  #expect(forest.count == 1)
  #expect(forest.first?.node.id == c.id)   // C is a root, not dropped
}
