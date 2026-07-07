import Foundation
import SQLiteData
import GRDB

public struct ProjectResolver: Sendable {
  let db: any DatabaseWriter
  public init(db: any DatabaseWriter) { self.db = db }

  /// Canonicalizes a path (resolves symlinks + standardizes) so different spellings of
  /// the same directory (e.g. /tmp vs /private/tmp) produce one source key.
  static func canonical(_ path: String) -> String {
    URL(fileURLWithPath: path).resolvingSymlinksInPath().path
  }

  /// Human-readable node name from an identity key. A git common-dir ends in `.git`;
  /// name the node after the repo directory, not ".git".
  static func displayName(forKey key: String) -> String {
    let url = URL(fileURLWithPath: key)
    return url.lastPathComponent == ".git"
      ? url.deletingLastPathComponent().lastPathComponent
      : url.lastPathComponent
  }

  public func resolve(path: String, kind: String) throws -> (project: Node, source: Source) {
    try db.write { db in try resolve(db, path: path, kind: kind) }
  }

  /// Resolve within an existing transaction, so callers can combine resolve + insert atomically.
  public func resolve(_ db: Database, path rawPath: String, kind: String)
    throws -> (project: Node, source: Source) {
    let path = Self.canonical(rawPath)
    // 1. Exact source (path, kind) already exists?
    if let source = try Source.where({ $0.key.eq(path) && $0.kind.eq(kind) }).fetchOne(db),
       let project = try Node.where({ $0.id.eq(source.nodeID) }).fetchOne(db) {
      return (project, source)
    }
    // 2. A project already bound to this path via another source kind?
    if let sibling = try Source.where({ $0.key.eq(path) }).fetchOne(db),
       let project = try Node.where({ $0.id.eq(sibling.nodeID) }).fetchOne(db) {
      let source = Source(nodeID: project.id, kind: kind, key: path)
      try Source.insert { source }.execute(db)
      return (project, source)
    }
    // 3. Brand-new project + source.
    let project = Node(name: Self.displayName(forKey: path))
    let source = Source(nodeID: project.id, kind: kind, key: path)
    try Node.insert { project }.execute(db)
    try Source.insert { source }.execute(db)
    return (project, source)
  }

  public func group(_ primaryID: UUID, into merged: [UUID]) throws {
    try db.write { db in
      let absorbed = Set(merged).subtracting([primaryID])
      guard !absorbed.isEmpty else { return }

      // 1. Lift the primary above any absorbed node on its OWN ancestor chain, so that reattaching
      //    an absorbed node's children to the primary below can never fold the primary under itself
      //    or under a soon-deleted node. The primary takes the position of the highest (closest to
      //    root) absorbed ancestor: its new parent is that ancestor's parent (a survivor, or root).
      let chain = try NodeCommands.ancestorIDs(db, of: primaryID)   // [parent, …, root]
      if let highest = chain.lastIndex(where: { absorbed.contains($0) }) {
        let newParent = chain.indices.contains(highest + 1) ? chain[highest + 1] : nil
        try Node.where { $0.id.eq(primaryID) }
          .update { $0.parentID = #bind(newParent) }.execute(db)
      }

      // 2. Absorb each merged node into the primary.
      for other in absorbed {
        try Source.where { $0.nodeID.eq(other) }.update { $0.nodeID = primaryID }.execute(db)
        try Event.where { $0.nodeID.eq(other) }.update { $0.nodeID = primaryID }.execute(db)
        try LooseEnd.where { $0.nodeID.eq(other) }.update { $0.nodeID = primaryID }.execute(db)
        try Checkpoint.where { $0.nodeID.eq(other) }.update { $0.nodeID = primaryID }.execute(db)
        // Reattach other's children to the primary, skipping other absorbed nodes (deleted anyway).
        // Step 1 already lifted the primary off the absorbed set, so it is never among these children.
        let children = try Node.where { $0.parentID.eq(other) }.fetchAll(db)
        for child in children where !absorbed.contains(child.id) {
          try Node.where { $0.id.eq(child.id) }
            .update { $0.parentID = #bind(primaryID) }.execute(db)
        }
        try Node.where { $0.id.eq(other) }.delete().execute(db)
      }
    }
  }
}
