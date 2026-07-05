import Foundation
import SQLiteData
import GRDB

public enum SessionQueries {
  /// True if a session (by its `session:<id>` fingerprint) already has a canonical event.
  /// Discovery's cost guard — done before reading a transcript file.
  public static func isIngested(_ db: any DatabaseReader, sessionID: String) throws -> Bool {
    try db.read { db in
      try Event.where { $0.fingerprint.eq(Fingerprint.session(sessionID: sessionID)) }.fetchOne(db) != nil
    }
  }
}
