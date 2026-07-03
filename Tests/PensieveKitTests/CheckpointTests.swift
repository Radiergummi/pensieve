import Foundation
import Testing
import SQLiteData
@testable import PensieveKit

@Test func checkpointInsertsForKnownProject() throws {
  let db = try openCanonicalDatabase(at: tempURL("cp"))
  _ = try ProjectResolver(db: db).resolve(path: "/p/colibri", kind: SourceKind.gitRepo)
  #expect(try CheckpointCommands.add(db, projectName: "colibri", note: "mid refactor") == true)
  #expect(try CheckpointCommands.add(db, projectName: "nope", note: "x") == false)
  let notes = try db.read { db in try Checkpoint.all.fetchAll(db) }
  #expect(notes.first?.note == "mid refactor")
}
