import Foundation

/// The `Node.context` string values. Centralized like `NodeKind` so a typo can't misfile a node.
/// The column stays an open `String`; `""` means unset (inherit from the nearest ancestor).
public enum NodeContext {
  public static let work = "work"
  public static let personal = "personal"
  public static let unset = ""

  /// The user-selectable explicit contexts (for the app's Context picker + Focus filter).
  public static let all = [work, personal]
}

/// Pure context resolution + the Focus-filter visibility predicate. Operates on an in-memory `[Node]`
/// (the app already holds the full node set) — no DB round-trip. Tested; the app applies it thinly.
public enum NodeContextResolver {
  /// The effective context of `nodeID`: its own if set, else the nearest ancestor's; `""` if none.
  public static func resolve(_ nodeID: UUID, in nodes: [Node]) -> String {
    resolve(nodeID, byID: Dictionary(nodes.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a }))
  }

  static func resolve(_ nodeID: UUID, byID: [UUID: Node]) -> String {
    var seen: Set<UUID> = []
    var cursor: UUID? = nodeID
    // `seen.insert(...).inserted` bounds a corrupt (pre-existing) parent cycle.
    while let id = cursor, seen.insert(id).inserted, let node = byID[id] {
      if !node.context.isEmpty { return node.context }
      cursor = node.parentID
    }
    return ""
  }

  /// The ids visible under `active`: resolved context equal to `active` OR unset. `active == ""`
  /// (no Focus) ⇒ every id. Generalizes to more contexts: show active + unset, hide every other.
  public static func visibleNodeIDs(for active: String, in nodes: [Node]) -> Set<UUID> {
    let byID = Dictionary(nodes.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    let allIDs = Set(byID.keys)
    guard !active.isEmpty else { return allIDs }
    return allIDs.filter { id in
      let ctx = resolve(id, byID: byID)
      return ctx == active || ctx.isEmpty
    }
  }
}
