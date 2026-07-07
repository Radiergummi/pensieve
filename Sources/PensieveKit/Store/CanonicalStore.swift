import Foundation
import SQLiteData   // re-exports GRDB symbols (DatabasePool, Configuration, DatabaseMigrator, #sql).

public func openCanonicalDatabase(at url: URL) throws -> any DatabaseWriter {
  try PensievePaths.ensureParentDirectory(of: url)
  var configuration = Configuration()
  configuration.busyMode = .timeout(5)   // wait, don't throw SQLITE_BUSY, under writer contention
  let db = try DatabasePool(path: url.path, configuration: configuration)  // WAL, multi-process
  try migrateCanonical(db)
  return db
}

/// Opens an EXISTING canonical store strictly read-only (no migrator run, cannot create the file).
/// For read-only observers (e.g. `MonitorSnapshot`) that must never write to or contend with the
/// canonical store's write path.
public func openCanonicalDatabaseReadOnly(at url: URL) throws -> any DatabaseReader {
  var configuration = Configuration()
  configuration.readonly = true
  configuration.busyMode = .timeout(5)   // wait out a concurrent writer checkpoint rather than reading empty
  return try DatabasePool(path: url.path, configuration: configuration)
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
  migrator.registerMigration("v3-fingerprint-extraction-provenance") { db in
    try #sql(#"ALTER TABLE "events" ADD COLUMN "fingerprint" TEXT"#).execute(db)
    try #sql(#"ALTER TABLE "events" ADD COLUMN "extractedAt" TEXT"#).execute(db)
    try #sql(#"ALTER TABLE "looseEnds" ADD COLUMN "role" TEXT NOT NULL DEFAULT ''"#).execute(db)
    try #sql(#"ALTER TABLE "looseEnds" ADD COLUMN "sourceMessageIndex" INTEGER NOT NULL DEFAULT 0"#).execute(db)
    // Backfill fingerprints for already-captured rows so the unique index is meaningful.
    try #sql(#"UPDATE "events" SET "fingerprint" = 'commit:' || json_extract("detailJSON", '$.hash') WHERE "kind" = 'git.commit' AND "fingerprint" IS NULL"#).execute(db)
    try #sql(#"UPDATE "events" SET "fingerprint" = 'session:' || json_extract("detailJSON", '$.sessionID') WHERE "kind" = 'cc.session' AND "fingerprint" IS NULL"#).execute(db)
    // An upgraded 1A DB may already contain two events with the same commit hash / sessionID
    // under one source (1A had no dedup), which would now backfill to identical fingerprints
    // and make the unique index below fail. Collapse those, keeping the earliest row. Pre-1B
    // DBs have no populated looseEnds yet, so the ON DELETE CASCADE this triggers is harmless.
    try #sql(#"""
      DELETE FROM "events" WHERE "fingerprint" IS NOT NULL AND "rowid" NOT IN
        (SELECT MIN("rowid") FROM "events" WHERE "fingerprint" IS NOT NULL GROUP BY "sourceID", "fingerprint")
      """#).execute(db)
    // NULLs are distinct in a SQLite unique index, so unbackfilled rows (e.g. checkouts) don't collide.
    try #sql(#"CREATE UNIQUE INDEX "idx_events_source_fingerprint" ON "events"("sourceID", "fingerprint")"#).execute(db)
  }
  // .immediate: keeps foreign-key enforcement ON during this migration so SQLite's
  // ALTER TABLE RENAME TO / RENAME COLUMN auto-rewrites the FK clauses in "sources",
  // "events", "looseEnds", "checkpoints" (the default .deferred disables FK checks
  // first, which suppresses that auto-rewrite and leaves them pointing at "projects").
  migrator.registerMigration("v4-nodes-tree", foreignKeyChecks: .immediate) { db in
    try #sql(#"ALTER TABLE "projects" RENAME TO "nodes""#).execute(db)
    try #sql(#"ALTER TABLE "nodes" ADD COLUMN "parentID" TEXT REFERENCES "nodes"("id") ON DELETE SET NULL"#).execute(db)
    try #sql(#"ALTER TABLE "nodes" ADD COLUMN "kind" TEXT NOT NULL DEFAULT 'project'"#).execute(db)
    try #sql(#"ALTER TABLE "nodes" ADD COLUMN "description" TEXT NOT NULL DEFAULT ''"#).execute(db)
    try #sql(#"ALTER TABLE "nodes" ADD COLUMN "metadataJSON" TEXT NOT NULL DEFAULT '{}'"#).execute(db)
    try #sql(#"ALTER TABLE "nodes" ADD COLUMN "branchKey" TEXT"#).execute(db)
    try #sql(#"ALTER TABLE "sources" RENAME COLUMN "projectID" TO "nodeID""#).execute(db)
    try #sql(#"ALTER TABLE "events" RENAME COLUMN "projectID" TO "nodeID""#).execute(db)
    try #sql(#"ALTER TABLE "looseEnds" RENAME COLUMN "projectID" TO "nodeID""#).execute(db)
    try #sql(#"ALTER TABLE "checkpoints" RENAME COLUMN "projectID" TO "nodeID""#).execute(db)
  }
  migrator.registerMigration("v5-event-branchkey") { db in
    try #sql(#"ALTER TABLE "events" ADD COLUMN "branchKey" TEXT"#).execute(db)
  }
  migrator.registerMigration("v6-session-branches") { db in
    try #sql("""
      CREATE TABLE "sessionBranches"(
        "id" TEXT NOT NULL PRIMARY KEY,
        "sessionID" TEXT NOT NULL,
        "branch" TEXT,
        "commonDir" TEXT NOT NULL,
        "createdAt" TEXT NOT NULL
      ) STRICT
      """).execute(db)
    try #sql(#"CREATE UNIQUE INDEX "idx_sessionbranches_sessionid" ON "sessionBranches"("sessionID")"#).execute(db)
  }
  migrator.registerMigration("v7-incremental-extraction") { db in
    try #sql(#"ALTER TABLE "events" ADD COLUMN "extractedMessageCount" INTEGER NOT NULL DEFAULT 0"#).execute(db)
    // -1 = "never watermarked" (unambiguous sentinel that can't collide with a real byte size,
    // including a genuine 0-byte transcript). Existing rows backfill to -1; the runner's legacy-init
    // then initializes them once without extracting (see ExtractionRunner.run()).
    try #sql(#"ALTER TABLE "events" ADD COLUMN "extractedTranscriptSize" INTEGER NOT NULL DEFAULT -1"#).execute(db)
  }
  try migrator.migrate(db)
}
