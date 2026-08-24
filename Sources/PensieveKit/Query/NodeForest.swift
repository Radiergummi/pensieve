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
    for node in nodes {
      if let parentID = node.parentID, ids.contains(parentID) {
        childrenByParent[parentID, default: []].append(node)
      } else {
        roots.append(node)   // nil parent, or parent absent from the set → promote to root
      }
    }
    func make(_ node: Node, _ visited: Set<UUID>) -> NodeForestNode {
      var visited = visited
      visited.insert(node.id)
      let children = (childrenByParent[node.id] ?? [])
        .filter { !visited.contains($0.id) }        // cycle guard: can never recurse forever
        .sorted { $0.name < $1.name }
        .map { make($0, visited) }
      return NodeForestNode(node: node, children: children)
    }
    return roots.sorted { $0.name < $1.name }.map { make($0, []) }
  }

  /// All transitive descendants of `id` within `nodes` (excludes `id` itself). Read-only,
  /// deterministic, and cycle-safe (a visited set guards against any pre-existing bad edge).
  public static func descendantIDs(of id: UUID, in nodes: [Node]) -> Set<UUID> {
    var childrenByParent: [UUID: [UUID]] = [:]
    for node in nodes { if let parentID = node.parentID { childrenByParent[parentID, default: []].append(node.id) } }
    var result: Set<UUID> = []
    var stack = childrenByParent[id] ?? []
    while let next = stack.popLast() {
      guard result.insert(next).inserted else { continue }
      stack.append(contentsOf: childrenByParent[next] ?? [])
    }
    return result
  }

  /// Direct children of `id` within `nodes`, name-sorted. Pure and deterministic; mirrors
  /// `descendantIDs` but one level only.
  public static func children(of id: UUID, in nodes: [Node]) -> [Node] {
    nodes.filter { $0.parentID == id }.sorted { $0.name < $1.name }
  }
}
