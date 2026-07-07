import Foundation
import SQLiteData
import GRDB

public enum NodeCommands {
  /// Find a node by UUID string (preferred) or exact name.
  public static func find(_ db: Database, nameOrID: String) throws -> Node? {
    if let uuid = UUID(uuidString: nameOrID),
       let byID = try Node.where({ $0.id.eq(uuid) }).fetchOne(db) { return byID }
    return try Node.where { $0.name.eq(nameOrID) }.fetchOne(db)
  }

  @discardableResult
  public static func add(_ db: any DatabaseWriter, name: String, kind: String,
                         parent: String?, description: String) throws -> Node? {
    try db.write { db in
      var parentID: UUID? = nil
      if let parent {
        guard let p = try find(db, nameOrID: parent) else { return nil }
        parentID = p.id
      }
      let node = Node(name: name, parentID: parentID, kind: kind, description: description)
      try Node.insert { node }.execute(db)
      return node
    }
  }

  /// Reparent `nodeID` under `newParentID` (nil = move to root). Returns false — writing nothing — if
  /// either id is unknown or the move would create a cycle (`newParentID == nodeID`, or `nodeID` is an
  /// ancestor of `newParentID`). The read side (`NodeForest.build`) guards display; this guards data.
  @discardableResult
  public static func reparent(_ db: any DatabaseWriter, nodeID: UUID, newParentID: UUID?) throws -> Bool {
    try db.write { db in try reparent(db, nodeID: nodeID, newParentID: newParentID) }
  }

  /// In-transaction core, so `nest` can reuse the guard inside its own `db.write`.
  static func reparent(_ db: Database, nodeID: UUID, newParentID: UUID?) throws -> Bool {
    guard try Node.where({ $0.id.eq(nodeID) }).fetchOne(db) != nil else { return false }
    if let newParentID {
      guard try Node.where({ $0.id.eq(newParentID) }).fetchOne(db) != nil else { return false }
      // Walk up from the intended parent; hitting nodeID means this move would form a cycle.
      var cursor: UUID? = newParentID
      while let current = cursor {
        if current == nodeID { return false }
        cursor = try Node.where { $0.id.eq(current) }.fetchOne(db)?.parentID
      }
    }
    try Node.where { $0.id.eq(nodeID) }.update { $0.parentID = #bind(newParentID) }.execute(db)
    return true
  }

  public static func nest(_ db: any DatabaseWriter, child: String, under parent: String) throws -> Bool {
    try db.write { db in
      guard let c = try find(db, nameOrID: child), let p = try find(db, nameOrID: parent) else { return false }
      return try reparent(db, nodeID: c.id, newParentID: p.id)
    }
  }

  public static func rename(_ db: any DatabaseWriter, node: String, to newName: String) throws -> Bool {
    try db.write { db in
      guard let n = try find(db, nameOrID: node) else { return false }
      try Node.where { $0.id.eq(n.id) }.update { $0.name = newName }.execute(db)
      return true
    }
  }

  public static func retype(_ db: any DatabaseWriter, node: String, to newKind: String) throws -> Bool {
    try db.write { db in
      guard let n = try find(db, nameOrID: node) else { return false }
      try Node.where { $0.id.eq(n.id) }.update { $0.kind = newKind }.execute(db)
      return true
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
        let kindTag = n.kind == "project" ? "" : " (\(n.kind))"
        lines.append("\(indent)\(n.name)\(kindTag)  [\(n.state)]")
        walk(n.id, depth: depth + 1)
      }
    }
    walk(nil, depth: 0)
    return lines
  }
}
