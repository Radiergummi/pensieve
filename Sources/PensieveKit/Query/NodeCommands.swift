import Foundation
import SQLiteData
import GRDB

public enum NodeCommands {
  /// Find a node by UUID string (preferred) or exact name. Node names are NOT unique, so the
  /// name fallback returns an arbitrary match among duplicates — pass a UUID when the target is
  /// known (the app always does; only CLI-by-name can hit the ambiguity).
  public static func find(_ database: Database, nameOrID: String) throws -> Node? {
    if let uuid = UUID(uuidString: nameOrID),
       let byID = try Node.where({ $0.id.eq(uuid) }).fetchOne(database) { return byID }
    return try Node.where { $0.name.eq(nameOrID) }.fetchOne(database)
  }

  @discardableResult
  public static func add(_ database: any DatabaseWriter, name: String, kind: NodeKind,
                         parent: String?, description: String,
                         icon: String = "", colorTag: String = "", context: String = "") throws -> Node? {
    try database.write { database in
      var parentID: UUID?
      if let parent {
        guard let p = try find(database, nameOrID: parent) else { return nil }
        parentID = p.id
      }
      let node = Node(name: name, parentID: parentID, kind: kind, description: description,
                      icon: icon, colorTag: colorTag, context: context)
      try Node.insert { node }.execute(database)
      return node
    }
  }

  /// Reparent `nodeID` under `newParentID` (nil = move to root). Returns false — writing nothing — if
  /// either id is unknown or the move would create a cycle (`newParentID == nodeID`, or `nodeID` is an
  /// ancestor of `newParentID`). The read side (`NodeForest.build`) guards display; this guards data.
  @discardableResult
  public static func reparent(_ database: any DatabaseWriter, nodeID: UUID, newParentID: UUID?) throws -> Bool {
    try database.write { database in try reparent(database, nodeID: nodeID, newParentID: newParentID) }
  }

  /// In-transaction core, so `nest` can reuse the guard inside its own `database.write`.
  static func reparent(_ database: Database, nodeID: UUID, newParentID: UUID?) throws -> Bool {
    guard try Node.where({ $0.id.eq(nodeID) }).fetchOne(database) != nil else { return false }
    if let newParentID {
      guard try Node.where({ $0.id.eq(newParentID) }).fetchOne(database) != nil else { return false }
      // A cycle would form if nodeID is the new parent itself or any of its ancestors.
      if newParentID == nodeID { return false }
      if try ancestorIDs(database, of: newParentID).contains(nodeID) { return false }
    }
    try Node.where { $0.id.eq(nodeID) }.update { $0.parentID = #bind(newParentID) }.execute(database)
    return true
  }

  /// The ancestor chain of `nodeID` within the current transaction: `[parent, grandparent, …, root]`,
  /// excluding `nodeID`. Cycle-safe — a visited set bounds a corrupt (pre-existing) parent cycle.
  static func ancestorIDs(_ database: Database, of nodeID: UUID) throws -> [UUID] {
    var chain: [UUID] = []
    var seen: Set<UUID> = [nodeID]
    var cursor = try Node.where { $0.id.eq(nodeID) }.fetchOne(database)?.parentID
    while let current = cursor, seen.insert(current).inserted {
      chain.append(current)
      cursor = try Node.where { $0.id.eq(current) }.fetchOne(database)?.parentID
    }
    return chain
  }

  public static func nest(_ database: any DatabaseWriter, child: String, under parent: String) throws -> Bool {
    try database.write { database in
      guard let c = try find(database, nameOrID: child), let p = try find(database, nameOrID: parent) else { return false }
      return try reparent(database, nodeID: c.id, newParentID: p.id)
    }
  }

  public static func rename(_ database: any DatabaseWriter, node: String, to newName: String) throws -> Bool {
    try database.write { database in
      guard let n = try find(database, nameOrID: node) else { return false }
      try Node.where { $0.id.eq(n.id) }.update { $0.name = newName }.execute(database)
      return true
    }
  }

  public static func retype(_ database: any DatabaseWriter, node: String, to newKind: NodeKind) throws -> Bool {
    try database.write { database in
      guard let n = try find(database, nameOrID: node) else { return false }
      try Node.where { $0.id.eq(n.id) }.update { $0.kind = newKind }.execute(database)
      return true
    }
  }

  /// Atomic edit of a node's user-facing fields (the app's Edit modal). Leaves description,
  /// parentID, state, branchKey untouched. Returns false — writing nothing — for an unknown id.
  @discardableResult
  public static func update(_ database: any DatabaseWriter, nodeID: UUID,
                            name: String, kind: NodeKind, icon: String, colorTag: String,
                            context: String = "") throws -> Bool {
    try database.write { database in
      guard try Node.where({ $0.id.eq(nodeID) }).fetchOne(database) != nil else { return false }
      try Node.where { $0.id.eq(nodeID) }.update {
        $0.name = name; $0.kind = kind; $0.icon = icon; $0.colorTag = colorTag; $0.context = context
      }.execute(database)
      return true
    }
  }

  /// Archive `nodeID` and all its descendants (whole-subtree, state = "archived"). Unlike
  /// `delete`, archive is always allowed — it's the escape hatch for source-bearing nodes that
  /// `delete` refuses. Returns false — writing nothing — for an unknown id.
  @discardableResult
  public static func archive(_ database: any DatabaseWriter, nodeID: UUID) throws -> Bool {
    try setSubtreeState(database, nodeID: nodeID, to: .archived)
  }

  /// Restore `nodeID` and all its descendants to state = "active", AND walk `nodeID`'s ancestor
  /// chain flipping "archived" ancestors to "active" too — symmetric with
  /// `Ingester.resurfaceIfArchived`, so unarchiving a NESTED node never leaves it detached under a
  /// still-archived parent (which would otherwise render as a phantom top-level root). A "muted"
  /// ancestor is sticky and left untouched — there is no write path to mute.
  @discardableResult
  public static func unarchive(_ database: any DatabaseWriter, nodeID: UUID) throws -> Bool {
    try database.write { database in
      guard try setSubtreeState(database, nodeID: nodeID, to: .active) else { return false }
      try resurface(database, ids: ancestorIDs(database, of: nodeID))
      return true
    }
  }

  private static func setSubtreeState(_ database: any DatabaseWriter, nodeID: UUID, to state: NodeState) throws -> Bool {
    try database.write { database in try setSubtreeState(database, nodeID: nodeID, to: state) }
  }

  /// In-transaction core, so `unarchive` can set the subtree AND walk the ancestor chain within one write.
  private static func setSubtreeState(_ database: Database, nodeID: UUID, to state: NodeState) throws -> Bool {
    guard try Node.where({ $0.id.eq(nodeID) }).fetchOne(database) != nil else { return false }
    let all = try Node.all.fetchAll(database)
    let ids = NodeForest.descendantIDs(of: nodeID, in: all).union([nodeID])
    for id in ids {
      try Node.where { $0.id.eq(id) }.update { $0.state = state }.execute(database)
    }
    return true
  }

  /// Flips every "archived" node among `ids` to "active", leaving any other state (e.g. "muted")
  /// untouched. In-transaction; shared by `unarchive` and `Ingester.resurfaceIfArchived`.
  static func resurface(_ database: Database, ids: [UUID]) throws {
    for id in ids {
      guard let n = try Node.where({ $0.id.eq(id) }).fetchOne(database), n.state == .archived else { continue }
      try Node.where { $0.id.eq(id) }.update { $0.state = NodeState.active }.execute(database)
    }
  }

  /// The outcome of a delete attempt. `.blocked` = the subtree still has a live source, which
  /// `ProjectResolver` would re-create on the next drain — so delete is refused.
  public enum DeleteResult: Equatable, Sendable {
    case deleted(nodes: Int, events: Int, looseEnds: Int)
    case blocked
    case notFound
  }

  /// Delete `nodeID` and all its descendants (manual-only). Refused (`.blocked`, nothing written)
  /// if any node in the subtree has a `Source`, or is an auto-birthed strand (`branchKey` set).
  /// Child rows cascade via FK on node-row delete; `nodes.parentID` is SET NULL, so the subtree
  /// is deleted explicitly.
  @discardableResult
  public static func delete(_ database: any DatabaseWriter, nodeID: UUID) throws -> DeleteResult {
    try database.write { database in
      guard try Node.where({ $0.id.eq(nodeID) }).fetchOne(database) != nil else { return .notFound }
      let all = try Node.all.fetchAll(database)
      let ids = NodeForest.descendantIDs(of: nodeID, in: all).union([nodeID])

      // Manual-only guard: a subtree node with a live source OR an auto-birthed strand
      // (branchKey set) would re-materialize on the next drain — refuse.
      for id in ids {
        if all.first(where: { $0.id == id })?.branchKey != nil { return .blocked }
        if try Source.where({ $0.nodeID.eq(id) }).fetchCount(database) > 0 { return .blocked }
      }

      var events = 0, looseEnds = 0
      for id in ids {
        events += try Event.where { $0.nodeID.eq(id) }.fetchCount(database)
        looseEnds += try LooseEnd.where { $0.nodeID.eq(id) }.fetchCount(database)
      }
      for id in ids {
        try Node.where { $0.id.eq(id) }.delete().execute(database)   // cascades its child-table rows
      }
      return .deleted(nodes: ids.count, events: events, looseEnds: looseEnds)
    }
  }

  /// True if `nodeID` or any descendant would resurrect on the next drain — has its own `Source`,
  /// or is an auto-birthed strand (`branchKey` set). The app gates the Delete menu item on this.
  public static func subtreeIsActivityBorn(_ database: any DatabaseReader, nodeID: UUID) throws -> Bool {
    try database.read { database in
      let all = try Node.all.fetchAll(database)
      let ids = NodeForest.descendantIDs(of: nodeID, in: all).union([nodeID])
      for id in ids {
        if all.first(where: { $0.id == id })?.branchKey != nil { return true }
        if try Source.where({ $0.nodeID.eq(id) }).fetchCount(database) > 0 { return true }
      }
      return false
    }
  }
}

public enum NodeTree {
  /// Render nodes as an indented tree (roots first, children under parents, siblings by name).
  public static func render(_ nodes: [Node]) -> [String] {
    let byParent = Dictionary(grouping: nodes, by: { $0.parentID })
    var lines: [String] = []
    func walk(_ parent: UUID?, depth: Int) {
      for n in (byParent[parent] ?? []).sorted(by: { $0.name < $1.name }) {
        let indent = String(repeating: "  ", count: depth)
        let kindTag = n.kind == .project ? "" : " (\(n.kind.rawValue))"
        lines.append("\(indent)\(n.name)\(kindTag)  [\(n.state.rawValue)]")
        walk(n.id, depth: depth + 1)
      }
    }
    walk(nil, depth: 0)
    return lines
  }
}
