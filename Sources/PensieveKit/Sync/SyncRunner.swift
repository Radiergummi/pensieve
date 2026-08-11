import Foundation
import SQLiteData
import GRDB
import os

/// One `sync` cycle: drain the spool, discover + spool new session transcripts, drain again,
/// then run incremental extraction. Pure over injected dependencies (spool, database, provider,
/// projectsDir, clock) so it is testable without touching the live stores or `~/.claude`.
public struct SyncRunner {
  let spool: CaptureSpool
  let database: any DatabaseWriter
  let provider: any LLMProvider
  let projectsDir: URL
  let now: @Sendable () -> Date
  let searchIndexer: SearchIndexer?

  public init(spool: CaptureSpool, database: any DatabaseWriter, provider: any LLMProvider,
              projectsDir: URL, now: @escaping @Sendable () -> Date = Date.init,
              searchIndexer: SearchIndexer? = nil) {
    self.spool = spool; self.database = database; self.provider = provider
    self.projectsDir = projectsDir; self.now = now
    self.searchIndexer = searchIndexer
  }

  public struct Summary: Sendable {
    public let ingested: Int
    public let discovered: Int
    public let extracted: Int
  }

  public func run() async throws -> Summary {
    Log.sync.info("Sync cycle start")
    let ingester = Ingester(spool: spool, database: database, llm: provider)
    var ingested = try await ingester.drain()

    let discovered = TranscriptDiscovery.discover(projectsDir: projectsDir, now: now()) { sessionID in
      (try? SessionQueries.isIngested(database, sessionID: sessionID)) ?? false
    }
    for url in discovered {
      try? spool.append(kind: CaptureKind.ccSession,
                        payload: try encodeJSON(SessionRefPayload(transcriptPath: url.path)))
    }
    ingested += try await ingester.drain()
    await ingester.refineProjectNames()
    await ingester.describeProjectNodes()

    let results = try await ExtractionRunner(database: database, provider: provider).run()
    let extracted = results.reduce(0) { $0 + $1.inserted }
    Log.sync.info("""
      Sync complete: ingested=\(ingested, privacy: .public) discovered=\(discovered.count, privacy: .public) \
      extracted=\(extracted, privacy: .public)
      """)

    // Search index refresh (best-effort — BM25 is the only retrieval path, so it is never
    // optional). Hash-guarded, so an unchanged corpus costs one read.
    //
    // Deliberately no fallback to `PensievePaths.searchIndexURL()` when nil: a whole-rebuild
    // against the shared support directory would let any test that constructs a SyncRunner
    // overwrite the developer's live index with its fixture corpus. (The retired semantic block
    // here DID self-construct exactly that way, which is why it is worth naming.) Both production
    // entry points (`pensieve sync`, PensieveSyncAgent) inject one explicitly.
    searchIndexer?.sync(database)

    return Summary(ingested: ingested, discovered: discovered.count, extracted: extracted)
  }
}
