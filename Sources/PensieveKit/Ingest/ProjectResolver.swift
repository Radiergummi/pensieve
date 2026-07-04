import Foundation
import SQLiteData
import GRDB

public struct ProjectResolver {
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
      for other in merged where other != primaryID {
        try Source.where { $0.nodeID.eq(other) }
          .update { $0.nodeID = primaryID }.execute(db)
        try Event.where { $0.nodeID.eq(other) }
          .update { $0.nodeID = primaryID }.execute(db)
        try LooseEnd.where { $0.nodeID.eq(other) }
          .update { $0.nodeID = primaryID }.execute(db)
        try Checkpoint.where { $0.nodeID.eq(other) }
          .update { $0.nodeID = primaryID }.execute(db)
        try Node.where { $0.id.eq(other) }.delete().execute(db)
      }
    }
  }
}
