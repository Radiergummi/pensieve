import Foundation
import SQLiteData

public enum CheckpointCommands {
  @discardableResult
  public static func add(_ db: any DatabaseWriter, projectName: String, note: String) throws -> Bool {
    try db.write { db in
      guard let project = try Node.where({ $0.name.eq(projectName) }).fetchOne(db) else { return false }
      try Checkpoint.insert { Checkpoint(nodeID: project.id, note: note) }.execute(db)
      return true
    }
  }
}
