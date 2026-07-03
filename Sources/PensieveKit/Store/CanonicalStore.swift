import Foundation
import SQLiteData   // re-exports GRDB symbols (DatabasePool, Configuration, DatabaseMigrator, #sql).
                    // If a symbol is missing at compile time, add `import GRDB`.

public func openCanonicalDatabase(at url: URL) throws -> any DatabaseWriter {
  try FileManager.default.createDirectory(
    at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
  let configuration = Configuration()
  let db = try DatabasePool(path: url.path, configuration: configuration)  // WAL, multi-process
  try migrateCanonical(db)
  return db
}

func migrateCanonical(_ db: any DatabaseWriter) throws {
  var migrator = DatabaseMigrator()
  migrator.registerMigration("v1-projects") { db in
    try #sql("""
      CREATE TABLE "projects"(
        "id" TEXT NOT NULL PRIMARY KEY,
        "name" TEXT NOT NULL,
        "state" TEXT NOT NULL DEFAULT 'active',
        "createdAt" TEXT NOT NULL
      ) STRICT
      """).execute(db)
  }
  try migrator.migrate(db)
}
