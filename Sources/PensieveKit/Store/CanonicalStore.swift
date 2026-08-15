import Foundation
import SQLiteData   // re-exports GRDB symbols (DatabasePool, Configuration, DatabaseMigrator, #sql).

public func openCanonicalDatabase(at url: URL) throws -> any DatabaseWriter {
  try PensievePaths.ensureParentDirectory(of: url)
  var configuration = Configuration()
  configuration.busyMode = .timeout(5)   // wait, don't throw SQLITE_BUSY, under writer contention
  let database = try DatabasePool(path: url.path, configuration: configuration)  // WAL, multi-process
  try migrateCanonical(database)
  return database
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

func migrateCanonical(_ database: any DatabaseWriter) throws {
  var migrator = DatabaseMigrator()
  registerV1Migration(on: &migrator)
  registerV2Migration(on: &migrator)
  registerV3Migration(on: &migrator)
  registerTreeMigrations(on: &migrator)
  registerRecentMigrations(on: &migrator)
  try migrator.migrate(database)
}

private func registerV1Migration(on migrator: inout DatabaseMigrator) {
  migrator.registerMigration("v1-projects") { database in
    try #sql("""
      CREATE TABLE "projects"(
        "id" TEXT NOT NULL PRIMARY KEY,
        "name" TEXT NOT NULL,
        "state" TEXT NOT NULL DEFAULT 'active',
        "createdAt" TEXT NOT NULL
      ) STRICT
      """).execute(database)
  }
}

private func registerV2Migration(on migrator: inout DatabaseMigrator) {
  migrator.registerMigration("v2-sources-events-looseends-checkpoints") { database in
    try #sql("""
      CREATE TABLE "sources"(
        "id" TEXT NOT NULL PRIMARY KEY,
        "projectID" TEXT NOT NULL REFERENCES "projects"("id") ON DELETE CASCADE,
        "kind" TEXT NOT NULL,
        "key" TEXT NOT NULL,
        "createdAt" TEXT NOT NULL
      ) STRICT
      """).execute(database)
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
      """).execute(database)
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
      """).execute(database)
    try #sql("""
      CREATE TABLE "checkpoints"(
        "id" TEXT NOT NULL PRIMARY KEY,
        "projectID" TEXT NOT NULL REFERENCES "projects"("id") ON DELETE CASCADE,
        "note" TEXT NOT NULL,
        "createdAt" TEXT NOT NULL
      ) STRICT
      """).execute(database)
    try #sql(#"CREATE INDEX "idx_events_project" ON "events"("projectID", "occurredAt")"#).execute(database)
    try #sql(#"CREATE UNIQUE INDEX "idx_sources_key_kind" ON "sources"("key", "kind")"#).execute(database)
  }
}

private func registerV3Migration(on migrator: inout DatabaseMigrator) {
  migrator.registerMigration("v3-fingerprint-extraction-provenance") { database in
    try #sql(#"ALTER TABLE "events" ADD COLUMN "fingerprint" TEXT"#).execute(database)
    try #sql(#"ALTER TABLE "events" ADD COLUMN "extractedAt" TEXT"#).execute(database)
    try #sql(#"ALTER TABLE "looseEnds" ADD COLUMN "role" TEXT NOT NULL DEFAULT ''"#).execute(database)
    try #sql(#"ALTER TABLE "looseEnds" ADD COLUMN "sourceMessageIndex" INTEGER NOT NULL DEFAULT 0"#).execute(database)
    // Backfill fingerprints for already-captured rows so the unique index is meaningful.
    try #sql(#"""
      UPDATE "events" SET "fingerprint" = 'commit:' || json_extract("detailJSON", '$.hash')
        WHERE "kind" = 'git.commit' AND "fingerprint" IS NULL
      """#).execute(database)
    try #sql(#"""
      UPDATE "events" SET "fingerprint" = 'session:' || json_extract("detailJSON", '$.sessionID')
        WHERE "kind" = 'cc.session' AND "fingerprint" IS NULL
      """#).execute(database)
    // An upgraded 1A DB may already contain two events with the same commit hash / sessionID
    // under one source (1A had no dedup), which would now backfill to identical fingerprints
    // and make the unique index below fail. Collapse those, keeping the earliest row. Pre-1B
    // DBs have no populated looseEnds yet, so the ON DELETE CASCADE this triggers is harmless.
    try #sql(#"""
      DELETE FROM "events" WHERE "fingerprint" IS NOT NULL AND "rowid" NOT IN
        (SELECT MIN("rowid") FROM "events" WHERE "fingerprint" IS NOT NULL GROUP BY "sourceID", "fingerprint")
      """#).execute(database)
    // NULLs are distinct in a SQLite unique index, so unbackfilled rows (e.g. checkouts) don't collide.
    try #sql(#"CREATE UNIQUE INDEX "idx_events_source_fingerprint" ON "events"("sourceID", "fingerprint")"#).execute(database)
  }
}

private func registerTreeMigrations(on migrator: inout DatabaseMigrator) {
  // .immediate: keeps foreign-key enforcement ON during this migration so SQLite's
  // ALTER TABLE RENAME TO / RENAME COLUMN auto-rewrites the FK clauses in "sources",
  // "events", "looseEnds", "checkpoints" (the default .deferred disables FK checks
  // first, which suppresses that auto-rewrite and leaves them pointing at "projects").
  migrator.registerMigration("v4-nodes-tree", foreignKeyChecks: .immediate) { database in
    try #sql(#"ALTER TABLE "projects" RENAME TO "nodes""#).execute(database)
    try #sql(#"ALTER TABLE "nodes" ADD COLUMN "parentID" TEXT REFERENCES "nodes"("id") ON DELETE SET NULL"#).execute(database)
    try #sql(#"ALTER TABLE "nodes" ADD COLUMN "kind" TEXT NOT NULL DEFAULT 'project'"#).execute(database)
    try #sql(#"ALTER TABLE "nodes" ADD COLUMN "description" TEXT NOT NULL DEFAULT ''"#).execute(database)
    try #sql(#"ALTER TABLE "nodes" ADD COLUMN "metadataJSON" TEXT NOT NULL DEFAULT '{}'"#).execute(database)
    try #sql(#"ALTER TABLE "nodes" ADD COLUMN "branchKey" TEXT"#).execute(database)
    try #sql(#"ALTER TABLE "sources" RENAME COLUMN "projectID" TO "nodeID""#).execute(database)
    try #sql(#"ALTER TABLE "events" RENAME COLUMN "projectID" TO "nodeID""#).execute(database)
    try #sql(#"ALTER TABLE "looseEnds" RENAME COLUMN "projectID" TO "nodeID""#).execute(database)
    try #sql(#"ALTER TABLE "checkpoints" RENAME COLUMN "projectID" TO "nodeID""#).execute(database)
  }
  migrator.registerMigration("v5-event-branchkey") { database in
    try #sql(#"ALTER TABLE "events" ADD COLUMN "branchKey" TEXT"#).execute(database)
  }
  migrator.registerMigration("v6-session-branches") { database in
    try #sql("""
      CREATE TABLE "sessionBranches"(
        "id" TEXT NOT NULL PRIMARY KEY,
        "sessionID" TEXT NOT NULL,
        "branch" TEXT,
        "commonDir" TEXT NOT NULL,
        "createdAt" TEXT NOT NULL
      ) STRICT
      """).execute(database)
    try #sql(#"CREATE UNIQUE INDEX "idx_sessionbranches_sessionid" ON "sessionBranches"("sessionID")"#).execute(database)
  }
}

private func registerRecentMigrations(on migrator: inout DatabaseMigrator) {
  migrator.registerMigration("v7-incremental-extraction") { database in
    try #sql(#"ALTER TABLE "events" ADD COLUMN "extractedMessageCount" INTEGER NOT NULL DEFAULT 0"#).execute(database)
    // -1 = "never watermarked" (unambiguous sentinel that can't collide with a real byte size,
    // including a genuine 0-byte transcript). Existing rows backfill to -1; the runner's legacy-init
    // then initializes them once without extracting (see ExtractionRunner.run()).
    try #sql(#"ALTER TABLE "events" ADD COLUMN "extractedTranscriptSize" INTEGER NOT NULL DEFAULT -1"#).execute(database)
  }
  migrator.registerMigration("v8-node-appearance") { database in
    try #sql(#"ALTER TABLE "nodes" ADD COLUMN "icon" TEXT NOT NULL DEFAULT ''"#).execute(database)
    try #sql(#"ALTER TABLE "nodes" ADD COLUMN "colorTag" TEXT NOT NULL DEFAULT ''"#).execute(database)
  }
  migrator.registerMigration("v9-node-context") { database in
    try #sql(#"ALTER TABLE "nodes" ADD COLUMN "context" TEXT NOT NULL DEFAULT ''"#).execute(database)
  }
  migrator.registerMigration("v10-event-worksummary") { database in
    // Nullable: existing rows read NULL (un-enriched) and re-enrich on their next
    // size-changed extraction. Never gates anything — best-effort narration input.
    try #sql(#"ALTER TABLE "events" ADD COLUMN "workSummary" TEXT"#).execute(database)
  }
  migrator.registerMigration("v11-looseend-label") { database in
    // Human-confirmed + machine-suggested salience labels. NOT NULL DEFAULT '' (like v9 context)
    // so `.neq("noise")` filters correctly (a nullable column would drop NULL rows under SQL
    // three-valued logic). Additive; nothing gates on it — Phase 1 stays lossless.
    try #sql(#"ALTER TABLE "looseEnds" ADD COLUMN "label" TEXT NOT NULL DEFAULT ''"#).execute(database)
    try #sql(#"ALTER TABLE "looseEnds" ADD COLUMN "labelSuggestion" TEXT NOT NULL DEFAULT ''"#).execute(database)
  }

  migrator.registerMigration("v12-looseend-resolvedat") { database in
    // Nullable on purpose: NULL means "never resolved", the honest reading for every existing row,
    // and there are no closed rows to backfill. v11's three-valued-logic warning does not apply —
    // nothing filters on this column, it is only an ORDER BY key.
    try #sql(#"ALTER TABLE "looseEnds" ADD COLUMN "resolvedAt" TEXT"#).execute(database)
  }

  migrator.registerMigration("v13-passages") { database in
    // Additive: a new table only, no ALTER on an existing one, so every v4–v12 store opens
    // unchanged. Both foreign keys CASCADE — a deleted node or a re-ingested event must not
    // leave passages behind, because a passage whose anchor is gone can never be cited.
    try #sql("""
      CREATE TABLE "passages"(
        "id" TEXT NOT NULL PRIMARY KEY,
        "nodeID" TEXT NOT NULL REFERENCES "nodes"("id") ON DELETE CASCADE,
        "eventID" TEXT NOT NULL REFERENCES "events"("id") ON DELETE CASCADE,
        "turnIndex" INTEGER NOT NULL,
        "messageIndex" INTEGER NOT NULL,
        "role" TEXT NOT NULL,
        "text" TEXT NOT NULL,
        "occurredAt" TEXT NOT NULL,
        "createdAt" TEXT NOT NULL
      ) STRICT
      """).execute(database)
    // The write path deletes by event before rewriting (idempotent re-ingest), and the corpus
    // producer reads by node. Without these, both are full scans over the largest table in the
    // store — and `looseEnds` already demonstrates the cost of a missing nodeID index.
    try #sql(#"CREATE INDEX "idx_passages_event" ON "passages"("eventID")"#).execute(database)
    try #sql(#"CREATE INDEX "idx_passages_node" ON "passages"("nodeID", "occurredAt")"#).execute(database)
  }
}
