import Foundation
import Testing
import SQLiteData
@testable import PensieveKit

@Test func checkpointInsertsForKnownProject() throws {
  let database = try openCanonicalDatabase(at: tempURL("cp"))
  _ = try ProjectResolver(database: database).resolve(path: "/p/colibri", kind: SourceKind.gitRepo)
  #expect(try CheckpointCommands.add(database, projectName: "colibri", note: "mid refactor") == true)
  #expect(try CheckpointCommands.add(database, projectName: "nope", note: "x") == false)
  let notes = try database.read { database in try Checkpoint.all.fetchAll(database) }
  #expect(notes.first?.note == "mid refactor")
}
