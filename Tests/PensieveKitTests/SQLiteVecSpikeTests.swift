import Testing
import Foundation
import SQLiteData   // re-exports GRDB
import CSQLiteVec
@testable import PensieveKit

@Suite struct SQLiteVecSpikeTests {
  @Test func vec0KNNReturnsNearestFirst() throws {
    // Spike finding: Apple's system libsqlite3 disables sqlite3_auto_extension()
    // (API_DEPRECATED "Process-global auto extensions are not supported on Apple
    // platforms"; it fails at runtime with SQLITE_MISUSE == 21). The working path
    // on this platform is per-connection registration via GRDB's
    // Configuration.prepareDatabase, calling pensieve_sqlite_vec_init_connection
    // with the raw sqlite3 handle.
    var config = Configuration()
    config.prepareDatabase { database in
      let returnCode = pensieve_sqlite_vec_init_connection(UnsafeMutableRawPointer(database.sqliteConnection))
      #expect(returnCode == 0)   // SQLITE_OK
    }
    let queue = try DatabaseQueue(configuration: config)   // in-memory
    try queue.write { database in
      try database.execute(sql: "CREATE VIRTUAL TABLE vt USING vec0(item_id TEXT PRIMARY KEY, embedding float[3])")
      try database.execute(sql: "INSERT INTO vt(item_id, embedding) VALUES (?, ?)",
                     arguments: ["a", "[1.0, 0.0, 0.0]"])
      try database.execute(sql: "INSERT INTO vt(item_id, embedding) VALUES (?, ?)",
                     arguments: ["b", "[0.0, 1.0, 0.0]"])
    }
    let ids = try queue.read { database in
      try String.fetchAll(database, sql: """
        SELECT item_id FROM vt WHERE embedding MATCH ? AND k = 2 ORDER BY distance
        """, arguments: ["[0.9, 0.1, 0.0]"])
    }
    #expect(ids.first == "a")   // nearest to the query vector
    #expect(ids.count == 2)
  }
}
