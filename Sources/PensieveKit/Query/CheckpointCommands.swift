import Foundation
import SQLiteData

public enum CheckpointCommands {
  @discardableResult
  public static func add(_ database: any DatabaseWriter, projectName: String, note: String) throws -> Bool {
    try database.write { database in
      guard let project = try Node.where({ $0.name.eq(projectName) }).fetchOne(database) else { return false }
      try Checkpoint.insert { Checkpoint(nodeID: project.id, note: note) }.execute(database)
      return true
    }
  }
}
