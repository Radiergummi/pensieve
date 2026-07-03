import Foundation
import SQLiteData   // re-exports GRDB symbols (DatabasePool, Configuration, DatabaseMigrator, #sql).
                    // If a symbol is missing at compile time, add `import GRDB`.

public func openCanonicalDatabase(at url: URL) throws -> any DatabaseWriter {
  try PensievePaths.ensureParentDirectory(of: url)
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
  migrator.registerMigration("v2-sources-events-looseends-checkpoints") { db in
    try #sql("""
      CREATE TABLE "sources"(
        "id" TEXT NOT NULL PRIMARY KEY,
        "projectID" TEXT NOT NULL REFERENCES "projects"("id") ON DELETE CASCADE,
        "kind" TEXT NOT NULL,
        "key" TEXT NOT NULL,
        "createdAt" TEXT NOT NULL
      ) STRICT
      """).execute(db)
    try #sql("""
      CREATE TABLE "events"(
        "id" TEXT NOT NULL PRIMARY KEY,
        "projectID" TEXT NOT NULL REFERENCES "projects"("id") ON DELETE CASCADE,
        "sourceID" TEXT NOT NULL REFERENCES "sources"("id") ON DELETE CASCADE,
        "occurredAt" TEXT NOT NULL,
        "kind" TEXT NOT NULL,
        "summary" TEXT NOT NULL,
        "detailJSON" TEXT NOT NULL,
        "createdAt" TEXT NOT NULL
      ) STRICT
      """).execute(db)
    try #sql("""
      CREATE TABLE "looseEnds"(
        "id" TEXT NOT NULL PRIMARY KEY,
        "projectID" TEXT NOT NULL REFERENCES "projects"("id") ON DELETE CASCADE,
        "sourceEventID" TEXT NOT NULL REFERENCES "events"("id") ON DELETE CASCADE,
        "text" TEXT NOT NULL,
        "quote" TEXT NOT NULL,
        "status" TEXT NOT NULL DEFAULT 'open',
        "createdAt" TEXT NOT NULL
      ) STRICT
      """).execute(db)
    try #sql("""
      CREATE TABLE "checkpoints"(
        "id" TEXT NOT NULL PRIMARY KEY,
        "projectID" TEXT NOT NULL REFERENCES "projects"("id") ON DELETE CASCADE,
        "note" TEXT NOT NULL,
        "createdAt" TEXT NOT NULL
      ) STRICT
      """).execute(db)
    try #sql(#"CREATE INDEX "idx_events_project" ON "events"("projectID", "occurredAt")"#).execute(db)
    try #sql(#"CREATE UNIQUE INDEX "idx_sources_key_kind" ON "sources"("key", "kind")"#).execute(db)
  }
  try migrator.migrate(db)
}
