import Foundation
import SQLiteData
import GRDB

public enum SessionQueries {
  /// True if a session (by its `session:<id>` fingerprint) already has a canonical event.
  /// Discovery's cost guard — done before reading a transcript file.
  public static func isIngested(_ database: any DatabaseReader, sessionID: String) throws -> Bool {
    try database.read { database in
      try Event.where { $0.fingerprint.eq(Fingerprint.session(sessionID: sessionID)) }.fetchOne(database) != nil
    }
  }
}
