import Foundation
import SQLiteData

public struct ProjectResolver {
  let db: any DatabaseWriter
  public init(db: any DatabaseWriter) { self.db = db }

  public func resolve(path: String, kind: String) throws -> (project: Project, source: Source) {
    try db.write { db in
      // 1. Exact source (path, kind) already exists?
      if let source = try Source.where({ $0.key.eq(path) && $0.kind.eq(kind) }).fetchOne(db),
         let project = try Project.where({ $0.id.eq(source.projectID) }).fetchOne(db) {
        return (project, source)
      }
      // 2. A project already bound to this path via another source kind?
      if let sibling = try Source.where({ $0.key.eq(path) }).fetchOne(db),
         let project = try Project.where({ $0.id.eq(sibling.projectID) }).fetchOne(db) {
        let source = Source(projectID: project.id, kind: kind, key: path)
        try Source.insert { source }.execute(db)
        return (project, source)
      }
      // 3. Brand-new project + source.
      let project = Project(name: (path as NSString).lastPathComponent)
      let source = Source(projectID: project.id, kind: kind, key: path)
      try Project.insert { project }.execute(db)
      try Source.insert { source }.execute(db)
      return (project, source)
    }
  }

  public func group(_ primaryID: UUID, into merged: [UUID]) throws {
    try db.write { db in
      for other in merged where other != primaryID {
        try Source.where { $0.projectID.eq(other) }
          .update { $0.projectID = primaryID }.execute(db)
        try Event.where { $0.projectID.eq(other) }
          .update { $0.projectID = primaryID }.execute(db)
        try LooseEnd.where { $0.projectID.eq(other) }
          .update { $0.projectID = primaryID }.execute(db)
        try Checkpoint.where { $0.projectID.eq(other) }
          .update { $0.projectID = primaryID }.execute(db)
        try Project.where { $0.id.eq(other) }.delete().execute(db)
      }
    }
  }
}
