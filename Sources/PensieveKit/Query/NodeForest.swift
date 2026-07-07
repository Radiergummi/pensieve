import Foundation

/// A node plus its child nodes, ready for SwiftUI `OutlineGroup`. Pure value type.
public struct NodeForestNode: Identifiable, Equatable, Sendable {
  public let node: Node
  public let children: [NodeForestNode]
  public var id: UUID { node.id }
  public init(node: Node, children: [NodeForestNode]) {
    self.node = node; self.children = children
  }
}

/// Turns a flat `[Node]` into a rooted forest by `parentID`. Read-only, deterministic.
public enum NodeForest {
  public static func build(_ nodes: [Node]) -> [NodeForestNode] {
    let ids = Set(nodes.map(\.id))
    var childrenByParent: [UUID: [Node]] = [:]
    var roots: [Node] = []
    for n in nodes {
      if let pid = n.parentID, ids.contains(pid) {
        childrenByParent[pid, default: []].append(n)
      } else {
        roots.append(n)   // nil parent, or parent absent from the set → promote to root
      }
    }
    func make(_ n: Node, _ visited: Set<UUID>) -> NodeForestNode {
      var visited = visited
      visited.insert(n.id)
      let kids = (childrenByParent[n.id] ?? [])
        .filter { !visited.contains($0.id) }        // cycle guard: can never recurse forever
        .sorted { $0.name < $1.name }
        .map { make($0, visited) }
      return NodeForestNode(node: n, children: kids)
    }
    return roots.sorted { $0.name < $1.name }.map { make($0, []) }
  }

  /// All transitive descendants of `id` within `nodes` (excludes `id` itself). Read-only,
  /// deterministic, and cycle-safe (a visited set guards against any pre-existing bad edge).
  public static func descendantIDs(of id: UUID, in nodes: [Node]) -> Set<UUID> {
    var childrenByParent: [UUID: [UUID]] = [:]
    for n in nodes { if let p = n.parentID { childrenByParent[p, default: []].append(n.id) } }
    var result: Set<UUID> = []
    var stack = childrenByParent[id] ?? []
    while let next = stack.popLast() {
      guard result.insert(next).inserted else { continue }
      stack.append(contentsOf: childrenByParent[next] ?? [])
    }
    return result
  }
}
