import Foundation
import Testing
@testable import PensieveKit

@Test func buildsNestedForestSortedByName() {
  let root = Node(name: "alpha", kind: .project)
  let childB = Node(name: "b-strand", parentID: root.id, kind: .strand)
  let childA = Node(name: "a-strand", parentID: root.id, kind: .strand)
  let grandchild = Node(name: "deep", parentID: childA.id, kind: .strand)
  let other = Node(name: "zeta", kind: .project)

  let forest = NodeForest.build([grandchild, childB, root, other, childA])

  #expect(forest.map(\.node.name) == ["alpha", "zeta"])           // roots sorted
  #expect(forest[0].children.map(\.node.name) == ["a-strand", "b-strand"])  // children sorted
  #expect(forest[0].children[0].children.map(\.node.name) == ["deep"])
  #expect(forest[1].children.isEmpty)
}

@Test func promotesOrphanWithMissingParentToRoot() {
  let ghostParent = UUID()
  let orphan = Node(name: "orphan", parentID: ghostParent, kind: .strand)
  let realRoot = Node(name: "real", kind: .project)

  let forest = NodeForest.build([orphan, realRoot])

  // parent isn't in the set → orphan is promoted, never dropped
  #expect(Set(forest.map(\.node.name)) == ["orphan", "real"])
}

@Test func descendantIDsTransitiveExcludesSelf() {
  let rootDomain = Node(name: "A", kind: .domain)
  let childProject = Node(name: "B", parentID: rootDomain.id, kind: .project)
  let grandchildStrand = Node(name: "C", parentID: childProject.id, kind: .strand)
  let unrelatedRoot = Node(name: "D", kind: .project)   // unrelated root
  let nodes = [rootDomain, childProject, grandchildStrand, unrelatedRoot]

  #expect(NodeForest.descendantIDs(of: rootDomain.id, in: nodes) == [childProject.id, grandchildStrand.id])
  #expect(!NodeForest.descendantIDs(of: rootDomain.id, in: nodes).contains(rootDomain.id))
  #expect(NodeForest.descendantIDs(of: grandchildStrand.id, in: nodes).isEmpty)   // leaf
  #expect(NodeForest.descendantIDs(of: unrelatedRoot.id, in: nodes).isEmpty)   // childless root
  #expect(NodeForest.descendantIDs(of: UUID(), in: nodes).isEmpty) // unknown id
}

@Test func childrenReturnsDirectChildrenNameSorted() {
  let root = Node(name: "root", kind: .project)
  let childB = Node(name: "b", parentID: root.id, kind: .strand)
  let childA = Node(name: "a", parentID: root.id, kind: .strand)
  let grandchild = Node(name: "grand", parentID: childA.id, kind: .strand)   // grandchild, NOT a direct child of root
  let other = Node(name: "other", kind: .project)
  let nodes = [grandchild, childB, root, other, childA]

  #expect(NodeForest.children(of: root.id, in: nodes).map(\.name) == ["a", "b"])   // direct + name-sorted
  #expect(NodeForest.children(of: childA.id, in: nodes).map(\.name) == ["grand"])       // one level only
  #expect(NodeForest.children(of: childB.id, in: nodes).isEmpty)                        // leaf
  #expect(NodeForest.children(of: other.id, in: nodes).isEmpty)                    // childless root
  #expect(NodeForest.children(of: UUID(), in: nodes).isEmpty)                      // unknown id
}

@Test func archivedOnlySubsetReRootsUnderAbsentParent() {
  // Active parent P, archived child C: an archived-only forest promotes C to a root.
  let activeParent = Node(name: "P", kind: .project, description: "")   // active
  let archivedChild = Node(name: "C", state: .archived, parentID: activeParent.id, kind: .strand, description: "")
  let archived = [activeParent, archivedChild].filter { $0.state == .archived }
  let forest = NodeForest.build(archived)
  #expect(forest.count == 1)
  #expect(forest.first?.node.id == archivedChild.id)   // C is a root, not dropped
}
