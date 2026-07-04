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

  public static func nest(_ db: any DatabaseWriter, child: String, under parent: String) throws -> Bool {
    try db.write { db in
      guard let c = try find(db, nameOrID: child), let p = try find(db, nameOrID: parent) else { return false }
      try Node.where { $0.id.eq(c.id) }.update { $0.parentID = #bind(p.id) }.execute(db)
      return true
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
